# CPAY BTCPay staging runbook

This runbook is for the new CPAY project only. The previous production
store, node, Supabase project and Cloudflare routes stay untouched.

## Hard boundary

- Use a separate BTCPay store and testnet or controlled test funds.
- Never paste a BTCPay token, webhook secret, node credential or Supabase
  service-role key into chat, frontend code or Git.
- Do not enable on-chain withdrawals in this phase. CPAY currently stores
  receiving addresses and QR codes only.
- Keep the emergency payment and withdrawal stops available to the operator.

## 1. Create the staging store

1. Create a separate store for CPAY staging.
2. Connect a testnet or isolated Lightning wallet.
3. Set the invoice currency, exchange-rate source and expiry.
4. Create a store API key with only the permissions needed by invoice
   creation and the payout flow being tested.
5. Add the store ID in Admin → Shops. Select the matching Edge Function
   secret name; the secret value stays in Supabase.
6. Add `BTCPAY_URL`, the matching `BTCPAY_API_KEY*`, and
   `BTCPAY_WEBHOOK_SECRET` to the staging Edge Function secrets.

Never point a staging shop at the old live store. A test payout against a
live Lightning node spends real money.

## 2. Configure the webhook

In BTCPay, create a webhook for the staging store and point it at:

```text
https://YOUR-STAGING-PROJECT.supabase.co/functions/v1/btcpay-webhook
```

Use a new webhook secret. Test invoice creation, settlement, expiry,
invalid delivery, duplicate delivery IDs and concurrent duplicate delivery.
The payment should settle once, the ledger balance should change once, and a
duplicate should be acknowledged without a second credit.

## 3. Invoice and settlement test

1. Register a staging Freelancer and approve the account.
2. Create one link for each payment theme that needs review.
3. Create and pay a small test invoice with the staging Lightning wallet.
4. Confirm the payment page and dashboard update.
5. Compare the payer-facing total, payment row, settled balance and
   `get_balance_for(...)`.
6. Let one invoice expire and confirm it does not credit the balance.

If a link has no shop, stop. Fix the shop assignment before retrying.

## 4. Withdrawal test

Start with the global emergency withdrawal stop enabled. Lift it only for a
controlled staging test.

1. Test a Lightning Address destination with a small amount.
2. Test a timeout or ambiguous provider response.
3. Confirm an unknown result remains `processing`.
4. Confirm the admin can inspect the provider result before retrying.
5. Submit the same request twice and confirm idempotency.
6. Confirm daily, per-invoice and per-profile limits are enforced.
7. Re-enable the emergency withdrawal stop and confirm both manual requests
   and settlement auto-queues are blocked.

On-chain payout signing is not part of this runbook. It remains disabled
until network, address, fee, confirmation, retry, idempotency and emergency
stop behavior have a separate staging sign-off.

## 5. Health and preflight

- Admin → Health → **Run preflight** checks safe database signals such as
  active shops, missing store IDs, payment domains, orphan links, pending
  withdrawals, processing withdrawals, profile states and emergency flags.
- Admin → Health → **Staging sign-off ledger** records evidence for each
  release gate. Complete a row only after the test has actually passed, and
  include an invoice ID, migration check, alert timestamp or other useful
  evidence. This checklist is audited and does not itself enable payments or
  withdrawals.
- The Health tab never exposes BTCPay credentials and does not call BTCPay
  from the browser.
- The scheduled `health` Edge Function remains the authoritative live check
  for BTCPay reachability, webhook freshness, cron freshness and stuck
  payouts. It requires `x-cron-secret`.

## 6. Rollback

If a staging test fails, stop new payments and withdrawals, record the
invoice or withdrawal IDs, and compare CPAY and BTCPay before retrying. Do
not reset a `processing` payout to `pending` just because a request timed
out; first confirm whether BTCPay paid it.

Production promotion requires every required gate in the sign-off ledger,
`docs/PRODUCTION-READINESS.md` and explicit owner sign-off. A green checklist
does not replace a backup, rollback plan or the final controlled-money test.