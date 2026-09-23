const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8" } });
const equalSecret = (a: string | null, b: string | undefined) => Boolean(a && b && a.length === b.length && a === b);

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const expected = Deno.env.get("TELEGRAM_REPORT_SECRET");
  if (!expected || !equalSecret(req.headers.get("x-telegram-report-secret"), expected)) return json({ error: "unauthorized" }, 401);
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRole) return json({ error: "server_not_configured" }, 500);
  let body: { action?: string; range?: string; days?: number; reference?: string; amount?: number };
  try { body = await req.json(); } catch { return json({ error: "invalid_json" }, 400); }

  const rpc = async (name: string, args: Record<string, unknown>) => {
    const res = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST", headers: { "content-type": "application/json", apikey: serviceRole, authorization: `Bearer ${serviceRole}` }, body: JSON.stringify(args)
    });
    const text = await res.text(); let parsed: unknown = text; try { parsed = JSON.parse(text); } catch { /* keep text */ }
    return { res, parsed };
  };

  if (body.action === "health") {
    const cron = Deno.env.get("CRON_SECRET");
    if (!cron) return json({ error: "cron_secret_not_configured" }, 500);
    const health = await fetch(`${supabaseUrl}/functions/v1/health?alert=0`, { headers: { "x-cron-secret": cron } });
    const text = await health.text(); let parsed: unknown = text; try { parsed = JSON.parse(text); } catch { /* keep text */ }
    return json({ ok: health.ok, status: health.status, result: parsed }, health.ok ? 200 : 503);
  }

  if (body.action === "verify_payment") {
    const result = await rpc("telegram_find_payments", { p_reference: body.reference ?? null, p_amount: body.amount ?? null });
    return json(result.parsed, result.res.status);
  }

  const range = ["today", "7d", "30d", "all"].includes(body.range ?? "") ? body.range : "today";
  const days = Math.min(Math.max(Number(body.days ?? 7) || 7, 1), 30);
  const result = await rpc("telegram_context", { p_range: range, p_days: days });
  return json(result.parsed, result.res.status);
});
