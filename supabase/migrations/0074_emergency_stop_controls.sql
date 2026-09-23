-- ============================================================
-- CPAY — 0074: emergency stop controls
-- ============================================================
-- Admin-only kill switches for new invoices and all new withdrawals.
-- Both manual and settlement-triggered withdrawal paths fail closed.

insert into app_settings(key, value)
values
  ('emergency_payments_stop', 'false'::jsonb),
  ('emergency_withdrawals_stop', 'false'::jsonb)
on conflict (key) do nothing;

-- Recreate the authenticated withdrawal path with the emergency stop in
-- addition to the existing manual_withdrawals_enabled switch.
create or replace function request_withdrawal(p_amount numeric, p_method text, p_destination text)
returns withdrawals language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_fee_percent numeric; v_available numeric;
  v_amount_after_fee numeric; v_row withdrawals;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if coalesce((select value::text from app_settings where key='emergency_withdrawals_stop'),'false') = 'true' then
    raise exception 'Withdrawals are temporarily paused by the platform operator.';
  end if;
  if coalesce((select value::text from app_settings where key='manual_withdrawals_enabled'),'true') <> 'true' then
    raise exception 'Withdrawal requests are temporarily paused. Please try again later.';
  end if;
  perform 1 from profiles where id=v_uid for update;
  if p_amount is null or p_amount < 5 then raise exception 'Minimum withdrawal is $5'; end if;
  if p_method is null or p_method not in ('bkash','nagad','binance','lightning','usdt_bep20','bank') then raise exception 'Invalid withdrawal method'; end if;
  if p_destination is null or length(trim(p_destination))=0 then raise exception 'Destination account is required'; end if;
  if length(trim(p_destination)) > 500 then raise exception 'Destination is too long'; end if;
  select coalesce(withdrawal_fee_percent,3.0) into v_fee_percent from profiles where id=v_uid;
  select b.available into v_available from get_balance_for(v_uid) b;
  if p_amount > v_available then raise exception 'Insufficient balance. Available: $%', round(v_available,2); end if;
  v_amount_after_fee := round(p_amount*(1-v_fee_percent/100),2);
  insert into withdrawals(user_id,amount_requested,fee_percent,amount_after_fee,method,destination,status)
  values(v_uid,p_amount,v_fee_percent,v_amount_after_fee,p_method,trim(p_destination),'pending') returning * into v_row;
  return v_row;
end; $$;
revoke all on function request_withdrawal(numeric,text,text) from public, anon;
grant execute on function request_withdrawal(numeric,text,text) to authenticated;

-- Recreate the service-role auto-queue path with the same emergency stop.
create or replace function system_queue_withdrawal(p_user_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_profile profiles; v_available numeric; v_destination text; v_method text; v_id uuid;
begin
  if coalesce((select value::text from app_settings where key='emergency_withdrawals_stop'),'false') = 'true' then return null; end if;
  if coalesce((select value::text from app_settings where key='manual_withdrawals_enabled'),'true') <> 'true' then return null; end if;
  select * into v_profile from profiles where id=p_user_id for update;
  if not found or coalesce(v_profile.auto_withdraw_enabled,false)=false then return null; end if;
  v_method := coalesce(v_profile.default_withdrawal_method,'usdt_bep20');
  if v_method='lightning' or v_method not in ('bkash','nagad','binance','usdt_bep20','bank') then return null; end if;
  v_destination := coalesce(nullif(trim(coalesce(v_profile.default_withdrawal_destination,'')),''), case v_method
    when 'bkash' then v_profile.wallet_bkash when 'nagad' then v_profile.wallet_nagad
    when 'binance' then v_profile.wallet_binance_id when 'usdt_bep20' then v_profile.wallet_usdt_bep20
    when 'bank' then v_profile.wallet_bank end);
  if v_destination is null or length(trim(v_destination))=0 then return null; end if;
  select b.available into v_available from get_balance_for(p_user_id) b;
  if v_available is null or v_available < 5 then return null; end if;
  insert into withdrawals(user_id,amount_requested,fee_percent,amount_after_fee,method,destination,status,admin_note)
  values(p_user_id,v_available,coalesce(v_profile.withdrawal_fee_percent,3.0),round(v_available*(1-coalesce(v_profile.withdrawal_fee_percent,3.0)/100),2),v_method,trim(v_destination),'pending','Auto-queued on settlement') returning id into v_id;
  return v_id;
end; $$;
revoke all on function system_queue_withdrawal(uuid) from public, anon, authenticated;
grant execute on function system_queue_withdrawal(uuid) to service_role;
