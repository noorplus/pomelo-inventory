-- Pomelo Inventory - Atomic Purchase Operations
-- Repository migration only. Do not apply to Supabase unless explicitly requested.
--
-- Purchase service boundary:
-- Draft creation/update is atomic across purchase header + line items.
-- Confirmation is atomic across purchase status + stock + inventory ledger + payable ledger.
-- Cancellation is atomic across purchase status + reverse stock movement + reversing payable entry.
-- Payment allocations are not created by purchase operations; confirmed payments are handled by
-- the payment service and a confirmed allocation blocks purchase cancellation.
--
-- No new tables are introduced.

create or replace function public.create_purchase_draft(
  p_organization_id uuid,
  p_contact_id uuid,
  p_invoice_date date default null,
  p_notes text default null,
  p_items jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_purchase_id uuid;
  v_invoice_date date := coalesce(p_invoice_date, current_date);
  v_subtotal numeric(18,4);
  v_discount numeric(18,4);
  v_tax numeric(18,4);
  v_total numeric(18,4);
  v_item_count integer;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = p_organization_id
      and ou.user_id = v_user_id
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  if not exists (
    select 1
    from public.contacts c
    where c.id = p_contact_id
      and c.organization_id = p_organization_id
  ) then
    raise exception 'Contact not found in this organization';
  end if;

  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'Purchase items must be an array';
  end if;

  select count(*) into v_item_count
  from jsonb_to_recordset(p_items) as x(
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric,
    tax numeric
  );

  if v_item_count = 0 then
    raise exception 'Add at least one product';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      product_id uuid,
      quantity numeric,
      unit_price numeric,
      discount numeric,
      tax numeric
    )
    where x.product_id is null
       or x.quantity is null
       or x.quantity <= 0
       or x.unit_price is null
       or x.unit_price < 0
       or coalesce(x.discount, 0) < 0
       or coalesce(x.tax, 0) < 0
       or coalesce(x.discount, 0) > x.quantity * x.unit_price
  ) then
    raise exception 'One or more purchase items are invalid';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      product_id uuid,
      quantity numeric,
      unit_price numeric,
      discount numeric,
      tax numeric
    )
    group by x.product_id
    having count(*) > 1
  ) then
    raise exception 'A product can appear only once in a purchase';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      product_id uuid,
      quantity numeric,
      unit_price numeric,
      discount numeric,
      tax numeric
    )
    where not exists (
      select 1
      from public.products p
      where p.id = x.product_id
        and p.organization_id = p_organization_id
    )
  ) then
    raise exception 'One or more products do not belong to this organization';
  end if;

  select
    coalesce(sum(x.quantity * x.unit_price), 0),
    coalesce(sum(coalesce(x.discount, 0)), 0),
    coalesce(sum(coalesce(x.tax, 0)), 0)
  into v_subtotal, v_discount, v_tax
  from jsonb_to_recordset(p_items) as x(
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric,
    tax numeric
  );

  v_total := v_subtotal - v_discount + v_tax;

  insert into public.purchases (
    organization_id,
    contact_id,
    invoice_date,
    status,
    subtotal,
    discount,
    tax,
    total,
    notes,
    created_by
  )
  values (
    p_organization_id,
    p_contact_id,
    v_invoice_date,
    'Draft',
    v_subtotal,
    v_discount,
    v_tax,
    v_total,
    nullif(btrim(p_notes), ''),
    v_user_id
  )
  returning id into v_purchase_id;

  insert into public.purchase_items (
    organization_id,
    purchase_id,
    product_id,
    quantity,
    unit_price,
    discount,
    tax,
    line_total,
    created_by
  )
  select
    p_organization_id,
    v_purchase_id,
    x.product_id,
    x.quantity,
    x.unit_price,
    coalesce(x.discount, 0),
    coalesce(x.tax, 0),
    x.quantity * x.unit_price - coalesce(x.discount, 0) + coalesce(x.tax, 0),
    v_user_id
  from jsonb_to_recordset(p_items) as x(
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric,
    tax numeric
  );

  return jsonb_build_object(
    'purchase_id', v_purchase_id
  );
end;
$$;

create or replace function public.update_purchase_draft(
  p_purchase_id uuid,
  p_contact_id uuid,
  p_invoice_date date default null,
  p_notes text default null,
  p_items jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_purchase_creator uuid;
  v_current_status public.invoice_status;
  v_invoice_date date := coalesce(p_invoice_date, current_date);
  v_subtotal numeric(18,4);
  v_discount numeric(18,4);
  v_tax numeric(18,4);
  v_total numeric(18,4);
  v_item_count integer;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select p.organization_id, p.created_by, p.status
  into v_organization_id, v_purchase_creator, v_current_status
  from public.purchases p
  where p.id = p_purchase_id
  for update;

  if not found then
    raise exception 'Purchase not found';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = v_organization_id
      and ou.user_id = v_user_id
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  if v_current_status <> 'Draft' then
    raise exception 'Only Draft purchase invoices can be edited';
  end if;

  if not exists (
    select 1
    from public.contacts c
    where c.id = p_contact_id
      and c.organization_id = v_organization_id
  ) then
    raise exception 'Contact not found in this organization';
  end if;

  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'Purchase items must be an array';
  end if;

  select count(*) into v_item_count
  from jsonb_to_recordset(p_items) as x(
    id uuid,
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric,
    tax numeric
  );

  if v_item_count = 0 then
    raise exception 'Add at least one product';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      id uuid,
      product_id uuid,
      quantity numeric,
      unit_price numeric,
      discount numeric,
      tax numeric
    )
    where x.product_id is null
       or x.quantity is null
       or x.quantity <= 0
       or x.unit_price is null
       or x.unit_price < 0
       or coalesce(x.discount, 0) < 0
       or coalesce(x.tax, 0) < 0
       or coalesce(x.discount, 0) > x.quantity * x.unit_price
  ) then
    raise exception 'One or more purchase items are invalid';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      id uuid,
      product_id uuid,
      quantity numeric,
      unit_price numeric,
      discount numeric,
      tax numeric
    )
    group by x.product_id
    having count(*) > 1
  ) then
    raise exception 'A product can appear only once in a purchase';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      id uuid,
      product_id uuid,
      quantity numeric,
      unit_price numeric,
      discount numeric,
      tax numeric
    )
    where not exists (
      select 1
      from public.products p
      where p.id = x.product_id
        and p.organization_id = v_organization_id
    )
  ) then
    raise exception 'One or more products do not belong to this organization';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      id uuid,
      product_id uuid,
      quantity numeric,
      unit_price numeric,
      discount numeric,
      tax numeric
    )
    where x.id is not null
      and not exists (
        select 1
        from public.purchase_items pi
        where pi.id = x.id
          and pi.purchase_id = p_purchase_id
          and pi.organization_id = v_organization_id
      )
  ) then
    raise exception 'One or more purchase item IDs are invalid';
  end if;

  select
    coalesce(sum(x.quantity * x.unit_price), 0),
    coalesce(sum(coalesce(x.discount, 0)), 0),
    coalesce(sum(coalesce(x.tax, 0)), 0)
  into v_subtotal, v_discount, v_tax
  from jsonb_to_recordset(p_items) as x(
    id uuid,
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric,
    tax numeric
  );

  v_total := v_subtotal - v_discount + v_tax;

  update public.purchases
  set contact_id = p_contact_id,
      invoice_date = v_invoice_date,
      subtotal = v_subtotal,
      discount = v_discount,
      tax = v_tax,
      total = v_total,
      notes = nullif(btrim(p_notes), ''),
      updated_at = now()
  where id = p_purchase_id;

  delete from public.purchase_items pi
  where pi.purchase_id = p_purchase_id
    and not exists (
      select 1
      from jsonb_to_recordset(p_items) as x(
        id uuid,
        product_id uuid,
        quantity numeric,
        unit_price numeric,
        discount numeric,
        tax numeric
      )
      where x.id = pi.id
    );

  update public.purchase_items pi
  set product_id = x.product_id,
      quantity = x.quantity,
      unit_price = x.unit_price,
      discount = coalesce(x.discount, 0),
      tax = coalesce(x.tax, 0),
      line_total = x.quantity * x.unit_price - coalesce(x.discount, 0) + coalesce(x.tax, 0),
      updated_at = now()
  from jsonb_to_recordset(p_items) as x(
    id uuid,
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric,
    tax numeric
  )
  where pi.id = x.id
    and pi.purchase_id = p_purchase_id;

  insert into public.purchase_items (
    organization_id,
    purchase_id,
    product_id,
    quantity,
    unit_price,
    discount,
    tax,
    line_total,
    created_by
  )
  select
    v_organization_id,
    p_purchase_id,
    x.product_id,
    x.quantity,
    x.unit_price,
    coalesce(x.discount, 0),
    coalesce(x.tax, 0),
    x.quantity * x.unit_price - coalesce(x.discount, 0) + coalesce(x.tax, 0),
    v_user_id
  from jsonb_to_recordset(p_items) as x(
    id uuid,
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric,
    tax numeric
  )
  where x.id is null;

  return jsonb_build_object(
    'purchase_id', p_purchase_id
  );
end;
$$;

create or replace function public.delete_purchase_draft(
  p_purchase_id uuid
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_status public.invoice_status;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select p.organization_id, p.status
  into v_organization_id, v_status
  from public.purchases p
  where p.id = p_purchase_id
  for update;

  if not found then
    raise exception 'Purchase not found';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = v_organization_id
      and ou.user_id = v_user_id
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  if v_status <> 'Draft' then
    raise exception 'Only Draft purchase invoices can be deleted';
  end if;

  delete from public.purchases
  where id = p_purchase_id;
end;
$$;

create or replace function public.confirm_purchase(
  p_purchase_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_contact_id uuid;
  v_status public.invoice_status;
  v_total numeric(18,4);
  v_item_count integer;
  v_existing_total numeric(18,4);
  v_product_id uuid;
  v_quantity numeric(18,4);
  v_stock_quantity numeric(18,4);
  v_line_total numeric(18,4);
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select p.organization_id, p.contact_id, p.status, p.total
  into v_organization_id, v_contact_id, v_status, v_total
  from public.purchases p
  where p.id = p_purchase_id
  for update;

  if not found then
    raise exception 'Purchase not found';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = v_organization_id
      and ou.user_id = v_user_id
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  if v_status <> 'Draft' then
    raise exception 'Only Draft purchase invoices can be confirmed';
  end if;

  select count(*), coalesce(sum(pi.line_total), 0)
  into v_item_count, v_existing_total
  from public.purchase_items pi
  where pi.purchase_id = p_purchase_id
    and pi.organization_id = v_organization_id;

  if v_item_count = 0 then
    raise exception 'A purchase must contain at least one item';
  end if;

  if v_existing_total <> v_total then
    raise exception 'Purchase total does not match its line items';
  end if;

  -- Lock/update each product stock row inside this transaction before writing the movement.
  for v_product_id, v_quantity in
    select pi.product_id, pi.quantity
    from public.purchase_items pi
    where pi.purchase_id = p_purchase_id
      and pi.organization_id = v_organization_id
    order by pi.product_id
  loop
    insert into public.stock (organization_id, product_id, quantity)
    values (v_organization_id, v_product_id, 0)
    on conflict (organization_id, product_id) do nothing;

    select s.quantity
    into v_stock_quantity
    from public.stock s
    where s.organization_id = v_organization_id
      and s.product_id = v_product_id
    for update;

    update public.stock
    set quantity = v_stock_quantity + v_quantity,
        updated_at = now()
    where organization_id = v_organization_id
      and product_id = v_product_id;

    select pi.line_total
    into v_line_total
    from public.purchase_items pi
    where pi.purchase_id = p_purchase_id
      and pi.organization_id = v_organization_id
      and pi.product_id = v_product_id;

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
      created_by
    )
    select
      v_organization_id,
      pi.product_id,
      'In',
      'Purchase',
      pi.quantity,
      'purchase',
      p_purchase_id,
      pi.unit_price,
      now(),
      v_user_id
    from public.purchase_items pi
    where pi.purchase_id = p_purchase_id
      and pi.organization_id = v_organization_id
      and pi.product_id = v_product_id;
  end loop;

  insert into public.account_transactions (
    organization_id,
    transaction_date,
    transaction_type,
    reference_type,
    reference_id,
    contact_id,
    description,
    debit,
    credit,
    created_by
  )
  values (
    v_organization_id,
    now(),
    'Purchase',
    'purchase',
    p_purchase_id,
    v_contact_id,
    'Purchase payable - invoice ' ||
      (select p.invoice_no from public.purchases p where p.id = p_purchase_id),
    0,
    v_total,
    v_user_id
  );

  update public.purchases
  set status = 'Confirmed',
      updated_at = now()
  where id = p_purchase_id;

  return jsonb_build_object(
    'purchase_id', p_purchase_id,
    'status', 'Confirmed',
    'total', v_total
  );
end;
$$;

create or replace function public.cancel_purchase(
  p_purchase_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_organization_id uuid;
  v_contact_id uuid;
  v_invoice_no text;
  v_status public.invoice_status;
  v_total numeric(18,4);
  v_product_id uuid;
  v_quantity numeric(18,4);
  v_stock_quantity numeric(18,4);
  v_paid numeric(18,4);
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select p.organization_id, p.contact_id, p.invoice_no, p.status, p.total
  into v_organization_id, v_contact_id, v_invoice_no, v_status, v_total
  from public.purchases p
  where p.id = p_purchase_id
  for update;

  if not found then
    raise exception 'Purchase not found';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = v_organization_id
      and ou.user_id = v_user_id
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  if v_status <> 'Confirmed' then
    raise exception 'Only Confirmed purchase invoices can be cancelled';
  end if;

  select coalesce(sum(pa.allocated_amount), 0)
  into v_paid
  from public.payment_allocations pa
  join public.payments pay
    on pay.id = pa.payment_id
   and pay.organization_id = pa.organization_id
  where pa.organization_id = v_organization_id
    and pa.purchase_id = p_purchase_id
    and pay.status = 'Confirmed';

  if v_paid > 0 then
    raise exception 'Purchase cannot be cancelled while confirmed payments are allocated to it';
  end if;

  for v_product_id, v_quantity in
    select pi.product_id, pi.quantity
    from public.purchase_items pi
    where pi.purchase_id = p_purchase_id
      and pi.organization_id = v_organization_id
    order by pi.product_id
  loop
    select s.quantity
    into v_stock_quantity
    from public.stock s
    where s.organization_id = v_organization_id
      and s.product_id = v_product_id
    for update;

    if not found then
      raise exception 'Stock record not found for product %', v_product_id;
    end if;

    if v_stock_quantity < v_quantity then
      raise exception 'Purchase cannot be cancelled because stock for product % is already consumed', v_product_id;
    end if;

    update public.stock
    set quantity = quantity - v_quantity,
        updated_at = now()
    where organization_id = v_organization_id
      and product_id = v_product_id;

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
      created_by
    )
    select
      v_organization_id,
      pi.product_id,
      'Out',
      'Return',
      pi.quantity,
      'purchase_cancel',
      p_purchase_id,
      pi.unit_price,
      now(),
      v_user_id
    from public.purchase_items pi
    where pi.purchase_id = p_purchase_id
      and pi.organization_id = v_organization_id
      and pi.product_id = v_product_id;
  end loop;

  insert into public.account_transactions (
    organization_id,
    transaction_date,
    transaction_type,
    reference_type,
    reference_id,
    contact_id,
    description,
    debit,
    credit,
    created_by
  )
  values (
    v_organization_id,
    now(),
    'Purchase Cancellation',
    'purchase',
    p_purchase_id,
    v_contact_id,
    'Reversal of purchase payable - invoice ' || v_invoice_no,
    v_total,
    0,
    v_user_id
  );

  update public.purchases
  set status = 'Cancelled',
      updated_at = now()
  where id = p_purchase_id;

  return jsonb_build_object(
    'purchase_id', p_purchase_id,
    'status', 'Cancelled',
    'total', v_total
  );
end;
$$;

revoke all on function public.create_purchase_draft(uuid, uuid, date, text, jsonb) from public;
revoke all on function public.update_purchase_draft(uuid, uuid, date, text, jsonb) from public;
revoke all on function public.delete_purchase_draft(uuid) from public;
revoke all on function public.confirm_purchase(uuid) from public;
revoke all on function public.cancel_purchase(uuid) from public;

grant execute on function public.create_purchase_draft(uuid, uuid, date, text, jsonb) to authenticated;
grant execute on function public.update_purchase_draft(uuid, uuid, date, text, jsonb) to authenticated;
grant execute on function public.delete_purchase_draft(uuid) to authenticated;
grant execute on function public.confirm_purchase(uuid) to authenticated;
grant execute on function public.cancel_purchase(uuid) to authenticated;

comment on function public.create_purchase_draft(uuid, uuid, date, text, jsonb)
is 'Atomically creates a Draft purchase and its line items. Server calculates invoice totals and enforces organization ownership.';

comment on function public.update_purchase_draft(uuid, uuid, date, text, jsonb)
is 'Atomically updates a Draft purchase. Existing line-item creators remain immutable; newly added lines use the current actor.';

comment on function public.delete_purchase_draft(uuid)
is 'Deletes a Draft purchase only. Confirmed and Cancelled purchase history is immutable.';

comment on function public.confirm_purchase(uuid)
is 'Atomically confirms a purchase, increases stock, writes purchase inventory movements, and creates the payable ledger entry.';

comment on function public.cancel_purchase(uuid)
is 'Atomically cancels a confirmed purchase, reverses stock and payable effects, and blocks cancellation when confirmed payments are allocated or stock has been consumed.';
