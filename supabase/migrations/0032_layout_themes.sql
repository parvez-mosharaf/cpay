-- ============================================================
-- CPAY — 0032: Themes become layouts, not palettes
-- ============================================================
-- site_domains.theme used to swap the colour palette, which is exactly
-- backwards: the brand is one colour everywhere — the Cash App green of
-- the payment page — and what should differ per domain is the LAYOUT of
-- that page.
--
-- So the four palette names become three layout names:
--
--   keypad   the current page: big amount, 3x4 keypad, quick amounts
--   classic  amount field + quick-select chips + a single Pay button
--   tile     full-bleed green, large keypad, amount over the pad
--
-- All three paint in the same green. The invoice page is deliberately
-- not themed at all — it is the same for every domain.
-- ============================================================

alter table site_domains drop constraint if exists site_domains_theme_check;

-- Map the old palette names onto the closest layout before the new
-- constraint goes on, or existing rows would fail it.
update site_domains set theme = case theme
  when 'voltmeter' then 'keypad'
  when 'ledger'    then 'classic'
  when 'aurora'    then 'tile'
  when 'calm'      then 'classic'
  else 'keypad'
end
where theme is null or theme not in ('keypad','classic','tile');

alter table site_domains alter column theme set default 'keypad';

alter table site_domains add constraint site_domains_theme_check
  check (theme in ('keypad','classic','tile'));
