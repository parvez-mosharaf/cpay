-- ============================================================
-- Boltpay — 0065: buyer_amount কলাম + display RPC ফাংশন আপডেট
-- ============================================================
-- এটা কোনো charge, BTCPay invoice amount, balance বা withdrawal
-- logic বদলায় না। শুধু একটা নতুন nullable কলাম (buyer_amount)
-- যুক্ত করে এবং ৬টা "read/display" ফাংশনের আউটপুট মান বদলায়
-- যাতে সব জায়গায় buyer যা টাইপ করেছিল সেটাই মূল amount হিসেবে
-- দেখা যায়। amount_requested/amount_settled টেবিলে (raw column)
-- এবং balance/withdrawal/reconcile-এর ভিতরে সম্পূর্ণ অপরিবর্তিত
-- থাকছে — সেগুলোই markup-সহ প্রকৃত চার্জ, balance-এর ভিত্তি।
--
-- কোনো DROP FUNCTION লাগছে না — এই ৬টা ফাংশনের কোনোটার signature
-- বা return column বদলাচ্ছে না, শুধু ভিতরের SELECT-এর মান বদলাচ্ছে,
-- তাই grant হারানোর ঝুঁকিও নেই।
-- ============================================================

alter table payments add column if not exists buyer_amount numeric(18,2);

alter table payments drop constraint if exists payments_buyer_amount_positive;
alter table payments add constraint payments_buyer_amount_positive
  check (buyer_amount is null or buyer_amount > 0)
  not valid;

-- পুরনো payment-এর জন্য: buyer আসলে কত টাইপ করেছিল তা কখনো
-- সংরক্ষণ করা হয়নি, তাই amount_requested দিয়েই ব্যাকফিল করা হচ্ছে
-- (মানে পুরনো record-এ fee দেখাবে $0, যেহেতু এটা কখনো জানা ছিল না
-- — এটা এড়ানো সম্ভব না, শুধু migration-এর পর তৈরি হওয়া প্রতিটা
-- নতুন payment-এই সঠিক buyer amount দেখাবে)
update payments
   set buyer_amount = amount_requested
 where buyer_amount is null;

comment on column payments.buyer_amount is
  'বায়ার পেমেন্ট পেজে যা টাইপ করেছে, markup যোগ হওয়ার আগে। amount_requested/amount_settled অপরিবর্তিত থাকে — markup-সহ প্রকৃত চার্জ, balance ও BTCPay-এর ভিত্তি।';


-- ============================================================
-- 1. get_invoice_public() — success/receipt পেজ
-- ============================================================
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
    p.id,
    coalesce(p.buyer_amount, p.amount_requested) as amount_requested,
    case when p.amount_settled is not null
         then coalesce(p.buyer_amount, p.amount_settled)
         else null end as amount_settled,
    p.method, p.status,
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


-- ============================================================
-- 2. get_my_payments() — creator dashboard Transactions
-- ============================================================
create or replace function get_my_payments(
  p_limit int default 60,
  p_offset int default 0,
  p_search text default null,
  p_status text default null
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
  link_slug text,
  link_name text,
  surcharge_percent numeric,
  btcpay_invoice_id text,
  lightning_invoice text,
  marked_at timestamptz,
  marked_by_name text,
  marked_by_self boolean,
  mark_note text,
  total_count bigint
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_limit int := least(greatest(coalesce(p_limit, 60), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_status text := lower(nullif(trim(coalesce(p_status, '')), ''));
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_hide_at numeric := small_payment_threshold();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  if v_status is not null
     and v_status not in ('settled', 'new', 'pending', 'expired', 'invalid') then
    raise exception 'Invalid status filter';
  end if;

  return query
  with filtered as (
    select p.*
    from payments p
    left join payment_links pl on pl.id = p.payment_link_id
    where p.user_id = v_uid
      and (v_status is null or p.status = v_status)
      and not (p.status = 'settled' and p.amount_settled < v_hide_at)
      and (
        v_search is null
        or p.btcpay_invoice_id ilike '%' || v_search || '%'
        or p.lightning_invoice ilike '%' || v_search || '%'
        or pl.slug ilike '%' || v_search || '%'
      )
  )
  select
    f.id,
    coalesce(f.buyer_amount, f.amount_requested) as amount_requested,
    case when f.amount_settled is not null
         then coalesce(f.buyer_amount, f.amount_settled)
         else null end as amount_settled,
    f.status, f.method,
    f.created_at, f.settled_at, f.expires_at,
    f.customer_city, f.customer_country,
    pl.slug, pl.display_name, s.surcharge_percent,
    f.btcpay_invoice_id, f.lightning_invoice,
    f.marked_at, mb.display_name, f.marked_by = v_uid, f.mark_note,
    count(*) over () as total_count
  from filtered f
  left join payment_links pl on pl.id = f.payment_link_id
  left join btcpay_shops s on s.id = pl.shop_id
  left join profiles mb on mb.id = f.marked_by
  order by f.created_at desc
  limit v_limit offset v_offset;
end;

$$;

revoke all on function get_my_payments(int, int, text, text) from public, anon;
grant execute on function get_my_payments(int, int, text, text) to authenticated;


-- ============================================================
-- 3. admin_list_payments() — admin panel Transactions
-- ============================================================
create or replace function admin_list_payments(
  p_limit int default 100,
  p_offset int default 0,
  p_search text default null
)
returns table (
  id uuid, amount_requested numeric, amount_settled numeric, status text, method text,
  created_at timestamptz, settled_at timestamptz, expires_at timestamptz,
  customer_city text, customer_country text,
  creator_id uuid, creator_email text, creator_name text,
  link_slug text, shop_name text, surcharge_percent numeric,
  btcpay_invoice_id text, lightning_invoice text,
  marked_at timestamptz, marked_by_name text, mark_note text,
  total_count bigint
)
language plpgsql security definer set search_path = public as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not (is_admin() or is_moderator()) then raise exception 'Not authorized'; end if;

  return query
  with filtered as (
    select p.*
    from payments p
    join profiles pr on pr.id = p.user_id
    left join payment_links pl on pl.id = p.payment_link_id
    where (is_admin() or handles_creator(p.user_id))
      and (
        v_search is null
        or p.btcpay_invoice_id ilike '%' || v_search || '%'
        or p.lightning_invoice ilike '%' || v_search || '%'
        or pr.email ilike '%' || v_search || '%'
        or pl.slug ilike '%' || v_search || '%'
      )
  )
  select
    f.id,
    coalesce(f.buyer_amount, f.amount_requested) as amount_requested,
    case when f.amount_settled is not null
         then coalesce(f.buyer_amount, f.amount_settled)
         else null end as amount_settled,
    f.status, f.method,
    f.created_at, f.settled_at, f.expires_at,
    f.customer_city, f.customer_country,
    f.user_id, pr.email, pr.display_name,
    pl.slug, s.name, s.surcharge_percent,
    f.btcpay_invoice_id, f.lightning_invoice,
    f.marked_at, mb.display_name, f.mark_note,
    count(*) over () as total_count
  from filtered f
  join profiles pr on pr.id = f.user_id
  left join payment_links pl on pl.id = f.payment_link_id
  left join btcpay_shops s on s.id = pl.shop_id
  left join profiles mb on mb.id = f.marked_by
  order by f.created_at desc
  limit v_limit offset v_offset;
end; $$;

revoke all on function admin_list_payments(int, int, text) from public, anon;
grant execute on function admin_list_payments(int, int, text) to authenticated;


-- ============================================================
-- 4. staff_list_payments() — moderator panel
-- ============================================================
create or replace function staff_list_payments(
  p_limit int default 120,
  p_offset int default 0,
  p_search text default null,
  p_status text default null,
  p_time text default null
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
  creator_id uuid,
  creator_email text,
  creator_name text,
  link_slug text,
  shop_name text,
  surcharge_percent numeric,
  btcpay_invoice_id text,
  lightning_invoice text,
  marked_at timestamptz,
  marked_by_name text,
  mark_note text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit int := least(greatest(coalesce(p_limit, 120), 1), 200);
  v_offset int := greatest(coalesce(p_offset, 0), 0);
  v_status text := lower(nullif(trim(coalesce(p_status, '')), ''));
  v_time text := lower(nullif(trim(coalesce(p_time, '')), ''));
  v_now timestamptz := now();
  v_start timestamptz := null;
  v_hide_at numeric := small_payment_threshold();
begin
  if not (is_admin() or is_moderator()) then
    raise exception 'Not authorized';
  end if;

  if v_status is not null and v_status not in ('settled', 'new', 'pending', 'expired', 'invalid') then
    raise exception 'Invalid status filter';
  end if;

  if v_time = 'today' then
    v_start := date_trunc('day', v_now);
  elsif v_time = '7d' then
    v_start := v_now - interval '7 days';
  elsif v_time = '30d' then
    v_start := v_now - interval '30 days';
  elsif v_time is null or v_time = '' then
    v_start := null;
  else
    raise exception 'Invalid time filter';
  end if;

  return query
  select
    p.id,
    coalesce(p.buyer_amount, p.amount_requested) as amount_requested,
    case when p.amount_settled is not null
         then coalesce(p.buyer_amount, p.amount_settled)
         else null end as amount_settled,
    p.status,
    p.method,
    p.created_at,
    p.settled_at,
    p.expires_at,
    p.customer_city,
    p.customer_country,
    p.user_id,
    pr.email,
    pr.display_name,
    pl.slug,
    s.name,
    s.surcharge_percent,
    p.btcpay_invoice_id,
    p.lightning_invoice,
    p.marked_at,
    mb.display_name,
    p.mark_note
  from payments p
  join profiles pr on pr.id = p.user_id
  left join payment_links pl on pl.id = p.payment_link_id
  left join btcpay_shops s on s.id = pl.shop_id
  left join profiles mb on mb.id = p.marked_by
  where (is_admin() or handles_creator(p.user_id))
    and not (p.status = 'settled' and p.amount_settled < v_hide_at)
    and (
      p_search is null or p_search = ''
      or p.btcpay_invoice_id ilike '%' || p_search || '%'
      or p.lightning_invoice ilike '%' || p_search || '%'
      or pr.email ilike '%' || p_search || '%'
      or coalesce(pr.display_name, '') ilike '%' || p_search || '%'
      or coalesce(pl.slug, '') ilike '%' || p_search || '%'
    )
    and (v_status is null or p.status = v_status)
    and (v_start is null or p.created_at >= v_start)
  order by p.created_at desc
  limit v_limit
  offset v_offset;
end;

$$;

revoke all on function staff_list_payments(int, int, text, text, text) from public, anon;
grant execute on function staff_list_payments(int, int, text, text, text) to authenticated;


-- ============================================================
-- 5. public_settled_feed() — home page-এর live feed
-- ============================================================
create or replace function public_settled_feed(p_limit int default 20)
returns table (amount numeric, settled_at timestamptz)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if coalesce((select (value)::text from app_settings
               where key = 'public_feed_enabled'), 'false') <> 'true' then
    return;
  end if;

  return query
  select coalesce(p.buyer_amount, p.amount_settled), p.settled_at
  from payments p
  where p.status = 'settled' and p.settled_at is not null
    and p.amount_settled >= small_payment_threshold()
  order by p.settled_at desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
end;

$$;


-- ============================================================
-- 6. lookup_payment_status() — home page-এর payment lookup
-- ============================================================
create or replace function lookup_payment_status(p_reference text)
returns table (amount numeric, status text, created_at timestamptz, settled_at timestamptz)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_ref text := trim(coalesce(p_reference, ''));
begin
  if length(v_ref) < 12 then
    raise exception 'Enter the full invoice ID or Lightning address';
  end if;

  return query
  select coalesce(p.buyer_amount, p.amount_settled, p.amount_requested),
         p.status, p.created_at, p.settled_at
  from payments p
  where p.btcpay_invoice_id = v_ref or p.lightning_invoice = v_ref
  limit 1;
end;

$$;
