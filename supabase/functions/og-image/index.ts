/**
 * Boltpay — on-demand OG preview images
 *
 * GET /og-image/<slug>.png   (proxied and cached by the Cloudflare Worker)
 *
 * Renders a 1200x630 PNG for a payment link. Nothing is uploaded and
 * nothing is stored, so a link has a preview the instant a creator makes
 * it — no GitHub commit, no Pages rebuild.
 *
 * The .png in the path is deliberate: a bare ?slug= works on most
 * platforms, but some iMessage and WhatsApp builds refuse to scrape an
 * og:image URL with no image extension.
 *
 * Deploy:  supabase functions deploy og-image --no-verify-jwt
 * (crawlers cannot present a JWT)
 */
import { initWasm, Resvg } from "https://esm.sh/@resvg/resvg-wasm@2.6.2";
import { DISPLAY_FONT_BASE64 } from "./font.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const WASM_URL = "https://esm.sh/@resvg/resvg-wasm@2.6.2/index_bg.wasm";

// Module scope: a warm isolate pays these costs once, not per request.
let wasmReady: Promise<void> | null = null;
let fontBytes: Uint8Array | null = null;

function ensureWasm(): Promise<void> {
  if (!wasmReady) wasmReady = initWasm(fetch(WASM_URL));
  return wasmReady;
}

function ensureFont(): Uint8Array {
  if (!fontBytes) {
    const bin = atob(DISPLAY_FONT_BASE64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    fontBytes = out;
  }
  return fontBytes;
}

function escapeXml(str: string): string {
  return String(str ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/**
 * Your SVG, with two substitutions: the avatar letter and the name.
 *
 * Changes from what you sent, and why:
 *
 *  - font-family is "Boltpay Display" everywhere. resvg has no system
 *    fonts, so 'Helvetica Neue', Helvetica, Arial would all miss and the
 *    text would render as nothing at all. The embedded face is registered
 *    under that name below.
 *
 *  - font-size on the name is computed rather than fixed at 150.
 *    "Taylor James" fits, but "Christopher Wellington" at 150px is about
 *    1,650px wide and would run off a 1200px canvas with no warning. The
 *    size steps down only when it has to, so short names look exactly as
 *    you designed them.
 *
 * Everything else — the green, the blue circle, the black square, the $,
 * the -5 letter-spacing, every coordinate — is untouched.
 */
function buildSvg(name: string): string {
  const displayName = String(name || "").trim().slice(0, 40);
  const safeName = escapeXml(displayName);
  const initial = escapeXml(
    ([...displayName][0] || "?").toUpperCase(),
  );

  // Inter Bold at -5 letter-spacing averages ~0.60 em per character.
  // Budget 1,120px so the name keeps your 60px left margin and still
  // clears the right edge.
  const estimatedWidth = displayName.length * 150 * 0.60 - displayName.length * 5;
  const nameSize = estimatedWidth > 1120
    ? Math.max(56, Math.floor(150 * (1120 / estimatedWidth)))
    : 150;

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 630" width="1200" height="630">
  <!-- Bolt Pay Green Background -->
  <rect width="1200" height="630" fill="#00D632" />

  <!-- Blue Avatar (Top Left, partially cut off like the screenshot) -->
  <circle cx="180" cy="40" r="110" fill="#4052FF" />
  <text x="180" y="72" font-size="90" font-family="Boltpay Display" font-weight="bold" fill="#ffffff" text-anchor="middle">${initial}</text>

  <!-- Black Icon (Top Right, partially cut off like the screenshot) -->
  <rect x="1000" y="-50" width="130" height="130" rx="30" fill="#000000" />

  <!-- Half Dollar Sign inside the black box -->
  <text x="1065" y="46" font-size="90" font-family="Boltpay Display" font-weight="bold" fill="#00D632" text-anchor="middle">$</text>

  <!-- Name (Bottom Left, large and bold like the screenshot) -->
  <text x="60" y="560" font-size="${nameSize}" font-family="Boltpay Display" font-weight="bold" letter-spacing="-5" fill="#000000">${safeName}</text>
</svg>`;
}

function fallbackRedirect(origin: string) {
  // Never hand a crawler an error status — it caches the failure and the
  // link shows no picture for as long as that cache lives. A redirect to
  // the static default means there is always something.
  return Response.redirect(`${origin}/assets/og/og-default.png`, 302);
}

Deno.serve(async (req) => {
  const url = new URL(req.url);

  // Accept /og-image/<slug>.png, /functions/v1/og-image/<slug>.png, and
  // ?slug= so the endpoint is easy to test by hand.
  const tail = url.pathname.split("/").filter(Boolean).pop() || "";
  const fromPath = tail.replace(/\.png$/i, "");
  const slug = decodeURIComponent(
    fromPath === "og-image" ? (url.searchParams.get("slug") || "") : fromPath,
  );

  // Case matters — the slug styles differ only by capitalisation.
  if (!/^[A-Za-z0-9][A-Za-z0-9-]{2,48}[A-Za-z0-9]$/.test(slug)) {
    return fallbackRedirect(url.origin);
  }

  let displayName = slug;
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/get_link_preview`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
      },
      body: JSON.stringify({ p_slug: slug }),
    });
    if (!res.ok) return fallbackRedirect(url.origin);
    const rows = await res.json();
    const row = Array.isArray(rows) ? rows[0] : rows;
    if (!row || row.is_active === false) return fallbackRedirect(url.origin);
    displayName = row.display_name || slug;
  } catch (e) {
    console.error("link lookup failed:", e);
    return fallbackRedirect(url.origin);
  }

  try {
    await ensureWasm();

    const resvg = new Resvg(buildSvg(displayName), {
      fitTo: { mode: "width", value: 1200 },
      font: {
        fontBuffers: [ensureFont()],
        defaultFontFamily: "Boltpay Display",
        // There are no system fonts in this runtime; scanning for them
        // only wastes cold-start time.
        loadSystemFonts: false,
      },
    });
    const png = resvg.render().asPng();
    // Copy into a concrete ArrayBuffer so Deno 2.x accepts the binary body
    // regardless of whether the renderer exposes ArrayBufferLike.
    const source = png.buffer as ArrayBuffer;
    const pngBuffer = source.slice(png.byteOffset, png.byteOffset + png.byteLength);

    return new Response(pngBuffer, {
      headers: {
        "Content-Type": "image/png",
        // Immutable for a year. The Worker caches on top of this, so a
        // crawler almost never waits on a cold start.
        "Cache-Control": "public, max-age=31536000, immutable",
        "Access-Control-Allow-Origin": "*",
      },
    });
  } catch (e) {
    console.error("render failed:", e);
    return fallbackRedirect(url.origin);
  }
});
