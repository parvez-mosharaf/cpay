# Voice reply fix

Voice transcription already works. এই ছোট update-এ general voice questions-এর জন্য fallback answer যোগ হয়েছে। যেমন:

- কত ভাষা বোঝো?
- তুমি কে?
- কী কী করতে পারো?

Apply:

```powershell
$repo = "C:\Users\PARVEZ MOSHARAF\Downloads\cpay-github"
Expand-Archive `
  -LiteralPath "$env:USERPROFILE\Downloads\cpay-voice-reply-fix.zip" `
  -DestinationPath $repo `
  -Force

Set-Location -LiteralPath "$repo\worker\telegram-bot"
npx wrangler@latest deploy --config wrangler.jsonc
```

Webhook/secrets আবার সেট করতে হবে না।
