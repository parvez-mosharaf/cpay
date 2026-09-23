-- CPAY 0088: atomic account-scoped invoice creation rate limiter
create table if not exists public.invoice_rate_limits (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  window_started_at timestamptz not null default now(),
  request_count integer not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.invoice_rate_limits enable row level security;
revoke all on public.invoice_rate_limits from anon, authenticated;

create or replace function public.claim_invoice_rate_limit(p_user_id uuid, p_limit integer default 30, p_window_seconds integer default 60)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_count integer;
begin
  if p_user_id is null or p_limit < 1 or p_window_seconds < 1 then raise exception 'Invalid rate-limit parameters'; end if;
  insert into public.invoice_rate_limits(user_id, window_started_at, request_count, updated_at)
  values (p_user_id, now(), 1, now())
  on conflict (user_id) do update
    set window_started_at = case when now() - invoice_rate_limits.window_started_at >= make_interval(secs => p_window_seconds) then now() else invoice_rate_limits.window_started_at end,
        request_count = case when now() - invoice_rate_limits.window_started_at >= make_interval(secs => p_window_seconds) then 1 else invoice_rate_limits.request_count + 1 end,
        updated_at = now();
  select request_count into v_count from public.invoice_rate_limits where user_id=p_user_id;
  return v_count <= p_limit;
end; $$;

create or replace function public.release_invoice_rate_limit(p_user_id uuid)
returns void language sql security definer set search_path=public as $$
  update public.invoice_rate_limits set request_count=greatest(request_count-1,0), updated_at=now() where user_id=p_user_id;
$$;

revoke all on function public.claim_invoice_rate_limit(uuid,integer,integer) from public, anon, authenticated;
revoke all on function public.release_invoice_rate_limit(uuid) from public, anon, authenticated;
grant execute on function public.claim_invoice_rate_limit(uuid,integer,integer) to service_role;
grant execute on function public.release_invoice_rate_limit(uuid) to service_role;
