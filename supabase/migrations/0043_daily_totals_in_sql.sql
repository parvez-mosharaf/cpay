-- ============================================================
-- Boltpay — 0043: One definition of "a day", computed in SQL
-- ============================================================
-- Two problems in daily-report, both of the same kind: the arithmetic
-- was being done in JavaScript over rows fetched from PostgREST.
--
-- 1. The 1000-row cap. `.select("amount_settled")` with no .range()
--    returns at most 1000 rows, and the function then summed whatever
--    it got. Any day with more than 1000 settled payments was silently
--    under-reported, with nothing to indicate it. Same bug as the
--    ledger backup, same cause.
--
-- 2. Two different days. daily-report bucketed by MIDNIGHT Dhaka, while
--    admin_daily_settled(), staff_daily_settled() and my_daily_settled()
--    all bucket by 5pm–5pm Dhaka. The archive and the screen therefore
--    disagreed about which payments belonged to which day — and because
--    nothing displays daily_stats any more, nobody would have noticed
--    until an audit compared them.
--
-- Both go away by moving the work into SQL. The database sums whole
-- tables without a row limit, and it does it from the same cycle
-- boundary the live views already use, so there is now exactly one
-- definition of a day in the system.
--
-- The half-open interval matters too: the old code used
-- `lte(day_end)` with day_end = 23:59:59.999, which drops anything
-- settling in the final millisecond. `>= start and < end` cannot.
-- ============================================================

create or replace function daily_totals_for_cycle(p_cycle_date date)
returns table (
  cycle_start timestamptz,
  cycle_end timestamptz,
  total_settled numeric,
  payment_count bigint,
  total_withdrawn numeric
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
    ), 0)
  from b;
$$;

-- Only the cron reaches this, and it runs as the service role, which
-- bypasses grants entirely. Nothing signed in from a browser has any
-- reason to call it.
revoke all on function daily_totals_for_cycle(date) from public, anon, authenticated;


-- The withdrawal half of the query filters on (status, processed_at);
-- nothing indexed that pair, so each day's rollup scanned the table.
create index if not exists idx_withdrawals_status_processed
  on withdrawals(status, processed_at)
  where status = 'paid';
