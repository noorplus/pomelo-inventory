-- Pomelo Inventory - Stock adjustments and item returns
-- Repository migration only. Do NOT apply to Supabase unless explicitly requested.
--
-- The frozen schema reserves inventory_movement_type values that no flow writes:
-- Opening, Adjustment and Return. This migration adds the controlled RPCs that
-- write them. No new tables, no columns, frozen migration untouched.
--
-- * record_stock_adjustment: Opening / Adjustment stock corrections (stock only,
--   no financial effect). Out adjustments can never drive stock negative.
-- * return_purchase_items / return_sale_items: quantity-based returns against a
--   Confirmed invoice. Rejected while confirmed payment allocations exist
--   (same dependency rule as cancellation). Each call reverses stock through
--   append-only Return movements plus a proportional reversing double-entry
--   pair. The invoice stays Confirmed; repeated returns accumulate until the
--   purchased/sold quantity is fully returned.
-- * Every function runs in ONE PostgreSQL transaction with row locking and is
--   safe against double submission (remaining-quantity guards).

create or replace function public.record_stock_adjustment(
  p_organization_id uuid,
  p_product_id uuid,
  p_quantity numeric,
  p_direction public.inventory_movement_direction,
  p_movement_type public.inventory_movement_type,
  p_unit_cost numeric default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $func$
declare
  v_user uuid := (select auth.uid());
  v_movement_id uuid;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;

  if p_movement_type not in ('Opening', 'Adjustment') then
    raise exception 'Only Opening and Adjustment movements can be recorded here';
  end if;

  if p_quantity is null or p_quantity <= 0 then
    raise exception 'Quantity must be greater than zero';
  end if;

  if p_unit_cost is not null and p_unit_cost < 0 then
    raise exception 'Unit cost cannot be negative';
  end if;

  perform public.rpc_assert_member(p_organization_id);

  if not exists (
    select 1 from public.products
    where id = p_product_id
      and organization_id = p_organization_id
  ) then
    raise exception 'Product not found in this organization';
  end if;

  if p_direction = 'In' then
    insert into public.stock (organization_id, product_id, quantity)
    values (p_organization_id, p_product_id, p_quantity)
    on conflict (organization_id, product_id)
    do update set quantity = public.stock.quantity + excluded.quantity,
                  updated_at = now();
  else
    update public.stock
    set quantity = quantity - p_quantity,
        updated_at = now()
    where organization_id = p_organization_id
      and product_id = p_product_id
      and quantity >= p_quantity;

    if not found then
      raise exception 'Insufficient stock for adjustment';
    end if;
  end if;

  insert into public.inventory_movements (
    organization_id, product_id, movement_direction, movement_type,
    quantity, reference_type, reference_id, unit_cost, movement_date, created_by
  )
  values (
    p_organization_id, p_product_id, p_direction, p_movement_type,
    p_quantity, null, null, p_unit_cost, now(), v_user
  )
  returning id into v_movement_id;

  return v_movement_id;
end;
$func$;

create or replace function public.return_purchase_items(
  p_purchase_id uuid,
  p_lines jsonb
)
returns numeric
language plpgsql
security definer
set search_path = ''
as $func$
declare
  v_user uuid := (select auth.uid());
  v_org uuid;
  v_status public.invoice_status;
  v_contact uuid;
  v_invoice_no text;
  v_line record;
  v_item record;
  v_purchased numeric(18,4);
  v_returned numeric(18,4);
  v_remaining numeric(18,4);
  v_take numeric(18,4);
  v_row_remaining numeric(18,4);
  v_return_amount numeric(18,4) := 0;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Return lines must be a non-empty JSON array';
  end if;

  select organization_id, status, contact_id, invoice_no
    into v_org, v_status, v_contact, v_invoice_no
  from public.purchases
  where id = p_purchase_id
  for update;

  if not found then
    raise exception 'Purchase not found';
  end if;
  perform public.rpc_assert_member(v_org);

  if v_status <> 'Confirmed' then
    raise exception 'Only Confirmed purchases can be returned';
  end if;

  if exists (
    select 1
    from public.payment_allocations pa
    join public.payments py on py.id = pa.payment_id
    where pa.organization_id = v_org
      and pa.purchase_id = p_purchase_id
      and py.status = 'Confirmed'
  ) then
    raise exception 'Purchase cannot be returned while confirmed payments are allocated to it';
  end if;

  for v_line in
    select x.product_id, sum(x.quantity) as quantity
    from jsonb_to_recordset(p_lines) as x(product_id uuid, quantity numeric)
    group by x.product_id
  loop
    if v_line.quantity is null or v_line.quantity <= 0 then
      raise exception 'Return quantity must be greater than zero';
    end if;

    if not exists (
      select 1 from public.products
      where id = v_line.product_id and organization_id = v_org
    ) then
      raise exception 'Product not found in this organization';
    end if;

    select coalesce(sum(quantity), 0)
      into v_purchased
    from public.purchase_items
    where purchase_id = p_purchase_id
      and organization_id = v_org
      and product_id = v_line.product_id;

    if v_purchased <= 0 then
      raise exception 'Product was not part of this purchase';
    end if;

    select coalesce(sum(quantity), 0)
      into v_returned
    from public.inventory_movements
    where organization_id = v_org
      and reference_type = 'Purchase'
      and reference_id = p_purchase_id
      and product_id = v_line.product_id
      and movement_direction = 'Out'
      and movement_type = 'Return';

    v_remaining := v_purchased - v_returned;
    if v_line.quantity > v_remaining then
      raise exception 'Return quantity exceeds remaining quantity for product %', v_line.product_id;
    end if;

    v_row_remaining := v_line.quantity;

    for v_item in
      select product_id, quantity, unit_price, discount, tax
      from public.purchase_items
      where purchase_id = p_purchase_id
        and organization_id = v_org
        and product_id = v_line.product_id
      order by created_at, id
    loop
      exit when v_row_remaining <= 0;

      v_take := least(v_row_remaining, v_item.quantity);
      v_return_amount := v_return_amount
        + v_take * v_item.unit_price
        - v_item.discount * (v_take / v_item.quantity)
        + v_item.tax * (v_take / v_item.quantity);
      v_row_remaining := v_row_remaining - v_take;

      update public.stock
      set quantity = quantity - v_take,
          updated_at = now()
      where organization_id = v_org
        and product_id = v_item.product_id
        and quantity >= v_take;

      if not found then
        raise exception 'Return would make stock negative for product %', v_item.product_id;
      end if;

      insert into public.inventory_movements (
        organization_id, product_id, movement_direction, movement_type,
        quantity, reference_type, reference_id, unit_cost, movement_date, created_by
      )
      values (
        v_org, v_item.product_id, 'Out', 'Return',
        v_take, 'Purchase', p_purchase_id, v_item.unit_price, now(), v_user
      );
    end loop;
  end loop;

  if v_return_amount > 0 then
    insert into public.account_transactions (
      organization_id, transaction_date, transaction_type,
      reference_type, reference_id, contact_id, description,
      debit, credit, created_by
    )
    values
      (v_org, now(), 'Purchase Return - Payable',
       'Purchase', p_purchase_id, v_contact,
       'Reversal of purchase payable (return) - ' || v_invoice_no,
       v_return_amount, 0, v_user),
      (v_org, now(), 'Purchase Return - Inventory',
       'Purchase', p_purchase_id, v_contact,
       'Reversal of purchase inventory (return) - ' || v_invoice_no,
       0, v_return_amount, v_user);
  end if;

  return v_return_amount;
end;
$func$;

create or replace function public.return_sale_items(
  p_sale_id uuid,
  p_lines jsonb
)
returns numeric
language plpgsql
security definer
set search_path = ''
as $func$
declare
  v_user uuid := (select auth.uid());
  v_org uuid;
  v_status public.invoice_status;
  v_contact uuid;
  v_invoice_no text;
  v_line record;
  v_item record;
  v_sold numeric(18,4);
  v_returned numeric(18,4);
  v_remaining numeric(18,4);
  v_take numeric(18,4);
  v_row_remaining numeric(18,4);
  v_return_amount numeric(18,4) := 0;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Return lines must be a non-empty JSON array';
  end if;

  select organization_id, status, contact_id, invoice_no
    into v_org, v_status, v_contact, v_invoice_no
  from public.sales
  where id = p_sale_id
  for update;

  if not found then
    raise exception 'Sale not found';
  end if;
  perform public.rpc_assert_member(v_org);

  if v_status <> 'Confirmed' then
    raise exception 'Only Confirmed sales can be returned';
  end if;

  if exists (
    select 1
    from public.payment_allocations pa
    join public.payments py on py.id = pa.payment_id
    where pa.organization_id = v_org
      and pa.sale_id = p_sale_id
      and py.status = 'Confirmed'
  ) then
    raise exception 'Sale cannot be returned while confirmed payments are allocated to it';
  end if;

  for v_line in
    select x.product_id, sum(x.quantity) as quantity
    from jsonb_to_recordset(p_lines) as x(product_id uuid, quantity numeric)
    group by x.product_id
  loop
    if v_line.quantity is null or v_line.quantity <= 0 then
      raise exception 'Return quantity must be greater than zero';
    end if;

    if not exists (
      select 1 from public.products
      where id = v_line.product_id and organization_id = v_org
    ) then
      raise exception 'Product not found in this organization';
    end if;

    select coalesce(sum(quantity), 0)
      into v_sold
    from public.sale_items
    where sale_id = p_sale_id
      and organization_id = v_org
      and product_id = v_line.product_id;

    if v_sold <= 0 then
      raise exception 'Product was not part of this sale';
    end if;

    select coalesce(sum(quantity), 0)
      into v_returned
    from public.inventory_movements
    where organization_id = v_org
      and reference_type = 'Sale'
      and reference_id = p_sale_id
      and product_id = v_line.product_id
      and movement_direction = 'In'
      and movement_type = 'Return';

    v_remaining := v_sold - v_returned;
    if v_line.quantity > v_remaining then
      raise exception 'Return quantity exceeds remaining quantity for product %', v_line.product_id;
    end if;

    v_row_remaining := v_line.quantity;

    for v_item in
      select product_id, quantity, unit_price, discount, tax
      from public.sale_items
      where sale_id = p_sale_id
        and organization_id = v_org
        and product_id = v_line.product_id
      order by created_at, id
    loop
      exit when v_row_remaining <= 0;

      v_take := least(v_row_remaining, v_item.quantity);
      v_return_amount := v_return_amount
        + v_take * v_item.unit_price
        - v_item.discount * (v_take / v_item.quantity)
        + v_item.tax * (v_take / v_item.quantity);
      v_row_remaining := v_row_remaining - v_take;

      insert into public.stock (organization_id, product_id, quantity)
      values (v_org, v_item.product_id, v_take)
      on conflict (organization_id, product_id)
      do update set quantity = public.stock.quantity + excluded.quantity,
                    updated_at = now();

      insert into public.inventory_movements (
        organization_id, product_id, movement_direction, movement_type,
        quantity, reference_type, reference_id, unit_cost, movement_date, created_by
      )
      values (
        v_org, v_item.product_id, 'In', 'Return',
        v_take, 'Sale', p_sale_id, null, now(), v_user
      );
    end loop;
  end loop;

  if v_return_amount > 0 then
    insert into public.account_transactions (
      organization_id, transaction_date, transaction_type,
      reference_type, reference_id, contact_id, description,
      debit, credit, created_by
    )
    values
      (v_org, now(), 'Sale Return - Revenue',
       'Sale', p_sale_id, v_contact,
       'Reversal of sale revenue (return) - ' || v_invoice_no,
       v_return_amount, 0, v_user),
      (v_org, now(), 'Sale Return - Receivable',
       'Sale', p_sale_id, v_contact,
       'Reversal of sale receivable (return) - ' || v_invoice_no,
       0, v_return_amount, v_user);
  end if;

  return v_return_amount;
end;
$func$;

revoke all on function public.record_stock_adjustment(uuid, uuid, numeric, public.inventory_movement_direction, public.inventory_movement_type, numeric, text) from public;
revoke all on function public.return_purchase_items(uuid, jsonb) from public;
revoke all on function public.return_sale_items(uuid, jsonb) from public;
grant execute on function public.record_stock_adjustment(uuid, uuid, numeric, public.inventory_movement_direction, public.inventory_movement_type, numeric, text) to authenticated;
grant execute on function public.return_purchase_items(uuid, jsonb) to authenticated;
grant execute on function public.return_sale_items(uuid, jsonb) to authenticated;

comment on function public.record_stock_adjustment(uuid, uuid, numeric, public.inventory_movement_direction, public.inventory_movement_type, numeric, text) is 'Atomically records an Opening or Adjustment stock movement and updates the balance. Out adjustments never drive stock negative.';
comment on function public.return_purchase_items(uuid, jsonb) is 'Atomically returns quantities against a Confirmed purchase: Return stock movements plus proportional payable/inventory reversal. Blocked by confirmed payment allocations.';
comment on function public.return_sale_items(uuid, jsonb) is 'Atomically returns quantities against a Confirmed sale: Return stock movements plus proportional revenue/receivable reversal. Blocked by confirmed payment allocations.';
