-- ============================================================
-- CPAY — 0026: The link style belongs to the LINK
-- ============================================================
-- The model was backwards. A shop owned one slug style, so creating a
-- name produced one link per shop and the creator had no say in how any
-- of them looked.
--
-- It is the other way round:
--   * a shop is a BTCPay store and a cost, nothing more
--   * the slug style is picked by the creator, per link
--   * which shop a link runs on can be changed at any time, the way a
--     domain is chosen
--
-- The creator types a name and only a name. The display name is
-- title-cased for them ("sophia" -> "Sophia"), and the styles are then
-- offered as they actually come out.
-- ============================================================


-- ============================================================
-- 1. Shops stop owning a style
-- ------------------------------------------------------------
-- The unique index in particular has to go: it allowed at most four
-- shops in the whole system, one per style, which is not a limit
-- anybody asked for.
-- ============================================================
drop index if exists idx_btcpay_shops_style;
alter table btcpay_shops drop constraint if exists btcpay_shops_style_check;

-- Record the style on the link instead, so the dashboard can show what
-- each one is without re-deriving it from the slug.
alter table payment_links add column if not exists slug_style text;

alter table payment_links drop constraint if exists payment_links_slug_style_check;
alter table payment_links add constraint payment_links_slug_style_check
  check (slug_style is null or slug_style in ('kebab','pascal','lower','title-kebab'))
  not valid;


-- ============================================================
-- 2. Title-casing
-- ------------------------------------------------------------
-- One implementation, used by both the option list and the insert, so
-- the name previewed in the picker is exactly the name that gets saved.
-- ============================================================
create or replace function title_case_name(p_name text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v_clean text;
begin
  v_clean := regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g');
  v_clean := trim(v_clean);
  if v_clean = '' then return ''; end if;

  -- initcap() alone would lowercase the rest of every word, which is
  -- right here: the creator types free text and the display name is
  -- meant to look like a name.
  return initcap(v_clean);
end;
$$;


-- ============================================================
-- 3. What styles are actually available for a name
-- ------------------------------------------------------------
-- A single-word name gives two distinct slugs, not four: "sophia" and
-- "Sophia". kebab and lower both collapse to "sophia" with no space to
-- hyphenate, and pascal and title-kebab both to "Sophia". Returning the
-- collapsed duplicates would show the creator four options where two of
-- them build the same link.
--
-- `taken` is returned rather than filtered out, so the picker can grey
-- an option out and say why instead of silently offering fewer.
-- ============================================================
create or replace function link_style_options(p_name text)
returns table (style text, slug text, taken boolean)
language plpgsql
security definer
stable
set search_path = public
as $$
#variable_conflict use_column
declare
  v_name text;
  v_style text;
  v_slug text;
  v_seen text[] := '{}';
begin
  v_name := title_case_name(p_name);
  if v_name = '' then return; end if;
  if slug_from_name(v_name, 'kebab') = '' then return; end if;

  foreach v_style in array array['lower','kebab','title-kebab','pascal'] loop
    v_slug := slug_from_name(v_name, v_style);
    if v_slug = '' or v_slug = any(v_seen) then continue; end if;
    v_seen := v_seen || v_slug;

    return query select
      v_style,
      v_slug,
      exists (select 1 from payment_links pl where pl.slug = v_slug);
  end loop;
end;
$$;

revoke all on function link_style_options(text) from public, anon;
grant execute on function link_style_options(text) to authenticated;


-- ============================================================
-- 4. Creating links: the creator picks the styles and the shop
-- ------------------------------------------------------------
-- The two-argument version from 0025 has to go, or PostgREST sees two
-- overloads of one name and refuses the call as ambiguous.
-- ============================================================
drop function if exists create_link_variants(text, uuid);

create or replace function create_link_variants(
  p_display_name text,
  p_styles text[],
  p_shop_id uuid default null
)
returns table (slug text, style text, shop_name text, surcharge_percent numeric, created boolean)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_uid uuid := auth.uid();
  v_group uuid := gen_random_uuid();
  v_shop btcpay_shops;
  v_name text;
  v_style text;
  v_slug text;
  v_seen text[] := '{}';
  v_any boolean := false;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  v_name := title_case_name(p_display_name);
  if v_name = '' then raise exception 'Please enter a name for the link'; end if;
  if length(v_name) > 60 then raise exception 'Name is too long'; end if;
  if slug_from_name(v_name, 'kebab') = '' then
    raise exception 'Name must contain letters or numbers';
  end if;

  if p_styles is null or array_length(p_styles, 1) is null then
    raise exception 'Pick at least one link style';
  end if;

  -- Resolve the shop first. A link with no shop cannot issue an invoice,
  -- so falling back to the default beats creating something broken.
  if p_shop_id is not null then
    select * into v_shop from btcpay_shops s
     where s.id = p_shop_id and s.is_active = true;
    if not found then raise exception 'That cost option is not available'; end if;
  else
    select * into v_shop from btcpay_shops s
     where s.is_active = true
     order by s.is_default desc, s.sort_order, s.name
     limit 1;
    if not found then raise exception 'No payment shop is configured yet'; end if;
  end if;

  foreach v_style in array p_styles loop
    if v_style not in ('kebab','pascal','lower','title-kebab') then
      raise exception 'Unknown link style: %', v_style;
    end if;

    v_slug := slug_from_name(v_name, v_style);
    if v_slug = '' then continue; end if;

    -- Two chosen styles can collapse onto one slug for a single-word
    -- name. Skip the duplicate rather than failing the whole call.
    if v_slug = any(v_seen) then continue; end if;
    v_seen := v_seen || v_slug;

    if exists (select 1 from payment_links pl where pl.slug = v_slug) then
      return query select v_slug, v_style, v_shop.name, v_shop.surcharge_percent, false;
      continue;
    end if;

    insert into payment_links (user_id, slug, display_name, slug_style,
                               shop_id, variant_group, is_active)
    values (v_uid, v_slug, v_name, v_style, v_shop.id, v_group, true);

    v_any := true;
    return query select v_slug, v_style, v_shop.name, v_shop.surcharge_percent, true;
  end loop;

  if not v_any then
    raise exception 'Those links already exist';
  end if;
end;
$$;

revoke all on function create_link_variants(text, text[], uuid) from public, anon;
grant execute on function create_link_variants(text, text[], uuid) to authenticated;


-- ============================================================
-- 5. Creators switch a link's shop themselves
-- ------------------------------------------------------------
-- Same idea as choosing a domain: the link stays where it is, only the
-- cost the payer sees changes, and only on invoices created from now on.
-- Invoices already issued keep their own store, because
-- payments.btcpay_store_id is recorded per payment.
--
-- Goes through a function rather than a direct UPDATE so the shop is
-- checked for existence and for being active. A link pointed at a
-- disabled shop fails at create-invoice with a 503 that explains
-- nothing to the customer.
-- ============================================================
create or replace function set_link_shop(p_link_id uuid, p_shop_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  if not exists (select 1 from payment_links pl
                 where pl.id = p_link_id and pl.user_id = v_uid) then
    raise exception 'Link not found';
  end if;

  if not exists (select 1 from btcpay_shops s
                 where s.id = p_shop_id and s.is_active = true) then
    raise exception 'That cost option is not available';
  end if;

  update payment_links set shop_id = p_shop_id where id = p_link_id;
end;
$$;

revoke all on function set_link_shop(uuid, uuid) from public, anon;
grant execute on function set_link_shop(uuid, uuid) to authenticated;


-- ============================================================
-- 6. Admin shop management, without the style
-- ============================================================
drop function if exists admin_list_shops();

create or replace function admin_list_shops()
returns table (
  id uuid, name text, store_id text, api_key_env text,
  surcharge_percent numeric, is_active boolean, is_default boolean,
  sort_order int, link_count bigint
)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select s.id, s.name, s.store_id, s.api_key_env, s.surcharge_percent,
         s.is_active, s.is_default, s.sort_order,
         (select count(*) from payment_links pl where pl.shop_id = s.id)
  from btcpay_shops s
  order by s.sort_order, s.name;
end; $$;

drop function if exists admin_upsert_shop(uuid, text, text, numeric, text, text, boolean, boolean, int);

create or replace function admin_upsert_shop(
  p_id uuid,
  p_name text,
  p_store_id text,
  p_surcharge_percent numeric,
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
  if p_surcharge_percent is null or p_surcharge_percent < 0 or p_surcharge_percent > 100 then
    raise exception 'Rate must be between 0 and 100';
  end if;
  if coalesce(p_api_key_env, '') !~ '^BTCPAY_API_KEY(_[2-9])?$' then
    raise exception 'API key secret must be named BTCPAY_API_KEY or BTCPAY_API_KEY_2 through _9';
  end if;

  if p_id is null then
    insert into btcpay_shops (name, store_id, api_key_env, surcharge_percent,
                              is_active, is_default, sort_order)
    values (trim(p_name), trim(p_store_id), p_api_key_env, p_surcharge_percent,
            coalesce(p_is_active, true), coalesce(p_is_default, false),
            coalesce(p_sort_order, 0))
    returning id into v_id;
  else
    update btcpay_shops
       set name = trim(p_name), store_id = trim(p_store_id),
           api_key_env = p_api_key_env, surcharge_percent = p_surcharge_percent,
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
revoke all on function admin_upsert_shop(uuid, text, text, numeric, text, boolean, boolean, int) from public, anon;
grant execute on function admin_list_shops() to authenticated;
grant execute on function admin_upsert_shop(uuid, text, text, numeric, text, boolean, boolean, int) to authenticated;

-- slug_style is dead once the functions above no longer reference it.
alter table btcpay_shops drop column if exists slug_style;


-- ============================================================
-- 7. The live payments card shows what the payer was charged
-- ============================================================
drop function if exists admin_list_payments(int, text);

create or replace function admin_list_payments(
  p_limit int default 100,
  p_search text default null
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
  creator_email text,
  creator_name text,
  link_slug text,
  shop_name text,
  surcharge_percent numeric,
  btcpay_invoice_id text,
  lightning_invoice text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  return query
  select p.id, p.amount_requested, p.amount_settled, p.status, p.method,
    p.created_at, p.settled_at, p.expires_at,
    p.customer_city, p.customer_country,
    pr.email, pr.display_name, pl.slug,
    s.name, s.surcharge_percent,
    p.btcpay_invoice_id, p.lightning_invoice
  from payments p
  join profiles pr on pr.id = p.user_id
  left join payment_links pl on pl.id = p.payment_link_id
  left join btcpay_shops s on s.id = pl.shop_id
  where
    p_search is null or p_search = ''
    or p.btcpay_invoice_id ilike '%' || p_search || '%'
    or p.lightning_invoice ilike '%' || p_search || '%'
    or pr.email ilike '%' || p_search || '%'
    or pl.slug ilike '%' || p_search || '%'
  order by p.created_at desc
  limit p_limit;
end;
$$;

revoke all on function admin_list_payments(int, text) from public, anon;
grant execute on function admin_list_payments(int, text) to authenticated;


-- ============================================================
-- 8. Backfill
-- ------------------------------------------------------------
-- Existing links predate slug_style. Work it out from the slug itself so
-- the dashboard can label them, and attach anything orphaned to the
-- default shop rather than leaving it unable to issue invoices.
-- ============================================================
update payment_links
   set slug_style = case
     when slug ~ '^[a-z0-9]+$'            then 'lower'
     when slug ~ '^[a-z0-9-]+$'           then 'kebab'
     when slug ~ '-'                      then 'title-kebab'
     else 'pascal'
   end
 where slug_style is null;

update payment_links
   set shop_id = (select id from btcpay_shops
                  where is_active order by is_default desc, sort_order limit 1)
 where shop_id is null;
