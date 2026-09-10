// The Supabase Edge Runtime resolves this remote Deno import at deployment time.
// @ts-expect-error The local TypeScript server cannot resolve URL imports without Deno's resolver.
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

// Local editor/tsserver environments do not always include the Deno globals
// that are present at runtime in Supabase Edge Functions. Declare the subset
// we use here so type-checking continues to work without changing runtime behavior.
declare const Deno: {
    env: {
        get(key: string): string | undefined;
    };
    serve(handler: (request: Request) => Response | Promise<Response>): void;
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
// One BTCPay server, several stores, and BTCPay generates a separate
// secret for every webhook. Rather than forcing all four stores to share
// one secret, collect every secret that is configured and accept a
// delivery that matches any of them.
//
// Add one Edge Function secret per shop:
//   BTCPAY_WEBHOOK_SECRET     (shop 1)
//   BTCPAY_WEBHOOK_SECRET_2   (shop 2)
//   BTCPAY_WEBHOOK_SECRET_3   (shop 3)
//   BTCPAY_WEBHOOK_SECRET_4   (shop 4)
// All four webhooks point at this same function URL.
const BTCPAY_WEBHOOK_SECRETS = [
    Deno.env.get("BTCPAY_WEBHOOK_SECRET"),
    Deno.env.get("BTCPAY_WEBHOOK_SECRET_2"),
    Deno.env.get("BTCPAY_WEBHOOK_SECRET_3"),
    Deno.env.get("BTCPAY_WEBHOOK_SECRET_4"),
    Deno.env.get("BTCPAY_WEBHOOK_SECRET_5"),
].filter((v): v is string => typeof v === "string" && v.length > 0);
const BTCPAY_URL = Deno.env.get("BTCPAY_URL")!;
// Whitelisted per-shop keys, same as create-invoice. Payouts still use
// BTCPAY_API_KEY / BTCPAY_STORE_ID — those come from your payout store,
// which is a separate decision from which store issued an invoice.
const BTCPAY_API_KEY = Deno.env.get("BTCPAY_API_KEY")!;
const API_KEY_ENVS: Record<string, string | undefined> = {
    BTCPAY_API_KEY: Deno.env.get("BTCPAY_API_KEY"),
    BTCPAY_API_KEY_2: Deno.env.get("BTCPAY_API_KEY_2"),
    BTCPAY_API_KEY_3: Deno.env.get("BTCPAY_API_KEY_3"),
    BTCPAY_API_KEY_4: Deno.env.get("BTCPAY_API_KEY_4"),
    BTCPAY_API_KEY_5: Deno.env.get("BTCPAY_API_KEY_5"),
};
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
async function hmacHex(secret: string, rawBody: string): Promise<string> {
    const key = await crypto.subtle.importKey(
        "raw",
        new TextEncoder().encode(secret),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"],
    );
    const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(rawBody));
    return Array.from(new Uint8Array(sig))
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");
}

function constantTimeEquals(a: string, b: string): boolean {
    if (a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diff === 0;
}

async function sha256Hex(text: string): Promise<string> {
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
    return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
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

/**
* ✅ Payment-settled notification. Uses the same channels as sendAlert but
* without the 🚨 alarm prefix — this is good news, not an incident. On by
* default when any alert channel is configured; set ALERT_ON_SETTLED=false
* to silence it (e.g. if volume gets noisy) without touching failure alerts.
*/
function sendSettledAlert(text: string) {
    if ((Deno.env.get("ALERT_ON_SETTLED") ?? "true").toLowerCase() === "false") return;
    const webhook = Deno.env.get("ALERT_WEBHOOK_URL");
    if (webhook) {
        fetch(webhook, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ content: text }),
        }).catch((e) => console.error("Discord/Slack settled-alert failed:", e));
    }
    const tgToken = Deno.env.get("ALERT_TELEGRAM_BOT_TOKEN");
    const tgChat = Deno.env.get("ALERT_TELEGRAM_CHAT_ID");
    if (tgToken && tgChat) {
        fetch(`https://api.telegram.org/bot${tgToken}/sendMessage`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ chat_id: tgChat, text }),
        }).catch((e) => console.error("Telegram settled-alert failed:", e));
    }
}

/** Look up the link slug for a nicer notification. Best-effort. */
async function linkSlugFor(paymentLinkId: string | null): Promise<string> {
    if (!paymentLinkId) return "unknown-link";
    try {
        const { data } = await supabaseAdmin
            .from("payment_links").select("slug").eq("id", paymentLinkId).single();
        return data?.slug ?? "unknown-link";
    } catch {
        return "unknown-link";
    }
}


async function verifySignature(rawBody: string, signatureHeader: string | null): Promise<boolean> {
    // No secret configured means every forged webhook would be accepted,
    // because an HMAC over the empty string is trivially reproducible.
    if (!BTCPAY_WEBHOOK_SECRETS.length) {
        console.error("No BTCPAY_WEBHOOK_SECRET configured — rejecting webhook");
        return false;
    }
    if (!signatureHeader) return false;

    const sigParts = signatureHeader.split("=");
    if (sigParts.length !== 2 || sigParts[0] !== "sha256") return false;
    const providedSig = sigParts[1].toLowerCase();

    // Check every configured secret. Each comparison is constant-time, and
    // they all run regardless of an early match, so the number of shops
    // configured is not observable from response timing.
    let matched = false;
    for (const secret of BTCPAY_WEBHOOK_SECRETS) {
        const computed = await hmacHex(secret, rawBody);
        if (constantTimeEquals(computed, providedSig)) matched = true;
    }
    return matched;
}

async function verifyAdminCaller(
    req: Request,
): Promise<{ ok: boolean; userId?: string; callerClient?: SupabaseClient }> {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return { ok: false };
    const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
        global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error } = await callerClient.auth.getUser();
    if (error || !user) return { ok: false };
    const { data: profile } = await supabaseAdmin
        .from("profiles").select("role").eq("id", user.id).single();
    if (profile?.role !== "admin") return { ok: false };
    return { ok: true, userId: user.id, callerClient };
}
/**
* Ask BTCPay what the invoice is actually worth instead of trusting a field
* on the webhook envelope. The InvoiceSettled payload does not carry a
* reliable fiat amount, so `event.amount ?? amount_requested` was either
* undefined or — on an overpayment — a BTC-denominated number being written
* into a USD column.
*/
async function fetchInvoiceAmountUsd(
    invoiceId: string,
    storeId: string | null,
    apiKeyEnv: string | null,
): Promise<number | null> {
    // With several shops on one server, the invoice only exists in the store
    // that issued it. payments.btcpay_store_id records that; the env value is
    // only a fallback for rows created before multi-shop support.
    const store = storeId || BTCPAY_STORE_ID;
    // Reading an invoice back needs the same key that created it, so the
    // payment records which secret to use alongside which store.
    const key = API_KEY_ENVS[apiKeyEnv || "BTCPAY_API_KEY"] || BTCPAY_API_KEY;
    if (!store || !key) return null;
    try {
        const res = await fetch(
            `${BTCPAY_URL}/api/v1/stores/${store}/invoices/${invoiceId}`,
            { headers: { "Authorization": `token ${key}` } },
        );
        if (!res.ok) return null;
        const invoice = await res.json();
        if (invoice?.currency !== "USD") return null;
        const amount = Number(invoice?.amount);
        return Number.isFinite(amount) && amount > 0 ? amount : null;
    } catch (e) {
        console.error("Could not read invoice from BTCPay:", e);
        return null;
    }
}
Deno.serve(async (req) => {
    const cors = await corsHeaders(req);
    if (req.method === "OPTIONS") return new Response(null, { headers: cors });
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405, cors);
    const url = new URL(req.url);
    // ==========================================
    // ROUTE: /admin-mark-settled
    // ==========================================
    if (url.pathname.endsWith("/admin-mark-settled")) {
        const auth = await verifyAdminCaller(req);
        if (!auth.ok) return json({ error: "Unauthorized" }, 401, cors);
        try {
            const { paymentId, amountSettled } = await req.json();
            if (!paymentId) return json({ error: "paymentId required" }, 400, cors);
            // Called with the ADMIN's client, not supabaseAdmin. A service-role
            // JWT carries no `sub` claim, so auth.uid() inside admin_mark_payment()
            // is null and its is_admin() check would reject the call outright.
            const { error } = await auth.callerClient!.rpc("admin_mark_payment", {
                p_payment_id: paymentId,
                p_status: "settled",
                p_amount_settled: amountSettled ?? null,
            });
            if (error) return json({ error: error.message }, 400, cors);
            const { data: payment } = await supabaseAdmin
                .from("payments").select("user_id, payment_link_id, amount_requested, amount_settled").eq("id", paymentId).single();
            if (payment) {
                const slug = await linkSlugFor(payment.payment_link_id ?? null);
                const settledAmt = payment.amount_settled ?? payment.amount_requested;
                sendSettledAlert(`✅ Payment settled (manual): $${Number(settledAmt).toFixed(2)} via /${slug}`);
                await maybeQueueAutoWithdrawal(payment.user_id);
            }
            return json({ status: "settled" }, 200, cors);
        } catch (e) {
            console.error("admin-mark-settled failed:", e);
            return json({ error: "Could not mark payment settled" }, 500, cors);
        }
    }
    // ==========================================
    // ROUTE: /process-withdrawal
    // ==========================================
    if (url.pathname.endsWith("/process-withdrawal")) {
        const auth = await verifyAdminCaller(req);
        if (!auth.ok) return json({ error: "Unauthorized" }, 401, cors);
        try {
            const { withdrawalId, action } = await req.json();
            if (!withdrawalId) return json({ error: "withdrawalId required" }, 400, cors);
            const { data: withdrawal } = await supabaseAdmin
                .from("withdrawals").select("*").eq("id", withdrawalId).single();
            if (!withdrawal) return json({ error: "Not found" }, 404, cors);
            if (action === "reject") {
                const { data: claimed } = await supabaseAdmin.rpc("system_claim_withdrawal", {
                    p_withdrawal_id: withdrawalId, p_next_status: "rejected",
                });
                if (claimed !== true) return json({ error: "Already processed" }, 409, cors);
                return json({ status: "rejected" }, 200, cors);
            }
            if (action === "mark_paid_manual") {
                const { data: claimed } = await supabaseAdmin.rpc("system_claim_withdrawal", {
                    p_withdrawal_id: withdrawalId, p_next_status: "paid",
                });
                if (claimed !== true) return json({ error: "Already processed" }, 409, cors);
                await supabaseAdmin.from("withdrawals").update({
                    admin_note: `Manually paid via ${withdrawal.method}`,
                }).eq("id", withdrawalId);
                return json({ status: "paid" }, 200, cors);
            }
            if (action === "approve") {
                // Claim BEFORE calling BTCPay. The old code read, paid, then wrote —
                // so a double-click sent two real Lightning payouts for one request.
                const { data: claimed } = await supabaseAdmin.rpc("system_claim_withdrawal", {
                    p_withdrawal_id: withdrawalId, p_next_status: "processing",
                });
                if (claimed !== true) return json({ error: "Already processed" }, 409, cors);
                let payoutRes: Response;
                try {
                    payoutRes = await fetch(
                        `${BTCPAY_URL}/api/v1/stores/${BTCPAY_STORE_ID}/payouts`,
                        {
                            method: "POST",
                            headers: {
                                "Content-Type": "application/json",
                                "Authorization": `token ${BTCPAY_API_KEY}`,
                            },
                            body: JSON.stringify({
                                destination: withdrawal.destination,
                                amount: Number(withdrawal.amount_after_fee).toFixed(2),
                                paymentMethod: "BTC-LightningNetwork",
                            }),
                        },
                    );
                } catch (e) {
                    console.error("BTCPay unreachable:", e);
                    sendAlert(`BTCPay unreachable while paying withdrawal ${withdrawalId} — returned to pending.`);
                    await supabaseAdmin.from("withdrawals")
                        .update({ status: "pending", admin_note: "Payout error — provider unreachable" })
                        .eq("id", withdrawalId);
                    return json({ error: "Payment provider unreachable" }, 502, cors);
                }
                if (!payoutRes.ok) {
                    const errText = await payoutRes.text();
                    console.error("BTCPay payout failed:", errText);
                    sendAlert(`Admin-forced payout FAILED for withdrawal ${withdrawalId} — returned to pending.`);
                    await supabaseAdmin.from("withdrawals")
                        .update({ status: "pending", admin_note: "BTCPay payout rejected — needs review" })
                        .eq("id", withdrawalId);
                    return json({ error: "BTCPay payout failed — request returned to pending" }, 502, cors);
                }
                const payoutData = await payoutRes.json();
                await supabaseAdmin.from("withdrawals").update({
                    status: "paid",
                    processed_at: new Date().toISOString(),
                    admin_note: `Admin-forced BTCPay payout: ${payoutData.id}`,
                }).eq("id", withdrawalId);
                return json({ status: "paid", payoutId: payoutData.id }, 200, cors);
            }
            return json({ error: "Invalid action" }, 400, cors);
        } catch (e) {
            console.error("process-withdrawal failed:", e);
            return json({ error: "Could not process withdrawal" }, 500, cors);
        }
    }
    // ==========================================
    // ROUTE: BTCPay webhook
    // ==========================================
    const rawBody = await req.text();
    const signature = req.headers.get("btcpay-sig");
    if (!(await verifySignature(rawBody, signature))) {
        return new Response("Invalid signature", { status: 401 });
    }
    let event: { invoiceId?: string; type?: string; deliveryId?: string };
    try {
        event = JSON.parse(rawBody);
    } catch {
        return new Response("Invalid JSON", { status: 400 });
    }
    const { invoiceId, type: eventType, deliveryId: payloadDeliveryId } = event;
    if (!invoiceId || !eventType) return new Response("Malformed event", { status: 400 });
    // Idempotency. BTCPay retries every delivery until it gets a 200, and it
    // can also deliver the same event twice side by side. The first thing we do
    // with a verified event is claim its delivery id; a duplicate (unique
    // violation 23505) is acknowledged with 200 so BTCPay stops retrying.
    // Without deliveryId in the payload we fall back to a hash of the raw body,
    // which is identical across retries of the same delivery.
    const deliveryId = (event as { deliveryId?: string }).deliveryId ?? `hash:${await sha256Hex(rawBody)}`;
    const { error: dedupErr } = await supabaseAdmin
        .from("webhook_events")
        .insert({ delivery_id: deliveryId, invoice_id: invoiceId, event_type: eventType });
    if (dedupErr?.code === "23505") return new Response("Duplicate delivery", { status: 200 });
    if (dedupErr) {
        // A missing webhook_events table (migration 0033 not applied yet) must not
        // stop settlement — but it must be loud, because idempotency is off.
        console.error("webhook_events insert failed (is migration 0033 applied?):", dedupErr.message);
    }
    const { data: payment } = await supabaseAdmin
        .from("payments").select("*").eq("btcpay_invoice_id", invoiceId).single();
    if (!payment) return new Response("Payment not found", { status: 404 });
    // A settled payment is money that already landed and may already have been
    // withdrawn. A later InvoiceExpired/InvoiceInvalid event must never walk it
    // back, or the creator's balance silently goes negative.
    if (payment.status === "settled") {
        return new Response("Already settled", { status: 200 });
    }
    let newStatus: string | null = null;
    if (eventType === "InvoiceSettled") newStatus = "settled";
    else if (eventType === "InvoiceExpired") newStatus = "expired";
    else if (eventType === "InvoiceProcessing" || eventType === "InvoiceReceivedPayment") newStatus = "pending";
    else if (eventType === "InvoiceInvalid") newStatus = "invalid";
    if (!newStatus) return new Response("Event ignored", { status: 200 });
    const updatePayload: Record<string, unknown> = { status: newStatus };
    if (newStatus === "settled") {
        const authoritativeAmount = await fetchInvoiceAmountUsd(
            invoiceId,
            payment.btcpay_store_id ?? null,
            payment.btcpay_api_key_env ?? null,
        );
        updatePayload.settled_at = new Date().toISOString();
        updatePayload.amount_settled = authoritativeAmount ?? payment.amount_requested;
    }
    // Conditional update: if a concurrent delivery of the same event already
    // settled this row, this write matches nothing instead of overwriting it.
    const { data: updated } = await supabaseAdmin
        .from("payments")
        .update(updatePayload)
        .eq("id", payment.id)
        .neq("status", "settled")
        .select("id");
    if (newStatus === "settled" && updated && updated.length > 0) {
        const slug = await linkSlugFor(payment.payment_link_id ?? null);
        const settledAmt = updatePayload.amount_settled ?? payment.amount_requested;
        sendSettledAlert(`✅ Payment settled: $${Number(settledAmt).toFixed(2)} via /${slug} (invoice ${invoiceId})`);
        await maybeQueueAutoWithdrawal(payment.user_id);
    }
    return new Response("OK", { status: 200 });
});
/**
* Auto-queue is now a thin wrapper over system_queue_withdrawal(), which
* shares the balance definition, the row lock and the fee maths with
* request_withdrawal(). The old TypeScript version computed its own
* balance from untagged payments — a different number than the dashboard
* showed, and one that double-counted money already in a manual request.
*/
async function maybeQueueAutoWithdrawal(userId: string) {
    // cspell:ignore supabase
    const { error } = await supabaseAdmin.rpc("system_queue_withdrawal", {
        p_user_id: userId,
    });
    if (error) console.error("Auto-queue failed for", userId, error.message);
}
