// Rename this file to config.js and fill in your real project values.
// The anon key is safe to expose in the browser — it's designed to be
// public. Real protection lives in RLS policies and SECURITY DEFINER
// functions in supabase/migrations/. Never put the service role key
// or any BTCPay secret in this file.
window.SUPABASE_URL = 'https://ohwzmxwsphsfzudmlins.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9od3pteHdzcGhzZnp1ZG1saW5zIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYwMzE0MTksImV4cCI6MjEwMTYwNzQxOX0.frTl7qnDx7SK2IBMQxFCkKGe5u4XAQweRxPhQ-2r8rU';
window.supabaseClient = window.supabase.createClient(window.SUPABASE_URL, SUPABASE_ANON_KEY);
