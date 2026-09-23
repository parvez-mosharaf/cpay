-- ============================================================
-- CPAY — 0067: account applications and controlled onboarding
-- ============================================================
-- New accounts are pending by default. Existing accounts are active.
-- Legacy database role values remain unchanged for compatibility:
--   creator   = Freelancer (user-facing label)
--   moderator = Reseller  (user-facing label)
-- ============================================================

-- 1. Account state on the existing profile record.
alter table profiles add column if not exists account_status text;
update profiles set account_status = 'active' where account_status is null;
alter table profiles alter column account_status set default 'pending';
alter table profiles alter column account_status set not null;
alter table profiles drop constraint if exists profiles_account_status_check;
alter table profiles add constraint profiles_account_status_check
  check (account_status in ('pending', 'active', 'rejected', 'suspended'));

-- 2. Application record. The legacy role is assigned only after approval.
create table if not exists account_applications (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid unique references auth.users(id) on delete cascade,
  email text not null,
  display_name text not null,
  requested_role text not null check (requested_role in ('freelancer', 'reseller')),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'suspended')),
  review_note text,
  reviewed_by uuid references profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_account_applications_status_created
  on account_applications(status, created_at desc);
create index if not exists idx_account_applications_email
  on account_applications(lower(email));

alter table account_applications enable row level security;
drop policy if exists "application owner read" on account_applications;
create policy "application owner read"
on account_applications for select
using (user_id = auth.uid() or is_admin());

drop policy if exists "application admin update" on account_applications;
create policy "application admin update"
on account_applications for update
using (is_admin())
with check (is_admin());

-- 3. Admin-controlled switches. Default is manual approval.
insert into app_settings (key, value)
values
  ('default_withdrawal_fee_percent', '{"percent": 3.0}'::jsonb),
  ('default_max_payment_links', '{"count": 5}'::jsonb),
  ('auto_approve_freelancer', 'false'::jsonb),
  ('auto_approve_reseller', 'false'::jsonb)
on conflict (key) do nothing;

create or replace function cpay_auto_approval_enabled(p_role text)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(
    ((select value from app_settings where key =
      case when p_role = 'reseller' then 'auto_approve_reseller'
           else 'auto_approve_freelancer' end)::text)::boolean,
    false
  );
$$;
revoke all on function cpay_auto_approval_enabled(text) from public, anon;
grant execute on function cpay_auto_approval_enabled(text) to authenticated;

create or replace function account_is_active(p_user_id uuid default auth.uid())
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = p_user_id and account_status = 'active'
  );
$$;
revoke all on function account_is_active(uuid) from public, anon;
grant execute on function account_is_active(uuid) to authenticated;

-- 4. New-user trigger: create a pending profile and application.
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
begin
  select coalesce((value->>'percent')::numeric, 3.0)
    into v_default_fee
  from app_settings where key = 'default_withdrawal_fee_percent';
  select coalesce((value->>'count')::int, 5)
    into v_default_links
  from app_settings where key = 'default_max_payment_links';

  insert into public.profiles
    (id, email, display_name, role, account_status,
     withdrawal_fee_percent, max_payment_links)
  values
    (new.id, new.email, v_name, v_role, v_status,
     coalesce(v_default_fee, 3.0), coalesce(v_default_links, 5))
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

  return new;
end;
$$;

-- Re-attach the trigger to ensure new CPAY accounts use the gated flow.
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function handle_new_user();

-- 5. Pending accounts cannot create payment links through the definer RPC.
create or replace function guard_payment_link_account_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() and not account_is_active(new.user_id) then
    raise exception 'Account approval is required before creating payment links';
  end if;
  return new;
end;
$$;

drop trigger if exists payment_links_require_active_account on payment_links;
create trigger payment_links_require_active_account
before insert or update on payment_links
for each row execute function guard_payment_link_account_status();

-- Pending users must not request payouts. The system queue runs without a
-- user JWT and is intentionally allowed to continue using the shared server
-- side balance path.
create or replace function guard_withdrawal_account_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null
     and not is_admin()
     and new.user_id = auth.uid()
     and not account_is_active(new.user_id) then
    raise exception 'Account approval is required before requesting withdrawals';
  end if;
  return new;
end;
$$;

drop trigger if exists withdrawals_require_active_account on withdrawals;
create trigger withdrawals_require_active_account
before insert on withdrawals
for each row execute function guard_withdrawal_account_status();

-- 6. Admin application queue and review actions.
drop function if exists admin_list_account_applications(text);
create or replace function admin_list_account_applications(p_status text default 'pending')
returns table (
  id uuid, user_id uuid, email text, display_name text,
  requested_role text, status text, review_note text,
  created_at timestamptz, reviewed_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_status is not null and p_status not in ('pending', 'approved', 'rejected', 'suspended') then
    raise exception 'Invalid application status';
  end if;

  return query
  select a.id, a.user_id, a.email, a.display_name,
         a.requested_role, a.status, a.review_note,
         a.created_at, a.reviewed_at
  from account_applications a
  where p_status is null or a.status = p_status
  order by a.created_at desc;
end;
$$;
revoke all on function admin_list_account_applications(text) from public, anon;
grant execute on function admin_list_account_applications(text) to authenticated;

drop function if exists admin_review_account_application(uuid, text, text);
create or replace function admin_review_account_application(
  p_application_id uuid,
  p_decision text,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app account_applications;
  v_role text;
  v_status text;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_decision not in ('approved', 'rejected', 'suspended') then
    raise exception 'Invalid application decision';
  end if;

  select * into v_app from account_applications where id = p_application_id for update;
  if not found then raise exception 'Application not found'; end if;
  if v_app.user_id is null then raise exception 'Application has no user account'; end if;

  v_status := p_decision;
  v_role := case when v_app.requested_role = 'reseller' then 'moderator' else 'creator' end;

  update profiles
  set account_status = v_status,
      role = case when p_decision = 'approved' then v_role else 'creator' end
  where id = v_app.user_id;

  update account_applications
  set status = p_decision,
      review_note = nullif(trim(coalesce(p_note, '')), ''),
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      updated_at = now()
  where id = p_application_id;
end;
$$;
revoke all on function admin_review_account_application(uuid, text, text) from public, anon;
grant execute on function admin_review_account_application(uuid, text, text) to authenticated;

drop function if exists admin_set_auto_approval(text, boolean);
create or replace function admin_set_auto_approval(p_role text, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_role not in ('freelancer', 'reseller') then raise exception 'Invalid application role'; end if;
  v_key := case when p_role = 'reseller' then 'auto_approve_reseller' else 'auto_approve_freelancer' end;
  insert into app_settings(key, value)
  values (v_key, to_jsonb(coalesce(p_enabled, false)))
  on conflict (key) do update set value = excluded.value, updated_at = now();
end;
$$;
revoke all on function admin_set_auto_approval(text, boolean) from public, anon;
grant execute on function admin_set_auto_approval(text, boolean) to authenticated;

create or replace function get_my_account_state()
returns table (account_status text, requested_role text, review_note text)
language sql
security definer
stable
set search_path = public
as $$
  select p.account_status, a.requested_role, a.review_note
  from profiles p
  left join account_applications a on a.user_id = p.id
  where p.id = auth.uid();
$$;
revoke all on function get_my_account_state() from public, anon;
grant execute on function get_my_account_state() to authenticated;

commit;
