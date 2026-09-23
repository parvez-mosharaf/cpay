-- ============================================================
-- CPAY — 0012: Admin ↔ Creator messaging
-- ============================================================
create table if not exists support_messages (
id uuid primary key default uuid_generate_v4(),
user_id uuid not null references profiles(id) on delete cascade,
sender text not null check (sender in ('admin', 'creator')),
message text not null,
created_at timestamptz default now(),
read_by_admin boolean default false,
read_by_creator boolean default false
);
create index if not exists idx_messages_user on support_messages(user_id);
alter table support_messages enable row level security;
-- Fix: Drop policies before creating them to avoid conflicts
drop policy if exists "own thread select" on support_messages;
create policy "own thread select"
on support_messages for select
using (user_id = auth.uid() or is_admin());
drop policy if exists "send in own thread" on support_messages;
create policy "send in own thread"
on support_messages for insert
with check (
(sender = 'creator' and user_id = auth.uid())
or (sender = 'admin' and is_admin())
);
drop policy if exists "mark read" on support_messages;
create policy "mark read"
on support_messages for update
using (user_id = auth.uid() or is_admin());
-- Admin needs a list of creators to message
create or replace function admin_list_creators()
returns table (id uuid, email text, display_name text, unread_count bigint)
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
return query
select pr.id, pr.email, pr.display_name,
coalesce((select count(*) from support_messages sm where sm.user_id = pr.id and sm.sender = 'creator' and sm.read_by_admin = false), 0)
from profiles pr
where pr.role = 'creator'
order by pr.display_name nulls last, pr.email;
end; $$;
revoke all on function admin_list_creators() from public;
grant execute on function admin_list_creators() to authenticated;
