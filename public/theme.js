/**
 * CPAY layout engine
 * Core 3: keypad, classic, tile
 * Plus 5 original + 5 new = 8 extra layouts available at link creation
 */
const CPAY_LAYOUTS = {
  keypad:     { label: 'Keypad', group: 'core' },
  classic:    { label: 'Classic', group: 'core' },
  tile:       { label: 'Tile', group: 'core' },
  focus:      { label: 'Focus', group: 'plus' },
  receipt:    { label: 'Receipt', group: 'plus' },
  pulse:      { label: 'Pulse', group: 'plus' },
  ledger:     { label: 'Ledger', group: 'plus' },
  studio:     { label: 'Studio', group: 'plus' },
  boulevard:  { label: 'Boulevard', group: 'plus' },
  aurora:     { label: 'Aurora', group: 'plus' },
};
const CPAY_INVOICE_THEMES = {
  default: { label: 'Default invoice' },
  compact: { label: 'Compact' },
  poster:  { label: 'Poster' },
  night:   { label: 'Night desk' },
  cashier: { label: 'Cashier' },
};
const CPAY_DEFAULT_LAYOUT = 'keypad';
window.CPAY_LAYOUT = CPAY_DEFAULT_LAYOUT;
window.CPAY_LAYOUTS = CPAY_LAYOUTS;
window.CPAY_INVOICE_THEMES = CPAY_INVOICE_THEMES;
async function applyDomainTheme() {
  const host = window.location.hostname;
  try {
    const { data, error } = await window.supabaseClient
      .from('site_domains')
      .select('hostname, theme')
      .eq('is_active', true);
    if (error || !data) return window.CPAY_LAYOUT;
    const row = data.find(d => (d.hostname || '').toLowerCase() === host.toLowerCase());
    const name = row && CPAY_LAYOUTS[row.theme] ? row.theme : CPAY_DEFAULT_LAYOUT;
    window.CPAY_LAYOUT = name;
    document.documentElement.setAttribute('data-layout', name);
    return name;
  } catch (e) {
    console.error('layout lookup failed:', e);
    return window.CPAY_LAYOUT;
  }
}
function applyLinkTheme(theme) {
  const name = theme && CPAY_LAYOUTS[theme] ? theme : window.CPAY_LAYOUT;
  window.CPAY_LAYOUT = name;
  document.documentElement.setAttribute('data-layout', name);
  return name;
}
function applyInvoiceTheme(theme) {
  const name = theme && CPAY_INVOICE_THEMES[theme] ? theme : 'default';
  document.documentElement.setAttribute('data-invoice-theme', name);
  return name;
}
