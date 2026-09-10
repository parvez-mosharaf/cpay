-- ============================================================
-- Boltpay — 0009: Live payments location + admin views
-- ============================================================
alter table payments add column if not exists customer_city text;
alter table payments add column if not exists customer_country text;
-- =========================================================
-- admin_live_payments — all pending/new payments across every creator,
-- for the real-time "Live Payments" admin view.
-- =========================================================
create or replace function admin_live_payments()
returns table (
id uuid,
btcpay_invoice_id text,
amount_requested numeric,
status text,
created_at timestamptz,
expires_at timestamptz,
customer_city text,
customer_country text,
creator_email text,
creator_name text,
link_slug text
)
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
return query
select p.id, p.btcpay_invoice_id, p.amount_requested, p.status,
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
