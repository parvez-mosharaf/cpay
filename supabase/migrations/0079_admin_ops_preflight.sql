-- ============================================================
-- CPAY — 0079: admin operations preflight snapshot
-- ============================================================
-- Read-only, admin-only visibility into the configuration and ledger
-- signals that should be checked before a staging or production release.
-- This deliberately does not call BTCPay: live BTCPay reachability stays
-- in the CRON-protected health function so secrets never enter a browser.

create or replace function admin_ops_snapshot()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_snapshot jsonb;
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;

  select jsonb_build_object(
    'checked_at', now(),
    'shops', jsonb_build_object(
      'active', (select count(*) from btcpay_shops where is_active = true),
      'missing_store_id', (
        select count(*) from btcpay_shops
        where is_active = true and nullif(trim(store_id), '') is null
      )
    ),
    'domains', jsonb_build_object(
      'active', (select count(*) from site_domains where is_active = true),
      'payment_ready', (
        select count(*) from site_domains
        where is_active = true and purpose in ('payment', 'both')
      )
    ),
    'flags', jsonb_build_object(
      'manual_withdrawals_enabled',
        coalesce((select value::text = 'true' from app_settings where key = 'manual_withdrawals_enabled'), true),
      'emergency_payments_stop',
        coalesce((select value::text = 'true' from app_settings where key = 'emergency_payments_stop'), false),
      'emergency_withdrawals_stop',
        coalesce((select value::text = 'true' from app_settings where key = 'emergency_withdrawals_stop'), false),
      'auto_withdraw_enabled',
        coalesce((select value::text = 'true' from app_settings where key = 'auto_withdraw_enabled'), false)
    ),
    'withdrawals', jsonb_build_object(
      'pending_count', (
        select count(*) from withdrawals where status in ('pending', 'approved')
      ),
      'pending_amount', (
        select coalesce(sum(amount_requested), 0) from withdrawals
        where status in ('pending', 'approved')
      ),
      'processing_count', (
        select count(*) from withdrawals where status = 'processing'
      )
    ),
    'pipeline', jsonb_build_object(
      'last_webhook_at', (select max(received_at) from webhook_events),
      'last_daily_stat_at', (select max(computed_at) from daily_stats),
      'active_orphan_links', (
        select count(*) from payment_links
        where is_active = true and shop_id is null
      )
    ),
    'profiles', jsonb_build_object(
      'active', (select count(*) from profiles where account_status = 'active'),
      'pending', (select count(*) from profiles where account_status = 'pending'),
      'suspended', (select count(*) from profiles where account_status = 'suspended')
    ),
    'receiving', jsonb_build_object(
      'active_onchain_addresses', (
        select count(*) from onchain_addresses where is_active = true
      )
    )
  )
  into v_snapshot;

  return v_snapshot;
end;
$$;

revoke all on function public.admin_ops_snapshot() from public, anon;
grant execute on function public.admin_ops_snapshot() to authenticated;