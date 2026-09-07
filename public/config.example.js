// Copy this file to config.js and fill in your own project values.
//
// The anon key is designed to be public — it identifies the project, it does
// not authorise anything on its own. Real protection lives in the RLS
// policies and SECURITY DEFINER functions in supabase/migrations/.
// Never put the service role key or any BTCPay secret in this file.
window.SUPABASE_URL = 'https://YOUR-PROJECT.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR-ANON-KEY';
window.supabaseClient = window.supabase.createClient(window.SUPABASE_URL, SUPABASE_ANON_KEY);
