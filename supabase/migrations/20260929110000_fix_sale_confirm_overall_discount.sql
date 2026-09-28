-- Fix sale confirmation validation for the two-level discount model.
-- sale_items.line_total already includes item-level discounts, while
-- sales.discount is the separate overall/header discount.

create or replace function public.confirm_sale(p_sale_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_user uuid := (select auth.uid());
  v_org uuid;
  v_status public.invoice_status;
  v_total numeric(18,4);
  v_discount numeric(18,4);
  v_item_total numeric(18,4);
  v_item_count integer;
  v_expected_total numeric(18,4);
  r record;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;

  select organization_id, status, total, discount
    into v_org, v_status, v_total, v_discount
  from public.sales
  where id = p_sale_id
  for update;

  if not found then
    raise exception 'Sale not found';
  end if;

  perform public.rpc_assert_member(v_org);

  if v_status <> 'Draft' then
    raise exception 'Only Draft sales can be confirmed';
  end if;

  select count(*), coalesce(sum(line_total), 0)
    into v_item_count, v_item_total
  from public.sale_items
  where sale_id = p_sale_id
    and organization_id = v_org;

  if v_item_count = 0 then
    raise exception 'Sale must contain at least one item';
  end if;

  v_discount := coalesce(v_discount, 0);
  if v_discount < 0 then
    raise exception 'Overall discount cannot be negative';
  end if;
  if v_discount > v_item_total then
    raise exception 'Overall discount cannot exceed subtotal after item discounts';
  end if;

  v_expected_total := v_item_total - v_discount;

  if v_expected_total <> v_total then
    raise exception 'Sale total does not match its item totals after overall discount';
  end if;

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
  set status = 'Confirmed', updated_at = now()
  where id = p_sale_id
    and status = 'Draft';

  if not found then
    raise exception 'Sale confirmation failed';
  end if;

  return p_sale_id;
end;
$function$;

revoke all on function public.confirm_sale(uuid) from public;
grant execute on function public.confirm_sale(uuid) to authenticated;

comment on function public.confirm_sale(uuid)
is 'Atomically confirms a sale, validates line totals plus overall discount, deducts stock, writes sale inventory movements, and creates receivable/revenue ledger entries.';
