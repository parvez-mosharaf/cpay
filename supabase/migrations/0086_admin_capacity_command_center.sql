-- ============================================================
-- CPAY — 0086: admin capacity + command center
-- ============================================================
-- Read-only operational telemetry for the admin panel. No secrets,
-- provider credentials or customer destinations are returned.

create index if not exists idx_payments_status_created_at on public.payments(status, created_at desc);
create index if not exists idx_payments_user_created_at on public.payments(user_id, created_at desc);
create index if not exists idx_payments_link_created_at on public.payments(payment_link_id, created_at desc);
create index if not exists idx_withdrawals_status_requested_at on public.withdrawals(status, requested_at desc);
create index if not exists idx_withdrawals_user_requested_at on public.withdrawals(user_id, requested_at desc);
create index if not exists idx_payment_links_active_created_at on public.payment_links(is_active, created_at desc) where deleted_at is null;
create index if not exists idx_audit_log_occurred_at on public.audit_log(occurred_at desc);
create index if not exists idx_webhook_events_received_at on public.webhook_events(received_at desc);

create or replace function public.admin_system_snapshot()
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v jsonb;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  select jsonb_build_object(
    'checked_at', now(),
    'database', jsonb_build_object(
      'size_bytes', pg_database_size(current_database()),
      'size_pretty', pg_size_pretty(pg_database_size(current_database()))
    ),
    'traffic', jsonb_build_object(
      'payments_24h', (select count(*) from payments where created_at >= now() - interval '24 hours'),
      'settled_24h', (select count(*) from payments where status='settled' and settled_at >= now() - interval '24 hours'),
      'withdrawals_24h', (select count(*) from withdrawals where requested_at >= now() - interval '24 hours'),
      'new_profiles_24h', (select count(*) from profiles where created_at >= now() - interval '24 hours')
    ),
    'queues', jsonb_build_object(
      'pending_withdrawals', (select count(*) from withdrawals where status in ('pending','approved')),
      'processing_withdrawals', (select count(*) from withdrawals where status='processing'),
      'new_payments', (select count(*) from payments where status='new'),
      'pending_payments', (select count(*) from payments where status='pending'),
      'pending_applications', (select count(*) from account_applications where status='pending')
    ),
    'platform', jsonb_build_object(
      'profiles', (select count(*) from profiles),
      'active_profiles', (select count(*) from profiles where account_status='active'),
      'payment_links', (select count(*) from payment_links where deleted_at is null),
      'active_links', (select count(*) from payment_links where deleted_at is null and is_active=true),
      'shops', (select count(*) from btcpay_shops where is_active=true),
      'domains', (select count(*) from site_domains where is_active=true)
    ),
    'latency', jsonb_build_object(
      'last_webhook_at', (select max(received_at) from webhook_events),
      'last_settled_at', (select max(settled_at) from payments where status='settled'),
      'oldest_pending_withdrawal_at', (select min(requested_at) from withdrawals where status in ('pending','approved')),
      'oldest_pending_payment_at', (select min(created_at) from payments where status='pending')
    ),
    'table_sizes', jsonb_build_object(
      'payments', pg_total_relation_size('public.payments'),
      'withdrawals', pg_total_relation_size('public.withdrawals'),
      'payment_links', pg_total_relation_size('public.payment_links'),
      'audit_log', pg_total_relation_size('public.audit_log'),
      'profiles', pg_total_relation_size('public.profiles')
    )
  ) into v;

  return v;
end;
$$;

revoke all on function public.admin_system_snapshot() from public, anon;
grant execute on function public.admin_system_snapshot() to authenticated;


-- Operator-threshold alert feed. These thresholds are intentionally explicit and
-- conservative; they are not claims about a provider's quota.
create or replace function public.admin_system_alerts()
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  alerts jsonb := '[]'::jsonb;
  db_bytes bigint := pg_database_size(current_database());
  pending_w bigint := (select count(*) from withdrawals where status in ('pending','approved'));
  processing_w bigint := (select count(*) from withdrawals where status='processing');
  pending_p bigint := (select count(*) from payments where status='pending');
  new_p bigint := (select count(*) from payments where status='new');
  pending_apps bigint := (select count(*) from account_applications where status='pending');
  last_webhook timestamptz := (select max(received_at) from webhook_events);
  last_settled timestamptz := (select max(settled_at) from payments where status='settled');
  oldest_w timestamptz := (select min(requested_at) from withdrawals where status in ('pending','approved'));
  oldest_p timestamptz := (select min(created_at) from payments where status='pending');
  recent_payments bigint := (select count(*) from payments where created_at >= now() - interval '24 hours');
  webhook_age numeric;
  settled_age numeric;
  db_gb numeric;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  db_gb := db_bytes / 1073741824.0;

  if db_gb >= 5 then alerts := alerts || jsonb_build_array(jsonb_build_object('code','db_critical','severity','critical','title','Database footprint is large','detail',round(db_gb,2)||' GB; review retention, indexes and storage capacity.'));
  elsif db_gb >= 1 then alerts := alerts || jsonb_build_array(jsonb_build_object('code','db_warning','severity','warning','title','Database footprint is growing','detail',round(db_gb,2)||' GB; review growth before the next capacity milestone.')); end if;

  if pending_w >= 20 then alerts := alerts || jsonb_build_array(jsonb_build_object('code','withdrawal_queue','severity','warning','title','Withdrawal queue is building','detail',pending_w||' pending/approved withdrawals.'));
  end if;
  if processing_w >= 5 then alerts := alerts || jsonb_build_array(jsonb_build_object('code','withdrawal_processing','severity','warning','title','Processing withdrawals need review','detail',processing_w||' withdrawals are currently processing.'));
  end if;
  if pending_p >= 25 then alerts := alerts || jsonb_build_array(jsonb_build_object('code','payment_backlog','severity','warning','title','Payment backlog is elevated','detail',pending_p||' pending payments.'));
  end if;
  if pending_apps >= 15 then alerts := alerts || jsonb_build_array(jsonb_build_object('code','application_queue','severity','info','title','Application queue is growing','detail',pending_apps||' account applications are pending.'));
  end if;

  if last_webhook is null and recent_payments > 0 then
    alerts := alerts || jsonb_build_array(jsonb_build_object('code','webhook_missing','severity','critical','title','No webhook activity recorded','detail',recent_payments||' payments were created in the last 24h but no webhook receipt exists.'));
  elsif last_webhook is not null then
    webhook_age := extract(epoch from (now()-last_webhook))/60.0;
    if webhook_age >= 30 and recent_payments > 0 then alerts := alerts || jsonb_build_array(jsonb_build_object('code','webhook_stale','severity','warning','title','Webhook activity looks stale','detail','Last webhook was '||round(webhook_age)||' minutes ago while payments were active.')); end if;
  end if;

  if last_settled is not null then
    settled_age := extract(epoch from (now()-last_settled))/60.0;
    if settled_age >= 60 and pending_p > 0 then alerts := alerts || jsonb_build_array(jsonb_build_object('code','settlement_stale','severity','warning','title','Settlement freshness needs review','detail','Last settled payment was '||round(settled_age)||' minutes ago with pending payments.')); end if;
  end if;

  if oldest_w is not null and extract(epoch from (now()-oldest_w))/3600.0 >= 6 then alerts := alerts || jsonb_build_array(jsonb_build_object('code','old_withdrawal','severity','warning','title','Withdrawal has been waiting','detail','Oldest pending/approved withdrawal is more than 6 hours old.')); end if;
  if oldest_p is not null and extract(epoch from (now()-oldest_p))/3600.0 >= 6 then alerts := alerts || jsonb_build_array(jsonb_build_object('code','old_payment','severity','warning','title','Payment has been pending','detail','Oldest pending payment is more than 6 hours old.')); end if;

  return jsonb_build_object('checked_at',now(),'alerts',alerts,'thresholds',jsonb_build_object('database_warning_gb',1,'database_critical_gb',5,'pending_withdrawals_warning',20,'processing_withdrawals_warning',5,'pending_payments_warning',25,'pending_applications_info',15,'webhook_stale_minutes',30,'settlement_stale_minutes',60,'old_queue_hours',6));
end;
$$;
revoke all on function public.admin_system_alerts() from public, anon;
grant execute on function public.admin_system_alerts() to authenticated;
