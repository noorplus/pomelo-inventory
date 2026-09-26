-- Pomelo Inventory - CATCH-UP BUNDLE (generated, do not hand-edit)
-- Paste this whole file into the Supabase Dashboard SQL editor and Run it.
-- PREREQUISITE: migrations 20260925000100 through 20260926180000 (frozen
-- schema) must already be applied. If unsure, run
-- supabase/probes/live_db_probe.sql first and confirm the frozen tables/RPCs exist.
-- This bundle is idempotent: every section uses IF EXISTS / OR REPLACE, so
-- re-running it is safe. After it succeeds, WAIT ~1 MINUTE for PostgREST's
-- schema cache to reload, then retry the app action.
-- Generated from repo files in strict version order listed below.

-- ================= 20260926210500_purchase_atomic_operations.sql =================
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
--
-- NOTE (2026-09-27 hardening, logic below unchanged): DROP-before-redefine.
-- PostgreSQL identifies a function by (name, argument types) and
-- CREATE OR REPLACE cannot change the return type, so redefining the frozen
-- confirm_/cancel_purchase(uuid) variants would abort this file on a database
-- where they already exist. Dropping those two first makes the file apply
-- cleanly in sequence.
drop function if exists public.confirm_purchase(uuid);
drop function if exists public.cancel_purchase(uuid);

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

-- ================= 20260926220000_atomic_business_operations.sql =================
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
--
-- NOTE (2026-09-27 hardening, logic below unchanged): DROP-before-redefine.
-- PostgreSQL identifies a function by (name, argument types) and
-- CREATE OR REPLACE cannot change the return type, so redefining the
-- confirm_/cancel_ variants created by the preceding migration would abort
-- this file. Dropping those same-signature variants first makes the file
-- apply cleanly in sequence; everything dropped is recreated below.
drop function if exists public.confirm_purchase(uuid);
drop function if exists public.cancel_purchase(uuid);
drop function if exists public.confirm_sale(uuid);
drop function if exists public.cancel_sale(uuid);
drop function if exists public.confirm_expense(uuid);
drop function if exists public.cancel_expense(uuid);
drop function if exists public.cancel_payment(uuid);

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

-- ================= 20260926230000_canonical_atomic_operations.sql =================
-- Pomelo Inventory - Canonical atomic business operations
-- Repository migration only. Do NOT apply to Supabase unless explicitly requested.
--
-- Why this migration exists:
-- The frozen schema migration (20260926180000_purchases_sales_inventory_finance_schema.sql)
-- already defined the hardened atomic RPC layer. Two later migrations redefined the SAME
-- function names with incompatible return types:
--   * 20260926210500_purchase_atomic_operations.sql
--     (confirm_purchase/cancel_purchase returning jsonb)
--   * 20260926220000_atomic_business_operations.sql
--     (confirm_*/cancel_* returning void, plus a split
--      set_payment_allocations + confirm_payment(uuid) payment model)
-- In PostgreSQL a function's identity is (name, argument types) and CREATE OR REPLACE
-- cannot change the return type, so that history cannot apply cleanly in order.
-- This migration consolidates ONE canonical surface and supersedes those variants.
--
-- Canonical surface (logic byte-identical to the frozen 20260926180000 definitions):
--   confirm_purchase(uuid) -> uuid        cancel_purchase(uuid) -> uuid
--   confirm_sale(uuid) -> uuid            cancel_sale(uuid) -> uuid
--   confirm_expense(uuid) -> uuid         cancel_expense(uuid) -> uuid
--   confirm_payment(uuid, jsonb) -> uuid  (single atomic call: allocations are
--     validated and written inside the same transaction; full-amount allocation
--     required; Payment In -> Sales only; Payment Out -> Purchases/Expenses only)
--   cancel_payment(uuid) -> uuid
--   purchase_outstanding(uuid) / sale_outstanding(uuid) / expense_outstanding(uuid)
--     -> numeric (SECURITY INVOKER; outstanding stays derived, no paid_amount columns)
--
-- Superseded and dropped here:
--   set_payment_allocations(uuid, jsonb) and confirm_payment(uuid): the split
--   draft-allocation payment model is replaced by atomic confirm_payment(uuid, jsonb).
--   Verified no application caller depends on them (only app/purchases/actions.ts
--   exists; it uses create/update/delete_purchase_draft + confirm/cancel_purchase,
--   and ignores the confirm/cancel return payload).
--
-- Preserved untouched (defined in 20260926210500, left in force, NOT redefined here):
--   create_purchase_draft, update_purchase_draft, delete_purchase_draft.
--
-- Guarantees: no new tables, no columns added, frozen migration untouched.
-- Every confirm/cancel runs in ONE PostgreSQL transaction with row locking
-- (SELECT ... FOR UPDATE) and is safe against double confirm/cancel.

-- Drop superseded/conflicting variants first. Function identity is (name, args),
-- so each DROP removes whichever return-type variant currently exists.
drop function if exists public.set_payment_allocations(uuid, jsonb);
drop function if exists public.confirm_payment(uuid);
drop function if exists public.confirm_payment(uuid, jsonb);
drop function if exists public.cancel_payment(uuid);
drop function if exists public.confirm_purchase(uuid);
drop function if exists public.cancel_purchase(uuid);
drop function if exists public.confirm_sale(uuid);
drop function if exists public.cancel_sale(uuid);
drop function if exists public.confirm_expense(uuid);
drop function if exists public.cancel_expense(uuid);
drop function if exists public.purchase_outstanding(uuid);
drop function if exists public.sale_outstanding(uuid);
drop function if exists public.expense_outstanding(uuid);
drop function if exists public.rpc_assert_member(uuid);

create or replace function public.rpc_assert_member(p_organization_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $func$
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
$func$;

revoke all on function public.rpc_assert_member(uuid) from public, anon, authenticated;

create or replace function public.confirm_purchase(p_purchase_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $func$
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
$func$;

create or replace function public.cancel_purchase(p_purchase_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $func$
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
$func$;

create or replace function public.confirm_sale(p_sale_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $func$
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
$func$;

create or replace function public.cancel_sale(p_sale_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $func$
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
$func$;

create or replace function public.confirm_expense(p_expense_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $func$
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
$func$;

create or replace function public.cancel_expense(p_expense_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $func$
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
$func$;

create or replace function public.confirm_payment(
  p_payment_id uuid,
  p_allocations jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $func$
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
$func$;

create or replace function public.cancel_payment(p_payment_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $func$
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
$func$;

create or replace function public.purchase_outstanding(p_purchase_id uuid)
returns numeric
language plpgsql
security invoker
set search_path = ''
as $func$
declare
  v_org uuid;
  v_total numeric(18,4);
  v_paid numeric(18,4);
begin
  select organization_id, total into v_org, v_total
  from public.purchases
  where id = p_purchase_id
    and status = 'Confirmed';

  if not found then raise exception 'Confirmed purchase not found'; end if;
  perform public.rpc_assert_member(v_org);

  select coalesce(sum(pa.allocated_amount), 0)
    into v_paid
  from public.payment_allocations pa
  join public.payments py on py.id = pa.payment_id
  where pa.organization_id = v_org
    and pa.purchase_id = p_purchase_id
    and py.status = 'Confirmed';

  return greatest(v_total - v_paid, 0);
end;
$func$;

create or replace function public.sale_outstanding(p_sale_id uuid)
returns numeric
language plpgsql
security invoker
set search_path = ''
as $func$
declare
  v_org uuid;
  v_total numeric(18,4);
  v_paid numeric(18,4);
begin
  select organization_id, total into v_org, v_total
  from public.sales
  where id = p_sale_id
    and status = 'Confirmed';

  if not found then raise exception 'Confirmed sale not found'; end if;
  perform public.rpc_assert_member(v_org);

  select coalesce(sum(pa.allocated_amount), 0)
    into v_paid
  from public.payment_allocations pa
  join public.payments py on py.id = pa.payment_id
  where pa.organization_id = v_org
    and pa.sale_id = p_sale_id
    and py.status = 'Confirmed';

  return greatest(v_total - v_paid, 0);
end;
$func$;

create or replace function public.expense_outstanding(p_expense_id uuid)
returns numeric
language plpgsql
security invoker
set search_path = ''
as $func$
declare
  v_org uuid;
  v_total numeric(18,4);
  v_paid numeric(18,4);
begin
  select organization_id, amount into v_org, v_total
  from public.expenses
  where id = p_expense_id
    and status = 'Confirmed';

  if not found then raise exception 'Confirmed expense not found'; end if;
  perform public.rpc_assert_member(v_org);

  select coalesce(sum(pa.allocated_amount), 0)
    into v_paid
  from public.payment_allocations pa
  join public.payments py on py.id = pa.payment_id
  where pa.organization_id = v_org
    and pa.expense_id = p_expense_id
    and py.status = 'Confirmed';

  return greatest(v_total - v_paid, 0);
end;
$func$;

-- Expose only the authenticated RPC surface; direct ledger writes remain revoked.
revoke all on function public.confirm_purchase(uuid) from public;
revoke all on function public.cancel_purchase(uuid) from public;
revoke all on function public.confirm_sale(uuid) from public;
revoke all on function public.cancel_sale(uuid) from public;
revoke all on function public.confirm_expense(uuid) from public;
revoke all on function public.cancel_expense(uuid) from public;
revoke all on function public.confirm_payment(uuid, jsonb) from public;
revoke all on function public.cancel_payment(uuid) from public;
revoke all on function public.purchase_outstanding(uuid) from public;
revoke all on function public.sale_outstanding(uuid) from public;
revoke all on function public.expense_outstanding(uuid) from public;

grant execute on function public.confirm_purchase(uuid) to authenticated;
grant execute on function public.cancel_purchase(uuid) to authenticated;
grant execute on function public.confirm_sale(uuid) to authenticated;
grant execute on function public.cancel_sale(uuid) to authenticated;
grant execute on function public.confirm_expense(uuid) to authenticated;
grant execute on function public.cancel_expense(uuid) to authenticated;
grant execute on function public.confirm_payment(uuid, jsonb) to authenticated;
grant execute on function public.cancel_payment(uuid) to authenticated;
grant execute on function public.purchase_outstanding(uuid) to authenticated;
grant execute on function public.sale_outstanding(uuid) to authenticated;
grant execute on function public.expense_outstanding(uuid) to authenticated;

comment on function public.confirm_purchase(uuid) is 'Atomically confirms a Draft purchase: validates lines, adds stock, records inventory/accounting entries, then marks Confirmed.';
comment on function public.cancel_purchase(uuid) is 'Atomically cancels a Confirmed purchase: blocks active allocations, reverses stock and accounting through append-only entries, then marks Cancelled.';
comment on function public.confirm_sale(uuid) is 'Atomically confirms a Draft sale: validates lines, locks/decrements stock without allowing negative balance, records inventory/accounting entries, then marks Confirmed.';
comment on function public.cancel_sale(uuid) is 'Atomically cancels a Confirmed sale: reverses stock and accounting through append-only entries, then marks Cancelled.';
comment on function public.confirm_expense(uuid) is 'Atomically confirms a Draft expense and creates expense/payable accounting entries.';
comment on function public.cancel_expense(uuid) is 'Atomically cancels a Confirmed expense after blocking active confirmed payment allocations.';
comment on function public.confirm_payment(uuid, jsonb) is 'Atomically confirms a Draft payment with validated full-amount allocations and accounting entries.';
comment on function public.cancel_payment(uuid) is 'Atomically cancels a Confirmed payment after validating its complete allocation and accounting ledger. Existing allocations remain as audit history but cease to count because outstanding sums only include Confirmed payments.';
comment on function public.purchase_outstanding(uuid) is 'Returns confirmed payment allocation balance due for a Confirmed purchase.';
comment on function public.sale_outstanding(uuid) is 'Returns confirmed payment allocation balance due for a Confirmed sale.';
comment on function public.expense_outstanding(uuid);

-- ================= 20260927090000_organization_member_update_grant.sql =================
-- Pomelo Inventory - Organization member update grant
-- Repository migration only. Do NOT apply to Supabase unless explicitly requested.
--
-- The 20260926090000_organization_update_policy.sql migration allows organization
-- members to update their own organization row, but the initial schema
-- (20260925000100_initial_schema.sql) revoked table-level UPDATE on
-- public.organizations from the authenticated role and nothing ever re-granted
-- it, so the policy can never fire and Settings saves fail with
-- "permission denied". Grant UPDATE only: INSERT stays behind the
-- create_organization RPC and DELETE is never client-allowed. No new tables.

grant update on table public.organizations to authenticated;

-- ================= 20260927100000_payment_expense_numbering.sql =================
-- Pomelo Inventory - Serialized payment/expense numbering
-- Repository migration only. Do NOT apply to Supabase unless explicitly requested.
--
-- The application previously generated payment_no / expense_no client-side via
-- count-then-insert (PAY-000001 / EXP-000001). Under concurrent creates two
-- transactions compute the same number and the second fails on the unique
-- constraint. These RPCs serialize numbering per organization by taking a row
-- lock on the organization before counting, so concurrent creates get distinct
-- numbers. Gaps may occur on rollback; numbers are never reused while the
-- referenced row still exists. No new tables.

create or replace function public.next_payment_no(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $func$
declare
  v_user uuid := (select auth.uid());
  v_count integer;
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

  perform 1 from public.organizations o where o.id = p_organization_id for update;
  if not found then
    raise exception 'Organization not found';
  end if;

  select count(*) into v_count
  from public.payments
  where organization_id = p_organization_id;

  return 'PAY-' || lpad((v_count + 1)::text, 6, '0');
end;
$func$;

create or replace function public.next_expense_no(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $func$
declare
  v_user uuid := (select auth.uid());
  v_count integer;
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

  perform 1 from public.organizations o where o.id = p_organization_id for update;
  if not found then
    raise exception 'Organization not found';
  end if;

  select count(*) into v_count
  from public.expenses
  where organization_id = p_organization_id;

  return 'EXP-' || lpad((v_count + 1)::text, 6, '0');
end;
$func$;

revoke all on function public.next_payment_no(uuid) from public;
revoke all on function public.next_expense_no(uuid) from public;
grant execute on function public.next_payment_no(uuid) to authenticated;
grant execute on function public.next_expense_no(uuid) to authenticated;

comment on function public.next_payment_no(uuid) is 'Returns the next serialized payment number (PAY-000001 style) for an organization.';
comment on function public.next_expense_no(uuid) is 'Returns the next serialized expense number (EXP-000001 style) for an organization.';

-- ================= 20260927110000_inventory_adjustments_returns.sql =================
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
