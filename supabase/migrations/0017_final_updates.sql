-- ============================================================
-- Boltpay — Final Admin Controls, Security & Wallets
-- ============================================================
-- 1. Wallet Columns & Auto-Withdraw Permission
alter table profiles
add column if not exists wallet_lightning text,
add column if not exists wallet_binance_id text,
add column if not exists wallet_usdt_bep20 text,
add column if not exists wallet_bkash text,
add column if not exists wallet_nagad text,
add column if not exists wallet_bank text,
add column if not exists auto_withdraw_enabled boolean default false; -- Default is False (Hidden)
-- 2. App Settings (Margin & Exchange Rate)
insert into app_settings (key, value) values ('profit_margin_percent', '{"percent": 7.7}') on conflict (key) do nothing;
insert into app_settings (key, value) values ('exchange_rates', '{"buy_rate": 133.0, "sell_rate": 133.0}') on conflict (key) do nothing;
-- 3. Soft Delete for Messages
alter table support_messages add column if not exists deleted_by_creator boolean default false;
create or replace function clear_message_thread(p_user_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
if not is_admin() and auth.uid() <> p_user_id then raise exception 'Not authorized'; end if;
if is_admin() then
delete from support_messages where user_id = p_user_id;
else
update support_messages set deleted_by_creator = true where user_id = p_user_id;
end if;
end; $$;
-- 4. Enforce Link Limit (Active only)
create or replace function enforce_link_limit() returns trigger language plpgsql security definer set search_path = public as $$
declare v_limit int; v_current int;
begin
select coalesce(max_payment_links, 5) into v_limit from profiles where id = new.user_id;
select count(*) into v_current from payment_links where user_id = new.user_id and is_active = true;
if v_current >= v_limit then raise exception 'Limit reached: You can have max % active links', v_limit; end if;
return new;
end; $$;
-- 5. Withdrawal Double-Spend Protection
alter table withdrawals drop constraint if exists withdrawals_method_check;
create or replace function request_withdrawal(p_amount numeric, p_method text, p_destination text)
returns withdrawals language plpgsql security definer set search_path = public as $$
declare
v_uid uuid := auth.uid();
v_fee_percent numeric; v_earned numeric; v_queued numeric; v_available numeric;
v_amount_after_fee numeric; v_status text; v_row withdrawals;
begin
if v_uid is null then raise exception 'Not authenticated'; end if;
if p_amount is null or p_amount < 5 then raise exception 'Minimum withdrawal is $5'; end if;
if p_destination is null or length(trim(p_destination)) = 0 then raise exception 'Destination required'; end if;
perform 1 from payments where user_id = v_uid and status = 'settled' for update;
select coalesce(withdrawal_fee_percent, 3.0) into v_fee_percent from profiles where id = v_uid;
select coalesce(sum(amount_settled), 0) into v_earned from payments where user_id = v_uid and status = 'settled';
select coalesce(sum(amount_requested), 0) into v_queued from withdrawals where user_id = v_uid and status != 'rejected';
v_available := v_earned - v_queued;
if p_amount > v_available then raise exception 'Insufficient balance. Available: $%', round(v_available, 2); end if;
v_amount_after_fee := round(p_amount * (1 - v_fee_percent / 100), 8);
v_status := 'pending';
insert into withdrawals (user_id, amount_requested, fee_percent, amount_after_fee, method, destination, status)
values (v_uid, p_amount, v_fee_percent, v_amount_after_fee, p_method, p_destination, v_status)
returning * into v_row;
return v_row;
end; $$;
-- 6. Admin Global Stats (Time-shifted to Handle 5:00 PM Day boundaries correctly)
drop function if exists admin_global_stats(date, date);
create or replace function admin_global_stats(p_start timestamptz default null, p_end timestamptz default null)
returns table (
total_settled numeric, total_admin_profit numeric, total_withdrawn numeric,
pending_withdrawals_count int, pending_withdrawals_amount numeric,
payment_count bigint, active_creators bigint, calculated_node_balance numeric
) language plpgsql security definer set search_path = public as $$
declare
v_total_settled numeric; v_margin numeric;
begin
if not is_admin() then raise exception 'Not authorized'; end if;
select coalesce((value->>'percent')::numeric, 7.7) into v_margin from app_settings where key = 'profit_margin_percent';
select coalesce(sum(amount_settled), 0) into v_total_settled from payments where status = 'settled'
and (p_start is null or settled_at >= p_start)
and (p_end is null or settled_at <= p_end);
return query select
v_total_settled as total_settled,
round((v_total_settled * (v_margin / 100.0)) / 2.0, 4) as total_admin_profit,
coalesce((select sum(amount_after_fee) from withdrawals where status = 'paid' and (p_start is null or processed_at >= p_start) and (p_end is null or processed_at <= p_end)), 0) as total_withdrawn,
(select count(*) from withdrawals where status = 'pending')::int as pending_withdrawals_count,
(select coalesce(sum(amount_requested), 0) from withdrawals where status = 'pending') as pending_withdrawals_amount,
(select count(*) from payments where status = 'settled' and (p_start is null or settled_at >= p_start) and (p_end is null or settled_at <= p_end)) as payment_count,
(select count(distinct user_id) from payments where status = 'settled') as active_creators,
round(v_total_settled * (1.0 + (v_margin / 100.0)), 4) as calculated_node_balance;
end; $$;
-- 7. Admin Customer Directory with ALL Wallets
create or replace function admin_toggle_creator_auto(p_creator_id uuid, p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
update profiles set auto_withdraw_enabled = p_enabled where id = p_creator_id;
end; $$;
revoke all on function admin_toggle_creator_auto(uuid, boolean) from public;
grant execute on function admin_toggle_creator_auto(uuid, boolean) to authenticated;
drop function if exists admin_customer_directory();
create or replace function admin_customer_directory()
returns table (
rn bigint, id uuid, email text, display_name text,
total_earned numeric, total_withdrawn numeric,
payment_count bigint, link_count bigint, max_links int,
auto_withdraw_enabled boolean,
w_lightning text, w_binance text, w_usdt text, w_bkash text, w_nagad text
) language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
return query select row_number() over (order by coalesce(te.total_earned,0) desc) as rn,
pr.id, pr.email, pr.display_name, coalesce(te.total_earned,0), coalesce(tw.total_withdrawn,0),
coalesce(te.payment_count,0), coalesce(pl.link_count,0), coalesce(pr.max_payment_links, 5), coalesce(pr.auto_withdraw_enabled, false),
pr.wallet_lightning, pr.wallet_binance_id, pr.wallet_usdt_bep20, pr.wallet_bkash, pr.wallet_nagad
from profiles pr
left join (select user_id, sum(amount_settled) as total_earned, count(*) as payment_count from payments where status = 'settled' group by user_id) te on te.user_id = pr.id
left join (select user_id, sum(amount_after_fee) as total_withdrawn from withdrawals where status = 'paid' group by user_id) tw on tw.user_id = pr.id
left join (select user_id, count(*) as link_count from payment_links group by user_id) pl on pl.user_id = pr.id
where pr.role = 'creator' order by rn;
end; $$;
