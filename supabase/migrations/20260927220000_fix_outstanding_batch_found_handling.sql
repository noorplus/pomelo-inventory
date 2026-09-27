create or replace function public.outstanding_for_documents(
  p_document_type text,
  p_document_ids uuid[]
)
returns table(document_id uuid, outstanding numeric)
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_id uuid;
  v_org uuid;
  v_total numeric(18,4);
  v_paid numeric(18,4);
  v_returned numeric(18,4);
begin
  if lower(btrim(p_document_type)) not in ('sale','purchase','expense') then
    raise exception 'Document type must be sale, purchase, or expense';
  end if;
  if p_document_ids is null then return; end if;

  foreach v_id in array p_document_ids loop
    v_paid := 0;
    v_returned := 0;
    v_org := null;
    v_total := null;

    if lower(btrim(p_document_type)) = 'sale' then
      select s.organization_id, s.total into v_org, v_total
      from public.sales s where s.id = v_id and s.status = 'Confirmed';
      if v_org is null then raise exception 'Confirmed sale not found'; end if;
      perform public.rpc_assert_member(v_org);
      select coalesce(sum(pa.allocated_amount), 0) into v_paid
      from public.payment_allocations pa join public.payments py on py.id = pa.payment_id
      where pa.organization_id = v_org and pa.sale_id = v_id and py.status = 'Confirmed';
      select coalesce(sum(at.credit), 0) into v_returned
      from public.account_transactions at
      where at.organization_id = v_org and at.reference_type = 'Sale' and at.reference_id = v_id
        and at.transaction_type like 'Sale Return%';

    elsif lower(btrim(p_document_type)) = 'purchase' then
      select p.organization_id, p.total into v_org, v_total
      from public.purchases p where p.id = v_id and p.status = 'Confirmed';
      if v_org is null then raise exception 'Confirmed purchase not found'; end if;
      perform public.rpc_assert_member(v_org);
      select coalesce(sum(pa.allocated_amount), 0) into v_paid
      from public.payment_allocations pa join public.payments py on py.id = pa.payment_id
      where pa.organization_id = v_org and pa.purchase_id = v_id and py.status = 'Confirmed';
      select coalesce(sum(at.debit), 0) into v_returned
      from public.account_transactions at
      where at.organization_id = v_org and at.reference_type = 'Purchase' and at.reference_id = v_id
        and at.transaction_type like 'Purchase Return%';

    else
      select e.organization_id, e.amount into v_org, v_total
      from public.expenses e where e.id = v_id and e.status = 'Confirmed';
      if v_org is null then raise exception 'Confirmed expense not found'; end if;
      perform public.rpc_assert_member(v_org);
      select coalesce(sum(pa.allocated_amount), 0) into v_paid
      from public.payment_allocations pa join public.payments py on py.id = pa.payment_id
      where pa.organization_id = v_org and pa.expense_id = v_id and py.status = 'Confirmed';
    end if;

    document_id := v_id;
    outstanding := greatest(v_total - v_paid - v_returned, 0);
    return next;
  end loop;
end;
$function$;
