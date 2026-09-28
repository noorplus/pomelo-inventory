-- Reconcile historical purchase inventory movement costs with the two-level
-- discount model. This updates only inbound Purchase movements; no quantities
-- or accounting entries are changed.
with ordered as (
  select
    im.id as movement_id,
    pi.line_total,
    pi.quantity,
    row_number() over (partition by p.id order by pi.product_id) as rn,
    count(*) over (partition by p.id) as row_count,
    sum(pi.line_total) over (partition by p.id) as net_total,
    (sum(pi.line_total) over (partition by p.id) - p.total) as overall_discount
  from public.inventory_movements im
  join public.purchases p
    on p.id = im.reference_id
   and p.status = 'Confirmed'
  join public.purchase_items pi
    on pi.purchase_id = p.id
   and pi.product_id = im.product_id
  where im.reference_type = 'purchase'
    and im.movement_type = 'Purchase'
    and im.movement_direction = 'In'
),
allocated as (
  select
    o.*,
    case
      when o.overall_discount <= 0 then 0
      when o.rn = o.row_count then
        o.overall_discount - coalesce(
          (
            select sum(round(o.overall_discount * o2.line_total / nullif(o2.net_total, 0), 4))
            from ordered o2
            where o2.movement_id = o.movement_id
              and o2.rn < o.rn
          ),
          0
        )
      else round(o.overall_discount * o.line_total / nullif(o.net_total, 0), 4)
    end as allocated_discount
  from ordered o
)
update public.inventory_movements im
set unit_cost = round((a.line_total - a.allocated_discount) / nullif(a.quantity, 0), 4)
from allocated a
where im.id = a.movement_id;
