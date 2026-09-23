# Browser analytics build

CPAY's home page uses the Amplitude unified browser SDK from `src/home-analytics.js`. The source is bundled with esbuild into `public/assets/home-analytics.js`; the generated bundle is referenced only by `public/index.html`. Other static pages do not initialize Amplitude.

## Build

From the repository root:

```bash
npm install
npm run build
```

The build is intentionally limited to the home analytics entry point. It does not move or replace the `public/` directory: Cloudflare continues to serve `public/` as the static-assets root from `wrangler.jsonc`.

Run the same commands before a static-assets deployment:

```bash
npm install
npm run build
wrangler deploy
```

Pull requests run dependency installation and `npm run build` before the existing frontend checks. The build output is therefore regenerated from the committed source and package manifest in the verification environment rather than hand-edited.

## Privacy and rollback

Session Replay is configured with a 100% sample rate. This must be reviewed as a deliberate privacy decision before production use; do not treat analytics as anonymous or risk-free. The initial event is `Viewed Home Page` with `prompt_version: 'BA400.4'`.

To roll back, remove the home bundle script from `public/index.html`, remove the analytics source and package manifest, and deploy the resulting static site. No production deployment or first-event verification is part of this change.
