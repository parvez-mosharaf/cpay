import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BTCPAY_URL = Deno.env.get("BTCPAY_URL")!;
// Per-shop API keys. The shop row stores only the NAME of the secret to
// read, never the key itself, so keys stay in Supabase's encrypted secret
// store and out of the database and its backups.
const API_KEY_ENVS: Record<string, string | undefined> = {
BTCPAY_API_KEY: Deno.env.get("BTCPAY_API_KEY"),
BTCPAY_API_KEY_2: Deno.env.get("BTCPAY_API_KEY_2"),
BTCPAY_API_KEY_3: Deno.env.get("BTCPAY_API_KEY_3"),
BTCPAY_API_KEY_4: Deno.env.get("BTCPAY_API_KEY_4"),
BTCPAY_API_KEY_5: Deno.env.get("BTCPAY_API_KEY_5"),
};
// Kept for reference only — the store is now chosen per payment link
// from btcpay_shops. The API key must have permission on every store.
const BTCPAY_STORE_ID = Deno.env.get("BTCPAY_STORE_ID") ?? "";
const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
// Wildcard origin is intentional here: payment links are embedded on
// creator-owned custom domains, so any site must be able to POST. The
// endpoint is unauthenticated by design and defends itself with the
// per-link rate limit below, not with CORS.
const CORS_HEADERS = {
"Access-Control-Allow-Origin": "*",
"Access-Control-Allow-Headers": "Content-Type",
"Access-Control-Allow-Methods": "POST, OPTIONS",
};
Deno.serve(async (req) => {
if (req.method === "OPTIONS") {
return new Response(null, { headers: CORS_HEADERS });
}
if (req.method !== "POST") {
return new Response("Method not allowed", { status: 405, headers: CORS_HEADERS });
}
let body: { slug?: string; amount?: number };
try {
body = await req.json();
} catch {
return json({ error: "Invalid JSON body" }, 400);
}
// Case matters: /taylor-james, /TaylorJames and /taylorjames are three
// different links routed to three different BTCPay stores.
const slug = String(body.slug ?? "").trim();
const amount = Math.round(Number(body.amount) * 100) / 100;
// `Number(body.amount)` alone let NaN and Infinity through the old
// `!amount` check in some shapes, and fractional cents reached BTCPay
// as an amount the ledger could never match exactly.
if (!/^[A-Za-z0-9][A-Za-z0-9-]{2,48}[A-Za-z0-9]$/.test(slug)) {
return json({ error: "Invalid payment link" }, 400);
}
if (!Number.isFinite(amount) || amount < 1 || amount > 5000) {
return json({ error: "Amount must be between $1 and $5000" }, 400);
}
// Cloudflare/Supabase edge passes these geo headers through — best-effort
// approximate location of the customer initiating the payment.
const customerCity = req.headers.get("cf-ipcity") || null;
const customerCountry = req.headers.get("cf-ipcountry") || null;
// Look up the payment link — must exist and be active
// system_link_for_invoice returns the shop's BTCPay store_id, which is
// deliberately not readable by anon or authenticated — only the service
// role can see which store a link belongs to.
const { data: linkRows, error: linkErr } = await supabaseAdmin
.rpc("system_link_for_invoice", { p_slug: slug });
const link = Array.isArray(linkRows) ? linkRows[0] : linkRows;
if (linkErr || !link) return json({ error: "Payment link not found" }, 404);
if (!link.is_active) return json({ error: "This payment link is no longer active" }, 410);

// Every link must resolve to an active shop. Falling back to the env
// store here would quietly bill the payer at the wrong rate, which is
// worse than refusing.
const storeId = link.store_id;
if (!storeId) {
console.error("No active shop for link", slug);
return json({ error: "This payment link is not available right now" }, 503);
}

// The lookup is keyed off a whitelist rather than Deno.env.get(name), so a
// shop row can never make this function read an arbitrary environment
// variable and post it to BTCPay as a bearer token.
const apiKeyEnv = link.api_key_env || "BTCPAY_API_KEY";
const apiKey = API_KEY_ENVS[apiKeyEnv];
if (!apiKey) {
console.error(`Shop for ${slug} wants secret ${apiKeyEnv}, which is not set`);
return json({ error: "This payment link is not available right now" }, 503);
}
// This endpoint is unauthenticated by design (customers have no account),
// so it needs its own brake. Without one, a script can spin up unlimited
// real invoices on the merchant's Lightning node.
const oneMinuteAgo = new Date(Date.now() - 60 * 1000).toISOString();
const { count: recentCount } = await supabaseAdmin
.from("payments")
.select("id", { count: "exact", head: true })
.eq("payment_link_id", link.link_id)
.gte("created_at", oneMinuteAgo);
if ((recentCount ?? 0) >= 10) {
return json({ error: "Too many invoices — please wait a moment and try again" }, 429);
}
// Create the BTCPay invoice
const expirationMinutes = 60;
let btcpayInvoice: any;
try {
const res = await fetch(`${BTCPAY_URL}/api/v1/stores/${storeId}/invoices`, {
method: "POST",
headers: {
"Content-Type": "application/json",
"Authorization": `token ${apiKey}`,
},
body: JSON.stringify({
amount: amount.toFixed(2),
currency: "USD",
checkout: {
expirationMinutes,
paymentMethods: ["BTC-LN"],
defaultPaymentMethod: "BTC-LN",
},
// Makes each BTCPay invoice traceable back to a link without
// having to cross-reference the database by hand.
metadata: { orderId: `boltpay:${link.slug}`, boltpayLinkId: link.link_id },
}),
});
if (!res.ok) {
const errText = await res.text();
console.error("BTCPay invoice creation failed:", errText);
return json({ error: "Could not create invoice" }, 502);
}
btcpayInvoice = await res.json();
} catch (e) {
console.error("BTCPay request error:", e);
return json({ error: "Payment provider unreachable" }, 502);
}
// Match by destination pattern (lnbc/lntb prefix), not by method name —
// BTCPay's method identifier for Lightning varies by server version/config
// (e.g. "BTC-LN" vs "BTC-LightningNetwork"), but a bolt11 string is always
// reliably identifiable by its prefix.
let payCode = "";
for (let attempt = 0; attempt < 3; attempt++) {
if (attempt > 0) {
await new Promise((resolve) => setTimeout(resolve, 800));
}
try {
const pmRes = await fetch(
`${BTCPAY_URL}/api/v1/stores/${storeId}/invoices/${btcpayInvoice.id}/payment-methods`,
{ headers: { "Authorization": `token ${apiKey}` } }
);
if (pmRes.ok) {
const methods = await pmRes.json();
for (const pm of methods) {
const dest = (pm.destination || "").trim();
if (dest.startsWith("lnbc") || dest.startsWith("lntb")) {
payCode = dest;
break;
}
}
if (payCode) break;
} else {
console.error("payment-methods fetch not ok, attempt", attempt, pmRes.status);
}
} catch (e) {
console.error("Failed to fetch payment methods, attempt", attempt, e);
}
}
const expiresAt = new Date(Date.now() + expirationMinutes * 60 * 1000).toISOString();
// Record the payment in our own database
const { data: payment, error: insertErr } = await supabaseAdmin
.from("payments")
.insert({
payment_link_id: link.link_id,
user_id: link.user_id,
btcpay_invoice_id: btcpayInvoice.id,
method: "lightning",
amount_requested: amount,
status: "new",
expires_at: expiresAt,
customer_city: customerCity,
customer_country: customerCountry,
lightning_invoice: payCode || null,
// The webhook has to read this invoice back from the same store that
// created it. Without this column a settled invoice on shop 2 would be
// looked up on shop 1, 404, and silently fall back to the requested
// amount.
btcpay_store_id: storeId,
btcpay_api_key_env: apiKeyEnv,
})
.select("id")
.single();
if (insertErr || !payment) {
// The BTCPay invoice already exists at this point. Archive it so the
// merchant is not left with a live invoice that Boltpay has no record
// of and can never settle against.
console.error("Failed to record payment:", insertErr);
try {
await fetch(
`${BTCPAY_URL}/api/v1/stores/${storeId}/invoices/${btcpayInvoice.id}`,
{ method: "DELETE", headers: { "Authorization": `token ${apiKey}` } },
);
} catch (e) {
console.error("Could not archive orphaned BTCPay invoice:", e);
}
return json({ error: "Could not record payment" }, 500);
}
return json({
paymentId: payment.id,
payCode,
payUrl: payCode ? `lightning:${payCode}` : btcpayInvoice.checkoutLink,
amountRequested: amount,
expiresAt,
});
});
function json(body: unknown, status = 200) {
return new Response(JSON.stringify(body), {
status,
headers: { "Content-Type": "application/json", ...CORS_HEADERS },
});
}
