# CPAY production-readiness checklist

CPAY is a separate system. Completing this checklist must not require a
change to the previous production project.

## Repository and database

- [ ] `python3 ci/check_frontend.py` passes.
- [ ] `npm run build` passes.
- [ ] A backup or snapshot exists for the new CPAY Supabase project.
- [ ] Migrations `0001` through `0080` apply in order on staging.
- [ ] Migration history and the live schema agree.
- [ ] RLS and security-definer search-path checks pass.
- [ ] The owner has recorded the rollback or restore plan.

## Identity and admin control

- [ ] An admin can approve and suspend test Freelancers and Resellers.
- [ ] Pending, rejected and suspended profiles cannot create public payment
  links or request payouts.
- [ ] Profile controls, domains, themes, limits, feature flags and audit
  entries have been exercised.
- [ ] Emergency suspension hides public payment pages and stops auto-queue
  behavior.

## BTCPay and webhooks

- [ ] CPAY has its own BTCPay store and credentials.
- [ ] Invoice creation, settlement, expiry and duplicate webhook delivery
  passed in staging.
- [ ] Public payment and QR invoice controls pass keyboard/screen-reader
  checks; `python3 ci/check_frontend.py` reports payment accessibility and
  QR ownership guards as green.
- [ ] Webhook signature validation is enabled.
- [ ] The live health function reports every active shop correctly.
- [ ] The operator knows where to inspect an ambiguous `processing` payout.

## Withdrawals

- [ ] Lightning Address resolution, timeout, retry and idempotency passed.
- [ ] Manual and automatic withdrawal freezes were tested.
- [ ] Per-profile invoice, single-withdrawal and daily limits were tested.
- [ ] On-chain withdrawals remain disabled unless separately approved with
  evidence for address validation, fees, confirmations, retries and rollback.

## Cloudflare and public site

- [ ] Cloudflare points to the new `parvez-mosharaf/cpay` repository.
- [ ] Build command is `npm run build`; deploy command is
  `npx wrangler deploy`.
- [ ] Separate site and payment favicons render on the intended domains.
- [ ] Headers, HTTPS, custom domains, OG preview routing and CORS were
  checked.
- [ ] No old CPAY URL, Supabase project reference, store ID or secret is
  present in the CPAY deployment.

## Operational sign-off

- [ ] Admin → Health preflight is reviewed.
- [ ] Admin → Health → Staging sign-off ledger is complete with evidence for
  every required gate.
- [ ] The scheduled health endpoint runs with a rotated cron secret.
- [ ] Daily reconciliation, ledger backup and alert delivery were observed.
- [ ] The owner has the BTCPay staging runbook and emergency-stop procedure.
- [ ] A small, controlled production rollout is planned.

Do not call CPAY production-ready until every unchecked item has a named
owner, documented exception or completed test result.