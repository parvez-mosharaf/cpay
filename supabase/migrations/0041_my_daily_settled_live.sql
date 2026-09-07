-- ============================================================
-- Boltpay — 0041: Creator's own daily settled, live (5pm–5pm Dhaka)
-- ============================================================
-- Same live, nothing-stored design as staff_daily_settled() (0040) and
-- admin_daily_settled() (0039), scoped to whoever is calling it. Any
-- authenticated creator may see their OWN daily settled history — no
-- is_admin()/is_moderator() check, because there is nothing to guard:
-- auth.uid() is hard-coded into the query, so a creator can never see
-- anyone else's numbers through this function no matter what argument
-- is passed, because no argument selects the creator at all.
-- ============================================================

create or replace function my_daily_settled(p_days int default 14)
returns table (
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
  v_uid uuid := auth.uid();
  v_days int := least(greatest(coalesce(p_days, 14), 1), 60);
  v_cur_cycle date;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  -- Same 17-hour shift as staff_daily_settled() / admin_daily_settled():
  -- the Dhaka calendar date on which the 5pm cycle containing "now" began.
  v_cur_cycle := ((now() at time zone 'Asia/Dhaka') - interval '17 hours')::date;

  return query
  with days as (
    select gs::date as d
    from generate_series(v_cur_cycle - (v_days - 1), v_cur_cycle, interval '1 day') as gs
  ),
  bounds as (
    select
      d.d as cycle_date,
      (d.d::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' as cycle_start,
      (d.d::text || ' 17:00')::timestamp at time zone 'Asia/Dhaka' + interval '24 hours' as cycle_end
    from days d
  )
  select
    b.cycle_date, b.cycle_start, b.cycle_end,
    coalesce(sum(p.amount_settled), 0),
    count(p.id)
  from bounds b
  left join payments p
    on p.user_id = v_uid
   and p.status = 'settled'
   and p.settled_at >= b.cycle_start
   and p.settled_at <  b.cycle_end
  group by b.cycle_date, b.cycle_start, b.cycle_end
  order by b.cycle_date desc;
end;
$$;

revoke all on function my_daily_settled(int) from public, anon;
grant execute on function my_daily_settled(int) to authenticated;
