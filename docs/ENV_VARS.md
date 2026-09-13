# Environment Variables Checklist

No real secret values belong in this repository. Fill these in on each
platform's dashboard.

## Supabase Edge Function secrets

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are
injected automatically into every function. The rest you add yourself under
Dashboard → Edge Functions → Secrets (they are project-wide, not per-function).

Used by `btcpay-webhook`, `create-invoice`, `user-withdraw`:

- [ ] `BTCPAY_URL` — e.g. https://your-btcpay-server.com (no trailing slash)
- [ ] `BTCPAY_API_KEY` — store API key with invoice + payout permissions
- [ ] `BTCPAY_STORE_ID`
- [ ] `BTCPAY_WEBHOOK_SECRET` — from BTCPay → Store → Webhooks.
      **Required.** The webhook rejects every request if this is unset, rather
      than HMAC-ing against an empty string that anyone could reproduce.

Used by `daily-report` and `ledger-backup`:

- [ ] `CRON_SECRET` — any long random string. Both functions refuse all
      requests if it is unset.

New in this update:

- [ ] `ALERT_WEBHOOK_URL` — a Discord/Slack/Telegram-bot webhook URL. When a
      BTCPay payout fails, BTCPay is unreachable, the ledger backup cannot
      commit, or the daily report skips a day, the function posts a `🚨`
      message here. Payment failures wake a human up instead of sitting in a
      log file. Unset = alerts are silently skipped.

CORS origins — **no secret needed**. The allowed browser origins for
`btcpay-webhook` (admin routes) and `user-withdraw` are read live from the
`site_domains` table — the same registry the admin panel manages. Add a
domain in the admin panel and it is allowed within ~5 minutes (cache
window); deactivate it and it stops working. No secret edit, no redeploy.

- [ ] `ALLOWED_ORIGINS` *(optional, merged on top of site_domains)* —
      comma-separated list, e.g. `https://boltpay.example.com,https://pay.example.com`.
      Only use this for a domain you do NOT want visible in the admin
      panel's domain registry. `create-invoice` keeps its wildcard by
      design — payment links are embedded on creator-owned domains, and it
      is defended by a per-link rate limit instead.

Used by `ledger-backup` only:

- [ ] `GITHUB_TOKEN` — a fine-grained token with Contents: write on **one**
      private repository, nothing else
- [ ] `GITHUB_OWNER`
- [ ] `GITHUB_REPO` — must be private. This function commits a full ledger
      snapshot into it.

## public/config.js (client-side, public by design)

- [ ] `SUPABASE_URL`
- [ ] anon key (the `SUPABASE_ANON_KEY` constant inside the file)

Copy `public/config.example.js` to `public/config.js` and fill these in. Both
values are meant to be visible in the browser, so this file is committed —
there is nothing to hide. Everything that actually protects data is an RLS
policy or a `SECURITY DEFINER` function in `supabase/migrations/`.

## Cloudflare Worker

`worker/og-preview-worker.js` has `SUPABASE_URL` and the anon key inline near
the top. Same reasoning as above: safe to keep there, or move to Worker
environment variables under Settings → Variables if you prefer.

## Rotation

If any of these has ever been committed, pushed or pasted into a shared
channel, rotate it. In particular, the `CRON_SECRET` that used to be inline in
`supabase/functions/ledger-backup/ledger-backup-trigger.sql` is in this repo's
Git history and must be considered public.

**How to rotate CRON_SECRET (5 minutes):**

1. Generate a new one: `openssl rand -hex 32`
2. Dashboard → Edge Functions → Secrets → update `CRON_SECRET`
3. SQL editor → `select vault.create_secret('<the-same-new-value>', 'boltpay_cron_secret');`
   (create it under the same name — `vault.create_secret` upserts by name,
   so both cron triggers keep working with no SQL changes)
4. Confirm the next nightly run in the ledger-backup function logs.
