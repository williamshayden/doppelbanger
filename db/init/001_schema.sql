create extension if not exists pgcrypto;

do $$
begin
  create role web_anon nologin;
exception when duplicate_object then
  null;
end $$;

create schema if not exists api;

create table if not exists api.tracks (
  id uuid primary key default gen_random_uuid(),
  role text not null check (role in ('reference', 'target')),
  source_path text not null,
  format text not null check (format in ('mp3', 'wav')),
  created_at timestamptz not null default now()
);

create table if not exists api.mastering_requests (
  id uuid primary key default gen_random_uuid(),
  reference_track_id uuid not null references api.tracks(id),
  target_track_id uuid not null references api.tracks(id),
  tuning jsonb not null default '{}'::jsonb,
  status text not null default 'queued'
    check (status in ('queued', 'analyzing', 'ready', 'rendering', 'complete', 'failed')),
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists api.analysis_results (
  id uuid primary key default gen_random_uuid(),
  track_id uuid not null references api.tracks(id),
  metrics jsonb not null,
  created_at timestamptz not null default now()
);

create table if not exists api.render_artifacts (
  id uuid primary key default gen_random_uuid(),
  mastering_request_id uuid not null references api.mastering_requests(id),
  output_path text not null,
  report jsonb not null,
  created_at timestamptz not null default now()
);

grant usage on schema api to web_anon;
grant select, insert, update, delete on all tables in schema api to web_anon;
