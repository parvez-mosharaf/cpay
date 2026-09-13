-- ============================================================
-- Boltpay — 0047: Audit log of privileged actions
-- ============================================================
-- Nothing in this system records who changed what.
--
-- An admin can change a creator's fee, raise their link limit, grant a
-- moderator access to customers, mark a payment settled (which creates
-- balance), or approve a payout. Today all of those leave the same
-- trace: the new value, and no history. If a fee is wrong, or a payment
-- was settled that should not have been, there is no way to answer
-- "when did this change, and who did it" — not for a dispute, not for a
-- mistake, and not if an admin account is ever compromised.
--
-- This is the table that answers it. Deliberately narrow:
--
--   * append-only. No UPDATE or DELETE policy exists for anyone, so a
--     row cannot be edited or removed through the API — including by an
--     admin. A log that the suspect can edit is not a log.
--   * written by SECURITY DEFINER functions, not by the client, so the
--     actor is auth.uid() as the database sees it rather than whatever
--     the browser claims.
--   * records the old value alongside the new one. "Fee set to 8%" is
--     much less useful than "fee changed from 3% to 8%".
-- ============================================================

create table if not exists audit_log (
  id           bigserial primary key,
  occurred_at  timestamptz not null default now(),
  actor_id     uuid references profiles(id),
  actor_email  text,
  action       text not null,
  subject_type text,
  subject_id   text,
  old_value    jsonb,
  new_value    jsonb,
  note         text
);

create index if not exists idx_audit_occurred on audit_log(occurred_at desc);
create index if not exists idx_audit_actor    on audit_log(actor_id, occurred_at desc);
create index if not exists idx_audit_subject  on audit_log(subject_type, subject_id, occurred_at desc);

alter table audit_log enable row level security;

-- Read: admins only. Moderators are among the people this log exists to
-- keep honest, so they do not get to read it.
drop policy if exists "audit admin read" on audit_log;
create policy "audit admin read"
on audit_log for select
using (is_admin());

-- No insert, update or delete policy on purpose. With RLS on and no
-- policy, every role except the service role is refused. Writes go
-- through record_audit() below, which is SECURITY DEFINER.


-- ============================================================
-- The writer
-- ------------------------------------------------------------
-- Never raises. An audit write failing must not roll back the action it
-- was recording — losing a log line is bad, but failing a payout because
-- the log was full is worse.
-- ============================================================
create or replace function record_audit(
  p_action text,
  p_subject_type text default null,
  p_subject_id text default null,
  p_old jsonb default null,
  p_new jsonb default null,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_email text;
begin
  select email into v_email from profiles where id = auth.uid();

  insert into audit_log (actor_id, actor_email, action, subject_type, subject_id, old_value, new_value, note)
  values (auth.uid(), v_email, p_action, p_subject_type, p_subject_id, p_old, p_new, p_note);
exception when others then
  -- Log the failure to the Postgres log and carry on.
  raise warning 'audit write failed for action %: %', p_action, sqlerrm;
end;
$$;

revoke all on function record_audit(text, text, text, jsonb, jsonb, text) from public, anon;
grant execute on function record_audit(text, text, text, jsonb, jsonb, text) to authenticated;


-- ============================================================
-- Wire it into the actions that matter
-- ------------------------------------------------------------
-- Only the ones that move money or change who can do what. Logging
-- every read would bury the handful of lines anyone will ever need.
-- ============================================================

-- Fee changes: directly changes what a creator is paid.
create or replace function admin_update_creator_fee(p_creator_id uuid, p_fee_percent numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_old numeric;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_fee_percent < 0 or p_fee_percent > 50 then
    raise exception 'Fee must be between 0 and 50';
  end if;

  select withdrawal_fee_percent into v_old from profiles where id = p_creator_id;
  update profiles set withdrawal_fee_percent = p_fee_percent where id = p_creator_id;

  perform record_audit(
    'creator.fee_changed', 'profile', p_creator_id::text,
    jsonb_build_object('withdrawal_fee_percent', v_old),
    jsonb_build_object('withdrawal_fee_percent', p_fee_percent)
  );
end; $$;

revoke all on function admin_update_creator_fee(uuid, numeric) from public, anon;
grant execute on function admin_update_creator_fee(uuid, numeric) to authenticated;


-- Role changes: changes who can do all of this.
create or replace function admin_set_role(p_user_id uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare v_admin_count int; v_old text;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_role not in ('creator', 'admin', 'moderator') then
    raise exception 'Unknown role';
  end if;

  if p_role <> 'admin' then
    select count(*) into v_admin_count from profiles
     where role = 'admin' and id <> p_user_id;
    if v_admin_count = 0 then
      raise exception 'This is the only admin account — promote someone else first';
    end if;
  end if;

  select role into v_old from profiles where id = p_user_id;
  update profiles set role = p_role where id = p_user_id;

  if p_role <> 'moderator' then
    delete from moderator_assignments where moderator_id = p_user_id;
  end if;

  perform record_audit(
    'staff.role_changed', 'profile', p_user_id::text,
    jsonb_build_object('role', v_old),
    jsonb_build_object('role', p_role)
  );
end; $$;

revoke all on function admin_set_role(uuid, text) from public, anon;
grant execute on function admin_set_role(uuid, text) to authenticated;


-- Assigning creators to a moderator: changes whose money someone can see.
create or replace function admin_assign_creator(
  p_moderator_id uuid, p_creator_id uuid, p_assigned boolean
)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  if not exists (select 1 from profiles where id = p_moderator_id and role = 'moderator') then
    raise exception 'That account is not a moderator';
  end if;
  if not exists (select 1 from profiles where id = p_creator_id and role = 'creator') then
    raise exception 'That account is not a creator';
  end if;

  if p_assigned then
    insert into moderator_assignments (moderator_id, creator_id)
    values (p_moderator_id, p_creator_id)
    on conflict do nothing;
  else
    delete from moderator_assignments
     where moderator_id = p_moderator_id and creator_id = p_creator_id;
  end if;

  perform record_audit(
    case when p_assigned then 'staff.creator_assigned' else 'staff.creator_unassigned' end,
    'profile', p_moderator_id::text,
    null,
    jsonb_build_object('creator_id', p_creator_id)
  );
end; $$;

revoke all on function admin_assign_creator(uuid, uuid, boolean) from public, anon;
grant execute on function admin_assign_creator(uuid, uuid, boolean) to authenticated;


-- Instant-payout access: the per-creator half of the money switch.
create or replace function admin_toggle_creator_auto(p_creator_id uuid, p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_old boolean;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  select auto_withdraw_enabled into v_old from profiles where id = p_creator_id;
  update profiles set auto_withdraw_enabled = coalesce(p_enabled, false)
   where id = p_creator_id;

  perform record_audit(
    'creator.instant_payout_toggled', 'profile', p_creator_id::text,
    jsonb_build_object('auto_withdraw_enabled', v_old),
    jsonb_build_object('auto_withdraw_enabled', coalesce(p_enabled, false))
  );
end; $$;

revoke all on function admin_toggle_creator_auto(uuid, boolean) from public, anon;
grant execute on function admin_toggle_creator_auto(uuid, boolean) to authenticated;


-- ============================================================
-- Reading the log
-- ============================================================
create or replace function admin_audit_log(
  p_limit int default 100,
  p_offset int default 0,
  p_action text default null
)
returns table (
  id bigint, occurred_at timestamptz, actor_email text, action text,
  subject_type text, subject_id text, old_value jsonb, new_value jsonb,
  note text, total_count bigint
)
language plpgsql security definer stable set search_path = public as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_action text := nullif(trim(coalesce(p_action, '')), '');
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  return query
  with filtered as (
    select a.* from audit_log a
    where v_action is null or a.action = v_action
  )
  select f.id, f.occurred_at, f.actor_email, f.action,
         f.subject_type, f.subject_id, f.old_value, f.new_value, f.note,
         count(*) over ()
  from filtered f
  order by f.occurred_at desc
  limit v_limit offset v_offset;
end; $$;

revoke all on function admin_audit_log(int, int, text) from public, anon;
grant execute on function admin_audit_log(int, int, text) to authenticated;
