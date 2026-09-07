-- ============================================================
-- Boltpay — 0013: Customer directory, domain setting, live-payment fix
-- ============================================================
-- Fix: Drop functions before replace to avoid return type conflict
drop function if exists admin_live_payments();
drop function if exists admin_customer_directory();
-- Add lightning_invoice to live payments view (needed for full-copy fix)
create or replace function admin_live_payments()
returns table (
id uuid, btcpay_invoice_id text, lightning_invoice text,
amount_requested numeric, status text,
created_at timestamptz, expires_at timestamptz,
customer_city text, customer_country text,
creator_email text, creator_name text, link_slug text
)
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
return query
select p.id, p.btcpay_invoice_id, p.lightning_invoice, p.amount_requested, p.status,
p.created_at, p.expires_at, p.customer_city, p.customer_country,
pr.email, pr.display_name, pl.slug
from payments p
join profiles pr on pr.id = p.user_id
left join payment_links pl on pl.id = p.payment_link_id
where p.status in ('new', 'pending')
order by p.created_at desc;
end; $$;
revoke all on function admin_live_payments() from public;
grant execute on function admin_live_payments() to authenticated;
-- =========================================================
-- admin_customer_directory — numbered, ranked by earnings desc
-- =========================================================
create or replace function admin_customer_directory()
returns table (
rn bigint, id uuid, email text, display_name text,
total_earned numeric, total_withdrawn numeric,
payment_count bigint, link_count bigint
)
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
return query
select row_number() over (order by coalesce(te.total_earned,0) desc) as rn,
pr.id, pr.email, pr.display_name,
coalesce(te.total_earned,0), coalesce(tw.total_withdrawn,0),
coalesce(te.payment_count,0), coalesce(pl.link_count,0)
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
-- No domain is seeded here.
-- This key was never read by any page, function or worker — the domain
-- registry in site_domains (0015) replaced it — and seeding it meant a
-- real hostname sat in the repo for no benefit. Domains are added from
-- the admin panel's Domains tab.
