-- ============================================================
-- Boltpay — 0021: Per-link preview images, resumable invoices
-- ============================================================

-- ============================================================
-- 1. payment_links.og_image
-- ------------------------------------------------------------
-- The worker guesses the preview image by firing a HEAD request at
-- assets/og/<slug>.png and falling back to og-default.png. That
-- still works and is still the fallback. This column lets a link
-- name an image explicitly, which is what an auto-generated preview
-- needs: the generator writes the filename here and the worker stops
-- guessing.
-- ============================================================
alter table payment_links add column if not exists og_image text;

-- Bare filename only. The worker interpolates this into a URL, so it
-- must not be able to escape /assets/og/.
alter table payment_links drop constraint if exists payment_links_og_image_check;
alter table payment_links add constraint payment_links_og_image_check
  check (og_image is null or og_image ~ '^[a-zA-Z0-9._-]{1,80}\.(png|jpg|jpeg|webp)$')
  not valid;


-- ============================================================
-- 2. get_link_preview also returns the image
-- ============================================================
-- `create or replace` cannot change a function's return type: adding a
-- column to a `returns table (...)` is a different row type, and Postgres
-- rejects it with 42P13. The old definition has to go first.
--
-- Dropping also drops its grants, which is why the grant statements below
-- are repeated rather than assumed. In the Supabase SQL editor the whole
-- script runs in one transaction, so there is no window where the payment
-- page finds the function missing.
drop function if exists get_link_preview(text);

create or replace function get_link_preview(p_slug text)
returns table (display_name text, is_active boolean, og_image text)
language sql
security definer
stable
set search_path = public
as $$
  select pl.display_name, pl.is_active, pl.og_image
  from payment_links pl
  where pl.slug = p_slug
  limit 1;
$$;

revoke all on function get_link_preview(text) from public;
grant execute on function get_link_preview(text) to anon, authenticated;


-- ============================================================
-- 3. get_invoice_public returns enough to rebuild the page
-- ------------------------------------------------------------
-- The payment page handed the bolt11 string to the invoice page via
-- sessionStorage, so the invoice existed only inside one tab. Close
-- it, refresh, or open the link on a laptop and the invoice was
-- unreachable even though it was alive on the node for another 50
-- minutes — the customer started over and the merchant collected an
-- orphaned invoice.
--
-- Expiry is unchanged: BTCPay still closes the invoice after 60
-- minutes and the page shows "expired" past that. This only makes
-- the invoice reachable *within* its own lifetime.
-- ============================================================
drop function if exists get_invoice_public(uuid);

create or replace function get_invoice_public(p_payment_id uuid)
returns table (
  id uuid,
  amount_requested numeric,
  amount_settled numeric,
  method text,
  status text,
  expires_at timestamptz,
  merchant_name text,
  link_slug text,
  lightning_invoice text
)
language sql
security definer
stable
set search_path = public
as $$
  select
    p.id, p.amount_requested, p.amount_settled, p.method, p.status,
    p.expires_at,
    pr.display_name as merchant_name,
    pl.slug as link_slug,
    p.lightning_invoice
  from payments p
  left join payment_links pl on pl.id = p.payment_link_id
  left join profiles pr on pr.id = p.user_id
  where p.id = p_payment_id;
$$;

revoke all on function get_invoice_public(uuid) from public;
grant execute on function get_invoice_public(uuid) to anon, authenticated;
