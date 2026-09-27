create index if not exists account_transactions_created_by_organization_idx
  on public.account_transactions (organization_id, created_by);

create index if not exists expense_categories_created_by_organization_idx
  on public.expense_categories (organization_id, created_by);

create index if not exists expenses_created_by_organization_idx
  on public.expenses (organization_id, created_by);

create index if not exists inventory_movements_created_by_organization_idx
  on public.inventory_movements (organization_id, created_by);

create index if not exists inventory_movements_product_organization_idx
  on public.inventory_movements (product_id, organization_id);

create index if not exists payment_allocations_created_by_organization_idx
  on public.payment_allocations (organization_id, created_by);

create index if not exists payment_allocations_organization_id_idx
  on public.payment_allocations (organization_id);

create index if not exists payments_created_by_organization_idx
  on public.payments (organization_id, created_by);

create index if not exists purchase_items_created_by_organization_idx
  on public.purchase_items (organization_id, created_by);

create index if not exists purchase_items_organization_id_idx
  on public.purchase_items (organization_id);

create index if not exists purchases_created_by_organization_idx
  on public.purchases (organization_id, created_by);

create index if not exists sale_items_created_by_organization_idx
  on public.sale_items (organization_id, created_by);

create index if not exists sale_items_organization_id_idx
  on public.sale_items (organization_id);

create index if not exists sales_created_by_organization_idx
  on public.sales (organization_id, created_by);