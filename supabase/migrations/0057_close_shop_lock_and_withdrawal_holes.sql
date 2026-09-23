-- ============================================================
-- CPAY — 0057: shop-lock, withdrawal-status, moderator-scope
-- ============================================================
-- Three findings from an external review, each verified against the
-- real code before fixing.
-- ============================================================


-- ============================================================
-- 1. shop_locked / forced_shop_id were never guarded
-- ------------------------------------------------------------
-- guard_profile_updates() (0018) blocks a creator from touching id,
-- email, role, withdrawal_fee_percent, max_payment_links,
-- auto_withdraw_enabled, buy_rate, sell_rate — but 0027 added
-- shop_locked and forced_shop_id afterward and never added them here.
-- The RLS policy on profiles is just `id = auth.uid()`, so a creator
-- could call `.update({ shop_locked: false, forced_shop_id: null })`
-- on their own row directly and undo an admin's rate lock. 0036 only
-- ever guarded payment_links.shop_id while shop_locked was true — with
-- the lock itself unguarded, that protection had nothing to stand on.
-- ============================================================
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
  then
    raise exception 'You may only change your display name and wallet details';
  end if;
  return new;
end;
$$;


-- ============================================================
-- 2. A paid (or processing) withdrawal could be pushed back to
--    'rejected' through the admin API, re-crediting spent money
-- ------------------------------------------------------------
-- The 0018 RLS policy's USING clause never restricted which CURRENT
-- status an admin could reach, and guard_withdrawal_updates() only
-- ever protected the amount/destination columns, never `status`. A
-- direct PostgREST UPDATE — not the admin.html UI, which never offers
-- this, but the API itself — could set an already-paid row's status to
-- 'rejected'. get_balance_for()'s `queued` sum excludes 'rejected'
-- rows, so the moment that happens the money reads as available again,
-- while the real payout already left days earlier.
--
-- Two layers now, not one: the RLS policy can no longer even see a
-- paid/processing row as a target, and the trigger independently
-- refuses any status change away from 'paid' once set (belt and
-- braces — a second migration touching this policy later should not
-- silently reopen the gap the way the first one did).
-- ============================================================
drop policy if exists "admin can approve or reject withdrawals" on withdrawals;
create policy "admin can approve or reject withdrawals"
on withdrawals for update
using (is_admin() and status in ('pending', 'approved'))
with check (status in ('pending', 'approved', 'rejected'));

create or replace function guard_withdrawal_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return new;  -- service role / definer functions
  end if;
  if new.user_id          is distinct from old.user_id
  or new.amount_requested is distinct from old.amount_requested
  or new.fee_percent      is distinct from old.fee_percent
  or new.amount_after_fee is distinct from old.amount_after_fee
  or new.destination      is distinct from old.destination
  then
    raise exception 'Withdrawal amounts and destination cannot be edited';
  end if;
  -- Once BTCPay has been asked to pay (processing) or has confirmed it
  -- did (paid), nothing reachable from a browser session may move the
  -- status away from that. Only the service role — used exclusively by
  -- the edge functions that already own this transition — bypasses the
  -- trigger entirely via the auth.uid() is null check above.
  if old.status in ('paid', 'processing') and new.status is distinct from old.status then
    raise exception 'A paid or processing withdrawal cannot be reopened';
  end if;
  return new;
end;
$$;


-- ============================================================
-- 3. mod_list_payments() — superseded, never dropped, still wide open
-- ------------------------------------------------------------
-- 0028 introduced it gated only on is_moderator() — role membership,
-- not creator assignment. 0029 built the real thing,
-- staff_list_payments(), scoped through handles_creator(). No
-- migration since has ever dropped the old one, so any account with
-- role = 'moderator' — including one with zero creators assigned —
-- could call it directly through PostgREST and read every settled
-- payment, invoice ID and creator name on the platform. Nothing in the
-- UI calls it; the exposure was the API surface itself.
-- ============================================================
drop function if exists mod_list_payments(int, text);


-- ============================================================
-- 4. record_audit() was directly callable by any logged-in user
-- ------------------------------------------------------------
-- It was granted to `authenticated` in 0047 — the standard pattern
-- for a function meant to be called from the client. But nothing ever
-- calls record_audit() directly from a page; every use is
-- `perform record_audit(...)` from inside another SECURITY DEFINER
-- function (admin_delete_link, admin_set_role, ...) that has already
-- checked authorization itself. Any authenticated account could call
-- it straight through PostgREST and write an arbitrary, misleading
-- entry into an append-only log that exists specifically to be
-- trusted.
--
-- Revoking the direct grant does not break the legitimate callers:
-- each of them is itself SECURITY DEFINER, so the call runs as that
-- function's owner, not as the original session — the same reason an
-- admin function can update a table a plain creator session could
-- never touch directly.
-- ============================================================
revoke execute on function record_audit(text, text, text, jsonb, jsonb, text) from authenticated;
