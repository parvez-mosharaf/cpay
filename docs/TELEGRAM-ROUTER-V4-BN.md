# CPAY Telegram Router V4

এই update-এর লক্ষ্য: bot যেন সবকিছুকে CPAY report না ধরে।

- General text question → general AI answer
- CPAY question → CPAY report
- Normal photo → image description/visible text analysis
- Payment verification চাইলে তবেই ledger verification
- PDF → clear limitation message
- Video → clear limitation message
- Voice → transcript করে একই router-এ পাঠানো

## Deploy

```powershell
$repo = "C:\Users\PARVEZ MOSHARAF\Downloads\cpay-github"
Expand-Archive `
  -LiteralPath "$env:USERPROFILE\Downloads\cpay-router-v4-patch.zip" `
  -DestinationPath $repo `
  -Force

Set-Location -LiteralPath "$repo\worker\telegram-bot"
npx wrangler@latest deploy --config wrangler.jsonc
```

Webhook/secrets/migration আবার লাগবে না।

## Test

সাধারণ question:

```text
পৃথিবীর সবচেয়ে বড় মহাসাগর কোনটি?
```

Normal photo পাঠালে description দেবে। Payment check চাইলে caption দিন:

```text
verify payment
```

PDF এখনো fully extract করে না; PDF-এর page screenshot পাঠালে image analysis হবে।
