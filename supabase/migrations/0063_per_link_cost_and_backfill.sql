-- ============================================================
-- CPAY — 0063: per-link cost, and a backfill that preserves
-- every existing link's current price
-- ============================================================
-- 0059 put cost_percent on the PROFILE. That was a design mistake, and
-- it would have been a silent, money-affecting one on an existing
-- deployment.
--
-- How pricing works TODAY, before this migration:
--   payment_links.shop_id  ->  btcpay_shops.surcharge_percent
-- Each link points at a shop; each shop is a separate BTCPay store with
-- its own rate spread. Two links owned by the same person can therefore
-- charge different markups by pointing at different shops — one at 10%,
-- another at 0%. That is real, in use, and per-LINK.
--
-- 0059's profiles.cost_percent is per-USER. Every link one person owns
-- gets the same markup, with no way to express "this link 10%, that one
-- 0%". Deploying it as-is would have flattened an existing pricing
-- structure without anyone being told.
--
-- This migration:
--   1. adds payment_links.cost_percent (nullable — null means "use the
--      owner's default"), so both levels exist
--   2. BACKFILLS it from each link's current shop surcharge, so every
--      existing link keeps charging exactly what it charges today
--
-- Step 2 is the important one. Once the BTCPay store spread goes to 0%
-- (which the new model requires — see docs/SETUP-REFERENCE.md §1.1),
-- a link that was quietly relying on a 10% store spread would start
-- charging 10% less. The backfill moves that 10% from the store into
-- the link itself, so the payer is charged the same amount before and
-- after. Nothing about what a customer pays changes on deploy day.
-- ============================================================

alter table payment_links add column if not exists cost_percent numeric(6,3);

alter table payment_links drop constraint if exists payment_links_cost_percent_range;
alter table payment_links add constraint payment_links_cost_percent_range
  check (cost_percent is null or (cost_percent >= 0 and cost_percent <= 1000));

comment on column payment_links.cost_percent is
  'Markup for this specific link. NULL means fall back to the owner''s profiles.cost_percent. Backfilled in 0063 from the link''s shop surcharge so existing prices survived the move to a single 0%-spread store.';


-- ============================================================
-- The backfill
-- ------------------------------------------------------------
-- Only touches links that currently resolve to a non-zero shop
-- surcharge. A link already on a 0% shop, or on no shop at all, is left
-- NULL and simply inherits its owner's default — which is 0 unless they
-- set one, so it too keeps charging exactly what it charges today.
--
-- Deliberately not `where cost_percent is null` alone: this runs once,
-- on a column that did not exist a moment ago, so every row is null.
-- Written to be re-runnable anyway — a second run finds nothing to do.
-- ============================================================
update payment_links pl
   set cost_percent = s.surcharge_percent
  from btcpay_shops s
 where s.id = pl.shop_id
   and pl.cost_percent is null
   and s.surcharge_percent > 0;


-- ============================================================
-- Resolution order, in one place
-- ------------------------------------------------------------
-- link.cost_percent  ->  owner's profiles.cost_percent  ->  0
--
-- COALESCE handles this exactly: a link-level value wins, null falls
-- through to the profile, and a profile with none falls through to 0.
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
  surcharge_percent numeric,
  cost_percent numeric
)
language sql
security definer
stable
set search_path = public
as $$
  select pl.id, pl.user_id, pl.slug, pl.display_name, pl.is_active,
         s.store_id, s.api_key_env, coalesce(s.surcharge_percent, 0),
         coalesce(pl.cost_percent, pr.cost_percent, 0)
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  left join btcpay_shops s on s.id = pl.shop_id and s.is_active = true
  where pl.slug = p_slug and pl.deleted_at is null
  limit 1;
$$;

-- DROP removes every grant. create-invoice calls this through the
-- service-role key; without this line every payment attempt would fail.
-- (0062 exists because exactly this was got wrong once already.)
revoke all on function system_link_for_invoice(text) from public, anon, authenticated;
grant execute on function system_link_for_invoice(text) to service_role;


-- Same resolution for the public payment page's display lookup.
drop function if exists link_cost_for_slug(text);

create or replace function link_cost_for_slug(p_slug text)
returns table (cost_percent numeric, shop_surcharge_percent numeric)
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(pl.cost_percent, pr.cost_percent, 0),
         coalesce(s.surcharge_percent, 0)
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  left join btcpay_shops s on s.id = pl.shop_id
  where pl.slug = p_slug and pl.deleted_at is null
  limit 1;
$$;

revoke all on function link_cost_for_slug(text) from public;
grant execute on function link_cost_for_slug(text) to anon, authenticated;


-- ============================================================
-- Setting a link's own cost
-- ------------------------------------------------------------
-- Owner-scoped, with the same typo guard as everywhere else. Passing
-- null clears the override and returns the link to the owner's default,
-- which is why p_percent is nullable here.
-- ============================================================
create or replace function set_link_cost_percent(p_link_id uuid, p_percent numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select user_id into v_owner from payment_links
   where id = p_link_id and deleted_at is null;
  if v_owner is null then raise exception 'Link not found'; end if;
  if v_owner <> v_uid and not is_admin() then
    raise exception 'Not authorized';
  end if;

  if p_percent is not null and (p_percent < 0 or p_percent > 1000) then
    raise exception 'Cost must be between 0 and 1000';
  end if;

  update payment_links
     set cost_percent = case when p_percent is null then null else round(p_percent, 3) end
   where id = p_link_id;

  return p_percent;
end;
$$;

revoke all on function set_link_cost_percent(uuid, numeric) from public, anon;
grant execute on function set_link_cost_percent(uuid, numeric) to authenticated;


-- The admin links list shows the effective rate and whether it is a
-- link-level override or inherited, so a mixed setup is readable at a
-- glance rather than needing a query to understand.
-- Two new columns, so the return type changes and this needs a DROP —
-- CREATE OR REPLACE against a different column list fails with 42P13
-- and would roll back this entire migration, backfill included.
drop function if exists admin_list_payment_links();

create or replace function admin_list_payment_links()
returns table (
  id uuid, slug text, display_name text, is_active boolean, created_at timestamptz,
  owner_email text, owner_name text, total_earned numeric, payment_count bigint,
  shop_id uuid, shop_name text, surcharge_percent numeric,
  cost_percent numeric, cost_is_override boolean
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
    pl.shop_id, s.name, s.surcharge_percent,
    coalesce(pl.cost_percent, pr.cost_percent, 0),
    pl.cost_percent is not null
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  left join btcpay_shops s on s.id = pl.shop_id
  where pl.deleted_at is null
  order by pl.created_at desc;
end; $$;

revoke all on function admin_list_payment_links() from public, anon;
grant execute on function admin_list_payment_links() to authenticated;
