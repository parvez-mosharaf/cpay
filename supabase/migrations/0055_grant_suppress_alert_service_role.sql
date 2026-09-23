-- ============================================================
-- CPAY — 0055: service_role can call should_suppress_payment_alert
-- ============================================================
-- 0054 granted this only to `authenticated`. btcpay-webhook calls it (as
-- of this migration) through the SERVICE_ROLE key, which maps to the
-- `service_role` database role — a role the earlier grant never covered.
-- Without this, the call would either be refused outright or rely on
-- default privileges that were never guaranteed.
-- ============================================================

grant execute on function should_suppress_payment_alert(numeric) to service_role;
