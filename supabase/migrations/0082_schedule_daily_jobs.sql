-- CPAY: install the two jobs that populate daily_stats and archive the
-- ledger. These were previously supplied only as manual SQL files, which
-- left a fresh project with a permanently unhealthy cron check.

do $$
declare
  v_url text;
  v_secret text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron is not installed; daily jobs were not scheduled.';
    return;
  end if;

  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    raise notice 'pg_net is not installed; daily jobs were not scheduled.';
    return;
  end if;

  select decrypted_secret
    into v_url
    from vault.decrypted_secrets
   where name = 'cpay_functions_url';

  select decrypted_secret
    into v_secret
    from vault.decrypted_secrets
   where name = 'cpay_cron_secret';

  if v_url is null or v_secret is null then
    raise notice 'Vault secrets cpay_functions_url/cpay_cron_secret are missing; daily jobs were not scheduled.';
    return;
  end if;

  perform cron.unschedule('daily-report-trigger')
   where exists (
     select 1 from cron.job where jobname = 'daily-report-trigger'
   );

  perform cron.schedule(
    'daily-report-trigger',
    '10 18 * * *',
    format(
      $job$
      select net.http_post(
        url := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', %L
        ),
        timeout_milliseconds := 120000
      );
      $job$,
      v_url || '/functions/v1/daily-report',
      v_secret
    )
  );

  perform cron.unschedule('ledger-backup-trigger')
   where exists (
     select 1 from cron.job where jobname = 'ledger-backup-trigger'
   );

  perform cron.schedule(
    'ledger-backup-trigger',
    '15 18 * * *',
    format(
      $job$
      select net.http_post(
        url := %L,
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', %L
        ),
        timeout_milliseconds := 120000
      );
      $job$,
      v_url || '/functions/v1/ledger-backup',
      v_secret
    )
  );
end $$;
