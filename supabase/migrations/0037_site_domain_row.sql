-- 0037_site_domain_row.sql
-- ALREADY APPLIED to project ohwzmxwsphsfzudmlins on 2026-09-01 (owner approved).
-- Committed for history only — do NOT re-run as if pending.
-- app_settings.site_domain pointed at parvez.website, which no longer resolves.
-- Repointed to the primary live host. Nothing in the app currently reads this key
-- (routing uses the site_domains table), so this is housekeeping only.
update public.app_settings
   set value = '{"domain": "cpay-cash.app"}'::jsonb,
       updated_at = now()
 where key = 'site_domain';
