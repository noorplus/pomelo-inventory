create or replace function public.sale_outstanding(p_sale_id uuid)
returns numeric
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_org uuid;
  v_total numeric(18,4);
  v_paid numeric(18,4);
  v_returned numeric(18,4) := 0;
begin
  select organization_id, total into v_org, v_total
  from public.sales
  where id = p_sale_id
    and status = 'Confirmed';
  if not found then raise exception 'Confirmed sale not found'; end if;
  perform public.rpc_assert_member(v_org);
  select coalesce(sum(pa.allocated_amount), 0) into v_paid
  from public.payment_allocations pa
  join public.payments py on py.id = pa.payment_id
  where pa.organization_id = v_org and pa.sale_id = p_sale_id and py.status = 'Confirmed';
  select coalesce(sum(credit), 0) into v_returned
  from public.account_transactions
  where organization_id = v_org and reference_type = 'Sale' and reference_id = p_sale_id
    and transaction_type like 'Sale Return%';
  return greatest(v_total - v_paid - coalesce(v_returned, 0), 0);
end;
$function$;

create or replace function public.purchase_outstanding(p_purchase_id uuid)
returns numeric
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_org uuid;
  v_total numeric(18,4);
  v_paid numeric(18,4);
  v_returned numeric(18,4) := 0;
begin
  select organization_id, total into v_org, v_total
  from public.purchases
  where id = p_purchase_id
    and status = 'Confirmed';
  if not found then raise exception 'Confirmed purchase not found'; end if;
  perform public.rpc_assert_member(v_org);
  select coalesce(sum(pa.allocated_amount), 0) into v_paid
  from public.payment_allocations pa
  join public.payments py on py.id = pa.payment_id
  where pa.organization_id = v_org and pa.purchase_id = p_purchase_id and py.status = 'Confirmed';
  select coalesce(sum(debit), 0) into v_returned
  from public.account_transactions
  where organization_id = v_org and reference_type = 'Purchase' and reference_id = p_purchase_id
    and transaction_type like 'Purchase Return%';
  return greatest(v_total - v_paid - coalesce(v_returned, 0), 0);
end;
$function$;

create or replace function public.expense_outstanding(p_expense_id uuid)
returns numeric
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_org uuid;
  v_total numeric(18,4);
  v_paid numeric(18,4);
begin
  select organization_id, amount into v_org, v_total
  from public.expenses
  where id = p_expense_id
    and status = 'Confirmed';
  if not found then raise exception 'Confirmed expense not found'; end if;
  perform public.rpc_assert_member(v_org);
  select coalesce(sum(pa.allocated_amount), 0) into v_paid
  from public.payment_allocations pa
  join public.payments py on py.id = pa.payment_id
  where pa.organization_id = v_org and pa.expense_id = p_expense_id and py.status = 'Confirmed';
  return greatest(v_total - v_paid, 0);
end;
$function$;

revoke execute on function public.sale_outstanding(uuid), public.purchase_outstanding(uuid), public.expense_outstanding(uuid) from public, anon;
grant execute on function public.sale_outstanding(uuid), public.purchase_outstanding(uuid), public.expense_outstanding(uuid) to authenticated;
