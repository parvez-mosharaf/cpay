-- ============================================================
-- Boltpay — 0033: Webhook idempotency + ledger integrity
-- ============================================================
-- Two unrelated hardening changes in one migration:
--
--   1. webhook_events — BTCPay retries every delivery until it receives a
--      200, and can also deliver the same event twice concurrently. The
--      btcpay-webhook function now claims a delivery id here BEFORE
--      touching the payments row; a duplicate insert (unique violation
--      23505) means "already handled", so the function acknowledges with
--      200 instead of reprocessing. This is the last line of defence
--      behind the conditional `neq('status','settled')` update.
--
--   2. CHECK constraints — defence in depth. Every money path already
--      validates amounts in SQL functions and edge functions, but a bug
--      or a future migration that bypasses one of those paths could
--      otherwise write a negative or zero amount straight into the
--      ledger. The database now refuses those rows no matter who writes.
-- ============================================================

-- ---------- 1. webhook_events ----------
create table if not exists webhook_events (
  id          bigint generated always as identity primary key,
  delivery_id text not null,
  invoice_id  text,
  event_type  text,
  received_at timestamptz not null default now()
);

-- The unique constraint IS the idempotency mechanism.
create unique index if not exists idx_webhook_events_delivery
  on webhook_events(delivery_id);

create index if not exists idx_webhook_events_invoice
  on webhook_events(invoice_id);

-- Service-role only. Nobody queries this from the browser; it exists so
-- the edge function (which uses the service role) can claim deliveries.
alter table webhook_events enable row level security;
-- No policies on purpose: with RLS enabled and no policies, anon and
-- authenticated get zero access, and the service role bypasses RLS.

-- Pruning helper — keep ~90 days of deliveries so the table stays small.
-- Schedule it from the dashboard cron (optional):
--   select cron.schedule('prune-webhook-events', '30 11 * * *',
--     $$select public.prune_webhook_events()$$);
create or replace function public.prune_webhook_events()
returns integer
language sql
security definer
set search_path = public
as $$
  with deleted as (
    delete from webhook_events
    where received_at < now() - interval '90 days'
    returning 1
  )
  select count(*)::integer from deleted;
$$;

-- Only the service role (edge functions / cron) may call it.
revoke execute on function public.prune_webhook_events() from anon, authenticated;

-- ---------- 2. CHECK constraints ----------
-- Amounts can never be negative, and a requested amount can never be 0.
-- (amount_settled is nullable — an unsettled payment has no settled amount.)
alter table payments
  drop constraint if exists payments_amount_requested_positive,
  add constraint payments_amount_requested_positive
    check (amount_requested > 0);

alter table payments
  drop constraint if exists payments_amount_settled_nonnegative,
  add constraint payments_amount_settled_nonnegative
    check (amount_settled is null or amount_settled >= 0);

alter table withdrawals
  drop constraint if exists withdrawals_amount_requested_positive,
  add constraint withdrawals_amount_requested_positive
    check (amount_requested > 0);

alter table withdrawals
  drop constraint if exists withdrawals_amount_after_fee_nonnegative,
  add constraint withdrawals_amount_after_fee_nonnegative
    check (amount_after_fee >= 0);

-- Sanity check (run in the SQL editor after applying):
--   insert into payments (payment_link_id, user_id, btcpay_invoice_id,
--     method, amount_requested, status)
--   values (null, null, 'x', 'lightning', -5, 'new');
-- Expected: ERROR  new row for relation "payments" violates check constraint
