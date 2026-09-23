-- ============================================================
-- CPAY — 0022: Multiple BTCPay shops, one rate each
-- ============================================================
-- One BTCPay server, several stores. Each store carries its own rate
-- spread (BTCPay: Store → Rates → "Add a percentage on top"), so the
-- same $100 invoice costs the payer $100, $102, $103 or $104
-- depending on which store issued it.
--
-- BTCPay applies that spread itself. CPAY never changes the
-- amount: it sends $100 USD to the chosen store and BTCPay converts
-- at its own marked-up rate. So the creator is still credited $100,
-- and surcharge_percent here exists purely so the panel and the
-- payment page can *show* what the payer will be charged. Keeping it
-- in sync with BTCPay is a manual step — nothing here can read it
-- back off the server.
-- ============================================================


-- ============================================================
-- 1. Case-sensitive slugs
-- ------------------------------------------------------------
-- Four variants of one name have to be four distinct slugs, and the
-- only thing separating TaylorJames from taylorjames is case. 0018's
-- validate_link_slug() lowercased every slug on the way in, which
-- would have collapsed all four into one and thrown a unique
-- violation on the second.
--
-- Worth knowing what this costs: URL paths are case-sensitive, but
-- people are not. Someone typing a link off a screenshot, or an app
-- that lowercases pasted URLs, lands on the wrong variant — or on a
-- 404. If that turns out to bite, give the shops distinct suffixes
-- (taylor-james-a / -b) instead of relying on capitalisation.
-- ============================================================
create or replace function validate_link_slug()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.slug := trim(new.slug);

  if new.slug !~ '^[A-Za-z0-9][A-Za-z0-9-]{2,48}[A-Za-z0-9]$' then
    raise exception 'Link name must be 4-50 characters: letters, numbers and hyphens only';
  end if;

  -- Reserved names are matched case-insensitively: /Admin must be
  -- blocked just as firmly as /admin.
  if lower(new.slug) in (
    'index','login','register','dashboard','admin','404','config','theme',
    'assets','favicon','invoice-cpay-v2','api','u','static','public',
    'well-known','robots','sitemap'
  ) then
    raise exception 'That link name is reserved';
  end if;

  return new;
end;
$$;


-- ============================================================
-- 2. btcpay_shops
-- ============================================================
create table if not exists btcpay_shops (
  id uuid primary key default uuid_generate_v4(),
  name text not null,
  store_id text not null,
  surcharge_percent numeric(6,3) not null default 0,
  slug_style text not null default 'kebab',
  is_active boolean not null default true,
  is_default boolean not null default false,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

alter table btcpay_shops drop constraint if exists btcpay_shops_style_check;
alter table btcpay_shops add constraint btcpay_shops_style_check
  check (slug_style in ('kebab', 'pascal', 'lower', 'title-kebab'));

alter table btcpay_shops drop constraint if exists btcpay_shops_surcharge_check;
alter table btcpay_shops add constraint btcpay_shops_surcharge_check
  check (surcharge_percent >= 0 and surcharge_percent <= 100);

-- One style per shop, or two shops would generate the same slug for
-- the same creator and the second insert would fail on the unique
-- index with a confusing message.
create unique index if not exists idx_btcpay_shops_style on btcpay_shops(slug_style);

alter table btcpay_shops enable row level security;

drop policy if exists "shops admin write" on btcpay_shops;
create policy "shops admin write"
on btcpay_shops for all
using (is_admin())
with check (is_admin());

-- Creators need the name, style and rate to render their links.
-- store_id is NOT in this policy's reach — see the column grant below.
drop policy if exists "shops creator read" on btcpay_shops;
create policy "shops creator read"
on btcpay_shops for select
to authenticated
using (is_active = true);

-- store_id identifies a real BTCPay store and has no business in a
-- creator's browser. Column-level grants keep it server-side.
revoke select on btcpay_shops from authenticated, anon;
grant select (id, name, surcharge_percent, slug_style, is_active, is_default, sort_order)
  on btcpay_shops to authenticated;


-- ============================================================
-- 3. Links know their shop; payments remember which store issued them
-- ------------------------------------------------------------
-- payments.btcpay_store_id matters because the webhook has to read
-- the invoice back from the same store that created it. Without it,
-- a settled invoice on shop 2 would be looked up on shop 1, come
-- back 404, and fall through to the requested amount.
-- ============================================================
alter table payment_links add column if not exists shop_id uuid references btcpay_shops(id);
alter table payment_links add column if not exists variant_group uuid;
alter table payments add column if not exists btcpay_store_id text;

create index if not exists idx_payment_links_shop on payment_links(shop_id);
create index if not exists idx_payment_links_variant on payment_links(variant_group);


-- ============================================================
-- 4. Slug styles
-- ============================================================
create or replace function slug_from_name(p_name text, p_style text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v_words text[];
  v_clean text;
begin
  -- Strip everything that is not a letter, digit or separator, then
  -- split into words. Non-Latin display names reduce to nothing here,
  -- which the caller has to handle.
  v_clean := regexp_replace(coalesce(p_name, ''), '[^A-Za-z0-9]+', ' ', 'g');
  v_clean := trim(v_clean);
  if v_clean = '' then return ''; end if;

  v_words := regexp_split_to_array(v_clean, '\s+');

  return case p_style
    when 'kebab'       then lower(array_to_string(v_words, '-'))
    when 'lower'       then lower(array_to_string(v_words, ''))
    when 'pascal'      then array_to_string(
                             array(select initcap(lower(w)) from unnest(v_words) w), '')
    when 'title-kebab' then array_to_string(
                             array(select initcap(lower(w)) from unnest(v_words) w), '-')
    else lower(array_to_string(v_words, '-'))
  end;
end;
$$;


-- ============================================================
-- 5. The link limit counts variant groups, not rows
-- ------------------------------------------------------------
-- One name across four shops is four payment_links rows but one link
-- as far as the creator is concerned. Counting rows would let a
-- creator with a limit of 5 make exactly one link.
-- ============================================================
create or replace function enforce_link_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit int;
  v_current int;
begin
  if coalesce(new.is_active, true) = false then
    return new;
  end if;

  if tg_op = 'UPDATE' and coalesce(old.is_active, true) = true then
    return new;
  end if;

  if is_admin() then
    return new;
  end if;

  select coalesce(max_payment_links, 5) into v_limit
  from profiles where id = new.user_id;

  select count(distinct coalesce(variant_group, id)) into v_current
  from payment_links
  where user_id = new.user_id
    and is_active = true
    and coalesce(variant_group, id) is distinct from coalesce(new.variant_group, new.id);

  if v_current >= v_limit then
    raise exception 'Limit reached: you can have at most % active links', v_limit;
  end if;

  return new;
end;
$$;

revoke all on function enforce_link_limit() from anon, authenticated;


-- ============================================================
-- 6. Creating a link creates one variant per active shop
-- ============================================================
create or replace function create_link_variants(p_display_name text)
returns table (slug text, shop_name text, surcharge_percent numeric)
language plpgsql
security definer
set search_path = public
as $$
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
    select * from btcpay_shops where is_active = true order by sort_order, name
  loop
    v_slug := slug_from_name(v_name, v_shop.slug_style);
    if v_slug = '' then continue; end if;

    -- Skip a variant whose slug is already taken rather than failing
    -- the whole call: the creator still gets the shops that are free,
    -- and the response tells them which ones they got.
    if exists (select 1 from payment_links where slug = v_slug) then
      continue;
    end if;

    insert into payment_links (user_id, slug, display_name, shop_id, variant_group, is_active)
    values (v_uid, v_slug, v_name, v_shop.id, v_group, true);

    v_any := true;
    return query select v_slug, v_shop.name, v_shop.surcharge_percent;
  end loop;

  if not v_any then
    raise exception 'That name is already taken on every shop';
  end if;
end;
$$;

revoke all on function create_link_variants(text) from public, anon;
grant execute on function create_link_variants(text) to authenticated;


-- ============================================================
-- 7. The payment page needs to show what the payer will be charged
-- ============================================================
-- Same 42P13 problem as in 0021: two more columns means a new row type,
-- so the 0021 version has to be dropped before this one can be created.
drop function if exists get_link_preview(text);

create or replace function get_link_preview(p_slug text)
returns table (
  display_name text,
  is_active boolean,
  og_image text,
  shop_name text,
  surcharge_percent numeric
)
language sql
security definer
stable
set search_path = public
as $$
  -- Exact match, no lower(). Case is what separates the variants.
  select pl.display_name, pl.is_active, pl.og_image,
         s.name, coalesce(s.surcharge_percent, 0)
  from payment_links pl
  left join btcpay_shops s on s.id = pl.shop_id
  where pl.slug = p_slug
  limit 1;
$$;

revoke all on function get_link_preview(text) from public;
grant execute on function get_link_preview(text) to anon, authenticated;


-- ============================================================
-- 8. Server-side lookup for create-invoice
-- ------------------------------------------------------------
-- Returns store_id, which no client role can read off the table.
-- ============================================================
create or replace function system_link_for_invoice(p_slug text)
returns table (
  link_id uuid,
  user_id uuid,
  slug text,
  display_name text,
  is_active boolean,
  store_id text,
  surcharge_percent numeric
)
language sql
security definer
stable
set search_path = public
as $$
  select pl.id, pl.user_id, pl.slug, pl.display_name, pl.is_active,
         s.store_id, coalesce(s.surcharge_percent, 0)
  from payment_links pl
  left join btcpay_shops s on s.id = pl.shop_id and s.is_active = true
  where pl.slug = p_slug
  limit 1;
$$;

revoke all on function system_link_for_invoice(text) from public, anon, authenticated;
grant execute on function system_link_for_invoice(text) to service_role;


-- ============================================================
-- 9. Admin shop management
-- ============================================================
create or replace function admin_list_shops()
returns table (
  id uuid, name text, store_id text, surcharge_percent numeric,
  slug_style text, is_active boolean, is_default boolean, sort_order int,
  link_count bigint
)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select s.id, s.name, s.store_id, s.surcharge_percent, s.slug_style,
         s.is_active, s.is_default, s.sort_order,
         (select count(*) from payment_links pl where pl.shop_id = s.id)
  from btcpay_shops s
  order by s.sort_order, s.name;
end; $$;

create or replace function admin_upsert_shop(
  p_id uuid,
  p_name text,
  p_store_id text,
  p_surcharge_percent numeric,
  p_slug_style text,
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

  if p_id is null then
    insert into btcpay_shops (name, store_id, surcharge_percent, slug_style,
                              is_active, is_default, sort_order)
    values (trim(p_name), trim(p_store_id), p_surcharge_percent, p_slug_style,
            coalesce(p_is_active, true), coalesce(p_is_default, false),
            coalesce(p_sort_order, 0))
    returning id into v_id;
  else
    update btcpay_shops
       set name = trim(p_name),
           store_id = trim(p_store_id),
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

create or replace function admin_delete_shop(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  -- Links pointing at this shop would lose their store and every new
  -- invoice on them would fail. Deactivate instead of deleting.
  if exists (select 1 from payment_links where shop_id = p_id) then
    raise exception 'This shop still has payment links. Disable it instead of deleting.';
  end if;

  delete from btcpay_shops where id = p_id;
end; $$;

revoke all on function admin_list_shops() from public, anon;
revoke all on function admin_upsert_shop(uuid, text, text, numeric, text, boolean, boolean, int) from public, anon;
revoke all on function admin_delete_shop(uuid) from public, anon;
grant execute on function admin_list_shops() to authenticated;
grant execute on function admin_upsert_shop(uuid, text, text, numeric, text, boolean, boolean, int) to authenticated;
grant execute on function admin_delete_shop(uuid) to authenticated;


-- ============================================================
-- 10. Seed the existing store so nothing breaks on deploy
-- ------------------------------------------------------------
-- Every link that exists today was created against BTCPAY_STORE_ID
-- with no markup. Put a 0% shop in and attach them to it, so the
-- first invoice after this migration still finds a store.
--
-- Replace 'REPLACE_WITH_YOUR_BTCPAY_STORE_ID' before running, or fix
-- it afterwards in the admin panel.
-- ============================================================
insert into btcpay_shops (name, store_id, surcharge_percent, slug_style, is_default, sort_order)
select 'Happy Shop', 'Ez5UXumquwG2arh1U6vchz7eMhpca4SPM9gP4nUV7CMo', 0, 'lower', true, 0
where not exists (select 1 from btcpay_shops);

update payment_links
   set shop_id = (select id from btcpay_shops where is_default order by sort_order limit 1)
 where shop_id is null;
