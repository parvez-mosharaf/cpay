-- ============================================================
-- CPAY — 0006: Default app_settings
-- ============================================================
insert into app_settings (key, value) values
('exchange_rates', '{"buy_rate": 1.0, "sell_rate": 1.0}'),
('auto_withdraw_threshold', '{"amount": 500}')
on conflict (key) do nothing;
