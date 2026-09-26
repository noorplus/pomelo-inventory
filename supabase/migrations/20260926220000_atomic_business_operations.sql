-- Pomelo Inventory - Atomic business operations (final)
-- Migration history cleanup: consolidated duplicate RPC drafts into this single post-schema migration.
-- This migration adds RPC/service-layer functions only; no tables are introduced.
-- Repository migration only. Do not apply to Supabase unless explicitly requested.
--
-- This migration adds transactional RPCs for:
--   * Confirm / cancel purchase and sales invoices
--   * Confirm / cancel payments
--   * Confirm / cancel expenses
--   * Atomic stock movement and negative-stock protection
--   * Payment allocation integrity
--   * Financial/inventory reversal through append-only ledgers
--
-- No tables are added. Existing frozen schema remains unchanged.

create or replace function public.confirm_purchase(p_purchase_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $func$
declare
  v_user_id uuid := auth.uid();
  v_purchase public.purchases%rowtype;
  v_item record;
  v_stock public.stock%rowtype;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select * into v_purchase
  from public.purchases
  where id = p_purchase_id
  for update;

  if not found then raise exception 'Purchase not found'; end if;

  if not exists (
    select 1 from public.organization_users
    where organization_id = v_purchase.organization_id and user_id = v_user_id
  ) then raise exception 'User is not a member of this organization'; end if;

  if v_purchase.status <> 'Draft' then
    raise exception 'Only Draft purchase invoices can be confirmed';
  end if;

  if not exists (select 1 from public.purchase_items where purchase_id = v_purchase.id) then
    raise exception 'Purchase invoice must contain at least one item';
  end if;

  for v_item in
    select product_id, quantity, unit_price
    from public.purchase_items
    where purchase_id = v_purchase.id
    order by id
  loop
    insert into public.stock (organization_id, product_id, quantity)
    values (v_purchase.organization_id, v_item.product_id, v_item.quantity)
    on conflict (organization_id, product_id)
    do update set quantity = public.stock.quantity + excluded.quantity,
                  updated_at = now();

    insert into public.inventory_movements (
      organization_id, product_id, movement_direction, movement_type,
      quantity, reference_type, reference_id, unit_cost, movement_date, created_by
    )
    values (
      v_purchase.organization_id, v_item.product_id, 'In', 'Purchase',
      v_item.quantity, 'Purchase', v_purchase.id, v_item.unit_price,
      now(), v_user_id
    );
  end loop;

  update public.purchases
  set status = 'Confirmed', updated_at = now()
  where id = v_purchase.id;
end;
$func$;

create or replace function public.confirm_sale(p_sale_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $func$
declare
  v_user_id uuid := auth.uid();
  v_sale public.sales%rowtype;
  v_item record;
  v_available numeric(18,4);
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select * into v_sale
  from public.sales
  where id = p_sale_id
  for update;

  if not found then raise exception 'Sale not found'; end if;

  if not exists (
    select 1 from public.organization_users
    where organization_id = v_sale.organization_id and user_id = v_user_id
  ) then raise exception 'User is not a member of this organization'; end if;

  if v_sale.status <> 'Draft' then
    raise exception 'Only Draft sales invoices can be confirmed';
  end if;

  if not exists (select 1 from public.sale_items where sale_id = v_sale.id) then
    raise exception 'Sales invoice must contain at least one item';
  end if;

  for v_item in
    select product_id, quantity, unit_price
    from public.sale_items
    where sale_id = v_sale.id
    order by id
  loop
    select quantity into v_available
    from public.stock
    where organization_id = v_sale.organization_id
      and product_id = v_item.product_id
    for update;

    if not found then
      raise exception 'Insufficient stock for product %', v_item.product_id;
    end if;

    if v_available < v_item.quantity then
      raise exception 'Insufficient stock for product %. Available: %, requested: %',
        v_item.product_id, v_available, v_item.quantity;
    end if;

    update public.stock
    set quantity = quantity - v_item.quantity, updated_at = now()
    where organization_id = v_sale.organization_id
      and product_id = v_item.product_id;

    insert into public.inventory_movements (
      organization_id, product_id, movement_direction, movement_type,
      quantity, reference_type, reference_id, unit_cost, movement_date, created_by
    )
    values (
      v_sale.organization_id, v_item.product_id, 'Out', 'Sale',
      v_item.quantity, 'Sale', v_sale.id, v_item.unit_price,
      now(), v_user_id
    );
  end loop;

  update public.sales
  set status = 'Confirmed', updated_at = now()
  where id = v_sale.id;
end;
$func$;

create or replace function public.confirm_expense(p_expense_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $func$
declare
  v_user_id uuid := auth.uid();
  v_expense public.expenses%rowtype;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select * into v_expense from public.expenses where id = p_expense_id for update;
  if not found then raise exception 'Expense not found'; end if;

  if not exists (
    select 1 from public.organization_users
    where organization_id = v_expense.organization_id and user_id = v_user_id
  ) then raise exception 'User is not a member of this organization'; end if;

  if v_expense.status <> 'Draft' then
    raise exception 'Only Draft expenses can be confirmed';
  end if;

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description, debit, credit, created_by
  )
  values (
    v_expense.organization_id, now(), 'Expense',
    'Expense', v_expense.id, v_expense.contact_id, v_expense.description,
    v_expense.amount, 0, v_user_id
  );

  update public.expenses
  set status = 'Confirmed', updated_at = now()
  where id = v_expense.id;
end;
$func$;

create or replace function public.confirm_payment(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $func$
declare
  v_user_id uuid := auth.uid();
  v_payment public.payments%rowtype;
  v_alloc record;
  v_target_total numeric(18,4);
  v_invoice_total numeric(18,4);
  v_invoice_paid numeric(18,4);
  v_balance numeric(18,4);
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select * into v_payment from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;

  if not exists (
    select 1 from public.organization_users
    where organization_id = v_payment.organization_id and user_id = v_user_id
  ) then raise exception 'User is not a member of this organization'; end if;

  if v_payment.status <> 'Draft' then
    raise exception 'Only Draft payments can be confirmed';
  end if;

  if not exists (select 1 from public.payment_allocations where payment_id = v_payment.id) then
    raise exception 'Payment must have at least one allocation';
  end if;

  select coalesce(sum(allocated_amount), 0)
  into v_target_total
  from public.payment_allocations
  where payment_id = v_payment.id;

  if v_target_total <> v_payment.amount then
    raise exception 'Payment allocations (%) must equal payment amount (%)',
      v_target_total, v_payment.amount;
  end if;

  -- Lock and validate every distinct target before calculating outstanding balances.
  for v_alloc in
    select sale_id, purchase_id, expense_id, sum(allocated_amount) as allocated_amount
    from public.payment_allocations
    where payment_id = v_payment.id
    group by sale_id, purchase_id, expense_id
    order by sale_id nulls last, purchase_id nulls last, expense_id nulls last
  loop
    if v_payment.payment_type = 'In' and (v_alloc.purchase_id is not null or v_alloc.expense_id is not null) then
      raise exception 'Payment In can only be allocated to sales';
    end if;

    if v_payment.payment_type = 'Out' and v_alloc.sale_id is not null then
      raise exception 'Payment Out cannot be allocated to sales';
    end if;

    if v_alloc.sale_id is not null then
      select total into v_invoice_total
      from public.sales
      where id = v_alloc.sale_id and organization_id = v_payment.organization_id
      for update;
      if not found then raise exception 'Sales invoice not found'; end if;

      if not exists (
        select 1 from public.sales
        where id = v_alloc.sale_id and organization_id = v_payment.organization_id and status = 'Confirmed'
      ) then raise exception 'Sales invoice must be Confirmed before payment allocation'; end if;

      select coalesce(sum(pa.allocated_amount),0)
      into v_invoice_paid
      from public.payment_allocations pa
      join public.payments p on p.id = pa.payment_id
      where pa.sale_id = v_alloc.sale_id and p.status = 'Confirmed';

      v_balance := v_invoice_total - v_invoice_paid;
      if v_alloc.allocated_amount > v_balance then
        raise exception 'Sale allocation exceeds outstanding balance. Balance: %, requested: %',
          v_balance, v_alloc.allocated_amount;
      end if;
    elsif v_alloc.purchase_id is not null then
      select total into v_invoice_total
      from public.purchases
      where id = v_alloc.purchase_id and organization_id = v_payment.organization_id
      for update;
      if not found then raise exception 'Purchase invoice not found'; end if;

      if not exists (
        select 1 from public.purchases
        where id = v_alloc.purchase_id and organization_id = v_payment.organization_id and status = 'Confirmed'
      ) then raise exception 'Purchase invoice must be Confirmed before payment allocation'; end if;

      select coalesce(sum(pa.allocated_amount),0)
      into v_invoice_paid
      from public.payment_allocations pa
      join public.payments p on p.id = pa.payment_id
      where pa.purchase_id = v_alloc.purchase_id and p.status = 'Confirmed';

      v_balance := v_invoice_total - v_invoice_paid;
      if v_alloc.allocated_amount > v_balance then
        raise exception 'Purchase allocation exceeds outstanding balance. Balance: %, requested: %',
          v_balance, v_alloc.allocated_amount;
      end if;
    elsif v_alloc.expense_id is not null then
      select amount into v_invoice_total
      from public.expenses
      where id = v_alloc.expense_id and organization_id = v_payment.organization_id
      for update;
      if not found then raise exception 'Expense not found'; end if;

      if not exists (
        select 1 from public.expenses
        where id = v_alloc.expense_id and organization_id = v_payment.organization_id and status = 'Confirmed'
      ) then raise exception 'Expense must be Confirmed before payment allocation'; end if;

      select coalesce(sum(pa.allocated_amount),0)
      into v_invoice_paid
      from public.payment_allocations pa
      join public.payments p on p.id = pa.payment_id
      where pa.expense_id = v_alloc.expense_id and p.status = 'Confirmed';

      v_balance := v_invoice_total - v_invoice_paid;
      if v_alloc.allocated_amount > v_balance then
        raise exception 'Expense allocation exceeds outstanding balance. Balance: %, requested: %',
          v_balance, v_alloc.allocated_amount;
      end if;
    end if;
  end loop;

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description, debit, credit, created_by
  )
  values (
    v_payment.organization_id, now(), 'Payment',
    'Payment', v_payment.id, v_payment.contact_id,
    case when v_payment.payment_type = 'In' then 'Payment received' else 'Payment made' end,
    case when v_payment.payment_type = 'Out' then v_payment.amount else 0 end,
    case when v_payment.payment_type = 'In' then v_payment.amount else 0 end,
    v_user_id
  );

  update public.payments
  set status = 'Confirmed', updated_at = now()
  where id = v_payment.id;
end;
$func$;

create or replace function public.set_payment_allocations(
  p_payment_id uuid,
  p_allocations jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $func$
declare
  v_user_id uuid := auth.uid();
  v_payment public.payments%rowtype;
  v_row jsonb;
  v_sale_id uuid;
  v_purchase_id uuid;
  v_expense_id uuid;
  v_amount numeric(18,4);
  v_sum numeric(18,4) := 0;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select * into v_payment
  from public.payments
  where id = p_payment_id
  for update;

  if not found then raise exception 'Payment not found'; end if;

  if not exists (
    select 1 from public.organization_users
    where organization_id = v_payment.organization_id and user_id = v_user_id
  ) then raise exception 'User is not a member of this organization'; end if;

  if v_payment.status <> 'Draft' then
    raise exception 'Allocations can only be changed while Payment is Draft';
  end if;

  if jsonb_typeof(p_allocations) <> 'array' then
    raise exception 'Allocations must be a JSON array';
  end if;

  delete from public.payment_allocations where payment_id = v_payment.id;

  for v_row in select value from jsonb_array_elements(p_allocations) loop
    v_sale_id := nullif(v_row->>'sale_id','')::uuid;
    v_purchase_id := nullif(v_row->>'purchase_id','')::uuid;
    v_expense_id := nullif(v_row->>'expense_id','')::uuid;
    v_amount := (v_row->>'allocated_amount')::numeric(18,4);

    if v_amount is null or v_amount <= 0 then
      raise exception 'Allocation amount must be greater than zero';
    end if;

    if num_nonnulls(v_sale_id, v_purchase_id, v_expense_id) <> 1 then
      raise exception 'Each allocation must target exactly one sale, purchase, or expense';
    end if;

    if v_payment.payment_type = 'In' and (v_purchase_id is not null or v_expense_id is not null) then
      raise exception 'Payment In can only be allocated to sales';
    end if;

    if v_payment.payment_type = 'Out' and v_sale_id is not null then
      raise exception 'Payment Out cannot be allocated to sales';
    end if;

    if v_sale_id is not null and not exists (
      select 1 from public.sales where id = v_sale_id and organization_id = v_payment.organization_id and status = 'Confirmed'
    ) then raise exception 'Target sale must exist, belong to the organization, and be Confirmed'; end if;

    if v_purchase_id is not null and not exists (
      select 1 from public.purchases where id = v_purchase_id and organization_id = v_payment.organization_id and status = 'Confirmed'
    ) then raise exception 'Target purchase must exist, belong to the organization, and be Confirmed'; end if;

    if v_expense_id is not null and not exists (
      select 1 from public.expenses where id = v_expense_id and organization_id = v_payment.organization_id and status = 'Confirmed'
    ) then raise exception 'Target expense must exist, belong to the organization, and be Confirmed'; end if;

    v_sum := v_sum + v_amount;

    if v_sum > v_payment.amount then
      raise exception 'Total allocations cannot exceed payment amount';
    end if;

    insert into public.payment_allocations (
      organization_id, payment_id, purchase_id, sale_id, expense_id,
      allocated_amount, created_by
    )
    values (
      v_payment.organization_id, v_payment.id, v_purchase_id, v_sale_id, v_expense_id,
      v_amount, v_user_id
    );
  end loop;
end;
$func$;

create or replace function public.cancel_purchase(p_purchase_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $func$
declare
  v_user_id uuid := auth.uid();
  v_purchase public.purchases%rowtype;
  v_item record;
  v_allocated numeric(18,4);
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  select * into v_purchase from public.purchases where id = p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if not exists (select 1 from public.organization_users where organization_id = v_purchase.organization_id and user_id = v_user_id) then
    raise exception 'User is not a member of this organization';
  end if;
  if v_purchase.status <> 'Confirmed' then raise exception 'Only Confirmed purchases can be cancelled'; end if;

  select coalesce(sum(pa.allocated_amount),0) into v_allocated
  from public.payment_allocations pa
  join public.payments p on p.id = pa.payment_id
  where pa.purchase_id = v_purchase.id and p.status = 'Confirmed';

  if v_allocated > 0 then
    raise exception 'Purchase has confirmed payments and cannot be cancelled';
  end if;

  for v_item in select product_id, quantity from public.purchase_items where purchase_id = v_purchase.id order by id loop
    update public.stock
    set quantity = quantity - v_item.quantity, updated_at = now()
    where organization_id = v_purchase.organization_id and product_id = v_item.product_id and quantity >= v_item.quantity;

    if not found then raise exception 'Cannot reverse purchase stock; insufficient current stock'; end if;

    insert into public.inventory_movements (
      organization_id, product_id, movement_direction, movement_type,
      quantity, reference_type, reference_id, unit_cost, movement_date, created_by
    )
    values (
      v_purchase.organization_id, v_item.product_id, 'Out', 'Return',
      v_item.quantity, 'purchase_cancel', v_purchase.id, v_item.unit_price, now(), v_user_id
    );
  end loop;

  update public.purchases set status = 'Cancelled', updated_at = now() where id = v_purchase.id;
end;
$func$;

create or replace function public.cancel_sale(p_sale_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $func$
declare
  v_user_id uuid := auth.uid();
  v_sale public.sales%rowtype;
  v_item record;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  select * into v_sale from public.sales where id = p_sale_id for update;
  if not found then raise exception 'Sale not found'; end if;
  if not exists (select 1 from public.organization_users where organization_id = v_sale.organization_id and user_id = v_user_id) then
    raise exception 'User is not a member of this organization';
  end if;
  if v_sale.status <> 'Confirmed' then raise exception 'Only Confirmed sales can be cancelled'; end if;

  if exists (
    select 1
    from public.payment_allocations pa
    join public.payments p on p.id = pa.payment_id
    where pa.sale_id = v_sale.id and p.status = 'Confirmed'
  ) then
    raise exception 'Sale has confirmed payments and cannot be cancelled';
  end if;

  for v_item in select product_id, quantity, unit_price from public.sale_items where sale_id = v_sale.id order by id loop
    insert into public.stock (organization_id, product_id, quantity)
    values (v_sale.organization_id, v_item.product_id, v_item.quantity)
    on conflict (organization_id, product_id)
    do update set quantity = public.stock.quantity + excluded.quantity, updated_at = now();

    insert into public.inventory_movements (
      organization_id, product_id, movement_direction, movement_type,
      quantity, reference_type, reference_id, unit_cost, movement_date, created_by
    )
    values (
      v_sale.organization_id, v_item.product_id, 'In', 'Return',
      v_item.quantity, 'sale_cancel', v_sale.id, v_item.unit_price, now(), v_user_id
    );
  end loop;

  update public.sales set status = 'Cancelled', updated_at = now() where id = v_sale.id;
end;
$func$;

create or replace function public.cancel_expense(p_expense_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $func$
declare
  v_user_id uuid := auth.uid();
  v_expense public.expenses%rowtype;
  v_payment_total numeric(18,4);
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  select * into v_expense from public.expenses where id = p_expense_id for update;
  if not found then raise exception 'Expense not found'; end if;
  if not exists (select 1 from public.organization_users where organization_id = v_expense.organization_id and user_id = v_user_id) then
    raise exception 'User is not a member of this organization';
  end if;
  if v_expense.status <> 'Confirmed' then raise exception 'Only Confirmed expenses can be cancelled'; end if;

  select coalesce(sum(pa.allocated_amount),0) into v_payment_total
  from public.payment_allocations pa
  join public.payments p on p.id = pa.payment_id
  where pa.expense_id = v_expense.id and p.status = 'Confirmed';

  if v_payment_total > 0 then raise exception 'Expense has confirmed payments and cannot be cancelled'; end if;

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description, debit, credit, created_by
  )
  values (
    v_expense.organization_id, now(), 'Expense Reversal',
    'expense_cancel', v_expense.id, v_expense.contact_id,
    'Expense cancellation reversal', 0, v_expense.amount, v_user_id
  );

  update public.expenses set status = 'Cancelled', updated_at = now() where id = v_expense.id;
end;
$func$;

create or replace function public.cancel_payment(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $func$
declare
  v_user_id uuid := auth.uid();
  v_payment public.payments%rowtype;
  v_alloc record;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  select * into v_payment from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  if not exists (select 1 from public.organization_users where organization_id = v_payment.organization_id and user_id = v_user_id) then
    raise exception 'User is not a member of this organization';
  end if;
  if v_payment.status <> 'Confirmed' then raise exception 'Only Confirmed payments can be cancelled'; end if;

  for v_alloc in
    select * from public.payment_allocations
    where payment_id = v_payment.id
    order by id
    for update
  loop
    -- Keep allocation history; the cancelled payment is excluded from outstanding calculations.
    null;
  end loop;

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description, debit, credit, created_by
  )
  values (
    v_payment.organization_id, now(), 'Payment Reversal',
    'payment_cancel', v_payment.id, v_payment.contact_id,
    'Payment cancellation reversal',
    case when v_payment.payment_type = 'In' then v_payment.amount else 0 end,
    case when v_payment.payment_type = 'Out' then v_payment.amount else 0 end,
    v_user_id
  );

  update public.payments set status = 'Cancelled', updated_at = now() where id = v_payment.id;
end;
$func$;

-- Controlled RPCs are the only client-facing write path for state transitions.
revoke all on function public.set_payment_allocations(uuid, jsonb) from public;
grant execute on function public.set_payment_allocations(uuid, jsonb) to authenticated;

revoke all on function public.confirm_purchase(uuid) from public;
revoke all on function public.confirm_sale(uuid) from public;
revoke all on function public.confirm_expense(uuid) from public;
revoke all on function public.confirm_payment(uuid) from public;
revoke all on function public.cancel_purchase(uuid) from public;
revoke all on function public.cancel_sale(uuid) from public;
revoke all on function public.cancel_expense(uuid) from public;
revoke all on function public.cancel_payment(uuid) from public;

grant execute on function public.confirm_purchase(uuid) to authenticated;
grant execute on function public.confirm_sale(uuid) to authenticated;
grant execute on function public.confirm_expense(uuid) to authenticated;
grant execute on function public.confirm_payment(uuid) to authenticated;
grant execute on function public.cancel_purchase(uuid) to authenticated;
grant execute on function public.cancel_sale(uuid) to authenticated;
grant execute on function public.cancel_expense(uuid) to authenticated;
grant execute on function public.cancel_payment(uuid) to authenticated;

comment on function public.set_payment_allocations(uuid, jsonb) is 'Replaces Draft payment allocations atomically, enforcing organization, target status, payment direction, and total-allocation limits.';
comment on function public.confirm_purchase(uuid) is 'Atomically confirms a Draft purchase, increases stock, writes Purchase inventory movements, and changes status to Confirmed.';
comment on function public.confirm_sale(uuid) is 'Atomically confirms a Draft sale after locking/checking stock, decreases stock, writes Sale inventory movements, and changes status to Confirmed.';
comment on function public.confirm_payment(uuid) is 'Atomically confirms a Draft payment after validating type, target, allocation total, and outstanding balance, then writes the payment ledger transaction.';
comment on function public.cancel_purchase(uuid) is 'Atomically cancels a Confirmed purchase by reversing stock through an append-only Return movement; confirmed payments block cancellation.';
comment on function public.cancel_sale(uuid) is 'Atomically cancels a Confirmed sale by restoring stock through an append-only Return movement.';
comment on function public.confirm_expense(uuid) is 'Atomically confirms a Draft expense and writes its accounting transaction.';
comment on function public.cancel_expense(uuid) is 'Atomically cancels a Confirmed expense through an append-only reversing accounting transaction; confirmed payments block cancellation.';
comment on function public.cancel_payment(uuid) is 'Atomically cancels a Confirmed payment and writes an append-only reversing accounting transaction while preserving allocation history.';
