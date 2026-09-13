-- ============================================================
-- Boltpay — 0028: Moderator role
-- ============================================================
-- A limited account for staff who handle payment history. A moderator
-- can see settled payments and put a "checked" mark on them, and that
-- mark shows up on the creator's own dashboard.
--
-- What a moderator deliberately CANNOT do:
--   * change a payment's status, amount or settled value
--   * approve, reject or pay a withdrawal
--   * see or change fees, shops, domains, settings or other creators
--   * read anybody's email
--
-- The mark is bookkeeping, not money. BTCPay settles the payment; this
-- only records that a person has looked at it. Nothing here can create
-- balance, which is the whole reason it is safe to hand out.
-- ============================================================


-- ============================================================
-- 1. The role itself
-- ============================================================
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check
  check (role in ('creator', 'admin', 'moderator'));

-- is_admin() is left alone on purpose. A moderator must not satisfy it,
-- or every admin-only function in the system would open up at once.
create or replace function is_moderator() returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists(
    select 1 from profiles
    where id = auth.uid() and role in ('admin', 'moderator')
  );
$$;

revoke all on function is_moderator() from public, anon;
grant execute on function is_moderator() to authenticated;


-- ============================================================
-- 2. The mark
-- ============================================================
alter table payments add column if not exists marked_at timestamptz;
alter table payments add column if not exists marked_by uuid references profiles(id);
alter table payments add column if not exists mark_note text;

alter table payments drop constraint if exists payments_mark_note_check;
alter table payments add constraint payments_mark_note_check
  check (mark_note is null or length(mark_note) <= 200)
  not valid;

create index if not exists idx_payments_marked on payments(marked_at)
  where marked_at is not null;


-- ============================================================
-- 3. What a moderator can see
-- ------------------------------------------------------------
-- Settled payments only, and no email addresses. A moderator has enough
-- to identify a payment — amount, time, link, invoice id — without a
-- list of everyone's contact details attached.
-- ============================================================
create or replace function mod_list_payments(
  p_limit int default 100,
  p_search text default null
)
returns table (
  id uuid,
  amount numeric,
  status text,
  created_at timestamptz,
  settled_at timestamptz,
  link_slug text,
  creator_name text,
  btcpay_invoice_id text,
  marked_at timestamptz,
  marked_by_name text,
  mark_note text
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not is_moderator() then raise exception 'Not authorized'; end if;

  return query
  select p.id,
    coalesce(p.amount_settled, p.amount_requested),
    p.status, p.created_at, p.settled_at,
    pl.slug, pr.display_name, p.btcpay_invoice_id,
    p.marked_at, mb.display_name, p.mark_note
  from payments p
  left join payment_links pl on pl.id = p.payment_link_id
  left join profiles pr on pr.id = p.user_id
  left join profiles mb on mb.id = p.marked_by
  where p.status = 'settled'
    and (
      p_search is null or p_search = ''
      or p.btcpay_invoice_id ilike '%' || p_search || '%'
      or p.lightning_invoice ilike '%' || p_search || '%'
      or pl.slug ilike '%' || p_search || '%'
    )
  order by p.settled_at desc nulls last
  limit least(greatest(coalesce(p_limit, 100), 1), 300);
end;
$$;

revoke all on function mod_list_payments(int, text) from public, anon;
grant execute on function mod_list_payments(int, text) to authenticated;


-- ============================================================
-- 4. Marking
-- ------------------------------------------------------------
-- Only a settled payment can be marked. Marking something still in
-- flight would tell the creator it had been checked before there was
-- anything to check.
-- ============================================================
create or replace function mod_mark_payment(p_payment_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_status text;
begin
  if not is_moderator() then raise exception 'Not authorized'; end if;

  select status into v_status from payments where id = p_payment_id;
  if not found then raise exception 'Payment not found'; end if;
  if v_status <> 'settled' then
    raise exception 'Only settled payments can be marked';
  end if;

  update payments
     set marked_at = now(),
         marked_by = auth.uid(),
         mark_note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_payment_id;
end;
$$;

create or replace function mod_unmark_payment(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_moderator() then raise exception 'Not authorized'; end if;
  update payments
     set marked_at = null, marked_by = null, mark_note = null
   where id = p_payment_id;
end;
$$;

revoke all on function mod_mark_payment(uuid, text) from public, anon;
revoke all on function mod_unmark_payment(uuid) from public, anon;
grant execute on function mod_mark_payment(uuid, text) to authenticated;
grant execute on function mod_unmark_payment(uuid) to authenticated;


-- ============================================================
-- 5. A creator sees the mark on their own payments
-- ------------------------------------------------------------
-- payments already has an "own payments" select policy, and the three
-- new columns come with select('*'). This function exists so the
-- dashboard can show WHO marked it without granting a creator any read
-- access to the profiles table beyond their own row.
-- ============================================================
create or replace function get_my_payment_marks()
returns table (payment_id uuid, marked_at timestamptz, marked_by_name text, mark_note text)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  return query
  select p.id, p.marked_at, mb.display_name, p.mark_note
  from payments p
  left join profiles mb on mb.id = p.marked_by
  where p.user_id = auth.uid() and p.marked_at is not null;
end;
$$;

revoke all on function get_my_payment_marks() from public, anon;
grant execute on function get_my_payment_marks() to authenticated;


-- ============================================================
-- 6. Admin assigns the role
-- ============================================================
create or replace function admin_set_role(p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_admin_count int;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;

  if p_role not in ('creator', 'admin', 'moderator') then
    raise exception 'Unknown role';
  end if;

  -- Demoting the last admin would lock everybody out of the panel, and
  -- the only way back would be a manual UPDATE in the SQL editor.
  if p_role <> 'admin' then
    select count(*) into v_admin_count
    from profiles where role = 'admin' and id <> p_user_id;
    if v_admin_count = 0 then
      raise exception 'This is the only admin account — promote someone else first';
    end if;
  end if;

  update profiles set role = p_role where id = p_user_id;
end;
$$;

revoke all on function admin_set_role(uuid, text) from public, anon;
grant execute on function admin_set_role(uuid, text) to authenticated;


-- ============================================================
-- 7. The customer directory has to show moderators too
-- ------------------------------------------------------------
-- It filtered on role = 'creator', so a promoted moderator vanished
-- from the list and there was no way to demote them again.
-- ============================================================
create or replace function admin_list_staff()
returns table (id uuid, email text, display_name text, role text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  return query
  select pr.id, pr.email, pr.display_name, pr.role, pr.created_at
  from profiles pr
  where pr.role in ('admin', 'moderator')
  order by pr.role, pr.created_at;
end; $$;

revoke all on function admin_list_staff() from public, anon;
grant execute on function admin_list_staff() to authenticated;
