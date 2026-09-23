-- CPAY 0089: bound anonymous historical invoice lookup
-- Active invoices remain public; expired/settled receipts remain discoverable for 90 days.
create or replace function public.get_invoice_public(p_payment_id uuid)
returns table (id uuid, amount_requested numeric, amount_settled numeric, method text, status text, expires_at timestamptz, merchant_name text, link_slug text, lightning_invoice text)
language sql security definer stable set search_path=public as $$
  select p.id,p.amount_requested,p.amount_settled,p.method,p.status,p.expires_at,
         pr.display_name as merchant_name,pl.slug as link_slug,p.lightning_invoice
  from public.payments p
  left join public.payment_links pl on pl.id=p.payment_link_id
  left join public.profiles pr on pr.id=p.user_id
  where p.id=p_payment_id
    and (p.expires_at >= now() or p.expires_at >= now() - interval '90 days');
$$;
revoke all on function public.get_invoice_public(uuid) from public;
grant execute on function public.get_invoice_public(uuid) to anon, authenticated;
