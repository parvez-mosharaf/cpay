-- ============================================================
-- CPAY — 0078: profile emergency suspension
-- ============================================================
-- Suspension immediately makes a profile's public links non-payable and
-- stops new/auto withdrawal paths, while preserving ledger history.

create table if not exists profile_suspensions (
  id bigserial primary key,
  user_id uuid not null references profiles(id) on delete cascade,
  reason text not null,
  suspended_by uuid not null references profiles(id),
  suspended_at timestamptz not null default now(),
  lifted_by uuid references profiles(id),
  lifted_at timestamptz
);
create index if not exists idx_profile_suspensions_user on profile_suspensions(user_id, suspended_at desc);
alter table profile_suspensions enable row level security;
drop policy if exists "suspensions admin read" on profile_suspensions;
create policy "suspensions admin read" on profile_suspensions for select using (is_admin());

create or replace function admin_set_profile_suspension(p_user_id uuid, p_suspended boolean, p_reason text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_role text; v_status text; v_id bigint;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_user_id=auth.uid() then raise exception 'You cannot suspend your own account'; end if;
  if p_suspended and nullif(trim(coalesce(p_reason,'')),'') is null then raise exception 'Enter a suspension reason'; end if;
  select role,account_status into v_role,v_status from profiles where id=p_user_id for update;
  if not found then raise exception 'Profile not found'; end if;
  if p_suspended and v_role='admin' then raise exception 'Admin accounts require the protected account-control flow'; end if;
  if p_suspended then
    update profiles set account_status='suspended' where id=p_user_id;
    insert into profile_suspensions(user_id,reason,suspended_by) values(p_user_id,trim(p_reason),auth.uid()) returning id into v_id;
    perform record_audit('profile.emergency_suspended','profile',p_user_id::text,jsonb_build_object('account_status',v_status),jsonb_build_object('account_status','suspended','reason',trim(p_reason)));
  else
    update profiles set account_status='active' where id=p_user_id and account_status='suspended';
    update profile_suspensions set lifted_by=auth.uid(),lifted_at=now() where id=(select id from profile_suspensions where user_id=p_user_id and lifted_at is null order by suspended_at desc limit 1);
    perform record_audit('profile.emergency_unsuspended','profile',p_user_id::text,jsonb_build_object('account_status','suspended'),jsonb_build_object('account_status','active'));
  end if;
  return p_suspended;
end; $$;
revoke all on function admin_set_profile_suspension(uuid,boolean,text) from public, anon;
grant execute on function admin_set_profile_suspension(uuid,boolean,text) to authenticated;

-- Public page lookup must hide suspended profiles, not merely prevent new link writes.
drop function if exists get_link_preview(text);
create or replace function get_link_preview(p_slug text)
returns table(display_name text,is_active boolean,og_image text,shop_name text,surcharge_percent numeric,cost_percent numeric,theme text)
language sql security definer stable set search_path = public as $$
  select pl.display_name,pl.is_active,pl.og_image,s.name,coalesce(s.surcharge_percent,0),coalesce(pl.cost_percent,pr.cost_percent,0),pl.theme
  from payment_links pl join profiles pr on pr.id=pl.user_id left join btcpay_shops s on s.id=pl.shop_id
  where pl.slug=p_slug and pl.deleted_at is null and pr.account_status='active' limit 1;
$$;
revoke all on function get_link_preview(text) from public;
grant execute on function get_link_preview(text) to anon, authenticated;

-- Service-side auto queue refuses suspended profiles.
create or replace function system_queue_withdrawal(p_user_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_profile profiles; v_limit profile_limits; v_available numeric; v_used numeric; v_amount numeric; v_destination text; v_method text; v_id uuid;
begin
  if coalesce((select value::text from app_settings where key='emergency_withdrawals_stop'),'false')='true' then return null; end if;
  if coalesce((select value::text from app_settings where key='manual_withdrawals_enabled'),'true') <> 'true' then return null; end if;
  select * into v_profile from profiles where id=p_user_id for update;
  if not found or v_profile.account_status <> 'active' or coalesce(v_profile.auto_withdraw_enabled,false)=false then return null; end if;
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

-- Service-role invoice lookup must enforce the same suspension boundary.
create or replace function system_link_for_invoice(p_slug text)
returns table(link_id uuid,user_id uuid,slug text,display_name text,is_active boolean,store_id text,api_key_env text,surcharge_percent numeric,cost_percent numeric)
language sql security definer stable set search_path = public as $$
  select pl.id,pl.user_id,pl.slug,pl.display_name,pl.is_active,s.store_id,s.api_key_env,coalesce(s.surcharge_percent,0),coalesce(pl.cost_percent,pr.cost_percent,0)
  from payment_links pl join profiles pr on pr.id=pl.user_id left join btcpay_shops s on s.id=pl.shop_id and s.is_active=true
  where pl.slug=p_slug and pl.deleted_at is null and pr.account_status='active' limit 1;
$$;
revoke all on function system_link_for_invoice(text) from public, anon, authenticated;
grant execute on function system_link_for_invoice(text) to service_role;
