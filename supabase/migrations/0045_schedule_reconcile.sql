-- ============================================================
-- CPAY — 0045: Schedule the reconciliation job
-- ============================================================
-- Runs the reconcile function once a day and alerts if BTCPay and the
-- CPAY ledger disagree about what settled.
--
-- Timing: 04:10 UTC (10:10 Dhaka). That is well after the 5pm Dhaka
-- cycle it reconciles has closed, and clear of daily-report (18:10 UTC),
-- ledger-backup (11:05 UTC) and prune-webhook-events (03:20 UTC), so no
-- two jobs contend for the same locks.
--
-- It reconciles the PREVIOUS cycle by default. A cycle still in progress
-- always looks short, and an alert that cries wolf every morning is an
-- alert everyone learns to ignore.
--
-- Reads its secrets from Vault, the same way the other cron triggers
-- here do, so the URL and CRON_SECRET are not duplicated into a schedule
-- definition where they would drift.
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
  from vault.decrypted_secrets where name = 'cpay_functions_url';
  select decrypted_secret into v_secret
  from vault.decrypted_secrets where name = 'cpay_cron_secret';

  if v_url is null or v_secret is null then
    raise notice 'Vault secrets cpay_functions_url / cpay_cron_secret are missing — skipping schedule.';
    return;
  end if;

  -- Unschedule first so re-running this migration cannot stack duplicates.
  perform cron.unschedule('cpay-reconcile')
  where exists (select 1 from cron.job where jobname = 'cpay-reconcile');

  perform cron.schedule(
    'cpay-reconcile',
    '10 4 * * *',
    format(
      $job$
      select net.http_post(
        url     := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', %L
        ),
        timeout_milliseconds := 120000
      );
      $job$,
      -- cpay_functions_url is the project base URL; the existing
      -- ledger-backup and daily-report triggers append '/functions/v1/...'
      -- to it the same way. Leaving that off would POST to a 404.
      v_url || '/functions/v1/reconcile?days=1',
      v_secret
    )
  );

  raise notice 'Scheduled cpay-reconcile at 04:10 UTC daily.';
end $$;


-- ============================================================
-- Check what is scheduled
-- ============================================================
-- select jobname, schedule, active from cron.job order by jobname;
--
-- Expect four CPAY jobs:
--   cpay-reconcile       10 4 * * *
--   prune-webhook-events    20 3 * * *
--   (plus your existing daily-report and ledger-backup jobs)
