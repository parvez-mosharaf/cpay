-- ============================================================
-- Boltpay — 0011: Wallet defaults + platform notice
-- ============================================================
alter table profiles add column if not exists default_withdrawal_method text;
alter table profiles add column if not exists default_withdrawal_destination text;
insert into app_settings (key, value) values
('platform_notice', '{"text": "", "active": false}')
on conflict (key) do nothing;
