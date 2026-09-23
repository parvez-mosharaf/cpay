-- ============================================================
-- CPAY — 0051: Hide small settled payments (creator/moderator)
-- ============================================================
-- A global toggle, admin-controlled. When on, settled payments at or
-- below the threshold ($10 by default) disappear from everywhere a
-- creator or moderator can see payment data: the payment list, payment
-- counts, "Total earned", the tier progress, and daily settled figures
-- — for both roles.
--
-- ONE THING THIS DELIBERATELY DOES NOT TOUCH: withdrawable balance.
-- get_balance_for() / get_my_balance() are untouched by this migration
-- on purpose. The money behind a hidden payment is exactly as real and
-- exactly as withdrawable as before — this is a display filter, not a
-- financial one. Folding it into balance too would mean a creator could
-- become unable to withdraw money that is genuinely theirs because of a
-- visibility setting, which is a much bigger and more dangerous change
-- than "don't show me these on screen". If available balance should also
-- exclude these payments, that is a separate, explicit decision — say so
-- and it can be added.
--
-- The admin panel is completely unaffected: admin_list_payments(),
-- admin_global_stats(), admin_daily_settled(), daily_totals_for_cycle()
-- (used by daily-report and reconcile) all keep reading the full, true
-- ledger regardless of this toggle. reconcile in particular compares
-- against BTCPay's real numbers — filtering that would manufacture fake
-- mismatches against a system that has no idea this toggle exists.
-- ============================================================

insert into app_settings (key, value)
select 'hide_small_payments_enabled', 'false'::jsonb
where not exists (select 1 from app_settings where key = 'hide_small_payments_enabled');

insert into app_settings (key, value)
select 'hide_small_payments_threshold', '10'::jsonb
where not exists (select 1 from app_settings where key = 'hide_small_payments_threshold');


-- ============================================================
-- One helper, read once per query rather than per row
-- ============================================================
create or replace function small_payment_threshold()
returns numeric
language sql
stable
set search_path = public
as $$
  select case
    when (select value from app_settings where key = 'hide_small_payments_enabled') = 'true'::jsonb
    then coalesce((select value::text::numeric from app_settings where key = 'hide_small_payments_threshold'), 10)
    else -1  -- Nothing is ever <= -1, so the filter becomes a no-op when the toggle is off.
  end;
$$;


-- ============================================================
-- Creator-facing functions
-- ============================================================

-- get_my_payments() (0046) — the transaction list.
drop function if exists get_my_payments(int, int, text, text);
create or replace function get_my_payments(
  p_limit int default 60,
  p_offset int default 0,
  p_search text default null,
  p_status text default null
)
returns table (
  id uuid,
  amount_requested numeric,
  amount_settled numeric,
  status text,
  method text,
  created_at timestamptz,
  settled_at timestamptz,
  expires_at timestamptz,
  customer_city text,
  customer_country text,
  link_slug text,
  link_name text,
  surcharge_percent numeric,
  btcpay_invoice_id text,
  lightning_invoice text,
  marked_at timestamptz,
  marked_by_name text,
  marked_by_self boolean,
  mark_note text,
  total_count bigint
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_limit int := least(greatest(coalesce(p_limit, 60), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_status text := lower(nullif(trim(coalesce(p_status, '')), ''));
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_hide_at numeric := small_payment_threshold();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  if v_status is not null
     and v_status not in ('settled', 'new', 'pending', 'expired', 'invalid') then
    raise exception 'Invalid status filter';
  end if;

  return query
  with filtered as (
    select p.*
    from payments p
    left join payment_links pl on pl.id = p.payment_link_id
    where p.user_id = v_uid
      and (v_status is null or p.status = v_status)
      and not (p.status = 'settled' and p.amount_settled <= v_hide_at)
      and (
        v_search is null
        or p.btcpay_invoice_id ilike '%' || v_search || '%'
        or p.lightning_invoice ilike '%' || v_search || '%'
        or pl.slug ilike '%' || v_search || '%'
      )
  )
  select
    f.id, f.amount_requested, f.amount_settled, f.status, f.method,
    f.created_at, f.settled_at, f.expires_at,
    f.customer_city, f.customer_country,
    pl.slug, pl.display_name, s.surcharge_percent,
    f.btcpay_invoice_id, f.lightning_invoice,
    f.marked_at, mb.display_name, f.marked_by = v_uid, f.mark_note,
    count(*) over () as total_count
  from filtered f
  left join payment_links pl on pl.id = f.payment_link_id
  left join btcpay_shops s on s.id = pl.shop_id
  left join profiles mb on mb.id = f.marked_by
  order by f.created_at desc
  limit v_limit offset v_offset;
end;
$$;

revoke all on function get_my_payments(int, int, text, text) from public, anon;
grant execute on function get_my_payments(int, int, text, text) to authenticated;


-- get_my_totals() (0042) — "Total earned", settled count, tier progress.
-- Explicitly NOT touching `available` — see the note at the top of this
-- file for why withdrawable balance stays untouched by this toggle.
drop function if exists get_my_totals();
create or replace function get_my_totals()
returns table (
  earned numeric,
  queued numeric,
  withdrawn numeric,
  available numeric,
  settled_count bigint,
  pending_count bigint
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_hide_at numeric := small_payment_threshold();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  return query
  select
    b.earned,
    b.queued,
    b.withdrawn,
    b.available,
    coalesce(c.settled_count, 0),
    coalesce(c.pending_count, 0)
  from get_balance_for(v_uid) b
  cross join lateral (
    select
      count(*) filter (
        where p.status = 'settled' and not (p.amount_settled <= v_hide_at)
      ) as settled_count,
      count(*) filter (where p.status in ('new', 'pending')) as pending_count
    from payments p
    where p.user_id = v_uid
  ) c;
end;
$$;

revoke all on function get_my_totals() from public, anon;
grant execute on function get_my_totals() to authenticated;


-- my_daily_settled() (0041) — the creator's daily 5pm-5pm figures.
drop function if exists my_daily_settled(int);
create or replace function my_daily_settled(p_days int default 14)
returns table (
  cycle_date date,
  cycle_start timestamptz,
  cycle_end timestamptz,
  settled numeric,
  payment_count bigint
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_days int := least(greatest(coalesce(p_days, 14), 1), 60);
  v_cur_cycle date;
  v_hide_at numeric := small_payment_threshold();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  v_cur_cycle := ((now() at time zone 'Asia/Dhaka') - interval '17 hours')::date;

  return query
  with days as (
    select gs::date as cycle_date
    from generate_series(v_cur_cycle - (v_days - 1), v_cur_cycle, interval '1 day') as gs
  ),
  bounds as (
    select
      d.cycle_date,
      (d.cycle_date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' as cycle_start,
      (d.cycle_date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' + interval '24 hours' as cycle_end
    from days d
  )
  select
    b.cycle_date, b.cycle_start, b.cycle_end,
    coalesce(sum(p.amount_settled), 0),
    count(p.id)
  from bounds b
  left join payments p
    on p.user_id = v_uid
   and p.status = 'settled'
   and not (p.amount_settled <= v_hide_at)
   and p.settled_at >= b.cycle_start
   and p.settled_at <  b.cycle_end
  group by b.cycle_date, b.cycle_start, b.cycle_end
  order by b.cycle_date desc;
end;
$$;

revoke all on function my_daily_settled(int) from public, anon;
grant execute on function my_daily_settled(int) to authenticated;


-- ============================================================
-- Moderator-facing functions
-- ============================================================







-- staff_daily_settled() (0040) — the moderator's daily 5pm-5pm figures.
create or replace function staff_daily_settled(p_days int default 14)
returns table (
  creator_id uuid,
  creator_name text,
  creator_email text,
  cycle_date date,
  cycle_start timestamptz,
  cycle_end timestamptz,
  settled numeric,
  payment_count bigint
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_days int := least(greatest(coalesce(p_days, 14), 1), 60);
  v_cur_cycle date;
  v_hide_at numeric := small_payment_threshold();
begin
  if not (is_admin() or is_moderator()) then
    raise exception 'Not authorized';
  end if;

  v_cur_cycle := ((now() at time zone 'Asia/Dhaka') - interval '17 hours')::date;

  return query
  with days as (
    select gs::date as cycle_date
    from generate_series(v_cur_cycle - (v_days - 1), v_cur_cycle, interval '1 day') as gs
  ),
  bounds as (
    select
      d.cycle_date,
      (d.cycle_date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' as cycle_start,
      (d.cycle_date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' + interval '24 hours' as cycle_end
    from days d
  ),
  mine as (
    select pr.id, pr.display_name, pr.email
    from profiles pr
    where pr.role = 'creator' and handles_creator(pr.id)
  )
  select
    m.id, m.display_name, m.email,
    b.cycle_date, b.cycle_start, b.cycle_end,
    coalesce(sum(p.amount_settled), 0),
    count(p.id)
  from mine m
  cross join bounds b
  left join payments p
    on p.user_id = m.id
   and p.status = 'settled'
   and not (p.amount_settled <= v_hide_at)
   and p.settled_at >= b.cycle_start
   and p.settled_at <  b.cycle_end
  group by m.id, m.display_name, m.email, b.cycle_date, b.cycle_start, b.cycle_end
  order by b.cycle_date desc, m.display_name;
end;
$$;

revoke all on function staff_daily_settled(int) from public, anon;
grant execute on function staff_daily_settled(int) to authenticated;


-- ============================================================
-- Moderator-facing functions
-- ------------------------------------------------------------
-- Each one below is the REAL current definition from its own migration
-- (0031, 0038), copied field-for-field, with exactly one change: the
-- small-payment filter added to whichever WHERE/FILTER clause already
-- restricts to status = 'settled'. Parameter names, defaults, and
-- return columns are all unchanged, because the frontend already calls
-- these with specific argument names and reads specific field names —
-- changing either would silently break the moderator panel rather than
-- filter it.
-- ============================================================

-- staff_list_payments() — real signature from 0038: p_time, not
-- p_time_filter; no total_count column (the panel infers "more to load"
-- from whether a page came back full, not from a count).
drop function if exists staff_list_payments(int, int, text, text, text);

create or replace function staff_list_payments(
  p_limit int default 120,
  p_offset int default 0,
  p_search text default null,
  p_status text default null,
  p_time text default null
)
returns table (
  id uuid,
  amount_requested numeric,
  amount_settled numeric,
  status text,
  method text,
  created_at timestamptz,
  settled_at timestamptz,
  expires_at timestamptz,
  customer_city text,
  customer_country text,
  creator_id uuid,
  creator_email text,
  creator_name text,
  link_slug text,
  shop_name text,
  surcharge_percent numeric,
  btcpay_invoice_id text,
  lightning_invoice text,
  marked_at timestamptz,
  marked_by_name text,
  mark_note text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 120), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_status text := lower(nullif(trim(coalesce(p_status, '')), ''));
  v_time text := lower(nullif(trim(coalesce(p_time, '')), ''));
  v_now timestamptz := now();
  v_start timestamptz := null;
  v_hide_at numeric := small_payment_threshold();
begin
  if not (is_admin() or is_moderator()) then
    raise exception 'Not authorized';
  end if;

  if v_status is not null and v_status not in ('settled', 'new', 'pending', 'expired', 'invalid') then
    raise exception 'Invalid status filter';
  end if;

  if v_time = 'today' then
    v_start := date_trunc('day', v_now);
  elsif v_time = '7d' then
    v_start := v_now - interval '7 days';
  elsif v_time = '30d' then
    v_start := v_now - interval '30 days';
  elsif v_time is null or v_time = '' then
    v_start := null;
  else
    raise exception 'Invalid time filter';
  end if;

  return query
  select
    p.id,
    p.amount_requested,
    p.amount_settled,
    p.status,
    p.method,
    p.created_at,
    p.settled_at,
    p.expires_at,
    p.customer_city,
    p.customer_country,
    p.user_id,
    pr.email,
    pr.display_name,
    pl.slug,
    s.name,
    s.surcharge_percent,
    p.btcpay_invoice_id,
    p.lightning_invoice,
    p.marked_at,
    mb.display_name,
    p.mark_note
  from payments p
  join profiles pr on pr.id = p.user_id
  left join payment_links pl on pl.id = p.payment_link_id
  left join btcpay_shops s on s.id = pl.shop_id
  left join profiles mb on mb.id = p.marked_by
  where (is_admin() or handles_creator(p.user_id))
    -- The one line added to the original: settled payments at or below
    -- the threshold never appear in the moderator's list while the
    -- toggle is on. A no-op when it is off (v_hide_at = -1).
    and not (p.status = 'settled' and p.amount_settled <= v_hide_at)
    and (
      p_search is null or p_search = ''
      or p.btcpay_invoice_id ilike '%' || p_search || '%'
      or p.lightning_invoice ilike '%' || p_search || '%'
      or pr.email ilike '%' || p_search || '%'
      or coalesce(pr.display_name, '') ilike '%' || p_search || '%'
      or coalesce(pl.slug, '') ilike '%' || p_search || '%'
    )
    and (v_status is null or p.status = v_status)
    and (v_start is null or p.created_at >= v_start)
  order by p.created_at desc
  limit v_limit
  offset v_offset;
end;
$$;

revoke all on function staff_list_payments(int, int, text, text, text) from public, anon;
grant execute on function staff_list_payments(int, int, text, text, text) to authenticated;


-- staff_global_stats() — real signature from 0031: takes p_start/p_end
-- (currently always called with null from moderator.html, but the
-- signature must match or CREATE OR REPLACE creates a second, unused
-- overload instead of replacing anything).
create or replace function staff_global_stats(
  p_start timestamptz default null,
  p_end   timestamptz default null
)
returns table (
  total_settled numeric,
  total_withdrawn numeric,
  pending_withdrawals_count bigint,
  pending_withdrawals_amount numeric,
  payment_count bigint,
  creator_count bigint
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_hide_at numeric := small_payment_threshold();
begin
  if not (is_admin() or is_moderator()) then
    raise exception 'Not authorized';
  end if;

  return query
  with mine as (
    select pr.id
    from profiles pr
    where pr.role = 'creator' and handles_creator(pr.id)
  ),
  pay as (
    select coalesce(sum(p.amount_settled), 0) as settled, count(*) as cnt
    from payments p
    join mine m on m.id = p.user_id
    where p.status = 'settled'
      and not (p.amount_settled <= v_hide_at)
      and (p_start is null or p.settled_at >= p_start)
      and (p_end   is null or p.settled_at <= p_end)
  ),
  wd as (
    select coalesce(sum(w.amount_after_fee) filter (where w.status = 'paid'), 0) as paid,
           count(*) filter (where w.status in ('pending','approved'))            as pend_cnt,
           coalesce(sum(w.amount_requested) filter (where w.status in ('pending','approved')), 0) as pend_amt
    from withdrawals w
    join mine m on m.id = w.user_id
  )
  select pay.settled, wd.paid, wd.pend_cnt, wd.pend_amt, pay.cnt,
         (select count(*) from mine)
  from pay, wd;
end;
$$;

revoke all on function staff_global_stats(timestamptz, timestamptz) from public, anon;
grant execute on function staff_global_stats(timestamptz, timestamptz) to authenticated;


-- staff_customer_totals() — real signature and columns from 0031: the
-- panel reads c.display_name / c.email / c.settled / c.payment_count /
-- c.withdrawn / c.pending directly, so every name below is load-bearing.
-- Only `settled` and `payment_count` are touched by the filter — pending,
-- expired and withdrawn are not settled-payment figures and are outside
-- what was asked for.
drop function if exists staff_customer_totals();

create or replace function staff_customer_totals()
returns table (
  creator_id uuid, email text, display_name text,
  settled numeric, pending numeric, expired numeric,
  withdrawn numeric, payment_count bigint
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_hide_at numeric := small_payment_threshold();
begin
  if not (is_admin() or is_moderator()) then
    raise exception 'Not authorized';
  end if;

  return query
  select
    pr.id, pr.email, pr.display_name,
    coalesce(sum(p.amount_settled) filter (
      where p.status = 'settled' and not (p.amount_settled <= v_hide_at)
    ), 0),
    coalesce(sum(p.amount_requested) filter (where p.status in ('new','pending')), 0),
    coalesce(sum(p.amount_requested) filter (where p.status in ('expired','invalid')), 0),
    coalesce((select sum(w.amount_after_fee) from withdrawals w
              where w.user_id = pr.id and w.status = 'paid'), 0),
    count(p.id) filter (
      where p.status = 'settled' and not (p.amount_settled <= v_hide_at)
    )
  from profiles pr
  left join payments p on p.user_id = pr.id
  where pr.role = 'creator' and handles_creator(pr.id)
  group by pr.id, pr.email, pr.display_name
  order by 4 desc;
end;
$$;

revoke all on function staff_customer_totals() from public, anon;
grant execute on function staff_customer_totals() to authenticated;
