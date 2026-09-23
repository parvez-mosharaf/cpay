-- ============================================================
-- CPAY — 0010: Store full Lightning address + searchable ledger
-- ============================================================
alter table payments add column if not exists lightning_invoice text;
create index if not exists idx_payments_lightning_invoice on payments(lightning_invoice);
-- Replace admin_list_payments with a searchable version
drop function if exists admin_list_payments(int);
create or replace function admin_list_payments(p_limit int default 100, p_search text default null)
returns table (
id uuid,
amount_requested numeric,
amount_settled numeric,
status text,
method text,
created_at timestamptz,
settled_at timestamptz,
creator_email text,
creator_name text,
link_slug text,
btcpay_invoice_id text,
lightning_invoice text
)
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
return query
select p.id, p.amount_requested, p.amount_settled, p.status, p.method,
p.created_at, p.settled_at, pr.email, pr.display_name, pl.slug,
p.btcpay_invoice_id, p.lightning_invoice
from payments p
join profiles pr on pr.id = p.user_id
left join payment_links pl on pl.id = p.payment_link_id
where
p_search is null or p_search = ''
or p.btcpay_invoice_id ilike '%' || p_search || '%'
or p.lightning_invoice ilike '%' || p_search || '%'
or pr.email ilike '%' || p_search || '%'
or pl.slug ilike '%' || p_search || '%'
order by p.created_at desc
limit p_limit;
end; $$;
revoke all on function admin_list_payments(int, text) from public;
grant execute on function admin_list_payments(int, text) to authenticated;
