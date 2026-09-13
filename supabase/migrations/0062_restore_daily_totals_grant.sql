-- ============================================================
-- Boltpay — 0062: restore daily_totals_for_cycle()'s grant
-- ============================================================
-- 0061 had to DROP daily_totals_for_cycle() to add total_admin_profit
-- (a return-type change). Its own comment correctly warned that DROP
-- removes every grant with the function — and then re-applied the WRONG
-- one:
--
--     grant execute on function daily_totals_for_cycle(date)
--       to service_role, authenticated;   -- 0061, wrong
--
-- Migration 0043, which created this function, had deliberately locked
-- it down, with the reason written directly above the line:
--
--     -- Only the cron reaches this, and it runs as the service role,
--     -- which bypasses grants entirely. Nothing signed in from a
--     -- browser has any reason to call it.
--     revoke all on function daily_totals_for_cycle(date)
--       from public, anon, authenticated;
--
-- 0061 undid that. It did not merely fail to tighten something — it
-- removed protection this project had already put in place on purpose.
--
-- Why it matters: this function is SECURITY DEFINER and contains no
-- authorization check at all. Not is_admin(), not auth.uid() — nothing.
-- It is a raw aggregate over every payment and every withdrawal on the
-- platform. Compare admin_daily_settled(), which opens with
-- `if not is_admin() then raise exception 'Not authorized'` and is
-- therefore safe to grant to authenticated; this has no such guard.
--
-- With the 0061 grant live, any signed-in account — an ordinary
-- freelancer, a reseller, anyone with a login — could run this from a
-- browser console:
--
--     await supabaseClient.rpc('daily_totals_for_cycle',
--                              { p_cycle_date: '2026-09-01' })
--
-- and read the platform's total settled revenue, payment count, total
-- withdrawn and total admin profit, for any date they chose.
--
-- Nothing legitimate breaks by removing it: the only two callers,
-- daily-report and reconcile, both use the service-role key, which
-- bypasses grants entirely. The `authenticated` grant was never needed
-- for anything — it came from habit, copying the shape of the many
-- other functions in this codebase that DO have an internal is_admin()
-- check and therefore do belong on that list.
--
-- Same reasoning, same shape, as get_balance_for(uuid) in 0018.
-- ============================================================

revoke all on function daily_totals_for_cycle(date) from public, anon, authenticated;
grant execute on function daily_totals_for_cycle(date) to service_role;


-- ============================================================
-- While here: make the two profit figures round identically
-- ------------------------------------------------------------
-- admin_daily_settled() rounds fee revenue to 4 decimal places;
-- admin_global_stats() does not round at all. Sub-cent, invisible in
-- practice, and not a bug — but the whole point of 0061 was that these
-- two figures come from one definition and cannot drift. Leaving one
-- rounded and one raw is a small hole in exactly that guarantee.
-- ============================================================
create or replace function admin_global_stats(
  p_start timestamptz default null,
  p_end   timestamptz default null
)
returns table (
  total_settled numeric, total_admin_profit numeric, total_withdrawn numeric,
  pending_withdrawals_count int, pending_withdrawals_amount numeric,
  payment_count bigint, active_creators bigint, calculated_node_balance numeric
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_total_settled numeric;
  v_margin numeric;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  select coalesce(sum(amount_settled), 0) into v_total_settled
  from payments
  where status = 'settled'
    and (p_start is null or settled_at >= p_start)
    and (p_end   is null or settled_at <= p_end);

  select coalesce((value->>'percent')::numeric, 7.7) into v_margin
  from app_settings where key = 'profit_margin_percent';

  return query
  select
    v_total_settled,
    -- Rounded to match admin_daily_settled() exactly.
    round(coalesce((
      select sum(w.amount_requested - w.amount_after_fee)
      from withdrawals w
      where w.status = 'paid'
        and (p_start is null or w.processed_at >= p_start)
        and (p_end   is null or w.processed_at <= p_end)
    ), 0), 4),
    coalesce((
      select sum(w.amount_after_fee) from withdrawals w
      where w.status = 'paid'
        and (p_start is null or w.processed_at >= p_start)
        and (p_end   is null or w.processed_at <= p_end)
    ), 0),
    (select count(*) from withdrawals w where w.status = 'pending')::int,
    coalesce((select sum(w.amount_requested) from withdrawals w where w.status = 'pending'), 0),
    (select count(*) from payments p
      where p.status = 'settled'
        and (p_start is null or p.settled_at >= p_start)
        and (p_end   is null or p.settled_at <= p_end)),
    (select count(distinct p.user_id) from payments p where p.status = 'settled'),
    round(v_total_settled * (1.0 + (v_margin / 100.0)), 4);
end;
$$;

revoke all on function admin_global_stats(timestamptz, timestamptz) from public, anon;
grant execute on function admin_global_stats(timestamptz, timestamptz) to authenticated;
