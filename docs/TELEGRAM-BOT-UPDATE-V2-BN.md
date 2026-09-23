# CPAY Telegram Bot — Reply Intelligence Update

আগের version-এ unknown প্রশ্নের জন্য generic report fallback দেখাচ্ছিল। এই update-এ:

- profit প্রশ্ন আলাদা উত্তর পাবে
- payment/creator summary আলাদা হবে
- withdrawal ও location আলাদা হবে
- daily breakdown থাকবে
- `tomar model name ki?`-এর উত্তর দেবে
- unrelated কথায় একই report repeat করবে না
- Workers AI response না এলে useful deterministic fallback থাকবে

## Install

Repository root থেকে patch extract করুন, তারপর:

```powershell
$repo = "C:\Users\PARVEZ MOSHARAF\Downloads\cpay-github"
Expand-Archive `
  -LiteralPath "$env:USERPROFILE\Downloads\cpay-telegram-v2-patch.zip" `
  -DestinationPath $repo `
  -Force

Set-Location -LiteralPath "$repo\worker\telegram-bot"
npx wrangler@latest deploy --config wrangler.jsonc
```

Webhook আবার সেট করার দরকার নেই—Worker URL একই থাকছে।

## Test

Group থেকে personal account দিয়ে লিখুন:

```text
আজ কত profit হয়েছে?
কে কত payment পেয়েছে?
withdrawal pending আছে?
customer location দেখাও
দিনভিত্তিক report দাও
তোমার model name কি?
```

বর্তমান version text message support করে। Voice transcription এখনো আলাদা feature হিসেবে যোগ করা হয়নি।
