-- ============================================================
-- Minimal Supabase-shaped bootstrap for CI
-- ============================================================
-- A bare postgres image has none of the roles, schemas or helpers the
-- migrations assume. Without these, every `grant ... to authenticated`
-- fails and the run tells you nothing about your actual SQL.
--
-- This is enough to prove ORDER and SYNTAX — that all migrations apply
-- cleanly, in sequence, to an empty database. It does not simulate RLS
-- behaviour, and is not meant to.
-- ============================================================

-- Roles the migrations grant to. NOLOGIN: nothing connects as these here.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator noinherit login password 'postgres';
  end if;
end $$;

grant anon, authenticated, service_role to authenticator;
grant usage on schema public to anon, authenticated, service_role;

create extension if not exists pgcrypto;
-- 0001 does `create extension if not exists "uuid-ossp"`. It ships with
-- the postgres image's contrib package but is not enabled by default.
create extension if not exists "uuid-ossp";

-- auth schema: the migrations reference auth.users and auth.uid().
create schema if not exists auth;
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz default now()
);
create or replace function auth.uid() returns uuid
  language sql stable as $fn$ select null::uuid $fn$;
create or replace function auth.role() returns text
  language sql stable as $fn$ select 'authenticated'::text $fn$;
create or replace function auth.jwt() returns jsonb
  language sql stable as $fn$ select '{}'::jsonb $fn$;

-- vault: the cron trigger migrations read secrets from here. They already
-- skip themselves when the secrets are absent, so an empty table is the
-- correct shape for CI.
create schema if not exists vault;
create table if not exists vault.decrypted_secrets (
  id uuid default gen_random_uuid(),
  name text primary key,
  decrypted_secret text
);

-- cron: the scheduling migrations guard on `pg_extension`, so with pg_cron
-- absent they log a notice and skip. The table exists only so any
-- reference to cron.job resolves.
create schema if not exists cron;
create table if not exists cron.job (
  jobid bigserial primary key,
  jobname text,
  schedule text,
  command text,
  active boolean default true
);

-- The realtime publication. 0005 does
--     alter publication supabase_realtime add table payments
-- which is how Supabase exposes a table over websockets. A bare Postgres
-- has no such publication, so that ALTER is what stopped the CI run at
-- migration 5 of 48.
--
-- Created empty here; the migrations add their own tables to it. No
-- FOR ALL TABLES, because that would silently include tables the real
-- project deliberately keeps out of realtime.
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

-- pg_net's schema. Every migration that calls net.http_post() already
-- guards on the extension being present and skips when it is not, so this
-- is belt-and-braces rather than load-bearing.
create schema if not exists net;

-- Supabase's own migration bookkeeping, so nothing trips over its absence.
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version text primary key,
  name text,
  statements text[]
);
