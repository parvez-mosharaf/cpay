-- ============================================================
-- CPAY — 0073: withdrawal freeze applies to auto-queue too
-- ============================================================
-- The manual withdrawal switch already blocks request_withdrawal(), but
-- settlement-triggered system_queue_withdrawal() bypassed that switch.
-- During an incident, turning the switch off must stop both paths.

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
  if coalesce((select value::text from app_settings
               where key = 'manual_withdrawals_enabled'), 'true') <> 'true' then
    return null;
  end if;

  select * into v_profile from profiles where id = p_user_id for update;
  if not found or coalesce(v_profile.auto_withdraw_enabled, false) = false then
    return null;
  end if;

  v_method := coalesce(v_profile.default_withdrawal_method, 'usdt_bep20');
  -- Lightning payouts are creator-initiated: a fresh bolt11 invoice for the
  -- exact amount is required, so settlement auto-queue does not use it.
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
