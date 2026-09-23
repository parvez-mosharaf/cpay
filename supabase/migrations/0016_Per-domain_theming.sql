-- ============================================================
-- CPAY — 0016: Per-domain theming
-- ============================================================
alter table site_domains add column if not exists theme text default 'voltmeter';
-- Guard against typos putting an unknown theme into production
alter table site_domains drop constraint if exists site_domains_theme_check;
alter table site_domains add constraint site_domains_theme_check
check (theme in ('voltmeter','ledger','aurora','calm'));
-- Expose theme to anon so the public payment page can style itself
-- before the visitor has any session.
drop policy if exists "domains public read" on site_domains;
create policy "domains public read"
on site_domains for select
using (true);
-- Refresh the admin listing to include theme
drop function if exists admin_list_domains();
create or replace function admin_list_domains()
returns table (
id uuid, hostname text, purpose text, theme text,
is_active boolean, is_primary_site boolean, sort_order int
)
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
return query
select d.id, d.hostname, d.purpose, d.theme, d.is_active, d.is_primary_site, d.sort_order
from site_domains d order by d.sort_order, d.hostname;
end; $$;
revoke all on function admin_list_domains() from public;
grant execute on function admin_list_domains() to authenticated;
