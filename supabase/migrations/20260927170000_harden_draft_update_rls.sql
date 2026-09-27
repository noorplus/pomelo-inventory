drop policy if exists "expenses_update_member" on public.expenses;
create policy "expenses_update_member"
on public.expenses
for update
to authenticated
using (
  status = 'Draft'::public.expense_status
  and exists (
    select 1 from public.organization_users ou
    where ou.organization_id = expenses.organization_id
      and ou.user_id = (select auth.uid())
  )
)
with check (
  status = 'Draft'::public.expense_status
  and exists (
    select 1 from public.organization_users ou
    where ou.organization_id = expenses.organization_id
      and ou.user_id = (select auth.uid())
  )
);

drop policy if exists "purchases_update_member" on public.purchases;
create policy "purchases_update_member"
on public.purchases
for update
to authenticated
using (
  status = 'Draft'::public.invoice_status
  and exists (
    select 1 from public.organization_users ou
    where ou.organization_id = purchases.organization_id
      and ou.user_id = (select auth.uid())
  )
)
with check (
  status = 'Draft'::public.invoice_status
  and exists (
    select 1 from public.organization_users ou
    where ou.organization_id = purchases.organization_id
      and ou.user_id = (select auth.uid())
  )
);

drop policy if exists "sales_update_member" on public.sales;
create policy "sales_update_member"
on public.sales
for update
to authenticated
using (
  status = 'Draft'::public.invoice_status
  and exists (
    select 1 from public.organization_users ou
    where ou.organization_id = sales.organization_id
      and ou.user_id = (select auth.uid())
  )
)
with check (
  status = 'Draft'::public.invoice_status
  and exists (
    select 1 from public.organization_users ou
    where ou.organization_id = sales.organization_id
      and ou.user_id = (select auth.uid())
  )
);