# Staging

Somewhere to run a migration before it touches real money.

Two of the worst moments in this project would have been caught by a
staging environment, and neither was expensive to cause:

- a migration that changed a function's return type without dropping it
  first. Supabase runs the whole file in one transaction, so it rolled
  back — leaving the admin panel calling functions that no longer
  existed, in production, with no warning until someone opened it.
- a migration numbered the same as one already applied, which failed on
  the bookkeeping insert *after* the DDL had run, leaving the history
  and the schema disagreeing.

CI now catches both. Staging catches the third category CI cannot: a
migration that applies perfectly to an *empty* database and does
something unwanted to one with real rows in it.

---

## What you need

A second Supabase project. Free tier is enough — staging holds test data
and can pause when idle.

Name it something unmistakable, e.g. `cpay-staging`. You will have
both dashboards open at once and they look identical.

---

## One-time setup

**1. Create the project** and note its URL and anon key.

**2. Apply every migration in order.** In the staging SQL Editor, run
`supabase/migrations/*.sql` from `0001` upward. This also confirms the
sequence still applies cleanly from scratch — the same thing CI checks,
but against a real Supabase rather than a bare Postgres.

**3. Enable the extensions** the cron migrations need:
Database → Extensions → `pg_cron`, `pg_net`.

**4. Vault secrets**, so the schedule migrations do not skip:

```sql
select vault.create_secret('https://YOUR-STAGING.supabase.co', 'cpay_functions_url');
select vault.create_secret('any-value-you-like', 'cpay_cron_secret');
```

**5. Edge Function secrets.** Copy the names from `docs/ENV_VARS.md`,
but point them at test resources:

| Secret | Staging value |
|---|---|
| `BTCPAY_URL` | A BTCPay **testnet** store, or leave unset to test the failure path |
| `BTCPAY_API_KEY*` | Testnet keys only |
| `GITHUB_REPO` | A throwaway repo, or unset so ledger-backup no-ops |
| `ALERT_WEBHOOK_URL` | A separate channel, so staging noise never reaches the real one |
| `CRON_SECRET` | Different from production |

**Never point staging at the production BTCPay store.** A test payout
run against a live Lightning node spends real sats.

**6. A staging copy of the site.** Either a second Cloudflare Pages
project on a `staging` branch, or run it locally — the site is static
with no build step:

```bash
cd public && python3 -m http.server 8080
```

with a `config.js` holding the staging URL and anon key.

---

## Using it

Before any migration reaches production:

1. Apply it on staging.
2. Open the panels and click through whatever it touched.
3. Then production.

For a migration that rewrites existing rows — a backfill, a column
change, a data migration — do one more thing first: put representative
rows in staging. A migration that works on an empty table and mangles a
full one is exactly the case CI cannot see.

```sql
-- On staging, after applying the migrations: a handful of rows to act on.
insert into auth.users (id, email) values (gen_random_uuid(), 'test@example.com');
-- then sign up through the staging site, which fires handle_new_user()
```

Signing up through the site is better than inserting profiles by hand —
it exercises the trigger, the defaults and the RLS policies, which is
most of what a migration can break.

---

## CPAY operations preflight

After migrations `0079` and `0080`, Admin → Health → **Run preflight** and the
**Staging sign-off ledger** provide a
read-only snapshot of active shops, payment domains, orphan links, pending
and processing withdrawals, profile states, emergency flags and receiving
QR records. It is a configuration check, not a BTCPay network probe.

Use `docs/BTCPAY-STAGING-RUNBOOK.md` for invoice, webhook, duplicate delivery
and payout tests. Use `docs/PRODUCTION-READINESS.md` before any production
money movement.

## Keeping the two in step

Staging drifts. When it does, the safest fix is to rebuild it rather
than reconcile it: delete the project, create it again, re-run the
migrations. It holds nothing you need to keep, and a rebuilt staging is
the only kind you can trust.

Check what has been applied where:

```sql
select version, name from supabase_migrations.schema_migrations
order by version desc limit 20;
```

Run it on both. If staging is behind, apply the difference. If staging
is *ahead*, something was applied there and never promoted — find out
what before touching production.
