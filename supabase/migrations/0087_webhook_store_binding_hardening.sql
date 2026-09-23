-- CPAY 0087: require explicit BTCPay store binding on invoice webhooks
-- A valid HMAC from one configured store must never settle an invoice belonging to another store.

-- No schema change is required; the Edge Function enforces this at the trust boundary.
