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
// The operator emergency stop is checked before any public link lookup or
// BTCPay call. A settings read failure fails closed: a payment kill switch
// must never be silently ignored during a database incident.
const { data: paymentStop, error: paymentStopError } = await supabaseAdmin
  .from("app_settings")
  .select("value")
  .eq("key", "emergency_payments_stop")
  .maybeSingle();
if (paymentStopError) {
  console.error("emergency payment-stop read failed:", paymentStopError.message);
  return json({ error: "Payment service temporarily unavailable" }, 503);
}
if (paymentStop?.value === true || String(paymentStop?.value) === "true") {
  return json({ error: "New payments are temporarily paused by the platform operator" }, 503);
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
// The owner's own markup, applied by us — BTCPay's Greenfield API has
// no per-invoice rate override (checkout carries speedPolicy,
// paymentMethods, paymentTolerance and so on, but no rate rules), so a
// shared store cannot price per user. Changing the amount we send is
// equivalent from the payer's side and stays entirely under our control.
//
// One BTCPay shop is enough. Multi-shop stays available for capacity only.
// Cost lives on the payment link / profile, not on the shop.
// The BTCPay store's own spread is expected to be 0%, so this markup is
// the only thing separating what the payer is charged from the link's
// face value. Clamped defensively: a negative or absurd cost_percent
// must never be able to produce a smaller or wildly larger charge than
// intended, even if the column constraint were somehow bypassed.
const rawCost = Number(link.cost_percent ?? 0);
// Upper bound matches the database's own CHECK constraint (0-1000,
// set by migrations 0060 and 0063), which is a typo guard rather than a
// policy ceiling. This line said 100 from when it was written alongside
// 0059's since-removed 25% ceiling, and was not updated when 0060
// deliberately lifted the limit — so any cost above 100% was silently
// clamped, quietly undoing the exact decision 0060 made. Nothing
// errored; a link set to 300% simply charged as if it were 100%.
const costPercent = Number.isFinite(rawCost) ? Math.min(Math.max(rawCost, 0), 1000) : 0;
// Rounded to cents, because that is what gets both charged and recorded
// — computing one and storing the other would make every reconciliation
// off by fractions.
const chargedAmount = Math.round(amount * (1 + costPercent / 100) * 100) / 100;

// An admin may set a lower per-profile ceiling than the platform-wide
// safety ceiling. Apply it to the final payer charge, including markup.
const { data: profileLimit, error: profileLimitError } = await supabaseAdmin
  .from("profile_limits")
  .select("max_invoice_amount")
  .eq("user_id", link.user_id)
  .maybeSingle();
if (profileLimitError) {
  console.error("profile invoice-limit read failed:", profileLimitError.message);
  return json({ error: "Payment service temporarily unavailable" }, 503);
}
const profileMaxInvoice = Number(profileLimit?.max_invoice_amount ?? 5000);
if (Number.isFinite(profileMaxInvoice) && chargedAmount > profileMaxInvoice) {
  return json({
    error: `This profile accepts payments up to $${profileMaxInvoice.toFixed(2)} per invoice.`,
  }, 400);
}

// A deliberately generous ceiling on the FINAL amount, separate from the
// markup's own bound. A 900% markup on a $6,000 link is individually
// within every rule above and still produces a $60,000 invoice — more
// than a Lightning channel is likely to carry, and the failure would
// surface as an opaque BTCPay or routing error rather than anything a
// payer could act on. Refusing it here gives a comprehensible message
// instead.
//
// Set well above any real payment so it never interferes with ordinary
// use; this catches the combination of two individually-legal numbers,
// not a normal one.
if (chargedAmount > 50000) {
return json({
error: "This link's current price is too high to invoice. Lower the link's cost percentage and try again.",
}, 400);
}

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
//
// Scoped by the link's OWNER, not the link. create_link_variants() gives
// one name up to four links (kebab, lower, pascal, title-kebab), each
// with its own id — so a per-link budget handed the same person four
// times the intended allowance for what is, to them, one target. The cap
// is higher than the old per-link 10 because it now covers a whole
// account, but well under the 40/min four variants used to permit.
const { data: rateAllowed, error: rateErr } = await supabaseAdmin.rpc("claim_invoice_rate_limit", {
  p_user_id: link.user_id, p_limit: 30, p_window_seconds: 60
});
if (rateErr) {
  console.error("rate-limit claim failed, refusing:", rateErr.message);
  return json({ error: "Temporarily unavailable — please try again in a moment" }, 503);
}
if (rateAllowed !== true) {
  return json({ error: "Too many invoices — please wait a moment and try again" }, 429);
}
let rateClaimed = true;
const releaseRateClaim = async () => {
  if (!rateClaimed) return;
  rateClaimed = false;
  const { error } = await supabaseAdmin.rpc("release_invoice_rate_limit", { p_user_id: link.user_id });
  if (error) console.error("rate-limit release failed:", error.message);
};

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
amount: chargedAmount.toFixed(2),
currency: "USD",
checkout: {
expirationMinutes,
paymentMethods: ["BTC-LN"],
defaultPaymentMethod: "BTC-LN",
},
// Makes each BTCPay invoice traceable back to a link without
// having to cross-reference the database by hand.
metadata: { orderId: `cpay:${link.slug}`, cpayLinkId: link.link_id },
}),
});
if (!res.ok) {
const errText = await res.text();
console.error("BTCPay invoice creation failed:", errText);
await releaseRateClaim();
return json({ error: "Could not create invoice" }, 502);
}
btcpayInvoice = await res.json();
} catch (e) {
console.error("BTCPay request error:", e);
await releaseRateClaim();
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
// NEW: buyer পেমেন্ট পেজে যা টাইপ করেছিল, markup যোগ হওয়ার আগে।
// শুধু display-এর জন্য (get_invoice_public, get_my_payments ইত্যাদি
// RPC ফাংশন এটা পড়ে) — BTCPay-কে পাঠানো amount, balance বা
// accounting-এর কোনো হিসাবে এটা ব্যবহার হয় না।
buyer_amount: amount,
// What the payer is actually being asked for, and therefore what the
// owner is credited when it settles. The link's face value plus their
// own markup — not the face value, or the two would disagree the moment
// anyone set a cost above zero.
amount_requested: chargedAmount,
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
// merchant is not left with a live invoice that CPAY has no record
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
await releaseRateClaim();
return json({ error: "Could not record payment" }, 500);
}
return json({
paymentId: payment.id,
payCode,
payUrl: payCode ? `lightning:${payCode}` : btcpayInvoice.checkoutLink,
// Return the amount actually sent to BTCPay. The original face amount is
// retained in buyer_amount for display and reconciliation.
amountRequested: chargedAmount,
expiresAt,
});
});
function json(body: unknown, status = 200) {
return new Response(JSON.stringify(body), {
status,
headers: { "Content-Type": "application/json", ...CORS_HEADERS },
});
}
