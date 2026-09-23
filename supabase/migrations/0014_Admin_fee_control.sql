-- ============================================================
-- CPAY — 0014: Admin fee control
-- ============================================================
insert into app_settings (key, value) values
('default_withdrawal_fee_percent', '{"percent": 3.0}')
on conflict (key) do nothing;
-- New signups pick up the current global default fee instead of a hardcoded 3%
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
v_default_fee numeric;
begin
select coalesce((value->>'percent')::numeric, 3.0) into v_default_fee
from app_settings where key = 'default_withdrawal_fee_percent';
insert into public.profiles (id, email, display_name, withdrawal_fee_percent)
values (
new.id,
new.email,
coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
coalesce(v_default_fee, 3.0)
)
on conflict (id) do nothing;
return new;
end;
$$;
-- Admin can change any individual creator's fee percentage
create or replace function admin_update_creator_fee(p_creator_id uuid, p_fee_percent numeric)
returns void
language plpgsql security definer set search_path = public as $$
begin
if not is_admin() then raise exception 'Not authorized'; end if;
if p_fee_percent < 0 or p_fee_percent > 50 then
raise exception 'Fee must be between 0 and 50 percent';
end if;
update profiles set withdrawal_fee_percent = p_fee_percent where id = p_creator_id;
end; $$;
revoke all on function admin_update_creator_fee(uuid, numeric) from public;
grant execute on function admin_update_creator_fee(uuid, numeric) to authenticated;
