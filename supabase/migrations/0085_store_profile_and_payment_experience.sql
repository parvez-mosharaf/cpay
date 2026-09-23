-- CPAY 0085: public seller profile + storefront customization + richer payment header
alter table profiles add column if not exists store_tagline text;
alter table profiles add column if not exists store_bio text;
alter table profiles add column if not exists store_avatar_url text;
alter table profiles add column if not exists store_theme text not null default 'midnight';
alter table profiles add column if not exists store_accent text not null default '#00D632';
alter table profiles add column if not exists store_cta text not null default 'Pay now';

alter table profiles drop constraint if exists profiles_store_theme_check;
alter table profiles add constraint profiles_store_theme_check check (store_theme in ('midnight','snow','glass','sunset'));

drop function if exists public.get_public_store(uuid);
create or replace function get_public_store(p_user_id uuid)
returns table (
  display_name text,
  tagline text,
  bio text,
  avatar_url text,
  theme text,
  accent text,
  cta text,
  links jsonb
)
language sql security definer stable set search_path=public
as $$
  select coalesce(pr.display_name,'CPAY creator'),
         coalesce(pr.store_tagline,''),
         coalesce(pr.store_bio,''),
         coalesce(pr.store_avatar_url,''),
         coalesce(pr.store_theme,'midnight'),
         coalesce(pr.store_accent,'#00D632'),
         coalesce(pr.store_cta,'Pay now'),
         coalesce((select jsonb_agg(jsonb_build_object(
           'slug',l.slug,
           'display_name',coalesce(l.display_name,l.slug),
           'theme',coalesce(l.theme,'keypad'),
           'og_image',l.og_image
         ) order by l.created_at desc)
         from payment_links l where l.user_id=p_user_id and l.is_active=true and l.deleted_at is null),'[]'::jsonb)
  from profiles pr where pr.id=p_user_id and pr.role in ('creator','moderator');
$$;
revoke all on function get_public_store(uuid) from public;
grant execute on function get_public_store(uuid) to anon, authenticated;

-- Public invoice metadata is intentionally limited to presentation fields.
drop function if exists get_invoice_public(uuid);
create or replace function get_invoice_public(p_payment_id uuid)
returns table (
  id uuid, amount_requested numeric, amount_settled numeric, method text, status text,
  expires_at timestamptz, merchant_name text, link_slug text, lightning_invoice text,
  link_name text, merchant_tagline text, merchant_avatar_url text, merchant_accent text
)
language sql security definer stable set search_path=public
as $$
  select p.id,
    case when should_show_buyer_amount(p.user_id) then coalesce(p.buyer_amount,p.amount_requested) else p.amount_requested end,
    case when p.amount_settled is null then null when should_show_buyer_amount(p.user_id) then coalesce(p.buyer_amount,p.amount_settled) else p.amount_settled end,
    p.method,p.status,p.expires_at,pr.display_name,pl.slug,p.lightning_invoice,
    coalesce(pl.display_name,pl.slug),coalesce(pr.store_tagline,''),coalesce(pr.store_avatar_url,''),coalesce(pr.store_accent,'#00D632')
  from payments p left join payment_links pl on pl.id=p.payment_link_id left join profiles pr on pr.id=p.user_id
  where p.id=p_payment_id;
$$;
revoke all on function get_invoice_public(uuid) from public;
grant execute on function get_invoice_public(uuid) to anon, authenticated;
