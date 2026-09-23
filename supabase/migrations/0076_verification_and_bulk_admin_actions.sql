-- ============================================================
-- CPAY — 0076: verification state and bulk-safe admin actions
-- ============================================================

alter table profiles add column if not exists verification_status text not null default 'unverified';
alter table profiles drop constraint if exists profiles_verification_status_check;
alter table profiles add constraint profiles_verification_status_check
  check (verification_status in ('unverified','pending','verified','rejected'));
alter table profiles add column if not exists verification_note text;
alter table profiles add column if not exists verified_at timestamptz;
alter table profiles add column if not exists verified_by uuid references profiles(id);

create or replace function admin_set_profile_verification(p_user_id uuid, p_status text, p_note text default null)
returns profiles language plpgsql security definer set search_path = public as $$
declare v_old text; v_row profiles;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_status not in ('unverified','pending','verified','rejected') then raise exception 'Invalid verification status'; end if;
  select verification_status into v_old from profiles where id=p_user_id for update;
  if not found then raise exception 'Profile not found'; end if;
  update profiles set verification_status=p_status, verification_note=nullif(trim(p_note),''),
    verified_at=case when p_status='verified' then now() else null end,
    verified_by=case when p_status='verified' then auth.uid() else null end
  where id=p_user_id returning * into v_row;
  perform record_audit('profile.verification_changed','profile',p_user_id::text,
    jsonb_build_object('status',v_old),jsonb_build_object('status',p_status),p_note);
  return v_row;
end; $$;
revoke all on function admin_set_profile_verification(uuid,text,text) from public, anon;
grant execute on function admin_set_profile_verification(uuid,text,text) to authenticated;

create or replace function admin_bulk_set_account_status(p_user_ids uuid[], p_status text)
returns integer language plpgsql security definer set search_path = public as $$
declare v_count integer;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_status not in ('active','pending','rejected','suspended') then raise exception 'Invalid account status'; end if;
  if p_user_ids is null or cardinality(p_user_ids)=0 then return 0; end if;
  if auth.uid() = any(p_user_ids) then raise exception 'Bulk actions cannot change your own access'; end if;
  if p_status <> 'active' and exists (select 1 from profiles where id=any(p_user_ids) and role='admin' and account_status='active') then
    raise exception 'Bulk action cannot suspend or reject an active admin';
  end if;
  update profiles set account_status=p_status where id=any(p_user_ids) and role <> 'admin';
  get diagnostics v_count = row_count;
  perform record_audit('profile.bulk_account_status_changed','profiles',array_to_string(p_user_ids,','),
    null,jsonb_build_object('account_status',p_status,'affected_count',v_count));
  return v_count;
end; $$;
revoke all on function admin_bulk_set_account_status(uuid[],text) from public, anon;
grant execute on function admin_bulk_set_account_status(uuid[],text) to authenticated;
