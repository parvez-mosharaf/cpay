-- ============================================================
-- CPAY — 0084: public creator store + richer analytics
-- ============================================================

-- Public storefront lookup. Only exposes intentionally public profile/link
-- fields; no email, balances, costs, internal ids or payment history.
drop function if exists get_public_store(uuid);
create or replace function get_public_store(p_user_id uuid)
returns table (
  display_name text,
  links jsonb
)
language sql
security definer
stable
set search_path = public
as $$
  select
    coalesce(pr.display_name, 'CPAY creator'),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug', l.slug,
        'display_name', coalesce(l.display_name, l.slug),
        'theme', coalesce(l.theme, 'keypad'),
        'og_image', l.og_image
      ) order by l.created_at desc)
      from payment_links l
      where l.user_id = p_user_id
        and l.is_active = true
        and l.deleted_at is null
    ), '[]'::jsonb)
  from profiles pr
  where pr.id = p_user_id
    and pr.role in ('creator','moderator');
$$;
revoke all on function get_public_store(uuid) from public;
grant execute on function get_public_store(uuid) to anon, authenticated;

-- 30-day daily performance + per-link performance. The function intentionally
-- returns only aggregate creator-owned data.
drop function if exists get_my_analytics();
create or replace function get_my_analytics()
returns table (
  day date,
  revenue numeric,
  payments bigint,
  link_slug text,
  link_revenue numeric,
  link_payments bigint
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_cutoff timestamptz := now() - interval '30 days';
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  return query
  with days as (
    select generate_series(current_date - 29, current_date, interval '1 day')::date as d
  ),
  daily as (
    select p.settled_at::date as d,
           coalesce(sum(p.amount_settled),0) as revenue,
           count(*) as payments
    from payments p
    where p.user_id = v_uid
      and p.status = 'settled'
      and p.settled_at >= v_cutoff
      and p.amount_settled >= small_payment_threshold()
    group by p.settled_at::date
  ),
  links as (
    select l.slug,
           coalesce(sum(p.amount_settled) filter (where p.status='settled' and p.amount_settled >= small_payment_threshold()),0) as link_revenue,
           count(*) filter (where p.status='settled' and p.amount_settled >= small_payment_threshold()) as link_payments
    from payment_links l
    left join payments p on p.payment_link_id = l.id and p.user_id = v_uid
    where l.user_id = v_uid and l.deleted_at is null
    group by l.slug
  )
  select d.d, coalesce(x.revenue,0), coalesce(x.payments,0), null::text, null::numeric, null::bigint
  from days d left join daily x on x.d=d.d
  union all
  select current_date, null::numeric, null::bigint, l.slug, l.link_revenue, l.link_payments
  from links l
  order by 1 desc, 4 nulls last;
end;
$$;
revoke all on function get_my_analytics() from public, anon;
grant execute on function get_my_analytics() to authenticated;
