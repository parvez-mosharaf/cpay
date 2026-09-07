import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BTCPAY_URL = Deno.env.get("BTCPAY_URL")!;
const BTCPAY_API_KEY = Deno.env.get("BTCPAY_API_KEY")!;
const BTCPAY_STORE_ID = Deno.env.get("BTCPAY_STORE_ID")!;
const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
// Only browser calls need CORS (server-to-server callers like BTCPay and
// pg_cron ignore these headers entirely). The allowed-origin list is read
// from the site_domains table — the same registry the admin panel manages —
// so adding a domain in the admin panel enables it here within one cache
// window, with no secret change and no redeploy. The optional ALLOWED_ORIGINS
// secret is merged on top (comma-separated; accepts full URLs or bare hosts).
/**
* A CORS host, normalized exactly one way everywhere it is used.
*
* ALLOWED_ORIGINS can hold a full URL ("https://pay.example.com") or a
* bare host ("pay.example.com"); the database's site_domains.hostname is
* always bare. The normal path already reduced everything to bare,
* lowercase hosts before comparing — but the fallback taken when the
* database lookup fails returned STATIC_ORIGINS unnormalized. With a
* full-URL secret, that meant the working path compared "pay.example.com"
* while the fallback compared "https://pay.example.com": never equal, so
* every browser request lost its CORS header for as long as the fallback
* was active. Not an auth bypass — an availability bug that only showed
* up during a database hiccup, which is exactly when a payout or a
* payment matters most.
*/
function normalizeOriginHost(value: string): string {
const trimmed = value.trim().replace(/\/+$/, "");
try {
return new URL(trimmed).host.toLowerCase();
} catch {
return trimmed.toLowerCase();
}
}

const STATIC_ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
.split(",").map((s) => s.trim()).filter(Boolean);
const DOMAIN_CACHE_MS = 5 * 60 * 1000;
let domainCache: { hosts: Set<string>; fetchedAt: number } | null = null;

async function allowedHosts(): Promise<Set<string>> {
if (domainCache && Date.now() - domainCache.fetchedAt < DOMAIN_CACHE_MS) {
return domainCache.hosts;
}
const hosts = new Set<string>();
for (const o of STATIC_ORIGINS) hosts.add(normalizeOriginHost(o));
try {
const { data, error } = await supabaseAdmin
.from("site_domains").select("hostname").eq("is_active", true);
if (error) throw error;
for (const d of data ?? []) if (d.hostname) hosts.add(String(d.hostname).toLowerCase());
} catch (e) {
// If the lookup fails, fall back to whatever the last good cache had;
// failing closed here would lock every browser out of payments.
console.error("site_domains lookup failed, using cached/static origins:", e);
return domainCache?.hosts ?? new Set(STATIC_ORIGINS.map(normalizeOriginHost));
}
domainCache = { hosts, fetchedAt: Date.now() };
return hosts;
}

async function corsHeaders(req: Request): Promise<Record<string, string>> {
const h: Record<string, string> = {
"Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
"Access-Control-Allow-Methods": "POST, OPTIONS",
"Vary": "Origin",
};
const origin = req.headers.get("Origin");
if (!origin) return h; // server-to-server call: no CORS needed at all
let originHost = "";
try { originHost = new URL(origin).host; } catch { return h; }
if ((await allowedHosts()).has(originHost)) {
h["Access-Control-Allow-Origin"] = origin;
}
return h;
}
function json(body: unknown, status = 200, cors: Record<string, string> = {}) {
return new Response(JSON.stringify(body), {
status,
headers: { "Content-Type": "application/json", ...cors },
});
}
const VALID_METHODS = ["bkash", "nagad", "binance", "lightning", "usdt_bep20", "bank"];


/**
* Best-effort ops alerts. Payment failures must wake a human up, not sit in
* a log file. Two channels are supported — either one, or both at once:
*   ALERT_WEBHOOK_URL         — Discord or Slack incoming webhook
*   ALERT_TELEGRAM_BOT_TOKEN  — from @BotFather (/newbot)
*   ALERT_TELEGRAM_CHAT_ID    — chat/group id (see docs/ENV_VARS.md)
* Never awaited in a way that can break the money path — every call site
* uses .catch(), and an alert failure only ever lands in the function log.
*/
function sendAlert(message: string) {
const text = `🚨 Boltpay: ${message}`;
const webhook = Deno.env.get("ALERT_WEBHOOK_URL");
if (webhook) {
fetch(webhook, {
method: "POST",
headers: { "Content-Type": "application/json" },
body: JSON.stringify({ content: text }),
}).catch((e) => console.error("Discord/Slack alert delivery failed:", e));
}
const tgToken = Deno.env.get("ALERT_TELEGRAM_BOT_TOKEN");
const tgChat = Deno.env.get("ALERT_TELEGRAM_CHAT_ID");
if (tgToken && tgChat) {
fetch(`https://api.telegram.org/bot${tgToken}/sendMessage`, {
method: "POST",
headers: { "Content-Type": "application/json" },
body: JSON.stringify({ chat_id: tgChat, text }),
}).catch((e) => console.error("Telegram alert delivery failed:", e));
}
if (!webhook && !(tgToken && tgChat)) {
console.warn("sendAlert called but no alert channel is configured.");
}
}

Deno.serve(async (req) => {
const cors = await corsHeaders(req);
if (req.method === "OPTIONS") return new Response(null, { headers: cors });
if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, cors);
const authHeader = req.headers.get("Authorization");
if (!authHeader) return json({ error: "Unauthorized" }, 401, cors);
// The caller client carries the user's JWT, so request_withdrawal() runs as
// that user and every check inside it (auth, balance, fee, row lock) applies.
const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
global: { headers: { Authorization: authHeader } },
});
const { data: { user }, error: userErr } = await callerClient.auth.getUser();
if (userErr || !user) return json({ error: "Invalid session" }, 401, cors);
let body: { amount?: unknown; method?: unknown; destination?: unknown };
try {
body = await req.json();
} catch {
return json({ error: "Invalid JSON body" }, 400, cors);
}
const amount = Number(body.amount);
const method = String(body.method ?? "").trim();
const destination = String(body.destination ?? "").trim();
// Cheap client-side-mirroring checks. The authoritative versions all live
// in request_withdrawal(); these only exist to return a nicer error faster.
if (!Number.isFinite(amount) || amount < 5) {
return json({ error: "Minimum withdrawal is $5" }, 400, cors);
}
if (!VALID_METHODS.includes(method)) {
return json({ error: "Invalid withdrawal method" }, 400, cors);
}
if (!destination) {
return json({ error: "Destination account is required" }, 400, cors);
}
if (method === "lightning" && !/^ln(bc|tb|bcrt)[0-9a-z]+$/i.test(destination)) {
return json({ error: "That does not look like a Lightning invoice" }, 400, cors);
}
// ---- Single source of truth: the database decides ----
// Previously this function did its own balance maths against a different
// definition than request_withdrawal(), which let the same money be
// withdrawn twice. Now there is one code path.
const { data: withdrawal, error: rpcErr } = await callerClient
.rpc("request_withdrawal", {
p_amount: amount,
p_method: method,
p_destination: destination,
});
if (rpcErr || !withdrawal) {
// Postgres RAISE messages here are user-facing and intentionally safe
// ("Insufficient balance. Available: $12.40").
return json({ error: rpcErr?.message ?? "Could not create withdrawal request" }, 400, cors);
}
const row = Array.isArray(withdrawal) ? withdrawal[0] : withdrawal;
const withdrawalId = row.id as string;
const amountAfterFee = Number(row.amount_after_fee);
// ---- Instant Lightning payout, if the creator is allowed one ----
const { data: profile } = await supabaseAdmin
.from("profiles")
.select("auto_withdraw_enabled")
.eq("id", user.id)
.single();
const { data: settingRows } = await supabaseAdmin
.from("app_settings")
.select("key, value")
.in("key", ["auto_withdraw_threshold", "auto_withdraw_enabled"]);
const settings = Object.fromEntries((settingRows ?? []).map((r) => [r.key, r.value]));
const autoThreshold = Number(settings.auto_withdraw_threshold?.amount ?? 50);

// The GLOBAL master switch, which was not being checked at all.
//
// The admin panel says of this toggle: "Off here means no creator gets an
// instant payout, whatever their own profile says." That was not true —
// only the per-creator flag was consulted here, so turning the master
// switch off did nothing for any creator who already had their own flag
// on. They kept receiving instant real-money payouts.
//
// Defaults to false: a missing or unreadable row must never be read as
// permission to move money.
const globalAutoWithdraw =
settings.auto_withdraw_enabled === true ||
String(settings.auto_withdraw_enabled) === "true";

const instantEligible =
method === "lightning" &&
globalAutoWithdraw &&
profile?.auto_withdraw_enabled === true &&
amount < autoThreshold;
if (!instantEligible) {
return json({
status: "pending",
withdrawalId,
msg: "Request queued for admin approval.",
}, 200, cors);
}
// Atomically claim the row. If anything else already moved it, stop —
// this is what prevents a duplicate real-money payout.
const { data: claimed } = await supabaseAdmin
.rpc("system_claim_withdrawal", {
p_withdrawal_id: withdrawalId,
p_next_status: "processing",
});
if (claimed !== true) {
return json({ status: "pending", withdrawalId, msg: "Request queued for admin approval." }, 200, cors);
}
try {
const payoutRes = await fetch(
`${BTCPAY_URL}/api/v1/stores/${BTCPAY_STORE_ID}/payouts`,
{
method: "POST",
headers: {
"Content-Type": "application/json",
"Authorization": `token ${BTCPAY_API_KEY}`,
},
body: JSON.stringify({
destination,
amount: amountAfterFee.toFixed(2),
paymentMethod: "BTC-LightningNetwork",
}),
},
);
if (payoutRes.ok) {
const payoutData = await payoutRes.json();
await supabaseAdmin.from("withdrawals").update({
status: "paid",
processed_at: new Date().toISOString(),
admin_note: `Auto BTCPay payout: ${payoutData.id}`,
}).eq("id", withdrawalId);
return json({ status: "paid", withdrawalId, msg: "Instant payout successful!" }, 200, cors);
}
const errText = await payoutRes.text();
console.error("BTCPay payout rejected:", errText);
sendAlert(`Auto-payout REJECTED by BTCPay for withdrawal ${withdrawalId} — sent to manual review.`);
await supabaseAdmin.from("withdrawals").update({
status: "pending",
admin_note: "Auto-payout failed, sent for manual review",
}).eq("id", withdrawalId);
// The BTCPay error body can contain node/store internals — log it, don't ship it.
return json({
status: "pending",
withdrawalId,
msg: "Auto-payout could not complete. Sent to admin for manual review.",
}, 200, cors);
} catch (e) {
console.error("BTCPay unreachable:", e);
sendAlert(`BTCPay unreachable during auto-payout for withdrawal ${withdrawalId}.`);
await supabaseAdmin.from("withdrawals").update({
status: "pending",
admin_note: "Auto-payout error, sent for manual review",
}).eq("id", withdrawalId);
return json({
status: "pending",
withdrawalId,
msg: "Payment provider unreachable. Sent to admin for manual review.",
}, 200, cors);
}
});
