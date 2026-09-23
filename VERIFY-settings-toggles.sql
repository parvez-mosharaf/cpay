-- ============================================================
-- Why a Settings toggle might not be "working properly"
-- ============================================================
-- Checked everything reachable from the code and found no bug:
--   - app_settings.key is a real PRIMARY KEY, so .upsert() correctly
--     updates the existing row rather than duplicating it
--   - the read policy (0027) is `is_admin() OR key IN (...)` — an
--     admin session reads every key regardless of the list
--   - the write policy (0002) is `FOR ALL USING (is_admin())` with no
--     explicit WITH CHECK — Postgres reuses USING for that, so an
--     admin's INSERT/UPDATE is allowed the same way
--   - saveGlobalToggle() / loadSettings() round-tripped correctly in a
--     browser test against a mocked Supabase client
--
-- Run this against the REAL database to see what a mock cannot show.
-- ============================================================

select
  key,
  value,
  jsonb_typeof(value) as value_type,
  updated_at
from app_settings
where key in (
  'auto_withdraw_enabled',
  'public_feed_enabled',
  'hide_small_payments_enabled',
  'hide_small_payments_threshold',
  'manual_withdrawals_enabled'   -- new in this round; expect this row to be missing until 0058 runs
)
order by key;

-- Expect exactly one row per key, value_type = 'boolean' for the three
-- *_enabled keys (not 'string' — a value saved as the text "true"
-- rather than the JSON boolean true would break every `= true` check
-- silently, since 'true'::jsonb and '"true"'::jsonb are different
-- values). If a key is MISSING entirely, that migration never ran here.

-- ============================================================
-- The RLS policies themselves, as this database actually has them —
-- not as the migration files say they should be
-- ============================================================
select polname, cmd, permissive, qual, with_check
from pg_policies
where tablename = 'app_settings'
order by polname;

-- Expect:
--   "settings admin write"   cmd=ALL    qual=is_admin()
--   "settings creator read"  cmd=SELECT qual=(is_admin() OR key = ANY(...))
--   "settings public read"   cmd=SELECT qual=(key = ANY(...))
--
-- If "settings admin write" is missing entirely, or its `cmd` is
-- something narrower than ALL, that is the bug: writes would then fall
-- through to no matching policy and be silently refused.
