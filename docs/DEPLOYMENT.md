# Boltpay — Deployment Checklist

## 1. Supabase

- [ ] Create a new Supabase project
- [ ] Run migrations in order from `supabase/migrations/`, **0001 → 0057**,
      one file at a time in the SQL Editor. 0018 is required — without it the
      database has a privilege-escalation hole and two conflicting balance
      definitions.
- [ ] Run the verification queries at the bottom of this file
- [ ] Deploy the Edge Functions:

      supabase functions deploy btcpay-webhook  --no-verify-jwt
      supabase functions deploy create-invoice  --no-verify-jwt
      supabase functions deploy user-withdraw
      supabase functions deploy daily-report    --no-verify-jwt
      supabase functions deploy ledger-backup   --no-verify-jwt
      supabase functions deploy og-image        --no-verify-jwt
      supabase functions deploy reconcile       --no-verify-jwt
      supabase functions deploy health          --no-verify-jwt

      Why the flags differ:
        * btcpay-webhook  — BTCPay cannot send a Supabase JWT. It authenticates
                            with an HMAC signature instead, checked in code.
                            Its two admin routes verify an admin JWT themselves.
        * create-invoice  — paying customers have no account, so there is no
                            JWT to send. Abuse is capped by a per-link rate
                            limit inside the function.
        * user-withdraw   — always called by a signed-in creator, so leave JWT
                            verification ON.
        * daily-report,
          ledger-backup   — called by pg_cron, which sends `x-cron-secret`,
                            not a JWT. Both fail closed if CRON_SECRET is unset.

- [ ] Add all secrets listed in `docs/ENV_VARS.md`
- [ ] Create your own account through the app, then in the SQL Editor:
      `update profiles set role = 'admin' where email = 'you@example.com';`
      (This has to be done in SQL. A creator cannot promote themselves — 0018
      added a trigger that blocks it.)
- [ ] Schedule the cron jobs. Store the secret in Vault rather than inline:

      select vault.create_secret('<random-secret>', 'boltpay_cron_secret');
      select vault.create_secret('https://YOUR-PROJECT.supabase.co', 'boltpay_functions_url');

      Then run `supabase/functions/ledger-backup/ledger-backup-trigger.sql`.

## 2. BTCPay Server

- [ ] Create a Store, connect a Lightning node
- [ ] Add a webhook: URL = `https://YOUR-PROJECT.supabase.co/functions/v1/btcpay-webhook`,
      secret = same value as `BTCPAY_WEBHOOK_SECRET`
- [ ] Subscribe the webhook to at least: InvoiceSettled, InvoiceExpired,
      InvoiceInvalid, InvoiceProcessing, InvoiceReceivedPayment
- [ ] Store invoice currency must be **USD** — the webhook only accepts a
      settled amount from BTCPay when the invoice currency matches the column
      it is being written into, and falls back to the requested amount otherwise
- [ ] Enable the Payout Processor plugin (needed for the automated
      Lightning payout path)
- [ ] Set invoice expiration to 60 minutes, matching `create-invoice`

## 3. Frontend hosting (Cloudflare Pages, or GitHub Pages)

- [ ] Push this repo to a GitHub repository. **Make it private** if you intend
      to keep using the `ledger-backup` function — it commits ledger snapshots
      back into the repo.
- [ ] Copy `public/config.example.js` to `public/config.js` and fill in your
      Supabase URL and anon key. Both values are public by design, so this file
      is committed rather than gitignored.
- [ ] Point your host at the `public/` folder as the site root
- [ ] `public/404.html` doubles as the payment page: any unmatched path is
      treated as a payment slug, so the host must serve it for 404s.
      `wrangler.jsonc` already sets `not_found_handling: 404-page`.
- [ ] Add a `CNAME` file inside `public/` containing your domain if using
      GitHub Pages

## 4. Cloudflare

- [ ] Confirm your domain's nameservers point to Cloudflare (shows as "Active")
- [ ] Deploy `worker/og-preview-worker.js` (`wrangler deploy` from `worker/`)
- [ ] Add the route so the worker sees payment slugs, e.g. `yourdomain.com/*`
      (Worker → Settings → Triggers → Add route). The worker passes through
      anything that is not a crawler hitting a single-segment slug.
- [ ] SSL/TLS mode = Full (strict)
- [ ] Register each domain in the admin panel's Domains tab so themes and
      root-domain routing work

## 5. End-to-end test

- [ ] Register a test account, log in, create a payment link
- [ ] Send a small BTCPay testnet Lightning payment to a generated invoice
- [ ] Confirm the invoice page flips to "settled" live, with no refresh
- [ ] Confirm the creator dashboard's "available" figure matches
      `select * from get_balance_for('<user-id>')`
- [ ] Submit a withdrawal request as the test user
- [ ] In the admin panel: approve/reject a pending request, and mark a
      bKash/Nagad request paid manually
- [ ] Double-click "Force BTCPay Payout" — the second click must return
      "Already processed", not a second payout
- [ ] Paste a payment link into WhatsApp and confirm the link preview renders

## 5b. This update's new pieces (migration 0033 + headers + alerts)

After deploying the current code:

- [ ] Run migration **0033** (`0033_webhook_idempotency_and_integrity.sql`) in
      the SQL editor. Verify:
      `select count(*) from webhook_events;` → must succeed (table exists)
- [ ] Set the two new Edge Function secrets (see `docs/ENV_VARS.md`):
      `ALLOWED_ORIGINS` = your site domain(s), and `ALERT_WEBHOOK_URL` = a
      Discord/Slack webhook for payment-failure alerts
- [ ] `wrangler deploy` — this publishes `public/_headers` automatically.
      Verify: `curl -sI https://<your-domain> | grep -i frame-ancestors`
      → expect `frame-ancestors 'none'`
- [ ] Optional: schedule webhook-event pruning in the SQL editor:
      `select cron.schedule('prune-webhook-events', '30 11 * * *',
        $$select public.prune_webhook_events()$$);`

## 6. Security regressions to re-check after any migration

Run these as a **non-admin** creator. Every one must fail:

```sql
-- must fail: privilege escalation
update profiles set role = 'admin' where id = auth.uid();

-- must fail: zeroing your own fee
update profiles set withdrawal_fee_percent = 0 where id = auth.uid();

-- must fail: minting a withdrawal without a balance check
insert into withdrawals (user_id, amount_requested, fee_percent,
  amount_after_fee, method, destination, status)
values (auth.uid(), 999999, 0, 999999, 'bkash', 'x', 'approved');

-- must fail: editing an admin's message in your own thread
update support_messages set message = 'x'
where user_id = auth.uid() and sender = 'admin';

-- must fail: taking a reserved slug
insert into payment_links (user_id, slug) values (auth.uid(), 'admin');

-- must return only your own rows
select count(*) from payments;
```

## Verification queries

```sql
-- RLS enabled on every table
select relname, relrowsecurity
from pg_class
where relname in ('profiles','payment_links','payments','withdrawals',
                  'app_settings','daily_stats','support_messages','site_domains');

-- Policies
select tablename, policyname, cmd, qual, with_check
from pg_policies where schemaname = 'public' order by tablename;

-- Every SECURITY DEFINER function must pin search_path
select p.proname, p.prosecdef, p.proconfig
from pg_proc p
where p.pronamespace = 'public'::regnamespace and p.prosecdef
order by p.proname;
-- proconfig must contain search_path=public for all of them

-- Guard triggers are installed
select tgname, tgrelid::regclass from pg_trigger
where tgname in ('trg_guard_profile_updates','trg_guard_withdrawal_updates',
                 'trg_guard_message_updates','trg_enforce_link_limit',
                 'trg_validate_link_slug');

-- Constraints
select conrelid::regclass, conname, pg_get_constraintdef(oid)
from pg_constraint
where conrelid in ('public.payments'::regclass, 'public.withdrawals'::regclass)
  and contype = 'c';

-- request_withdrawal must NOT be executable by anon
select grantee, privilege_type from information_schema.routine_privileges
where routine_name in ('request_withdrawal','system_queue_withdrawal',
                       'system_claim_withdrawal','get_balance_for');

-- Realtime publication includes payments
select schemaname, tablename from pg_publication_tables
where pubname = 'supabase_realtime';
```
