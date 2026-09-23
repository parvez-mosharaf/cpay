-- ============================================================
-- CPAY — 0053: Fix the threshold boundary, and exclude small
-- settled payments from withdrawable balance too
-- ============================================================
-- Two corrections to 0051/0052's "hide small settled payments"
-- feature, both from the owner after seeing it in use:
--
-- 1. BOUNDARY: 0051 hid anything AT OR BELOW the threshold ($10.00
--    itself included). The intent was always "strictly under $10" —
--    $10.00 exactly should count as a real payment. Every place that
--    compared `amount_settled <= v_hide_at` now compares
--    `amount_settled < v_hide_at`. The seven functions below are the
--    exact bodies 0051 shipped, with only that one operator changed —
--    nothing else about them is touched, so their signatures cannot
--    have drifted from what is already live.
--
-- 2. WITHDRAWABLE BALANCE: 0051 deliberately left get_balance_for()
--    untouched, reasoning that a display filter should never reduce
--    money a creator can actually withdraw. The owner's correction:
--    payments this small are not real creator earnings in the first
--    place — they are what a card-testing or probing client sends to
--    check a payment method works before attempting something larger
--    elsewhere. That money should never have been withdrawable to
--    begin with, so it is excluded from `earned` (and therefore from
--    `available`) the same way it is excluded from everything else.
--
--    get_balance_for() is the single source both request_withdrawal()
--    and system_queue_withdrawal() already read `available` from, so
--    this one change is enough to make both the manual and the
--    instant-auto-payout paths correctly stop offering this money —
--    neither of those two functions needs to change at all.
--
--    Still gated by the same hide_small_payments_enabled toggle as
--    everything else — turning that off restores the old behaviour
--    everywhere, balance included.
-- ============================================================

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
      and not (p.status = 'settled' and p.amount_settled < v_hide_at)
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
        where p.status = 'settled' and not (p.amount_settled < v_hide_at)
      ) as settled_count,
      count(*) filter (where p.status in ('new', 'pending')) as pending_count
    from payments p
    where p.user_id = v_uid
  ) c;
end;
$$;

revoke all on function get_my_totals() from public, anon;
grant execute on function get_my_totals() to authenticated;


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
   and not (p.amount_settled < v_hide_at)
   and p.settled_at >= b.cycle_start
   and p.settled_at <  b.cycle_end
  group by b.cycle_date, b.cycle_start, b.cycle_end
  order by b.cycle_date desc;
end;
$$;

revoke all on function my_daily_settled(int) from public, anon;
grant execute on function my_daily_settled(int) to authenticated;


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
    and not (p.status = 'settled' and p.amount_settled < v_hide_at)
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
      and not (p.amount_settled < v_hide_at)
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
      where p.status = 'settled' and not (p.amount_settled < v_hide_at)
    ), 0),
    coalesce(sum(p.amount_requested) filter (where p.status in ('new','pending')), 0),
    coalesce(sum(p.amount_requested) filter (where p.status in ('expired','invalid')), 0),
    coalesce((select sum(w.amount_after_fee) from withdrawals w
              where w.user_id = pr.id and w.status = 'paid'), 0),
    count(p.id) filter (
      where p.status = 'settled' and not (p.amount_settled < v_hide_at)
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
   and not (p.amount_settled < v_hide_at)
   and p.settled_at >= b.cycle_start
   and p.settled_at <  b.cycle_end
  group by m.id, m.display_name, m.email, b.cycle_date, b.cycle_start, b.cycle_end
  order by b.cycle_date desc, m.display_name;
end;
$$;

revoke all on function staff_daily_settled(int) from public, anon;
grant execute on function staff_daily_settled(int) to authenticated;


-- ============================================================
-- get_balance_for() — same signature as always. request_withdrawal()
-- and system_queue_withdrawal() both read `available` from this, so
-- withdrawal eligibility now correctly excludes small settled
-- payments too, without either of those functions changing.
-- ============================================================
create or replace function get_balance_for(p_user_id uuid)
returns table (earned numeric, queued numeric, withdrawn numeric, available numeric)
language sql
security definer
stable
set search_path = public
as $$
  select
    e.earned,
    q.queued,
    w.withdrawn,
    round(e.earned - q.queued, 8) as available
  from
    (select coalesce(sum(amount_settled), 0) as earned
     from payments
     where user_id = p_user_id and status = 'settled'
       -- Strictly under the threshold, matching every other filter in
       -- this feature. A no-op when the toggle is off: threshold is -1
       -- and amount_settled is never negative.
       and amount_settled >= small_payment_threshold())
    e,
    (select coalesce(sum(amount_requested), 0) as queued
     from withdrawals where user_id = p_user_id and status <> 'rejected') q,
    (select coalesce(sum(amount_after_fee), 0) as withdrawn
     from withdrawals where user_id = p_user_id and status = 'paid') w;
$$;
