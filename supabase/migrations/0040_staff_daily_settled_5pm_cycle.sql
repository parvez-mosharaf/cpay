-- ============================================================
-- CPAY — 0040: Daily settled earnings (5pm–5pm Dhaka), live
-- ============================================================
-- A moderator's "daily settled" figure, per assigned creator, on a
-- 5:00 PM to 5:00 PM Dhaka cycle — not midnight to midnight. This is
-- computed live from `payments` on every call; nothing is stored,
-- nothing is cron'd, nothing needs a backup. It answers only "what
-- does the ledger say right now for this cycle", the same way the
-- rest of the payment data is read live.
--
-- Why 5pm and not midnight: this mirrors the boundary this project
-- has used for "the day" since the very first daily-report cron, and
-- is what the owner asked for specifically — a business-day cutoff
-- rather than a calendar-day one. Bangladesh has no DST, so a fixed
-- +06:00 offset (via the 'Asia/Dhaka' zone name, which is the same
-- thing but self-documenting) is safe year-round.
--
-- An admin calling this gets every creator, via handles_creator()'s
-- is_admin() branch — same sharing pattern as staff_global_stats()
-- and staff_customer_totals() in 0031.
-- ============================================================

-- Composite partial index matching this query's access pattern
-- exactly: one creator, one settled-payment time window. The existing
-- idx_payments_user_status and idx_payments_settled_at each cover half
-- of that; this one covers both at once.
create index if not exists idx_payments_user_settled_at
  on payments(user_id, settled_at)
  where status = 'settled';

create or replace function staff_daily_settled(p_days int default 14)
returns table (
  creator_id uuid,
  creator_name text,
  creator_email text,
  cycle_date date,
  cycle_start timestamptz,
  cycle_end timestamptz,
  settled numeric,
  payment_count bigint
)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_days int := least(greatest(coalesce(p_days, 14), 1), 60);
  v_cur_cycle date;
begin
  if not (is_admin() or is_moderator()) then
    raise exception 'Not authorized';
  end if;

  -- The Dhaka calendar date on which the 5pm cycle CONTAINING "now"
  -- began. Shifting now() back 17 hours before taking the date turns
  -- "5pm today through 4:59:59pm tomorrow" into one calendar date.
  v_cur_cycle := ((now() at time zone 'Asia/Dhaka') - interval '17 hours')::date;

  return query
  with days as (
    select gs::date as cycle_date
    from generate_series(v_cur_cycle - (v_days - 1), v_cur_cycle, interval '1 day') as gs
  ),
  bounds as (
    select
      d.cycle_date,
      (d.cycle_date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' as cycle_start,
      (d.cycle_date::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' + interval '24 hours' as cycle_end
    from days d
  ),
  mine as (
    select pr.id, pr.display_name, pr.email
    from profiles pr
    where pr.role = 'creator' and handles_creator(pr.id)
  )
  select
    m.id, m.display_name, m.email,
    b.cycle_date, b.cycle_start, b.cycle_end,
    coalesce(sum(p.amount_settled), 0),
    count(p.id)
  from mine m
  cross join bounds b
  left join payments p
    on p.user_id = m.id
   and p.status = 'settled'
   and p.settled_at >= b.cycle_start
   and p.settled_at <  b.cycle_end
  group by m.id, m.display_name, m.email, b.cycle_date, b.cycle_start, b.cycle_end
  order by b.cycle_date desc, m.display_name;
end;
$$;

revoke all on function staff_daily_settled(int) from public, anon;
grant execute on function staff_daily_settled(int) to authenticated;
