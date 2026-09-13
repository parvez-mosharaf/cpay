-- ============================================================
-- Run this BEFORE the migrations, and again AFTER.
-- ============================================================
-- Nothing here writes anything. It records what your prices are now, so
-- you can prove they did not change — rather than hoping they didn't.
-- ============================================================


-- ============================================================
-- BEFORE — save this output somewhere you can read it later
-- ============================================================

-- 1. Confirm you are where we think you are: 56 migrations applied.
select count(*) as migrations_applied,
       max(version) as latest
from supabase_migrations.schema_migrations;
-- Expect 56, latest 0056. If it is higher, some of 0057-0064 already
-- ran and you should stop and say so rather than running them twice.


-- 2. What every live link charges today. THIS IS THE ONE THAT MATTERS.
select pl.slug,
       s.name                         as shop,
       coalesce(s.surcharge_percent,0) as charges_percent,
       pl.is_active
from payment_links pl
left join btcpay_shops s on s.id = pl.shop_id
where pl.deleted_at is null
order by charges_percent desc, pl.slug;
-- Every row's charges_percent must read the same after the migrations.


-- 3. Your BTCPay shops and their spreads.
select name, store_id, surcharge_percent, is_active, is_default
from btcpay_shops order by sort_order, name;
-- Note every non-zero surcharge_percent. Those are what 0063 copies
-- onto the links, and what you then set to 0% inside BTCPay.


-- 4. Is any live link already sitting on a slug 0064 reserves?
select id, slug, user_id, is_active
from payment_links
where lower(slug) in (
  'index','login','register','dashboard','admin','404','config','theme',
  'assets','favicon','invoice-boltpay-v2','api','u','static','public',
  'well-known','robots','sitemap','moderator'
) and deleted_at is null;
-- Expect zero rows. 0064 raises a WARNING for each one it finds, but
-- knowing beforehand is better than reading it in the output.
-- A row here means that link stops resolving once the Worker is
-- redeployed. Rename or disable it first.


-- 5. Anything mid-flight? Run the migrations when this is empty.
select status, count(*), sum(amount_requested)
from withdrawals
where status in ('pending','approved','processing')
group by status;
-- 'processing' especially: that is a payout in progress. Wait for it.


-- ============================================================
-- AFTER the migrations — before touching BTCPay
-- ============================================================

-- 6. All 64 applied?
select count(*) as migrations_applied, max(version) as latest
from supabase_migrations.schema_migrations;
-- Expect 64, latest 0064.


-- 7. THE IMPORTANT ONE: prices unchanged?
select pl.slug,
       coalesce(s.surcharge_percent,0)                     as shop_still_charges,
       pl.cost_percent                                     as link_cost_now,
       pr.cost_percent                                     as owner_default,
       coalesce(pl.cost_percent, pr.cost_percent, 0)       as boltpay_will_add
from payment_links pl
join profiles pr on pr.id = pl.user_id
left join btcpay_shops s on s.id = pl.shop_id
where pl.deleted_at is null
order by boltpay_will_add desc, pl.slug;
--
-- Compare `boltpay_will_add` against query 2's `charges_percent`.
-- They must match row for row.
--
-- While BTCPay's own spread is still set, the two ADD UP — a link at 10%
-- charges 10% from Boltpay plus 10% from BTCPay, so payers briefly pay
-- more. That is why BTCPay comes last and quickly.


-- 8. Sanity on the two percentages, which are unrelated.
select email, role, cost_percent as their_markup,
       withdrawal_fee_percent as what_you_charge_them
from profiles
where role in ('creator','moderator')
order by created_at desc limit 20;
-- withdrawal_fee_percent must be unchanged from before — no migration
-- in this set alters a stored fee.


-- ============================================================
-- AFTER setting the BTCPay store spread to 0%
-- ============================================================

-- 9. Open one real link that used to be on a non-zero shop and check the
--    invoice amount matches what it charged yesterday. Query 7 tells you
--    which link to test: pick one where boltpay_will_add > 0.

-- 10. Then confirm the shops read 0:
select name, surcharge_percent from btcpay_shops where is_active;
-- All zero. If any is not, links on that shop are double-charging.
