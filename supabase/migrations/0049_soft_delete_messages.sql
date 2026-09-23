-- ============================================================
-- CPAY — 0049: Support messages are never really deleted
-- ============================================================
-- The thread already had a soft delete: "Clear history" sets
-- deleted_by_creator, which hides the messages from the creator while
-- the admin still sees them marked "[Deleted by user]". That is the
-- right behaviour for a payments platform — a support conversation is
-- often the only record of what was agreed about someone's money.
--
-- But deleting a SINGLE message did a hard DELETE, from both panels.
-- So the careful design was one button away from being bypassed, and
-- either side could remove a specific inconvenient line permanently.
--
-- This makes the single-message delete behave like the bulk one: the
-- row stays, it is hidden from whoever removed it, and the other side
-- can still see that something was there.
--
-- Deleting is also recorded in audit_log, because "the message that
-- proved X is gone" is exactly the kind of thing worth being able to
-- reconstruct later.
-- ============================================================

alter table support_messages add column if not exists deleted_by_admin boolean not null default false;

create index if not exists idx_messages_not_deleted
  on support_messages(user_id, created_at)
  where deleted_by_creator = false and deleted_by_admin = false;


-- ============================================================
-- Hide a message from the caller's own view
-- ------------------------------------------------------------
-- Each side can only hide it from themselves. A creator cannot make a
-- message vanish from the admin's view, and an admin cannot make one
-- vanish from the creator's — otherwise "delete" becomes a way to
-- rewrite what the other person saw.
-- ============================================================
create or replace function hide_message(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_owner uuid;
  v_sender text;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select user_id, sender into v_owner, v_sender
  from support_messages where id = p_message_id;
  if not found then raise exception 'Message not found'; end if;

  if is_admin() then
    update support_messages set deleted_by_admin = true where id = p_message_id;
    perform record_audit(
      'message.hidden_by_admin', 'support_message', p_message_id::text,
      null, jsonb_build_object('thread_user_id', v_owner, 'sender', v_sender)
    );
  elsif v_owner = v_uid then
    update support_messages set deleted_by_creator = true where id = p_message_id;
  else
    raise exception 'Not authorized';
  end if;
end;
$$;

revoke all on function hide_message(uuid) from public, anon;
grant execute on function hide_message(uuid) to authenticated;


-- ============================================================
-- Close the hard-delete route
-- ------------------------------------------------------------
-- The panels now call hide_message(), but the DELETE policy that let
-- them do it directly is still there. Removing it means the soft delete
-- is the only route, rather than merely the one the current UI happens
-- to use.
--
-- Nothing legitimate needs to remove a support message outright. The
-- service role still can, for a genuine erasure request.
-- ============================================================
-- The real policy name, from 0015. Getting this wrong would have left
-- the hard-delete route wide open while looking like it was closed.
drop policy if exists "delete own messages" on support_messages;


-- ============================================================
-- Reading a thread
-- ------------------------------------------------------------
-- One function for both panels, so the two can never disagree about
-- what is visible. Each caller sees everything except what they
-- themselves hid; the other side's hidden messages come back flagged
-- so the UI can show them greyed rather than pretending they were
-- never sent.
-- ============================================================
create or replace function get_message_thread(p_user_id uuid, p_limit int default 300)
returns table (
  id uuid,
  sender text,
  message text,
  created_at timestamptz,
  edited_at timestamptz,
  read_by_admin boolean,
  read_by_creator boolean,
  hidden_by_other boolean
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_is_admin boolean := is_admin();
  v_limit int := least(greatest(coalesce(p_limit, 300), 1), 1000);
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not v_is_admin and p_user_id <> v_uid then
    raise exception 'Not authorized';
  end if;

  return query
  select * from (
    select
      m.id, m.sender, m.message, m.created_at, m.edited_at,
      m.read_by_admin, m.read_by_creator,
      case when v_is_admin then m.deleted_by_creator else m.deleted_by_admin end
    from support_messages m
    where m.user_id = p_user_id
      -- Hide only what the CALLER hid. Ordered newest-first and capped,
      -- then flipped back below: sorting ascending with a limit would
      -- have kept the oldest messages and dropped the recent ones.
      and (case when v_is_admin then m.deleted_by_admin else m.deleted_by_creator end) = false
    order by m.created_at desc
    limit v_limit
  ) recent
  order by recent.created_at asc;
end;
$$;

revoke all on function get_message_thread(uuid, int) from public, anon;
grant execute on function get_message_thread(uuid, int) to authenticated;
