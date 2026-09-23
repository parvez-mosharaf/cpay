-- ============================================================
-- CPAY — 0092: Model G
-- Platform fee (admin) ≠ link cost (payer markup) ≠ reseller commission.
-- Commission is stamped on settle from net (settled - platform fee).
-- Reseller may lock cost_percent for attached freelancers.
-- Only admin can change commission rates and unlock overrides.
-- ============================================================

alter table profiles add column if not exists reseller_commission_percent numeric(6,3);
alter table profiles add column if not exists team_cost_percent numeric(6,3);
alter table profiles add column if not exists cost_locked boolean not null default false;

alter table profiles drop constraint if exists profiles_reseller_commission_range;
alter table profiles add constraint profiles_reseller_commission_range
  check (reseller_commission_percent is null or (reseller_commission_percent >= 0 and reseller_commission_percent <= 50));

alter table profiles drop constraint if exists profiles_team_cost_range;
alter table profiles add constraint profiles_team_cost_range
  check (team_cost_percent is null or (team_cost_percent >= 0 and team_cost_percent <= 1000));

insert into app_settings(key, value)
select 'default_reseller_commission_percent', '{"percent": 8.0}'::jsonb
where not exists (select 1 from app_settings where key = 'default_reseller_commission_percent');

alter table payments add column if not exists reseller_id uuid references profiles(id);
alter table payments add column if not exists reseller_commission_percent numeric(6,3) not null default 0;
alter table payments add column if not exists reseller_commission_amount numeric(12,2) not null default 0;
create index if not exists idx_payments_reseller on payments(reseller_id) where reseller_id is not null;

create or replace function cpay_reseller_for(p_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select referred_by from profiles where id = p_user_id),
    (select moderator_id from moderator_assignments where creator_id = p_user_id limit 1)
  );
$$;

create or replace function cpay_reseller_commission_percent(p_reseller_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select reseller_commission_percent from profiles where id = p_reseller_id and reseller_commission_percent is not null),
    (select coalesce((value->>'percent')::numeric, 8.0) from app_settings where key = 'default_reseller_commission_percent'),
    8.0
  );
$$;

-- Extend settle stamp: platform fee first, then affiliate commission on the net.
create or replace function stamp_payment_platform_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pct numeric;
  v_reseller uuid;
  v_comm numeric;
  v_net numeric;
begin
  if new.status = 'settled' and (old.status is distinct from 'settled') then
    v_pct := cpay_platform_fee_percent(new.user_id);
    new.platform_fee_percent := v_pct;
    new.platform_fee_amount := round(coalesce(new.amount_settled, new.amount_requested, 0) * v_pct / 100.0, 2);

    -- Only affiliate-attached books pay commission. Assigned-only stays 0.
    select referred_by into v_reseller from profiles where id = new.user_id;
    if v_reseller is not null and v_reseller <> new.user_id then
      v_comm := cpay_reseller_commission_percent(v_reseller);
      v_net := greatest(coalesce(new.amount_settled, 0) - coalesce(new.platform_fee_amount, 0), 0);
      new.reseller_id := v_reseller;
      new.reseller_commission_percent := v_comm;
      new.reseller_commission_amount := round(v_net * v_comm / 100.0, 2);
    else
      new.reseller_id := null;
      new.reseller_commission_percent := 0;
      new.reseller_commission_amount := 0;
    end if;
  end if;
  return new;
end;
$$;

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
    (select
        coalesce((
          select sum(amount_settled - coalesce(platform_fee_amount,0) - coalesce(reseller_commission_amount,0))
          from payments
          where user_id = p_user_id and status = 'settled'
            and amount_settled >= hide_threshold_for(p_user_id)
        ), 0)
        +
        coalesce((
          select sum(reseller_commission_amount)
          from payments
          where reseller_id = p_user_id and status = 'settled'
            and amount_settled >= hide_threshold_for(p_user_id)
        ), 0)
        as earned
    ) e,
    (select coalesce(sum(amount_requested), 0) as queued
     from withdrawals where user_id = p_user_id and status <> 'rejected') q,
    (select coalesce(sum(amount_after_fee), 0) as withdrawn
     from withdrawals where user_id = p_user_id and status = 'paid') w;
$$;
revoke all on function get_balance_for(uuid) from public, anon, authenticated;
grant execute on function get_balance_for(uuid) to service_role;

create or replace function admin_set_reseller_commission(p_reseller_id uuid, p_percent numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_percent < 0 or p_percent > 50 then raise exception 'Commission must be 0–50 percent'; end if;
  if not exists (select 1 from profiles where id = p_reseller_id and role = 'moderator') then
    raise exception 'Reseller not found';
  end if;
  update profiles set reseller_commission_percent = round(p_percent, 3) where id = p_reseller_id;
  perform record_audit('reseller.commission', 'profile', p_reseller_id::text,
    null, jsonb_build_object('percent', round(p_percent,3)));
  return round(p_percent, 3);
end;
$$;
revoke all on function admin_set_reseller_commission(uuid,numeric) from public, anon;
grant execute on function admin_set_reseller_commission(uuid,numeric) to authenticated;

create or replace function admin_set_default_reseller_commission(p_percent numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_percent < 0 or p_percent > 50 then raise exception 'Commission must be 0–50 percent'; end if;
  insert into app_settings(key,value) values ('default_reseller_commission_percent', jsonb_build_object('percent', p_percent))
  on conflict (key) do update set value = jsonb_build_object('percent', p_percent);
  return p_percent;
end;
$$;
revoke all on function admin_set_default_reseller_commission(numeric) from public, anon;
grant execute on function admin_set_default_reseller_commission(numeric) to authenticated;

-- Reseller locks / sets cost_percent on attached freelancer books.
-- This is payer markup, not platform fee and not commission.
create or replace function reseller_set_freelancer_cost(p_freelancer_id uuid, p_percent numeric, p_lock boolean default true)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_max numeric;
begin
  if not is_reseller() and not is_admin() then raise exception 'Not authorized'; end if;
  if not is_admin() and not reseller_owns(p_freelancer_id) then
    raise exception 'That account is not on your team';
  end if;
  if p_percent < 0 then raise exception 'Cost must be 0 or more'; end if;
  select coalesce((value)::text::numeric, 1000) into v_max
  from app_settings where key = 'max_user_cost_percent';
  if p_percent > coalesce(v_max, 1000) then
    raise exception 'Cost cannot exceed %%%', v_max;
  end if;
  update profiles
     set cost_percent = round(p_percent, 3),
         cost_locked = coalesce(p_lock, true)
   where id = p_freelancer_id;
  if not is_admin() then
    update profiles set team_cost_percent = round(p_percent, 3) where id = auth.uid();
  end if;
  return round(p_percent, 3);
end;
$$;
revoke all on function reseller_set_freelancer_cost(uuid,numeric,boolean) from public, anon;
grant execute on function reseller_set_freelancer_cost(uuid,numeric,boolean) to authenticated;

-- If cost is locked by reseller, freelancer cannot change it.
create or replace function set_my_cost_percent(p_percent numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_max numeric;
  v_role text;
  v_locked boolean;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select role, cost_locked into v_role, v_locked from profiles where id = v_uid;
  if v_role not in ('creator', 'moderator') then raise exception 'Not authorized'; end if;
  if coalesce(v_locked, false) and not is_admin() then
    raise exception 'Your reseller locked this payment-link cost rate';
  end if;
  if p_percent is null or p_percent < 0 then raise exception 'Cost must be 0 or more'; end if;
  select coalesce((value)::text::numeric, 25) into v_max
  from app_settings where key = 'max_user_cost_percent';
  if p_percent > coalesce(v_max, 25) then raise exception 'Cost cannot exceed %%%', v_max; end if;
  update profiles set cost_percent = round(p_percent, 3) where id = v_uid;
  return round(p_percent, 3);
end;
$$;

create or replace function my_commission_totals()
returns table(commission_earned numeric, team_net numeric, payment_count bigint)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  return query
  select
    coalesce(sum(p.reseller_commission_amount),0),
    coalesce(sum(p.amount_settled - p.platform_fee_amount),0),
    count(*)
  from payments p
  where p.reseller_id = auth.uid() and p.status = 'settled';
end;
$$;
revoke all on function my_commission_totals() from public, anon;
grant execute on function my_commission_totals() to authenticated;

-- Link-level cost cannot bypass a reseller lock.
create or replace function set_link_cost_percent(p_link_id uuid, p_percent numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
  v_locked boolean;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select pl.user_id, pr.cost_locked into v_owner, v_locked
  from payment_links pl join profiles pr on pr.id = pl.user_id
  where pl.id = p_link_id and pl.deleted_at is null;
  if v_owner is null then raise exception 'Link not found'; end if;
  if v_owner <> v_uid and not is_admin() and not (is_reseller() and reseller_owns(v_owner)) then
    raise exception 'Not authorized';
  end if;
  if coalesce(v_locked, false) and not is_admin() and v_uid = v_owner then
    raise exception 'Your reseller locked this payment-link cost rate';
  end if;
  if p_percent is not null and (p_percent < 0 or p_percent > 1000) then
    raise exception 'Cost must be between 0 and 1000';
  end if;
  update payment_links
     set cost_percent = case when p_percent is null then null else round(p_percent, 3) end
   where id = p_link_id;
  return p_percent;
end;
$$;

-- Lock or set the same payer-markup cost on every affiliate freelancer.
create or replace function reseller_lock_team_cost(p_percent numeric, p_lock boolean default true)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_count int := 0;
begin
  if not is_reseller() and not is_admin() then raise exception 'Not authorized'; end if;
  if p_percent < 0 or p_percent > 1000 then raise exception 'Cost must be 0–1000'; end if;
  update profiles
     set team_cost_percent = round(p_percent, 3)
   where id = auth.uid();
  update profiles
     set cost_percent = round(p_percent, 3),
         cost_locked = coalesce(p_lock, true)
   where referred_by = auth.uid()
      or id in (select creator_id from moderator_assignments where moderator_id = auth.uid());
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function reseller_lock_team_cost(numeric,boolean) from public, anon;
grant execute on function reseller_lock_team_cost(numeric,boolean) to authenticated;

-- Each role sees its own split. Nobody else can change it except admin.
create or replace function my_earnings_split()
returns table(
  settled numeric,
  platform_fee numeric,
  reseller_commission_out numeric,
  reseller_commission_in numeric,
  net numeric,
  cost_percent numeric,
  cost_locked boolean,
  commission_percent numeric
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  return query
  select
    coalesce((select sum(amount_settled) from payments where user_id = v_uid and status = 'settled'), 0),
    coalesce((select sum(platform_fee_amount) from payments where user_id = v_uid and status = 'settled'), 0),
    coalesce((select sum(reseller_commission_amount) from payments where user_id = v_uid and status = 'settled'), 0),
    coalesce((select sum(reseller_commission_amount) from payments where reseller_id = v_uid and status = 'settled'), 0),
    (select available from get_balance_for(v_uid)),
    (select cost_percent from profiles where id = v_uid),
    (select cost_locked from profiles where id = v_uid),
    case
      when (select role from profiles where id = v_uid) = 'moderator'
        then cpay_reseller_commission_percent(v_uid)
      else coalesce((
        select cpay_reseller_commission_percent(referred_by)
        from profiles where id = v_uid and referred_by is not null
      ), 0)
    end;
end;
$$;
revoke all on function my_earnings_split() from public, anon;
grant execute on function my_earnings_split() to authenticated;

create or replace function my_affiliate_commission_rows()
returns table(
  freelancer_id uuid,
  freelancer_name text,
  link_slug text,
  settled numeric,
  platform_fee numeric,
  commission numeric,
  settled_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not is_reseller() and not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select p.user_id,
         coalesce(pr.display_name, pr.email),
         pl.slug,
         p.amount_settled,
         p.platform_fee_amount,
         p.reseller_commission_amount,
         p.settled_at
  from payments p
  join profiles pr on pr.id = p.user_id
  left join payment_links pl on pl.id = p.payment_link_id
  where p.status = 'settled'
    and p.reseller_id = auth.uid()
  order by p.settled_at desc
  limit 100;
end;
$$;
revoke all on function my_affiliate_commission_rows() from public, anon;
grant execute on function my_affiliate_commission_rows() to authenticated;
