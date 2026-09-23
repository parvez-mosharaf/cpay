-- ============================================================
-- CPAY — reseller-digest cron trigger
-- 17:00 Asia/Dhaka = 11:00 UTC (Bangladesh has no DST)
--
-- Requires the same Vault secrets as daily-report:
--   select vault.create_secret('<CRON_SECRET>', 'cpay_cron_secret');
--   select vault.create_secret('https://YOUR-PROJECT.supabase.co',
--                              'cpay_functions_url');
--
-- One BTCPay shop is enough. Link cost_percent is set by the
-- freelancer or locked by their reseller; it is not a shop setting.
-- Admin profit is platform_fee on settled earnings, not shop spread.
-- ============================================================

select cron.unschedule('reseller-digest-trigger')
where exists (select 1 from cron.job where jobname = 'reseller-digest-trigger');

select cron.schedule(
  'reseller-digest-trigger',
  '0 11 * * *',
  $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets
             where name = 'cpay_functions_url') || '/functions/v1/reseller-digest',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets
                         where name = 'cpay_cron_secret')
    )
  );
  $$
);
