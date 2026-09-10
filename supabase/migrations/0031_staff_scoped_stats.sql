-- ============================================================
-- Boltpay — 0031: Stats scoped to a moderator's creators
-- ============================================================
-- A moderator assigned five creators should see the same picture an
-- admin sees, only narrowed to those five: settled totals, pending
-- payouts, withdrawn, payment counts.
--
-- admin_global_stats() cannot be reused for that — it aggregates the
-- whole platform, and a moderator must never see the platform total or
-- the admin profit figure. This is the same shape minus the profit and
-- node-balance columns, restricted by handles_creator().
--
-- An admin calling it gets every creator, so the moderator panel and
-- the admin panel can share one function.
-- ============================================================

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


-- ============================================================
-- Per-creator totals, for the moderator's customer list
-- ------------------------------------------------------------
-- staff_customer_directory() from 0029 already returns these scoped the
-- same way. This only adds the settled/pending split the moderator
-- panel shows per creator card.
-- ============================================================
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
begin
  if not (is_admin() or is_moderator()) then
    raise exception 'Not authorized';
  end if;

  return query
  select
    pr.id, pr.email, pr.display_name,
    coalesce(sum(p.amount_settled) filter (where p.status = 'settled'), 0),
    coalesce(sum(p.amount_requested) filter (where p.status in ('new','pending')), 0),
    coalesce(sum(p.amount_requested) filter (where p.status in ('expired','invalid')), 0),
    coalesce((select sum(w.amount_after_fee) from withdrawals w
              where w.user_id = pr.id and w.status = 'paid'), 0),
    count(p.id) filter (where p.status = 'settled')
  from profiles pr
  left join payments p on p.user_id = pr.id
  where pr.role = 'creator' and handles_creator(pr.id)
  group by pr.id, pr.email, pr.display_name
  order by 4 desc;
end;
$$;

revoke all on function staff_customer_totals() from public, anon;
grant execute on function staff_customer_totals() to authenticated;
