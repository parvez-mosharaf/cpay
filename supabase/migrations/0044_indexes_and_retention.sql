-- ============================================================
-- CPAY — 0044: Hot-path indexes and webhook retention
-- ============================================================
-- Three findings from the audit, all cheap, all in one place.
--
-- M1 — payments(created_at) had no index, yet it is the ORDER BY of
--      both admin_list_payments() and the creator dashboard's payment
--      list. Every load sorted the whole table.
--
-- M2 — prune_webhook_events() was written in 0033 but its cron schedule
--      was left as a comment, so webhook_events has been growing without
--      limit since the day it was created.
--
-- M3 — the statement timeout (SQLSTATE 57014) seen on a support_messages
--      UPDATE was lock contention: the UPDATE waited behind a slower
--      statement until Postgres cancelled it at 8 seconds. 0034 already
--      indexed that UPDATE, so M1 is the remaining half of the cure —
--      faster sorts mean less time holding locks.
-- ============================================================


-- ============================================================
-- M1 — ordering indexes
-- ============================================================
-- DESC matches the ORDER BY exactly, so the planner can walk the index
-- backwards instead of sorting. An ASC index would also work, but
-- spelling it the way the query reads it costs nothing.
create index if not exists idx_payments_created_at
  on payments(created_at desc);

-- The creator dashboard filters to one user and then orders by date.
-- The composite serves both halves in one scan; idx_payments_user_status
-- from 0018 cannot, because status is not in the ORDER BY.
create index if not exists idx_payments_user_created_at
  on payments(user_id, created_at desc);


-- ============================================================
-- M3 — already covered
-- ============================================================
-- The statement timeout was on
--   UPDATE support_messages SET read_by_creator = true
--   WHERE user_id = $1 AND sender = $2 AND read_by_creator = false
-- and 0034 already added idx_messages_creator_unread and
-- idx_messages_admin_unread for exactly that shape. Nothing to add here;
-- the remaining contention should ease once the payment indexes above
-- stop the long sorts that the UPDATE was queueing behind.


-- ============================================================
-- M2 — actually schedule the pruning
-- ============================================================
-- 0033 defined prune_webhook_events() and then left the schedule in a
-- comment, which is the same as not having written it. Scheduling it
-- here means the retention policy exists in the migration history rather
-- than in someone's memory of a dashboard setting.
--
-- Runs 03:20 UTC (09:20 Dhaka), clear of the daily-report and
-- ledger-backup jobs so three cron jobs never contend for the same
-- locks — which is the contention M3 was a symptom of.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise notice 'pg_cron not installed — skipping schedule. Enable it under Database > Extensions, then re-run this migration.';
    return;
  end if;

  -- Unschedule first so re-running this migration cannot stack duplicate
  -- jobs, which cron.schedule() on its own happily would.
  perform cron.unschedule('prune-webhook-events')
  where exists (select 1 from cron.job where jobname = 'prune-webhook-events');

  perform cron.schedule(
    'prune-webhook-events',
    '20 3 * * *',
    $job$select public.prune_webhook_events()$job$
  );
end $$;
