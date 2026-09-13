-- ============================================================
-- Boltpay — 0059: reseller links, saved Lightning Address,
-- per-user cost control, and fee-based admin profit
-- ============================================================
-- Four related changes. Read the money model note at the bottom before
-- changing any of this later — the three revenue concepts here are
-- easy to conflate and mean very different things.
-- ============================================================


-- ============================================================
-- 1. Resellers (role = 'moderator') can own payment links
-- ------------------------------------------------------------
-- Verified first: nothing actually blocked this. The RLS policies on
-- payment_links are `user_id = auth.uid()` with no role test, and
-- enforce_link_limit() reads max_payment_links off whichever profile
-- owns the row. So a reseller could already insert a link — the gap
-- was that reseller profiles were never given a link allowance, and
-- the admin panel's own creator-detail tooling only ever listed
-- role = 'creator'.
--
-- Backfilling the allowance is the only DB-side change needed. The
-- panel-side change (admin_list_creators including moderators, so you
-- can open a reseller's profile the same way) is below in section 4.
-- ============================================================
update profiles
   set max_payment_links = coalesce(max_payment_links, 5)
 where role = 'moderator'
   and max_payment_links is null;


-- ============================================================
-- 2. A saved Lightning Address for auto-withdrawals
-- ------------------------------------------------------------
-- A bolt11 invoice expires (typically an hour), so it can never be
-- saved once and reused — which is why Lightning has always required
-- pasting a fresh invoice per withdrawal, and why it could never be an
-- automatic payout destination.
--
-- A Lightning Address (user@domain, exactly the shape of an email) is
-- static. It resolves through LNURL-pay to a fresh invoice at payout
-- time, so it CAN be saved once in a profile and reused forever.
--
-- Stored as its own column rather than reusing one of the wallet_*
-- fields, because the validation is different and the payout path
-- treats it differently.
-- ============================================================
alter table profiles add column if not exists wallet_lightning_address text;

alter table profiles drop constraint if exists profiles_lightning_address_shape;
alter table profiles add constraint profiles_lightning_address_shape
  check (
    wallet_lightning_address is null
    or wallet_lightning_address ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
  );

comment on column profiles.wallet_lightning_address is
  'Static LNURL-pay address (user@domain) for automatic Lightning payouts. Unlike a bolt11 invoice this does not expire, so it can be saved once and reused.';


-- ============================================================
-- 3. Per-user cost control
-- ------------------------------------------------------------
-- Until now the payer's markup was btcpay_shops.surcharge_percent — a
-- STORE-level BTCPay rate spread that BTCPay itself applied, which
-- Boltpay could only display, never change. With one shared shop that
-- means one markup for everyone, so a freelancer could not price their
-- own work.
--
-- Confirmed against BTCPay's Greenfield API that a per-invoice rate
-- override does not exist — `checkout` carries speedPolicy,
-- paymentMethods, paymentTolerance and so on, but no rate rules. So
-- this cannot be done by asking BTCPay for a different rate per
-- invoice. Boltpay changes the AMOUNT it sends instead, which is
-- equivalent from the payer's side and entirely under our control.
--
-- cost_percent is the user's own markup, on top of whatever spread the
-- shared BTCPay store already applies. Bounded by an admin-set
-- ceiling so "set your own price" cannot become "charge 400%".
-- ============================================================
alter table profiles add column if not exists cost_percent numeric(6,3) not null default 0;

alter table profiles drop constraint if exists profiles_cost_percent_range;
alter table profiles add constraint profiles_cost_percent_range
  check (cost_percent >= 0 and cost_percent <= 100);

insert into app_settings (key, value)
select 'max_user_cost_percent', '25'::jsonb
where not exists (select 1 from app_settings where key = 'max_user_cost_percent');


-- The user sets their own, within the admin's ceiling. A SECURITY
-- DEFINER function rather than a direct column update, because
-- guard_profile_updates() (correctly) refuses direct writes to
-- anything money-related, and because the ceiling has to be enforced
-- somewhere the client cannot skip.
create or replace function set_my_cost_percent(p_percent numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_max numeric;
  v_role text;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select role into v_role from profiles where id = v_uid;
  if v_role not in ('creator', 'moderator') then
    raise exception 'Not authorized';
  end if;

  if p_percent is null or p_percent < 0 then
    raise exception 'Cost must be 0 or more';
  end if;

  select coalesce((value)::text::numeric, 25) into v_max
  from app_settings where key = 'max_user_cost_percent';
  v_max := coalesce(v_max, 25);

  if p_percent > v_max then
    raise exception 'Cost cannot exceed %%%', v_max;
  end if;

  update profiles set cost_percent = round(p_percent, 3) where id = v_uid;
  return round(p_percent, 3);
end;
$$;

revoke all on function set_my_cost_percent(numeric) from public, anon;
grant execute on function set_my_cost_percent(numeric) to authenticated;


-- guard_profile_updates() must cover the new columns too. cost_percent
-- goes through set_my_cost_percent() above (SECURITY DEFINER, so it
-- bypasses this trigger legitimately); a direct write must not be a
-- way around the ceiling. wallet_lightning_address is deliberately NOT
-- listed — it is a wallet detail the user is meant to set themselves,
-- exactly like the other wallet_* columns.
create or replace function guard_profile_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or is_admin() then
    return new;
  end if;
  if new.id                     is distinct from old.id
  or new.email                  is distinct from old.email
  or new.role                   is distinct from old.role
  or new.withdrawal_fee_percent is distinct from old.withdrawal_fee_percent
  or new.max_payment_links      is distinct from old.max_payment_links
  or new.auto_withdraw_enabled  is distinct from old.auto_withdraw_enabled
  or new.buy_rate               is distinct from old.buy_rate
  or new.sell_rate              is distinct from old.sell_rate
  or new.shop_locked            is distinct from old.shop_locked
  or new.forced_shop_id         is distinct from old.forced_shop_id
  or new.cost_percent           is distinct from old.cost_percent
  then
    raise exception 'You may only change your display name and wallet details';
  end if;
  return new;
end;
$$;


-- What create-invoice reads to price an invoice. Runs as the caller
-- (anon, on a public payment page), so it exposes exactly the two
-- numbers that page legitimately needs and nothing else about the user.
create or replace function link_cost_for_slug(p_slug text)
returns table (cost_percent numeric, shop_surcharge_percent numeric)
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(pr.cost_percent, 0), coalesce(s.surcharge_percent, 0)
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  left join btcpay_shops s on s.id = pl.shop_id
  where pl.slug = p_slug and pl.deleted_at is null
  limit 1;
$$;

revoke all on function link_cost_for_slug(text) from public;
grant execute on function link_cost_for_slug(text) to anon, authenticated;


-- ============================================================
-- 4. Admin profit is now the fees actually charged
-- ------------------------------------------------------------
-- The old figure was `total_settled * (profit_margin_percent/100) / 2`
-- — a guess derived from volume and a global margin, matching no real
-- transaction, and the /2 was never explained anywhere. The platform's
-- actual revenue is the withdrawal fee charged to each user, which is
-- already recorded per row: amount_requested - amount_after_fee.
--
-- Counting only PAID withdrawals, because a fee on a pending request
-- is not revenue yet.
-- ============================================================
create or replace function admin_global_stats(
  p_start timestamptz default null,
  p_end   timestamptz default null
)
returns table (
  total_settled numeric, total_admin_profit numeric, total_withdrawn numeric,
  pending_withdrawals_count int, pending_withdrawals_amount numeric,
  payment_count bigint, active_creators bigint, calculated_node_balance numeric
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_total_settled numeric;
  v_margin numeric;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  select coalesce(sum(amount_settled), 0) into v_total_settled
  from payments
  where status = 'settled'
    and (p_start is null or settled_at >= p_start)
    and (p_end   is null or settled_at <= p_end);

  select coalesce((value->>'percent')::numeric, 7.7) into v_margin
  from app_settings where key = 'profit_margin_percent';

  return query
  select
    v_total_settled,
    -- Real fee revenue: what each paid-out user was actually charged.
    coalesce((
      select sum(w.amount_requested - w.amount_after_fee)
      from withdrawals w
      where w.status = 'paid'
        and (p_start is null or w.processed_at >= p_start)
        and (p_end   is null or w.processed_at <= p_end)
    ), 0),
    coalesce((
      select sum(w.amount_after_fee) from withdrawals w
      where w.status = 'paid'
        and (p_start is null or w.processed_at >= p_start)
        and (p_end   is null or w.processed_at <= p_end)
    ), 0),
    (select count(*) from withdrawals w where w.status = 'pending')::int,
    coalesce((select sum(w.amount_requested) from withdrawals w where w.status = 'pending'), 0),
    (select count(*) from payments p
      where p.status = 'settled'
        and (p_start is null or p.settled_at >= p_start)
        and (p_end   is null or p.settled_at <= p_end)),
    (select count(distinct p.user_id) from payments p where p.status = 'settled'),
    round(v_total_settled * (1.0 + (v_margin / 100.0)), 4);
end;
$$;

revoke all on function admin_global_stats(timestamptz, timestamptz) from public, anon;
grant execute on function admin_global_stats(timestamptz, timestamptz) to authenticated;


-- The admin's people list, now including resellers so a reseller's
-- profile opens the same way a freelancer's does — fee control, link
-- allowance, lock, all of it.
--
-- Deliberately a NEW name. admin_list_creators() already exists and is
-- something else entirely: the messages sidebar's list, returning
-- (id, email, display_name, unread_count). Redefining it here with a
-- different column set would have silently broken the Messages tab —
-- and, because the return type changes, would have failed to apply at
-- all with a 42P13 error, exactly like the earlier incident recorded
-- in AUDIT.md.
create or replace function admin_list_people()
returns table (
  id uuid, email text, display_name text, role text,
  withdrawal_fee_percent numeric, max_payment_links int,
  auto_withdraw_enabled boolean, shop_locked boolean, forced_shop_id uuid,
  cost_percent numeric,
  total_settled numeric, available_balance numeric, created_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select
    pr.id, pr.email, pr.display_name, pr.role,
    pr.withdrawal_fee_percent, pr.max_payment_links,
    pr.auto_withdraw_enabled, pr.shop_locked, pr.forced_shop_id,
    coalesce(pr.cost_percent, 0),
    coalesce((select sum(p.amount_settled) from payments p
              where p.user_id = pr.id and p.status = 'settled'), 0),
    coalesce((select b.available from get_balance_for(pr.id) b), 0),
    pr.created_at
  from profiles pr
  where pr.role in ('creator', 'moderator')
  order by pr.created_at desc;
end;
$$;

revoke all on function admin_list_people() from public, anon;
grant execute on function admin_list_people() to authenticated;


-- Admin can set anyone's cost ceiling override from their profile.
create or replace function admin_set_cost_percent(p_user_id uuid, p_percent numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_old numeric;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_percent is null or p_percent < 0 or p_percent > 100 then
    raise exception 'Cost must be between 0 and 100';
  end if;

  select cost_percent into v_old from profiles where id = p_user_id;
  if not found then raise exception 'User not found'; end if;

  update profiles set cost_percent = round(p_percent, 3) where id = p_user_id;

  perform record_audit(
    'user.cost_percent_changed', 'profile', p_user_id::text,
    jsonb_build_object('cost_percent', v_old),
    jsonb_build_object('cost_percent', round(p_percent, 3))
  );
end;
$$;

revoke all on function admin_set_cost_percent(uuid, numeric) from public, anon;
grant execute on function admin_set_cost_percent(uuid, numeric) to authenticated;


-- ============================================================
-- The money model, written down once
-- ------------------------------------------------------------
-- Three separate numbers, often confused:
--
-- 1. btcpay_shops.surcharge_percent — the BTCPay STORE's rate spread.
--    BTCPay applies this itself when converting USD to BTC. It covers
--    the conversion and the node's own buffer. Boltpay only displays
--    it; changing it means changing it in BTCPay's own settings.
--
-- 2. profiles.cost_percent — the user's OWN markup, new here. Boltpay
--    applies it by multiplying the amount before sending the invoice
--    to BTCPay. This is the freelancer or reseller pricing their own
--    work. Capped by app_settings.max_user_cost_percent.
--
-- 3. profiles.withdrawal_fee_percent — what the PLATFORM charges the
--    user, taken at payout. This, and only this, is admin profit.
--
-- A payer charged $100 on a link whose owner has cost_percent = 5
-- pays $105 worth of BTC (plus whatever spread BTCPay adds on top of
-- that). The owner is credited $105. When they withdraw $105 with a
-- withdrawal_fee_percent of 3, they receive $101.85 and the platform
-- keeps $3.15 — which is what admin_global_stats() now reports as
-- profit, rather than the old volume-times-margin guess.
-- ============================================================

-- ============================================================
-- 5. create-invoice needs the owner's cost in the lookup it already does
-- ------------------------------------------------------------
-- system_link_for_invoice() is the single service-role lookup that
-- create-invoice already performs before building an invoice. Adding
-- cost_percent to it means no extra round-trip, and — more
-- importantly — means the price and the store can never be read from
-- two different points in time.
--
-- Return type changes, so this needs an explicit DROP first. A plain
-- CREATE OR REPLACE against a different column list fails with 42P13,
-- and (because Supabase runs the whole migration in one transaction)
-- would roll back everything above it. That exact mistake is recorded
-- in AUDIT.md from earlier in this project.
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
         coalesce(pr.cost_percent, 0)
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  left join btcpay_shops s on s.id = pl.shop_id and s.is_active = true
  where pl.slug = p_slug and pl.deleted_at is null
  limit 1;
$$;

revoke all on function system_link_for_invoice(text) from public, anon, authenticated;
-- DROP removes every grant with the function. Without re-granting this,
-- create-invoice (which calls it through the service-role key) would
-- start failing on every single payment attempt — the original grant
-- lives in 0022/0023 and would not re-apply on its own.
grant execute on function system_link_for_invoice(text) to service_role;

-- ============================================================
-- 6. The cost ceiling has to be readable to be shown
-- ------------------------------------------------------------
-- The dashboard displays "Maximum allowed: N%" so nobody discovers the
-- limit by having a save rejected. That read goes through the
-- authenticated-user policy from 0027, whose key list is a fixed
-- allowlist — a key not on it returns nothing at all, silently. Adding
-- it here rather than leaving the hint permanently blank.
--
-- Safe to expose: it is a platform-wide limit, identical for everyone,
-- and every user is about to see it in their own UI anyway.
-- ============================================================
drop policy if exists "settings creator read" on app_settings;
create policy "settings creator read"
on app_settings for select
to authenticated
using (
  is_admin()
  or key in (
    'platform_notice', 'site_domain', 'auto_withdraw_enabled',
    'auto_withdraw_threshold', 'default_max_payment_links',
    'default_withdrawal_fee_percent', 'public_feed_enabled', 'support_links',
    'max_user_cost_percent'
  )
);
