-- ============================================================
-- Why does a new creator's dashboard still show instant Lightning?
-- ============================================================
-- Every layer of this was re-checked directly against the code and all
-- four are correct:
--
--   1. profiles.auto_withdraw_enabled: `boolean default false`
--      (migration 0017) — a brand new row gets false automatically.
--   2. handle_new_user() never sets this column, so nothing overrides
--      that default.
--   3. dashboard.html only offers Lightning when BOTH the global switch
--      AND the creator's own flag are true (globalAuto && userAuto).
--   4. user-withdraw enforces the same double-check server-side, so
--      even a tampered client request is refused.
--
-- Since the code has no gap, this checks your LIVE database instead —
-- run it in the Supabase SQL Editor and read the verdict column.
-- ============================================================

with target as (
  -- Replace with the email of the creator account you tested with.
  select id, email, auto_withdraw_enabled, created_at
  from profiles
  where role = 'creator'
  order by created_at desc
  limit 5
),
global_setting as (
  select value as global_value
  from app_settings
  where key = 'auto_withdraw_enabled'
)
select
  t.email,
  t.created_at,
  t.auto_withdraw_enabled as creator_own_flag,
  g.global_value as admin_global_switch,
  case
    when g.global_value is null
      then 'app_settings has no auto_withdraw_enabled row at all — the admin panel has never saved this toggle. Open Admin > Settings > Global switches and toggle it once (even back to off) to create the row.'
    when g.global_value::text <> 'true' and t.auto_withdraw_enabled is not true
      then 'Correct: both are off. Lightning should NOT appear for this creator. If it still does, the deployed dashboard.html does not match what was delivered — check what is actually live on GitHub/Cloudflare against the file you were given.'
    when g.global_value::text = 'true'
      then 'The GLOBAL switch itself is ON in the database right now — not off. Re-check Admin > Settings; the checkbox may not have saved, or a different admin session turned it back on.'
    else 'Unexpected combination — read the two flag columns above directly.'
  end as verdict
from target t
cross join global_setting g
order by t.created_at desc;

-- ============================================================
-- If the verdict says everything in the database is correct
-- ============================================================
-- The remaining explanation is a deployment gap: the dashboard.html or
-- user-withdraw function actually running in production predates the
-- fix. Confirm by searching the LIVE dashboard.html (view source on the
-- real site) for this exact line:
--
--   const globalAuto = (appSetting?.value === true || String(appSetting?.value) === 'true');
--
-- If that line is missing, or still reads `let globalAuto = true;`
-- anywhere, the file has not been redeployed — push the current
-- dashboard.html and redeploy user-withdraw:
--
--   supabase functions deploy user-withdraw --no-verify-jwt
