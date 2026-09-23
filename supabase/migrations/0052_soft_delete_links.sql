-- ============================================================
-- CPAY — 0052: Soft delete for payment links
-- ============================================================
-- admin_delete_link() ran a hard DELETE. payment_links.payment_link_id
-- on payments is `on delete set null`, so no payment record itself was
-- ever lost — but the moment a link was deleted, every payment that
-- came through it permanently lost its link context: the admin panel's
-- own comment on the old function said as much ("only lose the slug
-- they came in on... shows a dash for those").
--
-- This makes deletion non-destructive at the row level too: the link
-- row survives, marked deleted, so every payment join
-- (get_my_payments, admin_list_payments, staff_list_payments, ...)
-- keeps showing which link a payment came from — deleted or not.
--
-- The slug is freed for reuse at the same time, by rewriting it to an
-- unmistakably-archived, guaranteed-unique value. slug carries a plain
-- `unique not null` constraint (0001), and truncating a column-level
-- constraint into a partial index is a bigger, riskier change than this
-- migration needs — mangling the value achieves the same outcome
-- (a deleted link's original name becomes available again) without
-- touching the constraint at all.
--
-- One thing this is NOT: a "trash bin" UI. Nobody asked for a way to
-- browse or restore deleted links, so none is built. The row survives
-- for the sake of payment history, not to be managed as a link again.
-- ============================================================

alter table payment_links add column if not exists deleted_at timestamptz;

create index if not exists idx_payment_links_not_deleted
  on payment_links(user_id)
  where deleted_at is null;


-- ============================================================
-- admin_delete_link() — same signature and return type as before,
-- because nothing about what a caller sends or receives needs to
-- change; only what happens underneath does.
-- ============================================================
create or replace function admin_delete_link(p_link_id uuid)
returns table (slug text, detached_payments bigint)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v_link payment_links;
  v_count bigint;
  v_new_slug text;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  select * into v_link from payment_links pl where pl.id = p_link_id;
  if not found then raise exception 'Link not found'; end if;

  if v_link.deleted_at is not null then
    raise exception 'This link was already deleted';
  end if;

  -- No longer "how many will be detached" — nothing detaches any more.
  -- Kept for the admin panel's pre-delete warning, which uses a separate
  -- call (admin_link_payment_count) for that message today; this return
  -- value is otherwise informational.
  select count(*) into v_count
  from payments p where p.payment_link_id = p_link_id;

  -- Truncated so the mangled slug can never exceed the 50-character
  -- ceiling trg_validate_link_slug enforces (this UPDATE touches slug,
  -- so that trigger fires): 32 + 10 + 8 = 50 in the worst case.
  v_new_slug := left(v_link.slug, 32) || '--deleted-'
              || left(replace(p_link_id::text, '-', ''), 8);

  update payment_links
    set deleted_at = now(),
        is_active = false,
        slug = v_new_slug
    where id = p_link_id;

  perform record_audit(
    'link.deleted', 'payment_link', p_link_id::text,
    jsonb_build_object('slug', v_link.slug, 'display_name', v_link.display_name),
    jsonb_build_object('deleted_at', now())
  );

  return query select v_link.slug, v_count;
end;
$$;

revoke all on function admin_delete_link(uuid) from public, anon;
grant execute on function admin_delete_link(uuid) to authenticated;


-- ============================================================
-- Read paths — explicit guards added for clarity and defense in depth.
-- ------------------------------------------------------------
-- Slug-based lookups (get_link_preview, system_link_for_invoice,
-- link_style_options) already stop matching a deleted link the moment
-- its slug is mangled — no change in behaviour is strictly required.
-- The guard is added anyway: it makes the intent explicit in the SQL
-- itself, and it means correctness never depends on remembering that
-- mangling is what does the real work.
-- ============================================================

create or replace function get_link_preview(p_slug text)
returns table (
  display_name text,
  is_active boolean,
  og_image text,
  shop_name text,
  surcharge_percent numeric
)
language sql
security definer
stable
set search_path = public
as $$
  select pl.display_name, pl.is_active, pl.og_image,
         s.name, coalesce(s.surcharge_percent, 0)
  from payment_links pl
  left join btcpay_shops s on s.id = pl.shop_id
  where pl.slug = p_slug and pl.deleted_at is null
  limit 1;
$$;


create or replace function system_link_for_invoice(p_slug text)
returns table (
  link_id uuid,
  user_id uuid,
  slug text,
  display_name text,
  is_active boolean,
  store_id text,
  api_key_env text,
  surcharge_percent numeric
)
language sql
security definer
stable
set search_path = public
as $$
  select pl.id, pl.user_id, pl.slug, pl.display_name, pl.is_active,
         s.store_id, s.api_key_env, coalesce(s.surcharge_percent, 0)
  from payment_links pl
  left join btcpay_shops s on s.id = pl.shop_id and s.is_active = true
  where pl.slug = p_slug and pl.deleted_at is null
  limit 1;
$$;


create or replace function link_style_options(p_name text)
returns table (style text, slug text, taken boolean)
language plpgsql
security definer
stable
set search_path = public
as $$
#variable_conflict use_column
declare
  v_name text;
  v_style text;
  v_slug text;
  v_seen text[] := '{}';
begin
  v_name := title_case_name(p_name);
  if v_name = '' then return; end if;
  if slug_from_name(v_name, 'kebab') = '' then return; end if;

  foreach v_style in array array['lower','kebab','title-kebab','pascal'] loop
    v_slug := slug_from_name(v_name, v_style);
    if v_slug = '' or v_slug = any(v_seen) then continue; end if;
    v_seen := v_seen || v_slug;

    return query select
      v_style,
      v_slug,
      exists (
        select 1 from payment_links pl
        where pl.slug = v_slug and pl.deleted_at is null
      );
  end loop;
end;
$$;


-- admin_list_payment_links() — the admin panel's Links tab. A deleted
-- link disappears from this list exactly as a hard-deleted one used to;
-- the row still exists underneath for the sake of payment history, it
-- is just no longer something to manage here.
create or replace function admin_list_payment_links()
returns table (
  id uuid, slug text, display_name text, is_active boolean, created_at timestamptz,
  owner_email text, owner_name text, total_earned numeric, payment_count bigint,
  shop_id uuid, shop_name text, surcharge_percent numeric
)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pl.id, pl.slug, pl.display_name, pl.is_active, pl.created_at,
    pr.email, pr.display_name,
    coalesce((select sum(p.amount_settled) from payments p
              where p.payment_link_id = pl.id and p.status = 'settled'), 0),
    coalesce((select count(*) from payments p
              where p.payment_link_id = pl.id and p.status = 'settled'), 0),
    pl.shop_id, s.name, s.surcharge_percent
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  left join btcpay_shops s on s.id = pl.shop_id
  where pl.deleted_at is null
  order by pl.created_at desc;
end; $$;
