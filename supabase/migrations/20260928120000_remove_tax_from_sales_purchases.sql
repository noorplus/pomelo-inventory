-- Remove Tax from purchases and sales.
-- Historical migrations remain unchanged; this migration removes the live schema/API dependency.

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
    discount numeric
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
    )
    where x.product_id is null
       or x.quantity is null
       or x.quantity <= 0
       or x.unit_price is null
       or x.unit_price < 0
       or coalesce(x.discount, 0) < 0
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
    coalesce(sum(coalesce(x.discount, 0)), 0)
  into v_subtotal, v_discount
  from jsonb_to_recordset(p_items) as x(
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric
  );

  v_total := v_subtotal - v_discount;

  insert into public.purchases (
    organization_id,
    contact_id,
    invoice_date,
    status,
    subtotal,
    discount,
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
    x.quantity * x.unit_price - coalesce(x.discount, 0),
    v_user_id
  from jsonb_to_recordset(p_items) as x(
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric
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
    discount numeric
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
    )
    where x.product_id is null
       or x.quantity is null
       or x.quantity <= 0
       or x.unit_price is null
       or x.unit_price < 0
       or coalesce(x.discount, 0) < 0
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
    coalesce(sum(coalesce(x.discount, 0)), 0)
  into v_subtotal, v_discount
  from jsonb_to_recordset(p_items) as x(
    id uuid,
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric
  );

  v_total := v_subtotal - v_discount;

  update public.purchases
  set contact_id = p_contact_id,
      invoice_date = v_invoice_date,
      subtotal = v_subtotal,
      discount = v_discount,
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
      )
      where x.id = pi.id
    );

  update public.purchase_items pi
  set product_id = x.product_id,
      quantity = x.quantity,
      unit_price = x.unit_price,
      discount = coalesce(x.discount, 0),
      line_total = x.quantity * x.unit_price - coalesce(x.discount, 0) ,
      updated_at = now()
  from jsonb_to_recordset(p_items) as x(
    id uuid,
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric,
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
    x.quantity * x.unit_price - coalesce(x.discount, 0),
    v_user_id
  from jsonb_to_recordset(p_items) as x(
    id uuid,
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric,
  )
  where x.id is null;

  return jsonb_build_object(
    'purchase_id', p_purchase_id
  );
end;
$$;

create or replace function public.create_sale_draft(
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
  v_sale_id uuid;
  v_invoice_date date := coalesce(p_invoice_date, current_date);
  v_subtotal numeric(18,4);
  v_discount numeric(18,4);
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
    raise exception 'Sale items must be an array';
  end if;

  select count(*) into v_item_count
  from jsonb_to_recordset(p_items) as x(
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric
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
    )
    where x.product_id is null
       or x.quantity is null
       or x.quantity <= 0
       or x.unit_price is null
       or x.unit_price < 0
       or coalesce(x.discount, 0) < 0
       or coalesce(x.discount, 0) > x.quantity * x.unit_price
  ) then
    raise exception 'One or more sale items are invalid';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      product_id uuid,
      quantity numeric,
      unit_price numeric,
      discount numeric,
    )
    group by x.product_id
    having count(*) > 1
  ) then
    raise exception 'A product can appear only once in a sale';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      product_id uuid,
      quantity numeric,
      unit_price numeric,
      discount numeric,
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
    coalesce(sum(coalesce(x.discount, 0)), 0)
  into v_subtotal, v_discount
  from jsonb_to_recordset(p_items) as x(
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric
  );

  v_total := v_subtotal - v_discount;

  insert into public.sales (
    organization_id,
    contact_id,
    invoice_date,
    status,
    subtotal,
    discount,
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
    v_total,
    nullif(btrim(p_notes), ''),
    v_user_id
  )
  returning id into v_sale_id;

  insert into public.sale_items (
    organization_id,
    sale_id,
    product_id,
    quantity,
    unit_price,
    discount,
    line_total,
    created_by
  )
  select
    p_organization_id,
    v_sale_id,
    x.product_id,
    x.quantity,
    x.unit_price,
    coalesce(x.discount, 0),
    x.quantity * x.unit_price - coalesce(x.discount, 0),
    v_user_id
  from jsonb_to_recordset(p_items) as x(
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric
  );

  return jsonb_build_object(
    'sale_id', v_sale_id
  );
end;
$$;

create or replace function public.update_sale_draft(
  p_sale_id uuid,
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
  v_sale_creator uuid;
  v_current_status public.invoice_status;
  v_invoice_date date := coalesce(p_invoice_date, current_date);
  v_subtotal numeric(18,4);
  v_discount numeric(18,4);
  v_total numeric(18,4);
  v_item_count integer;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select s.organization_id, s.created_by, s.status
  into v_organization_id, v_sale_creator, v_current_status
  from public.sales s
  where s.id = p_sale_id
  for update;

  if not found then
    raise exception 'Sale not found';
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
    raise exception 'Only Draft sales invoices can be edited';
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
    raise exception 'Sale items must be an array';
  end if;

  select count(*) into v_item_count
  from jsonb_to_recordset(p_items) as x(
    id uuid,
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric
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
    )
    where x.product_id is null
       or x.quantity is null
       or x.quantity <= 0
       or x.unit_price is null
       or x.unit_price < 0
       or coalesce(x.discount, 0) < 0
       or coalesce(x.discount, 0) > x.quantity * x.unit_price
  ) then
    raise exception 'One or more sale items are invalid';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      id uuid,
      product_id uuid,
      quantity numeric,
      unit_price numeric,
      discount numeric,
    )
    group by x.product_id
    having count(*) > 1
  ) then
    raise exception 'A product can appear only once in a sale';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_items) as x(
      id uuid,
      product_id uuid,
      quantity numeric,
      unit_price numeric,
      discount numeric,
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
    )
    where x.id is not null
      and not exists (
        select 1
        from public.sale_items si
        where si.id = x.id
          and si.sale_id = p_sale_id
          and si.organization_id = v_organization_id
      )
  ) then
    raise exception 'One or more sale item IDs are invalid';
  end if;

  select
    coalesce(sum(x.quantity * x.unit_price), 0),
    coalesce(sum(coalesce(x.discount, 0)), 0)
  into v_subtotal, v_discount
  from jsonb_to_recordset(p_items) as x(
    id uuid,
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric
  );

  v_total := v_subtotal - v_discount;

  update public.sales
  set contact_id = p_contact_id,
      invoice_date = v_invoice_date,
      subtotal = v_subtotal,
      discount = v_discount,
      total = v_total,
      notes = nullif(btrim(p_notes), ''),
      updated_at = now()
  where id = p_sale_id;

  delete from public.sale_items si
  where si.sale_id = p_sale_id
    and not exists (
      select 1
      from jsonb_to_recordset(p_items) as x(
        id uuid,
        product_id uuid,
        quantity numeric,
        unit_price numeric,
        discount numeric,
      )
      where x.id = si.id
    );

  update public.sale_items si
  set product_id = x.product_id,
      quantity = x.quantity,
      unit_price = x.unit_price,
      discount = coalesce(x.discount, 0),
      line_total = x.quantity * x.unit_price - coalesce(x.discount, 0) ,
      updated_at = now()
  from jsonb_to_recordset(p_items) as x(
    id uuid,
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric,
  )
  where si.id = x.id
    and si.sale_id = p_sale_id;

  insert into public.sale_items (
    organization_id,
    sale_id,
    product_id,
    quantity,
    unit_price,
    discount,
    line_total,
    created_by
  )
  select
    v_organization_id,
    p_sale_id,
    x.product_id,
    x.quantity,
    x.unit_price,
    coalesce(x.discount, 0),
    x.quantity * x.unit_price - coalesce(x.discount, 0),
    v_user_id
  from jsonb_to_recordset(p_items) as x(
    id uuid,
    product_id uuid,
    quantity numeric,
    unit_price numeric,
    discount numeric,
  )
  where x.id is null;

  return jsonb_build_object(
    'sale_id', p_sale_id
  );
end;
$$;

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
      select product_id, quantity, unit_price, discount
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
        ;
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
      select product_id, quantity, unit_price, discount
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
        ;
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

update public.purchase_items set line_total = quantity * unit_price - discount;
update public.purchases set total = subtotal - discount;
update public.sale_items set line_total = quantity * unit_price - discount;
update public.sales set total = subtotal - discount;

alter table public.purchase_items drop column tax;
alter table public.purchases drop column tax;
alter table public.sale_items drop column tax;
alter table public.sales drop column tax;
