-- ============================================================
-- CPAY — 0004: Lightning-only payments (USDC removed)
-- ============================================================
alter table payments drop constraint if exists payments_method_check;
alter table payments add constraint payments_method_check check (method = 'lightning');
alter table payments alter column method set default 'lightning';
update payments set method = 'lightning' where method != 'lightning';
