-- Pomelo Inventory - Atomic Sale Draft Operations
-- Repository migration only. Do NOT apply to Supabase unless explicitly requested.
--
-- Mirrors 20260926210500 purchase drafts for the sales side, which previously
-- had no atomic draft RPCs (clients wrote header + lines as separate queries):
-- Draft creation/update is atomic across sale header + line items, with
-- server-computed totals, same-organization enforcement and immutable
-- line-item creators. Deletion is Draft-only.
--
-- No new tables are introduced.

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
    raise exception 'Sale items must be an array';
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
    raise exception 'One or more sale items are invalid';
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
    raise exception 'A product can appear only once in a sale';
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

  insert into public.sales (
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
  returning id into v_sale_id;

  insert into public.sale_items (
    organization_id,
    sale_id,
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
    v_sale_id,
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
  v_tax numeric(18,4);
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
      tax numeric
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

  update public.sales
  set contact_id = p_contact_id,
      invoice_date = v_invoice_date,
      subtotal = v_subtotal,
      discount = v_discount,
      tax = v_tax,
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
        tax numeric
      )
      where x.id = si.id
    );

  update public.sale_items si
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
  where si.id = x.id
    and si.sale_id = p_sale_id;

  insert into public.sale_items (
    organization_id,
    sale_id,
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
    p_sale_id,
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
    'sale_id', p_sale_id
  );
end;
$$;

create or replace function public.delete_sale_draft(
  p_sale_id uuid
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

  select s.organization_id, s.status
  into v_organization_id, v_status
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

  if v_status <> 'Draft' then
    raise exception 'Only Draft sales invoices can be deleted';
  end if;

  delete from public.sales
  where id = p_sale_id;
end;
$$;

revoke all on function public.create_sale_draft(uuid, uuid, date, text, jsonb) from public;
revoke all on function public.update_sale_draft(uuid, uuid, date, text, jsonb) from public;
revoke all on function public.delete_sale_draft(uuid) from public;

grant execute on function public.create_sale_draft(uuid, uuid, date, text, jsonb) to authenticated;
grant execute on function public.update_sale_draft(uuid, uuid, date, text, jsonb) to authenticated;
grant execute on function public.delete_sale_draft(uuid) to authenticated;

comment on function public.create_sale_draft(uuid, uuid, date, text, jsonb)
is 'Atomically creates a Draft sale and its line items. Server calculates invoice totals and enforces organization ownership.';

comment on function public.update_sale_draft(uuid, uuid, date, text, jsonb)
is 'Atomically updates a Draft sale. Existing line-item creators remain immutable; newly added lines use the current actor.';

comment on function public.delete_sale_draft(uuid)
is 'Deletes a Draft sale only. Confirmed and Cancelled sales history is immutable.';
