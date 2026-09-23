-- CPAY — 0085: read-only payment screenshot verification lookup
-- A screenshot never proves payment. This function only returns ledger matches.
create or replace function public.telegram_find_payments(
  p_reference text default null,
  p_amount numeric default null
)
returns jsonb
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(jsonb_agg(row order by settled_at desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'creator', coalesce(nullif(trim(pr.display_name), ''), 'Unnamed creator'),
      'amountRequested', p.amount_requested,
      'amountSettled', p.amount_settled,
      'status', p.status,
      'method', p.method,
      'settledAt', p.settled_at,
      'invoiceId', p.btcpay_invoice_id
    ) as row, p.settled_at
    from payments p
    join profiles pr on pr.id = p.user_id
    where (
      nullif(trim(coalesce(p_reference, '')), '') is not null
      and (p.btcpay_invoice_id ilike '%' || trim(p_reference) || '%'
        or p.lightning_invoice ilike '%' || trim(p_reference) || '%')
    )
    or (
      p_amount is not null
      and abs(coalesce(p.amount_settled, p.amount_requested) - p_amount) < 0.000001
    )
    order by p.settled_at desc nulls last
    limit 10
  ) x;
$$;
revoke all on function public.telegram_find_payments(text, numeric) from public, anon, authenticated;
grant execute on function public.telegram_find_payments(text, numeric) to service_role;
