// Copy to config.js for local development.
// The anon key is public by design; never put service-role or BTCPay secrets here.
window.SUPABASE_URL = 'https://YOUR_PROJECT_REF.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR_PUBLIC_ANON_KEY';
window.supabaseClient = window.supabase.createClient(window.SUPABASE_URL, SUPABASE_ANON_KEY);
