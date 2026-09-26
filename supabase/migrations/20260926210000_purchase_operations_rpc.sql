-- Pomelo Inventory - atomic purchase operations
-- Repository migration only. Do not apply to Supabase unless explicitly requested.
-- Purchase confirmation/cancellation is intentionally database-transactional.
-- No new tables are introduced.

create or replace function public.confirm_purchase(p_purchase_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $func$
declare
  v_user_id uuid := (select auth.uid());
  v_purchase public.purchases%rowtype;
  v_item record;
  v_item_count integer;
  v_items_total numeric(18,4);
  v_unit_cost numeric(18,4);
  v_now timestamptz := now();
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_purchase
  from public.purchases
  where id = p_purchase_id
  for update;

  if not found then
    raise exception 'Purchase not found';
  end if;

  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id = v_purchase.organization_id
      and ou.user_id = v_user_id
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  if v_purchase.status <> 'Draft' then
    raise exception 'Only Draft purchases can be confirmed';
  end if;

  select count(*), coalesce(sum(pi.line_total), 0)
    into v_item_count, v_items_total
  from public.purchase_items pi
  where pi.purchase_id = v_purchase.id
    and pi.organization_id = v_purchase.organization_id;

  if v_item_count = 0 then
    raise exception 'Purchase must contain at least one item';
  end if;

  if v_items_total <> v_purchase.total then
    raise exception 'Purchase total does not match purchase items';
  end if;

  if exists (
    select 1
    from public.purchase_items pi
    join public.products p
      on p.id = pi.product_id
     and p.organization_id = pi.organization_id
    where pi.purchase_id = v_purchase.id
      and pi.organization_id = v_purchase.organization_id
      and p.status <> 'Active'
  ) then
    raise exception 'Purchase contains an inactive product';
  end if;

  -- Stock changes are grouped by product and processed in deterministic
  -- product order. ON CONFLICT serializes the balance update.
  for v_item in
    select pi.product_id, sum(pi.quantity)::numeric(18,4) as quantity
    from public.purchase_items pi
    where pi.purchase_id = v_purchase.id
      and pi.organization_id = v_purchase.organization_id
    group by pi.product_id
    order by pi.product_id
  loop
    insert into public.stock (organization_id, product_id, quantity, created_at, updated_at)
    values (v_purchase.organization_id, v_item.product_id, v_item.quantity, v_now, v_now)
    on conflict (organization_id, product_id)
    do update set
      quantity = public.stock.quantity + excluded.quantity,
      updated_at = v_now;
  end loop;

  for v_item in
    select
      pi.product_id,
      pi.quantity,
      pi.unit_price,
      pi.discount
    from public.purchase_items pi
    where pi.purchase_id = v_purchase.id
      and pi.organization_id = v_purchase.organization_id
    order by pi.product_id, pi.id
  loop
    v_unit_cost := ((v_item.quantity * v_item.unit_price) - v_item.discount) / v_item.quantity;

    insert into public.inventory_movements (
      organization_id,
      product_id,
      movement_direction,
      movement_type,
      quantity,
      reference_type,
      reference_id,
      unit_cost,
      movement_date,
      created_by,
      created_at
    ) values (
      v_purchase.organization_id,
      v_item.product_id,
      'In',
      'Purchase',
      v_item.quantity,
      'purchase',
      v_purchase.id,
      v_unit_cost,
      v_now,
      v_user_id,
      v_now
    );
  end loop;

  -- Basic payable entry: debit inventory value and credit payable.
  -- The two rows form one balanced transaction for the purchase reference.
  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description,
    debit, credit, created_by, created_at
  ) values (
    v_purchase.organization_id, v_now, 'Purchase',
    'purchase', v_purchase.id, v_purchase.contact_id,
    'Purchase invoice ' || v_purchase.invoice_no,
    v_purchase.total, 0, v_user_id, v_now
  );

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description,
    debit, credit, created_by, created_at
  ) values (
    v_purchase.organization_id, v_now, 'Purchase Payable',
    'purchase', v_purchase.id, v_purchase.contact_id,
    'Payable for purchase invoice ' || v_purchase.invoice_no,
    0, v_purchase.total, v_user_id, v_now
  );

  update public.purchases
  set status = 'Confirmed', updated_at = v_now
  where id = v_purchase.id;

  return jsonb_build_object(
    'purchase_id', v_purchase.id,
    'status', 'Confirmed',
    'invoice_no', v_purchase.invoice_no,
    'total', v_purchase.total
  );
end;
$func$;

create or replace function public.cancel_purchase(p_purchase_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $func$
declare
  v_user_id uuid := (select auth.uid());
  v_purchase public.purchases%rowtype;
  v_item record;
  v_now timestamptz := now();
  v_current_stock numeric(18,4);
  v_unit_cost numeric(18,4);
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select * into v_purchase
  from public.purchases
  where id = p_purchase_id
  for update;

  if not found then
    raise exception 'Purchase not found';
  end if;

  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id = v_purchase.organization_id
      and ou.user_id = v_user_id
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  if v_purchase.status <> 'Confirmed' then
    raise exception 'Only Confirmed purchases can be cancelled';
  end if;

  -- A cancellation reverses the purchase IN movement. Refuse the
  -- cancellation if later activity has consumed the stock.
  for v_item in
    select pi.product_id, sum(pi.quantity)::numeric(18,4) as quantity
    from public.purchase_items pi
    where pi.purchase_id = v_purchase.id
      and pi.organization_id = v_purchase.organization_id
    group by pi.product_id
    order by pi.product_id
  loop
    select s.quantity into v_current_stock
    from public.stock s
    where s.organization_id = v_purchase.organization_id
      and s.product_id = v_item.product_id
    for update;

    if not found then
      raise exception 'Stock record missing for product %', v_item.product_id;
    end if;

    if v_current_stock < v_item.quantity then
      raise exception 'Cannot cancel purchase: insufficient current stock for product %', v_item.product_id;
    end if;

    update public.stock
    set quantity = quantity - v_item.quantity,
        updated_at = v_now
    where organization_id = v_purchase.organization_id
      and product_id = v_item.product_id;
  end loop;

  for v_item in
    select pi.product_id, pi.quantity, pi.unit_price, pi.discount
    from public.purchase_items pi
    where pi.purchase_id = v_purchase.id
      and pi.organization_id = v_purchase.organization_id
    order by pi.product_id, pi.id
  loop
    v_unit_cost := ((v_item.quantity * v_item.unit_price) - v_item.discount) / v_item.quantity;

    insert into public.inventory_movements (
      organization_id, product_id, movement_direction, movement_type,
      quantity, reference_type, reference_id, unit_cost,
      movement_date, created_by, created_at
    ) values (
      v_purchase.organization_id, v_item.product_id, 'Out', 'Return',
      v_item.quantity, 'purchase_cancel', v_purchase.id, v_unit_cost,
      v_now, v_user_id, v_now
    );
  end loop;

  -- Reverse the original accounting legs.
  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description,
    debit, credit, created_by, created_at
  ) values (
    v_purchase.organization_id, v_now, 'Purchase Cancellation',
    'purchase_cancel', v_purchase.id, v_purchase.contact_id,
    'Reversal of purchase invoice ' || v_purchase.invoice_no,
    0, v_purchase.total, v_user_id, v_now
  );

  insert into public.account_transactions (
    organization_id, transaction_date, transaction_type,
    reference_type, reference_id, contact_id, description,
    debit, credit, created_by, created_at
  ) values (
    v_purchase.organization_id, v_now, 'Purchase Payable Reversal',
    'purchase_cancel', v_purchase.id, v_purchase.contact_id,
    'Reversal of payable for purchase invoice ' || v_purchase.invoice_no,
    v_purchase.total, 0, v_user_id, v_now
  );

  update public.purchases
  set status = 'Cancelled', updated_at = v_now
  where id = v_purchase.id;

  return jsonb_build_object(
    'purchase_id', v_purchase.id,
    'status', 'Cancelled',
    'invoice_no', v_purchase.invoice_no,
    'total', v_purchase.total
  );
end;
$func$;

revoke all on function public.confirm_purchase(uuid) from public;
revoke all on function public.confirm_purchase(uuid) from anon;
revoke all on function public.cancel_purchase(uuid) from public;
revoke all on function public.cancel_purchase(uuid) from anon;
grant execute on function public.confirm_purchase(uuid) to authenticated;
grant execute on function public.cancel_purchase(uuid) to authenticated;

comment on function public.confirm_purchase(uuid) is
  'Atomically confirms a Draft purchase, updates stock, writes inventory and payable ledger entries, and changes status to Confirmed.';
comment on function public.cancel_purchase(uuid) is
  'Atomically cancels a Confirmed purchase, reverses stock and accounting effects, and changes status to Cancelled. Fails if current stock cannot absorb the reversal.';
