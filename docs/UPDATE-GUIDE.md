# Boltpay — Security Update Guide (Aug 2026)

Ei update e ki ki change hoyeche, keno, ar apni ki order e deploy korben —
shob ekhane. **Order ta follow korun**: database age, tarpor secrets, tarpor
code. Code age deploy korle notun webhook table missing thakay log e error
ashbe (payment off hobe na — tao age database kora bhalo).

## Migration order: 0033 → 0034

- **0033** (`0033_webhook_idempotency_and_integrity.sql`) — webhook
  idempotency table + amount CHECK constraints
- **0034** (`0034_messages_deadlock_fix.sql`) — support_messages deadlock fix
  (details niche §11)

---

## Ki ki change hoyeche ebong keno

### 🔴 Security fixes

**1. `ledger-backups/` folder repo theke removed + `.gitignore` e added**
- *Keno:* Oi JSON file gulo te real customer email chilo. Repo clone korlei
  customer PII chole jeto. Ekhon theke backup shudhu apnar private GitHub
  repo te jabe (ledger-backup function je khanei pathay).
- *Moner kotha:* Git history te snapshots akhon-o ache — nicher Step 6 dekhen.

**2. CORS restriction — `btcpay-webhook` + `user-withdraw` (dynamic, admin-panel-driven)**
- *Keno:* Age shob edge function e `Access-Control-Allow-Origin: *` chilo.
  Ekhon browser shudhu apnar registered domain theke ei duto function call
  korte parbe. Random website er visitor der browser diye keu apnar
  withdrawal endpoint chalate parbe na.
- *Ki vabe kaaj kore:* Allowed origin list ta `site_domains` table theke
  pora hoy — orthath **admin panel e domain add korlei ~5 minute er moddhe
  sei domain theke API call cholbe**, kono secret change ba redeploy chara.
  Domain deactivate korle access o bondho. `ALLOWED_ORIGINS` secret optional
  — shudhu emon domain er jonno ja apni admin panel e dekhate chan na.
- *Note:* `create-invoice` intentionally wildcard e ache — payment link
  creator-der nijer domain e embed hoy, ar eta per-link rate limit diye
  protected.

**3. Webhook idempotency — notun `webhook_events` table (migration 0033)**
- *Keno:* BTCPay 200 na paile same event bar bar retry kore, majhe majhe
  ek sathe duto delivery o pathay. Age sudhu conditional update chilo. Ekhon
  prottek delivery prothome unique delivery-id claim kore — duplicate pele
  200 diye bondho. Double-settlement er possibility fully bondho.

**4. CHECK constraints (migration 0033)**
- *Keno:* `amount_requested > 0`, `amount_settled >= 0`, withdrawal amounts o
  same. Kono future bug ba notun code path negative/zero amount likhle
  database nijei reject korbe — defence in depth.

**5. Security headers — notun `public/_headers`**
- *Keno:* `frame-ancestors 'none'` (clickjacking roddhe — keu apnar payment
  page ba admin panel invisible iframe e bosiye click churai korte parbe na),
  CSP (script shudhu apnar domain + 2 ta known CDN theke), `nosniff`,
  Referrer-Policy, Permissions-Policy. Cloudflare static deploy e eta
  automatically apply hoy, kono code change lage na.

### 🟡 Reliability fixes

**6. Admin panel timezone hack removed**
- *Keno:* Age `now - 11 hours` diye "BD day" hisab hoto — ekta magic number,
  daily-report er sathe silently mismatch korte parto. Ekhon dutoi real
  `Asia/Dhaka` timezone use kore, tai Earnings tab ar stats card kokhono
  alada din dekhabe na.

**7. Admin page login flash fix**
- *Keno:* Signed-in admin page load e "login screen" flash dekhto. Ekhon
  check cholte thakle "Verifying session…" dekhay, ar non-admin session
  pele sign-out kore dey.

**11. `support_messages` mark-as-read deadlock fix (migration 0034 + dashboard.html + admin.html)**
- *Lokkhhon:* supabase log e `40P01 deadlock detected` ar `57014 statement
  timeout` — creator ar admin ek sathe same message thread khulle hoto.
- *Keno:* Creator dashboard ar admin panel dutoi prottek message reload e
  puro thread e bulk UPDATE chalato (`read_by_creator` / `read_by_admin`).
  Index chara Postgres row gulo random order e lock korto; concurrent
  session gulo circle e wait korto, Postgres ekta ke maire ditto.
- *Fix:* 2 ta partial index (`idx_messages_creator_unread`,
  `idx_messages_admin_unread`) + duto page ekhon shudhu `unread > 0` hole-i,
  shudhu unread row te UPDATE chalay. 99% case e UPDATE cholbe-i na.

### 🔧 Operational improvements

**8. `ALERT_WEBHOOK_URL` — payment failure alerts**
- *Keno:* BTCPay payout fail, BTCPay unreachable, ledger backup fail, ba
  daily-report er kono din miss — shob ekhon apnar Discord/Slack/Telegram e
  🚨 message pathay. Age shudhu log e thakto, keu janto na.

**9. Deno std import removed — built-in `Deno.serve` + `crypto.subtle`**
- *Keno:* `deno.land/std@0.224.0` purono. Supabase er Deno runtime e `serve`
  ar Web Crypto built-in — external dependency kom, supply-chain risk kom,
  cold start ektu fast.

**10. Docs updated** — `README.md`, `SECURITY.md`, `docs/ENV_VARS.md`
(CRON_SECRET rotate korar exact step soho), `docs/DEPLOYMENT.md` (notun
§5b checklist soho).

---

## Deploy korar order (step by step)

### Step 1 — Supabase: migration 0033 + 0034 run korun
Supabase Dashboard → **SQL Editor** → New query → ei duto file er puro
content **ek tar por ekta** paste kore Run:
`supabase/migrations/0033_webhook_idempotency_and_integrity.sql`
`supabase/migrations/0034_messages_deadlock_fix.sql`

Verify (same editor e):
```sql
select count(*) from webhook_events;   -- table exists = OK
select indexname from pg_indexes
where tablename = 'support_messages'
  and indexname like 'idx_messages_%_unread';   -- expect: 2 rows
```

### Step 2 — Supabase: alert secret set korun
Dashboard → **Edge Functions → Secrets** e add korun:
- `ALERT_WEBHOOK_URL` → apnar Discord/Slack webhook URL

**Domain er jonne secret lage NA** — apnar 3 ta domain admin panel →
Domains section e add kora thaklei CORS automatically kaaj korbe. Pore
notun domain add korle o shudhu admin panel ei add korben, ar kichhu na.
(`ALLOWED_ORIGINS` shudhu optional extra layer.)

### Step 3 — Supabase: CRON_SECRET rotate korun ⚠️
Purano ta git history te leak hoyechilo — **eta skip korben na**:
1. Terminal e: `openssl rand -hex 32` → notun secret
2. Edge Functions → Secrets → `CRON_SECRET` update
3. SQL Editor e:
```sql
select vault.create_secret('<notun-secret>', 'boltpay_cron_secret');
```
(Same name e upsert hoy — cron trigger SQL change korte hobe na.)

### Step 4 — GitHub: notun code push korun
Ei updated folder tar content apnar repo te copy kore:
```bash
git add -A
git commit -m "Security hardening: idempotent webhooks, CORS restriction, CSP headers, amount constraints"
git push
```

### Step 5 — Cloudflare + Supabase functions redeploy
```bash
# Frontend + _headers (repo root theke)
wrangler deploy

# Edge functions (Supabase CLI)
supabase functions deploy btcpay-webhook
supabase functions deploy create-invoice
supabase functions deploy user-withdraw
supabase functions deploy daily-report
supabase functions deploy ledger-backup
```
(GitHub integration diye auto-deploy korle Step 4 er push e hoye jabe —
`supabase/config.toml` ei repo tei ache.)

### Step 6 — Git history theke purano leak clean korun
File delete korleo history te theke jay. Ekbar er kaj:
```bash
pip install git-filter-repo    # ba: brew install git-filter-repo
git filter-repo --path ledger-backups --invert-paths
git push --force
```
Tarpor je je clone koreche tader notun kore clone korte bolun.

### Step 7 — Verify (sob kaj sesh e)
```bash
curl -sI https://apnar-domain.com | grep -i frame-ancestors
# expect: frame-ancestors 'none'
```
- Ekta test payment link khulun → invoice create hocche kina dekhun
- Dashboard e admin login → login flash nei, stats load hocche
- Supabase logs e `ALLOWED_ORIGINS` warning khujun — set thakle warning thakbe na

---

## Jodi kichu bhenge jay (rollback)

- **Frontend/old functions:** git e ager commit e fire jan — `git revert` ba
  `git reset --hard <old-commit>` kore push, tarpor redeploy. Migration 0033
  shudhu notun table + constraint add kore, kichhu delete kore nai — tai DB
  rollback er dorkar nei.
- **CSP problem hole:** `public/_headers` file ta delete kore `wrangler deploy`
  — age abasthay fire jabe.
- **CORS problem hole (creator-er embed kaaje na):** `create-invoice`
  unaffected. Admin/withdraw er jonne check korun domain ta admin panel e
  active ache kina — ~5 min cache wait korte hote pare. Emergency te
  `ALLOWED_ORIGINS` secret e domain ta add korle static fallback hisabe
  immediately kaaj korbe.
