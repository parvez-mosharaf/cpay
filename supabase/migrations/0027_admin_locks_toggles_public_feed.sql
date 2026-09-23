-- ============================================================
-- CPAY — 0027: Admin locks, global toggles, public feed
-- ============================================================


-- ============================================================
-- 1. An admin can pin a creator to one shop
-- ------------------------------------------------------------
-- shop_locked freezes the cost: every link that creator owns moves to
-- forced_shop_id, new links are created there, and set_link_shop stops
-- accepting anything else. The dashboard hides the selector too, but
-- that is only cosmetic — the rule lives here, so a creator posting
-- straight to PostgREST is refused the same way.
-- ============================================================
alter table profiles add column if not exists shop_locked boolean not null default false;
alter table profiles add column if not exists forced_shop_id uuid references btcpay_shops(id);

create or replace function admin_lock_creator_shop(
  p_creator_id uuid,
  p_locked boolean,
  p_shop_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  if p_locked then
    if p_shop_id is null then
      raise exception 'Pick the shop to lock this creator to';
    end if;
    if not exists (select 1 from btcpay_shops s where s.id = p_shop_id and s.is_active) then
      raise exception 'That shop is not active';
    end if;

    update profiles
       set shop_locked = true, forced_shop_id = p_shop_id
     where id = p_creator_id;

    -- Move what they already have. Leaving old links on another cost
    -- would make "locked" mean nothing for every link created before it.
    update payment_links
       set shop_id = p_shop_id
     where user_id = p_creator_id;
  else
    update profiles
       set shop_locked = false, forced_shop_id = null
     where id = p_creator_id;
  end if;
end;
$$;

revoke all on function admin_lock_creator_shop(uuid, boolean, uuid) from public, anon;
grant execute on function admin_lock_creator_shop(uuid, boolean, uuid) to authenticated;


-- ============================================================
-- 2. Enforce the lock everywhere a shop can be chosen
-- ============================================================
create or replace function set_link_shop(p_link_id uuid, p_shop_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_profile profiles;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_profile from profiles where id = v_uid;

  if coalesce(v_profile.shop_locked, false) then
    raise exception 'Your payment cost is set by the admin and cannot be changed';
  end if;

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
  v_profile profiles;
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

  select * into v_profile from profiles where id = v_uid;

  -- A locked creator gets their assigned shop no matter what was sent.
  if coalesce(v_profile.shop_locked, false) and v_profile.forced_shop_id is not null then
    select * into v_shop from btcpay_shops s where s.id = v_profile.forced_shop_id;
    if not found then raise exception 'Your assigned payment shop is unavailable'; end if;
  elsif p_shop_id is not null then
    select * into v_shop from btcpay_shops s where s.id = p_shop_id and s.is_active = true;
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
    if v_slug = '' or v_slug = any(v_seen) then continue; end if;
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

  if not v_any then raise exception 'Those links already exist'; end if;
end;
$$;

revoke all on function create_link_variants(text, text[], uuid) from public, anon;
grant execute on function create_link_variants(text, text[], uuid) to authenticated;


-- ============================================================
-- 3. The dashboard needs to know it is locked
-- ------------------------------------------------------------
-- profiles is readable by its owner, so the two columns are visible
-- already. This just makes the intent explicit for the settings the
-- creator's own page reads.
-- ============================================================
create or replace function admin_customer_shop_lock(p_creator_id uuid)
returns table (shop_locked boolean, forced_shop_id uuid, shop_name text)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pr.shop_locked, pr.forced_shop_id, s.name
  from profiles pr
  left join btcpay_shops s on s.id = pr.forced_shop_id
  where pr.id = p_creator_id;
end; $$;

revoke all on function admin_customer_shop_lock(uuid) from public, anon;
grant execute on function admin_customer_shop_lock(uuid) to authenticated;


-- ============================================================
-- 4. Settings the admin can flip for everyone
-- ------------------------------------------------------------
-- auto_withdraw_enabled already existed but had no control in the panel.
-- It is the global gate: off here means no creator gets instant
-- Lightning payouts, whatever their individual profile says. Turning it
-- on does not turn anyone on by itself — the per-creator toggle in
-- Customers still has to be set.
-- ============================================================
insert into app_settings (key, value)
select 'auto_withdraw_enabled', 'false'::jsonb
where not exists (select 1 from app_settings where key = 'auto_withdraw_enabled');

insert into app_settings (key, value)
select 'public_feed_enabled', 'false'::jsonb
where not exists (select 1 from app_settings where key = 'public_feed_enabled');

insert into app_settings (key, value)
select 'support_links', jsonb_build_object('email', '', 'group_url', '')
where not exists (select 1 from app_settings where key = 'support_links');

-- The home page reads these three before anyone signs in.
drop policy if exists "settings public read" on app_settings;
create policy "settings public read"
on app_settings for select
to anon
using (key in ('platform_notice', 'site_domain', 'public_feed_enabled', 'support_links'));

drop policy if exists "settings creator read" on app_settings;
create policy "settings creator read"
on app_settings for select
to authenticated
using (
  is_admin()
  or key in (
    'platform_notice', 'site_domain', 'auto_withdraw_enabled',
    'auto_withdraw_threshold', 'default_max_payment_links',
    'default_withdrawal_fee_percent', 'public_feed_enabled', 'support_links'
  )
);


-- ============================================================
-- 5. Public settled-payment feed
-- ------------------------------------------------------------
-- Worth being clear about what this exposes. A public list of settled
-- payments is a public revenue log: anyone can sit on the page and add
-- up how much the platform takes in.
--
-- So it returns the least that can still look alive — amount and when,
-- nothing else. No creator, no email, no link slug, no payment id. And
-- it is off unless an admin turns it on.
-- ============================================================
create or replace function public_settled_feed(p_limit int default 20)
returns table (amount numeric, settled_at timestamptz)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if coalesce((select (value)::text from app_settings
               where key = 'public_feed_enabled'), 'false') <> 'true' then
    return;
  end if;

  return query
  select p.amount_settled, p.settled_at
  from payments p
  where p.status = 'settled' and p.settled_at is not null
  order by p.settled_at desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
end;
$$;

revoke all on function public_settled_feed(int) from public;
grant execute on function public_settled_feed(int) to anon, authenticated;


-- ============================================================
-- 6. Look up one payment by its invoice
-- ------------------------------------------------------------
-- Exact match only, never a prefix or a LIKE. A BTCPay invoice id and a
-- bolt11 string are both long and unguessable, so knowing one is proof
-- enough to see that one payment's status — but a partial match would
-- turn this into a way to walk the whole table.
--
-- Returns status and amount, and nothing that identifies the creator.
-- ============================================================
create or replace function lookup_payment_status(p_reference text)
returns table (amount numeric, status text, created_at timestamptz, settled_at timestamptz)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_ref text := trim(coalesce(p_reference, ''));
begin
  -- Short inputs are guessable, so refuse them outright.
  if length(v_ref) < 12 then
    raise exception 'Enter the full invoice ID or Lightning address';
  end if;

  return query
  select coalesce(p.amount_settled, p.amount_requested), p.status, p.created_at, p.settled_at
  from payments p
  where p.btcpay_invoice_id = v_ref or p.lightning_invoice = v_ref
  limit 1;
end;
$$;

revoke all on function lookup_payment_status(text) from public;
grant execute on function lookup_payment_status(text) to anon, authenticated;
