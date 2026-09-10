/**
 * Boltpay theme engine
 *
 * A theme is a LAYOUT, not a palette.
 *
 * It used to swap CSS colour variables per domain, which meant a domain
 * could end up beige or magenta while every other surface — the payment
 * page, the link previews, the admin panel — stayed Cash App green. The
 * brand is one colour; what varies per domain is how the payment page is
 * arranged.
 *
 * So this now resolves the domain to one of three layout names and does
 * nothing to the colours. 404.html reads the name and shows the matching
 * layout. The invoice page is deliberately never themed.
 */
const BOLTPAY_LAYOUTS = {
  keypad:  { label: 'Keypad — big amount over a 3x4 pad' },
  classic: { label: 'Classic — amount field with quick-select chips' },
  tile:    { label: 'Tile — full-green, large keypad' },
};

const BOLTPAY_DEFAULT_LAYOUT = 'keypad';

/** The layout resolved for this hostname. Set by applyDomainTheme(). */
window.BOLTPAY_LAYOUT = BOLTPAY_DEFAULT_LAYOUT;

async function applyDomainTheme() {
  const host = window.location.hostname;
  try {
    const { data, error } = await window.supabaseClient
      .from('site_domains')
      .select('hostname, theme')
      .eq('is_active', true);

    if (error || !data) return window.BOLTPAY_LAYOUT;

    const row = data.find(d => (d.hostname || '').toLowerCase() === host.toLowerCase());
    const name = row && BOLTPAY_LAYOUTS[row.theme] ? row.theme : BOLTPAY_DEFAULT_LAYOUT;
    window.BOLTPAY_LAYOUT = name;

    // Layout only — no colour variables are touched. A page that wants to
    // react hooks off this attribute or window.BOLTPAY_LAYOUT.
    document.documentElement.setAttribute('data-layout', name);
    return name;
  } catch (e) {
    console.error('layout lookup failed:', e);
    return window.BOLTPAY_LAYOUT;
  }
}
