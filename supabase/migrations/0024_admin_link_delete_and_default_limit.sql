-- ============================================================
-- Boltpay — 0024: Admin link deletion + default link limit
-- ============================================================


-- ============================================================
-- 1. New creators inherit the configured link limit
-- ------------------------------------------------------------
-- app_settings has held 'default_max_payment_links' since 0006, and
-- the admin panel never had a field for it — but more to the point,
-- handle_new_user() never read it. Every account was created with the
-- column default of 5 no matter what that setting said.
--
-- The fee lookup right above it already worked this way; the link
-- limit was simply left out.
-- ============================================================
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_default_fee numeric;
  v_default_links int;
begin
  select coalesce((value->>'percent')::numeric, 3.0) into v_default_fee
  from app_settings where key = 'default_withdrawal_fee_percent';

  select coalesce((value->>'count')::int, 5) into v_default_links
  from app_settings where key = 'default_max_payment_links';

  insert into public.profiles (id, email, display_name, withdrawal_fee_percent, max_payment_links)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
    coalesce(v_default_fee, 3.0),
    coalesce(v_default_links, 5)
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

revoke all on function handle_new_user() from anon, authenticated;

-- 0006 seeded this key; make sure it exists on databases that skipped it.
insert into app_settings (key, value)
select 'default_max_payment_links', '{"count": 5}'
where not exists (select 1 from app_settings where key = 'default_max_payment_links');


-- ============================================================
-- 2. Admins can delete a payment link, not only disable it
-- ------------------------------------------------------------
-- payments.payment_link_id is `on delete set null`, so deleting a link
-- never deletes money: the payment rows survive with their amount,
-- status and creator intact, and only lose the slug they came in on.
-- The admin panel's Transactions tab shows a dash for those.
--
-- The count is returned so the panel can warn before doing it — an
-- admin should know they are about to detach 40 payments from their
-- link, and pick "disable" instead if that is not what they meant.
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
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  select * into v_link from payment_links pl where pl.id = p_link_id;
  if not found then raise exception 'Link not found'; end if;

  select count(*) into v_count
  from payments p where p.payment_link_id = p_link_id;

  delete from payment_links pl where pl.id = p_link_id;

  return query select v_link.slug, v_count;
end;
$$;

revoke all on function admin_delete_link(uuid) from public, anon;
grant execute on function admin_delete_link(uuid) to authenticated;


-- ============================================================
-- 3. How many payments would a delete detach?
-- ------------------------------------------------------------
-- So the confirm dialog can state the number before anything is
-- removed, rather than reporting it afterwards.
-- ============================================================
create or replace function admin_link_payment_count(p_link_id uuid)
returns bigint
language plpgsql
security definer
stable
set search_path = public
as $$
declare v_count bigint;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  select count(*) into v_count from payments p where p.payment_link_id = p_link_id;
  return v_count;
end;
$$;

revoke all on function admin_link_payment_count(uuid) from public, anon;
grant execute on function admin_link_payment_count(uuid) to authenticated;
