-- ============================================================
-- Boltpay — 0046: Paginated payment lists
-- ============================================================
-- The last place the 1000-row cap still bites.
--
-- C2 fixed the creator's TOTALS by moving the arithmetic into SQL, but
-- the list itself is still a plain .select() on payments — so a creator
-- past 1000 payments can see their correct lifetime total and then
-- scroll a list that silently stops. Their oldest payments are simply
-- not reachable from the UI.
--
-- staff_list_payments (0038) already solved this shape for the moderator
-- panel. This adds the same thing for the two lists that still lack it:
--
--   get_my_payments()      the creator's own feed, scoped to auth.uid()
--   admin_list_payments()  gains p_offset, so the admin panel can page
--
-- Both return a total_count alongside the rows, so the UI can say
-- "showing 120 of 2213" and know when to stop offering "Load more"
-- rather than guessing from a short page.
-- ============================================================


-- ============================================================
-- 1. The creator's own paginated feed
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
    -- The count runs over the same filtered set, so it always describes
    -- the list the caller is actually paging through — not the whole
    -- table, which would make "showing 60 of 2213" a lie under a filter.
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


-- ============================================================
-- 2. admin_list_payments gains an offset
-- ------------------------------------------------------------
-- Dropped first: adding a parameter and a return column both change the
-- signature, and CREATE OR REPLACE cannot do that. Skipping the drop is
-- what produced the 42P13 failure earlier in this project.
-- ============================================================
drop function if exists admin_list_payments(int, text);
drop function if exists admin_list_payments(int, int, text);

create or replace function admin_list_payments(
  p_limit int default 100,
  p_offset int default 0,
  p_search text default null
)
returns table (
  id uuid, amount_requested numeric, amount_settled numeric, status text, method text,
  created_at timestamptz, settled_at timestamptz, expires_at timestamptz,
  customer_city text, customer_country text,
  creator_id uuid, creator_email text, creator_name text,
  link_slug text, shop_name text, surcharge_percent numeric,
  btcpay_invoice_id text, lightning_invoice text,
  marked_at timestamptz, marked_by_name text, mark_note text,
  total_count bigint
)
language plpgsql security definer set search_path = public as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not (is_admin() or is_moderator()) then raise exception 'Not authorized'; end if;

  return query
  with filtered as (
    select p.*
    from payments p
    join profiles pr on pr.id = p.user_id
    left join payment_links pl on pl.id = p.payment_link_id
    where (is_admin() or handles_creator(p.user_id))
      and (
        v_search is null
        or p.btcpay_invoice_id ilike '%' || v_search || '%'
        or p.lightning_invoice ilike '%' || v_search || '%'
        or pr.email ilike '%' || v_search || '%'
        or pl.slug ilike '%' || v_search || '%'
      )
  )
  select
    f.id, f.amount_requested, f.amount_settled, f.status, f.method,
    f.created_at, f.settled_at, f.expires_at,
    f.customer_city, f.customer_country,
    f.user_id, pr.email, pr.display_name,
    pl.slug, s.name, s.surcharge_percent,
    f.btcpay_invoice_id, f.lightning_invoice,
    f.marked_at, mb.display_name, f.mark_note,
    count(*) over () as total_count
  from filtered f
  join profiles pr on pr.id = f.user_id
  left join payment_links pl on pl.id = f.payment_link_id
  left join btcpay_shops s on s.id = pl.shop_id
  left join profiles mb on mb.id = f.marked_by
  order by f.created_at desc
  limit v_limit offset v_offset;
end; $$;

revoke all on function admin_list_payments(int, int, text) from public, anon;
grant execute on function admin_list_payments(int, int, text) to authenticated;
