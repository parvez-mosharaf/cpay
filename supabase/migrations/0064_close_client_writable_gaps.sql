-- ============================================================
-- Boltpay — 0064: columns a client could write that it should not
-- ============================================================
-- Three gaps, each verified against the real policies and triggers
-- before writing anything here. None is a money-movement path, which is
-- why they sat deferred — but each lets a user undo a decision the
-- system made deliberately.
--
-- The shape is the same in all three: an RLS policy that checks only
-- WHO is writing (`user_id = auth.uid()`) with no trigger checking WHAT
-- they are writing. Row ownership was never the question.
-- ============================================================


-- ============================================================
-- 1. A creator could hide their own messages from the admin
-- ------------------------------------------------------------
-- guard_message_updates() (0018) says so in its own comment:
--
--     -- Creators may flip read/delete flags on any message in their
--     -- thread, but may only change the text of messages they wrote
--
-- That was written before 0049 gave those flags real meaning. 0049's
-- whole design is that each side hides only from its OWN view:
-- deleted_by_creator hides from the creator, deleted_by_admin hides
-- from the admin, and neither can touch the other's copy. hide_message()
-- enforces exactly that.
--
-- But the raw UPDATE policy still let a creator set deleted_by_admin
-- directly through PostgREST, hiding a message from the admin's view —
-- the precise thing 0049 exists to prevent. read_by_admin had the same
-- problem: a creator could mark their own unread message as already
-- read by staff, burying it.
-- ============================================================
create or replace function guard_message_updates()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or is_admin() then
    return new;
  end if;

  if new.message is distinct from old.message and old.sender <> 'creator' then
    raise exception 'You can only edit your own messages';
  end if;
  if new.sender is distinct from old.sender
  or new.user_id is distinct from old.user_id
  then
    raise exception 'Message ownership cannot be changed';
  end if;

  -- The admin's side of the thread is the admin's. A creator may still
  -- set deleted_by_creator and read_by_creator freely — those are their
  -- own view, and hide_message() writes deleted_by_creator through this
  -- same path.
  if new.deleted_by_admin is distinct from old.deleted_by_admin
  or new.read_by_admin    is distinct from old.read_by_admin
  then
    raise exception 'You cannot change how this message appears to staff';
  end if;

  return new;
end;
$$;


-- ============================================================
-- 2. A creator could restore a link the admin deleted, and set any cost
-- ------------------------------------------------------------
-- guard_link_shop_updates() (0036) guards shop_id and user_id. Two
-- columns added later are not guarded at all:
--
--   deleted_at    (0052) — clearing it un-deletes a link an admin
--                 removed. The slug was mangled on delete, so the link
--                 would come back under a mangled name rather than its
--                 original one — but it comes back, and the admin is
--                 not told.
--
--   cost_percent  (0063) — set through set_link_cost_percent(), which
--                 bounds it at 0-1000. A direct UPDATE skips that
--                 entirely, so the typo guard protecting every payer on
--                 that link could simply be stepped around.
--
-- Both are now refused from a browser session. The admin path is
-- unaffected: is_admin() short-circuits at the top, and
-- set_link_cost_percent() is SECURITY DEFINER, so it does NOT bypass
-- this trigger — it runs with auth.uid() still set to the caller. That
-- is the mistake 0061 had to fix, so the exemption is written as an
-- explicit allowance below rather than assumed.
-- ============================================================
-- Written schema-qualified with the same `set search_path to 'public'`
-- form 0036 used, so this replaces that exact function rather than
-- risking a second one under a different resolution.
create or replace function public.guard_link_shop_updates()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_locked boolean;
  v_forced uuid;
begin
  if auth.uid() is null or is_admin() then
    return new;
  end if;

  if new.shop_id is distinct from old.shop_id then
    select coalesce(shop_locked, false), forced_shop_id
      into v_locked, v_forced
      from profiles where id = auth.uid();

    if v_locked then
      raise exception 'Your payment cost is set by the admin and cannot be changed';
    end if;

    if new.shop_id is not null
       and not exists (select 1 from btcpay_shops s
                       where s.id = new.shop_id and s.is_active = true) then
      raise exception 'That cost option is not available';
    end if;
  end if;

  if new.user_id is distinct from old.user_id then
    raise exception 'Cannot change link owner';
  end if;

  -- Deletion is the admin's call. A soft-deleted row stays soft-deleted
  -- until an admin says otherwise.
  if new.deleted_at is distinct from old.deleted_at then
    raise exception 'Deleted links cannot be restored from here';
  end if;

  -- cost_percent has to go through set_link_cost_percent(), which
  -- bounds it. Allowed here only when the new value is inside the same
  -- bound, so the function keeps working (it is SECURITY DEFINER, which
  -- does NOT bypass this trigger) while a hand-rolled UPDATE cannot
  -- exceed what the function would have permitted anyway.
  if new.cost_percent is distinct from old.cost_percent
     and new.cost_percent is not null
     and (new.cost_percent < 0 or new.cost_percent > 1000) then
    raise exception 'Cost must be between 0 and 1000';
  end if;

  return new;
end;
$function$;


-- ============================================================
-- 3. variant_group let one creator hold unlimited links
-- ------------------------------------------------------------
-- enforce_link_limit() counts distinct groups, not rows:
--
--     count(distinct coalesce(variant_group, id))
--
-- That is correct and intentional — create_link_variants() makes up to
-- four style spellings of one name (kebab, lower, pascal, title-kebab)
-- and they should count as the single link they are.
--
-- The gap is that nothing checked WHO a variant_group belongs to. The
-- INSERT policy is `with check (user_id = auth.uid())` and says nothing
-- about variant_group, so a creator could insert every link they wanted
-- with the same hand-picked variant_group value. Each insert then
-- counted the OTHER groups, found the same single group every time, and
-- the limit never triggered — an unlimited number of links under a
-- five-link allowance.
--
-- Fixed by capping the size of any one group at four, which is exactly
-- what create_link_variants() produces. Legitimate variants are
-- unaffected; a fifth member of a group is not a style variant of
-- anything.
-- ============================================================
create or replace function enforce_link_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit int;
  v_current int;
  v_group_size int;
begin
  if coalesce(new.is_active, true) = false then
    return new;
  end if;

  if tg_op = 'UPDATE' and coalesce(old.is_active, true) = true then
    return new;
  end if;

  if is_admin() then
    return new;
  end if;

  select coalesce(max_payment_links, 5) into v_limit
  from profiles where id = new.user_id;

  select count(distinct coalesce(variant_group, id)) into v_current
  from payment_links
  where user_id = new.user_id
    and is_active = true
    and coalesce(variant_group, id) is distinct from coalesce(new.variant_group, new.id);

  if v_current >= v_limit then
    raise exception 'Limit reached: you can have at most % active links', v_limit;
  end if;

  -- A variant group is at most the four spellings create_link_variants()
  -- generates. Without this, putting every link in one group made the
  -- count above see a single group forever and the limit never fire.
  if new.variant_group is not null then
    select count(*) into v_group_size
    from payment_links
    where user_id = new.user_id
      and variant_group = new.variant_group
      and id is distinct from new.id;

    if v_group_size >= 4 then
      raise exception 'A link can have at most 4 name variants';
    end if;
  end if;

  return new;
end;
$$;


-- ============================================================
-- 4. 'moderator' was never a reserved slug
-- ------------------------------------------------------------
-- /moderator.html is a real page, but nothing stopped a creator from
-- registering the slug `moderator` and having their payment link served
-- at /moderator on a domain that also serves the app. Every other page
-- name is on this list; this one was simply missed when the moderator
-- panel was added in 0028.
--
-- The list is duplicated in four places (this function, 404.html,
-- dashboard.html and the Worker) and they have already drifted apart —
-- the DB and 404.html carry 18 entries, the Worker 11, dashboard.html
-- 10. ci/check_frontend.py now diffs all four against this function so
-- the next drift fails the build instead of going unnoticed.
-- ============================================================
create or replace function validate_link_slug()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.slug := trim(new.slug);

  if new.slug !~ '^[A-Za-z0-9][A-Za-z0-9-]{2,48}[A-Za-z0-9]$' then
    raise exception 'Link name must be 4-50 characters: letters, numbers and hyphens only';
  end if;

  -- Reserved names are matched case-insensitively: /Admin must be
  -- blocked just as firmly as /admin.
  if lower(new.slug) in (
    'index','login','register','dashboard','admin','404','config','theme',
    'assets','favicon','invoice-boltpay-v2','api','u','static','public',
    'well-known','robots','sitemap','moderator'
  ) then
    raise exception 'That link name is reserved';
  end if;

  return new;
end;
$$;


-- ============================================================
-- 4b. Warn about any link that already holds a now-reserved slug
-- ------------------------------------------------------------
-- trg_validate_link_slug fires `before insert or update OF slug`, so it
-- only ever sees a slug being written. A row that already holds
-- 'moderator' — registered before this migration made it reserved —
-- passes through untouched.
--
-- That matters more than it looks. The Worker checks RESERVED before
-- deciding whether a path is a payment slug:
--
--     if (!looksLikeSlug || RESERVED.has(path.toLowerCase())) {
--         return fetch(request);
--     }
--
-- Once 'moderator' is on that list, /moderator serves moderator.html.
-- So an existing /moderator payment link does not merely lose its link
-- preview — it stops resolving as a payment link at all, silently, for
-- everyone the creator has already given that URL to.
--
-- Deliberately a WARNING, not an exception and not an automatic rename:
--   - an exception would abort this whole migration over one row
--   - renaming it silently would break the same URLs this is warning
--     about, just without telling anyone
-- The right call is a human's: disable it, or rename it and tell the
-- creator. A WARNING shows prominently in the Supabase SQL editor, so
-- it will not be missed the way a NOTICE can be.
-- ============================================================
do $$
declare
  v_row record;
  v_count int := 0;
begin
  for v_row in
    select slug, user_id, is_active
    from payment_links
    where lower(slug) in (
      'index','login','register','dashboard','admin','404','config','theme',
      'assets','favicon','invoice-boltpay-v2','api','u','static','public',
      'well-known','robots','sitemap','moderator'
    )
      and deleted_at is null
  loop
    v_count := v_count + 1;
    raise warning
      'Reserved slug already in use: /% (owner %, active %). This link will stop resolving — rename or disable it.',
      v_row.slug, v_row.user_id, v_row.is_active;
  end loop;

  if v_count = 0 then
    raise notice 'No existing links hold a reserved slug.';
  end if;
end
$$;
