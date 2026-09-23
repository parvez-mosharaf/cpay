# CPAY Telegram Intelligence Bot

Separate read-only Telegram interface for CPAY. It does not approve withdrawals, edit accounts, or expose secrets.

## Supabase

From the repository root:

```powershell
npx supabase@latest db push
$reportSecret = [guid]::NewGuid().Guid
npx supabase@latest secrets set "TELEGRAM_REPORT_SECRET=$reportSecret"
npx supabase@latest functions deploy telegram-report --no-verify-jwt
```

Keep the same report secret for the Worker secret `TELEGRAM_REPORT_SECRET`. Never commit it.

## Cloudflare Worker

From `worker/telegram-bot`:

```powershell
npx wrangler@latest secret put TELEGRAM_BOT_TOKEN
npx wrangler@latest secret put TELEGRAM_WEBHOOK_SECRET
npx wrangler@latest secret put TELEGRAM_REPORT_SECRET
```

For the allowlists, use these exact values:

```powershell
npx wrangler@latest secret put TELEGRAM_ALLOWED_CHAT_IDS
# -1004386934418
npx wrangler@latest secret put TELEGRAM_ALLOWED_USER_IDS
# 5730569660,2128199452,6219355722,6051645315
```

Then deploy:

```powershell
npx wrangler@latest deploy --config wrangler.jsonc
```

Finally run `scripts/set-webhook.ps1` locally. The Telegram token is entered only into the local prompt.
