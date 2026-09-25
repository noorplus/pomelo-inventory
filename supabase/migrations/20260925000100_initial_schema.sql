-- Pomelo Inventory - Initial Production Schema
-- PostgreSQL / Supabase
-- Repository migration only. Do not apply to Supabase unless explicitly requested.
-- Metadata strategy:
--   * profiles.metadata stores non-authoritative user profile extensions.
--   * organizations.metadata stores non-authoritative organization extensions/integrations.
--   * Authorization is never based on JSON metadata; use relational columns and RLS.
--   * Passwords and authentication secrets remain exclusively in auth.users.

create extension if not exists citext;

create type public.organization_status as enum (
  'Active',
  'Inactive',
  'Suspend'
);

create sequence public.organization_number_seq
  as integer
  minvalue 100000
  maxvalue 999999
  start with 100000
  increment by 1
  no cycle;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint profiles_full_name_not_blank
    check (btrim(full_name) <> ''),
  constraint profiles_metadata_object
    check (jsonb_typeof(metadata) = 'object')
);

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  organization_number integer not null default nextval('public.organization_number_seq'),
  organization_name citext not null,
  phone_number text not null,
  email citext not null,
  address text not null,
  tin text,
  bin text,
  status public.organization_status not null default 'Active',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint organizations_number_unique unique (organization_number),
  constraint organizations_number_six_digits
    check (organization_number between 100000 and 999999),
  constraint organizations_name_unique unique (organization_name),
  constraint organizations_phone_unique unique (phone_number),
  constraint organizations_email_unique unique (email),
  constraint organizations_name_not_blank
    check (btrim(organization_name::text) <> ''),
  constraint organizations_phone_not_blank
    check (btrim(phone_number) <> ''),
  constraint organizations_email_not_blank
    check (btrim(email::text) <> ''),
  constraint organizations_address_not_blank
    check (btrim(address) <> ''),
  constraint organizations_metadata_object
    check (jsonb_typeof(metadata) = 'object')
);

create table public.organization_users (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  primary key (organization_id, user_id),

  constraint organization_users_metadata_object
    check (jsonb_typeof(metadata) = 'object')
);

create index organization_users_user_id_idx
  on public.organization_users(user_id);

create index organizations_status_idx
  on public.organizations(status);

create index organizations_metadata_gin_idx
  on public.organizations using gin (metadata);

create index profiles_metadata_gin_idx
  on public.profiles using gin (metadata);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
before update on public.profiles
for each row
execute function public.set_updated_at();

create trigger organizations_set_updated_at
before update on public.organizations
for each row
execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, full_name)
  values (
    new.id,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(btrim(new.email), ''),
      'User'
    )
  )
  on conflict (id) do update
    set full_name = excluded.full_name,
        updated_at = now();

  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();

create or replace function public.create_organization(
  p_organization_name text,
  p_phone_number text,
  p_email text,
  p_address text,
  p_tin text default null,
  p_bin text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns public.organizations
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization public.organizations;
  v_name text := regexp_replace(btrim(p_organization_name), '[[:space:]]+', ' ', 'g');
  v_phone text := btrim(p_phone_number);
  v_email text := lower(btrim(p_email));
  v_address text := btrim(p_address);
  v_tin text := nullif(btrim(p_tin), '');
  v_bin text := nullif(btrim(p_bin), '');
  v_metadata jsonb := coalesce(p_metadata, '{}'::jsonb);
begin
  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Authentication required';
  end if;

  if jsonb_typeof(v_metadata) <> 'object' then
    raise exception using
      errcode = '22023',
      message = 'Organization metadata must be a JSON object';
  end if;

  if v_name = '' then
    raise exception using errcode = '22023', message = 'Organization name is required';
  end if;

  if v_phone = '' then
    raise exception using errcode = '22023', message = 'Phone number is required';
  end if;

  if v_email = '' then
    raise exception using errcode = '22023', message = 'Organization email is required';
  end if;

  if v_address = '' then
    raise exception using errcode = '22023', message = 'Address is required';
  end if;

  insert into public.organizations (
    organization_name,
    phone_number,
    email,
    address,
    tin,
    bin,
    metadata
  )
  values (
    v_name,
    v_phone,
    v_email,
    v_address,
    v_tin,
    v_bin,
    v_metadata
  )
  returning * into v_organization;

  insert into public.organization_users (organization_id, user_id)
  values (v_organization.id, v_user_id);

  return v_organization;
exception
  when unique_violation then
    if exists (
      select 1 from public.organizations
      where organization_name = v_name::citext
    ) then
      raise exception using errcode = '23505', message = 'organization_name already exists';
    elsif exists (
      select 1 from public.organizations
      where phone_number = v_phone
    ) then
      raise exception using errcode = '23505', message = 'phone_number already exists';
    elsif exists (
      select 1 from public.organizations
      where email = v_email::citext
    ) then
      raise exception using errcode = '23505', message = 'email already exists';
    else
      raise;
    end if;
end;
$$;

revoke all on function public.create_organization(text, text, text, text, text, text, jsonb)
  from public, anon;

grant execute on function public.create_organization(text, text, text, text, text, text, jsonb)
  to authenticated;

alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
alter table public.organization_users enable row level security;

create policy "profiles_select_own"
on public.profiles
for select
to authenticated
using ((select auth.uid()) = id);

create policy "profiles_update_own"
on public.profiles
for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

create policy "organizations_select_member"
on public.organizations
for select
to authenticated
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = organizations.id
      and ou.user_id = (select auth.uid())
  )
);

create policy "organization_users_select_own"
on public.organization_users
for select
to authenticated
using ((select auth.uid()) = user_id);

revoke all on table public.profiles from anon;
revoke all on table public.organizations from anon;
revoke all on table public.organization_users from anon;

grant select, update on table public.profiles to authenticated;
grant select on table public.organizations to authenticated;
grant select on table public.organization_users to authenticated;

revoke insert, update, delete on table public.organizations from authenticated;
revoke insert, update, delete on table public.organization_users from authenticated;
revoke delete on table public.profiles from authenticated;

comment on table public.profiles is
  'Application profile linked one-to-one with Supabase Auth users. Authentication credentials remain in auth.users.';

comment on column public.profiles.metadata is
  'Non-authoritative extensibility metadata. Never use this field for authorization decisions.';

comment on table public.organizations is
  'Tenant organizations for the Pomelo Inventory application.';

comment on column public.organizations.organization_number is
  'Six-digit human-facing organization identifier generated from organization_number_seq.';

comment on column public.organizations.metadata is
  'Non-authoritative organization metadata for future integrations and extensions.';

comment on table public.organization_users is
  'Many-to-many membership relation between authenticated users and organizations.';

comment on column public.organization_users.metadata is
  'Non-authoritative membership metadata. Roles and authorization should use explicit relational columns when introduced.';
