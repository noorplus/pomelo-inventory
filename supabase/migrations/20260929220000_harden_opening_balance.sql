-- Harden Opening Balance handling.
-- This migration is intentionally isolated to the stock-adjustment RPC
-- and the Opening movement invariant. It does not change Purchase, Sale,
-- Return, Payment, Accounting, or existing WAC functions.

create unique index inventory_movements_one_opening_per_product
on public.inventory_movements (organization_id, product_id)
where movement_type = 'Opening';

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
as $function$
declare
  v_user uuid := (select auth.uid());
  v_product_id uuid;
  v_cost numeric;
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

  /*
   * Lock the product row so Opening validation and creation are serialized
   * for the same product. The unique index below remains the database-level
   * invariant for the one-Opening-per-product rule.
   */
  select p.id
    into v_product_id
  from public.products as p
  where p.id = p_product_id
    and p.organization_id = p_organization_id
  for update;

  if not found then
    raise exception 'Product not found in this organization';
  end if;

  /*
   * Opening Balance is an initial inventory state:
   *   - inbound only
   *   - exactly once per organization/product
   *   - must be the first inventory movement for the product
   *   - unit cost is mandatory for the initial valuation
   */
  if p_movement_type = 'Opening' then
    if p_direction <> 'In' then
      raise exception 'Opening balance must be an inbound movement';
    end if;

    if exists (
      select 1
      from public.inventory_movements as im
      where im.organization_id = p_organization_id
        and im.product_id = p_product_id
        and im.movement_type = 'Opening'
    ) then
      raise exception 'Opening balance already exists for this product';
    end if;

    if exists (
      select 1
      from public.inventory_movements as im
      where im.organization_id = p_organization_id
        and im.product_id = p_product_id
    ) then
      raise exception
        'Opening balance must be the first inventory movement for this product';
    end if;

    if p_unit_cost is null then
      raise exception 'Unit cost is required for Opening balance';
    end if;
  end if;

  /*
   * Preserve the existing Weighted Average Cost behavior.
   */
  if p_direction = 'In' then
    select s.average_cost
      into v_cost
    from public.stock as s
    where s.organization_id = p_organization_id
      and s.product_id = p_product_id
    for update;

    v_cost := coalesce(p_unit_cost, v_cost);

    if v_cost is null then
      raise exception 'Unit cost is required for inbound Opening/Adjustment';
    end if;

    perform private.wac_in(
      p_organization_id,
      p_product_id,
      p_quantity,
      v_cost
    );
  else
    select s.average_cost
      into v_cost
    from public.stock as s
    where s.organization_id = p_organization_id
      and s.product_id = p_product_id
    for update;

    if v_cost is null then
      raise exception 'No inventory cost exists for this product';
    end if;

    v_cost := private.wac_out(
      p_organization_id,
      p_product_id,
      p_quantity
    );
  end if;

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
  values (
    p_organization_id,
    p_product_id,
    p_direction,
    p_movement_type,
    p_quantity,
    null,
    null,
    round(v_cost, 4),
    now(),
    v_user
  )
  returning public.inventory_movements.id
    into v_movement_id;

  return v_movement_id;
end
$function$;

revoke all on function public.record_stock_adjustment(
  uuid,
  uuid,
  numeric,
  public.inventory_movement_direction,
  public.inventory_movement_type,
  numeric,
  text
) from public;

grant execute on function public.record_stock_adjustment(
  uuid,
  uuid,
  numeric,
  public.inventory_movement_direction,
  public.inventory_movement_type,
  numeric,
  text
) to authenticated;

grant execute on function public.record_stock_adjustment(
  uuid,
  uuid,
  numeric,
  public.inventory_movement_direction,
  public.inventory_movement_type,
  numeric,
  text
) to postgres;

comment on function public.record_stock_adjustment(
  uuid,
  uuid,
  numeric,
  public.inventory_movement_direction,
  public.inventory_movement_type,
  numeric,
  text
) is 'Atomically records an Opening or Adjustment stock movement and updates weighted-average inventory cost. Opening is allowed once per product and must be the first inventory movement.';
