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
  u uuid = (select auth.uid());
  o uuid;
  contact uuid;
  st public.invoice_status;
  total numeric;
  disc numeric;
  n int;
  sub numeric;
  exp numeric;
  r record;
begin
  if u is null then raise exception 'Authentication required'; end if;

  select organization_id, contact_id, status, total, discount
    into o, contact, st, total, disc
  from public.purchases
  where id = p_purchase_id
  for update;

  if not found then raise exception 'Purchase not found'; end if;

  if not exists (
    select 1
    from public.organization_users
    where organization_id = o
      and user_id = u
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  if st <> 'Draft' then
    raise exception 'Only Draft purchase invoices can be confirmed';
  end if;

  select count(*), coalesce(sum(line_total), 0)
    into n, sub
  from public.purchase_items
  where purchase_id = p_purchase_id
    and organization_id = o;

  if n = 0 then raise exception 'A purchase must contain at least one item'; end if;

  disc = coalesce(disc, 0);
  exp = sub - disc;

  if disc < 0 or disc > sub or exp <> total then
    raise exception 'Purchase total does not match its item totals after overall discount';
  end if;

  insert into public.inventory_movements(
    organization_id, product_id, movement_type, reference_type,
    quantity, reference_id, unit_cost, created_at, created_by
  )
  with x as (
    select
      pi.product_id,
      pi.quantity,
      pi.line_total,
      row_number() over(order by pi.product_id, pi.id) rn,
      count(*) over() cnt,
      sum(pi.line_total) over() net
    from public.purchase_items pi
    where pi.purchase_id = p_purchase_id
      and pi.organization_id = o
  ),
  a as (
    select
      x.*,
      case
        when rn = cnt then
          disc - coalesce((
            select sum(round(disc * y.line_total / nullif(y.net, 0), 4))
            from x y
            where y.rn < x.rn
          ), 0)
        else round(disc * x.line_total / nullif(x.net, 0), 4)
      end ad
    from x
  )
  select
    o,
    product_id,
    'Purchase',
    'Purchase',
    quantity,
    p_purchase_id,
    round((line_total - ad) / nullif(quantity, 0), 4),
    now(),
    u
  from a;

  for r in
    select product_id, quantity, unit_cost
    from public.inventory_movements
    where organization_id = o
      and reference_type = 'Purchase'
      and reference_id = p_purchase_id
    order by created_at, id
  loop
    perform private.wac_in(o, r.product_id, r.quantity, r.unit_cost);
  end loop;

  -- Inventory asset debit: this was previously missing.
  insert into public.account_transactions(
    organization_id, transaction_date, transaction_type, reference_type,
    reference_id, contact_id, description, debit, credit, created_by
  )
  values(
    o,
    now(),
    'Purchase Inventory',
    'Purchase',
    p_purchase_id,
    contact,
    'Purchase inventory - invoice ' ||
      (select invoice_no from public.purchases where id = p_purchase_id),
    total,
    0,
    u
  );

  -- Purchase payable credit.
  insert into public.account_transactions(
    organization_id, transaction_date, transaction_type, reference_type,
    reference_id, contact_id, description, debit, credit, created_by
  )
  values(
    o,
    now(),
    'Purchase',
    'Purchase',
    p_purchase_id,
    contact,
    'Purchase payable - invoice ' ||
      (select invoice_no from public.purchases where id = p_purchase_id),
    0,
    total,
    u
  );

  update public.purchases
  set status = 'Confirmed',
      updated_at = now()
  where id = p_purchase_id;

  return jsonb_build_object(
    'purchase_id', p_purchase_id,
    'status', 'Confirmed',
    'total', total
  );
end
$function$;
