-- ============================================================
-- CPAY — 0034: support_messages mark-as-read deadlock fix
-- ============================================================
-- Symptom (postgres_logs):
--   40P01  deadlock detected
--   57014  canceling statement due to statement timeout
-- on:
--   UPDATE support_messages SET read_by_creator = true
--   WHERE user_id = $2 AND sender = $3
--
-- Root cause: the creator dashboard ran this bulk UPDATE on EVERY message
-- reload, with no read_by_creator filter and no usable index. Without an
-- index Postgres locks touched rows in physical scan order; concurrent
-- sessions (creator tab + admin panel + realtime-triggered refresh) pick
-- different orders and end up waiting on each other in a circle.
--
-- Fix (two parts):
--   1. THIS FILE — a partial index covering exactly the rows the
--      mark-as-read UPDATE touches (unread admin messages of one thread).
--      With it, Postgres finds those rows through the index, locks them
--      in a single deterministic order, and visiting sessions serialize
--      instead of deadlocking.
--   2. public/dashboard.html — loadMessages() now only issues the UPDATE
--      when unread > 0, and filters .eq('read_by_creator', false), so
--      already-read rows are never locked at all. In the 99% case the
--      UPDATE does not even run.
-- ============================================================

create index if not exists idx_messages_creator_unread
  on support_messages(user_id, sender)
  where read_by_creator = false;

-- Same pattern for the admin side: the admin panel marks creator messages
-- read per creator thread (read_by_admin), which is the same bulk-update
-- shape and the same deadlock risk.
create index if not exists idx_messages_admin_unread
  on support_messages(user_id, sender)
  where read_by_admin = false;

-- Sanity check (run after applying):
--   select indexname, indexdef from pg_indexes
--   where tablename = 'support_messages'
--     and indexname like 'idx_messages_%_unread';
-- Expected: 2 rows.
--
-- Verify the fix under load:
--   explain update support_messages set read_by_creator = true
--   where user_id = '<any-creator-uuid>' and sender = 'admin'
--     and read_by_creator = false;
-- Expected: Index Scan using idx_messages_creator_unread (NOT Seq Scan).
