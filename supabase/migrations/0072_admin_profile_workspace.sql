-- ============================================================
-- CPAY — 0072: audited 360° admin profile workspace
-- ============================================================

create or replace function admin_get_profile_workspace(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_workspace jsonb;
begin
  if not is_admin() then raise exception 'Not authorized'; end if;
  if p_user_id is null or not exists (select 1 from profiles where id=p_user_id) then raise exception 'Profile not found'; end if;
  select jsonb_build_object(
    'profile',to_jsonb(p),
    'application',coalesce((select to_jsonb(a) from account_applications a where a.user_id=p.id order by a.created_at desc limit 1),'{}'::jsonb),
    'domains',coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'hostname',d.hostname,'purpose',d.purpose,'theme',d.theme,'is_active',d.is_active,'is_primary_site',d.is_primary_site,'scope',case when d.owner_id is null then 'global' else 'reseller' end) order by d.owner_id nulls first,d.sort_order,d.hostname) from site_domains d where d.is_active and (d.owner_id is null or d.owner_id=p.id)),'[]'::jsonb),
    'links',coalesce((select jsonb_agg(x.row order by x.created_at desc) from (select jsonb_build_object('id',l.id,'slug',l.slug,'display_name',l.display_name,'theme',l.theme,'is_active',l.is_active,'created_at',l.created_at,'payment_count',(select count(*) from payments pay where pay.payment_link_id=l.id),'settled_total',coalesce((select sum(pay.amount_settled) from payments pay where pay.payment_link_id=l.id and pay.status='settled'),0)) as row,l.created_at from payment_links l where l.user_id=p.id and l.deleted_at is null) x),'[]'::jsonb),
    'payment_summary',jsonb_build_object('count',(select count(*) from payments pay where pay.user_id=p.id),'settled_count',(select count(*) from payments pay where pay.user_id=p.id and pay.status='settled'),'settled_total',coalesce((select sum(pay.amount_settled) from payments pay where pay.user_id=p.id and pay.status='settled'),0),'last_settled_at',(select max(pay.settled_at) from payments pay where pay.user_id=p.id and pay.status='settled')),
    'withdrawals',coalesce((select jsonb_agg(x.row order by x.requested_at desc) from (select jsonb_build_object('id',w.id,'amount_requested',w.amount_requested,'amount_after_fee',w.amount_after_fee,'fee_percent',w.fee_percent,'method',w.method,'status',w.status,'admin_note',w.admin_note,'requested_at',w.requested_at,'processed_at',w.processed_at) as row,w.requested_at from withdrawals w where w.user_id=p.id order by w.requested_at desc limit 100) x),'[]'::jsonb),
    'audit',coalesce((select jsonb_agg(x.row order by x.occurred_at desc) from (select jsonb_build_object('id',al.id,'occurred_at',al.occurred_at,'actor_email',al.actor_email,'action',al.action,'old_value',al.old_value,'new_value',al.new_value,'note',al.note) as row,al.occurred_at from audit_log al where (al.subject_type='profile' and al.subject_id=p.id::text) or (al.subject_type='payment_link' and al.subject_id in (select l.id::text from payment_links l where l.user_id=p.id)) order by al.occurred_at desc limit 100) x),'[]'::jsonb)
  ) into v_workspace from profiles p where p.id=p_user_id;
  return v_workspace;
end; $$;
revoke all on function admin_get_profile_workspace(uuid) from public, anon;
grant execute on function admin_get_profile_workspace(uuid) to authenticated;
