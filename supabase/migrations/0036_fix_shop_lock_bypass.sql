-- 0036_fix_shop_lock_bypass.sql
-- ALREADY APPLIED to project ohwzmxwsphsfzudmlins on 2026-09-01 (owner approved).
-- Committed for history only — do NOT re-run as if pending.
-- Fixes the shop_lock bypass left open by 0025_per_link_shop_choice.
--
-- Problem: set_link_shop() correctly refuses when profiles.shop_locked is true, but the
-- RLS policy "own links update" on payment_links is just (user_id = auth.uid()) with no
-- column guard. So a creator can skip the RPC and PATCH /rest/v1/payment_links?id=eq...
-- with {"shop_id": "<cheaper shop>"} and move themselves off the admin-forced shop.
--
-- Fix: a BEFORE UPDATE trigger that pins shop_id for locked creators, mirroring the
-- existing guard_profile_updates() pattern. Service role / admins are unaffected.

create or replace function public.guard_link_shop_updates()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_locked boolean;
  v_forced uuid;
begin
  -- service-role / trigger context (auth.uid() is null) and admins are allowed through;
  -- admin changes go via admin_set_link_shop().
  if auth.uid() is null or is_admin() then
    return new;
  end if;

  if new.shop_id is distinct from old.shop_id then
    select coalesce(shop_locked, false), forced_shop_id
      into v_locked, v_forced
      from profiles where id = auth.uid();

    if v_locked then
      raise exception 'Your payment cost is set by the admin and cannot be changed';
    end if;

    -- unlocked creators may only move to an ACTIVE shop (same rule as set_link_shop)
    if new.shop_id is not null
       and not exists (select 1 from btcpay_shops s
                       where s.id = new.shop_id and s.is_active = true) then
      raise exception 'That cost option is not available';
    end if;
  end if;

  -- a creator must never reassign a link to another user
  if new.user_id is distinct from old.user_id then
    raise exception 'Cannot change link owner';
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_guard_link_shop_updates on public.payment_links;
create trigger trg_guard_link_shop_updates
  before update on public.payment_links
  for each row execute function public.guard_link_shop_updates();
