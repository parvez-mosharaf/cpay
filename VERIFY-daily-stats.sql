-- ============================================================
-- Verify the daily_stats archive against the live ledger
-- ============================================================
-- Replaces the earlier version of this file, which bucketed by MIDNIGHT
-- Dhaka. Since migration 0043, daily_stats is written on the 5pm–5pm
-- Dhaka cycle — the same one the site displays — so the old query
-- reported "STALE" on every row even when nothing was wrong.
--
-- This uses daily_totals_for_cycle(), the single function that now
-- defines a day for the whole system, so what it checks against is by
-- construction the same thing daily-report wrote.
--
-- Note: daily_stats is no longer displayed anywhere. The admin Earnings
-- tab reads admin_daily_settled() live. This table is an archive, and
-- this query is how you confirm the archive is trustworthy.
-- ============================================================

with cycles as (
  select generate_series(
    ((now() at time zone 'Asia/Dhaka') - interval '17 hours')::date - 29,
    ((now() at time zone 'Asia/Dhaka') - interval '17 hours')::date,
    interval '1 day'
  )::date as cycle_date
),
expected as (
  select c.cycle_date, t.total_settled, t.payment_count
  from cycles c
  cross join lateral daily_totals_for_cycle(c.cycle_date) t
)
select
  e.cycle_date,
  round(e.total_settled, 2)                as should_be,
  round(coalesce(ds.total_settled, 0), 2)  as stored,
  e.payment_count                          as payments,
  case
    when ds.stat_date is null then 'row missing — run daily-report'
    when round(coalesce(ds.total_settled, 0), 2) = round(e.total_settled, 2) then 'ok'
    else 'STALE — re-run daily-report'
  end as verdict
from expected e
left join daily_stats ds on ds.stat_date = e.cycle_date
order by e.cycle_date desc;


-- ============================================================
-- If anything is not 'ok'
-- ============================================================
-- Backfill (replace <CRON_SECRET>):
--   curl -H "x-cron-secret: <CRON_SECRET>" \
--     "https://ohwzmxwsphsfzudmlins.supabase.co/functions/v1/daily-report?days=30"
--
-- Then re-run the query above. Every row should read 'ok'.
--
-- The newest row is the cycle currently in progress, so it reads low
-- until 5pm Dhaka passes. That is expected, not a fault.
