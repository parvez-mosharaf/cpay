-- 0035_revoke_truncate_grants.sql
-- ALREADY APPLIED to project ohwzmxwsphsfzudmlins on 2026-09-01 (owner approved).
-- Committed for history only — do NOT re-run as if pending.
--
-- TRUNCATE is not filtered by RLS. Roles anon and authenticated held it on all 12
-- public tables, so any signed-in user could have wiped payments/profiles/withdrawals.
-- REFERENCES and TRIGGER go too — client roles never need them.
do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname='public' loop
    execute format('revoke truncate, references, trigger on public.%I from anon, authenticated', t.tablename);
  end loop;
end $$;
