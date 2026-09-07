-- ============================================================
-- Boltpay — 0019: Admin RPC caller fix + grant tightening
-- ============================================================
-- Two problems found while re-auditing 0003 and 0018.
-- ============================================================


-- ============================================================
-- 1. admin_mark_payment could not be called by the service role
-- ------------------------------------------------------------
-- 0018 moved the bounds/already-settled checks into
-- admin_mark_payment(), and btcpay-webhook's /admin-mark-settled
-- route was changed to call it. But that route calls it with the
-- SERVICE ROLE client, and a service-role JWT has no `sub` claim —
-- so auth.uid() is null, is_admin() returns false, and the admin's
-- "Approve" button on a stuck payment failed with 'Not authorized'.
--
-- The admin panel's "Mark expired" button was never affected: it
-- calls the same function directly with the admin's own JWT.
--
-- Fix: allow the service role through. It can only be reached from
-- an Edge Function, and that route already verified an admin JWT in
-- code before getting here. Everyone else still needs is_admin().
-- ============================================================
create or replace function admin_mark_payment(
  p_payment_id uuid,
  p_status text,
  p_amount_settled numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment payments;
  v_is_service_role boolean;
begin
  v_is_service_role := coalesce(
    current_setting('request.jwt.claims', true)::jsonb ->> 'role',
    ''
  ) = 'service_role';

  if not (is_admin() or v_is_service_role) then
    raise exception 'Not authorized';
  end if;

  if p_status not in ('settled', 'expired', 'invalid') then
    raise exception 'Invalid status';
  end if;

  select * into v_payment from payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;

  if v_payment.status = 'settled' then
    raise exception 'This payment is already settled';
  end if;

  if p_status = 'settled' then
    if p_amount_settled is not null
       and (p_amount_settled <= 0 or p_amount_settled > 100000) then
      raise exception 'Settled amount out of range';
    end if;
    update payments
      set status = 'settled',
          settled_at = now(),
          amount_settled = coalesce(p_amount_settled, amount_requested)
      where id = p_payment_id;
  else
    update payments set status = p_status where id = p_payment_id;
  end if;
end;
$$;

revoke all on function admin_mark_payment(uuid, text, numeric) from public, anon;
grant execute on function admin_mark_payment(uuid, text, numeric)
  to authenticated, service_role;


-- ============================================================
-- 2. anon still had EXECUTE on every admin_* function
-- ------------------------------------------------------------
-- Migrations 0008 and 0013-0015 only did `revoke all ... from
-- public`. In a Supabase project, anon and authenticated are granted
-- EXECUTE explicitly through ALTER DEFAULT PRIVILEGES, not through
-- PUBLIC — so revoking PUBLIC leaves both roles untouched.
--
-- Every one of these starts with `if not is_admin() then raise`, so
-- an anonymous caller only ever got 'Not authorized'. It was never
-- exploitable. But there is no reason for these to be reachable
-- without a session at all, and a future function that forgets its
-- is_admin() line would then be wide open.
-- ============================================================
-- Written as a loop over pg_proc rather than a list of hardcoded
-- signatures. The Supabase SQL editor runs a script in one
-- transaction, so a single `revoke` naming an argument list that has
-- since drifted would abort this entire migration and roll back the
-- admin_mark_payment fix above with it.
do $$
declare
  fn record;
begin
  for fn in
    select p.oid::regprocedure as sig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in (
        'admin_customer_directory', 'admin_global_stats', 'admin_list_creators',
        'admin_list_domains', 'admin_list_payment_links', 'admin_list_payments',
        'admin_live_payments', 'admin_set_link_limit', 'admin_toggle_creator_auto',
        'admin_toggle_link', 'admin_update_creator_fee', 'clear_message_thread'
      )
  loop
    execute format('revoke all on function %s from anon', fn.sig);
  end loop;

  -- Trigger functions are never meant to be reachable over the API.
  for fn in
    select p.oid::regprocedure as sig
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in (
        'enforce_link_limit', 'validate_link_slug', 'handle_new_user',
        'guard_profile_updates', 'guard_withdrawal_updates', 'guard_message_updates'
      )
  loop
    execute format('revoke all on function %s from anon, authenticated', fn.sig);
  end loop;
end
$$;

grant execute on function get_link_preview(text) to anon, authenticated;

-- Trigger functions are never meant to be called over the API.
revoke all on function enforce_link_limit() from anon, authenticated;
revoke all on function validate_link_slug() from anon, authenticated;
revoke all on function guard_profile_updates() from anon, authenticated;
revoke all on function guard_withdrawal_updates() from anon, authenticated;
revoke all on function guard_message_updates() from anon, authenticated;
revoke all on function handle_new_user() from anon, authenticated;
