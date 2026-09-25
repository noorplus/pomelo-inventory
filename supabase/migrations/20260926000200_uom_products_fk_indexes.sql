-- Pomelo Inventory - UoM and Products FK indexes

create index units_of_measure_organization_created_by_idx
  on public.units_of_measure(organization_id, created_by);

create index products_organization_uom_idx
  on public.products(organization_id, uom_id);

create index products_organization_created_by_idx
  on public.products(organization_id, created_by);
