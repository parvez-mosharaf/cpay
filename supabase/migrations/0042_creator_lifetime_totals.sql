-- ============================================================
-- CPAY — 0042: Server-side lifetime totals for a creator
-- ============================================================
-- The dashboard was deriving "Total earned", the settled-payment count,
-- the pending count and the tier badge by summing `allPayments` in the
-- browser. That array comes from a plain .select() on payments, which
-- PostgREST caps at 1000 rows — so every one of those figures silently
-- stopped being true once a creator passed 1000 payments.
--
-- It is already happening: beauty-girl has 2213 payments, so their
-- dashboard has been showing a total built from only the most recent
-- 1000 of them. The withdrawable balance was never affected, because
-- that already came from get_my_balance() rather than the array.
--
-- This is the same fix, extended to every figure on the card: the
-- database does the counting, and the browser only ever renders what it
-- is handed. An array that may or may not be complete can no longer
-- produce a number a creator reads as fact.
--
-- get_my_balance() is deliberately left alone rather than widened. Its
-- return type is part of a working contract, and changing the shape of
-- an existing function is what caused the 42P13 failure earlier in this
-- project. A new function costs nothing and breaks nothing.
-- ============================================================

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
      count(*) filter (where p.status = 'settled')                  as settled_count,
      count(*) filter (where p.status in ('new', 'pending'))        as pending_count
    from payments p
    where p.user_id = v_uid
  ) c;
end;
$$;

revoke all on function get_my_totals() from public, anon;
grant execute on function get_my_totals() to authenticated;

-- No index needed here: the counts filter on (user_id, status), which
-- idx_payments_user_status from 0018 already covers.
