-- ============================================================
-- Boltpay — 0048: Schedule the health monitor
-- ============================================================
-- Every 15 minutes. Frequent enough that a dead webhook pipeline is
-- caught within one cycle rather than the next morning, and cheap
-- enough that it costs nothing to run — five small queries and one
-- BTCPay ping.
--
-- The function itself only alerts on genuine faults: it stays quiet
-- when there is simply no traffic, because an alert that fires on a
-- normal quiet night is one everybody learns to ignore.
-- ============================================================

do $$
declare
  v_url text;
  v_secret text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — enable it under Database > Extensions, then re-run.';
    return;
  end if;
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net not installed — enable it under Database > Extensions, then re-run.';
    return;
  end if;

  select decrypted_secret into v_url
  from vault.decrypted_secrets where name = 'boltpay_functions_url';
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'boltpay_cron_secret';

  if v_url is null or v_secret is null then
    raise notice 'Vault secrets boltpay_functions_url / boltpay_cron_secret missing — skipping schedule.';
    return;
  end if;

  perform cron.unschedule('boltpay-health')
  where exists (select 1 from cron.job where jobname = 'boltpay-health');

  perform cron.schedule(
    'boltpay-health',
    '*/15 * * * *',
    format(
      $job$
      select net.http_post(
        url     := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', %L
        ),
        timeout_milliseconds := 30000
      );
      $job$,
      v_url || '/functions/v1/health',
      v_secret
    )
  );

  raise notice 'Scheduled boltpay-health every 15 minutes.';
end $$;


-- ============================================================
-- All Boltpay cron jobs, for reference
-- ============================================================
-- select jobname, schedule, active from cron.job order by jobname;
--
--   boltpay-health          */15 * * * *   health checks + alerts
--   boltpay-reconcile       10 4 * * *     BTCPay vs ledger
--   prune-webhook-events    20 3 * * *     90-day webhook retention
--   ledger-backup-trigger   5 11 * * *     GitHub ledger snapshot
--   daily-report-trigger    10 18 * * *    daily_stats archive
