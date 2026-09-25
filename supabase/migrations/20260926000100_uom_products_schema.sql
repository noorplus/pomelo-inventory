-- Pomelo Inventory - UoM and Products Schema
-- Repository migration only. Do not apply to Supabase unless explicitly requested.

create type public.uom_status as enum (
  'Active',
  'Inactive'
);

create type public.product_status as enum (
  'Active',
  'Inactive'
);

create table public.units_of_measure (
  id uuid primary key default gen_random_uuid(),

  organization_id uuid not null
    references public.organizations(id)
    on delete cascade,

  name text not null,

  status public.uom_status not null default 'Active',

  created_by uuid not null
    references auth.users(id)
    on delete restrict,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint units_of_measure_name_not_blank
    check (btrim(name) <> ''),

  constraint units_of_measure_organization_name_unique
    unique (organization_id, name),

  constraint units_of_measure_id_organization_unique
    unique (id, organization_id),

  constraint units_of_measure_created_by_organization_fk
    foreign key (organization_id, created_by)
    references public.organization_users(organization_id, user_id)
    on delete restrict
);

create table public.products (
  id uuid primary key default gen_random_uuid(),

  organization_id uuid not null
    references public.organizations(id)
    on delete cascade,

  product_name text not null,

  uom_id uuid not null,

  retail_price numeric(18,4) not null default 0,

  status public.product_status not null default 'Active',

  created_by uuid not null
    references auth.users(id)
    on delete restrict,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint products_name_not_blank
    check (btrim(product_name) <> ''),

  constraint products_retail_price_check
    check (retail_price >= 0),

  constraint products_organization_name_unique
    unique (organization_id, product_name),

  constraint products_id_organization_unique
    unique (id, organization_id),

  constraint products_uom_same_organization_fk
    foreign key (uom_id, organization_id)
    references public.units_of_measure(id, organization_id)
    on delete restrict,

  constraint products_created_by_organization_fk
    foreign key (organization_id, created_by)
    references public.organization_users(organization_id, user_id)
    on delete restrict
);

create index units_of_measure_organization_id_idx
  on public.units_of_measure(organization_id);

create index units_of_measure_created_by_idx
  on public.units_of_measure(created_by);

create index products_organization_id_idx
  on public.products(organization_id);

create index products_uom_id_idx
  on public.products(uom_id);

create index products_created_by_idx
  on public.products(created_by);

create index products_status_idx
  on public.products(organization_id, status);

create trigger units_of_measure_set_updated_at
before update on public.units_of_measure
for each row
execute function public.set_updated_at();

create trigger products_set_updated_at
before update on public.products
for each row
execute function public.set_updated_at();

alter table public.units_of_measure enable row level security;
alter table public.products enable row level security;

create policy "units_of_measure_select_member"
on public.units_of_measure
for select
to authenticated
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = units_of_measure.organization_id
      and ou.user_id = (select auth.uid())
  )
);

create policy "units_of_measure_insert_member"
on public.units_of_measure
for insert
to authenticated
with check (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = units_of_measure.organization_id
      and ou.user_id = (select auth.uid())
  )
  and created_by = (select auth.uid())
);

create policy "units_of_measure_update_member"
on public.units_of_measure
for update
to authenticated
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = units_of_measure.organization_id
      and ou.user_id = (select auth.uid())
  )
)
with check (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = units_of_measure.organization_id
      and ou.user_id = (select auth.uid())
  )
);

create policy "units_of_measure_delete_member"
on public.units_of_measure
for delete
to authenticated
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = units_of_measure.organization_id
      and ou.user_id = (select auth.uid())
  )
);

create policy "products_select_member"
on public.products
for select
to authenticated
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = products.organization_id
      and ou.user_id = (select auth.uid())
  )
);

create policy "products_insert_member"
on public.products
for insert
to authenticated
with check (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = products.organization_id
      and ou.user_id = (select auth.uid())
  )
  and created_by = (select auth.uid())
);

create policy "products_update_member"
on public.products
for update
to authenticated
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = products.organization_id
      and ou.user_id = (select auth.uid())
  )
)
with check (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = products.organization_id
      and ou.user_id = (select auth.uid())
  )
);

create policy "products_delete_member"
on public.products
for delete
to authenticated
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = products.organization_id
      and ou.user_id = (select auth.uid())
  )
);

revoke all on table public.units_of_measure from anon;
revoke all on table public.products from anon;

grant select, insert, update, delete
on table public.units_of_measure
to authenticated;

grant select, insert, update, delete
on table public.products
to authenticated;

comment on table public.units_of_measure is
  'Organization-scoped units of measure for Pomelo Inventory.';

comment on table public.products is
  'Organization-scoped product master data for Pomelo Inventory.';
