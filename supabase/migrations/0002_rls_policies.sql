-- ============================================================
-- Boltpay — 0002: Row Level Security
-- ============================================================
alter table profiles enable row level security;
alter table payment_links enable row level security;
alter table payments enable row level security;
alter table withdrawals enable row level security;
alter table app_settings enable row level security;
alter table daily_stats enable row level security;
-- Helper: check admin role
create or replace function is_admin() returns boolean as $$
select exists(select 1 from profiles where id = auth.uid() and role = 'admin');
$$ language sql security definer stable;
-- ---------- profiles ----------
drop policy if exists "own profile" on profiles;
create policy "own profile"
on profiles for select
using (id = auth.uid() or is_admin());
drop policy if exists "update own profile" on profiles;
create policy "update own profile"
on profiles for update
using (id = auth.uid());
-- ---------- payment_links ----------
drop policy if exists "own links select" on payment_links;
create policy "own links select"
on payment_links for select
using (user_id = auth.uid() or is_admin());
drop policy if exists "own links insert" on payment_links;
create policy "own links insert"
on payment_links for insert
with check (user_id = auth.uid());
drop policy if exists "own links update" on payment_links;
create policy "own links update"
on payment_links for update
using (user_id = auth.uid());
-- ---------- payments ----------
drop policy if exists "own payments select" on payments;
create policy "own payments select"
on payments for select
using (user_id = auth.uid() or is_admin());
-- Public invoice pages read a narrow set of columns via Realtime.
-- id is a random UUID (unguessable); user_id and other sensitive
-- columns are hidden from anon via the column-level grant below.
drop policy if exists "anon can watch invoice status for realtime" on payments;
create policy "anon can watch invoice status for realtime"
on payments for select
to anon
using (true);
-- ---------- withdrawals ----------
drop policy if exists "own withdrawals select" on withdrawals;
create policy "own withdrawals select"
on withdrawals for select
using (user_id = auth.uid() or is_admin());
drop policy if exists "own withdrawals insert" on withdrawals;
create policy "own withdrawals insert"
on withdrawals for insert
with check (user_id = auth.uid());
-- Admin may move a withdrawal to 'approved' or 'rejected' directly.
-- Transition to 'paid' is intentionally NOT allowed here — that only
-- happens via the service-role Edge Function (process-withdrawal),
-- after either a real BTCPay payout or an explicit manual-pay action.
drop policy if exists "admin can approve or reject withdrawals" on withdrawals;
create policy "admin can approve or reject withdrawals"
on withdrawals for update
using (is_admin())
with check (status in ('approved', 'rejected', 'pending'));
-- ---------- app_settings ----------
drop policy if exists "settings read" on app_settings;
create policy "settings read"
on app_settings for select
using (true);
drop policy if exists "settings admin write" on app_settings;
create policy "settings admin write"
on app_settings for all
using (is_admin());
-- ---------- daily_stats ----------
drop policy if exists "stats admin only" on daily_stats;
create policy "stats admin only"
on daily_stats for select
using (is_admin());
-- ---------- column-level grant for anon on payments ----------
-- Restrict anon to only the columns an invoice-status page needs.
-- user_id, btcpay_invoice_id, payment_link_id internals stay hidden.
revoke select on payments from anon;
grant select (id, amount_requested, amount_settled, method, status, expires_at)
on payments to anon;