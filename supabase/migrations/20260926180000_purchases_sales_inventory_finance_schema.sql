-- Pomelo Inventory - Purchasing, Sales, Inventory & Finance
-- Repository migration only. Do not apply to Supabase unless explicitly requested.
--
-- 11 tables:
-- purchases, purchase_items, sales, sale_items, stock, inventory_movements,
-- account_transactions, payments, payment_allocations, expenses, expense_categories.
--
-- Audit rule:
-- User-created business records carry created_by.
-- stock is system-maintained balance and inventory_movements/account_transactions/payment_allocations
-- are controlled ledger/operation records; their creator is captured where operationally relevant.
--
-- Contacts remain the shared Customer/Supplier master.
-- Invoice numbers are generated when a Draft invoice is first inserted.
-- No additional table is introduced for numbering.
-- Schema freeze: future workflow integrity belongs in controlled RPC/service operations.

create type public.invoice_status as enum ('Draft', 'Confirmed', 'Cancelled');
create type public.payment_type as enum ('In', 'Out');
create type public.payment_method as enum ('Cash', 'Bank', 'Mobile Banking', 'Card', 'Other');
create type public.payment_status as enum ('Draft', 'Confirmed', 'Cancelled');
create type public.expense_status as enum ('Draft', 'Confirmed', 'Cancelled');
create type public.inventory_movement_direction as enum ('In', 'Out');
create type public.inventory_movement_type as enum ('Purchase', 'Sale', 'Adjustment', 'Opening', 'Return');
create type public.expense_category_status as enum ('Active', 'Inactive');

create or replace function public.next_purchase_invoice_no(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_next integer;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id = p_organization_id and ou.user_id = (select auth.uid())
  ) then raise exception 'User is not a member of this organization'; end if;

  perform 1 from public.organizations o where o.id = p_organization_id for update;
  if not found then raise exception 'Organization not found'; end if;

  select coalesce(max(invoice_no::integer), 0) + 1 into v_next
  from public.purchases where organization_id = p_organization_id;

  if v_next > 999999 then raise exception 'Purchase invoice number limit reached'; end if;
  return lpad(v_next::text, 6, '0');
end;
$$;

create or replace function public.next_sales_invoice_no(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_next integer;
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id = p_organization_id and ou.user_id = (select auth.uid())
  ) then raise exception 'User is not a member of this organization'; end if;

  perform 1 from public.organizations o where o.id = p_organization_id for update;
  if not found then raise exception 'Organization not found'; end if;

  select coalesce(max(invoice_no::integer), 0) + 1 into v_next
  from public.sales where organization_id = p_organization_id;

  if v_next > 999999 then raise exception 'Sales invoice number limit reached'; end if;
  return lpad(v_next::text, 6, '0');
end;
$$;

revoke all on function public.next_purchase_invoice_no(uuid) from public;
revoke all on function public.next_sales_invoice_no(uuid) from public;
grant execute on function public.next_purchase_invoice_no(uuid) to authenticated;
grant execute on function public.next_sales_invoice_no(uuid) to authenticated;

create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  status public.expense_category_status not null default 'Active',
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint expense_categories_name_not_blank check (btrim(name) <> ''),
  constraint expense_categories_organization_name_unique unique (organization_id, name),
  constraint expense_categories_id_organization_unique unique (id, organization_id),
  constraint expense_categories_created_by_organization_fk
    foreign key (organization_id, created_by)
    references public.organization_users(organization_id, user_id) on delete restrict
);

create table public.purchases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  invoice_no text not null,
  contact_id uuid not null,
  invoice_date date not null default current_date,
  status public.invoice_status not null default 'Draft',
  subtotal numeric(18,4) not null default 0,
  discount numeric(18,4) not null default 0,
  tax numeric(18,4) not null default 0,
  total numeric(18,4) not null default 0,
  notes text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint purchases_invoice_no_format check (invoice_no ~ '^[0-9]{6}$'),
  constraint purchases_invoice_no_unique unique (organization_id, invoice_no),
  constraint purchases_id_organization_unique unique (id, organization_id),
  constraint purchases_contact_same_organization_fk
    foreign key (contact_id, organization_id)
    references public.contacts(id, organization_id) on delete restrict,
  constraint purchases_created_by_organization_fk
    foreign key (organization_id, created_by)
    references public.organization_users(organization_id, user_id) on delete restrict,
  constraint purchases_subtotal_check check (subtotal >= 0),
  constraint purchases_discount_check check (discount >= 0),
  constraint purchases_tax_check check (tax >= 0),
  constraint purchases_total_check check (total >= 0),
  constraint purchases_discount_not_over_subtotal_check check (discount <= subtotal),
  constraint purchases_total_formula_check check (total = subtotal - discount + tax)
);

create table public.purchase_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  purchase_id uuid not null,
  product_id uuid not null,
  quantity numeric(18,4) not null,
  unit_price numeric(18,4) not null,
  discount numeric(18,4) not null default 0,
  tax numeric(18,4) not null default 0,
  line_total numeric(18,4) not null,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint purchase_items_purchase_same_organization_fk
    foreign key (purchase_id, organization_id)
    references public.purchases(id, organization_id) on delete cascade,
  constraint purchase_items_product_same_organization_fk
    foreign key (product_id, organization_id)
    references public.products(id, organization_id) on delete restrict,
  constraint purchase_items_created_by_organization_fk
    foreign key (organization_id, created_by)
    references public.organization_users(organization_id, user_id) on delete restrict,
  constraint purchase_items_quantity_check check (quantity > 0),
  constraint purchase_items_unit_price_check check (unit_price >= 0),
  constraint purchase_items_discount_check check (discount >= 0),
  constraint purchase_items_tax_check check (tax >= 0),
  constraint purchase_items_discount_not_over_base_check check (discount <= quantity * unit_price),
  constraint purchase_items_line_total_check check (line_total >= 0),
  constraint purchase_items_line_total_formula_check
    check (line_total = quantity * unit_price - discount + tax)
);

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  invoice_no text not null,
  contact_id uuid not null,
  invoice_date date not null default current_date,
  status public.invoice_status not null default 'Draft',
  subtotal numeric(18,4) not null default 0,
  discount numeric(18,4) not null default 0,
  tax numeric(18,4) not null default 0,
  total numeric(18,4) not null default 0,
  notes text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sales_invoice_no_format check (invoice_no ~ '^[0-9]{6}$'),
  constraint sales_invoice_no_unique unique (organization_id, invoice_no),
  constraint sales_id_organization_unique unique (id, organization_id),
  constraint sales_contact_same_organization_fk
    foreign key (contact_id, organization_id)
    references public.contacts(id, organization_id) on delete restrict,
  constraint sales_created_by_organization_fk
    foreign key (organization_id, created_by)
    references public.organization_users(organization_id, user_id) on delete restrict,
  constraint sales_subtotal_check check (subtotal >= 0),
  constraint sales_discount_check check (discount >= 0),
  constraint sales_tax_check check (tax >= 0),
  constraint sales_total_check check (total >= 0),
  constraint sales_discount_not_over_subtotal_check check (discount <= subtotal),
  constraint sales_total_formula_check check (total = subtotal - discount + tax)
);

create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sale_id uuid not null,
  product_id uuid not null,
  quantity numeric(18,4) not null,
  unit_price numeric(18,4) not null,
  discount numeric(18,4) not null default 0,
  tax numeric(18,4) not null default 0,
  line_total numeric(18,4) not null,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sale_items_sale_same_organization_fk
    foreign key (sale_id, organization_id)
    references public.sales(id, organization_id) on delete cascade,
  constraint sale_items_product_same_organization_fk
    foreign key (product_id, organization_id)
    references public.products(id, organization_id) on delete restrict,
  constraint sale_items_created_by_organization_fk
    foreign key (organization_id, created_by)
    references public.organization_users(organization_id, user_id) on delete restrict,
  constraint sale_items_quantity_check check (quantity > 0),
  constraint sale_items_unit_price_check check (unit_price >= 0),
  constraint sale_items_discount_check check (discount >= 0),
  constraint sale_items_tax_check check (tax >= 0),
  constraint sale_items_discount_not_over_base_check check (discount <= quantity * unit_price),
  constraint sale_items_line_total_check check (line_total >= 0),
  constraint sale_items_line_total_formula_check
    check (line_total = quantity * unit_price - discount + tax)
);

create table public.stock (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null,
  quantity numeric(18,4) not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint stock_quantity_nonnegative check (quantity >= 0),
  constraint stock_organization_product_unique unique (organization_id, product_id),
  constraint stock_id_organization_unique unique (id, organization_id),
  constraint stock_product_same_organization_fk
    foreign key (product_id, organization_id)
    references public.products(id, organization_id) on delete restrict
);

create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null,
  movement_direction public.inventory_movement_direction not null,
  movement_type public.inventory_movement_type not null,
  quantity numeric(18,4) not null,
  reference_type text,
  reference_id uuid,
  unit_cost numeric(18,4),
  movement_date timestamptz not null default now(),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint inventory_movements_product_same_organization_fk
    foreign key (product_id, organization_id)
    references public.products(id, organization_id) on delete restrict,
  constraint inventory_movements_created_by_organization_fk
    foreign key (organization_id, created_by)
    references public.organization_users(organization_id, user_id) on delete restrict,
  constraint inventory_movements_quantity_check check (quantity > 0),
  constraint inventory_movements_unit_cost_check check (unit_cost is null or unit_cost >= 0),
  constraint inventory_movements_reference_type_not_blank
    check (reference_type is null or btrim(reference_type) <> ''),
  constraint inventory_movements_reference_pair_check
    check ((reference_type is null) = (reference_id is null)),
  constraint inventory_movements_type_direction_check check (
    (movement_type = 'Purchase' and movement_direction = 'In') or
    (movement_type = 'Sale' and movement_direction = 'Out') or
    (movement_type = 'Opening' and movement_direction = 'In') or
    movement_type in ('Return', 'Adjustment')
  )
);

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  expense_no text not null,
  expense_date date not null default current_date,
  expense_category_id uuid not null,
  contact_id uuid,
  description text not null,
  amount numeric(18,4) not null,
  status public.expense_status not null default 'Draft',
  notes text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint expenses_expense_no_not_blank check (btrim(expense_no) <> ''),
  constraint expenses_expense_no_unique unique (organization_id, expense_no),
  constraint expenses_id_organization_unique unique (id, organization_id),
  constraint expenses_category_same_organization_fk
    foreign key (expense_category_id, organization_id)
    references public.expense_categories(id, organization_id) on delete restrict,
  constraint expenses_contact_same_organization_fk
    foreign key (contact_id, organization_id)
    references public.contacts(id, organization_id) on delete restrict,
  constraint expenses_created_by_organization_fk
    foreign key (organization_id, created_by)
    references public.organization_users(organization_id, user_id) on delete restrict,
  constraint expenses_description_not_blank check (btrim(description) <> ''),
  constraint expenses_amount_check check (amount > 0)
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  payment_no text not null,
  payment_date date not null default current_date,
  payment_type public.payment_type not null,
  contact_id uuid,
  amount numeric(18,4) not null,
  payment_method public.payment_method not null,
  reference_no text,
  status public.payment_status not null default 'Draft',
  notes text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payments_payment_no_not_blank check (btrim(payment_no) <> ''),
  constraint payments_payment_no_unique unique (organization_id, payment_no),
  constraint payments_id_organization_unique unique (id, organization_id),
  constraint payments_contact_same_organization_fk
    foreign key (contact_id, organization_id)
    references public.contacts(id, organization_id) on delete restrict,
  constraint payments_created_by_organization_fk
    foreign key (organization_id, created_by)
    references public.organization_users(organization_id, user_id) on delete restrict,
  constraint payments_amount_check check (amount > 0)
);

create table public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  payment_id uuid not null,
  purchase_id uuid,
  sale_id uuid,
  expense_id uuid,
  allocated_amount numeric(18,4) not null,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint payment_allocations_payment_same_organization_fk
    foreign key (payment_id, organization_id)
    references public.payments(id, organization_id) on delete restrict,
  constraint payment_allocations_purchase_same_organization_fk
    foreign key (purchase_id, organization_id)
    references public.purchases(id, organization_id) on delete restrict,
  constraint payment_allocations_sale_same_organization_fk
    foreign key (sale_id, organization_id)
    references public.sales(id, organization_id) on delete restrict,
  constraint payment_allocations_expense_same_organization_fk
    foreign key (expense_id, organization_id)
    references public.expenses(id, organization_id) on delete restrict,
  constraint payment_allocations_created_by_organization_fk
    foreign key (organization_id, created_by)
    references public.organization_users(organization_id, user_id) on delete restrict,
  constraint payment_allocations_exactly_one_target
    check (num_nonnulls(purchase_id, sale_id, expense_id) = 1),
  constraint payment_allocations_amount_check check (allocated_amount > 0)
);

create table public.account_transactions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  transaction_date timestamptz not null default now(),
  transaction_type text not null,
  reference_type text,
  reference_id uuid,
  contact_id uuid,
  description text not null,
  debit numeric(18,4) not null default 0,
  credit numeric(18,4) not null default 0,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint account_transactions_contact_same_organization_fk
    foreign key (contact_id, organization_id)
    references public.contacts(id, organization_id) on delete restrict,
  constraint account_transactions_created_by_organization_fk
    foreign key (organization_id, created_by)
    references public.organization_users(organization_id, user_id) on delete restrict,
  constraint account_transactions_type_not_blank check (btrim(transaction_type) <> ''),
  constraint account_transactions_description_not_blank check (btrim(description) <> ''),
  constraint account_transactions_debit_check check (debit >= 0),
  constraint account_transactions_credit_check check (credit >= 0),
  constraint account_transactions_one_side_only
    check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0)),
  constraint account_transactions_reference_pair_check
    check ((reference_type is null) = (reference_id is null)),
  constraint account_transactions_reference_type_not_blank
    check (reference_type is null or btrim(reference_type) <> '')
);

create index expense_categories_organization_id_idx on public.expense_categories (organization_id);
create index expense_categories_status_idx on public.expense_categories (organization_id, status);
create index expense_categories_created_by_idx on public.expense_categories (created_by);
create index purchases_organization_status_idx on public.purchases (organization_id, status);
create index purchases_contact_date_idx on public.purchases (contact_id, organization_id, invoice_date desc);
create index purchases_date_idx on public.purchases (organization_id, invoice_date desc);
create index purchases_created_by_idx on public.purchases (created_by);
create index purchase_items_purchase_idx on public.purchase_items (purchase_id, organization_id);
create index purchase_items_product_idx on public.purchase_items (product_id, organization_id);
create index purchase_items_created_by_idx on public.purchase_items (created_by);
create index sales_organization_status_idx on public.sales (organization_id, status);
create index sales_contact_date_idx on public.sales (contact_id, organization_id, invoice_date desc);
create index sales_date_idx on public.sales (organization_id, invoice_date desc);
create index sales_created_by_idx on public.sales (created_by);
create index sale_items_sale_idx on public.sale_items (sale_id, organization_id);
create index sale_items_product_idx on public.sale_items (product_id, organization_id);
create index sale_items_created_by_idx on public.sale_items (created_by);
create index stock_product_idx on public.stock (product_id, organization_id);
create index inventory_movements_product_date_idx on public.inventory_movements (organization_id, product_id, movement_date desc);
create index inventory_movements_reference_idx on public.inventory_movements (organization_id, reference_type, reference_id);
create index inventory_movements_created_by_idx on public.inventory_movements (created_by);
create index expenses_category_date_idx on public.expenses (expense_category_id, organization_id, expense_date desc);
create index expenses_contact_date_idx on public.expenses (contact_id, organization_id, expense_date desc);
create index expenses_status_idx on public.expenses (organization_id, status);
create index expenses_created_by_idx on public.expenses (created_by);
create index payments_contact_date_idx on public.payments (contact_id, organization_id, payment_date desc);
create index payments_type_date_idx on public.payments (organization_id, payment_type, payment_date desc);
create index payments_status_idx on public.payments (organization_id, status);
create index payments_created_by_idx on public.payments (created_by);
create index payment_allocations_payment_idx on public.payment_allocations (payment_id, organization_id);
create index payment_allocations_purchase_idx on public.payment_allocations (purchase_id, organization_id);
create index payment_allocations_sale_idx on public.payment_allocations (sale_id, organization_id);
create index payment_allocations_expense_idx on public.payment_allocations (expense_id, organization_id);
create index payment_allocations_created_by_idx on public.payment_allocations (created_by);
create index account_transactions_org_date_idx on public.account_transactions (organization_id, transaction_date desc);
create index account_transactions_contact_date_idx on public.account_transactions (contact_id, organization_id, transaction_date desc);
create index account_transactions_reference_idx on public.account_transactions (organization_id, reference_type, reference_id);
create index account_transactions_created_by_idx on public.account_transactions (created_by);

create trigger expense_categories_set_updated_at before update on public.expense_categories for each row execute function public.set_updated_at();
create trigger purchases_set_updated_at before update on public.purchases for each row execute function public.set_updated_at();
create trigger purchase_items_set_updated_at before update on public.purchase_items for each row execute function public.set_updated_at();
create trigger sales_set_updated_at before update on public.sales for each row execute function public.set_updated_at();
create trigger sale_items_set_updated_at before update on public.sale_items for each row execute function public.set_updated_at();
create trigger stock_set_updated_at before update on public.stock for each row execute function public.set_updated_at();
create trigger expenses_set_updated_at before update on public.expenses for each row execute function public.set_updated_at();
create trigger payments_set_updated_at before update on public.payments for each row execute function public.set_updated_at();

create or replace function public.set_purchase_invoice_no()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    new.invoice_no := public.next_purchase_invoice_no(new.organization_id);
    return new;
  end if;

  if new.organization_id <> old.organization_id then raise exception 'Purchase organization cannot be changed'; end if;
  if new.invoice_no <> old.invoice_no then raise exception 'Purchase invoice number cannot be changed'; end if;
  if new.created_by <> old.created_by then raise exception 'Purchase creator cannot be changed'; end if;

  if old.status <> new.status then
    if current_user <> 'postgres' then raise exception 'Purchase invoice status is controlled by invoice operations'; end if;
    return new;
  end if;

  if old.status <> 'Draft' and row(new.*) is distinct from row(old.*) then
    raise exception 'Only Draft purchase invoices can be edited';
  end if;
  return new;
end;
$$;

create trigger purchases_invoice_guard before insert or update on public.purchases
for each row execute function public.set_purchase_invoice_no();

create or replace function public.set_sales_invoice_no()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    new.invoice_no := public.next_sales_invoice_no(new.organization_id);
    return new;
  end if;

  if new.organization_id <> old.organization_id then raise exception 'Sales organization cannot be changed'; end if;
  if new.invoice_no <> old.invoice_no then raise exception 'Sales invoice number cannot be changed'; end if;
  if new.created_by <> old.created_by then raise exception 'Sales creator cannot be changed'; end if;

  if old.status <> new.status then
    if current_user <> 'postgres' then raise exception 'Sales invoice status is controlled by invoice operations'; end if;
    return new;
  end if;

  if old.status <> 'Draft' and row(new.*) is distinct from row(old.*) then
    raise exception 'Only Draft sales invoices can be edited';
  end if;
  return new;
end;
$$;

create trigger sales_invoice_guard before insert or update on public.sales
for each row execute function public.set_sales_invoice_no();

alter table public.expense_categories enable row level security;
alter table public.purchases enable row level security;
alter table public.purchase_items enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.stock enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.expenses enable row level security;
alter table public.payments enable row level security;
alter table public.payment_allocations enable row level security;
alter table public.account_transactions enable row level security;

create policy "expense_categories_select_member" on public.expense_categories for select to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = expense_categories.organization_id and ou.user_id = (select auth.uid())
));
create policy "expense_categories_insert_member" on public.expense_categories for insert to authenticated with check (
  created_by = (select auth.uid()) and exists (
    select 1 from public.organization_users ou where ou.organization_id = expense_categories.organization_id and ou.user_id = (select auth.uid())
));
create policy "expense_categories_update_member" on public.expense_categories for update to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = expense_categories.organization_id and ou.user_id = (select auth.uid())
)) with check (exists (
  select 1 from public.organization_users ou where ou.organization_id = expense_categories.organization_id and ou.user_id = (select auth.uid())
));
create policy "expense_categories_delete_member" on public.expense_categories for delete to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = expense_categories.organization_id and ou.user_id = (select auth.uid())
));

create policy "purchases_select_member" on public.purchases for select to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = purchases.organization_id and ou.user_id = (select auth.uid())
));
create policy "purchases_insert_member" on public.purchases for insert to authenticated with check (
  status = 'Draft' and created_by = (select auth.uid()) and exists (
    select 1 from public.organization_users ou where ou.organization_id = purchases.organization_id and ou.user_id = (select auth.uid())
));
create policy "purchases_update_member" on public.purchases for update to authenticated using (
  status = 'Draft' and exists (
    select 1 from public.organization_users ou where ou.organization_id = purchases.organization_id and ou.user_id = (select auth.uid())
)) with check (status = 'Draft');
create policy "purchases_delete_member" on public.purchases for delete to authenticated using (
  status = 'Draft' and exists (
    select 1 from public.organization_users ou where ou.organization_id = purchases.organization_id and ou.user_id = (select auth.uid())
));

create policy "purchase_items_select_member" on public.purchase_items for select to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = purchase_items.organization_id and ou.user_id = (select auth.uid())
));
create policy "purchase_items_insert_draft" on public.purchase_items for insert to authenticated with check (
  created_by = (select auth.uid()) and exists (
    select 1 from public.organization_users ou
    join public.purchases p on p.id = purchase_items.purchase_id and p.organization_id = purchase_items.organization_id
    where ou.organization_id = purchase_items.organization_id and ou.user_id = (select auth.uid()) and p.status = 'Draft'
  )
);
create policy "purchase_items_update_draft" on public.purchase_items for update to authenticated using (
  select 1 from public.organization_users ou
  join public.purchases p on p.id = purchase_items.purchase_id and p.organization_id = purchase_items.organization_id
  where ou.organization_id = purchase_items.organization_id and ou.user_id = (select auth.uid()) and p.status = 'Draft'
)) with check (exists (
    select 1 from public.organization_users ou
    join public.purchases p on p.id = purchase_items.purchase_id and p.organization_id = purchase_items.organization_id
    where ou.organization_id = purchase_items.organization_id and ou.user_id = (select auth.uid()) and p.status = 'Draft'
  ));
create policy "purchase_items_delete_draft" on public.purchase_items for delete to authenticated using (exists (
  select 1 from public.organization_users ou
  join public.purchases p on p.id = purchase_items.purchase_id and p.organization_id = purchase_items.organization_id
  where ou.organization_id = purchase_items.organization_id and ou.user_id = (select auth.uid()) and p.status = 'Draft'
));

create policy "sales_select_member" on public.sales for select to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = sales.organization_id and ou.user_id = (select auth.uid())
));
create policy "sales_insert_member" on public.sales for insert to authenticated with check (
  status = 'Draft' and created_by = (select auth.uid()) and exists (
    select 1 from public.organization_users ou where ou.organization_id = sales.organization_id and ou.user_id = (select auth.uid())
));
create policy "sales_update_member" on public.sales for update to authenticated using (
  status = 'Draft' and exists (
    select 1 from public.organization_users ou where ou.organization_id = sales.organization_id and ou.user_id = (select auth.uid())
)) with check (status = 'Draft');
create policy "sales_delete_member" on public.sales for delete to authenticated using (
  status = 'Draft' and exists (
    select 1 from public.organization_users ou where ou.organization_id = sales.organization_id and ou.user_id = (select auth.uid())
));

create policy "sale_items_select_member" on public.sale_items for select to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = sale_items.organization_id and ou.user_id = (select auth.uid())
));
create policy "sale_items_insert_draft" on public.sale_items for insert to authenticated with check (
  created_by = (select auth.uid()) and exists (
    select 1 from public.organization_users ou
    join public.sales s on s.id = sale_items.sale_id and s.organization_id = sale_items.organization_id
    where ou.organization_id = sale_items.organization_id and ou.user_id = (select auth.uid()) and s.status = 'Draft'
  )
);
create policy "sale_items_update_draft" on public.sale_items for update to authenticated using (
  select 1 from public.organization_users ou
  join public.sales s on s.id = sale_items.sale_id and s.organization_id = sale_items.organization_id
  where ou.organization_id = sale_items.organization_id and ou.user_id = (select auth.uid()) and s.status = 'Draft'
)) with check (exists (
    select 1 from public.organization_users ou
    join public.sales s on s.id = sale_items.sale_id and s.organization_id = sale_items.organization_id
    where ou.organization_id = sale_items.organization_id and ou.user_id = (select auth.uid()) and s.status = 'Draft'
  ));
create policy "sale_items_delete_draft" on public.sale_items for delete to authenticated using (exists (
  select 1 from public.organization_users ou
  join public.sales s on s.id = sale_items.sale_id and s.organization_id = sale_items.organization_id
  where ou.organization_id = sale_items.organization_id and ou.user_id = (select auth.uid()) and s.status = 'Draft'
));

create policy "stock_select_member" on public.stock for select to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = stock.organization_id and ou.user_id = (select auth.uid())
));

create policy "inventory_movements_select_member" on public.inventory_movements for select to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = inventory_movements.organization_id and ou.user_id = (select auth.uid())
));

create policy "expenses_select_member" on public.expenses for select to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = expenses.organization_id and ou.user_id = (select auth.uid())
));
create policy "expenses_insert_member" on public.expenses for insert to authenticated with check (
  status = 'Draft' and created_by = (select auth.uid()) and exists (
    select 1 from public.organization_users ou where ou.organization_id = expenses.organization_id and ou.user_id = (select auth.uid())
));
create policy "expenses_update_member" on public.expenses for update to authenticated using (
  status = 'Draft' and exists (
    select 1 from public.organization_users ou where ou.organization_id = expenses.organization_id and ou.user_id = (select auth.uid())
)) with check (status = 'Draft');
create policy "expenses_delete_member" on public.expenses for delete to authenticated using (
  status = 'Draft' and exists (
    select 1 from public.organization_users ou where ou.organization_id = expenses.organization_id and ou.user_id = (select auth.uid())
));

create policy "payments_select_member" on public.payments for select to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = payments.organization_id and ou.user_id = (select auth.uid())
));
create policy "payments_insert_member" on public.payments for insert to authenticated with check (
  status = 'Draft' and created_by = (select auth.uid()) and exists (
    select 1 from public.organization_users ou where ou.organization_id = payments.organization_id and ou.user_id = (select auth.uid())
));
create policy "payments_update_member" on public.payments for update to authenticated using (
  status = 'Draft' and exists (
    select 1 from public.organization_users ou where ou.organization_id = payments.organization_id and ou.user_id = (select auth.uid())
)) with check (status = 'Draft');
create policy "payments_delete_member" on public.payments for delete to authenticated using (
  status = 'Draft' and exists (
    select 1 from public.organization_users ou where ou.organization_id = payments.organization_id and ou.user_id = (select auth.uid())
));

create policy "payment_allocations_select_member" on public.payment_allocations for select to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = payment_allocations.organization_id and ou.user_id = (select auth.uid())
));

create policy "account_transactions_select_member" on public.account_transactions for select to authenticated using (exists (
  select 1 from public.organization_users ou where ou.organization_id = account_transactions.organization_id and ou.user_id = (select auth.uid())
));

revoke all on table public.expense_categories from anon;
revoke all on table public.purchases from anon;
revoke all on table public.purchase_items from anon;
revoke all on table public.sales from anon;
revoke all on table public.sale_items from anon;
revoke all on table public.stock from anon;
revoke all on table public.inventory_movements from anon;
revoke all on table public.expenses from anon;
revoke all on table public.payments from anon;
revoke all on table public.payment_allocations from anon;
revoke all on table public.account_transactions from anon;

revoke all on table public.stock from authenticated;
revoke all on table public.inventory_movements from authenticated;
revoke all on table public.payment_allocations from authenticated;
revoke all on table public.account_transactions from authenticated;

grant select, insert, update, delete on table public.expense_categories to authenticated;
grant select, insert, update, delete on table public.purchases to authenticated;
grant select, insert, update, delete on table public.purchase_items to authenticated;
grant select, insert, update, delete on table public.sales to authenticated;
grant select, insert, update, delete on table public.sale_items to authenticated;
grant select on table public.stock to authenticated;
grant select on table public.inventory_movements to authenticated;
grant select, insert, update, delete on table public.expenses to authenticated;
grant select, insert, update, delete on table public.payments to authenticated;
grant select on table public.payment_allocations to authenticated;
grant select on table public.account_transactions to authenticated;

comment on table public.purchases is 'Purchase invoices. Invoice number is assigned when the Draft row is first saved.';
comment on table public.sales is 'Sales invoices. Invoice number is assigned when the Draft row is first saved.';
comment on table public.stock is 'Current stock balance per organization and product; maintained by inventory operations.';
comment on table public.inventory_movements is 'Immutable inventory movement ledger. Quantity is positive; direction determines stock effect. created_by records the operation actor.';
comment on table public.payment_allocations is 'Payment allocations. Read-only to clients; controlled payment operations enforce allocation integrity and record created_by.';
comment on table public.account_transactions is 'Immutable accounting ledger. Corrections should use reversing entries; created_by records the operation actor.';
comment on column public.expense_categories.created_by is 'Creator is immutable after insert.';
comment on column public.expense_categories.organization_id is 'Tenant ownership is immutable after insert.';
comment on column public.expenses.created_by is 'Creator is immutable after insert.';
comment on column public.expenses.organization_id is 'Tenant ownership is immutable after insert.';
comment on column public.payments.created_by is 'Creator is immutable after insert.';
comment on column public.payments.organization_id is 'Tenant ownership is immutable after insert.';

 
-- Creator and organization immutability for master/financial business records.
-- These fields establish audit ownership and tenant scope at creation time.
create or replace function public.prevent_expense_category_identity_change()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $func$
begin
  if new.organization_id <> old.organization_id then
    raise exception 'Expense category organization cannot be changed';
  end if;
  if new.created_by <> old.created_by then
    raise exception 'Expense category creator cannot be changed';
  end if;
  return new;
end;
$func$;

create trigger expense_categories_prevent_identity_change
before update on public.expense_categories
for each row execute function public.prevent_expense_category_identity_change();

create or replace function public.prevent_expense_identity_change()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $func$
begin
  if new.organization_id <> old.organization_id then
    raise exception 'Expense organization cannot be changed';
  end if;
  if new.created_by <> old.created_by then
    raise exception 'Expense creator cannot be changed';
  end if;
  return new;
end;
$func$;

create trigger expenses_prevent_identity_change
before update on public.expenses
for each row execute function public.prevent_expense_identity_change();

create or replace function public.prevent_payment_identity_change()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $func$
begin
  if new.organization_id <> old.organization_id then
    raise exception 'Payment organization cannot be changed';
  end if;
  if new.created_by <> old.created_by then
    raise exception 'Payment creator cannot be changed';
  end if;
  return new;
end;
$func$;

create trigger payments_prevent_identity_change
before update on public.payments
for each row execute function public.prevent_payment_identity_change();

 
-- Creator immutability for Draft line items.
create or replace function public.prevent_purchase_item_creator_change()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if new.created_by <> old.created_by then
    raise exception 'Purchase item creator cannot be changed';
  end if;
  return new;
end;
$$;

create trigger purchase_items_prevent_creator_change
before update on public.purchase_items
for each row execute function public.prevent_purchase_item_creator_change();

create or replace function public.prevent_sale_item_creator_change()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if new.created_by <> old.created_by then
    raise exception 'Sale item creator cannot be changed';
  end if;
  return new;
end;
$$;

create trigger sale_items_prevent_creator_change
before update on public.sale_items
for each row execute function public.prevent_sale_item_creator_change();
