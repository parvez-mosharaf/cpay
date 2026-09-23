// CPAY public browser configuration. The anon key is intentionally public.
// Never place a service-role key or BTCPay secret in this file.
window.SUPABASE_URL = 'https://riumaeihemgznvgattoc.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJpdW1hZWloZW1nem52Z2F0dG9jIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk4NDU1MDAsImV4cCI6MjEwNTQyMTUwMH0.WEC84G_IwHG4jfAJ5fWVdSjFxS8xM-D9tklGn4jsyHk';
window.supabaseClient = window.supabase.createClient(window.SUPABASE_URL, SUPABASE_ANON_KEY);
