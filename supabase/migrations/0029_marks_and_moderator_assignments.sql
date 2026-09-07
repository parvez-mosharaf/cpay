-- ============================================================
-- Boltpay — 0029: Shared payment marks + moderator assignments
-- ============================================================
-- Replaces the earlier 0029 attempt, which aborted on 42P13 and so
-- applied nothing. Every function whose shape changed is dropped first
-- here, and the whole file is idempotent — run it on a database that
-- has 0028 or one that does not.
--
-- ------------------------------------------------------------
-- What a mark is
-- ------------------------------------------------------------
-- Bookkeeping, not money. BTCPay settles the payment; the mark only
-- records that a person has checked it off. Nothing here can create
-- balance, change an amount, or alter a status — which is exactly why
-- it is safe for a creator and a moderator to both use it.
--
-- One mark per payment, shared by everyone who can see it:
--   * the admin marks it   -> the creator sees it on their dashboard
--   * the creator marks it -> the admin sees it in Transactions
--   * an assigned moderator marks it -> both see it
-- ============================================================


-- ============================================================
-- 1. Columns (no-ops if 0028 already ran)
-- ============================================================
alter table payments add column if not exists marked_at timestamptz;
alter table payments add column if not exists marked_by uuid references profiles(id);
alter table payments add column if not exists mark_note text;

alter table payments drop constraint if exists payments_mark_note_check;
alter table payments add constraint payments_mark_note_check
  check (mark_note is null or length(mark_note) <= 200) not valid;

create index if not exists idx_payments_marked on payments(marked_at) where marked_at is not null;

alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check
  check (role in ('creator', 'admin', 'moderator'));


-- ============================================================
-- 2. Moderator assignments
-- ------------------------------------------------------------
-- A moderator handles specific creators, not the whole platform. Over
-- the creators they are assigned they get the full customer view; over
-- everyone else they get nothing.
-- ============================================================
create table if not exists moderator_assignments (
  moderator_id uuid not null references profiles(id) on delete cascade,
  creator_id   uuid not null references profiles(id) on delete cascade,
  assigned_at  timestamptz not null default now(),
  primary key (moderator_id, creator_id)
);

alter table moderator_assignments enable row level security;

drop policy if exists "assignments admin only" on moderator_assignments;
create policy "assignments admin only"
on moderator_assignments for all
using (is_admin()) with check (is_admin());

create index if not exists idx_mod_assign_creator on moderator_assignments(creator_id);


-- ============================================================
-- 3. Who may touch which creator
-- ------------------------------------------------------------
-- One place decides it, so the rule cannot drift between functions.
-- ============================================================
create or replace function handles_creator(p_creator_id uuid) returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select
    is_admin()
    or exists (
      select 1 from moderator_assignments ma
      join profiles pr on pr.id = ma.moderator_id
      where ma.moderator_id = auth.uid()
        and ma.creator_id = p_creator_id
        and pr.role = 'moderator'
    );
$$;

revoke all on function handles_creator(uuid) from public, anon;
grant execute on function handles_creator(uuid) to authenticated;

create or replace function is_moderator() returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'moderator');
$$;

revoke all on function is_moderator() from public, anon;
grant execute on function is_moderator() to authenticated;


-- ============================================================
-- 4. Marking
-- ------------------------------------------------------------
-- Allowed for: the payment's own creator, an admin, or a moderator
-- assigned to that creator. Only settled payments — marking something
-- still in flight would say "checked" before there was anything to
-- check.
-- ============================================================
drop function if exists mod_mark_payment(uuid, text);
drop function if exists mod_unmark_payment(uuid);

create or replace function mark_payment(p_payment_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_owner uuid; v_status text;
begin
  select user_id, status into v_owner, v_status from payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;

  if not (v_owner = auth.uid() or handles_creator(v_owner)) then
    raise exception 'Not authorized';
  end if;

  if v_status <> 'settled' then
    raise exception 'Only settled payments can be marked';
  end if;

  update payments
     set marked_at = now(), marked_by = auth.uid(),
         mark_note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_payment_id;
end;
$$;

create or replace function unmark_payment(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_owner uuid;
begin
  select user_id into v_owner from payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;

  if not (v_owner = auth.uid() or handles_creator(v_owner)) then
    raise exception 'Not authorized';
  end if;

  update payments set marked_at = null, marked_by = null, mark_note = null
   where id = p_payment_id;
end;
$$;

revoke all on function mark_payment(uuid, text) from public, anon;
revoke all on function unmark_payment(uuid) from public, anon;
grant execute on function mark_payment(uuid, text) to authenticated;
grant execute on function unmark_payment(uuid) to authenticated;


-- ============================================================
-- 5. Both sides read the same mark
-- ============================================================
drop function if exists get_my_payment_marks();

create or replace function get_my_payment_marks()
returns table (payment_id uuid, marked_at timestamptz, marked_by_name text,
               marked_by_self boolean, mark_note text)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  return query
  select p.id, p.marked_at, mb.display_name, p.marked_by = auth.uid(), p.mark_note
  from payments p
  left join profiles mb on mb.id = p.marked_by
  where p.user_id = auth.uid() and p.marked_at is not null;
end;
$$;

revoke all on function get_my_payment_marks() from public, anon;
grant execute on function get_my_payment_marks() to authenticated;

-- The admin Transactions list carries the mark, so the panel shows the
-- same state the creator's dashboard shows.
drop function if exists admin_list_payments(int, text);

create or replace function admin_list_payments(
  p_limit int default 100,
  p_search text default null
)
returns table (
  id uuid, amount_requested numeric, amount_settled numeric, status text, method text,
  created_at timestamptz, settled_at timestamptz, expires_at timestamptz,
  customer_city text, customer_country text,
  creator_id uuid, creator_email text, creator_name text,
  link_slug text, shop_name text, surcharge_percent numeric,
  btcpay_invoice_id text, lightning_invoice text,
  marked_at timestamptz, marked_by_name text, mark_note text
)
language plpgsql security definer set search_path = public as $$
begin
  -- A moderator sees only the creators assigned to them; an admin sees
  -- everything. Filtering here rather than in the panel means an
  -- unassigned creator's payments never leave the database.
  if not (is_admin() or is_moderator()) then raise exception 'Not authorized'; end if;

  return query
  select p.id, p.amount_requested, p.amount_settled, p.status, p.method,
    p.created_at, p.settled_at, p.expires_at,
    p.customer_city, p.customer_country,
    p.user_id, pr.email, pr.display_name,
    pl.slug, s.name, s.surcharge_percent,
    p.btcpay_invoice_id, p.lightning_invoice,
    p.marked_at, mb.display_name, p.mark_note
  from payments p
  join profiles pr on pr.id = p.user_id
  left join payment_links pl on pl.id = p.payment_link_id
  left join btcpay_shops s on s.id = pl.shop_id
  left join profiles mb on mb.id = p.marked_by
  where (is_admin() or handles_creator(p.user_id))
    and (
      p_search is null or p_search = ''
      or p.btcpay_invoice_id ilike '%' || p_search || '%'
      or p.lightning_invoice ilike '%' || p_search || '%'
      or pr.email ilike '%' || p_search || '%'
      or pl.slug ilike '%' || p_search || '%'
    )
  order by p.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 500);
end; $$;

revoke all on function admin_list_payments(int, text) from public, anon;
grant execute on function admin_list_payments(int, text) to authenticated;


-- ============================================================
-- 6. Assigning creators to a moderator
-- ============================================================
create or replace function admin_set_role(p_user_id uuid, p_role text)
returns void
language plpgsql security definer set search_path = public as $$
declare v_admin_count int;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_role not in ('creator', 'admin', 'moderator') then
    raise exception 'Unknown role';
  end if;

  -- Demoting the last admin would lock everyone out of the panel, and
  -- the only way back would be a manual UPDATE in the SQL editor.
  if p_role <> 'admin' then
    select count(*) into v_admin_count from profiles
     where role = 'admin' and id <> p_user_id;
    if v_admin_count = 0 then
      raise exception 'This is the only admin account — promote someone else first';
    end if;
  end if;

  update profiles set role = p_role where id = p_user_id;

  -- Dropping the moderator role drops what they were handling with it.
  if p_role <> 'moderator' then
    delete from moderator_assignments where moderator_id = p_user_id;
  end if;
end; $$;

create or replace function admin_assign_creator(
  p_moderator_id uuid, p_creator_id uuid, p_assigned boolean
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  if not exists (select 1 from profiles where id = p_moderator_id and role = 'moderator') then
    raise exception 'That account is not a moderator';
  end if;
  if not exists (select 1 from profiles where id = p_creator_id and role = 'creator') then
    raise exception 'That account is not a creator';
  end if;

  if p_assigned then
    insert into moderator_assignments (moderator_id, creator_id)
    values (p_moderator_id, p_creator_id)
    on conflict do nothing;
  else
    delete from moderator_assignments
     where moderator_id = p_moderator_id and creator_id = p_creator_id;
  end if;
end; $$;

drop function if exists admin_list_staff();

create or replace function admin_list_staff()
returns table (id uuid, email text, display_name text, role text,
               assigned_creators jsonb, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pr.id, pr.email, pr.display_name, pr.role,
    coalesce((
      select jsonb_agg(ma.creator_id)
      from moderator_assignments ma where ma.moderator_id = pr.id
    ), '[]'::jsonb),
    pr.created_at
  from profiles pr
  where pr.role in ('admin', 'moderator')
  order by pr.role, pr.created_at;
end; $$;

revoke all on function admin_set_role(uuid, text) from public, anon;
revoke all on function admin_assign_creator(uuid, uuid, boolean) from public, anon;
revoke all on function admin_list_staff() from public, anon;
grant execute on function admin_set_role(uuid, text) to authenticated;
grant execute on function admin_assign_creator(uuid, uuid, boolean) to authenticated;
grant execute on function admin_list_staff() to authenticated;


-- ============================================================
-- 7. A moderator's view of their creators
-- ------------------------------------------------------------
-- Same shape as admin_customer_directory, restricted to the creators
-- assigned to the caller. An admin gets everyone, so the panel can use
-- one function for both.
-- ============================================================
create or replace function staff_customer_directory()
returns table (
  rn bigint, id uuid, email text, display_name text,
  total_earned numeric, total_withdrawn numeric,
  payment_count bigint, link_count bigint, max_links int,
  auto_withdraw_enabled boolean,
  w_binance text, w_usdt text, w_bkash text, w_nagad text
)
language plpgsql security definer set search_path = public as $$
begin
  if not (is_admin() or is_moderator()) then raise exception 'Not authorized'; end if;

  return query
  select
    row_number() over (order by coalesce(e.earned, 0) desc),
    pr.id, pr.email, pr.display_name,
    coalesce(e.earned, 0), coalesce(w.paid, 0),
    coalesce(e.cnt, 0), coalesce(l.cnt, 0), pr.max_payment_links,
    pr.auto_withdraw_enabled,
    pr.wallet_binance_id, pr.wallet_usdt_bep20, pr.wallet_bkash, pr.wallet_nagad
  from profiles pr
  left join lateral (
    select sum(p.amount_settled) as earned, count(*) as cnt
    from payments p where p.user_id = pr.id and p.status = 'settled') e on true
  left join lateral (
    select sum(wd.amount_after_fee) as paid
    from withdrawals wd where wd.user_id = pr.id and wd.status = 'paid') w on true
  left join lateral (
    select count(*) as cnt from payment_links pl where pl.user_id = pr.id) l on true
  where pr.role = 'creator' and handles_creator(pr.id)
  order by coalesce(e.earned, 0) desc;
end; $$;

revoke all on function staff_customer_directory() from public, anon;
grant execute on function staff_customer_directory() to authenticated;
