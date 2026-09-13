-- ============================================================
-- Boltpay — 0054: Creator insights, and alerts respect the hide toggle
-- ============================================================

-- ============================================================
-- 1. get_my_insights() — 7-day / 30-day revenue and conversion rate
-- ------------------------------------------------------------
-- New tab, new figures. Filtered by the exact same
-- small_payment_threshold() every other creator-facing figure already
-- respects (0051/0053), for one reason: a creator's own dashboard must
-- never disagree with itself. "Total earned" on Overview and "30-day
-- revenue" on Insights have to describe the same underlying set of
-- payments, or the difference reads as a bug.
--
-- Conversion rate excludes a hidden payment from BOTH sides of the
-- ratio, not just the numerator — a probe/test payment that is invisible
-- everywhere else on the dashboard should not silently drag the
-- creator's conversion rate down as an uncounted "failure" either. As
-- far as this metric is concerned, while the toggle is on, it never
-- existed.
-- ============================================================
create or replace function get_my_insights()
returns table (
  revenue_7d numeric,
  revenue_30d numeric,
  total_invoices bigint,
  paid_invoices bigint
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
    coalesce(sum(p.amount_settled) filter (
      where p.status = 'settled' and p.amount_settled >= v_hide_at
        and p.settled_at >= now() - interval '7 days'
    ), 0),
    coalesce(sum(p.amount_settled) filter (
      where p.status = 'settled' and p.amount_settled >= v_hide_at
        and p.settled_at >= now() - interval '30 days'
    ), 0),
    count(*) filter (
      where not (p.status = 'settled' and p.amount_settled < v_hide_at)
    ),
    count(*) filter (
      where p.status = 'settled' and p.amount_settled >= v_hide_at
    )
  from payments p
  where p.user_id = v_uid;
end;
$$;

revoke all on function get_my_insights() from public, anon;
grant execute on function get_my_insights() to authenticated;


-- ============================================================
-- 2. A read-only check the Edge Functions can call before alerting
-- ------------------------------------------------------------
-- "hide small settled payments" was built as a display filter for
-- creator/moderator UI, driven entirely by SQL. Telegram/Discord alerts
-- are sent from TypeScript, outside any of that — so without this,
-- turning the toggle on would still leave a Telegram channel announcing
-- exactly the payments the toggle exists to hide. This gives the
-- webhook a single, cheap thing to ask before it announces a payment:
-- "is this one small enough that the toggle should suppress it?"
-- ============================================================
create or replace function should_suppress_payment_alert(p_amount numeric)
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(p_amount, 0) < small_payment_threshold();
$$;

-- Called from the webhook using the service-role key, which bypasses
-- grants entirely — this grant is for any authenticated-context caller
-- that might want the same check later, not a requirement for the
-- webhook itself to work.
revoke all on function should_suppress_payment_alert(numeric) from public, anon;
grant execute on function should_suppress_payment_alert(numeric) to authenticated;
