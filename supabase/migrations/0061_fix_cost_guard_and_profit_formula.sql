-- ============================================================
-- CPAY — 0061: two defects introduced by 0059, both mine
-- ============================================================
-- An external review found both. Each was verified against this repo's
-- own code and history before being accepted — and in both cases the
-- proof was already sitting in the repo.
-- ============================================================


-- ============================================================
-- 1. Creators could not actually set their own cost_percent
-- ------------------------------------------------------------
-- 0059 added cost_percent to guard_profile_updates()'s blocked list,
-- with a comment claiming set_my_cost_percent() "bypasses this trigger
-- legitimately" because it is SECURITY DEFINER. That is wrong, and
-- this repo already knew it: migration 0019's own comment explains
-- that auth.uid() is null only when a SERVICE-ROLE JWT is used,
-- because such a token has no `sub` claim.
--
-- SECURITY DEFINER changes the effective role for permission checks.
-- It does not touch `request.jwt.claims` — the transaction-scoped GUC
-- that auth.uid() reads. So inside set_my_cost_percent(), called from
-- a creator's own browser session, auth.uid() is that creator's id and
-- is_admin() is false. The trigger fired on every single save:
--
--     "You may only change your display name and wallet details"
--
-- The whole self-service pricing feature was dead on arrival. Only
-- admin_set_cost_percent() worked, because is_admin() short-circuits
-- the guard for admins.
--
-- The fix is to stop guarding the column at all, which is the correct
-- classification anyway. The guard exists for values a user must not
-- set for themselves: their own fee, their own link allowance, their
-- own role. cost_percent is the opposite — it is theirs to choose, the
-- same category as the wallet_* columns that 0059 deliberately left
-- out of this list for exactly that reason.
--
-- Nothing is lost by removing it. The only remaining bound on
-- cost_percent is the typo guard, and 0060 moved that into a table
-- CHECK constraint (0–1000), which applies to every write path
-- including a direct PostgREST update. The admin ceiling this guard
-- was originally protecting no longer exists — 0060 deleted it.
-- ============================================================
create or replace function guard_profile_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or is_admin() then
    return new;
  end if;
  if new.id                     is distinct from old.id
  or new.email                  is distinct from old.email
  or new.role                   is distinct from old.role
  or new.withdrawal_fee_percent is distinct from old.withdrawal_fee_percent
  or new.max_payment_links      is distinct from old.max_payment_links
  or new.auto_withdraw_enabled  is distinct from old.auto_withdraw_enabled
  or new.buy_rate               is distinct from old.buy_rate
  or new.sell_rate              is distinct from old.sell_rate
  or new.shop_locked            is distinct from old.shop_locked
  or new.forced_shop_id         is distinct from old.forced_shop_id
  then
    raise exception 'You may only change your display name and wallet details';
  end if;
  return new;
end;
$$;


-- ============================================================
-- 2. The two admin profit figures disagreed
-- ------------------------------------------------------------
-- 0059 changed admin_global_stats() to report real fee revenue —
-- sum(amount_requested - amount_after_fee) over paid withdrawals —
-- but left admin_daily_settled() on the old volume-derived estimate,
-- `settled * margin / 2`.
--
-- admin_daily_settled()'s own comment said "Identical formula to
-- admin_global_stats(), so this list and the header stat card never
-- drift apart." 0059 broke exactly the promise that comment was making:
-- the Earnings list and the header card would show different profit for
-- the same period, with no indication which to believe.
--
-- Fee revenue is attributed to the cycle the withdrawal was PAID in,
-- not the cycle the underlying payments settled in. Those are different
-- days, and paid-at is the right one: that is when the platform
-- actually took the money.
-- ============================================================
create or replace function admin_daily_settled(p_days int default 14)
returns table (
  cycle_date date,
  cycle_start timestamptz,
  cycle_end timestamptz,
  settled numeric,
  payment_count bigint,
  admin_profit numeric
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_days int := least(greatest(coalesce(p_days, 14), 1), 60);
  v_cur_cycle date;
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;

  -- Same 17-hour shift as staff_daily_settled(): the Dhaka calendar date
  -- on which the 5pm cycle containing "now" began.
  v_cur_cycle := ((now() at time zone 'Asia/Dhaka') - interval '17 hours')::date;

  return query
  with days as (
    select gs::date as d
    from generate_series(v_cur_cycle - (v_days - 1), v_cur_cycle, interval '1 day') as gs
  ),
  bounds as (
    select
      d.d as cycle_date,
      (d.d::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' as cycle_start,
      (d.d::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' + interval '24 hours' as cycle_end
    from days d
  ),
  settled_per_cycle as (
    select
      b.cycle_date, b.cycle_start, b.cycle_end,
      coalesce(sum(p.amount_settled), 0) as settled,
      count(p.id) as payment_count
    from bounds b
    left join payments p
      on p.status = 'settled'
     and p.settled_at >= b.cycle_start
     and p.settled_at <  b.cycle_end
    group by b.cycle_date, b.cycle_start, b.cycle_end
  ),
  -- Real fee revenue, matching admin_global_stats() exactly. Attributed
  -- by processed_at — when the payout actually went out — rather than by
  -- when the underlying payments settled.
  profit_per_cycle as (
    select
      b.cycle_date,
      coalesce(sum(w.amount_requested - w.amount_after_fee), 0) as admin_profit
    from bounds b
    left join withdrawals w
      on w.status = 'paid'
     and w.processed_at >= b.cycle_start
     and w.processed_at <  b.cycle_end
    group by b.cycle_date
  )
  select
    s.cycle_date, s.cycle_start, s.cycle_end,
    s.settled, s.payment_count,
    round(pr.admin_profit, 4)
  from settled_per_cycle s
  join profit_per_cycle pr on pr.cycle_date = s.cycle_date
  order by s.cycle_date desc;
end;
$$;

revoke all on function admin_daily_settled(int) from public, anon;
grant execute on function admin_daily_settled(int) to authenticated;


-- ============================================================
-- 3. The same stale formula lived in daily-report too
-- ------------------------------------------------------------
-- daily-report computes `totalSettled * marginPercent / 100 / 2` in
-- TypeScript and writes it to daily_stats.total_admin_profit. That is
-- a THIRD copy of the formula 0059 replaced in admin_global_stats() and
-- section 2 above replaced in admin_daily_settled().
--
-- Rather than fix the arithmetic in TypeScript — where it would drift
-- again the next time the definition changes — the number is added to
-- daily_totals_for_cycle(), the function daily-report already calls for
-- everything else in that row. One definition, one place.
--
-- Return type changes, so this needs an explicit DROP first. A plain
-- CREATE OR REPLACE against a different column list fails with 42P13
-- and, because Supabase runs a migration in one transaction, would roll
-- back everything above it.
-- ============================================================
drop function if exists daily_totals_for_cycle(date);

create or replace function daily_totals_for_cycle(p_cycle_date date)
returns table (
  cycle_start timestamptz,
  cycle_end timestamptz,
  total_settled numeric,
  payment_count bigint,
  total_withdrawn numeric,
  total_admin_profit numeric
)
language sql
security definer
stable
set search_path = public
as $$
  with b as (
    select
      (p_cycle_date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' as cycle_start,
      (p_cycle_date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka'
        + interval '24 hours' as cycle_end
  )
  select
    b.cycle_start,
    b.cycle_end,
    coalesce((
      select sum(p.amount_settled) from payments p
      where p.status = 'settled'
        and p.settled_at >= b.cycle_start
        and p.settled_at <  b.cycle_end
    ), 0),
    coalesce((
      select count(*) from payments p
      where p.status = 'settled'
        and p.settled_at >= b.cycle_start
        and p.settled_at <  b.cycle_end
    ), 0),
    coalesce((
      select sum(w.amount_after_fee) from withdrawals w
      where w.status = 'paid'
        and w.processed_at >= b.cycle_start
        and w.processed_at <  b.cycle_end
    ), 0),
    -- Real fee revenue for this cycle, identical in definition to
    -- admin_global_stats() and admin_daily_settled().
    coalesce((
      select sum(w.amount_requested - w.amount_after_fee) from withdrawals w
      where w.status = 'paid'
        and w.processed_at >= b.cycle_start
        and w.processed_at <  b.cycle_end
    ), 0)
  from b;
$$;

-- DROP removes every grant with the function. daily-report calls this
-- through the service-role key; without this the daily rollup would
-- start failing silently every night.
revoke all on function daily_totals_for_cycle(date) from public, anon;
grant execute on function daily_totals_for_cycle(date) to service_role, authenticated;
