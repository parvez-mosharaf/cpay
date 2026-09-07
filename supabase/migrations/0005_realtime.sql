-- ============================================================
-- Boltpay — 0005: Realtime — live invoice status updates
-- ============================================================
do $$
begin
if not exists (
select 1
from pg_publication_tables
where pubname = 'supabase_realtime'
and schemaname = 'public'
and tablename = 'payments'
) then
alter publication supabase_realtime add table payments;
end if;
end
$$;
