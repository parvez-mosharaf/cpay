-- ============================================================
-- Boltpay — daily-report cron trigger
-- ============================================================
-- This file did not exist. ledger-backup had a trigger committed;
-- daily-report's was only ever set up by hand in the dashboard, so
-- there was no record of what it sends — and when CRON_SECRET was
-- rotated, nothing in the repo showed that this job still had the
-- old value baked into it and had started returning 401 every night.
--
-- Requires the same Vault secrets as ledger-backup:
--   select vault.create_secret('<CRON_SECRET>', 'boltpay_cron_secret');
--   select vault.create_secret('https://YOUR-PROJECT.supabase.co',
--                              'boltpay_functions_url');
-- ============================================================

select cron.unschedule('daily-report-trigger')
where exists (select 1 from cron.job where jobname = 'daily-report-trigger');

select cron.schedule(
  'daily-report-trigger',
  -- 18:10 UTC = 00:10 Dhaka. Runs just after the Bangladesh day rolls
  -- over, so the day it closes out is actually complete. The function
  -- recomputes the last 3 days on every run, so a night the job misses
  -- is filled in automatically by the next one.
  '10 18 * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets
             where name = 'boltpay_functions_url') || '/functions/v1/daily-report',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
                         where name = 'boltpay_cron_secret')
    )
  );
  $$
);
