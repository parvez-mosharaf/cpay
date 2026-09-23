-- ============================================================
-- CPAY — 0066: Global + per-creator toggle for amount display
-- ============================================================
-- Buyer-এর টাইপ করা amount (fee ছাড়া) সব জায়গায় দেখাবে, নাকি
-- fee-সহ প্রকৃত charged amount দেখাবে — এটা নিয়ন্ত্রণ করার জন্য
-- একটা global switch + per-creator override যুক্ত করা হচ্ছে।
--
-- Resolution: coalesce(creator override, global setting)
-- Default = TRUE (এখন যা দেখাচ্ছে তাই থাকবে, migration চালালেও
-- সাইটের কোনো visual পরিবর্তন হবে না)।
--
-- balance, withdrawal, BTCPay charging, reconciliation — কোনোটাই
-- স্পর্শ করা হচ্ছে না। এটা সম্পূর্ণ display-only পরিবর্তন।
-- ============================================================

insert into app_settings (key, value)
select 'show_buyer_amount_enabled', 'true'::jsonb
where not exists (select 1 from app_settings where key = 'show_buyer_amount_enabled');


-- ============================================================
-- 1. Per-creator override কলাম
-- ============================================================
alter table profiles add column if not exists show_buyer_amount_override boolean;

comment on column profiles.show_buyer_amount_override is
  'null = global setting অনুসরণ করবে। true = এই creator-এর জন্য সবসময় buyer-typed amount দেখাবে। false = সবসময় fee-সহ amount দেখাবে। Admin-only, admin_set_creator_amount_display() দিয়ে সেট হয়।';


-- ============================================================
-- 2. নতুন কলামকে protect করা — creator নিজে এটা বদলাতে পারবে না
-- ------------------------------------------------------------
-- guard_profile_updates()-এর পূর্ণ, প্রতিষ্ঠিত সংস্করণ (migration
-- 0061-এর পর cost_percent স্বেচ্ছায় বাদ দেওয়া হয়েছিল, কারণ সেটা
-- creator নিজে সেট করার অধিকার রাখে) — সেই ঠিক রাখা হচ্ছে, শুধু
-- নতুন কলামটা যুক্ত করা হচ্ছে।
-- ============================================================
create or replace function guard_profile_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or is_admin() then
    return new;
  end if;
  if new.id                         is distinct from old.id
  or new.email                      is distinct from old.email
  or new.role                       is distinct from old.role
  or new.withdrawal_fee_percent     is distinct from old.withdrawal_fee_percent
  or new.max_payment_links          is distinct from old.max_payment_links
  or new.auto_withdraw_enabled      is distinct from old.auto_withdraw_enabled
  or new.buy_rate                   is distinct from old.buy_rate
  or new.sell_rate                  is distinct from old.sell_rate
  or new.shop_locked                is distinct from old.shop_locked
  or new.forced_shop_id              is distinct from old.forced_shop_id
  or new.show_buyer_amount_override is distinct from old.show_buyer_amount_override
  then
    raise exception 'You may only change your display name and wallet details';
  end if;
  return new;
end;

$$;


-- ============================================================
-- 3. Resolution helper ফাংশন
-- ============================================================
create or replace function should_show_buyer_amount(p_creator_id uuid)
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(
    (select show_buyer_amount_override from profiles where id = p_creator_id),
    coalesce((select (value)::text from app_settings
              where key = 'show_buyer_amount_enabled'), 'true') = 'true'
  );

$$;


-- ============================================================
-- 4. Admin-এর জন্য per-creator override সেট করার RPC
-- ============================================================
create or replace function admin_set_creator_amount_display(p_creator_id uuid, p_mode text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_mode not in ('default', 'buyer', 'fee') then
    raise exception 'Mode must be default, buyer, or fee';
  end if;

  update profiles
     set show_buyer_amount_override = case p_mode
       when 'default' then null
       when 'buyer'   then true
       when 'fee'     then false
     end
   where id = p_creator_id;

  if not found then raise exception 'Creator not found'; end if;

  perform record_audit(
    'creator.amount_display_changed', 'profile', p_creator_id::text,
    null, jsonb_build_object('mode', p_mode)
  );
end;

$$;

revoke all on function admin_set_creator_amount_display(uuid, text) from public, anon;
grant execute on function admin_set_creator_amount_display(uuid, text) to authenticated;


-- ============================================================
-- 5. get_invoice_public() — success/receipt page
-- ============================================================
drop function if exists public.get_invoice_public(uuid);
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
    case when should_show_buyer_amount(p.user_id)
         then coalesce(p.buyer_amount, p.amount_requested)
         else p.amount_requested
    end as amount_requested,
    case when p.amount_settled is null then null
         when should_show_buyer_amount(p.user_id)
         then coalesce(p.buyer_amount, p.amount_settled)
         else p.amount_settled
    end as amount_settled,
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
-- 6. get_my_payments() — creator dashboard Transactions
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
  v_show_buyer boolean;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  v_show_buyer := should_show_buyer_amount(v_uid);

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
    case when v_show_buyer then coalesce(f.buyer_amount, f.amount_requested) else f.amount_requested end,
    case when f.amount_settled is null then null
         when v_show_buyer then coalesce(f.buyer_amount, f.amount_settled)
         else f.amount_settled end,
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
-- 7. admin_list_payments() — admin panel Transactions
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
    case when should_show_buyer_amount(f.user_id) then coalesce(f.buyer_amount, f.amount_requested) else f.amount_requested end,
    case when f.amount_settled is null then null
         when should_show_buyer_amount(f.user_id) then coalesce(f.buyer_amount, f.amount_settled)
         else f.amount_settled end,
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
-- 8. staff_list_payments() — moderator panel
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
    case when should_show_buyer_amount(p.user_id) then coalesce(p.buyer_amount, p.amount_requested) else p.amount_requested end,
    case when p.amount_settled is null then null
         when should_show_buyer_amount(p.user_id) then coalesce(p.buyer_amount, p.amount_settled)
         else p.amount_settled end,
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
-- 9. public_settled_feed() — home page live feed
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
  select
    case when should_show_buyer_amount(p.user_id)
         then coalesce(p.buyer_amount, p.amount_settled)
         else p.amount_settled
    end,
    p.settled_at
  from payments p
  where p.status = 'settled' and p.settled_at is not null
    and p.amount_settled >= small_payment_threshold()
  order by p.settled_at desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
end;

$$;


-- ============================================================
-- 10. lookup_payment_status() — home page payment lookup
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
  select
    case when should_show_buyer_amount(p.user_id)
         then coalesce(p.buyer_amount, p.amount_settled, p.amount_requested)
         else coalesce(p.amount_settled, p.amount_requested)
    end,
    p.status, p.created_at, p.settled_at
  from payments p
  where p.btcpay_invoice_id = v_ref or p.lightning_invoice = v_ref
  limit 1;
end;

$$;
