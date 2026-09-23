-- ============================================================
-- CPAY — 0058: a Manual withdrawals master switch
-- ============================================================
-- auto_withdraw_enabled only ever controlled whether an already-created
-- Lightning withdrawal gets INSTANTLY processed — it never stopped a
-- request from being created in the first place; turned off, a
-- Lightning request still gets created and just waits for a human,
-- same as bKash/Nagad/Binance/USDT always have.
--
-- This is the other, independent half: a master switch over whether
-- request_withdrawal() accepts a NEW request at all, of any method.
-- Off means a full freeze on new submissions — useful during an
-- incident, a balance-integrity check, or simply because the admin
-- wants only instant Lightning available for a while. The two toggles
-- are deliberately orthogonal:
--   Auto Lightning ON,  Manual ON   -> normal operation
--   Auto Lightning OFF, Manual ON   -> everything queues for a human
--   Auto Lightning ON,  Manual OFF  -> no new requests of any kind
--   Auto Lightning OFF, Manual OFF  -> full freeze
-- ============================================================

insert into app_settings (key, value)
select 'manual_withdrawals_enabled', 'true'::jsonb
where not exists (select 1 from app_settings where key = 'manual_withdrawals_enabled');


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

  if coalesce((select (value)::text from app_settings
               where key = 'manual_withdrawals_enabled'), 'true') <> 'true' then
    raise exception 'Withdrawal requests are temporarily paused. Please try again later.';
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
