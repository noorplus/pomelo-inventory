-- Products master table.
-- This migration is intentionally NOT applied to any Supabase project.

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  sku text not null,
  name text not null,
  description text,
  barcode text,
  unit text not null default 'pcs',
  min_stock numeric(18,3) not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint products_sku_unique unique (sku),
  constraint products_barcode_unique unique (barcode),
  constraint products_name_not_blank check (btrim(name) <> ''),
  constraint products_sku_not_blank check (btrim(sku) <> ''),
  constraint products_unit_not_blank check (btrim(unit) <> ''),
  constraint products_min_stock_non_negative check (min_stock >= 0)
);

alter table public.products enable row level security;

create index if not exists products_name_idx on public.products (name);
create index if not exists products_barcode_idx on public.products (barcode);
create index if not exists products_active_idx on public.products (is_active);

create or replace function public.set_products_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists products_set_updated_at on public.products;

create trigger products_set_updated_at
before update on public.products
for each row
execute function public.set_products_updated_at();
