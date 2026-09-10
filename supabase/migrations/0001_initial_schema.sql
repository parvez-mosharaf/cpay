-- ============================================================
-- Boltpay — 0001: Initial schema
-- ============================================================
create extension if not exists "uuid-ossp";
-- Profiles (extends auth.users)
create table if not exists profiles (
id uuid primary key references auth.users(id) on delete cascade,
email text unique not null,
display_name text,
role text not null default 'creator' check (role in ('creator','admin')),
buy_rate numeric(10,4) default 1.0,
sell_rate numeric(10,4) default 1.0,
withdrawal_fee_percent numeric(5,2) default 3.0,
created_at timestamptz default now()
);
-- Payment links ("models")
create table if not exists payment_links (
id uuid primary key default uuid_generate_v4(),
user_id uuid not null references profiles(id) on delete cascade,
slug text unique not null,
display_name text,
is_active boolean default true,
created_at timestamptz default now()
);
create index if not exists idx_payment_links_user on payment_links(user_id);
create index if not exists idx_payment_links_slug on payment_links(slug);
-- Payments / Invoices
create table if not exists payments (
id uuid primary key default uuid_generate_v4(),
payment_link_id uuid references payment_links(id) on delete set null,
user_id uuid not null references profiles(id) on delete cascade,
btcpay_invoice_id text unique,
method text default 'lightning',
amount_requested numeric(18,8) not null,
amount_settled numeric(18,8),
status text not null default 'new' check (status in ('new','pending','settled','expired','invalid')),
withdrawal_id uuid,
expires_at timestamptz not null,
settled_at timestamptz,
created_at timestamptz default now()
);
create index if not exists idx_payments_user on payments(user_id);
create index if not exists idx_payments_status on payments(status);
create index if not exists idx_payments_btcpay on payments(btcpay_invoice_id);
create index if not exists idx_payments_withdrawal on payments(withdrawal_id);
-- Withdrawals
create table if not exists withdrawals (
id uuid primary key default uuid_generate_v4(),
user_id uuid not null references profiles(id) on delete cascade,
amount_requested numeric(18,8) not null,
fee_percent numeric(5,2) not null,
amount_after_fee numeric(18,8) not null,
method text check (method in ('bkash','nagad','binance')),
destination text not null,
status text not null default 'pending' check (status in ('pending','approved','rejected','paid')),
admin_note text,
requested_at timestamptz default now(),
processed_at timestamptz
);
create index if not exists idx_withdrawals_user on withdrawals(user_id);
create index if not exists idx_withdrawals_status on withdrawals(status);
alter table payments
add constraint fk_payments_withdrawal
foreign key (withdrawal_id) references withdrawals(id) on delete set null;
-- App settings (rates, notices, thresholds)
create table if not exists app_settings (
key text primary key,
value jsonb not null,
updated_at timestamptz default now()
);
-- Daily stats (lightweight rollup — one row per day, no bloated raw log tables)
create table if not exists daily_stats (
stat_date date primary key,
total_settled numeric(18,8) default 0,
total_admin_profit numeric(18,8) default 0,
total_withdrawn numeric(18,8) default 0,
payment_count int default 0,
computed_at timestamptz default now()
);