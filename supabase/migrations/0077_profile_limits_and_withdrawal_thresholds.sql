-- ============================================================
-- CPAY — 0077: advanced per-profile limits and payout thresholds
-- ============================================================
-- NULL means "use the platform default". Limits are enforced in both the
-- authenticated request path and the settlement-triggered auto-queue path.

create table if not exists profile_limits (
  user_id uuid primary key references profiles(id) on delete cascade,
  max_invoice_amount numeric(18,2) check (max_invoice_amount is null or (max_invoice_amount >= 1 and max_invoice_amount <= 50000)),
  single_withdrawal_limit numeric(18,2) check (single_withdrawal_limit is null or single_withdrawal_limit >= 5),
  daily_withdrawal_limit numeric(18,2) check (daily_withdrawal_limit is null or daily_withdrawal_limit >= 5),
  updated_by uuid references profiles(id),
  updated_at timestamptz not null default now()
);
alter table profile_limits enable row level security;
drop policy if exists "profile limits admin read" on profile_limits;
create policy "profile limits admin read" on profile_limits for select using (is_admin());

create or replace function admin_get_profile_limits(p_user_id uuid)
returns table(max_invoice_amount numeric, single_withdrawal_limit numeric, daily_withdrawal_limit numeric, updated_at timestamptz)
language sql security definer stable set search_path = public as $$
  select l.max_invoice_amount, l.single_withdrawal_limit, l.daily_withdrawal_limit, l.updated_at
  from profile_limits l where is_admin() and l.user_id=p_user_id;
$$;
revoke all on function admin_get_profile_limits(uuid) from public, anon;
grant execute on function admin_get_profile_limits(uuid) to authenticated;

create or replace function admin_set_profile_limits(
  p_user_id uuid, p_max_invoice_amount numeric default null,
  p_single_withdrawal_limit numeric default null, p_daily_withdrawal_limit numeric default null
)
returns profile_limits language plpgsql security definer set search_path = public as $$
declare v_old profile_limits; v_row profile_limits;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if not exists (select 1 from profiles where id=p_user_id) then raise exception 'Profile not found'; end if;
  if p_max_invoice_amount is not null and (p_max_invoice_amount < 1 or p_max_invoice_amount > 50000) then raise exception 'Invoice limit must be between $1 and $50,000'; end if;
  if p_single_withdrawal_limit is not null and p_single_withdrawal_limit < 5 then raise exception 'Single withdrawal limit must be at least $5'; end if;
  if p_daily_withdrawal_limit is not null and p_daily_withdrawal_limit < 5 then raise exception 'Daily withdrawal limit must be at least $5'; end if;
  select * into v_old from profile_limits where user_id=p_user_id;
  insert into profile_limits(user_id,max_invoice_amount,single_withdrawal_limit,daily_withdrawal_limit,updated_by,updated_at)
  values(p_user_id,p_max_invoice_amount,p_single_withdrawal_limit,p_daily_withdrawal_limit,auth.uid(),now())
  on conflict(user_id) do update set max_invoice_amount=excluded.max_invoice_amount,single_withdrawal_limit=excluded.single_withdrawal_limit,daily_withdrawal_limit=excluded.daily_withdrawal_limit,updated_by=excluded.updated_by,updated_at=excluded.updated_at
  returning * into v_row;
  perform record_audit('profile.limits_changed','profile',p_user_id::text,to_jsonb(v_old),to_jsonb(v_row));
  return v_row;
end; $$;
revoke all on function admin_set_profile_limits(uuid,numeric,numeric,numeric) from public, anon;
grant execute on function admin_set_profile_limits(uuid,numeric,numeric,numeric) to authenticated;

-- Authenticated withdrawal path with single and Dhaka-calendar daily limits.
create or replace function request_withdrawal(p_amount numeric, p_method text, p_destination text)
returns withdrawals language plpgsql security definer set search_path = public as $$
declare v_uid uuid:=auth.uid(); v_fee numeric; v_available numeric; v_after numeric; v_row withdrawals; v_limit profile_limits; v_used numeric;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if coalesce((select value::text from app_settings where key='emergency_withdrawals_stop'),'false')='true' then raise exception 'Withdrawals are temporarily paused by the platform operator.'; end if;
  if coalesce((select value::text from app_settings where key='manual_withdrawals_enabled'),'true') <> 'true' then raise exception 'Withdrawal requests are temporarily paused. Please try again later.'; end if;
  perform 1 from profiles where id=v_uid for update;
  if p_amount is null or p_amount < 5 then raise exception 'Minimum withdrawal is $5'; end if;
  if p_method is null or p_method not in ('bkash','nagad','binance','lightning','usdt_bep20','bank') then raise exception 'Invalid withdrawal method'; end if;
  if p_destination is null or length(trim(p_destination))=0 then raise exception 'Destination account is required'; end if;
  if length(trim(p_destination)) > 500 then raise exception 'Destination is too long'; end if;
  select * into v_limit from profile_limits where user_id=v_uid;
  if v_limit.single_withdrawal_limit is not null and p_amount > v_limit.single_withdrawal_limit then raise exception 'This amount exceeds your single-withdrawal limit of $%', v_limit.single_withdrawal_limit; end if;
  select coalesce(sum(amount_requested),0) into v_used from withdrawals where user_id=v_uid and status in ('pending','approved','processing','paid') and requested_at >= ((now() at time zone 'Asia/Dhaka')::date::text || ' 00:00:00')::timestamp at time zone 'Asia/Dhaka';
  if v_limit.daily_withdrawal_limit is not null and v_used+p_amount > v_limit.daily_withdrawal_limit then raise exception 'This request exceeds your daily withdrawal limit of $%', v_limit.daily_withdrawal_limit; end if;
  select coalesce(withdrawal_fee_percent,3.0) into v_fee from profiles where id=v_uid;
  select b.available into v_available from get_balance_for(v_uid) b;
  if p_amount > v_available then raise exception 'Insufficient balance. Available: $%', round(v_available,2); end if;
  v_after:=round(p_amount*(1-v_fee/100),2);
  insert into withdrawals(user_id,amount_requested,fee_percent,amount_after_fee,method,destination,status) values(v_uid,p_amount,v_fee,v_after,p_method,trim(p_destination),'pending') returning * into v_row;
  return v_row;
end; $$;
revoke all on function request_withdrawal(numeric,text,text) from public, anon;
grant execute on function request_withdrawal(numeric,text,text) to authenticated;

-- Settlement-triggered auto queue respects the same per-profile limits.
create or replace function system_queue_withdrawal(p_user_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_profile profiles; v_limit profile_limits; v_available numeric; v_used numeric; v_amount numeric; v_destination text; v_method text; v_id uuid;
begin
  if coalesce((select value::text from app_settings where key='emergency_withdrawals_stop'),'false')='true' then return null; end if;
  if coalesce((select value::text from app_settings where key='manual_withdrawals_enabled'),'true') <> 'true' then return null; end if;
  select * into v_profile from profiles where id=p_user_id for update;
  if not found or coalesce(v_profile.auto_withdraw_enabled,false)=false then return null; end if;
  select * into v_limit from profile_limits where user_id=p_user_id;
  v_method:=coalesce(v_profile.default_withdrawal_method,'usdt_bep20');
  if v_method='lightning' or v_method not in ('bkash','nagad','binance','usdt_bep20','bank') then return null; end if;
  v_destination:=coalesce(nullif(trim(coalesce(v_profile.default_withdrawal_destination,'')),''),case v_method when 'bkash' then v_profile.wallet_bkash when 'nagad' then v_profile.wallet_nagad when 'binance' then v_profile.wallet_binance_id when 'usdt_bep20' then v_profile.wallet_usdt_bep20 when 'bank' then v_profile.wallet_bank end);
  if v_destination is null or length(trim(v_destination))=0 then return null; end if;
  select b.available into v_available from get_balance_for(p_user_id) b;
  if v_available is null or v_available < 5 then return null; end if;
  select coalesce(sum(amount_requested),0) into v_used from withdrawals where user_id=p_user_id and status in ('pending','approved','processing','paid') and requested_at >= ((now() at time zone 'Asia/Dhaka')::date::text || ' 00:00:00')::timestamp at time zone 'Asia/Dhaka';
  v_amount:=least(v_available,coalesce(v_limit.single_withdrawal_limit,v_available));
  if v_limit.daily_withdrawal_limit is not null then v_amount:=least(v_amount,greatest(v_limit.daily_withdrawal_limit-v_used,0)); end if;
  if v_amount < 5 then return null; end if;
  insert into withdrawals(user_id,amount_requested,fee_percent,amount_after_fee,method,destination,status,admin_note) values(p_user_id,v_amount,coalesce(v_profile.withdrawal_fee_percent,3.0),round(v_amount*(1-coalesce(v_profile.withdrawal_fee_percent,3.0)/100),2),v_method,trim(v_destination),'pending','Auto-queued on settlement') returning id into v_id;
  return v_id;
end; $$;
revoke all on function system_queue_withdrawal(uuid) from public, anon, authenticated;
grant execute on function system_queue_withdrawal(uuid) to service_role;
