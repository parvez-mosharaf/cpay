-- ============================================================
-- Boltpay — ledger-backup cron trigger
-- ============================================================
-- The previous version of this file had the live project URL and the
-- real CRON_SECRET written inline, and it is committed to the repo.
-- That secret must be treated as burned: generate a new one, set it as
-- the CRON_SECRET Edge Function secret, and store it in Vault rather
-- than pasting it into SQL that lives in Git.
--
-- Setup (run once, in the SQL editor):
--   select vault.create_secret('<new-random-secret>', 'boltpay_cron_secret');
--   select vault.create_secret('https://YOUR-PROJECT.supabase.co', 'boltpay_functions_url');
-- ============================================================
select cron.unschedule('ledger-backup-trigger')
where exists (select 1 from cron.job where jobname = 'ledger-backup-trigger');
select cron.schedule(
'ledger-backup-trigger',
'5 11 * * *',  -- runs 5 minutes after daily-report, so that day's stats are already written
$$
select net.http_post(
url := (select decrypted_secret from vault.decrypted_secrets
where name = 'boltpay_functions_url') || '/functions/v1/ledger-backup',
headers := jsonb_build_object(
'Content-Type', 'application/json',
'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
where name = 'boltpay_cron_secret')
)
);
$$
);
