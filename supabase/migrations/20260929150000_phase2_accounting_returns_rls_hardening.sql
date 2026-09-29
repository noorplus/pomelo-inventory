-- Phase 2: historical accounting repair, return discount correctness, payment RLS hardening.
-- Applied to production as a forward-only migration.
-- No tables are created or deleted.

insert into public.account_transactions (
  organization_id, transaction_date, transaction_type,
  reference_type, reference_id, contact_id, description,
  debit, credit, created_by
)
select
  p.organization_id, now(), 'Purchase Inventory',
  'Purchase', p.id, p.contact_id,
  'Historical correction: missing purchase inventory debit - invoice ' || p.invoice_no,
  p.total, 0, ou.user_id
from public.purchases p
join lateral (
  select ou.user_id
  from public.organization_users ou
  where ou.organization_id = p.organization_id
    and ou.role = 'owner'
  order by ou.created_at, ou.user_id
  limit 1
) ou on true
where p.id in (
  '004c5147-e7f7-4d84-a926-6c285e6b96be'::uuid,
  '6ce1f0fc-8a9f-4cb6-ab84-54061cde128f'::uuid
)
and not exists (
  select 1
  from public.account_transactions at
  where at.reference_type = 'Purchase'
    and at.reference_id = p.id
    and at.transaction_type = 'Purchase Inventory'
    and at.description like 'Historical correction: missing purchase inventory debit%'
);

create or replace function public.return_purchase_items(p_purchase_id uuid, p_lines jsonb)
returns numeric
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user uuid := (select auth.uid());
  v_org uuid;
  v_status public.invoice_status;
  v_contact uuid;
  v_invoice_no text;
  v_header_discount numeric(18,4);
  v_document_line_total numeric(18,4);
  v_line record;
  v_item record;
  v_purchased numeric(18,4);
  v_returned numeric(18,4);
  v_remaining numeric(18,4);
  v_take numeric(18,4);
  v_row_remaining numeric(18,4);
  v_base_return_amount numeric(18,4) := 0;
  v_return_amount numeric(18,4) := 0;
  v_item_base numeric(18,4);
  v_effective_unit_cost numeric(18,8);
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Return lines must be a non-empty JSON array';
  end if;

  select p.organization_id, p.status, p.contact_id, p.invoice_no, coalesce(p.discount, 0)
    into v_org, v_status, v_contact, v_invoice_no, v_header_discount
  from public.purchases p where p.id = p_purchase_id for update;

  if not found then raise exception 'Purchase not found'; end if;
  perform public.rpc_assert_member(v_org);
  if v_status <> 'Confirmed' then raise exception 'Only Confirmed purchases can be returned'; end if;

  select coalesce(sum(pi.line_total), 0) into v_document_line_total
  from public.purchase_items pi
  where pi.purchase_id = p_purchase_id and pi.organization_id = v_org;

  if v_header_discount < 0 or v_header_discount > v_document_line_total then
    raise exception 'Purchase header discount is invalid';
  end if;

  if exists (
    select 1 from public.payment_allocations pa
    join public.payments py on py.id = pa.payment_id
    where pa.organization_id = v_org and pa.purchase_id = p_purchase_id and py.status = 'Confirmed'
  ) then
    raise exception 'Purchase cannot be returned while confirmed payments are allocated to it';
  end if;

  for v_line in
    select x.product_id, sum(x.quantity) quantity
    from jsonb_to_recordset(p_lines) x(product_id uuid, quantity numeric)
    group by x.product_id
  loop
    if v_line.quantity is null or v_line.quantity <= 0 then raise exception 'Return quantity must be greater than zero'; end if;
    if not exists (select 1 from public.products where id=v_line.product_id and organization_id=v_org) then
      raise exception 'Product not found in this organization';
    end if;

    select coalesce(sum(quantity),0) into v_purchased
    from public.purchase_items
    where purchase_id=p_purchase_id and organization_id=v_org and product_id=v_line.product_id;
    if v_purchased <= 0 then raise exception 'Product was not part of this purchase'; end if;

    select coalesce(sum(quantity),0) into v_returned
    from public.inventory_movements
    where organization_id=v_org and reference_type='Purchase' and reference_id=p_purchase_id
      and product_id=v_line.product_id and movement_direction='Out' and movement_type='Return';

    v_remaining := v_purchased - v_returned;
    if v_line.quantity > v_remaining then
      raise exception 'Return quantity exceeds remaining quantity for product %', v_line.product_id;
    end if;

    v_row_remaining := v_line.quantity;

    for v_item in
      select product_id, quantity, unit_price, discount
      from public.purchase_items
      where purchase_id=p_purchase_id and organization_id=v_org and product_id=v_line.product_id
      order by created_at,id
    loop
      exit when v_row_remaining <= 0;
      v_take := least(v_row_remaining,v_item.quantity);
      v_item_base := v_take*v_item.unit_price - v_item.discount*(v_take/v_item.quantity);
      v_base_return_amount := v_base_return_amount + v_item_base;

      v_effective_unit_cost := greatest(
        (v_item.unit_price-(v_item.discount/v_item.quantity)) *
        case when v_document_line_total > 0
          then (1-(v_header_discount/v_document_line_total)) else 1 end, 0);

      update public.stock set quantity=quantity-v_take,updated_at=now()
      where organization_id=v_org and product_id=v_item.product_id and quantity>=v_take;
      if not found then raise exception 'Return would make stock negative for product %',v_item.product_id; end if;

      insert into public.inventory_movements(
        organization_id,product_id,movement_direction,movement_type,quantity,
        reference_type,reference_id,unit_cost,movement_date,created_by)
      values(v_org,v_item.product_id,'Out','Return',v_take,'Purchase',p_purchase_id,
        round(v_effective_unit_cost,4),now(),v_user);

      v_row_remaining := v_row_remaining-v_take;
    end loop;
  end loop;

  if v_document_line_total > 0 then
    v_return_amount := round(
      v_base_return_amount - v_header_discount*(v_base_return_amount/v_document_line_total),4);
  else
    v_return_amount := 0;
  end if;

  if v_return_amount > 0 then
    insert into public.account_transactions(
      organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,
      description,debit,credit,created_by)
    values
      (v_org,now(),'Purchase Return - Payable','Purchase',p_purchase_id,v_contact,
       'Reversal of purchase payable (return) - '||v_invoice_no,v_return_amount,0,v_user),
      (v_org,now(),'Purchase Return - Inventory','Purchase',p_purchase_id,v_contact,
       'Reversal of purchase inventory (return) - '||v_invoice_no,0,v_return_amount,v_user);
  end if;

  return v_return_amount;
end;
$function$;

create or replace function public.return_sale_items(p_sale_id uuid, p_lines jsonb)
returns numeric
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user uuid := (select auth.uid());
  v_org uuid;
  v_status public.invoice_status;
  v_contact uuid;
  v_invoice_no text;
  v_header_discount numeric(18,4);
  v_document_line_total numeric(18,4);
  v_line record;
  v_item record;
  v_sold numeric(18,4);
  v_returned numeric(18,4);
  v_remaining numeric(18,4);
  v_take numeric(18,4);
  v_row_remaining numeric(18,4);
  v_base_return_amount numeric(18,4) := 0;
  v_return_amount numeric(18,4) := 0;
  v_item_base numeric(18,4);
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Return lines must be a non-empty JSON array';
  end if;

  select s.organization_id,s.status,s.contact_id,s.invoice_no,coalesce(s.discount,0)
    into v_org,v_status,v_contact,v_invoice_no,v_header_discount
  from public.sales s where s.id=p_sale_id for update;

  if not found then raise exception 'Sale not found'; end if;
  perform public.rpc_assert_member(v_org);
  if v_status <> 'Confirmed' then raise exception 'Only Confirmed sales can be returned'; end if;

  select coalesce(sum(si.line_total),0) into v_document_line_total
  from public.sale_items si
  where si.sale_id=p_sale_id and si.organization_id=v_org;

  if v_header_discount < 0 or v_header_discount > v_document_line_total then
    raise exception 'Sale header discount is invalid';
  end if;

  if exists (
    select 1 from public.payment_allocations pa
    join public.payments py on py.id=pa.payment_id
    where pa.organization_id=v_org and pa.sale_id=p_sale_id and py.status='Confirmed'
  ) then
    raise exception 'Sale cannot be returned while confirmed payments are allocated to it';
  end if;

  for v_line in
    select x.product_id,sum(x.quantity) quantity
    from jsonb_to_recordset(p_lines) x(product_id uuid,quantity numeric)
    group by x.product_id
  loop
    if v_line.quantity is null or v_line.quantity <= 0 then raise exception 'Return quantity must be greater than zero'; end if;
    if not exists (select 1 from public.products where id=v_line.product_id and organization_id=v_org) then
      raise exception 'Product not found in this organization';
    end if;

    select coalesce(sum(quantity),0) into v_sold
    from public.sale_items
    where sale_id=p_sale_id and organization_id=v_org and product_id=v_line.product_id;
    if v_sold <= 0 then raise exception 'Product was not part of this sale'; end if;

    select coalesce(sum(quantity),0) into v_returned
    from public.inventory_movements
    where organization_id=v_org and reference_type='Sale' and reference_id=p_sale_id
      and product_id=v_line.product_id and movement_direction='In' and movement_type='Return';

    v_remaining:=v_sold-v_returned;
    if v_line.quantity>v_remaining then
      raise exception 'Return quantity exceeds remaining quantity for product %',v_line.product_id;
    end if;

    v_row_remaining:=v_line.quantity;

    for v_item in
      select product_id,quantity,unit_price,discount
      from public.sale_items
      where sale_id=p_sale_id and organization_id=v_org and product_id=v_line.product_id
      order by created_at,id
    loop
      exit when v_row_remaining<=0;
      v_take:=least(v_row_remaining,v_item.quantity);
      v_item_base:=v_take*v_item.unit_price-v_item.discount*(v_take/v_item.quantity);
      v_base_return_amount:=v_base_return_amount+v_item_base;

      insert into public.stock(organization_id,product_id,quantity)
      values(v_org,v_item.product_id,v_take)
      on conflict(organization_id,product_id)
      do update set quantity=public.stock.quantity+excluded.quantity,updated_at=now();

      insert into public.inventory_movements(
        organization_id,product_id,movement_direction,movement_type,quantity,
        reference_type,reference_id,unit_cost,movement_date,created_by)
      values(v_org,v_item.product_id,'In','Return',v_take,'Sale',p_sale_id,null,now(),v_user);

      v_row_remaining:=v_row_remaining-v_take;
    end loop;
  end loop;

  if v_document_line_total>0 then
    v_return_amount:=round(
      v_base_return_amount-v_header_discount*(v_base_return_amount/v_document_line_total),4);
  else
    v_return_amount:=0;
  end if;

  if v_return_amount>0 then
    insert into public.account_transactions(
      organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,
      description,debit,credit,created_by)
    values
      (v_org,now(),'Sale Return - Revenue','Sale',p_sale_id,v_contact,
       'Reversal of sale revenue (return) - '||v_invoice_no,v_return_amount,0,v_user),
      (v_org,now(),'Sale Return - Receivable','Sale',p_sale_id,v_contact,
       'Reversal of sale receivable (return) - '||v_invoice_no,0,v_return_amount,v_user);
  end if;

  return v_return_amount;
end;
$function$;

drop policy if exists payments_update_member on public.payments;
create policy payments_update_member
on public.payments
for update
to authenticated
using (
  status='Draft'
  and exists (
    select 1 from public.organization_users ou
    where ou.organization_id=payments.organization_id and ou.user_id=(select auth.uid())
  )
)
with check (
  status='Draft'
  and exists (
    select 1 from public.organization_users ou
    where ou.organization_id=payments.organization_id and ou.user_id=(select auth.uid())
  )
);
