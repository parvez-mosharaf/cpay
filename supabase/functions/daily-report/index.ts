import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

// Bangladesh is UTC+6 with no DST, so a fixed offset is safe here.
const BD_OFFSET_MS = 6 * 60 * 60 * 1000;

/**
* The cycle date `daysAgo` cycles before the current one.
*
* A "cycle" runs 5pm Dhaka to 5pm Dhaka, and is named after the date it
* STARTED on. Shifting back 17 hours before taking the date turns
* "5pm today through 4:59pm tomorrow" into a single calendar date —
* the same arithmetic staff_daily_settled() does in SQL.
*/
function bdCycleDate(daysAgo: number): string {
  const t = new Date(Date.now() + BD_OFFSET_MS - 17 * 3600000 - daysAgo * 86400000);
  return t.toISOString().slice(0, 10);
}

async function computeDay(dateStr: string) {
  // The totals are computed in SQL, not here.
  //
  // This used to fetch the day's rows and add them up in JavaScript,
  // which meant PostgREST's 1000-row cap silently truncated any busy
  // day — the same failure as the ledger backup. It also bucketed by
  // midnight Dhaka while every live view on the site buckets 5pm–5pm,
  // so the archive and the screen disagreed about which day a payment
  // belonged to.
  //
  // daily_totals_for_cycle() fixes both: the database sums without a row
  // limit, using the exact cycle boundary admin_daily_settled() and
  // staff_daily_settled() already use.
  // The shape daily_totals_for_cycle() returns.
  //
  // Without generated database types, supabase-js infers the result of an
  // .rpc().maybeSingle() as `{}` — so reading .total_settled off it is a
  // type error. `deno check` catches that; esbuild does not, because it
  // strips types rather than checking them. Declaring the shape here is
  // both the fix and the documentation.
  type CycleTotals = {
    cycle_start: string;
    cycle_end: string;
    total_settled: number | string;
    payment_count: number | string;
    total_withdrawn: number | string;
    total_admin_profit: number | string;
  };

  const { data, error } = await supabase
    .rpc("daily_totals_for_cycle", { p_cycle_date: dateStr })
    .maybeSingle();
  if (error) throw new Error(`daily_totals_for_cycle: ${error.message}`);
  if (!data) throw new Error(`daily_totals_for_cycle returned nothing for ${dateStr}`);
  const totals = data as CycleTotals;

  const totalSettled = Number(totals.total_settled || 0);
  const totalWithdrawn = Number(totals.total_withdrawn || 0);
  const paymentCount = Number(totals.payment_count || 0);

  // Read from the database, not recomputed here.
  //
  // This figure has now had three definitions: `totalSettled *
  // (sell_rate - buy_rate)` (always 0, since those rates seed equal),
  // then `totalSettled * margin / 2`, and now real fee revenue —
  // sum(amount_requested - amount_after_fee) over paid withdrawals.
  //
  // Each time it changed, a copy was left behind somewhere. Migration
  // 0059 updated admin_global_stats() and missed both admin_daily_settled()
  // and this file, so the same period could report three different
  // profits depending on which screen you looked at. Taking the number
  // from daily_totals_for_cycle() — the function this already calls for
  // everything else in the row — means there is exactly one definition
  // left to change.
  const adminProfit = Number(totals.total_admin_profit || 0);

  const { error: upsertErr } = await supabase.from("daily_stats").upsert({
    stat_date: dateStr,
    total_settled: totalSettled,
    total_admin_profit: adminProfit,
    total_withdrawn: totalWithdrawn,
    payment_count: paymentCount,
    computed_at: new Date().toISOString(),
  }, { onConflict: "stat_date" });
  if (upsertErr) throw new Error(`upsert: ${upsertErr.message}`);

  return {
    date: dateStr,
    cycleStart: totals.cycle_start,
    totalSettled,
    totalWithdrawn,
    adminProfit,
    paymentCount,
  };
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

Deno.serve(async (req) => {
  const cronSecret = Deno.env.get("CRON_SECRET") ?? "";
  if (!cronSecret || req.headers.get("x-cron-secret") !== cronSecret) {
    return new Response("Unauthorized", { status: 401 });
  }

  // Recompute a window of days, not just one.
  //
  // The old version wrote a single row for "today" and nothing else. Two
  // consequences: any day the cron failed to fire was a permanent hole in
  // the ledger with no way to fill it, and because the job runs at 17:00
  // Dhaka the last seven hours of every day were never counted.
  //
  // Upsert makes recomputation idempotent, so re-running a day is always
  // safe and a late settlement gets picked up on the next pass.
  const url = new URL(req.url);
  const requested = Number(url.searchParams.get("days"));
  const days = Number.isFinite(requested)
    ? Math.min(Math.max(Math.trunc(requested), 1), 90)
    : 3;

  // profit_margin_percent is no longer read here — admin profit is real
  // fee revenue now, computed in daily_totals_for_cycle(). The setting
  // row is left in place because admin_global_stats() still uses it for
  // calculated_node_balance, which is a different figure entirely.

  const results = [];
  const failures = [];
  for (let i = 0; i < days; i++) {
    const dateStr = bdCycleDate(i);
    try {
      results.push(await computeDay(dateStr));
    } catch (e) {
      console.error(`daily-report failed for ${dateStr}:`, e);
      failures.push({ date: dateStr, error: String(e) });
    }
  }

  if (failures.length) {
    sendAlert(`daily-report failed for ${failures.length} day(s): ${failures.map((f) => f.date).join(", ")}`);
  }

  return new Response(
    JSON.stringify({ days, results, failures }),
    {
      status: failures.length && !results.length ? 500 : 200,
      headers: { "Content-Type": "application/json" },
    },
  );
});
