-- Pomelo Inventory - Live database probe (READ-ONLY).
-- Run this in the Supabase Dashboard SQL editor (or psql) and paste the full
-- output back. It changes nothing: only SELECTs from catalog views.
-- Purpose: confirm which migrations/RPC variants the live DB actually runs,
-- so the repo can be synchronized to it before anything is applied.

-- 1. Applied migrations (Supabase CLI history table).
select version, name
from supabase_migrations.schema_migrations
order by version;

-- 2. Canonical vs legacy RPC signatures + return types.
select
  p.proname as function_name,
  pg_get_function_arguments(p.oid) as arguments,
  pg_get_function_result(p.oid) as returns,
  case p.prosecdef when true then 'DEFINER' else 'INVOKER' end as security
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'confirm_purchase', 'cancel_purchase',
    'confirm_sale', 'cancel_sale',
    'confirm_expense', 'cancel_expense',
    'confirm_payment', 'cancel_payment',
    'set_payment_allocations',
    'create_purchase_draft', 'update_purchase_draft', 'delete_purchase_draft',
    'purchase_outstanding', 'sale_outstanding', 'expense_outstanding',
    'next_payment_no', 'next_expense_no',
    'record_stock_adjustment', 'return_purchase_items', 'return_sale_items',
    'next_purchase_invoice_no', 'next_sales_invoice_no',
    'create_organization'
  )
order by 1, 2;

-- 3. Table-level grants backing the RLS policies (settings-save check).
select table_name, grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in ('organizations', 'profiles')
  and grantee in ('authenticated', 'anon', 'public')
order by table_name, grantee, privilege_type;

-- 4. Confirm inventory/product columns match the frozen schema
-- (inventory page must not select id_no / symbol if these come back empty).
select table_name, column_name
from information_schema.columns
where table_schema = 'public'
  and table_name in ('products', 'units_of_measure')
  and column_name in ('id_no', 'symbol');
