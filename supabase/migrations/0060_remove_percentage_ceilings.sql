-- ============================================================
-- Boltpay — 0060: no ceiling on either percentage
-- ============================================================
-- Correcting two limits that were assumptions, not requirements.
--
-- They are separate numbers and always were. Stating it once more here
-- because the two have been conflated before:
--
--   cost_percent           the user's own markup on their payment
--                          links. The PAYER pays it. Set by the
--                          freelancer or reseller themselves.
--
--   withdrawal_fee_percent what the platform charges that user at
--                          payout. The USER pays it. Set by the admin,
--                          seeded from the "Default fee for new
--                          creators" setting, adjustable per profile.
--
-- Neither has a ceiling any more.
-- ============================================================


-- ============================================================
-- 1. cost_percent — the 25% admin ceiling is gone
-- ------------------------------------------------------------
-- 0059 introduced max_user_cost_percent (default 25) on the assumption
-- that "set your own price" needed a guard rail. It does not: a user
-- pricing their own work is their own business decision, and a markup
-- that is too high simply means nobody pays their link.
--
-- The setting row is deleted rather than raised to some large number,
-- so there is no half-enforced limit left behind for someone to
-- rediscover later and wonder about.
-- ============================================================
delete from app_settings where key = 'max_user_cost_percent';

-- The CHECK is widened rather than dropped entirely. This is NOT a
-- policy ceiling — it is a typo guard. Without any bound, a fat-fingered
-- "1000" instead of "10" would charge a payer eleven times the intended
-- amount with nothing to stop it. 1000% (an 11x markup) is far beyond
-- any real pricing decision while still catching the accident.
alter table profiles drop constraint if exists profiles_cost_percent_range;
alter table profiles add constraint profiles_cost_percent_range
  check (cost_percent >= 0 and cost_percent <= 1000);


create or replace function set_my_cost_percent(p_percent numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
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

  -- Matches the column's typo guard, with a message that explains what
  -- the limit is for rather than implying a policy the admin set.
  if p_percent > 1000 then
    raise exception 'That looks like a typo — the maximum markup is 1000%%';
  end if;

  update profiles set cost_percent = round(p_percent, 3) where id = v_uid;
  return round(p_percent, 3);
end;
$$;

revoke all on function set_my_cost_percent(numeric) from public, anon;
grant execute on function set_my_cost_percent(numeric) to authenticated;


create or replace function admin_set_cost_percent(p_user_id uuid, p_percent numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_old numeric;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_percent is null or p_percent < 0 or p_percent > 1000 then
    raise exception 'Cost must be between 0 and 1000';
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
-- 2. withdrawal_fee_percent — the 50% ceiling is gone
-- ------------------------------------------------------------
-- admin_update_creator_fee() has refused anything above 50% since 0014.
-- That was never asked for either; the admin sets this number and can
-- choose whatever it should be. Same typo-guard reasoning as above:
-- bounded at 100 because a withdrawal fee is a share of the amount, and
-- above 100% the payout goes negative — which is not a price, it is a
-- broken calculation. request_withdrawal() computes
-- `amount * (1 - fee/100)`, so 100% pays out exactly zero and anything
-- beyond would owe the user a negative sum.
-- ============================================================
create or replace function admin_update_creator_fee(p_creator_id uuid, p_fee_percent numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_old numeric;
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;
  if p_fee_percent is null or p_fee_percent < 0 or p_fee_percent > 100 then
    raise exception 'Fee must be between 0 and 100';
  end if;

  select withdrawal_fee_percent into v_old from profiles where id = p_creator_id;
  if not found then raise exception 'Creator not found'; end if;

  update profiles set withdrawal_fee_percent = p_fee_percent where id = p_creator_id;

  perform record_audit(
    'creator.fee_changed', 'profile', p_creator_id::text,
    jsonb_build_object('withdrawal_fee_percent', v_old),
    jsonb_build_object('withdrawal_fee_percent', p_fee_percent)
  );
end;
$$;

revoke all on function admin_update_creator_fee(uuid, numeric) from public, anon;
grant execute on function admin_update_creator_fee(uuid, numeric) to authenticated;


-- ============================================================
-- 3. The cost ceiling is no longer readable, because it no longer exists
-- ------------------------------------------------------------
-- 0059 added max_user_cost_percent to the authenticated read allowlist
-- so the dashboard could display "Maximum allowed: N%". With the
-- setting deleted, that entry is removed too rather than left pointing
-- at a key that will never return a row.
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
    'default_withdrawal_fee_percent', 'public_feed_enabled', 'support_links'
  )
);
