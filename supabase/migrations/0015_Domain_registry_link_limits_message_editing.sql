-- ============================================================
-- Boltpay — 0015: Domain registry, link limits, message editing
-- ============================================================
-- ---------- 1. Domain registry ----------
create table if not exists site_domains (
id uuid primary key default uuid_generate_v4(),
hostname text unique not null,
purpose text not null default 'payment' check (purpose in ('payment','site','both')),
is_active boolean default true,
is_primary_site boolean default false,
sort_order int default 0,
created_at timestamptz default now()
);
alter table site_domains enable row level security;
drop policy if exists "domains public read" on site_domains;
create policy "domains public read"
on site_domains for select
using (true);
drop policy if exists "domains admin write" on site_domains;
create policy "domains admin write"
on site_domains for all
using (is_admin());
-- No domain is seeded. Add yours from the admin panel's Domains tab
-- after running the migrations; nothing in the repo should carry a real
-- hostname, or it goes stale the moment a domain is renamed.
--
-- Until at least one row exists here the creator dashboard shows no
-- payment domains, which is the correct empty state rather than a
-- wrong one.
-- ---------- 2. Per-creator payment-link limit ----------
alter table profiles add column if not exists max_payment_links int default 5;
insert into app_settings (key, value) values
('default_max_payment_links', '{"count": 5}')
on conflict (key) do nothing;
-- Enforce the limit server-side so it cannot be bypassed from the browser
create or replace function enforce_link_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
v_limit int;
v_current int;
begin
select coalesce(max_payment_links, 5) into v_limit
from profiles where id = new.user_id;
select count(*) into v_current
from payment_links where user_id = new.user_id;
if v_current >= v_limit then
raise exception 'Link limit reached — you can create up to % payment links', v_limit;
end if;
return new;
end; $$;
drop trigger if exists trg_enforce_link_limit on payment_links;
create trigger trg_enforce_link_limit
before insert on payment_links
for each row execute function enforce_link_limit();
-- New signups inherit the current global default limit
create or replace function handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
v_default_fee numeric;
v_default_links int;
begin
select coalesce((value->>'percent')::numeric, 3.0) into v_default_fee
from app_settings where key = 'default_withdrawal_fee_percent';
select coalesce((value->>'count')::int, 5) into v_default_links
from app_settings where key = 'default_max_payment_links';
insert into public.profiles (id, email, display_name, withdrawal_fee_percent, max_payment_links)
values (
new.id, new.email,
coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
coalesce(v_default_fee, 3.0),
coalesce(v_default_links, 5)
)
on conflict (id) do nothing;
return new;
end; $$;
create or replace function admin_set_link_limit(p_creator_id uuid, p_limit int)
returns void
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
if p_limit < 0 or p_limit > 100 then
raise exception 'Limit must be between 0 and 100';
end if;
update profiles set max_payment_links = p_limit where id = p_creator_id;
end; $$;
revoke all on function admin_set_link_limit(uuid, int) from public;
grant execute on function admin_set_link_limit(uuid, int) to authenticated;
-- ---------- 3. Message edit / delete / clear ----------
drop policy if exists "mark read" on support_messages;
drop policy if exists "update own messages or mark read" on support_messages;
create policy "update own messages or mark read"
on support_messages for update
using (
is_admin()
or (user_id = auth.uid())
);
drop policy if exists "delete own messages" on support_messages;
create policy "delete own messages"
on support_messages for delete
using (
is_admin()
or (user_id = auth.uid() and sender = 'creator')
);
alter table support_messages add column if not exists edited_at timestamptz;
-- Clear an entire thread (admin only, or creator clearing their own)
create or replace function clear_message_thread(p_user_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() and auth.uid() <> p_user_id then
raise exception 'Not authorized';
end if;
delete from support_messages where user_id = p_user_id;
end; $$;
revoke all on function clear_message_thread(uuid) from public;
grant execute on function clear_message_thread(uuid) to authenticated;
-- ---------- 4. Admin views ----------
-- Fix: Drop function before replace to avoid return type conflict
drop function if exists admin_list_domains();
create or replace function admin_list_domains()
returns table (
id uuid, hostname text, purpose text,
is_active boolean, is_primary_site boolean, sort_order int
)
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
return query
select d.id, d.hostname, d.purpose, d.is_active, d.is_primary_site, d.sort_order
from site_domains d order by d.sort_order, d.hostname;
end; $$;
revoke all on function admin_list_domains() from public;
grant execute on function admin_list_domains() to authenticated;
-- Customer directory now also reports each creator's link limit
drop function if exists admin_customer_directory();
create or replace function admin_customer_directory()
returns table (
rn bigint, id uuid, email text, display_name text,
total_earned numeric, total_withdrawn numeric,
payment_count bigint, link_count bigint, max_links int
)
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
return query
select row_number() over (order by coalesce(te.total_earned,0) desc) as rn,
pr.id, pr.email, pr.display_name,
coalesce(te.total_earned,0), coalesce(tw.total_withdrawn,0),
coalesce(te.payment_count,0), coalesce(pl.link_count,0),
coalesce(pr.max_payment_links, 5)
from profiles pr
left join (
select user_id, sum(amount_settled) as total_earned, count(*) as payment_count
from payments where status = 'settled' group by user_id
) te on te.user_id = pr.id
left join (
select user_id, sum(amount_after_fee) as total_withdrawn
from withdrawals where status = 'paid' group by user_id
) tw on tw.user_id = pr.id
left join (
select user_id, count(*) as link_count from payment_links group by user_id
) pl on pl.user_id = pr.id
where pr.role = 'creator'
order by rn;
end; $$;
revoke all on function admin_customer_directory() from public;
grant execute on function admin_customer_directory() to authenticated;
