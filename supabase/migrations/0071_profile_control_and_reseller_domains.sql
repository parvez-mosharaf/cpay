-- ============================================================
-- CPAY — 0071: profile control center and Reseller domains
-- ============================================================

alter table site_domains add column if not exists owner_id uuid references profiles(id) on delete set null;
create index if not exists idx_site_domains_owner_active on site_domains(owner_id, is_active, sort_order);

create or replace function cpay_validate_domain_owner()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.owner_id is not null and not exists (
    select 1 from profiles where id = new.owner_id and role = 'moderator' and account_status = 'active'
  ) then
    raise exception 'A domain can only be assigned to an active Reseller account';
  end if;
  return new;
end; $$;
drop trigger if exists trg_validate_domain_owner on site_domains;
create trigger trg_validate_domain_owner before insert or update of owner_id on site_domains
for each row execute function cpay_validate_domain_owner();

create or replace function admin_set_domain_owner(p_domain_id uuid, p_owner_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_old uuid;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  select owner_id into v_old from site_domains where id = p_domain_id for update;
  if not found then raise exception 'Domain not found'; end if;
  if p_owner_id is not null and not exists (
    select 1 from profiles where id = p_owner_id and role = 'moderator' and account_status = 'active'
  ) then raise exception 'Select an active Reseller or Global domain'; end if;
  update site_domains set owner_id = p_owner_id where id = p_domain_id;
  perform record_audit('domain.owner_changed','site_domain',p_domain_id::text,
    jsonb_build_object('owner_id',v_old), jsonb_build_object('owner_id',p_owner_id));
end; $$;
revoke all on function admin_set_domain_owner(uuid, uuid) from public, anon;
grant execute on function admin_set_domain_owner(uuid, uuid) to authenticated;

create or replace function admin_list_resellers()
returns table(id uuid, email text, display_name text, account_status text)
language sql security definer stable set search_path = public as $$
  select p.id, p.email, p.display_name, p.account_status
  from profiles p where is_admin() and p.role = 'moderator'
  order by coalesce(p.display_name,p.email), p.email;
$$;
revoke all on function admin_list_resellers() from public, anon;
grant execute on function admin_list_resellers() to authenticated;

create or replace function admin_update_account_control(
  p_user_id uuid, p_role text, p_account_status text, p_review_note text default null
)
returns profiles language plpgsql security definer set search_path = public as $$
declare v_old_role text; v_old_status text; v_admins int; v_row profiles;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_user_id = auth.uid() then raise exception 'You cannot change your own admin access'; end if;
  if p_role not in ('creator','moderator','admin') then raise exception 'Invalid role'; end if;
  if p_account_status not in ('pending','active','rejected','suspended') then raise exception 'Invalid account status'; end if;
  select role, account_status into v_old_role, v_old_status from profiles where id = p_user_id for update;
  if not found then raise exception 'Profile not found'; end if;
  if v_old_role = 'admin' and (p_role <> 'admin' or p_account_status <> 'active') then
    select count(*) into v_admins from profiles where role='admin' and account_status='active';
    if v_admins <= 1 then raise exception 'The last active admin cannot be removed'; end if;
  end if;
  update profiles set role=p_role, account_status=p_account_status
  where id=p_user_id
  returning * into v_row;
  update account_applications set status=case when p_account_status='active' then 'approved' else p_account_status end,
    review_note=nullif(trim(p_review_note),''), reviewed_by=auth.uid(), reviewed_at=now(), updated_at=now()
  where user_id=p_user_id;
  perform record_audit('profile.account_control_changed','profile',p_user_id::text,
    jsonb_build_object('role',v_old_role,'account_status',v_old_status),
    jsonb_build_object('role',p_role,'account_status',p_account_status),p_review_note);
  return v_row;
end; $$;
revoke all on function admin_update_account_control(uuid,text,text,text) from public, anon;
grant execute on function admin_update_account_control(uuid,text,text,text) to authenticated;

drop function if exists admin_list_domains();
create or replace function admin_list_domains()
returns table(id uuid, hostname text, purpose text, theme text, is_active boolean, is_primary_site boolean,
  sort_order int, owner_id uuid, owner_email text, owner_name text)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query select d.id,d.hostname,d.purpose,d.theme,d.is_active,d.is_primary_site,d.sort_order,
    d.owner_id,p.email,p.display_name
  from site_domains d left join profiles p on p.id=d.owner_id order by d.sort_order,d.hostname;
end; $$;
revoke all on function admin_list_domains() from public, anon;
grant execute on function admin_list_domains() to authenticated;
