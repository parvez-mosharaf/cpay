# Upgrading an existing deployment

What happens to data that already exists — creators already promoted to
moderator, links already priced at 10% or 0% — when migrations 0058–0063
are applied.

**Short answer: nothing a customer pays changes, and nothing a user
loses, provided you run 0063 and follow the BTCPay step below in the
right order.** The details, and the one thing that would go wrong if you
skipped a step, are below.

---

## 1. Creators you already promoted to moderator

These accounts keep everything they had. `moderator_assignments` is
untouched, so the creators they oversee stay assigned, and the moderator
panel works exactly as before.

What they *gain*:

- **Their own dashboard.** Previously `dashboard.html` bounced any
  non-creator away. They now land on the moderator panel by default and
  reach their earnings through the new "My earnings" link in its header.
- **The ability to own payment links.** Nothing in the database ever
  blocked this — the RLS policies are `user_id = auth.uid()` with no
  role test — but a moderator profile had no link allowance set.
  Migration 0059 backfills `max_payment_links = 5` for any moderator
  whose value is null. If you want a different number, change it on
  their profile in the admin panel.

Nothing they could do before stops working.

---

## 2. Links priced at different rates — the important one

### How this worked before

`payment_links.shop_id` points at a shop; each shop is a separate BTCPay
store with its own rate spread in `btcpay_shops.surcharge_percent`.
BTCPay applied that spread itself. Two links owned by the same person
could charge different markups by pointing at different shops.

So "some links at 10%, some at 0%" is **per-link, expressed through
which shop the link uses**.

### How it works after

Pricing moves into Boltpay itself, resolved in this order:

```
payment_links.cost_percent        (this specific link)
  ↓ if null
profiles.cost_percent             (the owner's default)
  ↓ if null/zero
0%
```

Boltpay multiplies the amount before creating the invoice, because
BTCPay's API has no per-invoice rate override — the spread is a
store-level setting, so one shared store cannot price per user.

### What 0063 does about your existing links

It reads every link's current shop surcharge and writes it onto the link
itself:

```sql
update payment_links pl
   set cost_percent = s.surcharge_percent
  from btcpay_shops s
 where s.id = pl.shop_id
   and pl.cost_percent is null
   and s.surcharge_percent > 0;
```

A link on a 10% shop gets `cost_percent = 10`. A link on a 0% shop is
left null and inherits its owner's default (0 unless they set one).

**The result: every link charges exactly what it charged before.**

| Link | Before (shop spread) | After (link cost, store at 0%) |
|---|---|---|
| `/link-a` on a 10% shop | payer pays $110.00 | payer pays $110.00 |
| `/link-b` on a 0% shop | payer pays $100.00 | payer pays $100.00 |

### What would go wrong without it

If you set the BTCPay store spread to 0% **without** running 0063, every
10% link silently becomes a 0% link:

| Link | Before | After, no backfill |
|---|---|---|
| `/link-a` | $110.00 | **$100.00** |
| `/link-b` | $100.00 | $100.00 |

No error, no warning — just less money on every payment. This is the one
real hazard in the upgrade, and it is entirely avoided by running 0063.

---

## 3. Order of operations

**Run the migrations first, change BTCPay second.** Nothing breaks in
between, but the two markups **compound** during that window, so be
specific about how long it lasts.

A $100 link that was on a 10% shop, after the backfill but before the
store spread is set to 0%:

```
Boltpay applies the backfilled 10%  ->  sends BTCPay $110.00
BTCPay applies its own 10% spread   ->  payer charged $121.00
```

That is 10% above the $110.00 it charged the day before. Real, and
overcharging a customer — so do steps 1–4 in one sitting rather than
leaving the migrations applied overnight.

1. Run `0058` → `0063` in order, in one sitting
2. Deploy the Edge Functions (`create-invoice`, `btcpay-webhook`,
   `user-withdraw`, `daily-report`, `reconcile`, `health`)
3. Deploy the HTML pages
4. **Now** set the BTCPay store rate spread to 0%
   (Store → Settings → Rates → spread `0`)
5. Spot-check one link that used to be on a 10% shop: opening it should
   still produce an invoice for the same amount as before

If step 5 shows less than before, step 4 happened before step 1.

---

## 4. Checking the backfill landed

```sql
select pl.slug,
       pl.cost_percent              as link_cost,
       pr.cost_percent              as owner_default,
       s.name                       as shop,
       s.surcharge_percent          as shop_spread,
       coalesce(pl.cost_percent, pr.cost_percent, 0) as effective_rate
from payment_links pl
join profiles pr on pr.id = pl.user_id
left join btcpay_shops s on s.id = pl.shop_id
where pl.deleted_at is null
order by effective_rate desc, pl.slug;
```

`effective_rate` should match what each link was charging before. Any
link that was on a non-zero shop and shows `link_cost` as null did not
get backfilled — check whether its `shop_id` is set.

---

## 5. Withdrawal fees are unaffected

`withdrawal_fee_percent` is a separate number on each profile and no
migration in this set changes anyone's existing value. 0060 only removed
the 50% ceiling on what you can *set*; it did not alter any stored fee.

New accounts continue to take their fee from
**Admin → Settings → Default fee for new creators**.

---

## 6. What each user sees afterward

- **Freelancers and resellers:** a new "Your pricing" panel on the Cash
  out tab, showing their account-level default. If their links were
  backfilled with per-link rates, those override the default and are
  managed per link.
- **Admin:** a "Pricing markup for this user" field on each profile, and
  the links list now shows each link's effective rate and whether it is a
  link-level override or inherited.
