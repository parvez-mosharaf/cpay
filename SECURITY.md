# Security Policy

## Reporting a vulnerability

Email the maintainer directly rather than opening a public issue. Include
enough detail to reproduce (endpoint, payload, expected vs. actual). Expect an
acknowledgement within a few days.

Please do not test against the production instance with real payments. Use a
BTCPay testnet store.

## What is and is not a secret in this repo

Safe to commit — these are public by design:

- `public/config.js` — the Supabase project URL and **anon** key. The anon key
  identifies the project; it grants nothing on its own. Every real permission
  boundary is a Row Level Security policy or a `SECURITY DEFINER` function in
  `supabase/migrations/`.
- The same two values inlined at the top of `worker/og-preview-worker.js`.

Never commit:

- `SUPABASE_SERVICE_ROLE_KEY` — bypasses RLS completely.
- `BTCPAY_API_KEY`, `BTCPAY_WEBHOOK_SECRET`, `BTCPAY_STORE_ID`.
- `CRON_SECRET`, `GITHUB_TOKEN`.

All of the above belong in Supabase Edge Function secrets. See `docs/ENV_VARS.md`.

## Trust boundaries worth knowing before you deploy

- **The browser is not a boundary.** Anything the dashboard or admin panel can
  do, a user can do by hand against PostgREST with the anon key. Every rule
  that matters is enforced in SQL: `request_withdrawal()` owns the balance
  check, `guard_profile_updates()` owns which profile columns a creator may
  change, `enforce_link_limit()` and `validate_link_slug()` own link creation.
- **The service role bypasses RLS entirely.** The `/process-withdrawal` and
  `/admin-mark-settled` routes therefore verify the caller's admin role in
  code, via `verifyAdminCaller()`, before doing anything.
- **Withdrawal state transitions are claimed atomically.** Moving a withdrawal
  to `paid`, `processing` or `rejected` goes through
  `system_claim_withdrawal()`, which only succeeds from `pending`/`approved`.
  This is what stops a double-click from sending two real Lightning payouts.
- **`payments` is readable by anon only inside the payment window** so the
  public invoice page can receive Realtime updates. Rows older than two hours
  are invisible, and the column grant hides `user_id` and internal ids.
- **Creator-supplied text reaches the admin panel.** Display names and
  withdrawal destinations are attacker-controlled; the admin panel escapes
  every one of them before rendering. If you add a new field to that panel,
  escape it.
- **Webhook deliveries are idempotent.** `webhook_events.delivery_id` is
  claimed before any payment row is touched, so BTCPay retries and
  concurrent duplicate deliveries are acknowledged without reprocessing.
  Amounts additionally cannot be negative (or zero when requested) at the
  database level — CHECK constraints, not just application code.
- **Browser origins are restricted on the money endpoints.** `user-withdraw`
  and the admin routes on `btcpay-webhook` only emit CORS headers for
  domains registered (and active) in `site_domains` — the admin panel's own
  domain registry, cached for 5 minutes in the function. An optional
  `ALLOWED_ORIGINS` secret can add hosts that should stay out of that
  registry. `create-invoice` keeps a wildcard on purpose (payment links
  live on creators' own domains) and is defended by its per-link rate
  limit instead. `public/_headers` adds CSP and `frame-ancestors 'none'`
  (anti-clickjacking) to every page.

## After cloning or forking

Rotate every secret. The repository history contains a `CRON_SECRET` that was
committed in `ledger-backup-trigger.sql`, and the `ledger-backups/*.json`
snapshots contain real customer email addresses from the original deployment.
Treat both as public.

**Update (Aug 2026):** the `ledger-backups/` snapshots have been removed from
the working tree and the path is now in `.gitignore`. The nightly backup still
runs — it commits straight to the private GitHub repo configured via
`GITHUB_OWNER`/`GITHUB_REPO`, never into this one. If your fork's Git history
still contains either the snapshots or the old CRON_SECRET, purge the history
(`git filter-repo`) and rotate the secret per `docs/ENV_VARS.md` — deleting
the files from the latest commit does NOT remove them from history.
