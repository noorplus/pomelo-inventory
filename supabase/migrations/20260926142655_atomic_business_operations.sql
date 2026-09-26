-- Pomelo Inventory - Atomic business operations
-- Synced from the already-applied Supabase migration 20260926142655.
-- RPC/service layer only. No tables are introduced here.
-- SECURITY DEFINER functions validate auth + organization membership and write
-- protected inventory/accounting state atomically.

CREATE OR REPLACE FUNCTION public.rpc_assert_member(p_organization_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := (select auth.uid());
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = p_organization_id
      and ou.user_id = v_user
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  return v_user;
end;
$function$

CREATE OR REPLACE FUNCTION public.confirm_purchase(p_purchase_id uuid)
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
  v_item_total numeric(18,4);
  v_item_count integer;
  r record;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;

  select organization_id, status, total
    into v_org, v_status, v_total
  from public.purchases
  where id = p_purchase_id
  for update;

  if not found then
    raise exception 'Purchase not found';
  end if;

  perform public.rpc_assert_member(v_org);

  if v_status <> 'Draft' then
    raise exception 'Only Draft purchases can be confirmed';
  end if;

  select count(*), coalesce(sum(line_total), 0)
    into v_item_count, v_item_total
  from public.purchase_items
  where purchase_id = p_purchase_id
    and organization_id = v_org;

  if v_item_count = 0 then
    raise exception 'Purchase must contain at least one item';
  end if;

  if v_item_total <> v_total then
    raise exception 'Purchase total does not match item totals';
  end if;

  if exists (
    select 1 from public.inventory_movements
    where organization_id = v_org
      and reference_type = 'Purchase'
      and reference_id = p_purchase_id
  ) or exists (
    select 1 from public.account_transactions
    where organization_id = v_org
      and reference_type = 'Purchase'
      and reference_id = p_purchase_id
  ) then
    raise exception 'Purchase already has ledger effects';
  end if;

  for r in
    select product_id, sum(quantity) as quantity
    from public.purchase_items
    where purchase_id = p_purchase_id
      and organization_id = v_org
    group by product_id
    order by product_id
  loop
    insert into public.stock (organization_id, product_id, quantity)
    values (v_org, r.product_id, r.quantity)
    on conflict (organization_id, product_id)
    do update set quantity = public.stock.quantity + excluded.quantity,
                  updated_at = now();
  end loop;

  insert into public.inventory_movements (
    organization_id, product_id, movement_direction, movement_type,
    quantity, reference_type, reference_id, unit_cost, movement_date, created_by
  )
  select
    v_org, pi.product_id, 'In', 'Purchase',
    pi.quantity, 'Purchase', p_purchase_id, pi.unit_price, p.invoice_date, v_user
  from public.purchase_items pi
  join public.purchases p on p.id = pi.purchase_id
  where pi.purchase_id = p_purchase_id
    and pi.organization_id = v_org;

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description,
    debit, credit, created_by
  )
  select v_org, p.invoice_date::timestamptz, 'Purchase Inventory',
         'Purchase', p.id, p.contact_id,
         'Purchase inventory - ' || p.invoice_no,
         p.total, 0, v_user
  from public.purchases p
  where p.id = p_purchase_id
  union all
  select v_org, p.invoice_date::timestamptz, 'Purchase Payable',
         'Purchase', p.id, p.contact_id,
         'Purchase payable - ' || p.invoice_no,
         0, p.total, v_user
  from public.purchases p
  where p.id = p_purchase_id;

  update public.purchases
  set status = 'Confirmed'
  where id = p_purchase_id
    and status = 'Draft';

  if not found then
    raise exception 'Purchase confirmation failed';
  end if;

  return p_purchase_id;
end;
$function$

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
  r record;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select organization_id, status, total, contact_id, invoice_no
    into v_org, v_status, v_total, v_contact, v_invoice_no
  from public.purchases
  where id = p_purchase_id
  for update;

  if not found then raise exception 'Purchase not found'; end if;
  perform public.rpc_assert_member(v_org);

  if v_status <> 'Confirmed' then
    raise exception 'Only Confirmed purchases can be cancelled';
  end if;

  if exists (
    select 1
    from public.payment_allocations pa
    join public.payments py on py.id = pa.payment_id
    where pa.organization_id = v_org
      and pa.purchase_id = p_purchase_id
      and py.status = 'Confirmed'
  ) then
    raise exception 'Purchase cannot be cancelled while confirmed payments are allocated to it';
  end if;

  if not exists (
    select 1 from public.inventory_movements
    where organization_id = v_org
      and reference_type = 'Purchase'
      and reference_id = p_purchase_id
      and movement_direction = 'In'
      and movement_type = 'Purchase'
  ) then
    raise exception 'Purchase inventory ledger is missing';
  end if;

  if (
    select count(*)
    from public.account_transactions
    where organization_id = v_org
      and reference_type = 'Purchase'
      and reference_id = p_purchase_id
  ) <> 2 then
    raise exception 'Purchase accounting ledger is incomplete';
  end if;

  if exists (
    select 1
    from (
      select product_id, sum(quantity) as quantity
      from public.purchase_items
      where purchase_id = p_purchase_id and organization_id = v_org
      group by product_id
    ) i
    full join (
      select product_id, sum(quantity) as quantity
      from public.inventory_movements
      where organization_id = v_org
        and reference_type = 'Purchase'
        and reference_id = p_purchase_id
        and movement_direction = 'In'
        and movement_type = 'Purchase'
      group by product_id
    ) m using (product_id)
    where coalesce(i.quantity, 0) <> coalesce(m.quantity, 0)
  ) then
    raise exception 'Purchase inventory ledger does not match purchase items';
  end if;

  for r in
    select product_id, quantity, unit_cost
    from public.inventory_movements
    where organization_id = v_org
      and reference_type = 'Purchase'
      and reference_id = p_purchase_id
      and movement_direction = 'In'
      and movement_type = 'Purchase'
    order by product_id, id
  loop
    update public.stock
    set quantity = quantity - r.quantity,
        updated_at = now()
    where organization_id = v_org
      and product_id = r.product_id
      and quantity >= r.quantity;

    if not found then
      raise exception 'Purchase cancellation would make stock negative for product %', r.product_id;
    end if;

    insert into public.inventory_movements (
      organization_id, product_id, movement_direction, movement_type,
      quantity, reference_type, reference_id, unit_cost, movement_date, created_by
    )
    values (
      v_org, r.product_id, 'Out', 'Return',
      r.quantity, 'Purchase', p_purchase_id, r.unit_cost, now(), v_user
    );
  end loop;

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description,
    debit, credit, created_by
  )
  values
    (v_org, now(), 'Purchase Payable Reversal',
     'Purchase', p_purchase_id, v_contact,
     'Reversal of purchase payable - ' || v_invoice_no,
     v_total, 0, v_user),
    (v_org, now(), 'Purchase Inventory Reversal',
     'Purchase', p_purchase_id, v_contact,
     'Reversal of purchase inventory - ' || v_invoice_no,
     0, v_total, v_user);

  update public.purchases
  set status = 'Cancelled'
  where id = p_purchase_id
    and status = 'Confirmed';

  if not found then raise exception 'Purchase cancellation failed'; end if;
  return p_purchase_id;
end;
$function$

CREATE OR REPLACE FUNCTION public.confirm_sale(p_sale_id uuid)
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
  v_item_total numeric(18,4);
  v_item_count integer;
  r record;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select organization_id, status, total
    into v_org, v_status, v_total
  from public.sales
  where id = p_sale_id
  for update;

  if not found then raise exception 'Sale not found'; end if;
  perform public.rpc_assert_member(v_org);

  if v_status <> 'Draft' then raise exception 'Only Draft sales can be confirmed'; end if;

  select count(*), coalesce(sum(line_total), 0)
    into v_item_count, v_item_total
  from public.sale_items
  where sale_id = p_sale_id
    and organization_id = v_org;

  if v_item_count = 0 then raise exception 'Sale must contain at least one item'; end if;
  if v_item_total <> v_total then raise exception 'Sale total does not match item totals'; end if;

  if exists (
    select 1 from public.inventory_movements
    where organization_id = v_org and reference_type = 'Sale' and reference_id = p_sale_id
  ) or exists (
    select 1 from public.account_transactions
    where organization_id = v_org and reference_type = 'Sale' and reference_id = p_sale_id
  ) then
    raise exception 'Sale already has ledger effects';
  end if;

  for r in
    select product_id, sum(quantity) as quantity
    from public.sale_items
    where sale_id = p_sale_id
      and organization_id = v_org
    group by product_id
    order by product_id
  loop
    update public.stock
    set quantity = quantity - r.quantity,
        updated_at = now()
    where organization_id = v_org
      and product_id = r.product_id
      and quantity >= r.quantity;

    if not found then
      raise exception 'Insufficient stock for product %', r.product_id;
    end if;
  end loop;

  insert into public.inventory_movements (
    organization_id, product_id, movement_direction, movement_type,
    quantity, reference_type, reference_id, unit_cost, movement_date, created_by
  )
  select
    v_org, si.product_id, 'Out', 'Sale',
    si.quantity, 'Sale', p_sale_id, null, s.invoice_date, v_user
  from public.sale_items si
  join public.sales s on s.id = si.sale_id
  where si.sale_id = p_sale_id
    and si.organization_id = v_org;

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description,
    debit, credit, created_by
  )
  select v_org, s.invoice_date::timestamptz, 'Sale Receivable',
         'Sale', s.id, s.contact_id,
         'Sale receivable - ' || s.invoice_no,
         s.total, 0, v_user
  from public.sales s
  where s.id = p_sale_id
  union all
  select v_org, s.invoice_date::timestamptz, 'Sale Revenue',
         'Sale', s.id, s.contact_id,
         'Sale revenue - ' || s.invoice_no,
         0, s.total, v_user
  from public.sales s
  where s.id = p_sale_id;

  update public.sales
  set status = 'Confirmed'
  where id = p_sale_id
    and status = 'Draft';

  if not found then raise exception 'Sale confirmation failed'; end if;
  return p_sale_id;
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
  r record;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select organization_id, status, total, contact_id, invoice_no
    into v_org, v_status, v_total, v_contact, v_invoice_no
  from public.sales
  where id = p_sale_id
  for update;

  if not found then raise exception 'Sale not found'; end if;
  perform public.rpc_assert_member(v_org);

  if v_status <> 'Confirmed' then raise exception 'Only Confirmed sales can be cancelled'; end if;

  if exists (
    select 1
    from public.payment_allocations pa
    join public.payments py on py.id = pa.payment_id
    where pa.organization_id = v_org
      and pa.sale_id = p_sale_id
      and py.status = 'Confirmed'
  ) then
    raise exception 'Sale cannot be cancelled while confirmed payments are allocated to it';
  end if;

  if not exists (
    select 1 from public.inventory_movements
    where organization_id = v_org
      and reference_type = 'Sale'
      and reference_id = p_sale_id
      and movement_direction = 'Out'
      and movement_type = 'Sale'
  ) then
    raise exception 'Sale inventory ledger is missing';
  end if;

  if (
    select count(*)
    from public.account_transactions
    where organization_id = v_org
      and reference_type = 'Sale'
      and reference_id = p_sale_id
  ) <> 2 then
    raise exception 'Sale accounting ledger is incomplete';
  end if;

  if exists (
    select 1
    from (
      select product_id, sum(quantity) as quantity
      from public.sale_items
      where sale_id = p_sale_id and organization_id = v_org
      group by product_id
    ) i
    full join (
      select product_id, sum(quantity) as quantity
      from public.inventory_movements
      where organization_id = v_org
        and reference_type = 'Sale'
        and reference_id = p_sale_id
        and movement_direction = 'Out'
        and movement_type = 'Sale'
      group by product_id
    ) m using (product_id)
    where coalesce(i.quantity, 0) <> coalesce(m.quantity, 0)
  ) then
    raise exception 'Sale inventory ledger does not match sale items';
  end if;

  for r in
    select product_id, quantity, unit_cost
    from public.inventory_movements
    where organization_id = v_org
      and reference_type = 'Sale'
      and reference_id = p_sale_id
      and movement_direction = 'Out'
      and movement_type = 'Sale'
    order by product_id, id
  loop
    insert into public.inventory_movements (
      organization_id, product_id, movement_direction, movement_type,
      quantity, reference_type, reference_id, unit_cost, movement_date, created_by
    )
    values (
      v_org, r.product_id, 'In', 'Return',
      r.quantity, 'Sale', p_sale_id, r.unit_cost, now(), v_user
    );

    insert into public.stock (organization_id, product_id, quantity)
    values (v_org, r.product_id, r.quantity)
    on conflict (organization_id, product_id)
    do update set quantity = public.stock.quantity + excluded.quantity,
                  updated_at = now();
  end loop;

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description,
    debit, credit, created_by
  )
  values
    (v_org, now(), 'Sale Revenue Reversal',
     'Sale', p_sale_id, v_contact,
     'Reversal of sale revenue - ' || v_invoice_no,
     v_total, 0, v_user),
    (v_org, now(), 'Sale Receivable Reversal',
     'Sale', p_sale_id, v_contact,
     'Reversal of sale receivable - ' || v_invoice_no,
     0, v_total, v_user);

  update public.sales
  set status = 'Cancelled'
  where id = p_sale_id
    and status = 'Confirmed';

  if not found then raise exception 'Sale cancellation failed'; end if;
  return p_sale_id;
end;
$function$

CREATE OR REPLACE FUNCTION public.confirm_expense(p_expense_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := (select auth.uid());
  v_org uuid;
  v_status public.expense_status;
  v_amount numeric(18,4);
  v_contact uuid;
  v_expense_no text;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select organization_id, status, amount, contact_id, expense_no
    into v_org, v_status, v_amount, v_contact, v_expense_no
  from public.expenses
  where id = p_expense_id
  for update;

  if not found then raise exception 'Expense not found'; end if;
  perform public.rpc_assert_member(v_org);

  if v_status <> 'Draft' then raise exception 'Only Draft expenses can be confirmed'; end if;

  if exists (
    select 1 from public.account_transactions
    where organization_id = v_org
      and reference_type = 'Expense'
      and reference_id = p_expense_id
  ) then
    raise exception 'Expense already has ledger effects';
  end if;

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description,
    debit, credit, created_by
  )
  values
    (v_org, now(), 'Expense',
     'Expense', p_expense_id, v_contact,
     'Expense - ' || v_expense_no,
     v_amount, 0, v_user),
    (v_org, now(), 'Expense Payable',
     'Expense', p_expense_id, v_contact,
     'Expense payable - ' || v_expense_no,
     0, v_amount, v_user);

  update public.expenses
  set status = 'Confirmed'
  where id = p_expense_id
    and status = 'Draft';

  if not found then raise exception 'Expense confirmation failed'; end if;
  return p_expense_id;
end;
$function$

CREATE OR REPLACE FUNCTION public.cancel_expense(p_expense_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := (select auth.uid());
  v_org uuid;
  v_status public.expense_status;
  v_amount numeric(18,4);
  v_contact uuid;
  v_expense_no text;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select organization_id, status, amount, contact_id, expense_no
    into v_org, v_status, v_amount, v_contact, v_expense_no
  from public.expenses
  where id = p_expense_id
  for update;

  if not found then raise exception 'Expense not found'; end if;
  perform public.rpc_assert_member(v_org);

  if v_status <> 'Confirmed' then raise exception 'Only Confirmed expenses can be cancelled'; end if;

  if exists (
    select 1
    from public.payment_allocations pa
    join public.payments py on py.id = pa.payment_id
    where pa.organization_id = v_org
      and pa.expense_id = p_expense_id
      and py.status = 'Confirmed'
  ) then
    raise exception 'Expense cannot be cancelled while confirmed payments are allocated to it';
  end if;

  if (
    select count(*)
    from public.account_transactions
    where organization_id = v_org
      and reference_type = 'Expense'
      and reference_id = p_expense_id
  ) <> 2 then
    raise exception 'Expense accounting ledger is incomplete';
  end if;

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description,
    debit, credit, created_by
  )
  values
    (v_org, now(), 'Expense Payable Reversal',
     'Expense', p_expense_id, v_contact,
     'Reversal of expense payable - ' || v_expense_no,
     v_amount, 0, v_user),
    (v_org, now(), 'Expense Reversal',
     'Expense', p_expense_id, v_contact,
     'Reversal of expense - ' || v_expense_no,
     0, v_amount, v_user);

  update public.expenses
  set status = 'Cancelled'
  where id = p_expense_id
    and status = 'Confirmed';

  if not found then raise exception 'Expense cancellation failed'; end if;
  return p_expense_id;
end;
$function$

CREATE OR REPLACE FUNCTION public.confirm_payment(p_payment_id uuid, p_allocations jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := (select auth.uid());
  v_org uuid;
  v_status public.payment_status;
  v_type public.payment_type;
  v_amount numeric(18,4);
  v_contact uuid;
  v_payment_contact uuid;
  v_method public.payment_method;
  v_payment_no text;
  v_alloc_sum numeric(18,4);
  v_count integer;
  v_key_count integer;
  a record;
  v_target_total numeric(18,4);
  v_paid numeric(18,4);
  v_outstanding numeric(18,4);
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_allocations is null or jsonb_typeof(p_allocations) <> 'array' then
    raise exception 'Allocations must be a JSON array';
  end if;

  select organization_id, status, payment_type, amount, contact_id, payment_method, payment_no
    into v_org, v_status, v_type, v_amount, v_payment_contact, v_method, v_payment_no
  from public.payments
  where id = p_payment_id
  for update;

  if not found then raise exception 'Payment not found'; end if;
  perform public.rpc_assert_member(v_org);

  if v_status <> 'Draft' then raise exception 'Only Draft payments can be confirmed'; end if;
  if jsonb_array_length(p_allocations) = 0 then
    raise exception 'A confirmed payment must have at least one allocation';
  end if;

  select count(*),
         count(distinct case
           when x.sale_id is not null then 'sale:' || x.sale_id::text
           when x.purchase_id is not null then 'purchase:' || x.purchase_id::text
           when x.expense_id is not null then 'expense:' || x.expense_id::text
         end)
    into v_count, v_key_count
  from jsonb_to_recordset(p_allocations) as x(
    sale_id uuid,
    purchase_id uuid,
    expense_id uuid,
    allocated_amount numeric
  );

  if v_count <> v_key_count then
    raise exception 'Duplicate payment allocation target';
  end if;

  select coalesce(sum(x.allocated_amount), 0)
    into v_alloc_sum
  from jsonb_to_recordset(p_allocations) as x(
    sale_id uuid,
    purchase_id uuid,
    expense_id uuid,
    allocated_amount numeric
  );

  if v_alloc_sum <> v_amount then
    raise exception 'Payment allocations must equal the full payment amount';
  end if;

  if exists (
    select 1
    from public.payment_allocations pa
    where pa.payment_id = p_payment_id
  ) then
    raise exception 'Payment already has allocations';
  end if;

  for a in
    select *
    from jsonb_to_recordset(p_allocations) as x(
      sale_id uuid,
      purchase_id uuid,
      expense_id uuid,
      allocated_amount numeric
    )
    order by coalesce(x.sale_id::text, x.purchase_id::text, x.expense_id::text)
  loop
    if a.allocated_amount is null or a.allocated_amount <= 0 then
      raise exception 'Allocation amount must be greater than zero';
    end if;

    if num_nonnulls(a.sale_id, a.purchase_id, a.expense_id) <> 1 then
      raise exception 'Each allocation must target exactly one document';
    end if;

    if v_type = 'In' and (a.purchase_id is not null or a.expense_id is not null) then
      raise exception 'Payment In can only be allocated to Sales';
    end if;

    if v_type = 'Out' and a.sale_id is not null then
      raise exception 'Payment Out cannot be allocated to Sales';
    end if;

    if a.sale_id is not null then
      select total, contact_id
        into v_target_total, v_contact
      from public.sales
      where id = a.sale_id
        and organization_id = v_org
        and status = 'Confirmed'
      for update;

      if not found then raise exception 'Target Sale must be Confirmed and belong to the same organization'; end if;

      if v_payment_contact is null or v_contact <> v_payment_contact then
        raise exception 'Payment contact must match Sale contact';
      end if;

      select coalesce(sum(pa.allocated_amount), 0)
        into v_paid
      from public.payment_allocations pa
      join public.payments py on py.id = pa.payment_id
      where pa.sale_id = a.sale_id
        and pa.organization_id = v_org
        and py.status = 'Confirmed';

    elsif a.purchase_id is not null then
      select total, contact_id
        into v_target_total, v_contact
      from public.purchases
      where id = a.purchase_id
        and organization_id = v_org
        and status = 'Confirmed'
      for update;

      if not found then raise exception 'Target Purchase must be Confirmed and belong to the same organization'; end if;

      if v_payment_contact is null or v_contact <> v_payment_contact then
        raise exception 'Payment contact must match Purchase contact';
      end if;

      select coalesce(sum(pa.allocated_amount), 0)
        into v_paid
      from public.payment_allocations pa
      join public.payments py on py.id = pa.payment_id
      where pa.purchase_id = a.purchase_id
        and pa.organization_id = v_org
        and py.status = 'Confirmed';

    else
      select amount, contact_id
        into v_target_total, v_contact
      from public.expenses
      where id = a.expense_id
        and organization_id = v_org
        and status = 'Confirmed'
      for update;

      if not found then raise exception 'Target Expense must be Confirmed and belong to the same organization'; end if;

      if v_contact is not null
         and (v_payment_contact is null or v_contact <> v_payment_contact) then
        raise exception 'Payment contact must match Expense contact when the expense has a contact';
      end if;

      select coalesce(sum(pa.allocated_amount), 0)
        into v_paid
      from public.payment_allocations pa
      join public.payments py on py.id = pa.payment_id
      where pa.expense_id = a.expense_id
        and pa.organization_id = v_org
        and py.status = 'Confirmed';
    end if;

    v_outstanding := v_target_total - v_paid;

    if a.allocated_amount > v_outstanding then
      raise exception 'Allocation exceeds target outstanding balance';
    end if;

    insert into public.payment_allocations (
      organization_id, payment_id, purchase_id, sale_id, expense_id,
      allocated_amount, created_by
    )
    values (
      v_org, p_payment_id, a.purchase_id, a.sale_id, a.expense_id,
      a.allocated_amount, v_user
    );
  end loop;

  if v_type = 'In' then
    insert into public.account_transactions (
      organization_id, transaction_date, transaction_type,
      reference_type, reference_id, contact_id, description,
      debit, credit, created_by
    )
    values
      (v_org, now(), 'Payment In - ' || v_method::text,
       'Payment', p_payment_id, v_payment_contact,
       'Payment received - ' || v_payment_no,
       v_amount, 0, v_user),
      (v_org, now(), 'Payment In - Receivable Settlement',
       'Payment', p_payment_id, v_payment_contact,
       'Receivable settlement - ' || v_payment_no,
       0, v_amount, v_user);
  else
    insert into public.account_transactions (
      organization_id, transaction_date, transaction_type,
      reference_type, reference_id, contact_id, description,
      debit, credit, created_by
    )
    values
      (v_org, now(), 'Payment Out - Payable Settlement',
       'Payment', p_payment_id, v_payment_contact,
       'Payable settlement - ' || v_payment_no,
       v_amount, 0, v_user),
      (v_org, now(), 'Payment Out - ' || v_method::text,
       'Payment', p_payment_id, v_payment_contact,
       'Payment made - ' || v_payment_no,
       0, v_amount, v_user);
  end if;

  update public.payments
  set status = 'Confirmed'
  where id = p_payment_id
    and status = 'Draft';

  if not found then raise exception 'Payment confirmation failed'; end if;
  return p_payment_id;
end;
$function$

CREATE OR REPLACE FUNCTION public.cancel_payment(p_payment_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user uuid := (select auth.uid());
  v_org uuid;
  v_status public.payment_status;
  v_type public.payment_type;
  v_amount numeric(18,4);
  v_contact uuid;
  v_method public.payment_method;
  v_payment_no text;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select organization_id, status, payment_type, amount, contact_id, payment_method, payment_no
    into v_org, v_status, v_type, v_amount, v_contact, v_method, v_payment_no
  from public.payments
  where id = p_payment_id
  for update;

  if not found then raise exception 'Payment not found'; end if;
  perform public.rpc_assert_member(v_org);

  if v_status <> 'Confirmed' then raise exception 'Only Confirmed payments can be cancelled'; end if;

  if (
    select coalesce(sum(allocated_amount), 0)
    from public.payment_allocations
    where organization_id = v_org
      and payment_id = p_payment_id
  ) <> v_amount then
    raise exception 'Payment allocation ledger is incomplete';
  end if;

  if (
    select count(*)
    from public.account_transactions
    where organization_id = v_org
      and reference_type = 'Payment'
      and reference_id = p_payment_id
  ) <> 2 then
    raise exception 'Payment accounting ledger is incomplete';
  end if;

  if v_type = 'In' then
    insert into public.account_transactions (
      organization_id, transaction_date, transaction_type,
      reference_type, reference_id, contact_id, description,
      debit, credit, created_by
    )
    values
      (v_org, now(), 'Payment In Reversal',
       'Payment', p_payment_id, v_contact,
       'Reversal of payment received - ' || v_payment_no,
       0, v_amount, v_user),
      (v_org, now(), 'Payment In Receivable Reversal',
       'Payment', p_payment_id, v_contact,
       'Reversal of receivable settlement - ' || v_payment_no,
       v_amount, 0, v_user);
  else
    insert into public.account_transactions (
      organization_id, transaction_date, transaction_type,
      reference_type, reference_id, contact_id, description,
      debit, credit, created_by
    )
    values
      (v_org, now(), 'Payment Out Reversal',
       'Payment', p_payment_id, v_contact,
       'Reversal of payment made - ' || v_payment_no,
       v_amount, 0, v_user),
      (v_org, now(), 'Payment Out Payable Reversal',
       'Payment', p_payment_id, v_contact,
       'Reversal of payable settlement - ' || v_payment_no,
       0, v_amount, v_user);
  end if;

  update public.payments
  set status = 'Cancelled'
  where id = p_payment_id
    and status = 'Confirmed';

  if not found then raise exception 'Payment cancellation failed'; end if;
  return p_payment_id;
end;
$function$

revoke execute on function public.rpc_assert_member(uuid) from public, anon, authenticated;
revoke execute on function public.confirm_purchase(uuid) from public, anon;
revoke execute on function public.cancel_purchase(uuid) from public, anon;
revoke execute on function public.confirm_sale(uuid) from public, anon;
revoke execute on function public.cancel_sale(uuid) from public, anon;
revoke execute on function public.confirm_expense(uuid) from public, anon;
revoke execute on function public.cancel_expense(uuid) from public, anon;
revoke execute on function public.confirm_payment(uuid, jsonb) from public, anon;
revoke execute on function public.cancel_payment(uuid) from public, anon;

grant execute on function public.confirm_purchase(uuid) to authenticated;
grant execute on function public.cancel_purchase(uuid) to authenticated;
grant execute on function public.confirm_sale(uuid) to authenticated;
grant execute on function public.cancel_sale(uuid) to authenticated;
grant execute on function public.confirm_expense(uuid) to authenticated;
grant execute on function public.cancel_expense(uuid) to authenticated;
grant execute on function public.confirm_payment(uuid, jsonb) to authenticated;
grant execute on function public.cancel_payment(uuid) to authenticated;
