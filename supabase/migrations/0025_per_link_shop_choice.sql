-- ============================================================
-- Boltpay — 0025: Choose a shop per link
-- ============================================================
-- Until now, creating a link named "Taylor James" made one link on
-- EVERY active shop. That is right when you want the same name offered
-- at several rates, and wrong when you want Taylor James on one shop
-- and Sophia on another.
--
-- create_link_variants now takes an optional shop. Pass one and you get
-- a single link on that shop; pass nothing and you get the old
-- behaviour, one link per active shop. Nothing that exists changes.
--
-- This is why no `$sophia` slug style was needed. A `$` prefix would
-- have had to be threaded through five separate validators (the trigger,
-- create-invoice, og-image, 404.html and the worker's looksLikeSlug
-- check), and `$` is a URL sub-delimiter that some clients percent-encode
-- to %24 — a link that works when tapped and 404s when retyped is worse
-- than no feature. Picking the shop directly gets there without touching
-- the slug alphabet at all.
-- ============================================================


-- ============================================================
-- 1. create_link_variants(name, shop)
-- ------------------------------------------------------------
-- The old single-argument version has to go: leaving it in place would
-- give PostgREST two overloads with the same name and it would refuse
-- the call as ambiguous.
-- ============================================================
drop function if exists create_link_variants(text);

create or replace function create_link_variants(
  p_display_name text,
  p_shop_id uuid default null
)
returns table (slug text, shop_name text, surcharge_percent numeric, created boolean)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_group uuid := gen_random_uuid();
  v_shop btcpay_shops;
  v_slug text;
  v_name text;
  v_any boolean := false;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  v_name := trim(coalesce(p_display_name, ''));
  if v_name = '' then raise exception 'Please enter a name for the link'; end if;
  if length(v_name) > 60 then raise exception 'Name is too long'; end if;

  if slug_from_name(v_name, 'kebab') = '' then
    raise exception 'Name must contain letters or numbers';
  end if;

  -- A creator may only pick a shop that is actually open for business.
  -- Without this check the id could name a disabled shop, and every
  -- invoice on the resulting link would fail at create-invoice with a
  -- 503 that points at nothing obvious.
  if p_shop_id is not null
     and not exists (select 1 from btcpay_shops s
                     where s.id = p_shop_id and s.is_active = true) then
    raise exception 'That rate is not available';
  end if;

  for v_shop in
    select * from btcpay_shops
    where btcpay_shops.is_active = true
      and (p_shop_id is null or btcpay_shops.id = p_shop_id)
    order by btcpay_shops.sort_order, btcpay_shops.name
  loop
    v_slug := slug_from_name(v_name, v_shop.slug_style);
    if v_slug = '' then continue; end if;

    -- Taken, either by another creator or by a style this same name
    -- already produced. A single-word name collapses kebab and lower onto
    -- the same string, so this is a normal outcome, not an error.
    if exists (select 1 from payment_links pl where pl.slug = v_slug) then
      return query select v_slug, v_shop.name, v_shop.surcharge_percent, false;
      continue;
    end if;

    insert into payment_links (user_id, slug, display_name, shop_id, variant_group, is_active)
    values (v_uid, v_slug, v_name, v_shop.id, v_group, true);

    v_any := true;
    return query select v_slug, v_shop.name, v_shop.surcharge_percent, true;
  end loop;

  if not v_any then
    if p_shop_id is not null then
      raise exception 'That name is already taken on this rate';
    end if;
    raise exception 'That name is already taken on every rate';
  end if;
end;
$$;

revoke all on function create_link_variants(text, uuid) from public, anon;
grant execute on function create_link_variants(text, uuid) to authenticated;


-- ============================================================
-- 2. Move an existing link to a different shop
-- ------------------------------------------------------------
-- The slug is deliberately left alone. It may already be in a bio, a
-- printed card or a chat thread, and silently repointing it at a
-- different rate is one thing — silently changing the URL is another.
-- The rate on new invoices changes; invoices already issued keep the
-- store they were created on, because payments.btcpay_store_id records
-- it per payment.
-- ============================================================
create or replace function admin_set_link_shop(p_link_id uuid, p_shop_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  if not exists (select 1 from payment_links pl where pl.id = p_link_id) then
    raise exception 'Link not found';
  end if;

  if p_shop_id is not null
     and not exists (select 1 from btcpay_shops s where s.id = p_shop_id) then
    raise exception 'Shop not found';
  end if;

  update payment_links set shop_id = p_shop_id where id = p_link_id;
end;
$$;

revoke all on function admin_set_link_shop(uuid, uuid) from public, anon;
grant execute on function admin_set_link_shop(uuid, uuid) to authenticated;


-- ============================================================
-- 3. The admin Links tab needs to see which shop a link is on
-- ============================================================
drop function if exists admin_list_payment_links();

create or replace function admin_list_payment_links()
returns table (
  id uuid, slug text, display_name text, is_active boolean, created_at timestamptz,
  owner_email text, owner_name text, total_earned numeric, payment_count bigint,
  shop_id uuid, shop_name text, surcharge_percent numeric
)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pl.id, pl.slug, pl.display_name, pl.is_active, pl.created_at,
    pr.email, pr.display_name,
    coalesce((select sum(p.amount_settled) from payments p
              where p.payment_link_id = pl.id and p.status = 'settled'), 0),
    coalesce((select count(*) from payments p
              where p.payment_link_id = pl.id and p.status = 'settled'), 0),
    pl.shop_id, s.name, s.surcharge_percent
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  left join btcpay_shops s on s.id = pl.shop_id
  order by pl.created_at desc;
end; $$;

revoke all on function admin_list_payment_links() from public, anon;
grant execute on function admin_list_payment_links() to authenticated;

-- Applied 2026-09-01, project ohwzmxwsphsfzudmlins. Owner request (msg 3462545/3462917).
-- Logged-in creator/moderator/admin must all see BOTH shops (rates are per-shop, encoded in name).
-- Root cause: policy "shops creator read" (is_active = true) was dead — role `authenticated`
-- had no SELECT grant on public.btcpay_shops.
--
-- Column-level SELECT only. store_id + api_key_env are BTCPay secrets and stay ungranted;
-- admin.html reads those through the admin_list_shops() SECURITY DEFINER RPC instead.
grant select (id, name, surcharge_percent, is_active, is_default, sort_order, created_at)
  on public.btcpay_shops to authenticated;
