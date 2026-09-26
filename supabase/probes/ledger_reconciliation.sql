-- Pomelo Inventory - Ledger reconciliation (READ-ONLY).
-- Run in the Supabase SQL editor. Every query below returns VIOLATIONS only:
-- an empty result means that check is healthy. Any row back is a real
-- mismatch to investigate before month-end close.
-- Scope: set these two GUCs (or replace :org with a literal uuid).
--   set app.current_org = '<organization-uuid>';

-- R1. Negative stock balances (must never happen).
select organization_id, product_id, quantity
from public.stock
where quantity < 0;

-- R2. Stock balance vs movement ledger mismatch.
-- Current stock must equal opening/adjustment-corrected In minus Out.
select
  s.organization_id,
  s.product_id,
  s.quantity as stock_quantity,
  coalesce(m.in_qty, 0) - coalesce(m.out_qty, 0) as ledger_quantity
from public.stock s
full join (
  select
    organization_id,
    product_id,
    sum(case when movement_direction = 'In' then quantity else 0 end) as in_qty,
    sum(case when movement_direction = 'Out' then quantity else 0 end) as out_qty
  from public.inventory_movements
  group by organization_id, product_id
) m using (organization_id, product_id)
where coalesce(s.quantity, 0) <> coalesce(m.in_qty, 0) - coalesce(m.out_qty, 0);

-- R3. Purchase header totals vs item totals.
select p.id, p.invoice_no, p.status, p.total as header_total, coalesce(i.item_total, 0) as item_total
from public.purchases p
left join (
  select purchase_id, sum(line_total) as item_total
  from public.purchase_items
  group by purchase_id
) i on i.purchase_id = p.id
where p.total <> coalesce(i.item_total, 0);

-- R4. Sale header totals vs item totals.
select s.id, s.invoice_no, s.status, s.total as header_total, coalesce(i.item_total, 0) as item_total
from public.sales s
left join (
  select sale_id, sum(line_total) as item_total
  from public.sale_items
  group by sale_id
) i on i.sale_id = s.id
where s.total <> coalesce(i.item_total, 0);

-- R5. Line-total formula violations (line_total must equal qty*price-discount+tax).
select 'purchase_item' as source, id, purchase_id as parent_id, line_total,
       quantity * unit_price - discount + tax as expected_total
from public.purchase_items
where line_total <> quantity * unit_price - discount + tax
union all
select 'sale_item' as source, id, sale_id as parent_id, line_total,
       quantity * unit_price - discount + tax as expected_total
from public.sale_items
where line_total <> quantity * unit_price - discount + tax;

-- R6. Double-entry imbalance per reference (every operation posts pairs,
-- so debits must equal credits for each referenced document/payment).
select reference_type, reference_id,
       count(*) as entries,
       sum(debit) as total_debit,
       sum(credit) as total_credit
from public.account_transactions
where reference_type is not null
group by reference_type, reference_id
having sum(debit) <> sum(credit);

-- R7. Odd ledger entry counts per reference (all postings are pairs).
select reference_type, reference_id, count(*) as entries
from public.account_transactions
where reference_type is not null
group by reference_type, reference_id
having count(*) % 2 = 1;

-- R8. Confirmed payments whose allocations do not equal the payment amount.
select p.id, p.payment_no, p.amount as payment_amount, coalesce(a.allocated, 0) as allocated
from public.payments p
left join (
  select payment_id, sum(allocated_amount) as allocated
  from public.payment_allocations
  group by payment_id
) a on a.payment_id = p.id
where p.status = 'Confirmed'
  and coalesce(a.allocated, 0) <> p.amount;

-- R9. Over-allocated targets (net of posted return reversals).
-- Purchases.
select p.id, p.invoice_no,
       p.total - coalesce(a.paid, 0) - coalesce(r.ret, 0) as net_outstanding
from public.purchases p
left join (
  select pa.purchase_id, sum(pa.allocated_amount) as paid
  from public.payment_allocations pa
  join public.payments py on py.id = pa.payment_id
  where py.status = 'Confirmed'
  group by pa.purchase_id
) a on a.purchase_id = p.id
left join (
  select reference_id, sum(debit) as ret
  from public.account_transactions
  where reference_type = 'Purchase' and transaction_type like 'Purchase Return%'
  group by reference_id
) r on r.reference_id = p.id
where p.status = 'Confirmed'
  and p.total - coalesce(a.paid, 0) - coalesce(r.ret, 0) < 0;
-- Sales.
select s.id, s.invoice_no,
       s.total - coalesce(a.paid, 0) - coalesce(r.ret, 0) as net_outstanding
from public.sales s
left join (
  select pa.sale_id, sum(pa.allocated_amount) as paid
  from public.payment_allocations pa
  join public.payments py on py.id = pa.payment_id
  where py.status = 'Confirmed'
  group by pa.sale_id
) a on a.sale_id = s.id
left join (
  select reference_id, sum(credit) as ret
  from public.account_transactions
  where reference_type = 'Sale' and transaction_type like 'Sale Return%'
  group by reference_id
) r on r.reference_id = s.id
where s.status = 'Confirmed'
  and s.total - coalesce(a.paid, 0) - coalesce(r.ret, 0) < 0;
-- Expenses.
select e.id, e.expense_no,
       e.amount - coalesce(a.paid, 0) as net_outstanding
from public.expenses e
left join (
  select pa.expense_id, sum(pa.allocated_amount) as paid
  from public.payment_allocations pa
  join public.payments py on py.id = pa.payment_id
  where py.status = 'Confirmed'
  group by pa.expense_id
) a on a.expense_id = e.id
where e.status = 'Confirmed'
  and e.amount - coalesce(a.paid, 0) < 0;

-- R10. Allocations pointing at cancelled documents (cancellation must be
-- blocked while confirmed allocations exist, so these must not occur).
select pa.id, pa.payment_id, pa.purchase_id, pa.sale_id, pa.expense_id, py.status as payment_status
from public.payment_allocations pa
join public.payments py on py.id = pa.payment_id
left join public.purchases p on p.id = pa.purchase_id
left join public.sales s on s.id = pa.sale_id
left join public.expenses e on e.id = pa.expense_id
where coalesce(p.status, s.status, e.status) = 'Cancelled'
  and py.status = 'Confirmed';
