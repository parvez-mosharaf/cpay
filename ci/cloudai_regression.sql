\set ON_ERROR_STOP on
begin;
select '11111111-1111-1111-1111-111111111111'::uuid as admin_id \gset
select '22222222-2222-2222-2222-222222222222'::uuid as creator_id \gset
insert into auth.users(id, email) values (:'admin_id', 'admin@test.invalid'), (:'creator_id', 'creator@test.invalid');
update profiles set email = 'admin@test.invalid', display_name = 'Test Admin', role = 'admin' where id = :'admin_id';
update profiles set email = 'creator@test.invalid', display_name = 'Test Creator', role = 'creator' where id = :'creator_id';
create or replace function auth.uid() returns uuid language sql stable as $$ select '11111111-1111-1111-1111-111111111111'::uuid $$;
insert into payment_links(user_id, slug, display_name, is_active) values (:'creator_id', 'MixedCaseLink', 'Mixed Case Link', true);
insert into payments(payment_link_id, user_id, btcpay_invoice_id, method, amount_requested, status, expires_at)
select id, :'creator_id', 'cloudai-runtime-invoice', 'lightning', 10, 'new', now() + interval '1 hour' from payment_links where slug = 'MixedCaseLink';
do $$ begin
  begin
    perform admin_mark_payment((select id from payments where btcpay_invoice_id = 'cloudai-runtime-invoice'), 'settled', 1000);
    raise exception 'over-credit was accepted';
  exception when others then
    if sqlerrm = 'over-credit was accepted' then raise; end if;
  end;
end $$;
insert into support_messages(user_id, sender, message) values (:'creator_id', 'creator', 'creator message'), (:'creator_id', 'admin', 'admin message');
select clear_message_thread(:'creator_id');
do $$ declare v_count integer; v_hidden integer; begin
  select count(*), count(*) filter (where deleted_by_admin) into v_count, v_hidden from support_messages where user_id = '22222222-2222-2222-2222-222222222222'::uuid;
  if v_count <> 2 or v_hidden <> 2 then raise exception 'messages were not soft-hidden'; end if;
end $$;
rollback;
select 'Cloud AI archive SQL runtime checks passed' as result;
