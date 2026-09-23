import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

function requireCron(req: Request): boolean {
  const secret = Deno.env.get("CRON_SECRET");
  if (!secret) return false;
  return req.headers.get("x-cron-secret") === secret;
}

async function postDiscord(url: string, text: string) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ content: text.slice(0, 1900) }),
  });
  if (!res.ok) console.error("discord digest failed", res.status, await res.text());
}

async function postTelegram(token: string, chat: string, text: string) {
  const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chat, text, disable_web_page_preview: true }),
  });
  if (!res.ok) console.error("telegram digest failed", res.status, await res.text());
}

function formatDigest(
  name: string,
  cycle: string,
  total: number,
  count: number,
  rows: { link_slug: string; link_name: string; link_settled: number; link_count: number; cost_percent: number }[],
) {
  const lines = [
    `CPAY daily settled — ${name}`,
    `Cycle ${cycle} (5:00 PM Asia/Dhaka → 5:00 PM)`,
    `Total settled: $${total.toFixed(2)} across ${count} payment(s)`,
    "",
    "By payment link:",
  ];
  if (!rows.length) {
    lines.push("No settled payments this cycle.");
  } else {
    for (const r of rows) {
      const label = r.link_name || r.link_slug;
      lines.push(
        `• /${r.link_slug} (${label}) — $${Number(r.link_settled).toFixed(2)} / ${r.link_count} · cost ${Number(r.cost_percent).toFixed(2)}%`,
      );
    }
  }
  return lines.join("\n");
}

Deno.serve(async (req) => {
  if (req.method !== "POST" && req.method !== "GET") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!requireCron(req)) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
  }

  const { data: targets, error } = await supabase.rpc("list_reseller_alert_targets");
  if (error) {
    console.error(error);
    return new Response(JSON.stringify({ error: "target lookup failed" }), { status: 500 });
  }

  const sent: string[] = [];
  for (const t of targets ?? []) {
    const { data: rows, error: dErr } = await supabase.rpc("reseller_cycle_digest", {
      p_reseller_id: t.reseller_id,
      p_cycle_date: null,
    });
    if (dErr) {
      console.error("digest", t.reseller_id, dErr.message);
      continue;
    }
    const list = (rows ?? []) as {
      cycle_date: string;
      total_settled: number;
      payment_count: number;
      link_slug: string;
      link_name: string;
      link_settled: number;
      link_count: number;
      cost_percent: number;
    }[];
    const total = Number(list[0]?.total_settled ?? 0);
    const count = Number(list[0]?.payment_count ?? 0);
    const cycle = list[0]?.cycle_date ?? "today";
    const text = formatDigest(t.display_name || t.email, String(cycle), total, count, list.filter((r) => r.link_slug));
    if (t.discord_webhook) await postDiscord(t.discord_webhook, text);
    if (t.telegram_bot_token && t.telegram_chat_id) {
      await postTelegram(t.telegram_bot_token, t.telegram_chat_id, text);
    }
    sent.push(t.reseller_id);
  }

  return new Response(JSON.stringify({ ok: true, resellers: sent.length }), {
    headers: { "Content-Type": "application/json" },
  });
});
