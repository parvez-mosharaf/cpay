-- ============================================================
-- CPAY — 0003: RPC functions
-- ============================================================
-- =========================================================
-- request_withdrawal — user-triggered cashout request.
-- Fee % and balance are calculated SERVER-SIDE only.
-- =========================================================
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
v_earned numeric;
v_queued numeric;
v_available numeric;
v_amount_after_fee numeric;
v_auto_threshold numeric;
v_status text;
v_row withdrawals;
begin
if v_uid is null then
raise exception 'Not authenticated';
end if;
if p_amount is null or p_amount < 5 then
raise exception 'Minimum withdrawal is $5';
end if;
if p_method not in ('bkash','nagad','binance') then
raise exception 'Invalid withdrawal method';
end if;
if p_destination is null or length(trim(p_destination)) = 0 then
raise exception 'Destination account is required';
end if;
select withdrawal_fee_percent into v_fee_percent
from profiles where id = v_uid;
v_fee_percent := coalesce(v_fee_percent, 3.0);
select coalesce(sum(amount_settled), 0) into v_earned
from payments where user_id = v_uid and status = 'settled';
select coalesce(sum(amount_requested), 0) into v_queued
from withdrawals where user_id = v_uid and status != 'rejected';
v_available := v_earned - v_queued;
if p_amount > v_available then
raise exception 'Insufficient balance. Available: %', round(v_available, 2);
end if;
select coalesce((value->>'amount')::numeric, 50) into v_auto_threshold
from app_settings where key = 'auto_withdraw_threshold';
v_amount_after_fee := round(p_amount * (1 - v_fee_percent / 100), 8);
v_status := case when p_amount < v_auto_threshold then 'approved' else 'pending' end;
insert into withdrawals (user_id, amount_requested, fee_percent, amount_after_fee, method, destination, status)
values (v_uid, p_amount, v_fee_percent, v_amount_after_fee, p_method, p_destination, v_status)
returning * into v_row;
return v_row;
end;
$$;
revoke all on function request_withdrawal(numeric, text, text) from public;
revoke all on function request_withdrawal(numeric, text, text) from anon;
grant execute on function request_withdrawal(numeric, text, text) to authenticated;
-- =========================================================
-- get_invoice_public — public invoice status lookup.
-- Returns only display-safe fields, never user_id or raw ids.
-- =========================================================
drop function if exists public.get_invoice_public(uuid);
create or replace function get_invoice_public(p_payment_id uuid)
returns table (
id uuid,
amount_requested numeric,
amount_settled numeric,
method text,
status text,
expires_at timestamptz,
merchant_name text,
link_slug text
)
language sql
security definer
set search_path = public
as $$
select
p.id,
p.amount_requested,
p.amount_settled,
p.method,
p.status,
p.expires_at,
pr.display_name as merchant_name,
pl.slug as link_slug
from payments p
left join payment_links pl on pl.id = p.payment_link_id
left join profiles pr on pr.id = p.user_id
where p.id = p_payment_id;
$$;
revoke all on function get_invoice_public(uuid) from public;
grant execute on function get_invoice_public(uuid) to anon, authenticated;
-- =========================================================
-- get_link_preview — for the Cloudflare OG-preview worker.
-- =========================================================
create or replace function get_link_preview(p_slug text)
returns table (display_name text, is_active boolean)
language sql
security definer
set search_path = public
as $$
select pl.display_name, pl.is_active
from payment_links pl
where pl.slug = p_slug
limit 1;
$$;
revoke all on function get_link_preview(text) from public;
grant execute on function get_link_preview(text) to anon;
-- =========================================================
-- admin_global_stats — aggregated dashboard numbers for admin panel.
-- =========================================================
create or replace function admin_global_stats(p_start date default null, p_end date default null)
returns table (
total_settled numeric,
total_admin_profit numeric,
total_withdrawn numeric,
pending_withdrawals_count int,
pending_withdrawals_amount numeric,
payment_count bigint,
active_creators bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
if not is_admin() then
raise exception 'Not authorized';
end if;
return query
select
coalesce(sum(p.amount_settled) filter (where p.status = 'settled'
and (p_start is null or p.settled_at::date >= p_start)
and (p_end is null or p.settled_at::date <= p_end)), 0) as total_settled,
coalesce((
select sum(ds.total_admin_profit) from daily_stats ds
where (p_start is null or ds.stat_date >= p_start)
and (p_end is null or ds.stat_date <= p_end)
), 0) as total_admin_profit,
coalesce(sum(w.amount_after_fee) filter (where w.status = 'paid'
and (p_start is null or w.processed_at::date >= p_start)
and (p_end is null or w.processed_at::date <= p_end)), 0) as total_withdrawn,
(select count(*) from withdrawals where status = 'pending')::int as pending_withdrawals_count,
(select coalesce(sum(amount_requested), 0) from withdrawals where status = 'pending') as pending_withdrawals_amount,
(select count(*) from payments where status = 'settled'
and (p_start is null or settled_at::date >= p_start)
and (p_end is null or settled_at::date <= p_end)) as payment_count,
(select count(distinct user_id) from payments where status = 'settled') as active_creators
from payments p
left join withdrawals w on true
limit 1;
end;
$$;
revoke all on function admin_global_stats(date, date) from public;
grant execute on function admin_global_stats(date, date) to authenticated;