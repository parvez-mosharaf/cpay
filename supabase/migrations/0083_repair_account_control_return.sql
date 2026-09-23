-- CPAY: repair an already-applied 0071 migration whose older copy used
-- RETURN QUERY in a function declared to return one composite profile row.
-- This is safe for existing databases and keeps fresh preview databases
-- correct when they replay the complete migration history.

create or replace function public.admin_update_account_control(
  p_user_id uuid,
  p_role text,
  p_account_status text,
  p_review_note text default null
)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_role text;
  v_old_status text;
  v_admins int;
  v_row public.profiles;
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'You cannot change your own admin access';
  end if;

  if p_role not in ('creator', 'moderator', 'admin') then
    raise exception 'Invalid role';
  end if;

  if p_account_status not in ('pending', 'active', 'rejected', 'suspended') then
    raise exception 'Invalid account status';
  end if;

  select role, account_status
    into v_old_role, v_old_status
    from public.profiles
   where id = p_user_id
   for update;

  if not found then
    raise exception 'Profile not found';
  end if;

  if v_old_role = 'admin'
     and (p_role <> 'admin' or p_account_status <> 'active') then
    select count(*)
      into v_admins
      from public.profiles
     where role = 'admin'
       and account_status = 'active';

    if v_admins <= 1 then
      raise exception 'The last active admin cannot be removed';
    end if;
  end if;

  update public.profiles
     set role = p_role,
         account_status = p_account_status
   where id = p_user_id
   returning * into v_row;

  update public.account_applications
     set status = case
                    when p_account_status = 'active' then 'approved'
                    else p_account_status
                  end,
         review_note = nullif(trim(p_review_note), ''),
         reviewed_by = auth.uid(),
         reviewed_at = now(),
         updated_at = now()
   where user_id = p_user_id;

  perform public.record_audit(
    'profile.account_control_changed',
    'profile',
    p_user_id::text,
    jsonb_build_object(
      'role', v_old_role,
      'account_status', v_old_status
    ),
    jsonb_build_object(
      'role', p_role,
      'account_status', p_account_status
    ),
    p_review_note
  );

  return v_row;
end;
$$;

revoke all on function public.admin_update_account_control(uuid, text, text, text)
  from public, anon;

grant execute on function public.admin_update_account_control(uuid, text, text, text)
  to authenticated;
