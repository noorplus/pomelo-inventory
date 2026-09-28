-- Fix purchase confirmation validation and inventory costing for the two-level discount model.
-- Item line totals already include item-level discounts. The purchase header
-- discount is the separate overall discount and must be applied once more
-- before comparing against purchases.total.
--
-- The public function previously returned uuid. Drop it before recreating because
-- PostgreSQL cannot change a function return type with CREATE OR REPLACE.

drop function if exists public.confirm_purchase(uuid);

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
  v_discount numeric(18,4);
  v_item_count integer;
  v_existing_total numeric(18,4);
  v_expected_total numeric(18,4);
  v_product_id uuid;
  v_quantity numeric(18,4);
  v_stock_quantity numeric(18,4);
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select p.organization_id, p.contact_id, p.status, p.total, p.discount
  into v_organization_id, v_contact_id, v_status, v_total, v_discount
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

  v_discount := coalesce(v_discount, 0);
  if v_discount < 0 then
    raise exception 'Overall discount cannot be negative';
  end if;
  if v_discount > v_existing_total then
    raise exception 'Overall discount cannot exceed subtotal after item discounts';
  end if;

  v_expected_total := v_existing_total - v_discount;

  if v_expected_total <> v_total then
    raise exception 'Purchase total does not match its item totals after overall discount';
  end if;

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

    -- Inventory movements are inserted after stock updates so the overall
    -- discount can be allocated proportionally across all net purchase lines.
  end loop;

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
  with ordered as (
    select
      pi.product_id,
      pi.quantity,
      pi.line_total,
      row_number() over (order by pi.product_id) as rn,
      count(*) over () as row_count,
      sum(pi.line_total) over () as net_total
    from public.purchase_items pi
    where pi.purchase_id = p_purchase_id
      and pi.organization_id = v_organization_id
  ),
  allocated as (
    select
      o.*,
      case
        when o.rn = o.row_count then
          v_discount - coalesce(
            (
              select sum(round(v_discount * o2.line_total / nullif(o2.net_total, 0), 4))
              from ordered o2
              where o2.rn < o.rn
            ),
            0
          )
        else round(v_discount * o.line_total / nullif(o.net_total, 0), 4)
      end as allocated_discount
    from ordered o
  )
  select
    v_organization_id,
    a.product_id,
    'In',
    'Purchase',
    a.quantity,
    'purchase',
    p_purchase_id,
    round((a.line_total - a.allocated_discount) / nullif(a.quantity, 0), 4),
    now(),
    v_user_id
  from allocated a;

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

revoke all on function public.confirm_purchase(uuid) from public;
grant execute on function public.confirm_purchase(uuid) to authenticated;

comment on function public.confirm_purchase(uuid)
is 'Atomically confirms a purchase, validates line totals plus overall discount, increases stock, writes purchase inventory movements, and creates the payable ledger entry.';
