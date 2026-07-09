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
  source_path text not null,
  format text not null check (format in ('mp3', 'wav')),
  created_at timestamptz not null default now()
);

create table if not exists api.mastering_requests (
  id uuid primary key default gen_random_uuid(),
  parent_request_id uuid references api.mastering_requests(id),
  reference_track_id uuid not null references api.tracks(id),
  target_track_id uuid not null references api.tracks(id),
  output_path text not null,
  submitted_plan jsonb,
  status text not null default 'queued'
    check (status in ('queued', 'analyzing', 'ready', 'rendering', 'complete', 'failed')),
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists api.analysis_results (
  id uuid primary key default gen_random_uuid(),
  mastering_request_id uuid not null references api.mastering_requests(id),
  track_id uuid not null references api.tracks(id),
  role text not null check (role in ('reference', 'target')),
  metrics jsonb not null,
  created_at timestamptz not null default now(),
  unique (mastering_request_id, role)
);

create table if not exists api.mastering_plans (
  id uuid primary key default gen_random_uuid(),
  mastering_request_id uuid not null unique references api.mastering_requests(id),
  plan jsonb not null,
  created_at timestamptz not null default now()
);

create table if not exists api.render_artifacts (
  id uuid primary key default gen_random_uuid(),
  mastering_request_id uuid not null unique references api.mastering_requests(id),
  output_path text not null,
  report jsonb not null,
  created_at timestamptz not null default now()
);

create index if not exists mastering_requests_claim_idx
  on api.mastering_requests (created_at, id)
  where status = 'queued';

create or replace function api.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists mastering_requests_touch_updated_at on api.mastering_requests;
create trigger mastering_requests_touch_updated_at
before update on api.mastering_requests
for each row execute function api.touch_updated_at();

create or replace function api.submit_mastering_request(
  reference_path text,
  reference_format text,
  target_path text,
  target_format text,
  output_path text,
  submitted_plan jsonb default null,
  parent_request_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = api, public
as $$
declare
  reference_id uuid;
  target_id uuid;
  request_id uuid;
begin
  if reference_format not in ('mp3', 'wav') then
    raise exception 'unsupported reference format: %', reference_format;
  end if;
  if target_format not in ('mp3', 'wav') then
    raise exception 'unsupported target format: %', target_format;
  end if;
  if submitted_plan is not null and parent_request_id is null then
    raise exception 'edited plan requests require parent_request_id';
  end if;

  insert into api.tracks (source_path, format)
  values (reference_path, reference_format)
  returning id into reference_id;

  insert into api.tracks (source_path, format)
  values (target_path, target_format)
  returning id into target_id;

  insert into api.mastering_requests (
    parent_request_id,
    reference_track_id,
    target_track_id,
    output_path,
    submitted_plan
  ) values (
    parent_request_id,
    reference_id,
    target_id,
    output_path,
    submitted_plan
  ) returning id into request_id;

  return request_id;
end;
$$;

create or replace function api.claim_mastering_request()
returns jsonb
language plpgsql
security definer
set search_path = api, public
as $$
declare
  claimed_id uuid;
  claimed jsonb;
begin
  select id
  into claimed_id
  from api.mastering_requests
  where status = 'queued'
  order by created_at, id
  for update skip locked
  limit 1;

  if claimed_id is null then
    return null;
  end if;

  update api.mastering_requests
  set status = 'analyzing', error = null
  where id = claimed_id;

  select jsonb_build_object(
    'id', request.id,
    'parent_request_id', request.parent_request_id,
    'reference_track_id', request.reference_track_id,
    'target_track_id', request.target_track_id,
    'reference_path', reference.source_path,
    'target_path', target.source_path,
    'output_path', request.output_path,
    'submitted_plan', request.submitted_plan,
    'status', request.status
  )
  into claimed
  from api.mastering_requests request
  join api.tracks reference on reference.id = request.reference_track_id
  join api.tracks target on target.id = request.target_track_id
  where request.id = claimed_id;

  return claimed;
end;
$$;

revoke all on function api.submit_mastering_request(text, text, text, text, text, jsonb, uuid)
  from public;
revoke all on function api.claim_mastering_request() from public;

grant usage on schema api to web_anon;
grant select on api.tracks to web_anon;
grant select, update on api.mastering_requests to web_anon;
grant insert, select on api.analysis_results to web_anon;
grant insert, select on api.mastering_plans to web_anon;
grant insert, select on api.render_artifacts to web_anon;
grant execute on function api.submit_mastering_request(text, text, text, text, text, jsonb, uuid)
  to web_anon;
grant execute on function api.claim_mastering_request() to web_anon;
