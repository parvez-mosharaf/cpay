-- ============================================================
-- CPAY — 0075: profile feature flags and permission matrix
-- ============================================================
-- Defaults are permissive for backwards compatibility. Once an admin saves
-- a flag, the explicit row becomes the source of truth for that profile.

create table if not exists profile_feature_flags (
  user_id uuid not null references profiles(id) on delete cascade,
  feature_key text not null check (feature_key in (
    'can_create_links', 'can_request_withdrawals', 'can_use_lightning',
    'can_use_onchain_qr', 'can_use_custom_domains'
  )),
  enabled boolean not null default true,
  updated_by uuid references profiles(id),
  updated_at timestamptz not null default now(),
  primary key (user_id, feature_key)
);
create index if not exists idx_profile_feature_flags_user on profile_feature_flags(user_id);
alter table profile_feature_flags enable row level security;
drop policy if exists "feature flags admin read" on profile_feature_flags;
create policy "feature flags admin read" on profile_feature_flags for select using (is_admin());

create or replace function cpay_feature_enabled(p_user_id uuid, p_feature_key text)
returns boolean language sql security definer stable set search_path = public as $$
  select coalesce(
    (select f.enabled from profile_feature_flags f where f.user_id=p_user_id and f.feature_key=p_feature_key),
    case when p_feature_key in ('can_create_links','can_request_withdrawals','can_use_lightning','can_use_onchain_qr') then true else false end
  );
$$;
revoke all on function cpay_feature_enabled(uuid,text) from public, anon;
grant execute on function cpay_feature_enabled(uuid,text) to authenticated;

create or replace function admin_list_profile_feature_flags(p_user_id uuid)
returns table(feature_key text, enabled boolean, is_custom boolean, updated_at timestamptz)
language plpgsql security definer stable set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if not exists (select 1 from profiles where id=p_user_id) then raise exception 'Profile not found'; end if;
  return query
  select v.feature_key,
    coalesce(f.enabled,v.default_enabled),
    f.user_id is not null,
    f.updated_at
  from (values
    ('can_create_links', true),
    ('can_request_withdrawals', true),
    ('can_use_lightning', true),
    ('can_use_onchain_qr', true),
    ('can_use_custom_domains', false)
  ) v(feature_key, default_enabled)
  left join profile_feature_flags f on f.user_id=p_user_id and f.feature_key=v.feature_key
  order by v.feature_key;
end; $$;
revoke all on function admin_list_profile_feature_flags(uuid) from public, anon;
grant execute on function admin_list_profile_feature_flags(uuid) to authenticated;

create or replace function admin_set_profile_feature_flag(p_user_id uuid, p_feature_key text, p_enabled boolean)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_old boolean;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_feature_key not in ('can_create_links','can_request_withdrawals','can_use_lightning','can_use_onchain_qr','can_use_custom_domains') then raise exception 'Invalid feature flag'; end if;
  if not exists (select 1 from profiles where id=p_user_id) then raise exception 'Profile not found'; end if;
  select enabled into v_old from profile_feature_flags where user_id=p_user_id and feature_key=p_feature_key;
  insert into profile_feature_flags(user_id,feature_key,enabled,updated_by,updated_at)
  values(p_user_id,p_feature_key,coalesce(p_enabled,false),auth.uid(),now())
  on conflict (user_id,feature_key) do update set enabled=excluded.enabled,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
  perform record_audit('profile.feature_flag_changed','profile',p_user_id::text,
    jsonb_build_object('feature_key',p_feature_key,'enabled',v_old),
    jsonb_build_object('feature_key',p_feature_key,'enabled',p_enabled));
  return coalesce(p_enabled,false);
end; $$;
revoke all on function admin_set_profile_feature_flag(uuid,text,boolean) from public, anon;
grant execute on function admin_set_profile_feature_flag(uuid,text,boolean) to authenticated;

create or replace function cpay_guard_link_feature()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not is_admin() and not cpay_feature_enabled(new.user_id,'can_create_links') then
    raise exception 'Payment link creation is disabled for this account';
  end if;
  return new;
end; $$;
drop trigger if exists trg_guard_link_feature on payment_links;
create trigger trg_guard_link_feature before insert on payment_links for each row execute function cpay_guard_link_feature();

create or replace function cpay_guard_withdrawal_feature()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not is_admin() and not cpay_feature_enabled(new.user_id,'can_request_withdrawals') then
    raise exception 'Withdrawal requests are disabled for this account';
  end if;
  return new;
end; $$;
drop trigger if exists trg_guard_withdrawal_feature on withdrawals;
create trigger trg_guard_withdrawal_feature before insert on withdrawals for each row execute function cpay_guard_withdrawal_feature();
