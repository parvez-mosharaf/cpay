-- ============================================================
-- CPAY — 0069: additional payment layouts and price transparency
-- ============================================================

-- 1. Add two additive payment-page layouts. Existing domains keep their
-- current theme; unknown or blank values fall back to keypad.
alter table site_domains drop constraint if exists site_domains_theme_check;
update site_domains
set theme = 'keypad'
where theme is null
   or theme not in ('keypad', 'classic', 'tile', 'focus', 'receipt');
alter table site_domains alter column theme set default 'keypad';
alter table site_domains add constraint site_domains_theme_check
  check (theme in ('keypad', 'classic', 'tile', 'focus', 'receipt'));

-- 2. The public preview exposes the resolved markup so the payer can see
-- the final amount before creating a BTCPay invoice.
drop function if exists get_link_preview(text);
create or replace function get_link_preview(p_slug text)
returns table (
  display_name text,
  is_active boolean,
  og_image text,
  shop_name text,
  surcharge_percent numeric,
  cost_percent numeric
)
language sql
security definer
stable
set search_path = public
as $$
  select pl.display_name, pl.is_active, pl.og_image,
         s.name,
         coalesce(s.surcharge_percent, 0),
         coalesce(pl.cost_percent, pr.cost_percent, 0)
  from payment_links pl
  join profiles pr on pr.id = pl.user_id
  left join btcpay_shops s on s.id = pl.shop_id
  where pl.slug = p_slug and pl.deleted_at is null
  limit 1;
$$;
revoke all on function get_link_preview(text) from public;
grant execute on function get_link_preview(text) to anon, authenticated;

-- 3. Close the INSERT variant of the shop-lock bypass. A locked account may
-- not create a new link with a different shop_id by writing directly to
-- PostgREST; the admin RPC remains allowed.
create or replace function public.guard_link_shop_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_locked boolean;
  v_forced uuid;
begin
  if auth.uid() is null or is_admin() then
    return new;
  end if;

  if new.user_id is distinct from auth.uid() then
    raise exception 'Cannot create or move a link for another user';
  end if;

  select coalesce(shop_locked, false), forced_shop_id
    into v_locked, v_forced
    from profiles
   where id = auth.uid();

  if tg_op = 'INSERT' then
    if v_locked and new.shop_id is distinct from v_forced then
      raise exception 'Your payment cost is set by the admin and cannot be changed';
    end if;
    if not v_locked and new.shop_id is not null
       and not exists (
         select 1 from btcpay_shops s
          where s.id = new.shop_id and s.is_active = true
       ) then
      raise exception 'That cost option is not available';
    end if;
    return new;
  end if;

  if new.shop_id is distinct from old.shop_id then
    if v_locked then
      raise exception 'Your payment cost is set by the admin and cannot be changed';
    end if;
    if new.shop_id is not null
       and not exists (
         select 1 from btcpay_shops s
          where s.id = new.shop_id and s.is_active = true
       ) then
      raise exception 'That cost option is not available';
    end if;
  end if;

  if new.user_id is distinct from old.user_id then
    raise exception 'Cannot change link owner';
  end if;
  if new.deleted_at is distinct from old.deleted_at then
    raise exception 'Deleted links cannot be restored from here';
  end if;
  if new.cost_percent is distinct from old.cost_percent
     and new.cost_percent is not null
     and (new.cost_percent < 0 or new.cost_percent > 1000) then
    raise exception 'Cost must be between 0 and 1000';
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_guard_link_shop_updates on public.payment_links;
create trigger trg_guard_link_shop_updates
before insert or update on public.payment_links
for each row execute function public.guard_link_shop_updates();

commit;