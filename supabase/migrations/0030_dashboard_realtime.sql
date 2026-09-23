-- ============================================================
-- CPAY — 0030: Dashboard realtime streams
-- ============================================================
-- Payments were added to supabase_realtime in 0005. Creator and admin
-- dashboards also depend on payout changes for live balances and on support
-- message changes for the inbox badge. Keep these tables in the same
-- publication so browsers do not need refresh-only polling.

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'withdrawals'
  ) then
    alter publication supabase_realtime add table withdrawals;
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'support_messages'
  ) then
    alter publication supabase_realtime add table support_messages;
  end if;
end
$$;

-- The browser filters events by the owning user. FULL identity keeps the
-- previous row available for UPDATE/DELETE events on installations that use
-- strict Realtime filters.
alter table public.withdrawals replica identity full;
alter table public.support_messages replica identity full;
