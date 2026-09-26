create extension if not exists pg_trgm with schema extensions;

create index if not exists contacts_organization_created_by_idx
  on public.contacts (organization_id, created_by);

create index if not exists products_uom_organization_idx
  on public.products (uom_id, organization_id);

create index if not exists units_of_measure_active_organization_name_idx
  on public.units_of_measure (organization_id, name)
  where status = 'Active';

create index if not exists products_product_name_trgm_idx
  on public.products using gin (product_name extensions.gin_trgm_ops);

create index if not exists contacts_name_trgm_idx
  on public.contacts using gin (name extensions.gin_trgm_ops);

create index if not exists contacts_phone_trgm_idx
  on public.contacts using gin (phone extensions.gin_trgm_ops);

create index if not exists contacts_email_trgm_idx
  on public.contacts using gin ((email::text) extensions.gin_trgm_ops);
