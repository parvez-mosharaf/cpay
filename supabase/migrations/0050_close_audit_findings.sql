-- ============================================================
-- CPAY — 0050: Close two gaps a third-party audit found
-- ============================================================
-- Two real findings from an external review of 0049 and 0018. Verified
-- against the actual function bodies before fixing — a third finding in
-- the same report (that validate_link_slug() lowercases new slugs) does
-- not match the code: that trigger only lower()s for the reserved-name
-- comparison, never assigns it back to new.slug. No case-folding bug
-- exists there, so nothing about slugs changes here.
-- ============================================================


-- ============================================================
-- 1. clear_message_thread() still hard-deleted
-- ------------------------------------------------------------
-- 0049 added hide_message() and get_message_thread() so a single message
-- could be hidden without erasing it, and dropped the DELETE policy so
-- that route was closed. But clear_message_thread() — "Clear entire
-- conversation" in both panels — was never touched, and its admin branch
-- still ran a bare DELETE. The soft-delete guarantee 0049 was for could
-- be bypassed by the one button that clears everything at once.
-- ============================================================
create or replace function clear_message_thread(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() and auth.uid() <> p_user_id then
    raise exception 'Not authorized';
  end if;

  if is_admin() then
    update support_messages set deleted_by_admin = true where user_id = p_user_id;
    perform record_audit(
      'message.thread_cleared_by_admin', 'support_message_thread', p_user_id::text,
      null, null
    );
  else
    update support_messages set deleted_by_creator = true where user_id = p_user_id;
  end if;
end;
$$;

-- Belt and braces: even if some future change reintroduces a DELETE
-- policy on this table, nothing here should ever need one.
drop policy if exists "delete own messages" on support_messages;


-- ============================================================
-- 2. Manual settlement could credit more than was ever requested
-- ------------------------------------------------------------
-- admin_mark_payment() checked that p_amount_settled was positive and
-- under 100,000 — but never against the payment's own amount_requested,
-- and never against BTCPay's authoritative figure. A $1 invoice could be
-- marked settled for $50,000, which get_balance_for() would then add to
-- the creator's withdrawable balance in full.
--
-- The cap is amount_requested, with a small allowance for a payer who
-- rounds up or overpays slightly on a Lightning wallet. Anything genuinely
-- larger than that has no legitimate manual-settlement path: it should
-- come through the BTCPay webhook, which reads the amount BTCPay itself
-- reports rather than trusting a number typed into a form.
-- ============================================================
create or replace function admin_mark_payment(
  p_payment_id uuid,
  p_status text,
  p_amount_settled numeric default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment payments;
  v_is_service_role boolean;
  v_max_allowed numeric;
begin
  v_is_service_role := coalesce(
    current_setting('request.jwt.claims', true)::jsonb ->> 'role',
    ''
  ) = 'service_role';

  if not (is_admin() or v_is_service_role) then
    raise exception 'Not authorized';
  end if;

  if p_status not in ('settled', 'expired', 'invalid') then
    raise exception 'Invalid status';
  end if;

  select * into v_payment from payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;

  if v_payment.status = 'settled' then
    raise exception 'This payment is already settled';
  end if;

  if p_status = 'settled' then
    if p_amount_settled is not null and p_amount_settled <= 0 then
      raise exception 'Settled amount must be positive';
    end if;

    -- 2% headroom for a payer who rounds up; nothing beyond that without
    -- a real reason, since this figure becomes withdrawable balance.
    v_max_allowed := round(v_payment.amount_requested * 1.02, 2);
    if p_amount_settled is not null and p_amount_settled > v_max_allowed then
      raise exception
        'Settled amount $% exceeds the requested $% by more than 2%%. '
        'A genuine overpayment should be verified against BTCPay directly.',
        p_amount_settled, v_payment.amount_requested;
    end if;

    update payments
      set status = 'settled',
          settled_at = now(),
          amount_settled = coalesce(p_amount_settled, amount_requested)
      where id = p_payment_id;

    perform record_audit(
      'payment.manually_settled', 'payment', p_payment_id::text,
      jsonb_build_object('status', v_payment.status),
      jsonb_build_object('status', 'settled',
                         'amount_settled', coalesce(p_amount_settled, v_payment.amount_requested),
                         'amount_requested', v_payment.amount_requested)
    );
  else
    update payments set status = p_status where id = p_payment_id;
  end if;
end;
$$;

revoke all on function admin_mark_payment(uuid, text, numeric) from public, anon;
grant execute on function admin_mark_payment(uuid, text, numeric) to authenticated, service_role;
