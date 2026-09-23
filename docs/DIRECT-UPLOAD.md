# CPAY direct upload

This workflow is for the **new CPAY project only**. It does not touch the old
previous production site.

## 1. Prepare the frontend bundle

From the CPAY project folder:

```bash
npm install
cp public/config.example.js public/config.js
```

Edit `public/config.js` with the new CPAY Supabase URL and public anon key.
The anon key is public by design. Never place a service-role key, BTCPay token
or webhook secret in this file.

Then run:

```bash
npm run prepare:upload
```

The command builds the analytics bundle, validates the required public files,
and creates a clean `dist/` folder. Upload **the contents of `dist/`** to the
new CPAY Cloudflare Pages/Workers project using the direct-upload flow.

The bundle includes:

- public landing, login, registration and dashboard pages
- admin and Reseller/Freelancer panels
- payment and invoice surfaces
- five payment themes
- separate site and payment favicons
- Cloudflare headers
- the configured CPAY Supabase public client

## 2. Deploy the backend separately

The direct frontend upload does not deploy Supabase SQL or Edge Functions.
Apply migrations `0001` through `0080` only to the new CPAY staging project,
then deploy the Edge Functions using `docs/DEPLOYMENT.md`.

Do not connect the direct-upload project to previous Supabase project, BTCPay,
Cloudflare routes or secrets.

## 3. Verify after upload

1. Open the CPAY home page.
2. Open `/login.html` and `/register.html`.
3. Open an unknown test slug and confirm CPAY's payment/404 surface appears.
4. Open `/theme-preview.html`.
5. Confirm the site favicon and payment favicon are different.
6. Open Admin → Health and run the preflight after migrations `0079` and
   `0080` are applied; then review the staging sign-off ledger.

Use a staging domain first. Do not enable real BTCPay money movement until
the sign-off ledger, webhook tests, reconciliation and rollback evidence are
complete.