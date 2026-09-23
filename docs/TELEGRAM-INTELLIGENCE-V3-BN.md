# CPAY Telegram Intelligence V3

এই update-এ যোগ হয়েছে:

- যেকোনো public HTTPS URL research
- Facebook/Instagram/LinkedIn block হলে পরিষ্কার কারণ
- `/research` URL ছাড়া দিলে usage help
- “কেন যায়নি?” প্রশ্নের ব্যাখ্যা
- Voice message transcription ও CPAY question answering
- Payment screenshot screening
- Screenshot থেকে visible amount/reference extraction
- CPAY ledger match: `VERIFIED`, `MISMATCH`, `UNVERIFIED`

## Apply

Patch extract করার পর repository root থেকে:

```powershell
$repo = "C:\Users\PARVEZ MOSHARAF\Downloads\cpay-github"
Set-Location -LiteralPath $repo

npx supabase@latest db push
npx supabase@latest functions deploy telegram-report --no-verify-jwt

Set-Location -LiteralPath "$repo\worker\telegram-bot"
npx wrangler@latest deploy --config wrangler.jsonc
```

Webhook বা secrets আবার সেট করার দরকার নেই।

## Test

```text
/research https://example.com
/research https://www.facebook.com/public-page
আজ কত profit হয়েছে?
```

তারপর একটি voice message বা payment screenshot পাঠান।

## Verification rule

Screenshot নিজে payment proof নয়। Matching settled CPAY ledger record ছাড়া bot `VERIFIED` বলবে না। Exact invoice/reference না পাওয়া গেলে result `UNVERIFIED` হতে পারে।

Video analysis এখনো আলাদা media-processing step; এই update voice এবং payment screenshot screening চালু করে।
