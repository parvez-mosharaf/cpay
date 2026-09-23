-- ============================================================
-- CPAY — 0008: Admin management tools
-- ============================================================
create or replace function admin_list_payment_links()
returns table (
id uuid, slug text, display_name text, is_active boolean, created_at timestamptz,
owner_email text, owner_name text, total_earned numeric, payment_count bigint
)
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
return query
select pl.id, pl.slug, pl.display_name, pl.is_active, pl.created_at,
pr.email, pr.display_name,
coalesce((select sum(p.amount_settled) from payments p where p.payment_link_id = pl.id and p.status = 'settled'), 0),
coalesce((select count(*) from payments p where p.payment_link_id = pl.id and p.status = 'settled'), 0)
from payment_links pl
join profiles pr on pr.id = pl.user_id
order by pl.created_at desc;
end; $$;
revoke all on function admin_list_payment_links() from public;
grant execute on function admin_list_payment_links() to authenticated;
create or replace function admin_toggle_link(p_link_id uuid, p_is_active boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
update payment_links set is_active = p_is_active where id = p_link_id;
end; $$;
revoke all on function admin_toggle_link(uuid, boolean) from public;
grant execute on function admin_toggle_link(uuid, boolean) to authenticated;
create or replace function admin_list_payments(p_limit int default 100)
returns table (
id uuid, amount_requested numeric, amount_settled numeric, status text, method text,
created_at timestamptz, settled_at timestamptz,
creator_email text, creator_name text, link_slug text
)
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
return query
select p.id, p.amount_requested, p.amount_settled, p.status, p.method,
p.created_at, p.settled_at, pr.email, pr.display_name, pl.slug
from payments p
join profiles pr on pr.id = p.user_id
left join payment_links pl on pl.id = p.payment_link_id
order by p.created_at desc
limit p_limit;
end; $$;
revoke all on function admin_list_payments(int) from public;
grant execute on function admin_list_payments(int) to authenticated;
create or replace function admin_mark_payment(p_payment_id uuid, p_status text, p_amount_settled numeric default null)
returns void language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
if p_status not in ('settled', 'expired', 'invalid') then
raise exception 'Invalid status';
end if;
if p_status = 'settled' then
update payments set status = 'settled', settled_at = now(),
amount_settled = coalesce(p_amount_settled, amount_requested)
where id = p_payment_id;
else
update payments set status = p_status where id = p_payment_id;
end if;
end; $$;
revoke all on function admin_mark_payment(uuid, text, numeric) from public;
grant execute on function admin_mark_payment(uuid, text, numeric) to authenticated;
insert into app_settings (key, value) values ('auto_withdraw_enabled', 'true')
on conflict (key) do nothing;
