import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

/**
* Boltpay — daily reconciliation
*
* Compares what BTCPay says it settled against what the Boltpay ledger
* records, for one 5pm–5pm Dhaka cycle, per store.
*
* Why this exists: every other safeguard in this system checks Boltpay
* against itself. The webhook writes a payment, the ledger sums those
* payments, the backup copies those sums. If a webhook is never
* delivered — dropped in transit, rejected while the function was
* redeploying, silently 500'd — the payment settles at BTCPay and simply
* never appears here. Nothing internal can notice, because from
* Boltpay's point of view the invoice was never paid.
*
* This is the one job that looks outside. A mismatch means real money
* moved that the creator has not been credited for.
*
* Read-only. It never writes to payments or withdrawals — it reports,
* and a human decides. An automated "fix" here could credit a creator
* twice, which is worse than the problem it solves.
*/

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BTCPAY_URL = Deno.env.get("BTCPAY_URL")!;
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// Same whitelist the other functions use. A shop names which secret holds
// its key rather than storing the key itself.
const API_KEY_ENVS: Record<string, string | undefined> = {
  BTCPAY_API_KEY: Deno.env.get("BTCPAY_API_KEY"),
  BTCPAY_API_KEY_2: Deno.env.get("BTCPAY_API_KEY_2"),
  BTCPAY_API_KEY_3: Deno.env.get("BTCPAY_API_KEY_3"),
  BTCPAY_API_KEY_4: Deno.env.get("BTCPAY_API_KEY_4"),
  BTCPAY_API_KEY_5: Deno.env.get("BTCPAY_API_KEY_5"),
};

/**
* What daily_totals_for_cycle() returns.
*
* supabase-js infers an untyped .rpc() result as `{}`, so every property
* read off it is a type error under `deno check`. Declaring the shape is
* the fix, and it doubles as a record of the contract this function
* depends on.
*/
type CycleTotals = {
  cycle_start: string;
  cycle_end: string;
  total_settled: number | string;
  payment_count: number | string;
  total_withdrawn: number | string;
};

const BD_OFFSET_MS = 6 * 60 * 60 * 1000;

/** The cycle date `daysAgo` cycles back, matching daily-report exactly. */
function bdCycleDate(daysAgo: number): string {
  const t = new Date(Date.now() + BD_OFFSET_MS - 17 * 3600000 - daysAgo * 86400000);
  return t.toISOString().slice(0, 10);
}

/** Alerts, same shape as the other functions. Never throws. */
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
* Every settled invoice BTCPay holds for one store in one window.
*
* BTCPay pages its invoice list, so this pages too — the same 1000-row
* lesson that silently truncated the ledger backup applies to any API
* that caps a response.
*/
async function fetchBtcpaySettled(
  storeId: string,
  apiKey: string,
  startMs: number,
  endMs: number,
): Promise<{ total: number; ids: Set<string> } | null> {
  const ids = new Set<string>();
  let total = 0;
  const TAKE = 250;

  for (let skip = 0; ; skip += TAKE) {
    const url = new URL(`${BTCPAY_URL}/api/v1/stores/${storeId}/invoices`);
    // BTCPay expects seconds, not milliseconds.
    url.searchParams.set("startDate", String(Math.floor(startMs / 1000)));
    url.searchParams.set("endDate", String(Math.floor(endMs / 1000)));
    url.searchParams.set("take", String(TAKE));
    url.searchParams.set("skip", String(skip));

    const res = await fetch(url.toString(), {
      headers: { "Authorization": `token ${apiKey}` },
    });
    if (!res.ok) {
      console.error(`BTCPay ${storeId} returned ${res.status}`);
      return null;
    }
    const page = await res.json();
    if (!Array.isArray(page)) return null;

    for (const inv of page) {
      // "Settled" is BTCPay's terminal paid state. "Processing" means
      // seen but not confirmed, and counting it here would report a
      // mismatch against a ledger that is correctly still waiting.
      if (inv?.status !== "Settled") continue;
      if (inv?.currency !== "USD") continue;
      const amount = Number(inv?.amount);
      if (!Number.isFinite(amount)) continue;
      ids.add(String(inv.id));
      total += amount;
    }

    if (page.length < TAKE) break;
  }

  return { total: Number(total.toFixed(2)), ids };
}

Deno.serve(async (req) => {
  const cronSecret = Deno.env.get("CRON_SECRET") ?? "";
  if (!cronSecret || req.headers.get("x-cron-secret") !== cronSecret) {
    return new Response("Unauthorized", { status: 401 });
  }

  const url = new URL(req.url);
  const requested = Number(url.searchParams.get("days"));
  const days = Number.isFinite(requested)
    ? Math.min(Math.max(Math.trunc(requested), 1), 30)
    : 1;

  // Reconcile yesterday by default, not today: a cycle still in progress
  // will always look short, and alerting on that every run would train
  // everyone to ignore the alert.
  const offset = Number(url.searchParams.get("offset")) || 1;

  const { data: shops, error: shopErr } = await supabase
    .from("btcpay_shops")
    .select("id, name, store_id, api_key_env, is_active");
  if (shopErr) {
    return new Response(JSON.stringify({ error: shopErr.message }), { status: 500 });
  }

  const report: unknown[] = [];
  const problems: string[] = [];

  for (let d = 0; d < days; d++) {
    const cycleDate = bdCycleDate(d + offset);

    const { data: boundsRaw, error: bErr } = await supabase
      .rpc("daily_totals_for_cycle", { p_cycle_date: cycleDate })
      .maybeSingle();
    if (bErr || !boundsRaw) {
      problems.push(`${cycleDate}: could not read the Boltpay total (${bErr?.message ?? "no row"})`);
      continue;
    }
    const bounds = boundsRaw as CycleTotals;

    const startMs = new Date(bounds.cycle_start).getTime();
    const endMs = new Date(bounds.cycle_end).getTime();
    const ledgerTotal = Number(bounds.total_settled || 0);

    let btcpayTotal = 0;
    let btcpayIds = new Set<string>();
    let unreadable = 0;

    for (const shop of shops ?? []) {
      if (!shop.store_id) continue;
      const apiKey = API_KEY_ENVS[shop.api_key_env || "BTCPAY_API_KEY"];
      if (!apiKey) {
        unreadable++;
        problems.push(`${cycleDate}: no API key configured for shop "${shop.name}" (${shop.api_key_env})`);
        continue;
      }
      const result = await fetchBtcpaySettled(shop.store_id, apiKey, startMs, endMs);
      if (!result) {
        unreadable++;
        problems.push(`${cycleDate}: BTCPay unreachable for shop "${shop.name}"`);
        continue;
      }
      btcpayTotal += result.total;
      for (const id of result.ids) btcpayIds.add(id);
    }

    // A store we could not read makes the comparison meaningless — a
    // "missing $500" that is really "we could not ask" would send someone
    // hunting for a payment that is fine.
    if (unreadable > 0) {
      report.push({ cycleDate, skipped: true, reason: `${unreadable} store(s) unreadable` });
      continue;
    }

    btcpayTotal = Number(btcpayTotal.toFixed(2));

    // Which settled BTCPay invoices are missing from our ledger entirely.
    // This is the actionable part: each id is a payment a creator has not
    // been credited for.
    // Paged, not a single .select() — PostgREST caps a plain query at 1000
    // rows, and a busy 5pm-5pm cycle can settle more than that. Capped
    // there before, this silently marked real, already-known invoices as
    // "missing" and fired a false reconciliation alert. Same lesson as
    // the ledger backup's own fetchAll(), applied here.
    const known: { btcpay_invoice_id: string | null }[] = [];
    const PAGE = 1000;
    for (let from = 0; ; from += PAGE) {
      const { data: page, error: pageErr } = await supabase
        .from("payments")
        .select("btcpay_invoice_id")
        .eq("status", "settled")
        .gte("settled_at", bounds.cycle_start)
        .lt("settled_at", bounds.cycle_end)
        .range(from, from + PAGE - 1);
      if (pageErr) {
        problems.push(`${cycleDate}: could not page known invoices (${pageErr.message})`);
        break;
      }
      known.push(...(page ?? []));
      if (!page || page.length < PAGE) break;
    }
    const knownIds = new Set(known.map((r) => String(r.btcpay_invoice_id)));
    const missing = [...btcpayIds].filter((id) => !knownIds.has(id));

    const diff = Number((btcpayTotal - ledgerTotal).toFixed(2));
    // Rounding across many invoices can drift by a cent or two; anything
    // larger is a real gap worth a human's attention.
    const matched = Math.abs(diff) < 0.05 && missing.length === 0;

    report.push({
      cycleDate,
      cycleStart: bounds.cycle_start,
      btcpayTotal,
      ledgerTotal,
      diff,
      btcpayInvoices: btcpayIds.size,
      ledgerPayments: Number(bounds.payment_count || 0),
      missingInvoiceIds: missing.slice(0, 25),
      missingCount: missing.length,
      matched,
    });

    if (!matched) {
      problems.push(
        `${cycleDate}: BTCPay $${btcpayTotal} vs ledger $${ledgerTotal} (diff $${diff}), ${missing.length} invoice(s) missing from the ledger`,
      );
    }
  }

  if (problems.length) {
    sendAlert(`Reconciliation found ${problems.length} issue(s):\n${problems.join("\n")}`);
  }

  return new Response(
    JSON.stringify({ days, offset, report, problems }, null, 2),
    {
      status: 200,
      headers: { "Content-Type": "application/json" },
    },
  );
});
