-- ============================================================
-- CPAY — 0070: per-link theme selection and admin visibility
-- ============================================================

alter table payment_links add column if not exists theme text;
alter table payment_links drop constraint if exists payment_links_theme_check;
alter table payment_links add constraint payment_links_theme_check
  check (theme is null or theme in ('keypad','classic','tile','focus','receipt'));
comment on column payment_links.theme is
  'Optional payment-page layout override. NULL inherits the active domain layout.';

create or replace function set_payment_link_theme(p_link_id uuid, p_theme text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old text;
  v_user uuid;
begin
  if p_theme is not null and p_theme not in ('keypad','classic','tile','focus','receipt') then
    raise exception 'Invalid payment theme';
  end if;
  select theme, user_id into v_old, v_user from payment_links
  where id = p_link_id and deleted_at is null for update;
  if not found then raise exception 'Payment link not found'; end if;
  if not is_admin() and v_user <> auth.uid() then raise exception 'Not authorized'; end if;
  update payment_links set theme = p_theme where id = p_link_id;
  if v_old is distinct from p_theme then
    perform record_audit(
      'payment_link.theme_changed', 'payment_link', p_link_id::text,
      jsonb_build_object('theme', v_old), jsonb_build_object('theme', p_theme)
    );
  end if;
  return p_theme;
end;
$$;
revoke all on function set_payment_link_theme(uuid, text) from public, anon;
grant execute on function set_payment_link_theme(uuid, text) to authenticated;

-- Public payment page: theme is resolved in the browser as link override,
-- otherwise the current domain layout remains the fallback.
drop function if exists get_link_preview(text);
create or replace function get_link_preview(p_slug text)
returns table (
  display_name text, is_active boolean, og_image text, shop_name text,
  surcharge_percent numeric, cost_percent numeric, theme text
)
language sql security definer stable set search_path = public as $$
  select pl.display_name, pl.is_active, pl.og_image, s.name,
         coalesce(s.surcharge_percent, 0),
         coalesce(pl.cost_percent, pr.cost_percent, 0), pl.theme
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  left join btcpay_shops s on s.id = pl.shop_id
  where pl.slug = p_slug and pl.deleted_at is null
  limit 1;
$$;
revoke all on function get_link_preview(text) from public;
grant execute on function get_link_preview(text) to anon, authenticated;

-- Admin Links tab with the effective override value.
drop function if exists admin_list_payment_links();
create or replace function admin_list_payment_links()
returns table (
  id uuid, slug text, display_name text, is_active boolean, created_at timestamptz,
  owner_email text, owner_name text, total_earned numeric, payment_count bigint,
  shop_id uuid, shop_name text, surcharge_percent numeric,
  cost_percent numeric, cost_is_override boolean, theme text
)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pl.id, pl.slug, pl.display_name, pl.is_active, pl.created_at,
    pr.email, pr.display_name,
    coalesce((select sum(p.amount_settled) from payments p where p.payment_link_id = pl.id and p.status = 'settled'), 0),
    coalesce((select count(*) from payments p where p.payment_link_id = pl.id and p.status = 'settled'), 0),
    pl.shop_id, s.name, s.surcharge_percent,
    coalesce(pl.cost_percent, pr.cost_percent, 0),
    pl.cost_percent is not null, pl.theme
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  left join btcpay_shops s on s.id = pl.shop_id
  where pl.deleted_at is null
  order by pl.created_at desc;
end; $$;
revoke all on function admin_list_payment_links() from public, anon;
grant execute on function admin_list_payment_links() to authenticated;
