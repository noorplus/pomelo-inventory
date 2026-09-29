-- Production DB ↔ Repository synchronization for Phase 2–5 hardening.
-- Canonical snapshot of verified live function contracts, generated 2026-09-29.
-- This migration is for repository/fresh-deployment synchronization. It is NOT
-- intended to be re-applied to the already-hardened production database.

BEGIN;

ALTER TABLE public.stock ADD COLUMN IF NOT EXISTS average_cost numeric(18,8) NOT NULL DEFAULT 0;
ALTER TABLE public.stock ADD COLUMN IF NOT EXISTS inventory_value numeric(18,4) NOT NULL DEFAULT 0;

CREATE SCHEMA IF NOT EXISTS private;

CREATE OR REPLACE FUNCTION private.wac_in(o uuid, p uuid, q numeric, c numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare oq numeric;ov numeric;nq numeric;nv numeric;a numeric;
begin
 if q<=0 or c is null or c<0 then raise exception 'Invalid inbound cost'; end if;
 insert into public.stock(organization_id,product_id,quantity,average_cost,inventory_value) values(o,p,0,0,0) on conflict(organization_id,product_id) do nothing;
 select quantity,inventory_value into oq,ov from public.stock where organization_id=o and product_id=p for update;
 nq=oq+q;nv=ov+q*c;a=case when nq>0 then nv/nq else 0 end;
 update public.stock set quantity=round(nq,4),inventory_value=round(nv,4),average_cost=round(a,8),updated_at=now() where organization_id=o and product_id=p;
 return round(a,8);
end $function$


CREATE OR REPLACE FUNCTION private.wac_out(o uuid, p uuid, q numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare oq numeric;ov numeric;a numeric;nv numeric;
begin
 if q<=0 then raise exception 'Invalid outbound quantity'; end if;
 select quantity,inventory_value,average_cost into oq,ov,a from public.stock where organization_id=o and product_id=p for update;
 if not found or oq<q then raise exception 'Insufficient stock for product %',p; end if;
 nv=ov-q*a;if nv < -0.01 then raise exception 'Inventory value would become negative for product %',p;end if;nv=greatest(nv,0);
 update public.stock set quantity=round(oq-q,4),inventory_value=round(nv,4),average_cost=case when oq-q>0 then round(a,8) else 0 end,updated_at=now() where organization_id=o and product_id=p;
 return round(a,8);
end $function$


CREATE OR REPLACE FUNCTION public.cancel_purchase(p_purchase_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := (select auth.uid());
  v_org uuid;
  v_status public.invoice_status;
  v_total numeric(18,4);
  v_contact uuid;
  v_invoice_no text;
  v_returned_amount numeric(18,4) := 0;
  v_remaining_amount numeric(18,4) := 0;
  v_row record;
  v_cost numeric(18,4);
  v_cancel_inventory_cost numeric(18,4) := 0;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select organization_id, status, total, contact_id, invoice_no
    into v_org, v_status, v_total, v_contact, v_invoice_no
  from public.purchases where id = p_purchase_id for update;

  if not found then raise exception 'Purchase not found'; end if;
  perform public.rpc_assert_member(v_org);

  if v_status <> 'Confirmed' then raise exception 'Only Confirmed purchases can be cancelled'; end if;

  if exists (
    select 1 from public.payment_allocations pa
    join public.payments py on py.id = pa.payment_id
    where pa.organization_id=v_org and pa.purchase_id=p_purchase_id and py.status='Confirmed'
  ) then raise exception 'Purchase cannot be cancelled while confirmed payments are allocated to it'; end if;

  if not exists (
    select 1 from public.inventory_movements
    where organization_id=v_org and reference_type='Purchase' and reference_id=p_purchase_id
      and movement_direction='In' and movement_type='Purchase'
  ) then raise exception 'Purchase inventory ledger is missing'; end if;

  if (
    select count(*) from public.account_transactions
    where organization_id=v_org and reference_type='Purchase' and reference_id=p_purchase_id
      and transaction_type='Purchase'
  ) <> 1 then raise exception 'Purchase accounting ledger is incomplete'; end if;

  if exists (
    select 1 from (
      select product_id,sum(quantity) quantity from public.purchase_items
      where purchase_id=p_purchase_id and organization_id=v_org group by product_id
    ) i
    full join (
      select product_id,sum(quantity) quantity from public.inventory_movements
      where organization_id=v_org and reference_type='Purchase' and reference_id=p_purchase_id
        and movement_direction='In' and movement_type='Purchase' group by product_id
    ) m using(product_id)
    where coalesce(i.quantity,0)<>coalesce(m.quantity,0)
  ) then raise exception 'Purchase inventory ledger does not match purchase items'; end if;

  select coalesce(sum(debit),0) into v_returned_amount
  from public.account_transactions
  where organization_id=v_org and reference_type='Purchase' and reference_id=p_purchase_id
    and transaction_type='Purchase Return - Payable';

  if v_returned_amount<0 or v_returned_amount>v_total then
    raise exception 'Purchase return accounting exceeds the original purchase amount';
  end if;

  if exists (
    select 1 from (
      select coalesce(sum(debit),0) debit,coalesce(sum(credit),0) credit
      from public.account_transactions
      where organization_id=v_org and reference_type='Purchase' and reference_id=p_purchase_id
        and transaction_type like 'Purchase Return%'
    ) ret where ret.debit<>ret.credit
  ) then raise exception 'Purchase return accounting ledger is unbalanced'; end if;

  if exists (
    select 1 from (
      select product_id,sum(quantity) quantity
      from public.inventory_movements
      where organization_id=v_org and reference_type='Purchase' and reference_id=p_purchase_id
        and movement_direction='Out' and movement_type='Return' group by product_id
    ) ret
    full join (
      select product_id,sum(quantity) quantity
      from public.purchase_items
      where purchase_id=p_purchase_id and organization_id=v_org group by product_id
    ) bought using(product_id)
    where coalesce(ret.quantity,0)>coalesce(bought.quantity,0)
  ) then raise exception 'Purchase return inventory exceeds the original purchased quantity'; end if;

  for v_row in
    select i.product_id,
           greatest(sum(i.quantity)-coalesce((
             select sum(m.quantity) from public.inventory_movements m
             where m.organization_id=v_org and m.reference_type='Purchase' and m.reference_id=p_purchase_id
               and m.product_id=i.product_id and m.movement_direction='Out' and m.movement_type='Return'
           ),0),0) quantity
    from public.purchase_items i
    where i.purchase_id=p_purchase_id and i.organization_id=v_org
    group by i.product_id
    having greatest(sum(i.quantity)-coalesce((
      select sum(m.quantity) from public.inventory_movements m
      where m.organization_id=v_org and m.reference_type='Purchase' and m.reference_id=p_purchase_id
        and m.product_id=i.product_id and m.movement_direction='Out' and m.movement_type='Return'
    ),0),0)>0
  loop
    select round(average_cost,8) into v_cost
    from public.stock
    where organization_id=v_org and product_id=v_row.product_id
    for update;

    if v_cost is null then
      raise exception 'Current WAC unavailable for product %',v_row.product_id;
    end if;

    v_cancel_inventory_cost := v_cancel_inventory_cost
      + round(v_row.quantity * v_cost,4);

    perform private.wac_out(v_org,v_row.product_id,v_row.quantity);

    insert into public.inventory_movements(
      organization_id,product_id,movement_direction,movement_type,quantity,
      reference_type,reference_id,unit_cost,movement_date,created_by
    ) values(
      v_org,v_row.product_id,'Out','Return',v_row.quantity,'Purchase',p_purchase_id,
      v_cost,now(),v_user
    );
  end loop;

  v_remaining_amount:=greatest(v_total-v_returned_amount,0);

  if v_remaining_amount>0 then
    insert into public.account_transactions(
      organization_id,transaction_date,transaction_type,reference_type,reference_id,
      contact_id,description,debit,credit,created_by
    ) values(
      v_org,now(),'Purchase Payable Reversal','Purchase',p_purchase_id,v_contact,
      'Reversal of remaining purchase payable - '||v_invoice_no,v_remaining_amount,0,v_user
    );

    if v_cancel_inventory_cost <= v_remaining_amount then
      insert into public.account_transactions(
        organization_id,transaction_date,transaction_type,reference_type,reference_id,
        contact_id,description,debit,credit,created_by
      ) values
      (
        v_org,now(),'Purchase Cancellation - Inventory','Purchase',p_purchase_id,v_contact,
        'Inventory reduction on purchase cancellation - '||v_invoice_no,0,v_cancel_inventory_cost,v_user
      ),(
        v_org,now(),'Purchase Cancellation - Cost Variance','Purchase',p_purchase_id,v_contact,
        'WAC vs remaining purchase cancellation amount',0,
        v_remaining_amount-v_cancel_inventory_cost,v_user
      );
    else
      insert into public.account_transactions(
        organization_id,transaction_date,transaction_type,reference_type,reference_id,
        contact_id,description,debit,credit,created_by
      ) values
      (
        v_org,now(),'Purchase Cancellation - Inventory','Purchase',p_purchase_id,v_contact,
        'Inventory reduction on purchase cancellation - '||v_invoice_no,0,v_cancel_inventory_cost,v_user
      ),(
        v_org,now(),'Purchase Cancellation - Cost Variance','Purchase',p_purchase_id,v_contact,
        'WAC vs remaining purchase cancellation amount',
        v_cancel_inventory_cost-v_remaining_amount,0,v_user
      );
    end if;
  end if;

  update public.purchases set status='Cancelled',updated_at=now()
  where id=p_purchase_id and status='Confirmed';

  if not found then raise exception 'Purchase cancellation failed'; end if;
  return p_purchase_id;
end;
$function$


CREATE OR REPLACE FUNCTION public.cancel_sale(p_sale_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := (select auth.uid());
  v_org uuid;
  v_status public.invoice_status;
  v_total numeric(18,4);
  v_contact uuid;
  v_invoice_no text;
  v_returned_amount numeric(18,4) := 0;
  v_remaining_amount numeric(18,4) := 0;
  v_row record;
  v_cost numeric(18,4);
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select organization_id,status,total,contact_id,invoice_no
    into v_org,v_status,v_total,v_contact,v_invoice_no
  from public.sales where id=p_sale_id for update;

  if not found then raise exception 'Sale not found'; end if;
  perform public.rpc_assert_member(v_org);

  if v_status <> 'Confirmed' then raise exception 'Only Confirmed sales can be cancelled'; end if;

  if exists (
    select 1 from public.payment_allocations pa
    join public.payments py on py.id=pa.payment_id
    where pa.organization_id=v_org and pa.sale_id=p_sale_id and py.status='Confirmed'
  ) then
    raise exception 'Sale cannot be cancelled while confirmed payments are allocated to it';
  end if;

  if not exists (
    select 1 from public.inventory_movements
    where organization_id=v_org and reference_type='Sale' and reference_id=p_sale_id
      and movement_direction='Out' and movement_type='Sale'
  ) then raise exception 'Sale inventory ledger is missing'; end if;

  if (
    select count(*) from public.account_transactions
    where organization_id=v_org and reference_type='Sale' and reference_id=p_sale_id
      and transaction_type in ('Sale Revenue','Sale Receivable')
  ) <> 2
  or (
    select count(*) from public.account_transactions
    where organization_id=v_org and reference_type='Sale' and reference_id=p_sale_id
      and transaction_type='Sale Revenue'
  ) <> 1
  or (
    select count(*) from public.account_transactions
    where organization_id=v_org and reference_type='Sale' and reference_id=p_sale_id
      and transaction_type='Sale Receivable'
  ) <> 1
  then raise exception 'Sale accounting ledger is incomplete'; end if;

  if exists (
    select 1 from (
      select product_id,sum(quantity) quantity from public.sale_items
      where sale_id=p_sale_id and organization_id=v_org group by product_id
    ) i
    full join (
      select product_id,sum(quantity) quantity from public.inventory_movements
      where organization_id=v_org and reference_type='Sale' and reference_id=p_sale_id
        and movement_direction='Out' and movement_type='Sale' group by product_id
    ) m using(product_id)
    where coalesce(i.quantity,0)<>coalesce(m.quantity,0)
  ) then raise exception 'Sale inventory ledger does not match sale items'; end if;

  select coalesce(sum(case when transaction_type='Sale Return - Revenue' then debit else 0 end),0)
    into v_returned_amount
  from public.account_transactions
  where organization_id=v_org and reference_type='Sale' and reference_id=p_sale_id;

  if v_returned_amount<0 or v_returned_amount>v_total then
    raise exception 'Sale return accounting exceeds the original sale amount';
  end if;

  if exists (
    select 1 from (
      select coalesce(sum(debit),0) debit,coalesce(sum(credit),0) credit
      from public.account_transactions
      where organization_id=v_org and reference_type='Sale' and reference_id=p_sale_id
        and transaction_type in ('Sale Return - Revenue','Sale Return - Receivable')
    ) ret where ret.debit<>ret.credit
  ) then raise exception 'Sale return accounting ledger is unbalanced'; end if;

  if exists (
    select 1 from (
      select product_id,sum(quantity) quantity from public.inventory_movements
      where organization_id=v_org and reference_type='Sale' and reference_id=p_sale_id
        and movement_direction='In' and movement_type='Return' group by product_id
    ) ret
    full join (
      select product_id,sum(quantity) quantity from public.sale_items
      where sale_id=p_sale_id and organization_id=v_org group by product_id
    ) sold using(product_id)
    where coalesce(ret.quantity,0)>coalesce(sold.quantity,0)
  ) then raise exception 'Sale return inventory exceeds the original sold quantity'; end if;

  for v_row in
    select i.product_id,
           greatest(sum(i.quantity)-coalesce((
             select sum(m.quantity) from public.inventory_movements m
             where m.organization_id=v_org and m.reference_type='Sale' and m.reference_id=p_sale_id
               and m.product_id=i.product_id and m.movement_direction='In' and m.movement_type='Return'
           ),0),0) quantity,
           (
             select m.unit_cost from public.inventory_movements m
             where m.organization_id=v_org and m.reference_type='Sale' and m.reference_id=p_sale_id
               and m.product_id=i.product_id and m.movement_direction='Out' and m.movement_type='Sale'
             order by m.created_at,m.id limit 1
           ) unit_cost
    from public.sale_items i
    where i.sale_id=p_sale_id and i.organization_id=v_org
    group by i.product_id
    having greatest(sum(i.quantity)-coalesce((
      select sum(m.quantity) from public.inventory_movements m
      where m.organization_id=v_org and m.reference_type='Sale' and m.reference_id=p_sale_id
        and m.product_id=i.product_id and m.movement_direction='In' and m.movement_type='Return'
    ),0),0)>0
  loop
    if v_row.unit_cost is null then
      raise exception 'Original sale WAC unavailable for product %',v_row.product_id;
    end if;

    v_cost := round(v_row.quantity * v_row.unit_cost,4);
    perform private.wac_in(v_org,v_row.product_id,v_row.quantity,v_row.unit_cost);

    insert into public.inventory_movements(
      organization_id,product_id,movement_direction,movement_type,quantity,
      reference_type,reference_id,unit_cost,movement_date,created_by
    ) values(
      v_org,v_row.product_id,'In','Return',v_row.quantity,'Sale',p_sale_id,
      round(v_row.unit_cost,4),now(),v_user
    );

    insert into public.account_transactions(
      organization_id,transaction_date,transaction_type,reference_type,reference_id,
      contact_id,description,debit,credit,created_by
    ) values
      (v_org,now(),'Sale Cancellation - Inventory','Sale',p_sale_id,v_contact,
       'Inventory restored on sale cancellation - '||v_invoice_no,v_cost,0,v_user),
      (v_org,now(),'Sale Cancellation - COGS','Sale',p_sale_id,v_contact,
       'COGS reversal on sale cancellation - '||v_invoice_no,0,v_cost,v_user);
  end loop;

  v_remaining_amount:=greatest(v_total-v_returned_amount,0);

  if v_remaining_amount>0 then
    insert into public.account_transactions(
      organization_id,transaction_date,transaction_type,reference_type,reference_id,
      contact_id,description,debit,credit,created_by
    ) values
      (v_org,now(),'Sale Revenue Reversal','Sale',p_sale_id,v_contact,
       'Reversal of remaining sale revenue - '||v_invoice_no,v_remaining_amount,0,v_user),
      (v_org,now(),'Sale Receivable Reversal','Sale',p_sale_id,v_contact,
       'Reversal of remaining sale receivable - '||v_invoice_no,0,v_remaining_amount,v_user);
  end if;

  update public.sales set status='Cancelled',updated_at=now()
  where id=p_sale_id and status='Confirmed';

  if not found then raise exception 'Sale cancellation failed'; end if;
  return p_sale_id;
end;
$function$


CREATE OR REPLACE FUNCTION public.confirm_payment(p_payment_id uuid, p_allocations jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_user uuid:=(select auth.uid()); v_org uuid; v_status public.payment_status; v_type public.payment_type;
 v_amount numeric(18,4); v_contact uuid; v_payment_contact uuid; v_method public.payment_method; v_payment_no text;
 v_alloc_sum numeric(18,4); v_count integer; v_key_count integer; a record;
 v_target_total numeric(18,4); v_paid numeric(18,4); v_outstanding numeric(18,4); v_returned numeric(18,4):=0;
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if p_allocations is null or jsonb_typeof(p_allocations)<>'array' then raise exception 'Allocations must be a JSON array'; end if;
 select organization_id,status,payment_type,amount,contact_id,payment_method,payment_no
 into v_org,v_status,v_type,v_amount,v_payment_contact,v_method,v_payment_no
 from public.payments where id=p_payment_id for update;
 if not found then raise exception 'Payment not found'; end if;
 perform public.rpc_assert_member(v_org);
 if v_status<>'Draft' then raise exception 'Only Draft payments can be confirmed'; end if;
 if jsonb_array_length(p_allocations)=0 then raise exception 'A confirmed payment must have at least one allocation'; end if;
 select count(*),count(distinct case when x.sale_id is not null then 'sale:'||x.sale_id::text when x.purchase_id is not null then 'purchase:'||x.purchase_id::text when x.expense_id is not null then 'expense:'||x.expense_id::text end)
 into v_count,v_key_count
 from jsonb_to_recordset(p_allocations) x(sale_id uuid,purchase_id uuid,expense_id uuid,allocated_amount numeric);
 if v_count<>v_key_count then raise exception 'Duplicate payment allocation target'; end if;
 select coalesce(sum(x.allocated_amount),0) into v_alloc_sum
 from jsonb_to_recordset(p_allocations) x(sale_id uuid,purchase_id uuid,expense_id uuid,allocated_amount numeric);
 if v_alloc_sum<>v_amount then raise exception 'Payment allocations must equal the full payment amount'; end if;
 if exists(select 1 from public.payment_allocations where payment_id=p_payment_id) then raise exception 'Payment already has allocations'; end if;

 for a in select * from jsonb_to_recordset(p_allocations) x(sale_id uuid,purchase_id uuid,expense_id uuid,allocated_amount numeric)
 order by coalesce(x.sale_id::text,x.purchase_id::text,x.expense_id::text)
 loop
  if a.allocated_amount is null or a.allocated_amount<=0 then raise exception 'Allocation amount must be greater than zero'; end if;
  if num_nonnulls(a.sale_id,a.purchase_id,a.expense_id)<>1 then raise exception 'Each allocation must target exactly one document'; end if;
  if v_type='In' and (a.purchase_id is not null or a.expense_id is not null) then raise exception 'Payment In can only be allocated to Sales'; end if;
  if v_type='Out' and a.sale_id is not null then raise exception 'Payment Out cannot be allocated to Sales'; end if;

  if a.sale_id is not null then
   select total,contact_id into v_target_total,v_contact from public.sales
   where id=a.sale_id and organization_id=v_org and status='Confirmed' for update;
   if not found then raise exception 'Target Sale must be Confirmed and belong to the same organization'; end if;
   if v_payment_contact is null or v_contact<>v_payment_contact then raise exception 'Payment contact must match Sale contact'; end if;
   select coalesce(sum(pa.allocated_amount),0) into v_paid
   from public.payment_allocations pa join public.payments py on py.id=pa.payment_id
   where pa.sale_id=a.sale_id and pa.organization_id=v_org and py.status='Confirmed';
   select coalesce(sum(debit),0) into v_returned
   from public.account_transactions
   where organization_id=v_org and reference_type='Sale' and reference_id=a.sale_id
     and transaction_type='Sale Return - Revenue';
  elsif a.purchase_id is not null then
   select total,contact_id into v_target_total,v_contact from public.purchases
   where id=a.purchase_id and organization_id=v_org and status='Confirmed' for update;
   if not found then raise exception 'Target Purchase must be Confirmed and belong to the same organization'; end if;
   if v_payment_contact is null or v_contact<>v_payment_contact then raise exception 'Payment contact must match Purchase contact'; end if;
   select coalesce(sum(pa.allocated_amount),0) into v_paid
   from public.payment_allocations pa join public.payments py on py.id=pa.payment_id
   where pa.purchase_id=a.purchase_id and pa.organization_id=v_org and py.status='Confirmed';
   select coalesce(sum(debit),0) into v_returned
   from public.account_transactions
   where organization_id=v_org and reference_type='Purchase' and reference_id=a.purchase_id
     and transaction_type='Purchase Return - Payable';
  else
   select amount,contact_id into v_target_total,v_contact from public.expenses
   where id=a.expense_id and organization_id=v_org and status='Confirmed' for update;
   if not found then raise exception 'Target Expense must be Confirmed and belong to the same organization'; end if;
   if v_contact is not null and (v_payment_contact is null or v_contact<>v_payment_contact) then raise exception 'Payment contact must match Expense contact when the expense has a contact'; end if;
   select coalesce(sum(pa.allocated_amount),0) into v_paid
   from public.payment_allocations pa join public.payments py on py.id=pa.payment_id
   where pa.expense_id=a.expense_id and pa.organization_id=v_org and py.status='Confirmed';
  end if;

  v_outstanding:=greatest(v_target_total-v_paid-coalesce(v_returned,0),0);
  if a.allocated_amount>v_outstanding then raise exception 'Allocation exceeds target outstanding balance'; end if;

  insert into public.payment_allocations(organization_id,payment_id,purchase_id,sale_id,expense_id,allocated_amount,created_by)
  values(v_org,p_payment_id,a.purchase_id,a.sale_id,a.expense_id,a.allocated_amount,v_user);
 end loop;

 if v_type='In' then
  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by)
  values(v_org,now(),'Payment In - '||v_method::text,'Payment',p_payment_id,v_payment_contact,'Payment received - '||v_payment_no,v_amount,0,v_user),
        (v_org,now(),'Payment In - Receivable Settlement','Payment',p_payment_id,v_payment_contact,'Receivable settlement - '||v_payment_no,0,v_amount,v_user);
 else
  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by)
  values(v_org,now(),'Payment Out - Payable Settlement','Payment',p_payment_id,v_payment_contact,'Payable settlement - '||v_payment_no,v_amount,0,v_user),
        (v_org,now(),'Payment Out - '||v_method::text,'Payment',p_payment_id,v_payment_contact,'Payment made - '||v_payment_no,0,v_amount,v_user);
 end if;

 update public.payments set status='Confirmed' where id=p_payment_id and status='Draft';
 if not found then raise exception 'Payment confirmation failed'; end if;
 return p_payment_id;
end;$function$


CREATE OR REPLACE FUNCTION public.confirm_purchase(p_purchase_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u uuid=(select auth.uid());o uuid;contact uuid;st public.invoice_status;total numeric;disc numeric;n int;sub numeric;exp numeric;r record;
begin
 if u is null then raise exception 'Authentication required';end if;
 select organization_id,contact_id,status,total,discount into o,contact,st,total,disc from public.purchases where id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found';end if;
 if not exists(select 1 from public.organization_users where organization_id=o and user_id=u) then raise exception 'User is not a member of this organization';end if;
 if st<>'Draft' then raise exception 'Only Draft purchase invoices can be confirmed';end if;
 select count(*),coalesce(sum(line_total),0) into n,sub from public.purchase_items where purchase_id=p_purchase_id and organization_id=o;
 if n=0 then raise exception 'A purchase must contain at least one item';end if;
 disc=coalesce(disc,0);exp=sub-disc;
 if disc<0 or disc>sub or exp<>total then raise exception 'Purchase total does not match its item totals after overall discount';end if;
 insert into public.inventory_movements(organization_id,product_id,movement_direction,movement_type,quantity,reference_type,reference_id,unit_cost,movement_date,created_by)
 with x as(select pi.product_id,pi.quantity,pi.line_total,row_number() over(order by pi.product_id,pi.id) rn,count(*) over() cnt,sum(pi.line_total) over() net from public.purchase_items pi where pi.purchase_id=p_purchase_id and pi.organization_id=o),
 a as(select x.*,case when rn=cnt then disc-coalesce((select sum(round(disc*y.line_total/nullif(y.net,0),4)) from x y where y.rn<x.rn),0) else round(disc*x.line_total/nullif(x.net,0),4) end ad from x)
 select o,product_id,'In','Purchase',quantity,'purchase',p_purchase_id,round((line_total-ad)/nullif(quantity,0),4),now(),u from a;
 for r in select product_id,quantity,unit_cost from public.inventory_movements where organization_id=o and reference_type='purchase' and reference_id=p_purchase_id order by created_at,id loop perform private.wac_in(o,r.product_id,r.quantity,r.unit_cost);end loop;
 insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by)
 values(o,now(),'Purchase','purchase',p_purchase_id,contact,'Purchase payable - invoice '||(select invoice_no from public.purchases where id=p_purchase_id),0,total,u);
 update public.purchases set status='Confirmed',updated_at=now() where id=p_purchase_id;
 return jsonb_build_object('purchase_id',p_purchase_id,'status','Confirmed','total',total);
end $function$


CREATE OR REPLACE FUNCTION public.confirm_sale(p_sale_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u uuid=(select auth.uid());o uuid;st public.invoice_status;total numeric;disc numeric;sub numeric;exp numeric;n int;r record;c numeric;cg numeric;d date;contact uuid;inv text;
begin
 if u is null then raise exception 'Authentication required';end if;
 select organization_id,status,total,discount,invoice_date,contact_id,invoice_no into o,st,total,disc,d,contact,inv from public.sales where id=p_sale_id for update;
 if not found then raise exception 'Sale not found';end if;perform public.rpc_assert_member(o);if st<>'Draft' then raise exception 'Only Draft sales can be confirmed';end if;
 select count(*),coalesce(sum(line_total),0) into n,sub from public.sale_items where sale_id=p_sale_id and organization_id=o;
 if n=0 then raise exception 'Sale must contain at least one item';end if;
 disc=coalesce(disc,0);exp=sub-disc;if disc<0 or disc>sub or exp<>total then raise exception 'Sale total does not match its item totals after overall discount';end if;
 if exists(select 1 from public.inventory_movements where organization_id=o and reference_type='Sale' and reference_id=p_sale_id) or exists(select 1 from public.account_transactions where organization_id=o and reference_type='Sale' and reference_id=p_sale_id) then raise exception 'Sale already has ledger effects';end if;
 for r in select product_id,sum(quantity) quantity from public.sale_items where sale_id=p_sale_id and organization_id=o group by product_id order by product_id loop
  c=private.wac_out(o,r.product_id,r.quantity);cg=round(r.quantity*c,4);
  insert into public.inventory_movements(organization_id,product_id,movement_direction,movement_type,quantity,reference_type,reference_id,unit_cost,movement_date,created_by) values(o,r.product_id,'Out','Sale',r.quantity,'Sale',p_sale_id,round(c,4),d,u);
  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by) values
  (o,d::timestamptz,'COGS','Sale',p_sale_id,contact,'COGS - '||inv,cg,0,u),(o,d::timestamptz,'Inventory - COGS','Sale',p_sale_id,contact,'Inventory reduction - '||inv,0,cg,u);
 end loop;
 insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by) values
 (o,d::timestamptz,'Sale Receivable','Sale',p_sale_id,contact,'Sale receivable - '||inv,total,0,u),(o,d::timestamptz,'Sale Revenue','Sale',p_sale_id,contact,'Sale revenue - '||inv,0,total,u);
 update public.sales set status='Confirmed',updated_at=now() where id=p_sale_id;return p_sale_id;
end $function$


CREATE OR REPLACE FUNCTION public.outstanding_for_documents(p_document_type text, p_document_ids uuid[])
 RETURNS TABLE(document_id uuid, outstanding numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id uuid; v_org uuid; v_total numeric(18,4); v_paid numeric(18,4); v_returned numeric(18,4);
begin
 if lower(btrim(p_document_type)) not in ('sale','purchase','expense') then raise exception 'Document type must be sale, purchase, or expense'; end if;
 if p_document_ids is null then return; end if;
 foreach v_id in array p_document_ids loop
  v_paid:=0; v_returned:=0; v_org:=null; v_total:=null;
  if lower(btrim(p_document_type))='sale' then
   select s.organization_id,s.total into v_org,v_total from public.sales s where s.id=v_id and s.status='Confirmed';
   if v_org is null then raise exception 'Confirmed sale not found'; end if;
   perform public.rpc_assert_member(v_org);
   select coalesce(sum(pa.allocated_amount),0) into v_paid
   from public.payment_allocations pa join public.payments py on py.id=pa.payment_id
   where pa.organization_id=v_org and pa.sale_id=v_id and py.status='Confirmed';
   select coalesce(sum(at.debit),0) into v_returned
   from public.account_transactions at
   where at.organization_id=v_org and at.reference_type='Sale' and at.reference_id=v_id
     and at.transaction_type='Sale Return - Revenue';
  elsif lower(btrim(p_document_type))='purchase' then
   select p.organization_id,p.total into v_org,v_total from public.purchases p where p.id=v_id and p.status='Confirmed';
   if v_org is null then raise exception 'Confirmed purchase not found'; end if;
   perform public.rpc_assert_member(v_org);
   select coalesce(sum(pa.allocated_amount),0) into v_paid
   from public.payment_allocations pa join public.payments py on py.id=pa.payment_id
   where pa.organization_id=v_org and pa.purchase_id=v_id and py.status='Confirmed';
   select coalesce(sum(at.debit),0) into v_returned
   from public.account_transactions at
   where at.organization_id=v_org and at.reference_type='Purchase' and at.reference_id=v_id
     and at.transaction_type='Purchase Return - Payable';
  else
   select e.organization_id,e.amount into v_org,v_total from public.expenses e where e.id=v_id and e.status='Confirmed';
   if v_org is null then raise exception 'Confirmed expense not found'; end if;
   perform public.rpc_assert_member(v_org);
   select coalesce(sum(pa.allocated_amount),0) into v_paid
   from public.payment_allocations pa join public.payments py on py.id=pa.payment_id
   where pa.organization_id=v_org and pa.expense_id=v_id and py.status='Confirmed';
  end if;
  document_id:=v_id; outstanding:=greatest(v_total-v_paid-v_returned,0); return next;
 end loop;
end;$function$


CREATE OR REPLACE FUNCTION public.purchase_outstanding(p_purchase_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_org uuid; v_total numeric(18,4); v_paid numeric(18,4); v_returned numeric(18,4):=0;
begin
 select organization_id,total into v_org,v_total from public.purchases where id=p_purchase_id and status='Confirmed';
 if not found then raise exception 'Confirmed purchase not found'; end if;
 perform public.rpc_assert_member(v_org);
 select coalesce(sum(pa.allocated_amount),0) into v_paid
 from public.payment_allocations pa join public.payments py on py.id=pa.payment_id
 where pa.organization_id=v_org and pa.purchase_id=p_purchase_id and py.status='Confirmed';
 select coalesce(sum(debit),0) into v_returned
 from public.account_transactions
 where organization_id=v_org and reference_type='Purchase' and reference_id=p_purchase_id
   and transaction_type='Purchase Return - Payable';
 return greatest(v_total-v_paid-v_returned,0);
end;$function$


CREATE OR REPLACE FUNCTION public.record_stock_adjustment(p_organization_id uuid, p_product_id uuid, p_quantity numeric, p_direction inventory_movement_direction, p_movement_type inventory_movement_type, p_unit_cost numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u uuid=(select auth.uid());id uuid;c numeric;
begin
 if u is null then raise exception 'Authentication required';end if;if p_movement_type not in ('Opening','Adjustment') then raise exception 'Only Opening and Adjustment movements can be recorded here';end if;if p_quantity is null or p_quantity<=0 then raise exception 'Quantity must be greater than zero';end if;if p_unit_cost is not null and p_unit_cost<0 then raise exception 'Unit cost cannot be negative';end if;
 perform public.rpc_assert_member(p_organization_id);if not exists(select 1 from public.products where id=p_product_id and organization_id=p_organization_id) then raise exception 'Product not found in this organization';end if;
 if p_direction='In' then select average_cost into c from public.stock where organization_id=p_organization_id and product_id=p_product_id for update;c=coalesce(p_unit_cost,c);if c is null then raise exception 'Unit cost is required for inbound Opening/Adjustment';end if;perform private.wac_in(p_organization_id,p_product_id,p_quantity,c);
 else select average_cost into c from public.stock where organization_id=p_organization_id and product_id=p_product_id for update;if c is null then raise exception 'No inventory cost exists for this product';end if;c=private.wac_out(p_organization_id,p_product_id,p_quantity);end if;
 insert into public.inventory_movements(organization_id,product_id,movement_direction,movement_type,quantity,reference_type,reference_id,unit_cost,movement_date,created_by) values(p_organization_id,p_product_id,p_direction,p_movement_type,p_quantity,null,null,round(c,4),now(),u) returning id into id;
 return id;
end $function$


CREATE OR REPLACE FUNCTION public.return_purchase_items(p_purchase_id uuid, p_lines jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u uuid=(select auth.uid());o uuid;st public.invoice_status;contact uuid;inv text;hd numeric;doc numeric;l record;i record;bought numeric;returned numeric;rem numeric;take numeric;rowrem numeric;base numeric=0;amt numeric=0;ibase numeric;c numeric;cost numeric=0;
begin
 if u is null then raise exception 'Authentication required';end if;if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'Return lines must be a non-empty JSON array';end if;
 select organization_id,status,contact_id,invoice_no,coalesce(discount,0) into o,st,contact,inv,hd from public.purchases where id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found';end if;perform public.rpc_assert_member(o);if st<>'Confirmed' then raise exception 'Only Confirmed purchases can be returned';end if;
 select coalesce(sum(line_total),0) into doc from public.purchase_items where purchase_id=p_purchase_id and organization_id=o;
 if hd<0 or hd>doc then raise exception 'Purchase header discount is invalid';end if;
 if exists(select 1 from public.payment_allocations pa join public.payments py on py.id=pa.payment_id where pa.organization_id=o and pa.purchase_id=p_purchase_id and py.status='Confirmed') then raise exception 'Purchase cannot be returned while confirmed payments are allocated to it';end if;
 for l in select x.product_id,sum(x.quantity) quantity from jsonb_to_recordset(p_lines) x(product_id uuid,quantity numeric) group by x.product_id loop
  select coalesce(sum(quantity),0) into bought from public.purchase_items where purchase_id=p_purchase_id and organization_id=o and product_id=l.product_id;
  select coalesce(sum(quantity),0) into returned from public.inventory_movements where organization_id=o and reference_type='Purchase' and reference_id=p_purchase_id and product_id=l.product_id and movement_direction='Out' and movement_type='Return';
  rem=bought-returned;if bought<=0 or l.quantity<=0 or l.quantity>rem then raise exception 'Return quantity exceeds remaining quantity for product %',l.product_id;end if;
  rowrem=l.quantity;
  for i in select product_id,quantity,unit_price,discount,line_total from public.purchase_items where purchase_id=p_purchase_id and organization_id=o and product_id=l.product_id order by created_at,id loop
   exit when rowrem<=0;take=least(rowrem,i.quantity);ibase=take*i.unit_price-i.discount*(take/i.quantity);base=base+ibase;
   select average_cost into c from public.stock where organization_id=o and product_id=i.product_id for update;
   if c is null then raise exception 'Current WAC unavailable for product %',i.product_id;end if;
   cost=cost+round(take*c,4);perform private.wac_out(o,i.product_id,take);
   insert into public.inventory_movements(organization_id,product_id,movement_direction,movement_type,quantity,reference_type,reference_id,unit_cost,movement_date,created_by) values(o,i.product_id,'Out','Return',take,'Purchase',p_purchase_id,round(c,4),now(),u);
   rowrem=rowrem-take;
  end loop;
 end loop;
 if doc>0 then amt=round(base-hd*(base/doc),4);end if;
 if amt>0 then
  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by) values
  (o,now(),'Purchase Return - Payable','Purchase',p_purchase_id,contact,'Reversal of purchase payable (return) - '||inv,amt,0,u);
  if cost<=amt then
   insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by) values
   (o,now(),'Purchase Return - Inventory','Purchase',p_purchase_id,contact,'Inventory reduction at WAC - '||inv,0,cost,u),
   (o,now(),'Purchase Return - Cost Variance','Purchase',p_purchase_id,contact,'WAC vs purchase return amount',0,amt-cost,u);
  else
   insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by) values
   (o,now(),'Purchase Return - Inventory','Purchase',p_purchase_id,contact,'Inventory reduction at WAC - '||inv,0,cost,u),
   (o,now(),'Purchase Return - Cost Variance','Purchase',p_purchase_id,contact,'WAC vs purchase return amount',cost-amt,0,u);
  end if;
 end if;
 return amt;
end $function$


CREATE OR REPLACE FUNCTION public.return_sale_items(p_sale_id uuid, p_lines jsonb)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u uuid=(select auth.uid());o uuid;st public.invoice_status;contact uuid;inv text;hd numeric;doc numeric;l record;i record;sold numeric;returned numeric;rem numeric;take numeric;rowrem numeric;base numeric=0;amt numeric=0;ibase numeric;c numeric;cost numeric=0;
begin
 if u is null then raise exception 'Authentication required';end if;if p_lines is null or jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)=0 then raise exception 'Return lines must be a non-empty JSON array';end if;
 select organization_id,status,contact_id,invoice_no,coalesce(discount,0) into o,st,contact,inv,hd from public.sales where id=p_sale_id for update;
 if not found then raise exception 'Sale not found';end if;perform public.rpc_assert_member(o);if st<>'Confirmed' then raise exception 'Only Confirmed sales can be returned';end if;
 select coalesce(sum(line_total),0) into doc from public.sale_items where sale_id=p_sale_id and organization_id=o;
 if hd<0 or hd>doc then raise exception 'Sale header discount is invalid';end if;
 if exists(select 1 from public.payment_allocations pa join public.payments py on py.id=pa.payment_id where pa.organization_id=o and pa.sale_id=p_sale_id and py.status='Confirmed') then raise exception 'Sale cannot be returned while confirmed payments are allocated to it';end if;
 for l in select x.product_id,sum(x.quantity) quantity from jsonb_to_recordset(p_lines) x(product_id uuid,quantity numeric) group by x.product_id loop
  select coalesce(sum(quantity),0) into sold from public.sale_items where sale_id=p_sale_id and organization_id=o and product_id=l.product_id;
  select coalesce(sum(quantity),0) into returned from public.inventory_movements where organization_id=o and reference_type='Sale' and reference_id=p_sale_id and product_id=l.product_id and movement_direction='In' and movement_type='Return';
  rem=sold-returned;if sold<=0 or l.quantity<=0 or l.quantity>rem then raise exception 'Return quantity exceeds remaining quantity for product %',l.product_id;end if;
  rowrem=l.quantity;
  for i in select product_id,quantity,unit_price,discount,line_total from public.sale_items where sale_id=p_sale_id and organization_id=o and product_id=l.product_id order by created_at,id loop
   exit when rowrem<=0;take=least(rowrem,i.quantity);ibase=take*i.unit_price-i.discount*(take/i.quantity);base=base+ibase;
   select unit_cost into c from public.inventory_movements where organization_id=o and reference_type='Sale' and reference_id=p_sale_id and product_id=i.product_id and movement_type='Sale' and movement_direction='Out' order by created_at,id limit 1;
   if c is null then select average_cost into c from public.stock where organization_id=o and product_id=i.product_id;end if;
   if c is null then raise exception 'Sale cost unavailable for product %',i.product_id;end if;
   cost=cost+round(take*c,4);perform private.wac_in(o,i.product_id,take,c);
   insert into public.inventory_movements(organization_id,product_id,movement_direction,movement_type,quantity,reference_type,reference_id,unit_cost,movement_date,created_by) values(o,i.product_id,'In','Return',take,'Sale',p_sale_id,round(c,4),now(),u);
   rowrem=rowrem-take;
  end loop;
 end loop;
 if doc>0 then amt=round(base-hd*(base/doc),4);end if;
 if amt>0 then
  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by) values
  (o,now(),'Sale Return - Revenue','Sale',p_sale_id,contact,'Reversal of sale revenue (return) - '||inv,amt,0,u),
  (o,now(),'Sale Return - Receivable','Sale',p_sale_id,contact,'Reversal of sale receivable (return) - '||inv,0,amt,u);
 end if;
 if cost>0 then
  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by) values
  (o,now(),'Sale Return - Inventory','Sale',p_sale_id,contact,'Inventory restored at WAC - '||inv,cost,0,u),
  (o,now(),'Sale Return - COGS','Sale',p_sale_id,contact,'COGS reversal - '||inv,0,cost,u);
 end if;
 return amt;
end $function$


CREATE OR REPLACE FUNCTION public.sale_outstanding(p_sale_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_org uuid; v_total numeric(18,4); v_paid numeric(18,4); v_returned numeric(18,4):=0;
begin
 select organization_id,total into v_org,v_total from public.sales where id=p_sale_id and status='Confirmed';
 if not found then raise exception 'Confirmed sale not found'; end if;
 perform public.rpc_assert_member(v_org);
 select coalesce(sum(pa.allocated_amount),0) into v_paid
 from public.payment_allocations pa join public.payments py on py.id=pa.payment_id
 where pa.organization_id=v_org and pa.sale_id=p_sale_id and py.status='Confirmed';
 select coalesce(sum(debit),0) into v_returned
 from public.account_transactions
 where organization_id=v_org and reference_type='Sale' and reference_id=p_sale_id
   and transaction_type='Sale Return - Revenue';
 return greatest(v_total-v_paid-v_returned,0);
end;$function$


CREATE OR REPLACE FUNCTION public.update_purchase_draft(p_purchase_id uuid, p_contact_id uuid, p_invoice_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb, p_overall_discount numeric DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb; v_gross numeric; v_item_discount numeric; v_net numeric; v_overall numeric := coalesce(p_overall_discount,0);
begin
  if v_overall < 0 then raise exception 'Overall discount cannot be negative'; end if;
  v_result := public.update_purchase_draft_base(p_purchase_id,p_contact_id,p_invoice_date,p_notes,p_items);
  select coalesce(sum(x.quantity*x.unit_price),0),coalesce(sum(coalesce(x.discount,0)),0) into v_gross,v_item_discount
  from jsonb_to_recordset(p_items) x(id uuid,product_id uuid,quantity numeric,unit_price numeric,discount numeric);
  v_net := v_gross-v_item_discount;
  if v_overall > v_net then raise exception 'Overall discount cannot exceed subtotal after item discounts'; end if;
  update public.purchases set subtotal=v_net,discount=v_overall,total=v_net-v_overall,updated_at=now() where id=p_purchase_id;
  return jsonb_build_object('purchase_id',p_purchase_id);
end $function$


CREATE OR REPLACE FUNCTION public.update_sale_draft(p_sale_id uuid, p_contact_id uuid, p_invoice_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_items jsonb DEFAULT '[]'::jsonb, p_overall_discount numeric DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_result jsonb; v_gross numeric; v_item_discount numeric; v_net numeric; v_overall numeric := coalesce(p_overall_discount,0);
begin
  if v_overall < 0 then raise exception 'Overall discount cannot be negative'; end if;
  v_result := public.update_sale_draft_base(p_sale_id,p_contact_id,p_invoice_date,p_notes,p_items);
  select coalesce(sum(x.quantity*x.unit_price),0),coalesce(sum(coalesce(x.discount,0)),0) into v_gross,v_item_discount
  from jsonb_to_recordset(p_items) x(id uuid,product_id uuid,quantity numeric,unit_price numeric,discount numeric);
  v_net := v_gross-v_item_discount;
  if v_overall > v_net then raise exception 'Overall discount cannot exceed subtotal after item discounts'; end if;
  update public.sales set subtotal=v_net,discount=v_overall,total=v_net-v_overall,updated_at=now() where id=p_sale_id;
  return jsonb_build_object('sale_id',p_sale_id);
end $function$


-- Security hardening applied to all current SECURITY DEFINER public RPCs.
ALTER FUNCTION public.add_organization_member(p_organization_id uuid, p_email text) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.add_organization_member(p_organization_id uuid, p_email text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.add_organization_member(p_organization_id uuid, p_email text) TO authenticated;

ALTER FUNCTION public.cancel_expense(p_expense_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.cancel_expense(p_expense_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_expense(p_expense_id uuid) TO authenticated;

ALTER FUNCTION public.cancel_payment(p_payment_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.cancel_payment(p_payment_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_payment(p_payment_id uuid) TO authenticated;

ALTER FUNCTION public.cancel_purchase(p_purchase_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.cancel_purchase(p_purchase_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_purchase(p_purchase_id uuid) TO authenticated;

ALTER FUNCTION public.cancel_sale(p_sale_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.cancel_sale(p_sale_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cancel_sale(p_sale_id uuid) TO authenticated;

ALTER FUNCTION public.confirm_expense(p_expense_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.confirm_expense(p_expense_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_expense(p_expense_id uuid) TO authenticated;

ALTER FUNCTION public.confirm_payment(p_payment_id uuid, p_allocations jsonb) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.confirm_payment(p_payment_id uuid, p_allocations jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_payment(p_payment_id uuid, p_allocations jsonb) TO authenticated;

ALTER FUNCTION public.confirm_purchase(p_purchase_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.confirm_purchase(p_purchase_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_purchase(p_purchase_id uuid) TO authenticated;

ALTER FUNCTION public.confirm_sale(p_sale_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.confirm_sale(p_sale_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.confirm_sale(p_sale_id uuid) TO authenticated;

ALTER FUNCTION public.create_organization(p_organization_name text, p_phone_number text, p_email text, p_address text, p_tin text, p_bin text) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.create_organization(p_organization_name text, p_phone_number text, p_email text, p_address text, p_tin text, p_bin text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_organization(p_organization_name text, p_phone_number text, p_email text, p_address text, p_tin text, p_bin text) TO authenticated;

ALTER FUNCTION public.create_purchase_draft(p_organization_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb, p_overall_discount numeric) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.create_purchase_draft(p_organization_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb, p_overall_discount numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_purchase_draft(p_organization_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb, p_overall_discount numeric) TO authenticated;

ALTER FUNCTION public.create_purchase_draft_base(p_organization_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.create_purchase_draft_base(p_organization_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_purchase_draft_base(p_organization_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb) TO authenticated;

ALTER FUNCTION public.create_sale_draft(p_organization_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb, p_overall_discount numeric) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.create_sale_draft(p_organization_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb, p_overall_discount numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_sale_draft(p_organization_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb, p_overall_discount numeric) TO authenticated;

ALTER FUNCTION public.create_sale_draft_base(p_organization_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.create_sale_draft_base(p_organization_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_sale_draft_base(p_organization_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb) TO authenticated;

ALTER FUNCTION public.delete_sale_draft(p_sale_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.delete_sale_draft(p_sale_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_sale_draft(p_sale_id uuid) TO authenticated;

ALTER FUNCTION public.handle_new_user() SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.handle_new_user() TO authenticated;

ALTER FUNCTION public.next_contact_id_no(p_organization_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.next_contact_id_no(p_organization_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.next_contact_id_no(p_organization_id uuid) TO authenticated;

ALTER FUNCTION public.next_expense_no(p_organization_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.next_expense_no(p_organization_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.next_expense_no(p_organization_id uuid) TO authenticated;

ALTER FUNCTION public.next_payment_no(p_organization_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.next_payment_no(p_organization_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.next_payment_no(p_organization_id uuid) TO authenticated;

ALTER FUNCTION public.next_purchase_invoice_no(p_organization_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.next_purchase_invoice_no(p_organization_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.next_purchase_invoice_no(p_organization_id uuid) TO authenticated;

ALTER FUNCTION public.next_sales_invoice_no(p_organization_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.next_sales_invoice_no(p_organization_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.next_sales_invoice_no(p_organization_id uuid) TO authenticated;

ALTER FUNCTION public.organization_members(p_organization_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.organization_members(p_organization_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.organization_members(p_organization_id uuid) TO authenticated;

ALTER FUNCTION public.outstanding_for_documents(p_document_type text, p_document_ids uuid[]) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.outstanding_for_documents(p_document_type text, p_document_ids uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.outstanding_for_documents(p_document_type text, p_document_ids uuid[]) TO authenticated;

ALTER FUNCTION public.record_stock_adjustment(p_organization_id uuid, p_product_id uuid, p_quantity numeric, p_direction inventory_movement_direction, p_movement_type inventory_movement_type, p_unit_cost numeric, p_notes text) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.record_stock_adjustment(p_organization_id uuid, p_product_id uuid, p_quantity numeric, p_direction inventory_movement_direction, p_movement_type inventory_movement_type, p_unit_cost numeric, p_notes text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.record_stock_adjustment(p_organization_id uuid, p_product_id uuid, p_quantity numeric, p_direction inventory_movement_direction, p_movement_type inventory_movement_type, p_unit_cost numeric, p_notes text) TO authenticated;

ALTER FUNCTION public.remove_organization_member(p_organization_id uuid, p_user_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.remove_organization_member(p_organization_id uuid, p_user_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.remove_organization_member(p_organization_id uuid, p_user_id uuid) TO authenticated;

ALTER FUNCTION public.return_purchase_items(p_purchase_id uuid, p_lines jsonb) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.return_purchase_items(p_purchase_id uuid, p_lines jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.return_purchase_items(p_purchase_id uuid, p_lines jsonb) TO authenticated;

ALTER FUNCTION public.return_sale_items(p_sale_id uuid, p_lines jsonb) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.return_sale_items(p_sale_id uuid, p_lines jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.return_sale_items(p_sale_id uuid, p_lines jsonb) TO authenticated;

ALTER FUNCTION public.rpc_assert_member(p_organization_id uuid) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.rpc_assert_member(p_organization_id uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_assert_member(p_organization_id uuid) TO authenticated;

ALTER FUNCTION public.set_organization_member_role(p_organization_id uuid, p_user_id uuid, p_role text) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.set_organization_member_role(p_organization_id uuid, p_user_id uuid, p_role text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.set_organization_member_role(p_organization_id uuid, p_user_id uuid, p_role text) TO authenticated;

ALTER FUNCTION public.update_purchase_draft(p_purchase_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb, p_overall_discount numeric) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.update_purchase_draft(p_purchase_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb, p_overall_discount numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_purchase_draft(p_purchase_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb, p_overall_discount numeric) TO authenticated;

ALTER FUNCTION public.update_purchase_draft_base(p_purchase_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.update_purchase_draft_base(p_purchase_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_purchase_draft_base(p_purchase_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb) TO authenticated;

ALTER FUNCTION public.update_sale_draft(p_sale_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb, p_overall_discount numeric) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.update_sale_draft(p_sale_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb, p_overall_discount numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_sale_draft(p_sale_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb, p_overall_discount numeric) TO authenticated;

ALTER FUNCTION public.update_sale_draft_base(p_sale_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb) SET search_path = '';
REVOKE EXECUTE ON FUNCTION public.update_sale_draft_base(p_sale_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_sale_draft_base(p_sale_id uuid, p_contact_id uuid, p_invoice_date date, p_notes text, p_items jsonb) TO authenticated;

REVOKE ALL ON SCHEMA private FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION private.wac_in(uuid,uuid,numeric,numeric) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION private.wac_out(uuid,uuid,numeric) FROM PUBLIC, anon, authenticated;

COMMIT;
