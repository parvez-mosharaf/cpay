-- ============================================================
-- CPAY — 0023: create_link_variants fix + per-shop API key
-- ============================================================


-- ============================================================
-- 1. "column reference slug is ambiguous"
-- ------------------------------------------------------------
-- create_link_variants declares `returns table (slug text, ...)`.
-- In plpgsql an OUT parameter is a variable in scope for the whole
-- body, so inside
--
--     select 1 from payment_links where slug = v_slug
--
-- the bare `slug` matches both the OUT parameter and the column, and
-- Postgres refuses to guess. It fails at runtime, not at creation,
-- which is why the function was created cleanly and only broke when a
-- creator pressed "Create link".
--
-- Fixed by qualifying every column reference, and by setting
-- #variable_conflict use_column so a future OUT parameter that
-- collides resolves to the column rather than erroring.
--
-- Also returns skipped variants instead of silently dropping them, so
-- the dashboard can say which shops a name was already taken on.
-- ============================================================
drop function if exists create_link_variants(text);

create or replace function create_link_variants(p_display_name text)
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

  for v_shop in
    select * from btcpay_shops where btcpay_shops.is_active = true
    order by btcpay_shops.sort_order, btcpay_shops.name
  loop
    v_slug := slug_from_name(v_name, v_shop.slug_style);
    if v_slug = '' then continue; end if;

    -- Taken, either by another creator or by a style this same name
    -- already produced. A single-word name collapses kebab and lower
    -- onto the same string, so this is a normal outcome, not an error.
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
    raise exception 'That name is already taken on every shop';
  end if;
end;
$$;

revoke all on function create_link_variants(text) from public, anon;
grant execute on function create_link_variants(text) to authenticated;


-- ============================================================
-- 2. Each shop gets its own BTCPay API key
-- ------------------------------------------------------------
-- The key is NOT stored here. This column holds the *name* of the
-- Edge Function secret to read it from, so the keys stay in Supabase's
-- encrypted secret store and never sit in the database, in a backup,
-- or in a ledger export.
--
-- Add one secret per shop and name it here:
--   BTCPAY_API_KEY     (shop 1, the one you already have)
--   BTCPAY_API_KEY_2   (shop 2)
--   BTCPAY_API_KEY_3   (shop 3)
--   BTCPAY_API_KEY_4   (shop 4)
--
-- The CHECK matters: without it an admin could point a shop at
-- SUPABASE_SERVICE_ROLE_KEY and the function would happily send it to
-- BTCPay as a bearer token.
-- ============================================================
alter table btcpay_shops add column if not exists api_key_env text not null default 'BTCPAY_API_KEY';

alter table btcpay_shops drop constraint if exists btcpay_shops_api_key_env_check;
alter table btcpay_shops add constraint btcpay_shops_api_key_env_check
  check (api_key_env ~ '^BTCPAY_API_KEY(_[2-9])?$');

-- Creators must never see which secret a shop uses. The column grant is
-- re-issued in full because adding a column does not extend it.
revoke select on btcpay_shops from authenticated, anon;
grant select (id, name, surcharge_percent, slug_style, is_active, is_default, sort_order)
  on btcpay_shops to authenticated;


-- ============================================================
-- 3. Payments remember the store AND the key that issued them
-- ------------------------------------------------------------
-- The webhook reads a settled invoice back from BTCPay to confirm the
-- amount. With per-shop keys it needs the same key that created the
-- invoice, and it must still work if the shop row is later edited or
-- disabled — so the context is copied onto the payment, not looked up.
-- ============================================================
alter table payments add column if not exists btcpay_api_key_env text;


-- ============================================================
-- 4. system_link_for_invoice hands create-invoice the key name
-- ============================================================
drop function if exists system_link_for_invoice(text);

create or replace function system_link_for_invoice(p_slug text)
returns table (
  link_id uuid,
  user_id uuid,
  slug text,
  display_name text,
  is_active boolean,
  store_id text,
  api_key_env text,
  surcharge_percent numeric
)
language sql
security definer
stable
set search_path = public
as $$
  select pl.id, pl.user_id, pl.slug, pl.display_name, pl.is_active,
         s.store_id, s.api_key_env, coalesce(s.surcharge_percent, 0)
  from payment_links pl
  left join btcpay_shops s on s.id = pl.shop_id and s.is_active = true
  where pl.slug = p_slug
  limit 1;
$$;

revoke all on function system_link_for_invoice(text) from public, anon, authenticated;
grant execute on function system_link_for_invoice(text) to service_role;


-- ============================================================
-- 5. admin_list_shops / admin_upsert_shop carry api_key_env
-- ============================================================
drop function if exists admin_list_shops();

create or replace function admin_list_shops()
returns table (
  id uuid, name text, store_id text, api_key_env text,
  surcharge_percent numeric, slug_style text,
  is_active boolean, is_default boolean, sort_order int,
  link_count bigint
)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select s.id, s.name, s.store_id, s.api_key_env, s.surcharge_percent,
         s.slug_style, s.is_active, s.is_default, s.sort_order,
         (select count(*) from payment_links pl where pl.shop_id = s.id)
  from btcpay_shops s
  order by s.sort_order, s.name;
end; $$;

drop function if exists admin_upsert_shop(uuid, text, text, numeric, text, boolean, boolean, int);

create or replace function admin_upsert_shop(
  p_id uuid,
  p_name text,
  p_store_id text,
  p_surcharge_percent numeric,
  p_slug_style text,
  p_api_key_env text default 'BTCPAY_API_KEY',
  p_is_active boolean default true,
  p_is_default boolean default false,
  p_sort_order int default 0
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  if p_name is null or trim(p_name) = '' then
    raise exception 'Shop name is required';
  end if;
  if p_store_id is null or trim(p_store_id) = '' then
    raise exception 'BTCPay store ID is required';
  end if;
  if p_slug_style not in ('kebab','pascal','lower','title-kebab') then
    raise exception 'Unknown link style';
  end if;
  if p_surcharge_percent is null or p_surcharge_percent < 0 or p_surcharge_percent > 100 then
    raise exception 'Rate must be between 0 and 100';
  end if;
  if coalesce(p_api_key_env, '') !~ '^BTCPAY_API_KEY(_[2-9])?$' then
    raise exception 'API key secret must be named BTCPAY_API_KEY or BTCPAY_API_KEY_2 through _9';
  end if;

  if p_id is null then
    insert into btcpay_shops (name, store_id, api_key_env, surcharge_percent,
                              slug_style, is_active, is_default, sort_order)
    values (trim(p_name), trim(p_store_id), p_api_key_env, p_surcharge_percent,
            p_slug_style, coalesce(p_is_active, true), coalesce(p_is_default, false),
            coalesce(p_sort_order, 0))
    returning id into v_id;
  else
    update btcpay_shops
       set name = trim(p_name),
           store_id = trim(p_store_id),
           api_key_env = p_api_key_env,
           surcharge_percent = p_surcharge_percent,
           slug_style = p_slug_style,
           is_active = coalesce(p_is_active, true),
           is_default = coalesce(p_is_default, false),
           sort_order = coalesce(p_sort_order, 0)
     where id = p_id
    returning id into v_id;
    if v_id is null then raise exception 'Shop not found'; end if;
  end if;

  if coalesce(p_is_default, false) then
    update btcpay_shops set is_default = false where id <> v_id;
  end if;

  return v_id;
end; $$;

revoke all on function admin_list_shops() from public, anon;
revoke all on function admin_upsert_shop(uuid, text, text, numeric, text, text, boolean, boolean, int) from public, anon;
grant execute on function admin_list_shops() to authenticated;
grant execute on function admin_upsert_shop(uuid, text, text, numeric, text, text, boolean, boolean, int) to authenticated;
