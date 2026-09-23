-- ============================================================
-- CPAY — 0056: The public feed was never covered by the
-- hide-small-payments toggle
-- ============================================================
-- 0051 filtered the creator dashboard and the moderator panel; 0053
-- extended it to withdrawable balance. Neither ever touched
-- public_settled_feed() — the anonymized "recent payments" ticker shown
-- to anyone on the home page, logged out, no account needed. The
-- owner's own screenshot of it showed $4.00 and $5.00 rows sitting right
-- there in public, the exact thing this whole feature exists to hide.
--
-- Same reasoning as everywhere else this toggle already applies: a
-- payment this small is what a client sends to test that a payment
-- method works, not real activity worth showcasing — and showing it
-- publicly is arguably worse than showing it internally, since anyone
-- on the internet sees it, logged in or not.
--
-- lookup_payment_status() is deliberately NOT touched here. It requires
-- the caller to already supply the exact invoice ID or Lightning address
-- (12+ characters, refused otherwise) — a customer checking on their own
-- small payment already has that reference, and filtering it out would
-- break a legitimate self-service check without adding any real privacy
-- benefit, since nothing there is being browsed or discovered.
-- ============================================================

create or replace function public_settled_feed(p_limit int default 20)
returns table (amount numeric, settled_at timestamptz)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if coalesce((select (value)::text from app_settings
               where key = 'public_feed_enabled'), 'false') <> 'true' then
    return;
  end if;

  return query
  select p.amount_settled, p.settled_at
  from payments p
  where p.status = 'settled' and p.settled_at is not null
    -- Strictly under the threshold, matching every other filter in this
    -- feature (0053's correction: $10.00 itself still counts). A no-op
    -- when the toggle is off — small_payment_threshold() returns -1 and
    -- amount_settled is never negative.
    and p.amount_settled >= small_payment_threshold()
  order by p.settled_at desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50);
end;
$$;
