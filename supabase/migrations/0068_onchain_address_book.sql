-- ============================================================
-- CPAY — 0068: safe on-chain address book and QR foundation
-- ============================================================
-- This migration stores receiving addresses only. It does not send
-- payouts, sign transactions, or enable on-chain withdrawals.

create table if not exists onchain_addresses (
  id uuid primary key default uuid_generate_v4(),
  user_id uuid not null references profiles(id) on delete cascade,
  network text not null default 'bitcoin'
    check (network in ('bitcoin', 'bitcoin_testnet')),
  label text not null default 'Bitcoin address'
    check (char_length(label) between 1 and 80),
  address text not null
    check (char_length(address) between 20 and 120),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, address)
);

create index if not exists idx_onchain_addresses_user_active
  on onchain_addresses(user_id, is_active, created_at desc);

alter table onchain_addresses enable row level security;

drop policy if exists "onchain owner read" on onchain_addresses;
create policy "onchain owner read"
on onchain_addresses for select
using (user_id = auth.uid() or is_admin());

-- Mutations go through RPCs so account status and address validation cannot
-- be bypassed with a direct PostgREST insert/update.
drop policy if exists "onchain owner insert" on onchain_addresses;
drop policy if exists "onchain owner update" on onchain_addresses;
drop policy if exists "onchain owner delete" on onchain_addresses;

create or replace function cpay_valid_onchain_address(
  p_network text,
  p_address text
)
returns boolean
language sql
immutable
as $$
  select case
    when p_network = 'bitcoin'
      then p_address ~* '^(bc1)[a-z0-9]{11,87}$'
        or p_address ~ '^[13][a-km-zA-HJ-NP-Z1-9]{24,34}$'
    when p_network = 'bitcoin_testnet'
      then p_address ~* '^(tb1)[a-z0-9]{11,87}$'
        or p_address ~ '^[2mn][a-km-zA-HJ-NP-Z1-9]{24,34}$'
    else false
  end;
$$;
revoke all on function cpay_valid_onchain_address(text, text) from public, anon;
grant execute on function cpay_valid_onchain_address(text, text) to authenticated;

create or replace function onchain_address_create(
  p_network text,
  p_address text,
  p_label text default null
)
returns onchain_addresses
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row onchain_addresses;
  -- Bech32 is case-insensitive, but legacy Base58 addresses are not.
  -- Preserve the caller's case after trimming.
  v_address text := trim(coalesce(p_address, ''));
  v_label text := left(trim(coalesce(nullif(p_label, ''), 'Bitcoin address')), 80);
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  if not account_is_active(auth.uid()) then
    raise exception 'Account approval is required before adding addresses';
  end if;
  if p_network not in ('bitcoin', 'bitcoin_testnet') then
    raise exception 'Unsupported Bitcoin network';
  end if;
  if not cpay_valid_onchain_address(p_network, v_address) then
    raise exception 'Enter a valid Bitcoin address for the selected network';
  end if;

  insert into onchain_addresses(user_id, network, address, label)
  values (auth.uid(), p_network, v_address, v_label)
  on conflict (user_id, address) do update
    set network = excluded.network,
        label = excluded.label,
        is_active = true,
        updated_at = now()
  returning * into v_row;

  return v_row;
end;
$$;
revoke all on function onchain_address_create(text, text, text) from public, anon;
grant execute on function onchain_address_create(text, text, text) to authenticated;

create or replace function onchain_address_update(
  p_id uuid,
  p_label text,
  p_is_active boolean
)
returns onchain_addresses
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row onchain_addresses;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  update onchain_addresses
  set label = left(trim(coalesce(nullif(p_label, ''), label)), 80),
      is_active = coalesce(p_is_active, is_active),
      updated_at = now()
  where id = p_id
    and (user_id = auth.uid() or is_admin())
  returning * into v_row;

  if v_row.id is null then raise exception 'Address not found'; end if;
  return v_row;
end;
$$;
revoke all on function onchain_address_update(uuid, text, boolean) from public, anon;
grant execute on function onchain_address_update(uuid, text, boolean) to authenticated;

create or replace function onchain_address_delete(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  update onchain_addresses
  set is_active = false, updated_at = now()
  where id = p_id
    and (user_id = auth.uid() or is_admin());
  if not found then raise exception 'Address not found'; end if;
end;
$$;
revoke all on function onchain_address_delete(uuid) from public, anon;
grant execute on function onchain_address_delete(uuid) to authenticated;

commit;