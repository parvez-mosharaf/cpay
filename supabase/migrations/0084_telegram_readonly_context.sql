-- ============================================================
-- CPAY — 0084: Telegram read-only intelligence context
-- ============================================================
-- No browser or Telegram client can execute this function. It is granted
-- only to Supabase's service_role, and is called by the telegram-report
-- Edge Function after that function authenticates its shared secret.

create or replace function public.telegram_context(
  p_range text default 'today',
  p_days int default 7
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_range text := lower(trim(coalesce(p_range, 'today')));
  v_days int := least(greatest(coalesce(p_days, 7), 1), 30);
  v_cycle_date date := ((now() at time zone 'Asia/Dhaka') - interval '17 hours')::date;
  v_start timestamptz;
  v_end timestamptz;
  v_margin numeric;
  v_total_settled numeric := 0;
  v_admin_profit numeric := 0;
  v_total_withdrawn numeric := 0;
  v_pending_count bigint := 0;
  v_pending_amount numeric := 0;
  v_payment_count bigint := 0;
  v_active_creators bigint := 0;
  v_creators jsonb := '[]'::jsonb;
  v_locations jsonb := '[]'::jsonb;
  v_payments jsonb := '[]'::jsonb;
  v_withdrawals jsonb := '[]'::jsonb;
  v_daily jsonb := '[]'::jsonb;
begin
  if v_range not in ('today', '7d', '30d', 'all') then
    raise exception 'Invalid report range';
  end if;

  if v_range = 'today' then v_days := 1;
  elsif v_range = '7d' then v_days := 7;
  elsif v_range = '30d' then v_days := 30;
  end if;

  if v_range = 'all' then
    v_start := null;
    v_end := null;
  else
    v_start := ((v_cycle_date - (v_days - 1))::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka';
    v_end := (v_cycle_date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' + interval '24 hours';
  end if;

  select coalesce((value->>'percent')::numeric, 7.7)
    into v_margin
  from app_settings where key = 'profit_margin_percent';

  select
    coalesce(sum(p.amount_settled) filter (where p.status = 'settled'), 0),
    count(*) filter (where p.status = 'settled'),
    count(distinct p.user_id) filter (where p.status = 'settled')
  into v_total_settled, v_payment_count, v_active_creators
  from payments p
  where (v_start is null or p.settled_at >= v_start)
    and (v_end is null or p.settled_at < v_end);

  select
    coalesce(sum(w.amount_requested - w.amount_after_fee) filter (where w.status = 'paid'), 0),
    coalesce(sum(w.amount_after_fee) filter (where w.status = 'paid'), 0),
    count(*) filter (where w.status in ('pending', 'approved')),
    coalesce(sum(w.amount_requested) filter (where w.status in ('pending', 'approved')), 0)
  into v_admin_profit, v_total_withdrawn, v_pending_count, v_pending_amount
  from withdrawals w
  where (v_start is null or w.processed_at >= v_start or w.status in ('pending', 'approved'))
    and (v_end is null or w.processed_at < v_end or w.status in ('pending', 'approved'));

  select coalesce(jsonb_agg(x.row order by x.settled desc), '[]'::jsonb)
    into v_creators
  from (
    select jsonb_build_object(
      'name', coalesce(nullif(trim(pr.display_name), ''), 'Unnamed creator'),
      'role', pr.role,
      'settled', coalesce(pay.settled, 0),
      'withdrawn', coalesce(wd.withdrawn, 0),
      'pendingWithdrawals', coalesce(wd.pending_amount, 0),
      'paymentCount', coalesce(pay.payment_count, 0),
      'pendingPayments', coalesce(pay.pending_amount, 0)
    ) as row,
    coalesce(pay.settled, 0) as settled
    from profiles pr
    left join lateral (
      select
        coalesce(sum(p.amount_settled) filter (where p.status = 'settled' and (v_start is null or p.settled_at >= v_start) and (v_end is null or p.settled_at < v_end)), 0) as settled,
        count(*) filter (where p.status = 'settled' and (v_start is null or p.settled_at >= v_start) and (v_end is null or p.settled_at < v_end)) as payment_count,
        coalesce(sum(p.amount_requested) filter (where p.status in ('new', 'pending') and (v_start is null or p.created_at >= v_start) and (v_end is null or p.created_at < v_end)), 0) as pending_amount
      from payments p
      where p.user_id = pr.id
    ) pay on true
    left join lateral (
      select
        coalesce(sum(w.amount_after_fee) filter (where w.status = 'paid' and (v_start is null or w.processed_at >= v_start) and (v_end is null or w.processed_at < v_end)), 0) as withdrawn,
        coalesce(sum(w.amount_requested) filter (where w.status in ('pending', 'approved')), 0) as pending_amount
      from withdrawals w
      where w.user_id = pr.id
    ) wd on true
    where pr.role in ('creator', 'moderator')
      and (coalesce(pay.settled, 0) > 0 or coalesce(wd.withdrawn, 0) > 0 or coalesce(wd.pending_amount, 0) > 0)
  ) x;

  select coalesce(jsonb_agg(x.row order by x.payment_count desc), '[]'::jsonb)
    into v_locations
  from (
    select jsonb_build_object(
      'country', coalesce(nullif(trim(p.customer_country), ''), 'Unknown'),
      'city', coalesce(nullif(trim(p.customer_city), ''), 'Unknown'),
      'paymentCount', count(*),
      'settled', coalesce(sum(p.amount_settled), 0)
    ) as row, count(*) as payment_count
    from payments p
    where p.status = 'settled'
      and (v_start is null or p.settled_at >= v_start)
      and (v_end is null or p.settled_at < v_end)
      and nullif(trim(coalesce(p.customer_country, '')), '') is not null
    group by p.customer_country, p.customer_city
    having count(*) >= 2
    order by count(*) desc
    limit 20
  ) x;

  select coalesce(jsonb_agg(row order by settled_at desc), '[]'::jsonb)
    into v_payments
  from (
    select jsonb_build_object(
      'creator', coalesce(nullif(trim(pr.display_name), ''), 'Unnamed creator'),
      'amount', p.amount_settled,
      'status', p.status,
      'method', p.method,
      'settledAt', p.settled_at,
      'country', p.customer_country,
      'city', p.customer_city
    ) as row, p.settled_at
    from payments p
    join profiles pr on pr.id = p.user_id
    where (v_start is null or p.settled_at >= v_start or p.created_at >= v_start)
      and (v_end is null or p.settled_at < v_end or p.created_at < v_end)
    order by p.settled_at desc nulls last
    limit 25
  ) x;

  select coalesce(jsonb_agg(row order by requested_at desc), '[]'::jsonb)
    into v_withdrawals
  from (
    select jsonb_build_object(
      'creator', coalesce(nullif(trim(pr.display_name), ''), 'Unnamed creator'),
      'amountRequested', w.amount_requested,
      'amountAfterFee', w.amount_after_fee,
      'status', w.status,
      'method', w.method,
      'requestedAt', w.requested_at,
      'processedAt', w.processed_at
    ) as row, w.requested_at
    from withdrawals w
    join profiles pr on pr.id = w.user_id
    where (v_start is null or w.processed_at >= v_start or w.status in ('pending', 'approved'))
      and (v_end is null or w.processed_at < v_end or w.status in ('pending', 'approved'))
    order by w.requested_at desc
    limit 25
  ) x;

  if v_range <> 'all' then
    select coalesce(jsonb_agg(row order by cycle_date desc), '[]'::jsonb)
      into v_daily
    from (
      select jsonb_build_object(
        'cycleDate', d.cycle_date,
        'cycleStart', d.cycle_start,
        'cycleEnd', d.cycle_end,
        'settled', coalesce((select sum(p.amount_settled) from payments p where p.status = 'settled' and p.settled_at >= d.cycle_start and p.settled_at < d.cycle_end), 0),
        'paymentCount', coalesce((select count(*) from payments p where p.status = 'settled' and p.settled_at >= d.cycle_start and p.settled_at < d.cycle_end), 0),
        'adminProfit', coalesce((select round(sum(w.amount_requested - w.amount_after_fee), 4) from withdrawals w where w.status = 'paid' and w.processed_at >= d.cycle_start and w.processed_at < d.cycle_end), 0)
      ) as row, d.cycle_date
      from (
        select gs::date as cycle_date,
          (gs::date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' as cycle_start,
          (gs::date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' + interval '24 hours' as cycle_end
        from generate_series(v_cycle_date - (v_days - 1), v_cycle_date, interval '1 day') gs
      ) d
    ) x;
  end if;

  return jsonb_build_object(
    'generatedAt', now(),
    'range', v_range,
    'timezone', 'Asia/Dhaka',
    'cycleBoundary', '17:00–17:00 Asia/Dhaka',
    'global', jsonb_build_object(
      'totalSettled', v_total_settled,
      'adminProfit', round(v_admin_profit, 4),
      'totalWithdrawn', v_total_withdrawn,
      'pendingWithdrawalsCount', v_pending_count,
      'pendingWithdrawalsAmount', v_pending_amount,
      'paymentCount', v_payment_count,
      'activeCreators', v_active_creators,
      'calculatedNodeBalance', round(v_total_settled * (1 + v_margin / 100.0), 4),
      'profitMarginPercent', v_margin
    ),
    'daily', v_daily,
    'creators', v_creators,
    'locations', v_locations,
    'recentPayments', v_payments,
    'recentWithdrawals', v_withdrawals,
    'privacy', jsonb_build_object(
      'customerLocations', 'Only grouped locations with at least two settled payments are included',
      'withdrawalDestinations', 'Never included',
      'privateSocialData', 'Never collected'
    )
  );
end;
$$;

revoke all on function public.telegram_context(text, int) from public, anon, authenticated;
grant execute on function public.telegram_context(text, int) to service_role;
