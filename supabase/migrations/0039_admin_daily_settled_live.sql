-- ============================================================
-- Boltpay — 0039: Admin daily settled + profit, live (5pm–5pm Dhaka)
-- ============================================================
-- The admin Earnings tab's "Daily settled balance history" used to
-- read from `daily_stats`, a table populated once a day by the
-- daily-report cron on a MIDNIGHT-to-midnight Dhaka boundary. That
-- gave two ways for the number on screen to be wrong at once: the
-- cron has to have actually run (a missed run left a day at $0.00,
-- which is exactly the bug that was reported and chased down
-- earlier), and even when it ran, its day boundary did not match the
-- 5pm-to-5pm cadence this project has used everywhere else — the
-- original daily-report cron, and now staff_daily_settled() (0040).
--
-- This does the same thing that fixed the moderator panel: compute
-- live, on every call, straight from `payments`. Nothing is stored,
-- nothing needs a cron, nothing can go stale. It differs from
-- staff_daily_settled() in two ways that matter for the admin view
-- specifically:
--   * one row per day across the WHOLE platform, not per creator —
--     admin's UI wants a single daily total, not a per-creator list
--   * includes admin_profit, computed with the exact formula
--     admin_global_stats() already uses, so the header stat and the
--     daily history can never quietly disagree again
--
-- ledger-backup and the daily-report cron are UNCHANGED by this — the
-- GitHub snapshot and the daily_stats table both keep working exactly
-- as before, for anything else that still reads them. This migration
-- only gives the admin panel's live view a better source to read from.
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
  v_margin numeric;
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;

  select coalesce((value->>'percent')::numeric, 7.7)
    into v_margin
  from app_settings where key = 'profit_margin_percent';

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
  )
  select
    b.cycle_date, b.cycle_start, b.cycle_end,
    coalesce(sum(p.amount_settled), 0) as settled,
    count(p.id) as payment_count,
    -- Identical formula to admin_global_stats(), so this list and the
    -- header stat card never drift apart.
    round((coalesce(sum(p.amount_settled), 0) * (v_margin / 100.0)) / 2.0, 4) as admin_profit
  from bounds b
  left join payments p
    on p.status = 'settled'
   and p.settled_at >= b.cycle_start
   and p.settled_at <  b.cycle_end
  group by b.cycle_date, b.cycle_start, b.cycle_end
  order by b.cycle_date desc;
end;
$$;

revoke all on function admin_daily_settled(int) from public, anon, authenticated;
grant execute on function admin_daily_settled(int) to authenticated;
