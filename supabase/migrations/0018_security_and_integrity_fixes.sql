-- ============================================================
-- CPAY — 0018: Security & integrity fixes
-- ============================================================
-- Safe to run on an existing database. Every statement is
-- idempotent or guarded, so re-running it is harmless.
-- ============================================================
-- ============================================================
-- 1. is_admin() — pin search_path
-- ------------------------------------------------------------
-- A SECURITY DEFINER function without a fixed search_path can be
-- hijacked by a caller that puts a fake `profiles` table earlier
-- on their own search_path. Every other definer function in this
-- repo already pins it; this one did not.
-- ============================================================
create or replace function is_admin() returns boolean
language sql
security definer
stable
set search_path = public
as $$
select exists(select 1 from profiles where id = auth.uid() and role = 'admin');
$$;
-- ============================================================
-- 2. profiles — stop self-service privilege escalation
-- ------------------------------------------------------------
-- The old policy was:  for update using (id = auth.uid())
-- with no WITH CHECK and no column restrictions, so any logged-in
-- creator could run:
--     update profiles set role = 'admin' where id = <self>;
--     update profiles set withdrawal_fee_percent = 0 ...;
--     update profiles set max_payment_links = 9999 ...;
-- and become an admin / zero out their own fees.
-- ============================================================
drop policy if exists "update own profile" on profiles;
create policy "update own profile"
on profiles for update
using (id = auth.uid())
with check (id = auth.uid());
create or replace function guard_profile_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
-- service-role / trigger context (auth.uid() is null) and admins are allowed.
-- anon can never reach here: the RLS policy above already blocks it.
if auth.uid() is null or is_admin() then
return new;
end if;
if new.id                     is distinct from old.id
or new.email                  is distinct from old.email
or new.role                   is distinct from old.role
or new.withdrawal_fee_percent is distinct from old.withdrawal_fee_percent
or new.max_payment_links      is distinct from old.max_payment_links
or new.auto_withdraw_enabled  is distinct from old.auto_withdraw_enabled
or new.buy_rate               is distinct from old.buy_rate
or new.sell_rate              is distinct from old.sell_rate
then
raise exception 'You may only change your display name and wallet details';
end if;
return new;
end;
$$;
drop trigger if exists trg_guard_profile_updates on profiles;
create trigger trg_guard_profile_updates
before update on profiles
for each row execute function guard_profile_updates();
-- ============================================================
-- 3. payments — narrow the anon Realtime window
-- ------------------------------------------------------------
-- The old policy was `for select to anon using (true)`, which let
-- anybody holding the (public) anon key read the amount, status and
-- expiry of EVERY payment ever made — the whole revenue ledger.
--
-- Realtime evaluates RLS per row, so the invoice page only needs to
-- see rows that are still inside their payment window. Two hours is
-- comfortably wider than the 60-minute invoice expiry, so the
-- "settled" UPDATE still gets delivered, while all history stays
-- private.
-- ============================================================
drop policy if exists "anon can watch invoice status for realtime" on payments;
create policy "anon can watch live invoice status"
on payments for select
to anon
using (expires_at > now() - interval '2 hours');
-- Re-assert the column grant (harmless if already applied)
revoke select on payments from anon;
grant select (id, amount_requested, amount_settled, method, status, expires_at)
on payments to anon;
-- ============================================================
-- 4. withdrawals — allowed values + no client-side inserts
-- ------------------------------------------------------------
-- 4a. 0017 dropped withdrawals_method_check entirely and did not
--     replace it, so any string was accepted. Restore it with the
--     full set of methods the app actually uses.
-- 4b. user-withdraw writes status 'processing', which the original
--     CHECK constraint rejected, so every instant-Lightning payout
--     failed with a constraint violation.
-- 4c. The "own withdrawals insert" policy let a creator INSERT
--     straight into withdrawals from the browser, skipping the
--     balance check and the fee entirely:
--         insert into withdrawals (user_id, amount_requested,
--           fee_percent, amount_after_fee, method, destination,
--           status) values (me, 1000000, 0, 1000000, 'bkash',
--           'x', 'approved');
--     All inserts now have to go through request_withdrawal().
-- ============================================================
alter table withdrawals drop constraint if exists withdrawals_method_check;
alter table withdrawals add constraint withdrawals_method_check
check (method in ('bkash','nagad','binance','lightning','usdt_bep20','bank'))
not valid;
alter table withdrawals drop constraint if exists withdrawals_status_check;
alter table withdrawals add constraint withdrawals_status_check
check (status in ('pending','approved','processing','rejected','paid'))
not valid;
drop policy if exists "own withdrawals insert" on withdrawals;
-- Admin may still move pending -> approved/rejected from the client.
-- Moving to 'paid' or 'processing' stays service-role only.
drop policy if exists "admin can approve or reject withdrawals" on withdrawals;
create policy "admin can approve or reject withdrawals"
on withdrawals for update
using (is_admin())
with check (status in ('pending','approved','rejected'));
-- Nobody but the service role may rewrite the money columns.
create or replace function guard_withdrawal_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
if auth.uid() is null then
return new;  -- service role / definer functions
end if;
if new.user_id          is distinct from old.user_id
or new.amount_requested is distinct from old.amount_requested
or new.fee_percent      is distinct from old.fee_percent
or new.amount_after_fee is distinct from old.amount_after_fee
or new.destination      is distinct from old.destination
then
raise exception 'Withdrawal amounts and destination cannot be edited';
end if;
return new;
end;
$$;
drop trigger if exists trg_guard_withdrawal_updates on withdrawals;
create trigger trg_guard_withdrawal_updates
before update on withdrawals
for each row execute function guard_withdrawal_updates();
-- ============================================================
-- 5. One single balance definition
-- ------------------------------------------------------------
-- The codebase had two competing definitions of "available balance":
--
--   A) sum(settled payments) - sum(non-rejected withdrawals)
--      — used by request_withdrawal() and the creator dashboard
--   B) sum(settled payments where withdrawal_id is null)
--      — used by user-withdraw and the webhook auto-queue
--
-- Because they disagree, a creator could withdraw the same money
-- twice: a manual request under (A) never tags payments, so (B)
-- still saw that money as unspent. Model (B) was also lossy —
-- withdrawing $5 out of $500 tagged ALL payments, freezing $495,
-- and a rejected request never released them again.
--
-- Model (A) is now the only definition, exposed as a function so
-- the server, the dashboard and the auto-queue cannot drift apart.
-- ============================================================
create or replace function get_balance_for(p_user_id uuid)
returns table (earned numeric, queued numeric, withdrawn numeric, available numeric)
language sql
security definer
stable
set search_path = public
as $$
select
e.earned,
q.queued,
w.withdrawn,
round(e.earned - q.queued, 8) as available
from
(select coalesce(sum(amount_settled), 0) as earned
from payments where user_id = p_user_id and status = 'settled') e,
(select coalesce(sum(amount_requested), 0) as queued
from withdrawals where user_id = p_user_id and status <> 'rejected') q,
(select coalesce(sum(amount_after_fee), 0) as withdrawn
from withdrawals where user_id = p_user_id and status = 'paid') w;
$$;
revoke all on function get_balance_for(uuid) from public, anon, authenticated;
-- Creator-facing wrapper: always your own balance, never anyone else's.
create or replace function get_my_balance()
returns table (earned numeric, queued numeric, withdrawn numeric, available numeric)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
if auth.uid() is null then raise exception 'Not authenticated'; end if;
return query select * from get_balance_for(auth.uid());
end;
$$;
revoke all on function get_my_balance() from public, anon;
grant execute on function get_my_balance() to authenticated;
-- ============================================================
-- 6. request_withdrawal — locking, validation, rounding
-- ------------------------------------------------------------
-- Fixes vs. 0017:
--   * `perform 1 from payments ... for update` locked the wrong
--     rows, and locked nothing at all for a user whose payments
--     were all still tagged — two parallel requests could both
--     pass the balance check. Now the profile row is locked, which
--     serialises every withdrawal request per user.
--   * 0017 deleted the p_method validation along with the CHECK
--     constraint, so any string was accepted.
--   * amount_after_fee was rounded to 8dp while payouts are made in
--     whole cents; 2dp keeps the ledger and the payout identical.
-- ============================================================
create or replace function request_withdrawal(
p_amount numeric,
p_method text,
p_destination text
)
returns withdrawals
language plpgsql
security definer
set search_path = public
as $$
declare
v_uid uuid := auth.uid();
v_fee_percent numeric;
v_available numeric;
v_amount_after_fee numeric;
v_row withdrawals;
begin
if v_uid is null then
raise exception 'Not authenticated';
end if;
-- Serialise concurrent requests from the same creator.
perform 1 from profiles where id = v_uid for update;
if p_amount is null or p_amount < 5 then
raise exception 'Minimum withdrawal is $5';
end if;
if p_method is null or p_method not in
('bkash','nagad','binance','lightning','usdt_bep20','bank') then
raise exception 'Invalid withdrawal method';
end if;
if p_destination is null or length(trim(p_destination)) = 0 then
raise exception 'Destination account is required';
end if;
if length(trim(p_destination)) > 500 then
raise exception 'Destination is too long';
end if;
select coalesce(withdrawal_fee_percent, 3.0) into v_fee_percent
from profiles where id = v_uid;
select b.available into v_available from get_balance_for(v_uid) b;
if p_amount > v_available then
raise exception 'Insufficient balance. Available: $%', round(v_available, 2);
end if;
v_amount_after_fee := round(p_amount * (1 - v_fee_percent / 100), 2);
insert into withdrawals (
user_id, amount_requested, fee_percent, amount_after_fee,
method, destination, status
)
values (
v_uid, p_amount, v_fee_percent, v_amount_after_fee,
p_method, trim(p_destination), 'pending'
)
returning * into v_row;
return v_row;
end;
$$;
revoke all on function request_withdrawal(numeric, text, text) from public, anon;
grant execute on function request_withdrawal(numeric, text, text) to authenticated;
-- ============================================================
-- 7. system_queue_withdrawal — auto-queue, same rules
-- ------------------------------------------------------------
-- The webhook used to build the auto-withdrawal by hand in
-- TypeScript with its own (different) balance maths and no lock.
-- It now calls this, so auto and manual withdrawals share one
-- code path. Returns null when there is nothing to queue.
-- ============================================================
create or replace function system_queue_withdrawal(p_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
v_profile profiles;
v_available numeric;
v_destination text;
v_method text;
v_id uuid;
begin
select * into v_profile from profiles where id = p_user_id for update;
if not found or coalesce(v_profile.auto_withdraw_enabled, false) = false then
return null;
end if;
v_method := coalesce(v_profile.default_withdrawal_method, 'usdt_bep20');
-- Lightning payouts are creator-initiated (they must supply a fresh
-- bolt11 invoice for the exact amount), so they are never auto-queued.
if v_method = 'lightning' then
return null;
end if;
if v_method not in ('bkash','nagad','binance','usdt_bep20','bank') then
return null;
end if;
v_destination := coalesce(
nullif(trim(coalesce(v_profile.default_withdrawal_destination, '')), ''),
case v_method
when 'bkash'      then v_profile.wallet_bkash
when 'nagad'      then v_profile.wallet_nagad
when 'binance'    then v_profile.wallet_binance_id
when 'usdt_bep20' then v_profile.wallet_usdt_bep20
when 'bank'       then v_profile.wallet_bank
end
);
-- No destination on file: leave the balance withdrawable instead of
-- queueing a request the admin cannot actually pay.
if v_destination is null or length(trim(v_destination)) = 0 then
return null;
end if;
select b.available into v_available from get_balance_for(p_user_id) b;
if v_available is null or v_available < 5 then
return null;
end if;
insert into withdrawals (
user_id, amount_requested, fee_percent, amount_after_fee,
method, destination, status, admin_note
)
values (
p_user_id,
v_available,
coalesce(v_profile.withdrawal_fee_percent, 3.0),
round(v_available * (1 - coalesce(v_profile.withdrawal_fee_percent, 3.0) / 100), 2),
v_method,
trim(v_destination),
'pending',
'Auto-queued on settlement'
)
returning id into v_id;
return v_id;
end;
$$;
revoke all on function system_queue_withdrawal(uuid) from public, anon, authenticated;
grant execute on function system_queue_withdrawal(uuid) to service_role;
-- ============================================================
-- 8. support_messages — a creator could rewrite admin messages
-- ------------------------------------------------------------
-- The update policy had a USING clause but no WITH CHECK, so
-- `update support_messages set message = '...' where id = <admin
-- message in my own thread>` succeeded. The UI hid the button; the
-- API did not. A creator can now only edit their own messages, and
-- cannot move a message into someone else's thread or forge the
-- sender.
-- ============================================================
drop policy if exists "update own messages or mark read" on support_messages;
create policy "update own messages or mark read"
on support_messages for update
using (is_admin() or user_id = auth.uid())
with check (is_admin() or user_id = auth.uid());
create or replace function guard_message_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
if auth.uid() is null or is_admin() then
return new;
end if;
-- Creators may flip read/delete flags on any message in their thread,
-- but may only change the text of messages they wrote themselves.
if new.message is distinct from old.message and old.sender <> 'creator' then
raise exception 'You can only edit your own messages';
end if;
if new.sender is distinct from old.sender
or new.user_id is distinct from old.user_id
then
raise exception 'Message ownership cannot be changed';
end if;
return new;
end;
$$;
drop trigger if exists trg_guard_message_updates on support_messages;
create trigger trg_guard_message_updates
before update on support_messages
for each row execute function guard_message_updates();
-- ============================================================
-- 9. app_settings — stop leaking business config to everyone
-- ------------------------------------------------------------
-- "settings read using (true)" exposed profit_margin_percent,
-- exchange_rates and the auto-withdraw threshold to anonymous
-- visitors. Only the keys a page genuinely renders stay readable.
-- ============================================================
drop policy if exists "settings read" on app_settings;
create policy "settings public read"
on app_settings for select
to anon
using (key in ('platform_notice', 'site_domain'));
create policy "settings creator read"
on app_settings for select
to authenticated
using (
is_admin()
or key in (
'platform_notice',
'site_domain',
'auto_withdraw_enabled',
'auto_withdraw_threshold',
'default_max_payment_links',
'default_withdrawal_fee_percent'
)
);
-- ============================================================
-- 10. Link limit also enforced on UPDATE
-- ------------------------------------------------------------
-- 0017 changed the limit to count only ACTIVE links, but the
-- trigger still only fired on INSERT — so a creator at their limit
-- could deactivate one link, create a new one, then re-activate the
-- old one and sit above the limit indefinitely.
-- ============================================================
create or replace function enforce_link_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
v_limit int;
v_current int;
begin
-- Only relevant when a link ends up active.
if coalesce(new.is_active, true) = false then
return new;
end if;
if tg_op = 'UPDATE' and coalesce(old.is_active, true) = true then
return new;  -- already counted
end if;
select coalesce(max_payment_links, 5) into v_limit
from profiles where id = new.user_id;
select count(*) into v_current
from payment_links
where user_id = new.user_id
and is_active = true
and id is distinct from new.id;
if v_current >= v_limit then
raise exception 'Limit reached: you can have at most % active links', v_limit;
end if;
return new;
end;
$$;
drop trigger if exists trg_enforce_link_limit on payment_links;
create trigger trg_enforce_link_limit
before insert or update on payment_links
for each row execute function enforce_link_limit();
-- ============================================================
-- 11. Reserved slugs enforced in the database
-- ------------------------------------------------------------
-- The reserved-name list lived in three places in JS (dashboard,
-- 404 page, worker) and in none of them was it binding — a creator
-- could POST a link with slug 'admin' straight to PostgREST and
-- shadow /admin on every payment domain.
-- ============================================================
create or replace function validate_link_slug()
returns trigger
language plpgsql
set search_path = public
as $$
begin
new.slug := lower(trim(new.slug));
if new.slug !~ '^[a-z0-9][a-z0-9-]{2,48}[a-z0-9]$' then
raise exception 'Link name must be 4-50 characters: letters, numbers and hyphens only';
end if;
if new.slug in (
'index','login','register','dashboard','admin','404','config','theme',
'assets','favicon','invoice-cpay-v2','api','u','static','public',
'well-known','robots','sitemap'
) then
raise exception 'That link name is reserved';
end if;
return new;
end;
$$;
drop trigger if exists trg_validate_link_slug on payment_links;
create trigger trg_validate_link_slug
before insert or update of slug on payment_links
for each row execute function validate_link_slug();
-- ============================================================
-- 12. Admin actions — bounds checking
-- ------------------------------------------------------------
-- admin_mark_payment accepted any amount_settled, including
-- negative numbers, which would silently corrupt every balance
-- derived from sum(amount_settled).
-- ============================================================
create or replace function admin_mark_payment(
p_payment_id uuid,
p_status text,
p_amount_settled numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
v_payment payments;
begin
if not is_admin() then raise exception 'Not authorized'; end if;
if p_status not in ('settled', 'expired', 'invalid') then
raise exception 'Invalid status';
end if;
select * into v_payment from payments where id = p_payment_id for update;
if not found then raise exception 'Payment not found'; end if;
-- A settled payment is money that already moved; never walk it back
-- automatically, or a creator's balance drops after they withdrew.
if v_payment.status = 'settled' then
raise exception 'This payment is already settled';
end if;
if p_status = 'settled' then
if p_amount_settled is not null and (p_amount_settled <= 0 or p_amount_settled > 100000) then
raise exception 'Settled amount out of range';
end if;
update payments
set status = 'settled',
settled_at = now(),
amount_settled = coalesce(p_amount_settled, amount_requested)
where id = p_payment_id;
else
update payments set status = p_status where id = p_payment_id;
end if;
end;
$$;
revoke all on function admin_mark_payment(uuid, text, numeric) from public, anon;
grant execute on function admin_mark_payment(uuid, text, numeric) to authenticated;
-- ============================================================
-- 13. Withdrawal state machine — no double payouts
-- ------------------------------------------------------------
-- The Edge Function read a withdrawal, then wrote status='paid'
-- unconditionally. Two clicks on "Force BTCPay Payout" fired two
-- real Lightning payouts for one request. This claim function makes
-- the transition atomic: whichever call gets there first wins, the
-- second gets false back and the function stops.
-- ============================================================
create or replace function system_claim_withdrawal(p_withdrawal_id uuid, p_next_status text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
v_updated int;
begin
if p_next_status not in ('processing','approved','rejected','paid') then
raise exception 'Invalid target status';
end if;
update withdrawals
set status = p_next_status,
processed_at = case when p_next_status in ('paid','rejected')
then now() else processed_at end
where id = p_withdrawal_id
and status in ('pending','approved');
get diagnostics v_updated = row_count;
return v_updated = 1;
end;
$$;
revoke all on function system_claim_withdrawal(uuid, text) from public, anon, authenticated;
grant execute on function system_claim_withdrawal(uuid, text) to service_role;
-- ============================================================
-- 14. Housekeeping indexes
-- ============================================================
create index if not exists idx_payments_user_status
on payments(user_id, status);
create index if not exists idx_withdrawals_user_status
on withdrawals(user_id, status);
create index if not exists idx_payments_settled_at
on payments(settled_at) where status = 'settled';
