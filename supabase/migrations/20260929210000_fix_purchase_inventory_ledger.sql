-- Fix purchase accounting: record the inventory asset debit alongside purchase payable credit.
-- The repair is additive and idempotent; it does not touch inventory movements/WAC.

insert into public.account_transactions(
  organization_id, transaction_date, transaction_type, reference_type,
  reference_id, contact_id, description, debit, credit, created_by
)
select
  p.organization_id,
  now(),
  'Purchase Inventory',
  'Purchase',
  p.id,
  p.contact_id,
  'Purchase inventory - invoice ' || p.invoice_no,
  p.total,
  0,
  p.created_by
from public.purchases p
where p.status = 'Confirmed'
  and not exists (
    select 1
    from public.account_transactions at
    where at.reference_type = 'Purchase'
      and at.reference_id = p.id
      and at.transaction_type = 'Purchase Inventory'
  );

create or replace function public.confirm_purchase(p_purchase_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user_id uuid = (select auth.uid());
  v_org_id uuid;
  v_contact_id uuid;
  v_status public.invoice_status;
  v_total numeric;
  v_discount numeric;
  v_item_count int;
  v_subtotal numeric;
  v_expected_total numeric;
  r record;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select p.organization_id, p.contact_id, p.status, p.total, p.discount
    into v_org_id, v_contact_id, v_status, v_total, v_discount
  from public.purchases p
  where p.id = p_purchase_id
  for update;

  if not found then raise exception 'Purchase not found'; end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = v_org_id
      and ou.user_id = v_user_id
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  if v_status <> 'Draft' then
    raise exception 'Only Draft purchase invoices can be confirmed';
  end if;

  select count(*), coalesce(sum(pi.line_total), 0)
    into v_item_count, v_subtotal
  from public.purchase_items pi
  where pi.purchase_id = p_purchase_id
    and pi.organization_id = v_org_id;

  if v_item_count = 0 then raise exception 'A purchase must contain at least one item'; end if;

  v_discount = coalesce(v_discount, 0);
  v_expected_total = v_subtotal - v_discount;

  if v_discount < 0 or v_discount > v_subtotal or v_expected_total <> v_total then
    raise exception 'Purchase total does not match its item totals after overall discount';
  end if;

  insert into public.inventory_movements(
    organization_id, product_id, movement_direction, movement_type, reference_type,
    quantity, reference_id, unit_cost, movement_date, created_at, created_by
  )
  with x as (
    select pi.product_id, pi.quantity, pi.line_total,
           row_number() over(order by pi.product_id, pi.id) rn,
           count(*) over() cnt,
           sum(pi.line_total) over() net
    from public.purchase_items pi
    where pi.purchase_id = p_purchase_id and pi.organization_id = v_org_id
  ),
  a as (
    select x.*,
           case
             when rn = cnt then
               v_discount - coalesce((
                 select sum(round(v_discount * y.line_total / nullif(y.net, 0), 4))
                 from x y where y.rn < x.rn
               ), 0)
             else round(v_discount * x.line_total / nullif(x.net, 0), 4)
           end ad
    from x
  )
  select v_org_id, product_id, 'In', 'Purchase', 'Purchase', quantity, p_purchase_id,
         round((line_total - ad) / nullif(quantity, 0), 4), now(), now(), v_user_id
  from a;

  for r in
    select im.product_id, im.quantity, im.unit_cost
    from public.inventory_movements im
    where im.organization_id = v_org_id
      and im.reference_type = 'Purchase'
      and im.reference_id = p_purchase_id
    order by im.created_at, im.id
  loop
    perform private.wac_in(v_org_id, r.product_id, r.quantity, r.unit_cost);
  end loop;

  insert into public.account_transactions(
    organization_id, transaction_date, transaction_type, reference_type,
    reference_id, contact_id, description, debit, credit, created_by
  )
  values(
    v_org_id, now(), 'Purchase Inventory', 'Purchase', p_purchase_id, v_contact_id,
    'Purchase inventory - invoice ' ||
      (select p.invoice_no from public.purchases p where p.id = p_purchase_id),
    v_total, 0, v_user_id
  );

  insert into public.account_transactions(
    organization_id, transaction_date, transaction_type, reference_type,
    reference_id, contact_id, description, debit, credit, created_by
  )
  values(
    v_org_id, now(), 'Purchase', 'Purchase', p_purchase_id, v_contact_id,
    'Purchase payable - invoice ' ||
      (select p.invoice_no from public.purchases p where p.id = p_purchase_id),
    0, v_total, v_user_id
  );

  update public.purchases
  set status = 'Confirmed', updated_at = now()
  where id = p_purchase_id;

  return jsonb_build_object('purchase_id', p_purchase_id, 'status', 'Confirmed', 'total', v_total);
end
$function$;