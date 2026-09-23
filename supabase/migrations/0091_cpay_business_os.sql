-- ============================================================
-- CPAY — 0091: Business OS
-- Affiliate ownership, platform fee profit, hide-small overrides,
-- extra layouts, wallet modes, team chat/notices, reseller alerts.
-- ============================================================

-- ---------- 1. Profile affiliation and platform fee ----------
alter table profiles add column if not exists affiliate_code text;
alter table profiles add column if not exists referred_by uuid references profiles(id);
alter table profiles add column if not exists platform_fee_percent numeric(6,3);
alter table profiles add column if not exists hide_small_payments_mode text;
alter table profiles add column if not exists bio text;
alter table profiles add column if not exists public_slug text;
alter table profiles add column if not exists default_wallet_mode text;
alter table profiles add column if not exists default_link_theme text;

alter table profiles drop constraint if exists profiles_hide_small_mode_check;
alter table profiles add constraint profiles_hide_small_mode_check
  check (hide_small_payments_mode is null or hide_small_payments_mode in ('inherit','on','off'));

alter table profiles drop constraint if exists profiles_wallet_mode_check;
alter table profiles add constraint profiles_wallet_mode_check
  check (default_wallet_mode is null or default_wallet_mode in ('cashapp','all_wallets'));

alter table profiles drop constraint if exists profiles_platform_fee_range;
alter table profiles add constraint profiles_platform_fee_range
  check (platform_fee_percent is null or (platform_fee_percent >= 0 and platform_fee_percent <= 90));

create unique index if not exists idx_profiles_affiliate_code
  on profiles (lower(affiliate_code)) where affiliate_code is not null;
create unique index if not exists idx_profiles_public_slug
  on profiles (lower(public_slug)) where public_slug is not null;
create index if not exists idx_profiles_referred_by on profiles (referred_by);

-- ---------- 2. Payment link wallet mode + extra themes ----------
alter table payment_links add column if not exists wallet_mode text;
alter table payment_links add column if not exists invoice_theme text;

alter table payment_links drop constraint if exists payment_links_wallet_mode_check;
alter table payment_links add constraint payment_links_wallet_mode_check
  check (wallet_mode is null or wallet_mode in ('cashapp','all_wallets'));

alter table payment_links drop constraint if exists payment_links_theme_check;
alter table payment_links add constraint payment_links_theme_check
  check (theme is null or theme in (
    'keypad','classic','tile','focus','receipt',
    'pulse','ledger','studio','boulevard','aurora'
  ));

alter table payment_links drop constraint if exists payment_links_invoice_theme_check;
alter table payment_links add constraint payment_links_invoice_theme_check
  check (invoice_theme is null or invoice_theme in ('default','compact','poster','night','cashier'));

alter table site_domains drop constraint if exists site_domains_theme_check;
alter table site_domains add constraint site_domains_theme_check
  check (theme in (
    'keypad','classic','tile','focus','receipt',
    'pulse','ledger','studio','boulevard','aurora'
  ));

-- ---------- 3. Platform fee captured on each settled payment ----------
alter table payments add column if not exists platform_fee_percent numeric(6,3) not null default 0;
alter table payments add column if not exists platform_fee_amount numeric(12,2) not null default 0;

insert into app_settings (key, value)
select 'default_platform_fee_percent', '{"percent": 3.0}'::jsonb
where not exists (select 1 from app_settings where key = 'default_platform_fee_percent');

insert into app_settings (key, value)
select 'feature_affiliate_enabled', 'true'::jsonb
where not exists (select 1 from app_settings where key = 'feature_affiliate_enabled');

insert into app_settings (key, value)
select 'feature_reseller_team_withdraw', 'true'::jsonb
where not exists (select 1 from app_settings where key = 'feature_reseller_team_withdraw');

insert into app_settings (key, value)
select 'feature_reseller_notices', 'true'::jsonb
where not exists (select 1 from app_settings where key = 'feature_reseller_notices');

create or replace function cpay_platform_fee_percent(p_user_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select platform_fee_percent from profiles where id = p_user_id and platform_fee_percent is not null),
    (select coalesce((value->>'percent')::numeric, 3.0) from app_settings where key = 'default_platform_fee_percent'),
    3.0
  );
$$;
revoke all on function cpay_platform_fee_percent(uuid) from public, anon;
grant execute on function cpay_platform_fee_percent(uuid) to authenticated, service_role;

create or replace function stamp_payment_platform_fee()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pct numeric;
begin
  if new.status = 'settled' and (old.status is distinct from 'settled') then
    v_pct := cpay_platform_fee_percent(new.user_id);
    new.platform_fee_percent := v_pct;
    new.platform_fee_amount := round(coalesce(new.amount_settled, new.amount_requested, 0) * v_pct / 100.0, 2);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_stamp_payment_platform_fee on payments;
create trigger trg_stamp_payment_platform_fee
before update on payments
for each row execute function stamp_payment_platform_fee();

-- ---------- 4. Hide-small: global default + per-profile override ----------
create or replace function hide_threshold_for(p_user_id uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_mode text;
  v_enabled boolean;
  v_threshold numeric;
begin
  select coalesce(hide_small_payments_mode, 'inherit') into v_mode
  from profiles where id = p_user_id;

  select coalesce((value)::text = 'true' or value = 'true'::jsonb, false)
    into v_enabled
  from app_settings where key = 'hide_small_payments_enabled';

  select coalesce((value)::numeric, (value#>>'{}')::numeric, 10)
    into v_threshold
  from app_settings where key = 'hide_small_payments_threshold';

  if v_mode = 'off' then
    return -1;
  elsif v_mode = 'on' then
    return coalesce(v_threshold, 10);
  else
    if coalesce(v_enabled, false) then
      return coalesce(v_threshold, 10);
    end if;
    return -1;
  end if;
end;
$$;
revoke all on function hide_threshold_for(uuid) from public, anon;
grant execute on function hide_threshold_for(uuid) to authenticated, service_role;

-- ---------- 5. Balance: earnings net of platform fee ----------
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
    (select coalesce(sum(amount_settled - coalesce(platform_fee_amount, 0)), 0) as earned
     from payments
     where user_id = p_user_id and status = 'settled'
       and amount_settled >= hide_threshold_for(p_user_id)) e,
    (select coalesce(sum(amount_requested), 0) as queued
     from withdrawals where user_id = p_user_id and status <> 'rejected') q,
    (select coalesce(sum(amount_after_fee), 0) as withdrawn
     from withdrawals where user_id = p_user_id and status = 'paid') w;
$$;
revoke all on function get_balance_for(uuid) from public, anon, authenticated;
grant execute on function get_balance_for(uuid) to service_role;

-- ---------- 6. Admin profit = platform fees on settled earnings ----------
create or replace function admin_global_stats(
  p_start timestamptz default null,
  p_end   timestamptz default null
)
returns table (
  total_settled numeric, total_admin_profit numeric, total_withdrawn numeric,
  pending_withdrawals_count int, pending_withdrawals_amount numeric,
  payment_count bigint, active_creators bigint, calculated_node_balance numeric
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_total_settled numeric;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  select coalesce(sum(amount_settled), 0) into v_total_settled
  from payments
  where status = 'settled'
    and (p_start is null or settled_at >= p_start)
    and (p_end   is null or settled_at <= p_end);

  return query
  select
    v_total_settled,
    coalesce((
      select sum(p.platform_fee_amount)
      from payments p
      where p.status = 'settled'
        and (p_start is null or p.settled_at >= p_start)
        and (p_end   is null or p.settled_at <= p_end)
    ), 0),
    coalesce((
      select sum(w.amount_after_fee) from withdrawals w
      where w.status = 'paid'
        and (p_start is null or w.processed_at >= p_start)
        and (p_end   is null or w.processed_at <= p_end)
    ), 0),
    (select count(*) from withdrawals w where w.status = 'pending')::int,
    coalesce((select sum(w.amount_requested) from withdrawals w where w.status = 'pending'), 0),
    (select count(*) from payments p
      where p.status = 'settled'
        and (p_start is null or p.settled_at >= p_start)
        and (p_end   is null or p.settled_at <= p_end)),
    (select count(*) from profiles where account_status = 'active' and role in ('creator','moderator')),
    v_total_settled;
end;
$$;
revoke all on function admin_global_stats(timestamptz, timestamptz) from public, anon;
grant execute on function admin_global_stats(timestamptz, timestamptz) to authenticated;

drop function if exists daily_totals_for_cycle(date);
create or replace function daily_totals_for_cycle(p_cycle_date date)
returns table (
  cycle_start timestamptz,
  cycle_end timestamptz,
  total_settled numeric,
  payment_count bigint,
  total_withdrawn numeric,
  total_admin_profit numeric
)
language sql
security definer
stable
set search_path = public
as $$
  with b as (
    select
      (p_cycle_date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' as cycle_start,
      (p_cycle_date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka'
        + interval '24 hours' as cycle_end
  )
  select
    b.cycle_start,
    b.cycle_end,
    coalesce((
      select sum(p.amount_settled) from payments p
      where p.status = 'settled'
        and p.settled_at >= b.cycle_start
        and p.settled_at <  b.cycle_end
    ), 0),
    coalesce((
      select count(*) from payments p
      where p.status = 'settled'
        and p.settled_at >= b.cycle_start
        and p.settled_at <  b.cycle_end
    ), 0),
    coalesce((
      select sum(w.amount_after_fee) from withdrawals w
      where w.status = 'paid'
        and w.processed_at >= b.cycle_start
        and w.processed_at <  b.cycle_end
    ), 0),
    coalesce((
      select sum(p.platform_fee_amount) from payments p
      where p.status = 'settled'
        and p.settled_at >= b.cycle_start
        and p.settled_at <  b.cycle_end
    ), 0)
  from b;
$$;
revoke all on function daily_totals_for_cycle(date) from public, anon;
grant execute on function daily_totals_for_cycle(date) to service_role, authenticated;

-- ---------- 7. Affiliate codes for resellers ----------
create or replace function cpay_make_affiliate_code(p_user_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  i int := 0;
begin
  loop
    v_code := 'r' || substr(replace(p_user_id::text, '-', ''), 1, 4) || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
    exit when not exists (select 1 from profiles where lower(affiliate_code) = lower(v_code));
    i := i + 1;
    if i > 12 then raise exception 'Could not allocate affiliate code'; end if;
  end loop;
  return v_code;
end;
$$;

update profiles
set affiliate_code = cpay_make_affiliate_code(id)
where role = 'moderator' and affiliate_code is null;

create or replace function attach_freelancer_to_reseller(p_freelancer uuid, p_reseller uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_freelancer is null or p_reseller is null then return false; end if;
  if p_freelancer = p_reseller then return false; end if;
  if not exists (select 1 from profiles where id = p_reseller and role = 'moderator') then
    return false;
  end if;
  update profiles set referred_by = p_reseller where id = p_freelancer and referred_by is null;
  insert into moderator_assignments (moderator_id, creator_id)
  values (p_reseller, p_freelancer)
  on conflict do nothing;
  return true;
end;
$$;
revoke all on function attach_freelancer_to_reseller(uuid, uuid) from public, anon;
grant execute on function attach_freelancer_to_reseller(uuid, uuid) to service_role;

-- Keep the existing handle_new_user behaviour and add affiliate + reseller code.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''), split_part(new.email, '@', 1));
  v_requested_role text := case
    when new.raw_user_meta_data->>'requested_role' = 'reseller' then 'reseller'
    else 'freelancer'
  end;
  v_default_fee numeric;
  v_default_links int;
  v_auto boolean := cpay_auto_approval_enabled(v_requested_role);
  v_status text := case when v_auto then 'active' else 'pending' end;
  v_role text := case when v_auto and v_requested_role = 'reseller' then 'moderator' else 'creator' end;
  v_aff text := nullif(lower(trim(coalesce(new.raw_user_meta_data->>'affiliate_code',''))), '');
  v_reseller uuid;
  v_code text;
begin
  select coalesce((value->>'percent')::numeric, 3.0)
    into v_default_fee
  from app_settings where key = 'default_withdrawal_fee_percent';
  select coalesce((value->>'count')::int, 5)
    into v_default_links
  from app_settings where key = 'default_max_payment_links';

  if v_role = 'moderator' then
    v_code := cpay_make_affiliate_code(new.id);
  end if;

  insert into public.profiles
    (id, email, display_name, role, account_status,
     withdrawal_fee_percent, max_payment_links, affiliate_code)
  values
    (new.id, new.email, v_name, v_role, v_status,
     coalesce(v_default_fee, 3.0), coalesce(v_default_links, 5), v_code)
  on conflict (id) do nothing;

  insert into public.account_applications
    (user_id, email, display_name, requested_role, status, reviewed_at)
  values
    (new.id, new.email, v_name, v_requested_role,
     case when v_auto then 'approved' else 'pending' end,
     case when v_auto then now() else null end)
  on conflict (user_id) do update
    set email = excluded.email,
        display_name = excluded.display_name,
        requested_role = excluded.requested_role,
        updated_at = now();

  if v_requested_role = 'freelancer' and v_aff is not null then
    select id into v_reseller
    from profiles
    where lower(affiliate_code) = v_aff
      and role = 'moderator'
      and account_status = 'active'
    limit 1;
    if v_reseller is not null then
      perform attach_freelancer_to_reseller(new.id, v_reseller);
    end if;
  end if;

  return new;
end;
$$;

-- When admin approves a reseller, mint an affiliate code.
create or replace function ensure_reseller_affiliate_code()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role = 'moderator' and new.affiliate_code is null then
    new.affiliate_code := cpay_make_affiliate_code(new.id);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_reseller_affiliate_code on profiles;
create trigger trg_reseller_affiliate_code
before insert or update of role on profiles
for each row execute function ensure_reseller_affiliate_code();

-- ---------- 8. Team membership helpers ----------
create or replace function is_reseller()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'moderator');
$$;
revoke all on function is_reseller() from public, anon;
grant execute on function is_reseller() to authenticated;

create or replace function reseller_owns(p_freelancer uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = p_freelancer
      and referred_by = auth.uid()
  ) or exists (
    select 1 from moderator_assignments
    where moderator_id = auth.uid() and creator_id = p_freelancer
  );
$$;
revoke all on function reseller_owns(uuid) from public, anon;
grant execute on function reseller_owns(uuid) to authenticated;

create or replace function my_reseller_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select referred_by from profiles where id = auth.uid()),
    (select moderator_id from moderator_assignments where creator_id = auth.uid() limit 1)
  );
$$;
revoke all on function my_reseller_id() from public;
grant execute on function my_reseller_id() to authenticated;

-- ---------- 9. Public link preview gains wallet + invoice theme ----------
drop function if exists get_link_preview(text);
create or replace function get_link_preview(p_slug text)
returns table(
  display_name text,
  is_active boolean,
  og_image text,
  shop_name text,
  surcharge_percent numeric,
  cost_percent numeric,
  theme text,
  wallet_mode text,
  invoice_theme text
)
language sql security definer stable set search_path = public as $$
  select
    pl.display_name,
    pl.is_active,
    pl.og_image,
    s.name,
    coalesce(s.surcharge_percent,0),
    coalesce(pl.cost_percent, pr.cost_percent, 0),
    pl.theme,
    coalesce(pl.wallet_mode, pr.default_wallet_mode, 'all_wallets'),
    coalesce(pl.invoice_theme, 'default')
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  left join btcpay_shops s on s.id = pl.shop_id
  where pl.slug = p_slug
    and pl.deleted_at is null
    and pr.account_status = 'active'
  limit 1;
$$;
revoke all on function get_link_preview(text) from public;
grant execute on function get_link_preview(text) to anon, authenticated;

create or replace function set_payment_link_experience(
  p_link_id uuid,
  p_theme text default null,
  p_wallet_mode text default null,
  p_invoice_theme text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select user_id into v_owner from payment_links where id = p_link_id and deleted_at is null;
  if v_owner is null then raise exception 'Link not found'; end if;
  if v_owner <> v_uid and not is_admin() and not (is_reseller() and reseller_owns(v_owner)) then
    raise exception 'Not authorized';
  end if;
  if p_theme is not null and p_theme not in (
    'keypad','classic','tile','focus','receipt','pulse','ledger','studio','boulevard','aurora'
  ) then raise exception 'Unknown payment design'; end if;
  if p_wallet_mode is not null and p_wallet_mode not in ('cashapp','all_wallets') then
    raise exception 'Unknown wallet mode';
  end if;
  if p_invoice_theme is not null and p_invoice_theme not in ('default','compact','poster','night','cashier') then
    raise exception 'Unknown invoice design';
  end if;
  update payment_links
     set theme = coalesce(p_theme, theme),
         wallet_mode = coalesce(p_wallet_mode, wallet_mode),
         invoice_theme = coalesce(p_invoice_theme, invoice_theme)
   where id = p_link_id;
  return true;
end;
$$;
revoke all on function set_payment_link_experience(uuid,text,text,text) from public, anon;
grant execute on function set_payment_link_experience(uuid,text,text,text) to authenticated;

-- ---------- 10. Notices from reseller to team ----------
create table if not exists reseller_notices (
  id uuid primary key default uuid_generate_v4(),
  reseller_id uuid not null references profiles(id) on delete cascade,
  title text not null,
  body text not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_reseller_notices_reseller on reseller_notices(reseller_id, created_at desc);
alter table reseller_notices enable row level security;
drop policy if exists "reseller notices read" on reseller_notices;
create policy "reseller notices read" on reseller_notices for select using (
  is_admin()
  or reseller_id = auth.uid()
  or reseller_id = my_reseller_id()
);
drop policy if exists "reseller notices write" on reseller_notices;
create policy "reseller notices write" on reseller_notices for insert with check (
  is_admin() or (is_reseller() and reseller_id = auth.uid())
);

create or replace function post_reseller_notice(p_title text, p_body text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if not is_reseller() and not is_admin() then raise exception 'Not authorized'; end if;
  if length(trim(coalesce(p_title,''))) < 2 then raise exception 'Title required'; end if;
  if length(trim(coalesce(p_body,''))) < 2 then raise exception 'Message required'; end if;
  insert into reseller_notices(reseller_id, title, body)
  values (auth.uid(), trim(p_title), trim(p_body))
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function post_reseller_notice(text,text) from public, anon;
grant execute on function post_reseller_notice(text,text) to authenticated;

-- ---------- 11. Team chat (reseller <-> freelancer) + keep admin thread ----------
create table if not exists team_messages (
  id uuid primary key default uuid_generate_v4(),
  reseller_id uuid not null references profiles(id) on delete cascade,
  freelancer_id uuid not null references profiles(id) on delete cascade,
  sender_id uuid not null references profiles(id),
  body text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists idx_team_messages_pair on team_messages(reseller_id, freelancer_id, created_at);
alter table team_messages enable row level security;
drop policy if exists "team messages read" on team_messages;
create policy "team messages read" on team_messages for select using (
  is_admin()
  or (auth.uid() = reseller_id)
  or (auth.uid() = freelancer_id)
);
drop policy if exists "team messages insert" on team_messages;
create policy "team messages insert" on team_messages for insert with check (
  sender_id = auth.uid()
  and (
    is_admin()
    or (is_reseller() and reseller_id = auth.uid() and reseller_owns(freelancer_id))
    or (freelancer_id = auth.uid() and reseller_id = my_reseller_id())
  )
);

create or replace function send_team_message(p_other_id uuid, p_body text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_me uuid := auth.uid();
  v_reseller uuid;
  v_freelancer uuid;
  v_id uuid;
begin
  if v_me is null then raise exception 'Not authenticated'; end if;
  if length(trim(coalesce(p_body,''))) < 1 then raise exception 'Message required'; end if;
  if is_reseller() then
    if not reseller_owns(p_other_id) then raise exception 'Not on your team'; end if;
    v_reseller := v_me;
    v_freelancer := p_other_id;
  elsif is_admin() then
    raise exception 'Admin uses the support thread';
  else
    v_reseller := my_reseller_id();
    if v_reseller is null or v_reseller <> p_other_id then
      raise exception 'No reseller assigned';
    end if;
    v_freelancer := v_me;
  end if;
  insert into team_messages(reseller_id, freelancer_id, sender_id, body)
  values (v_reseller, v_freelancer, v_me, trim(p_body))
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function send_team_message(uuid,text) from public, anon;
grant execute on function send_team_message(uuid,text) to authenticated;

-- ---------- 12. Per-reseller Telegram / Discord ----------
create table if not exists reseller_alert_channels (
  reseller_id uuid primary key references profiles(id) on delete cascade,
  discord_webhook text,
  telegram_bot_token text,
  telegram_chat_id text,
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by uuid references profiles(id)
);
alter table reseller_alert_channels enable row level security;
drop policy if exists "alert channels admin" on reseller_alert_channels;
create policy "alert channels admin" on reseller_alert_channels for all using (is_admin()) with check (is_admin());
drop policy if exists "alert channels reseller read" on reseller_alert_channels;
create policy "alert channels reseller read" on reseller_alert_channels for select using (reseller_id = auth.uid());

create or replace function admin_set_reseller_alerts(
  p_reseller_id uuid,
  p_discord_webhook text,
  p_telegram_bot_token text,
  p_telegram_chat_id text,
  p_enabled boolean default true
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if not exists (select 1 from profiles where id = p_reseller_id and role = 'moderator') then
    raise exception 'Reseller not found';
  end if;
  insert into reseller_alert_channels(reseller_id, discord_webhook, telegram_bot_token, telegram_chat_id, enabled, updated_by, updated_at)
  values (p_reseller_id, nullif(trim(p_discord_webhook),''), nullif(trim(p_telegram_bot_token),''), nullif(trim(p_telegram_chat_id),''), coalesce(p_enabled,true), auth.uid(), now())
  on conflict (reseller_id) do update set
    discord_webhook = excluded.discord_webhook,
    telegram_bot_token = excluded.telegram_bot_token,
    telegram_chat_id = excluded.telegram_chat_id,
    enabled = excluded.enabled,
    updated_by = auth.uid(),
    updated_at = now();
  perform record_audit('reseller.alerts_updated','profile',p_reseller_id::text, null, jsonb_build_object('enabled', p_enabled));
  return true;
end;
$$;
revoke all on function admin_set_reseller_alerts(uuid,text,text,text,boolean) from public, anon;
grant execute on function admin_set_reseller_alerts(uuid,text,text,text,boolean) to authenticated;

-- Digest used by the 17:00 Asia/Dhaka job.
create or replace function reseller_cycle_digest(p_reseller_id uuid, p_cycle_date date default null)
returns table(
  reseller_id uuid,
  cycle_date date,
  total_settled numeric,
  payment_count bigint,
  link_slug text,
  link_name text,
  link_settled numeric,
  link_count bigint,
  cost_percent numeric
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_date date := coalesce(p_cycle_date, ((now() at time zone 'Asia/Dhaka') - interval '17 hours')::date);
  v_start timestamptz;
  v_end timestamptz;
begin
  v_start := (v_date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka';
  v_end := v_start + interval '24 hours';
  return query
  with team as (
    select p_reseller_id as uid
    union
    select creator_id from moderator_assignments where moderator_id = p_reseller_id
    union
    select id from profiles where referred_by = p_reseller_id
  ),
  settled as (
    select pl.slug, pl.display_name, coalesce(pl.cost_percent, pr.cost_percent, 0) as cost_percent,
           p.amount_settled
    from payments p
    join payment_links pl on pl.id = p.payment_link_id
    join profiles pr on pr.id = p.user_id
    where p.status = 'settled'
      and p.settled_at >= v_start
      and p.settled_at < v_end
      and p.user_id in (select uid from team)
  )
  select
    p_reseller_id,
    v_date,
    (select coalesce(sum(amount_settled),0) from settled),
    (select count(*) from settled),
    s.slug,
    s.display_name,
    sum(s.amount_settled),
    count(*),
    max(s.cost_percent)
  from settled s
  group by s.slug, s.display_name;
end;
$$;
revoke all on function reseller_cycle_digest(uuid, date) from public, anon;
grant execute on function reseller_cycle_digest(uuid, date) to service_role, authenticated;

create or replace function list_reseller_alert_targets()
returns table(
  reseller_id uuid,
  email text,
  display_name text,
  discord_webhook text,
  telegram_bot_token text,
  telegram_chat_id text
)
language sql
security definer
stable
set search_path = public
as $$
  select p.id, p.email, p.display_name, c.discord_webhook, c.telegram_bot_token, c.telegram_chat_id
  from reseller_alert_channels c
  join profiles p on p.id = c.reseller_id
  where c.enabled = true
    and p.role = 'moderator'
    and p.account_status = 'active'
    and (
      nullif(c.discord_webhook,'') is not null
      or (nullif(c.telegram_bot_token,'') is not null and nullif(c.telegram_chat_id,'') is not null)
    );
$$;
revoke all on function list_reseller_alert_targets() from public, anon, authenticated;
grant execute on function list_reseller_alert_targets() to service_role;

-- ---------- 13. Admin fee + hide-small controls ----------
create or replace function admin_set_platform_fee(p_user_id uuid, p_percent numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_old numeric;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_percent < 0 or p_percent > 90 then raise exception 'Fee must be 0–90 percent'; end if;
  select platform_fee_percent into v_old from profiles where id = p_user_id;
  if not found then raise exception 'Profile not found'; end if;
  update profiles set platform_fee_percent = round(p_percent, 3) where id = p_user_id;
  perform record_audit('profile.platform_fee', 'profile', p_user_id::text,
    jsonb_build_object('platform_fee_percent', v_old),
    jsonb_build_object('platform_fee_percent', round(p_percent,3)));
  return round(p_percent, 3);
end;
$$;
revoke all on function admin_set_platform_fee(uuid,numeric) from public, anon;
grant execute on function admin_set_platform_fee(uuid,numeric) to authenticated;

create or replace function admin_set_default_platform_fee(p_percent numeric)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_percent < 0 or p_percent > 90 then raise exception 'Fee must be 0–90 percent'; end if;
  insert into app_settings(key, value) values ('default_platform_fee_percent', jsonb_build_object('percent', p_percent))
  on conflict (key) do update set value = jsonb_build_object('percent', p_percent);
  perform record_audit('settings.default_platform_fee', 'setting', 'default_platform_fee_percent',
    null, jsonb_build_object('percent', p_percent));
  return p_percent;
end;
$$;
revoke all on function admin_set_default_platform_fee(numeric) from public, anon;
grant execute on function admin_set_default_platform_fee(numeric) to authenticated;

create or replace function admin_set_hide_small_payments(p_enabled boolean, p_threshold numeric default 10)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_threshold is null or p_threshold < 0 or p_threshold > 1000 then
    raise exception 'Threshold out of range';
  end if;
  insert into app_settings(key, value) values ('hide_small_payments_enabled', to_jsonb(p_enabled))
  on conflict (key) do update set value = to_jsonb(p_enabled);
  insert into app_settings(key, value) values ('hide_small_payments_threshold', to_jsonb(p_threshold))
  on conflict (key) do update set value = to_jsonb(p_threshold);
  perform record_audit('settings.hide_small_payments', 'setting', 'hide_small_payments_enabled',
    null, jsonb_build_object('enabled', p_enabled, 'threshold', p_threshold));
  return p_enabled;
end;
$$;
revoke all on function admin_set_hide_small_payments(boolean,numeric) from public, anon;
grant execute on function admin_set_hide_small_payments(boolean,numeric) to authenticated;

create or replace function admin_set_profile_hide_small(p_user_id uuid, p_mode text)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_mode not in ('inherit','on','off') then raise exception 'Mode must be inherit, on or off'; end if;
  update profiles set hide_small_payments_mode = p_mode where id = p_user_id;
  if not found then raise exception 'Profile not found'; end if;
  perform record_audit('profile.hide_small_payments', 'profile', p_user_id::text,
    null, jsonb_build_object('mode', p_mode));
  return p_mode;
end;
$$;
revoke all on function admin_set_profile_hide_small(uuid,text) from public, anon;
grant execute on function admin_set_profile_hide_small(uuid,text) to authenticated;

create or replace function admin_set_feature_toggle(p_key text, p_enabled boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_key not in (
    'feature_affiliate_enabled','feature_reseller_team_withdraw','feature_reseller_notices',
    'emergency_payments_stop','emergency_withdrawals_stop','manual_withdrawals_enabled',
    'auto_withdraw_enabled','public_feed_enabled','hide_small_payments_enabled'
  ) then raise exception 'Unknown toggle'; end if;
  insert into app_settings(key, value) values (p_key, to_jsonb(p_enabled))
  on conflict (key) do update set value = to_jsonb(p_enabled);
  perform record_audit('settings.feature_toggle', 'setting', p_key,
    null, jsonb_build_object('enabled', p_enabled));
  return p_enabled;
end;
$$;
revoke all on function admin_set_feature_toggle(text,boolean) from public, anon;
grant execute on function admin_set_feature_toggle(text,boolean) to authenticated;

-- ---------- 14. Team dashboards ----------
create or replace function my_team_members()
returns table(
  id uuid, email text, display_name text, account_status text, role text,
  affiliate boolean, available numeric, earned numeric, created_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not is_reseller() and not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pr.id, pr.email, pr.display_name, pr.account_status, pr.role,
         (pr.referred_by = auth.uid()) as affiliate,
         b.available, b.earned, pr.created_at
  from profiles pr
  left join lateral get_balance_for(pr.id) b on true
  where pr.id <> auth.uid()
    and (
      pr.referred_by = auth.uid()
      or exists (
        select 1 from moderator_assignments a
        where a.moderator_id = auth.uid() and a.creator_id = pr.id
      )
    )
  order by pr.created_at desc;
end;
$$;
revoke all on function my_team_members() from public, anon;
grant execute on function my_team_members() to authenticated;

create or replace function my_team_totals()
returns table(member_count bigint, team_earned numeric, team_available numeric, own_available numeric)
language plpgsql
security definer
stable
set search_path = public
as $$
declare v_own numeric;
begin
  if not is_reseller() and not is_admin() then raise exception 'Not authorized'; end if;
  select available into v_own from get_balance_for(auth.uid());
  return query
  select
    count(*)::bigint,
    coalesce(sum(b.earned),0),
    coalesce(sum(b.available),0),
    coalesce(v_own,0)
  from my_team_members() m
  left join lateral get_balance_for(m.id) b on true;
end;
$$;
revoke all on function my_team_totals() from public, anon;
grant execute on function my_team_totals() to authenticated;

-- Reseller (or admin) can cash out an owned freelancer using that account's fee + destination.
create or replace function reseller_request_withdrawal_for(
  p_user_id uuid,
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
  v_row withdrawals;
  v_avail numeric;
  v_fee numeric;
  v_after numeric;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not is_admin() then
    if not is_reseller() then raise exception 'Not authorized'; end if;
    if p_user_id <> auth.uid() and not reseller_owns(p_user_id) then
      raise exception 'That account is not on your team';
    end if;
    if coalesce((select value from app_settings where key='feature_reseller_team_withdraw'),'true'::jsonb) = 'false'::jsonb then
      raise exception 'Team withdrawals are turned off';
    end if;
  end if;
  if coalesce((select value::text from app_settings where key='emergency_withdrawals_stop'),'false') = 'true' then
    raise exception 'Withdrawals are paused';
  end if;
  if p_amount is null or p_amount < 5 then raise exception 'Minimum withdrawal is $5'; end if;
  if p_method not in ('bkash','nagad','binance','lightning','usdt_bep20','bank') then
    raise exception 'Invalid method';
  end if;
  if nullif(trim(p_destination),'') is null then raise exception 'Destination required'; end if;

  perform 1 from profiles where id = p_user_id for update;
  select available into v_avail from get_balance_for(p_user_id);
  if v_avail is null or v_avail < p_amount then
    raise exception 'Insufficient balance. Available: $%', coalesce(v_avail,0);
  end if;
  select coalesce(withdrawal_fee_percent, 3.0) into v_fee from profiles where id = p_user_id;
  v_after := round(p_amount * (1 - v_fee / 100.0), 2);
  insert into withdrawals(user_id, amount_requested, fee_percent, amount_after_fee, method, destination, status, admin_note)
  values (p_user_id, p_amount, v_fee, v_after, p_method, trim(p_destination), 'pending',
          case when p_user_id = auth.uid() then null else 'Submitted by reseller' end)
  returning * into v_row;
  return v_row;
end;
$$;
revoke all on function reseller_request_withdrawal_for(uuid,numeric,text,text) from public, anon;
grant execute on function reseller_request_withdrawal_for(uuid,numeric,text,text) to authenticated;

-- ---------- 15. Profile workspace extras ----------
create or replace function update_my_public_profile(p_display_name text, p_bio text, p_public_slug text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if p_public_slug is not null and p_public_slug !~ '^[a-z0-9][a-z0-9-]{1,46}[a-z0-9]$' then
    raise exception 'Store slug must be 3–48 lowercase letters, numbers or hyphen';
  end if;
  update profiles
     set display_name = coalesce(nullif(trim(p_display_name),''), display_name),
         bio = nullif(trim(p_bio),''),
         public_slug = nullif(lower(trim(p_public_slug)),'')
   where id = auth.uid();
  return true;
end;
$$;
revoke all on function update_my_public_profile(text,text,text) from public, anon;
grant execute on function update_my_public_profile(text,text,text) to authenticated;

create or replace function admin_list_business_profiles()
returns table(
  id uuid, email text, display_name text, role text, account_status text,
  affiliate_code text, referred_by uuid, reseller_name text,
  platform_fee_percent numeric, hide_small_payments_mode text,
  withdrawal_fee_percent numeric, earned numeric, available numeric,
  created_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pr.id, pr.email, pr.display_name, pr.role, pr.account_status,
         pr.affiliate_code, pr.referred_by, rs.display_name,
         coalesce(pr.platform_fee_percent, cpay_platform_fee_percent(pr.id)),
         coalesce(pr.hide_small_payments_mode, 'inherit'),
         pr.withdrawal_fee_percent,
         b.earned, b.available, pr.created_at
  from profiles pr
  left join profiles rs on rs.id = pr.referred_by
  left join lateral get_balance_for(pr.id) b on true
  where pr.role in ('creator','moderator','admin')
  order by pr.created_at desc;
end;
$$;
revoke all on function admin_list_business_profiles() from public, anon;
grant execute on function admin_list_business_profiles() to authenticated;

-- Expand feature-flag catalog used by the admin matrix.
alter table profile_feature_flags drop constraint if exists profile_feature_flags_feature_key_check;
alter table profile_feature_flags add constraint profile_feature_flags_feature_key_check
  check (feature_key in (
    'can_create_links', 'can_request_withdrawals', 'can_use_lightning',
    'can_use_onchain_qr', 'can_use_custom_domains',
    'can_set_cost', 'can_affiliate', 'can_team_withdraw', 'can_send_notices'
  ));

create or replace function set_payment_link_theme(p_link_id uuid, p_theme text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old text;
  v_user uuid;
begin
  if p_theme is not null and p_theme not in (
    'keypad','classic','tile','focus','receipt','pulse','ledger','studio','boulevard','aurora'
  ) then
    raise exception 'Invalid payment theme';
  end if;
  select theme, user_id into v_old, v_user from payment_links
  where id = p_link_id and deleted_at is null for update;
  if not found then raise exception 'Payment link not found'; end if;
  if not is_admin() and v_user <> auth.uid() and not (is_reseller() and reseller_owns(v_user)) then
    raise exception 'Not authorized';
  end if;
  update payment_links set theme = p_theme where id = p_link_id;
  return p_theme;
end;
$$;


create or replace function validate_link_slug()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.slug := trim(new.slug);
  if new.slug !~ '^[a-z0-9][a-z0-9-]{2,48}[a-z0-9]$' and new.slug !~ '^[A-Za-z0-9][A-Za-z0-9-]{2,48}[A-Za-z0-9]$' then
    raise exception 'Invalid slug';
  end if;
  if lower(new.slug) in (
    'index','login','register','dashboard','admin','404','config','theme',
    'assets','favicon','invoice-cpay-v2','api','u','static','public',
    'well-known','robots','sitemap','moderator','reseller','store','classic'
  ) then
    raise exception 'That link name is reserved';
  end if;
  return new;
end;
$$;

-- Schedule (run after Vault has cpay_cron_secret):
-- select cron.schedule('cpay-reseller-digest', '0 11 * * *',
--   $job$ select net.http_post(
--     url := current_setting('app.functions_url', true) || '/reseller-digest',
--     headers := jsonb_build_object('x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cpay_cron_secret' limit 1), 'content-type','application/json'),
--     body := '{}'::jsonb
--   ); $job$);
-- 11:00 UTC = 5:00 PM Asia/Dhaka.
