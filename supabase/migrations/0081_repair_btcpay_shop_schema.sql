-- CPAY: repair BTCPay shop metadata when an older migration history
-- marked the multi-shop migration as applied before all columns existed.
--
-- This migration is additive and safe to run on a new or partially
-- upgraded CPAY database. It does not insert credentials or change the
-- configured store ID.

alter table public.btcpay_shops
  add column if not exists slug_style text not null default 'lower';

alter table public.btcpay_shops
  add column if not exists api_key_env text not null default 'BTCPAY_API_KEY';

alter table public.btcpay_shops
  drop constraint if exists btcpay_shops_style_check;

alter table public.btcpay_shops
  add constraint btcpay_shops_style_check
  check (slug_style in ('kebab', 'pascal', 'lower', 'title-kebab'));

alter table public.btcpay_shops
  drop constraint if exists btcpay_shops_api_key_env_check;

alter table public.btcpay_shops
  add constraint btcpay_shops_api_key_env_check
  check (api_key_env ~ '^BTCPAY_API_KEY(_[2-9])?$');

create unique index if not exists idx_btcpay_shops_style
  on public.btcpay_shops(slug_style);
