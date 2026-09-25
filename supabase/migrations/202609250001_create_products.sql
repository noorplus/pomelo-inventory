create extension if not exists pgcrypto;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique,
  name text not null,
  description text,
  unit text not null default 'pcs',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists products_name_idx on public.products (name);
create index if not exists products_active_idx on public.products (is_active);

alter table public.products enable row level security;
