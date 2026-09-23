# CPAY Telegram Bot — সহজ বাংলা সেটআপ গাইড

এই গাইডে Telegram webhook সেট করা, Cloudflare Worker deploy করা এবং test করা দেখানো আছে।

> **নিরাপত্তা:** Bot token, `TELEGRAM_WEBHOOK_SECRET` বা `TELEGRAM_REPORT_SECRET` কখনো chat/GitHub-এ লিখবেন না। এগুলো শুধু নিজের PowerShell prompt-এ দিন।

## পুরো flow

```text
Telegram group
      ↓  webhook
Cloudflare Worker: cpay-telegram-intelligence
      ↓  private shared secret
Supabase Function: telegram-report
      ↓
CPAY read-only reports
```

## 1. Patch extract করুন

Download করা `cpay-telegram-intelligence-patch.zip`-এর উপর right-click করে Extract করুন:

```text
C:\Users\PARVEZ MOSHARAF\Downloads\cpay-github
```

PowerShell দিয়েও করা যায়:

```powershell
$repo = "C:\Users\PARVEZ MOSHARAF\Downloads\cpay-github"
Expand-Archive `
  -LiteralPath "$env:USERPROFILE\Downloads\cpay-telegram-intelligence-patch.zip" `
  -DestinationPath $repo `
  -Force
```

## 2. Supabase migration এবং report function

```powershell
$repo = "C:\Users\PARVEZ MOSHARAF\Downloads\cpay-github"
Set-Location -LiteralPath $repo

npx supabase@latest link --project-ref riumaeihemgznvgattoc
npx supabase@latest db push

$reportSecret = [guid]::NewGuid().Guid
Write-Host "REPORT SECRET তৈরি হয়েছে। এটি chat-এ পাঠাবেন না।"
npx supabase@latest secrets set "TELEGRAM_REPORT_SECRET=$reportSecret"
npx supabase@latest functions deploy telegram-report --no-verify-jwt
```

`TELEGRAM_REPORT_SECRET` Supabase এবং Cloudflare—দুই জায়গায় **একই** হতে হবে।

## 3. Cloudflare Worker secrets

```powershell
Set-Location -LiteralPath "$repo\worker\telegram-bot"
```

প্রতিটি command চালিয়ে prompt এ value দিন:

```powershell
npx wrangler@latest secret put TELEGRAM_BOT_TOKEN
```

Value: BotFather থেকে পাওয়া Telegram bot token।

```powershell
npx wrangler@latest secret put TELEGRAM_REPORT_SECRET
```

Value: ধাপ ২-এর একই report secret।

```powershell
npx wrangler@latest secret put TELEGRAM_WEBHOOK_SECRET
```

Value হিসেবে নতুন একটি GUID ব্যবহার করুন:

```powershell
[guid]::NewGuid().Guid
```

এরপর allowlist সেট করুন:

```powershell
npx wrangler@latest secret put TELEGRAM_ALLOWED_CHAT_IDS
```

Value:

```text
-1004386934418
```

```powershell
npx wrangler@latest secret put TELEGRAM_ALLOWED_USER_IDS
```

Value:

```text
5730569660,2128199452,6219355722,6051645315
```

## 4. Worker deploy করুন

```powershell
npx wrangler@latest deploy --config wrangler.jsonc
```

শেষে এমন একটি URL পাবেন:

```text
https://cpay-telegram-intelligence.YOUR-SUBDOMAIN.workers.dev
```

এই URL-টি copy করুন। URL-এর শেষে এখনো `/telegram` যোগ করবেন না; script নিজে যোগ করবে।

## 5. Webhook সেট করার সহজ পদ্ধতি

Worker deploy হওয়ার পর চালান:

```powershell
.\scripts\set-webhook-bn.ps1
```

Script তিনটি জিনিস চাইবে:

1. **Telegram bot token** — local prompt-এ দিন
2. **Worker URL** — যেমন `https://cpay-telegram-intelligence.YOUR-SUBDOMAIN.workers.dev`
3. **Webhook secret** — ধাপ ৩-এ `TELEGRAM_WEBHOOK_SECRET` হিসেবে যে value দিয়েছেন, একই value দিন

Script নিজে এই URL সেট করবে:

```text
https://cpay-telegram-intelligence.YOUR-SUBDOMAIN.workers.dev/telegram
```

এটাই Telegram webhook URL।

## 6. Webhook verify করুন

```powershell
$token = Read-Host "Telegram bot token (local only)"
$base = "https://api.telegram.org/bot$token"
Invoke-RestMethod "$base/getWebhookInfo" | ConvertTo-Json -Depth 10
```

সফল হলে:

- `url`-এ Cloudflare Worker URL থাকবে
- `pending_update_count` সাধারণত `0` থাকবে
- `last_error_message` ফাঁকা থাকবে

Webhook চালু হওয়ার পরে `getUpdates`-এ conflict দেখালে ভয় পাবেন না—Telegram-এ webhook এবং `getUpdates` একসাথে ব্যবহার করা যায় না।

## 7. Telegram থেকে test করুন

Group `Kmon`-এ পাঠান:

```text
/today
```

```text
আজ কত profit হয়েছে?
```

```text
কে কত payment পেয়েছে?
```

```text
withdrawal pending আছে?
```

```text
/health
```

Natural-language message পড়ার জন্য BotFather-এ একবার করুন:

```text
/setprivacy → @parvez_personal_bot → Disable
```

Admin account থেকে message দেওয়ার সময় anonymous mode ব্যবহার করবেন না, যাতে allowlist নিরাপদে কাজ করে।

## Common সমস্যা

### Bot উত্তর দিচ্ছে না

1. Worker deploy হয়েছে কিনা দেখুন।
2. `getWebhookInfo`-এর `last_error_message` দেখুন।
3. `TELEGRAM_WEBHOOK_SECRET` দুই জায়গায় একই কিনা দেখুন।
4. `TELEGRAM_ALLOWED_CHAT_IDS`-এ `-1004386934418` আছে কিনা দেখুন।
5. `TELEGRAM_ALLOWED_USER_IDS`-এ আপনার Telegram ID আছে কিনা দেখুন।

### `401 unauthorized`

Worker secret এবং webhook secret মেলেনি। ধাপ ৩-এর একই secret দিয়ে webhook আবার সেট করুন:

```powershell
.\scripts\set-webhook-bn.ps1
```

### Webhook সরাতে চাইলে

```powershell
$token = Read-Host "Telegram bot token (local only)"
Invoke-RestMethod "https://api.telegram.org/bot$token/deleteWebhook?drop_pending_updates=false" | ConvertTo-Json
```
