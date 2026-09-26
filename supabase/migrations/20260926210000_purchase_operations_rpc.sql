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

create or replace function public.create_purchase_draft(
  p_organization_id uuid,
  p_contact_id uuid,
  p_invoice_date date,
  p_notes text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $func$
declare
  v_user_id uuid := (select auth.uid());
  v_purchase_id uuid;
  v_invoice_no text;
  v_subtotal numeric(18,4) := 0;
  v_discount numeric(18,4) := 0;
  v_tax numeric(18,4) := 0;
  v_total numeric(18,4) := 0;
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric(18,4);
  v_unit_price numeric(18,4);
  v_item_discount numeric(18,4);
  v_item_tax numeric(18,4);
  v_line_total numeric(18,4);
  v_product_org uuid;
  v_product_status public.product_status;
  v_contact_org uuid;
  v_contact_status public.contact_status;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;
  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id = p_organization_id and ou.user_id = v_user_id
  ) then raise exception 'User is not a member of this organization'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Purchase must contain at least one item';
  end if;

  select c.organization_id, c.status into v_contact_org, v_contact_status
  from public.contacts c where c.id = p_contact_id;
  if not found or v_contact_org <> p_organization_id then raise exception 'Contact does not belong to this organization'; end if;
  if v_contact_status <> 'Active' then raise exception 'Purchase contact must be Active'; end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    begin
      v_product_id := (v_item->>'product_id')::uuid;
      v_quantity := (v_item->>'quantity')::numeric;
      v_unit_price := (v_item->>'unit_price')::numeric;
      v_item_discount := coalesce((v_item->>'discount')::numeric, 0);
      v_item_tax := coalesce((v_item->>'tax')::numeric, 0);
    exception when others then
      raise exception 'Invalid purchase item data';
    end;
    if v_quantity <= 0 or v_unit_price < 0 or v_item_discount < 0 or v_item_tax < 0 then raise exception 'Purchase item values are invalid'; end if;
    if v_item_discount > v_quantity * v_unit_price then raise exception 'Purchase item discount cannot exceed line base'; end if;

    select p.organization_id, p.status into v_product_org, v_product_status
    from public.products p where p.id = v_product_id;
    if not found or v_product_org <> p_organization_id then raise exception 'Product does not belong to this organization'; end if;
    if v_product_status <> 'Active' then raise exception 'Purchase contains an inactive product'; end if;

    v_line_total := v_quantity * v_unit_price - v_item_discount + v_item_tax;
    v_subtotal := v_subtotal + v_quantity * v_unit_price;
    v_discount := v_discount + v_item_discount;
    v_tax := v_tax + v_item_tax;
    v_total := v_total + v_line_total;
  end loop;

  insert into public.purchases (
    organization_id, contact_id, invoice_date, status,
    subtotal, discount, tax, total, notes, created_by
  ) values (
    p_organization_id, p_contact_id, coalesce(p_invoice_date, current_date), 'Draft',
    v_subtotal, v_discount, v_tax, v_total, nullif(btrim(coalesce(p_notes, '')), ''), v_user_id
  ) returning id, invoice_no into v_purchase_id, v_invoice_no;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::numeric;
    v_unit_price := (v_item->>'unit_price')::numeric;
    v_item_discount := coalesce((v_item->>'discount')::numeric, 0);
    v_item_tax := coalesce((v_item->>'tax')::numeric, 0);
    v_line_total := v_quantity * v_unit_price - v_item_discount + v_item_tax;
    insert into public.purchase_items (
      organization_id, purchase_id, product_id, quantity, unit_price,
      discount, tax, line_total, created_by
    ) values (
      p_organization_id, v_purchase_id, v_product_id, v_quantity, v_unit_price,
      v_item_discount, v_item_tax, v_line_total, v_user_id
    );
  end loop;

  return jsonb_build_object(
    'purchase_id', v_purchase_id, 'invoice_no', v_invoice_no, 'status', 'Draft',
    'subtotal', v_subtotal, 'discount', v_discount, 'tax', v_tax, 'total', v_total
  );
end;
$func$;

create or replace function public.update_purchase_draft(
  p_purchase_id uuid,
  p_contact_id uuid,
  p_invoice_date date,
  p_notes text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $func$
declare
  v_user_id uuid := (select auth.uid());
  v_purchase public.purchases%rowtype;
  v_item jsonb;
  v_product_id uuid;
  v_quantity numeric(18,4);
  v_unit_price numeric(18,4);
  v_item_discount numeric(18,4);
  v_item_tax numeric(18,4);
  v_line_total numeric(18,4);
  v_subtotal numeric(18,4) := 0;
  v_discount numeric(18,4) := 0;
  v_tax numeric(18,4) := 0;
  v_total numeric(18,4) := 0;
  v_product_org uuid;
  v_product_status public.product_status;
  v_contact_org uuid;
  v_contact_status public.contact_status;
  v_now timestamptz := now();
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select * into v_purchase from public.purchases where id = p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if not exists (
    select 1 from public.organization_users ou
    where ou.organization_id = v_purchase.organization_id and ou.user_id = v_user_id
  ) then raise exception 'User is not a member of this organization'; end if;
  if v_purchase.status <> 'Draft' then raise exception 'Only Draft purchases can be edited'; end if;

  select c.organization_id, c.status into v_contact_org, v_contact_status
  from public.contacts c where c.id = p_contact_id;
  if not found or v_contact_org <> v_purchase.organization_id then raise exception 'Contact does not belong to this organization'; end if;
  if v_contact_status <> 'Active' then raise exception 'Purchase contact must be Active'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Purchase must contain at least one item'; end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    begin
      v_product_id := (v_item->>'product_id')::uuid;
      v_quantity := (v_item->>'quantity')::numeric;
      v_unit_price := (v_item->>'unit_price')::numeric;
      v_item_discount := coalesce((v_item->>'discount')::numeric, 0);
      v_item_tax := coalesce((v_item->>'tax')::numeric, 0);
    exception when others then
      raise exception 'Invalid purchase item data';
    end;
    if v_quantity <= 0 or v_unit_price < 0 or v_item_discount < 0 or v_item_tax < 0 then raise exception 'Purchase item values are invalid'; end if;
    if v_item_discount > v_quantity * v_unit_price then raise exception 'Purchase item discount cannot exceed line base'; end if;
    select p.organization_id, p.status into v_product_org, v_product_status from public.products p where p.id = v_product_id;
    if not found or v_product_org <> v_purchase.organization_id then raise exception 'Product does not belong to this organization'; end if;
    if v_product_status <> 'Active' then raise exception 'Purchase contains an inactive product'; end if;
    v_line_total := v_quantity * v_unit_price - v_item_discount + v_item_tax;
    v_subtotal := v_subtotal + v_quantity * v_unit_price;
    v_discount := v_discount + v_item_discount;
    v_tax := v_tax + v_item_tax;
    v_total := v_total + v_line_total;
  end loop;

  delete from public.purchase_items where purchase_id = v_purchase.id and organization_id = v_purchase.organization_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_product_id := (v_item->>'product_id')::uuid;
    v_quantity := (v_item->>'quantity')::numeric;
    v_unit_price := (v_item->>'unit_price')::numeric;
    v_item_discount := coalesce((v_item->>'discount')::numeric, 0);
    v_item_tax := coalesce((v_item->>'tax')::numeric, 0);
    v_line_total := v_quantity * v_unit_price - v_item_discount + v_item_tax;
    insert into public.purchase_items (
      organization_id, purchase_id, product_id, quantity, unit_price,
      discount, tax, line_total, created_by
    ) values (
      v_purchase.organization_id, v_purchase.id, v_product_id, v_quantity, v_unit_price,
      v_item_discount, v_item_tax, v_line_total, v_user_id
    );
  end loop;

  update public.purchases
  set contact_id = p_contact_id,
      invoice_date = coalesce(p_invoice_date, current_date),
      subtotal = v_subtotal,
      discount = v_discount,
      tax = v_tax,
      total = v_total,
      notes = nullif(btrim(coalesce(p_notes, '')), ''),
      updated_at = v_now
  where id = v_purchase.id;

  return jsonb_build_object(
    'purchase_id', v_purchase.id, 'invoice_no', v_purchase.invoice_no, 'status', 'Draft',
    'subtotal', v_subtotal, 'discount', v_discount, 'tax', v_tax, 'total', v_total
  );
end;
$func$;

revoke all on function public.create_purchase_draft(uuid, uuid, date, text, jsonb) from public;
revoke all on function public.create_purchase_draft(uuid, uuid, date, text, jsonb) from anon;
revoke all on function public.update_purchase_draft(uuid, uuid, date, text, jsonb) from public;
revoke all on function public.update_purchase_draft(uuid, uuid, date, text, jsonb) from anon;
grant execute on function public.create_purchase_draft(uuid, uuid, date, text, jsonb) to authenticated;
grant execute on function public.update_purchase_draft(uuid, uuid, date, text, jsonb) to authenticated;

comment on function public.create_purchase_draft(uuid, uuid, date, text, jsonb) is
  'Atomically creates a Draft purchase and its line items after validating organization, contact, products, quantities, and totals.';
comment on function public.update_purchase_draft(uuid, uuid, date, text, jsonb) is
  'Atomically replaces the Draft purchase lines and recalculates all header totals.';
