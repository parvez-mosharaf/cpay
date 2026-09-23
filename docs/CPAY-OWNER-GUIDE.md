# CPAY Owner Guide — new project only

এই গাইডটি নতুন `cpay` project-এর জন্য। পুরনো CPAY production project,
তার Supabase database, BTCPay store বা Cloudflare route-এ এই ধাপগুলো চালাবেন না।

## Current boundary

- GitHub: `parvez-mosharaf/cpay`
- Supabase: the new `cpay` project only
- Cloudflare: the separate `cpay` Workers & Pages project
- Old production: unchanged and out of scope
- Public browser configuration: `public/config.js` contains only the Supabase URL
  and anon key. Never add a service-role key, database password, BTCPay token,
  webhook secret or GitHub token to this file.

## Phase 1 delivered locally

- CPAY branding and separate site/payment favicons
- Freelancer/Reseller application choice at signup
- Pending-account gate until admin approval
- Admin application queue with approve, reject and suspend actions
- Per-role auto-approval switches in the admin panel
- Backward-compatible role mapping:
  - database `creator` → user-facing **Freelancer**
  - database `moderator` → user-facing **Reseller**
- A receiving-only Bitcoin address book with multiple QR codes
- Five payment-link layouts, including the new Focus and Receipt designs
- Payer-facing final-price disclosure for link markup
- Safe on-chain foundation: address validation and QR storage only; no payout
  signing or on-chain withdrawal is enabled by this phase
- Admin 360° profile workspace snapshot with payment, withdrawal, domain and audit timeline
- Withdrawal incident freeze now blocks both manual requests and settlement auto-queues
- Admin emergency stops for new customer payments and new withdrawals, enforced server-side
- Per-profile permission matrix with server-side feature flags for links, withdrawals, Lightning and on-chain QR
- Verification state, verification notes and guarded bulk account actions for admins
- Advanced per-profile invoice and withdrawal limits with Dhaka-day payout thresholds
- Audited profile emergency suspension that hides public payments and stops auto-withdrawals
- Read-only global Audit tab with action, actor, subject and before/after filters

## Apply the database safely

### Option A — Supabase SQL Editor

1. Open the **new CPAY Supabase project**.
2. Take a backup/snapshot if the project already has data.
3. Run the files in `supabase/migrations/` in numeric order.
4. The new project currently ends at migration `0091`.
5. Confirm the following objects exist:

```sql
select to_regclass('public.account_applications');
select to_regclass('public.onchain_addresses');
select proname
from pg_proc
where proname in (
  'admin_review_account_application',
  'onchain_address_create',
  'onchain_address_update',
  'admin_get_profile_workspace'
);
```

Do not run these migrations against the previous production project.

### Option B — Supabase CLI

From the repository root, link the CLI to the new project and push only after
checking the target project reference:

```bash
supabase link --project-ref riumaeihemgznvgattoc
supabase db push
```

If the CLI asks for a database password, enter it locally in the CLI prompt.
Do not send it in chat or commit it to Git.

## Make the first CPAY admin

Create a test account through the new CPAY site. Because manual approval is the
default, temporarily promote that first owner account in the new Supabase SQL
Editor:

```sql
update public.profiles
set role = 'admin', account_status = 'active'
where email = 'YOUR-CPAY-OWNER-EMAIL';
```

Then log out and back in. The owner should land on `admin.html`.

## First functional test

Use a separate test email, not a real customer:

1. Register as **Freelancer**.
2. Confirm the account is pending.
3. In Admin → Applications, approve it.
4. Log in again and create a payment link.
5. Register a second test account as **Reseller**.
6. Approve it and verify the user-facing label is Reseller.
7. In Cash out → On-chain receiving addresses, add one testnet address.
8. Add a second address with a different label and verify that both QR codes
   render and can be copied.
9. Confirm a pending account cannot create links or request withdrawals.

Use Bitcoin testnet addresses for UI testing. Do not enter a production payout
address until the network and withdrawal design have been reviewed.

## Deploy the frontend

The Cloudflare project should point to the new `parvez-mosharaf/cpay` repository,
not the old repository:

- Build command: `npm run build`
- Deploy command: `npx wrangler deploy`
- Root directory: `/`

Before the first deploy, run:

```bash
python3 ci/check_frontend.py
npm run build
```

The local sandbox may not have the optional Amplitude package installed. If
`npm run build` fails with a missing `@amplitude/unified` package, install
dependencies in the Cloudflare build environment or run `npm install` locally;
do not edit `node_modules` or commit generated secrets.

## BTCPay comes after onboarding

Create a separate CPAY BTCPay store and testnet/staging flow first. The safe
order is:

1. Create the store and connect the Lightning node.
2. Configure the CPAY invoice currency and expiry.
3. Deploy `create-invoice` and `btcpay-webhook`.
4. Add the CPAY webhook URL and a new webhook secret.
5. Test invoice creation, settlement, expiry and duplicate webhook delivery.
6. Only then test Lightning withdrawals.
7. On-chain withdrawals remain disabled until address validation, provider
   behavior, fees, confirmations, retry, idempotency and an emergency stop are
   verified in staging.

Never reuse the old project's BTCPay token, webhook secret or production store
without an explicit migration plan.

## What happens next

1. Apply migrations `0067` through `0091` to the new CPAY Supabase project.
2. Deploy the new Edge Functions and configure secrets in Supabase.
3. Push the local CPAY changes to the new GitHub repository.
4. Run the onboarding, link, invoice and QR test checklist.
5. Review the admin profile workspace, permission matrix, domain assignment, audit timeline and payment themes.
6. Use `docs/BTCPAY-STAGING-RUNBOOK.md` to complete BTCPay staging and withdrawal hardening.
7. Review Admin → Health and `docs/PRODUCTION-READINESS.md`.
8. Only after staging passes, consider production money movement.
