type Env = {
  AI: { run: (model: string, input: unknown) => Promise<any> };
  AI_MODEL?: string;
  TELEGRAM_BOT_TOKEN: string;
  TELEGRAM_WEBHOOK_SECRET: string;
  TELEGRAM_ALLOWED_CHAT_IDS: string;
  TELEGRAM_ALLOWED_USER_IDS: string;
  TELEGRAM_REPORT_URL: string;
  TELEGRAM_REPORT_SECRET: string;
};

type TelegramUpdate = {
  message?: {
    message_id: number;
    chat: { id: number; type: string; title?: string };
    from?: { id: number; is_bot?: boolean; first_name?: string; username?: string };
    sender_chat?: { id: number; type?: string };
    text?: string;
    caption?: string;
    photo?: Array<{ file_id: string; width: number; height: number }>;
    voice?: { file_id: string; duration?: number };
    video?: { file_id: string; duration?: number; file_size?: number };
    document?: { file_id: string; file_name?: string; mime_type?: string; file_size?: number };
  };
};

const MAX_TELEGRAM_CHARS = 3900;
const asIds = (value: string) => new Set(value.split(/[\s,]+/).map((x) => x.trim()).filter(Boolean));
const escapeHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const money = (value: unknown) => {
  const n = Number(value ?? 0);
  return Number.isFinite(n) ? `$${n.toFixed(2)}` : "$0.00";
};
const num = (value: unknown) => Number(value ?? 0).toLocaleString("en-US");

async function telegram(env: Env, method: string, body: Record<string, unknown>) {
  const res = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) console.error("Telegram API error", method, res.status, await res.text());
  return res;
}

async function report(env: Env, action: "context" | "health" | "verify_payment", range = "today", extra: Record<string, unknown> = {}) {
  const res = await fetch(env.TELEGRAM_REPORT_URL, {
    method: "POST",
    headers: { "content-type": "application/json", "x-telegram-report-secret": env.TELEGRAM_REPORT_SECRET },
    body: JSON.stringify({ action, range, days: range === "30d" ? 30 : range === "7d" ? 7 : 7, ...extra }),
  });
  const body = await res.json().catch(() => ({ error: "invalid_report_response" }));
  if (!res.ok) throw new Error(typeof body === "object" ? JSON.stringify(body) : String(body));
  return body as any;
}

async function telegramFile(env: Env, fileId: string) {
  const meta = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/getFile?file_id=${encodeURIComponent(fileId)}`).then((r) => r.json<any>());
  const path = meta?.result?.file_path;
  if (!path) throw new Error("Telegram file path unavailable");
  const res = await fetch(`https://api.telegram.org/file/bot${env.TELEGRAM_BOT_TOKEN}/${path}`);
  if (!res.ok) throw new Error(`Telegram file download failed: ${res.status}`);
  return new Uint8Array(await res.arrayBuffer());
}

async function transcribeVoice(env: Env, fileId: string) {
  const audio = await telegramFile(env, fileId);
  const result = await env.AI.run("@cf/openai/whisper", { audio: [...audio] });
  return String(result?.text ?? result?.transcription ?? result?.response ?? "").trim();
}

async function inspectPaymentImage(env: Env, fileId: string) {
  const image = await telegramFile(env, fileId);
  const prompt = "Read this payment screenshot. Extract only visible facts: amount, currency, invoice/reference/transaction ID, displayed status, merchant/recipient, and date/time. Do not decide whether it is genuine. Return one short JSON object with keys amount, reference, status, merchant, dateTime, notes. Use null when not visible.";
  const result = await env.AI.run("@cf/llava-hf/llava-1.5-7b-hf", { image: [...image], prompt, max_tokens: 400 });
  return String(result?.response ?? result?.text ?? "").trim();
}

async function inspectGeneralImage(env: Env, fileId: string) {
  const image = await telegramFile(env, fileId);
  const prompt = "Describe this image in Bangla. Read visible text when possible, explain screens/documents/objects, and clearly separate what is visible from what is uncertain. Do not infer private identity, health, income, or sensitive attributes. This is not necessarily a payment screenshot.";
  const result = await env.AI.run("@cf/llava-hf/llava-1.5-7b-hf", { image: [...image], prompt, max_tokens: 600 });
  return String(result?.response ?? result?.text ?? "").trim();
}

function extractVerification(text: string) {
  const amountMatch = text.match(/(?:amount|total|paid|value)[^0-9]{0,20}(\d+(?:\.\d{1,8})?)/i);
  const refMatch = text.match(/(?:reference|invoice|transaction|txid|id)[^A-Za-z0-9]{0,10}([A-Za-z0-9_-]{8,})/i);
  return { amount: amountMatch ? Number(amountMatch[1]) : null, reference: refMatch?.[1] ?? null };
}

function rangeFor(text: string) {
  if (/30\s*(day|দিন)|৩০\s*দিন|monthly|month/i.test(text)) return "30d";
  if (/7\s*(day|দিন)|৭\s*দিন|weekly|week/i.test(text)) return "7d";
  if (/all[- ]?time|lifetime|সবসময়|সর্বমোট|জীবনকাল/i.test(text)) return "all";
  return "today";
}

function compactReport(context: any) {
  const g = context.global ?? {};
  return [
    `CPAY report — ${context.range ?? "today"}`,
    `Time: ${context.timezone ?? "Asia/Dhaka"}; cycle ${context.cycleBoundary ?? "17:00–17:00"}`,
    `Settled: ${money(g.totalSettled)} (${num(g.paymentCount)} payments)`,
    `Admin profit: ${money(g.adminProfit)}`,
    `Withdrawn: ${money(g.totalWithdrawn)}`,
    `Pending withdrawals: ${num(g.pendingWithdrawalsCount)} — ${money(g.pendingWithdrawalsAmount)}`,
  ].join("\n");
}

function deterministicAnswer(context: any, question: string) {
  const q = question.toLowerCase();
  const g = context.global ?? {};
  if (/^\/(today|week|month|alltime)/.test(q)) {
    return compactReport(context);
  }
  if (/language|languages|ভাষা|কত ভাষা|which language|what languages/.test(q)) {
    return "আমি Bangla ও English text/voice প্রশ্ন বুঝতে পারি—এগুলো এই bot-এ tested। Whisper-এর multilingual support থাকায় আরও কিছু ভাষা transcription হতে পারে, তবে accuracy language ও audio quality-এর উপর নির্ভর করবে। CPAY report-এর উত্তর Bangla বা English-এ দিতে পারি।";
  }
  if (/model|who are you|what can you do|tomar model|তুমি কে|কি পারো|কী পারো|great|hello|hi\b/.test(q)) {
    return "আমি CPAY Intelligence Bot — CPAY-এর read-only operations assistant। আমি profit, settled payments, creator totals, withdrawals, grouped customer locations, health status এবং public URL research সম্পর্কে উত্তর দিতে পারি। আমি কোনো payment বা withdrawal পরিবর্তন করতে পারি না।\n\nAI engine: Cloudflare Workers AI\nData source: CPAY Supabase read-only report API";
  }
  if (/profit|earn|income|লাভ|আয়|আয়|কত হয়েছে|কত হয়েছে/.test(q)) {
    return `${compactReport(context)}\n\nএই report window-তে admin profit: ${money(g.adminProfit)}।`;
  }
  if (/location|country|city|দেশ|শহর|কোথা|কোথায়|কোথায়/.test(q)) {
    const rows = (context.locations ?? []).slice(0, 10);
    return `${compactReport(context)}\n\nGrouped customer locations:\n${rows.length ? rows.map((x: any) => `• ${x.country} / ${x.city}: ${num(x.paymentCount)} payments`).join("\n") : "• অন্তত ২টি settled payment-সহ কোনো grouped location নেই।"}`;
  }
  if (/withdraw|payout|cashout|উইথড্র|withdrawal|তুলেছে|তোলা/.test(q)) {
    const rows = (context.recentWithdrawals ?? []).slice(0, 10);
    return `${compactReport(context)}\n\nRecent withdrawals:\n${rows.length ? rows.map((x: any) => `• ${x.creator}: ${money(x.amountRequested)} → ${x.status}`).join("\n") : "• কোনো withdrawal record নেই।"}`;
  }
  if (/creator|payment|received|settled|পেমেন্ট|পেয়েছে|পেয়েছে|settled/.test(q)) {
    const rows = (context.creators ?? []).slice(0, 10);
    return `${compactReport(context)}\n\nCreator totals:\n${rows.length ? rows.map((x: any) => `• ${x.name}: received ${money(x.settled)}, withdrawn ${money(x.withdrawn)}, payments ${num(x.paymentCount)}`).join("\n") : "• এই window-তে creator activity নেই।"}`;
  }
  if (/daily|day by day|দিনভিত্তিক|প্রতিদিন|breakdown/.test(q)) {
    const rows = (context.daily ?? []).slice(0, 10);
    return `${compactReport(context)}\n\nDaily breakdown:\n${rows.length ? rows.map((x: any) => `• ${x.cycleDate}: settled ${money(x.settled)}, payments ${num(x.paymentCount)}, profit ${money(x.adminProfit)}`).join("\n") : "• Daily breakdown নেই।"}`;
  }
  return null;
}

async function aiAnswer(env: Env, context: any, question: string) {
  const direct = deterministicAnswer(context, question);
  if (direct) return direct;

  const q = question.toLowerCase();
  const cpayQuestion = /cpay|profit|earn|payment|settled|withdraw|payout|creator|location|country|city|health|ledger|payment|পেমেন্ট|লাভ|আয়|উইথড্র|কে কত/.test(q);
  const model = env.AI_MODEL ?? "@cf/meta/llama-3.1-8b-instruct";
  const system = cpayQuestion
    ? `You are CPAY's private operations analyst. Answer in Bangla unless the question is clearly English. Use only the supplied JSON context; never invent numbers. Do not reveal UUIDs, emails, wallet destinations, secrets, or private data. Do not perform writes.`
    : `You are a helpful general knowledge assistant inside the CPAY Telegram bot. Answer the user's question directly and clearly in Bangla or English matching the user. Do not pretend to know current private data. For current facts or a specific website, ask the user to use /research with a public URL. Do not claim access to private accounts.`;
  const prompt = cpayQuestion
    ? `${system}\n\nJSON context:\n${JSON.stringify(context).slice(0, 45000)}\n\nQuestion:\n${question}`
    : `${system}\n\nQuestion:\n${question}`;
  try {
    const attempts = [
      { messages: [{ role: "system", content: system }, { role: "user", content: prompt }], max_tokens: 700, temperature: 0.2 },
      { prompt, max_tokens: 700, temperature: 0.2 },
    ];
    for (const input of attempts) {
      const result = await env.AI.run(model, input);
      const text = result?.response ?? result?.result?.response ?? result?.output_text;
      if (typeof text === "string" && text.trim()) return text.trim();
    }
  } catch (error) {
    console.error("Workers AI failed", error);
  }
  return cpayQuestion
    ? `${compactReport(context)}\n\nআমি প্রশ্নটি পুরোপুরি বুঝিনি। Try: profit, payments, withdrawals, locations, daily breakdown, health, বা /help.`
    : "এই general question-এর AI উত্তর এখন পাওয়া যায়নি। Bangla/English-এ আবার সংক্ষেপে জিজ্ঞেস করুন, অথবা নির্দিষ্ট website-এর জন্য /research URL ব্যবহার করুন।";
}

async function research(env: Env, urlText: string) {
  let url: URL;
  try { url = new URL(urlText); } catch { return "Usage: /research https://example.com"; }
  if (url.protocol !== "https:" || url.username || url.password) return "শুধু public HTTPS URL গ্রহণ করা হয়।";
  if (/^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[0-1])\.|0\.)/.test(url.hostname)) return "Private/local address গ্রহণ করা হয় না।";
  const res = await fetch(url, { headers: { "user-agent": "CPAY-Public-Research/1.0" }, redirect: "follow" });
  if (!res.ok) return `Public page fetch করা যায়নি: HTTP ${res.status}. Login, robots policy বা anti-bot restriction থাকতে পারে।`;
  const html = (await res.text()).slice(0, 1_000_000);
  const title = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]?.replace(/<[^>]+>/g, " ").trim() ?? "";
  const description = html.match(/<meta[^>]+(?:name|property)=["'](?:description|og:description)["'][^>]+content=["']([^"']*)/i)?.[1] ?? "";
  const text = html.replace(/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>|<[^>]+>/gi, " ").replace(/\s+/g, " ").slice(0, 9000);
  const blockedSocial = /facebook\.com|instagram\.com|linkedin\.com|tiktok\.com/i.test(url.hostname) && text.length < 180;
  if (blockedSocial) return `এই social page-এর public content server-side পাওয়া যায়নি। Title: ${title || "Unavailable"}\nসম্ভাব্য কারণ: login requirement, JavaScript-only content বা platform anti-bot restriction। Private data bypass করা হবে না।`;
  if (text.length < 80 && !description) return `Page পাওয়া গেছে, কিন্তু readable public content পাওয়া যায়নি। Title: ${title || "Unavailable"}`;
  const prompt = `Summarize this public web page in Bangla. Separate verified page facts from uncertainty. Do not infer private identity, location, income, or sensitive attributes. URL: ${url.href}\nTitle: ${title}\nDescription: ${description}\nVisible text: ${text}`;
  try {
    const result = await env.AI.run(env.AI_MODEL ?? "@cf/meta/llama-3.1-8b-instruct", { messages: [{ role: "user", content: prompt }], max_tokens: 700, temperature: 0.1 });
    const answer = result?.response ?? result?.result?.response ?? result?.output_text;
    return answer ? String(answer).trim() : `Title: ${title}\n${description || "Visible summary তৈরি করা যায়নি।"}`;
  } catch { return `Title: ${title}\n${description || "AI summary unavailable; public page text পাওয়া গেছে কিন্তু summarize করা যায়নি।"}`; }
}

async function handle(env: Env, update: TelegramUpdate) {
  const message = update.message;
  if (!message) return;
  const chatId = String(message.chat.id);
  if (!asIds(env.TELEGRAM_ALLOWED_CHAT_IDS).has(chatId)) return;
  const userId = message.from?.id;
  if (!userId || !asIds(env.TELEGRAM_ALLOWED_USER_IDS).has(String(userId))) return;

  const raw = (message.text ?? message.caption ?? "").trim();
  let answer = "";
  try {
    if (message.voice) {
      const transcript = await transcribeVoice(env, message.voice.file_id);
      if (!transcript) answer = "Voice পাওয়া গেছে, কিন্তু transcription করা যায়নি। পরিষ্কার Bangla/English voice পাঠান।";
      else {
        const context = await report(env, "context", rangeFor(transcript));
        answer = `Voice transcript: ${transcript}\n\n${await aiAnswer(env, context, transcript)}`;
      }
    } else if (message.photo?.length) {
      const largest = message.photo[message.photo.length - 1];
      const wantsVerify = /verify|payment|receipt|invoice|transaction|fake|real|ভেরিফাই|পেমেন্ট|রসিদ|ইনভয়েস|আসল|নকল/i.test(raw);
      if (!wantsVerify) {
        const explanation = await inspectGeneralImage(env, largest.file_id);
        answer = explanation || "ছবির reliable visual analysis পাওয়া যায়নি। Caption-এ প্রশ্ন লিখে আবার পাঠান।";
      } else {
        const extracted = await inspectPaymentImage(env, largest.file_id);
        const found = extractVerification(extracted);
        const matches = await report(env, "verify_payment", "today", { reference: found.reference, amount: found.amount });
        const rows = Array.isArray(matches) ? matches : [];
        const verdict = rows.some((x: any) => x.status === "settled") ? "VERIFIED" : rows.length ? "MISMATCH" : "UNVERIFIED";
        answer = `Payment screenshot screening: ${verdict}\n\nVisible extraction:\n${extracted || "No reliable text extracted."}\n\nLedger match: ${rows.length ? JSON.stringify(rows).slice(0, 1600) : "No matching CPAY ledger record found."}\n\nScreenshot alone is never proof; VERIFIED requires a matching settled CPAY record.`;
      }
    } else if (message.document) {
      const name = message.document.file_name ?? "document";
      answer = `Document received: ${name}\n\nএই build-এ PDF/document text extraction এখনো চালু হয়নি। PDF-এর গুরুত্বপূর্ণ page screenshot হিসেবে পাঠালে আমি visible text/image analyse করতে পারব।`;
    } else if (message.video) {
      answer = "Video received. এই build-এ voice এবং image analysis চালু আছে; video audio/frame analysis এখনো চালু হয়নি।";
    } else if (!raw) {
      return;
    } else {
      const text = raw.replace(/^\/\w+(?:@\w+)?\s*/i, "").trim();
      if (/^\/start|^\/help/i.test(raw)) {
        answer = "CPAY Intelligence Bot\n\nText, voice এবং payment screenshot পাঠাতে পারেন। প্রশ্ন করুন: profit, payments, withdrawals, locations, health বা /research <public URL>।\n\nCommands: /today /week /month /alltime /health /research <URL> /help";
      } else if (/^\/health/i.test(raw) || /health|স্বাস্থ্য|system status|সিস্টেম/i.test(text)) {
        const h = await report(env, "health");
        answer = h.result?.healthy ? "✅ CPAY health: সব critical check ঠিক আছে।" : `⚠️ CPAY health সমস্যা: ${JSON.stringify(h.result?.checks ?? h.result).slice(0, 1800)}`;
      } else if (/^\/research\s*/i.test(raw)) {
        const target = raw.replace(/^\/research\s*/i, "").trim();
        answer = target ? await research(env, target) : "Usage: /research https://example.com\nশুধু public HTTPS URL দিন।";
      } else if (/কেন\s*(যায়নি|হয়নি)|why\s*(failed|not)|research.*fail/i.test(text)) {
        answer = "আগের social research-এ public content পাওয়া যায়নি কারণ platform login, JavaScript-only page বা anti-bot restriction থাকতে পারে। Private data bypass করা হবে না। একটি public HTTPS URL দিয়ে আবার /research করুন।";
      } else {
        const range = /^\/week/i.test(raw) ? "7d" : /^\/month/i.test(raw) ? "30d" : /^\/alltime/i.test(raw) ? "all" : rangeFor(text);
        const context = await report(env, "context", range);
        answer = await aiAnswer(env, context, text || raw);
      }
    }
  } catch (error) {
    console.error("CPAY bot error", error);
    answer = "এই মুহূর্তে requested intelligence service unavailable। Text question বা public URL দিয়ে আবার চেষ্টা করুন।";
  }

  const safe = escapeHtml(answer).slice(0, MAX_TELEGRAM_CHARS);
  await telegram(env, "sendMessage", { chat_id: message.chat.id, text: safe, parse_mode: "HTML", reply_to_message_id: message.message_id });
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    const url = new URL(request.url);
    if (url.pathname !== "/telegram" || request.method !== "POST") return new Response("CPAY Telegram worker", { status: 200 });
    if (request.headers.get("X-Telegram-Bot-Api-Secret-Token") !== env.TELEGRAM_WEBHOOK_SECRET) return new Response("unauthorized", { status: 401 });
    const update = await request.json<TelegramUpdate>();
    ctx.waitUntil(handle(env, update));
    return new Response("ok");
  },
};
