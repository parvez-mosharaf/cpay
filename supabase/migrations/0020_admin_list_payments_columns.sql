-- ============================================================
-- Boltpay — 0020: admin_list_payments missing columns
-- ============================================================
-- The admin Transactions tab renders a countdown and a location for
-- every live payment:
--
--   data-expires="${escapeAttr(p.expires_at)}"
--   [p.customer_city, p.customer_country].filter(Boolean)...
--
-- But admin_list_payments() never returned those three columns. So
-- `p.expires_at` was undefined, `new Date(undefined)` is an Invalid
-- Date, and the timer rendered as NaN:NaN. The location line had the
-- same cause and silently showed "Unknown location" on every row,
-- even for payments that do have geo data stored.
--
-- The creator dashboard was never affected: it reads the payments
-- table directly with select('*'), so it gets all three.
--
-- admin_live_payments() already returned them; only the searchable
-- ledger function was missing them.
-- ============================================================

drop function if exists admin_list_payments(int, text);

create or replace function admin_list_payments(
  p_limit int default 100,
  p_search text default null
)
returns table (
  id uuid,
  amount_requested numeric,
  amount_settled numeric,
  status text,
  method text,
  created_at timestamptz,
  settled_at timestamptz,
  expires_at timestamptz,
  customer_city text,
  customer_country text,
  creator_email text,
  creator_name text,
  link_slug text,
  btcpay_invoice_id text,
  lightning_invoice text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  return query
  select p.id, p.amount_requested, p.amount_settled, p.status, p.method,
    p.created_at, p.settled_at, p.expires_at,
    p.customer_city, p.customer_country,
    pr.email, pr.display_name, pl.slug,
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
end;
$$;

revoke all on function admin_list_payments(int, text) from public, anon;
grant execute on function admin_list_payments(int, text) to authenticated;


-- ============================================================
-- Dead helper: slug_exists()
-- ------------------------------------------------------------
-- Its body is `select exists(select 1 from models where slug = ...)`.
-- There is no `models` table — payment links live in payment_links.
-- This is a leftover from when they were called "models" (the UI
-- still uses that word). Calling it raises
-- "relation \"models\" does not exist", so nothing can be relying on
-- it. Uniqueness is already enforced by payment_links.slug's UNIQUE
-- constraint, and the format/reserved-name rules by
-- validate_link_slug().
--
-- Left commented out rather than dropped, in case something outside
-- this repo references it. Uncomment once you have checked.
-- ============================================================
-- drop function if exists slug_exists(text);


-- ============================================================
-- Keep: rls_auto_enable()
-- ------------------------------------------------------------
-- This is a Supabase-managed event trigger, not something that
-- slipped in. It fires on CREATE TABLE in the public schema and runs
-- `alter table ... enable row level security`, so any table added
-- later starts locked down instead of world-readable. It only ever
-- enables RLS, never disables it, and it swallows its own errors.
-- Nothing to do here.
-- ============================================================
