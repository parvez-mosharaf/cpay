-- ============================================================
-- CPAY — 0080: auditable staging and release-gate ledger
-- ============================================================
-- This is an operator checklist, not a money switch. Completing a gate
-- does not enable BTCPay, withdrawals, or production deployment.

create table if not exists ops_release_gates (
  gate_key       text primary key
    check (gate_key ~ '^[a-z0-9_]+$'),
  category       text not null default 'staging'
    check (category in ('foundation', 'btcpay', 'ledger', 'withdrawals', 'release')),
  title          text not null
    check (char_length(title) between 3 and 120),
  description    text not null default ''
    check (char_length(description) <= 500),
  sort_order     integer not null default 0,
  required       boolean not null default true,
  completed      boolean not null default false,
  evidence_note  text,
  completed_by   uuid references profiles(id),
  completed_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create index if not exists idx_ops_release_gates_order
  on ops_release_gates(required desc, sort_order, gate_key);

alter table ops_release_gates enable row level security;
-- No direct table policies: all reads and writes go through admin-only RPCs.

insert into ops_release_gates
  (gate_key, category, title, description, sort_order)
values
  ('staging_backup', 'foundation',
   'Staging backup exists',
   'A recoverable snapshot exists for the new CPAY Supabase project.',
   10),
  ('migration_chain', 'foundation',
   'Migrations apply in order',
   'Migrations 0001 through 0080 apply cleanly on the CPAY staging project.',
   20),
  ('separate_btcpay_store', 'btcpay',
   'Separate BTCPay store',
   'CPAY staging uses its own store, wallet and test funds—not previous production resources.',
   30),
  ('invoice_settlement_expiry', 'btcpay',
   'Invoice, settlement and expiry tested',
   'A staging invoice settles once and an expired invoice does not credit the ledger.',
   40),
  ('webhook_signature_idempotency', 'btcpay',
   'Webhook security and idempotency tested',
   'Signature validation, retries and duplicate delivery produce one ledger credit.',
   50),
  ('reconciliation_and_backup', 'ledger',
   'Reconciliation and backup observed',
   'Daily reconciliation, ledger backup and alert delivery have been observed.',
   60),
  ('lightning_withdrawal_safety', 'withdrawals',
   'Lightning withdrawal safety tested',
   'Limits, timeout behavior, processing state and retry/idempotency are verified.',
   70),
  ('onchain_withdrawals_disabled', 'withdrawals',
   'On-chain withdrawals remain disabled',
   'Receiving QR addresses are enabled only for receiving; payout signing remains off.',
   80),
  ('cloudflare_staging_route', 'release',
   'Staging route is isolated',
   'The staging site and custom domains cannot route into previous production.',
   90)
on conflict (gate_key) do update
set category = excluded.category,
    title = excluded.title,
    description = excluded.description,
    sort_order = excluded.sort_order,
    updated_at = now();

create or replace function admin_ops_release_gates()
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'gate_key', g.gate_key,
        'category', g.category,
        'title', g.title,
        'description', g.description,
        'required', g.required,
        'completed', g.completed,
        'evidence_note', g.evidence_note,
        'completed_by', g.completed_by,
        'completed_at', g.completed_at,
        'updated_at', g.updated_at
      )
      order by g.required desc, g.sort_order, g.gate_key
    )
    from ops_release_gates g
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.admin_ops_release_gates() from public, anon;
grant execute on function public.admin_ops_release_gates() to authenticated;

create or replace function admin_set_ops_release_gate(
  p_gate_key text,
  p_completed boolean,
  p_evidence_note text default null
)
returns ops_release_gates
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old ops_release_gates;
  v_row ops_release_gates;
  v_completed boolean := coalesce(p_completed, false);
  v_note text := left(trim(coalesce(p_evidence_note, '')), 2000);
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;

  select * into v_old
  from ops_release_gates
  where gate_key = trim(coalesce(p_gate_key, ''))
  for update;

  if v_old.gate_key is null then
    raise exception 'Unknown release gate';
  end if;
  if v_completed and char_length(v_note) < 4 then
    raise exception 'Evidence note is required when completing a gate';
  end if;

  update ops_release_gates
  set completed = v_completed,
      evidence_note = nullif(v_note, ''),
      completed_by = case when v_completed then auth.uid() else null end,
      completed_at = case when v_completed then now() else null end,
      updated_at = now()
  where gate_key = v_old.gate_key
  returning * into v_row;

  perform record_audit(
    'ops.release_gate_changed',
    'release_gate',
    v_row.gate_key,
    jsonb_build_object('completed', v_old.completed, 'evidence_note', v_old.evidence_note),
    jsonb_build_object('completed', v_row.completed, 'evidence_note', v_row.evidence_note),
    'Staging/release evidence ledger updated'
  );

  return v_row;
end;
$$;

revoke all on function public.admin_set_ops_release_gate(text, boolean, text)
  from public, anon;
grant execute on function public.admin_set_ops_release_gate(text, boolean, text)
  to authenticated;