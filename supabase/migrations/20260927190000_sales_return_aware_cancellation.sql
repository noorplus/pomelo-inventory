-- Sales cancellation is return-aware.
-- No new tables. Cancellation restores only unreturned stock and reverses
-- only the remaining accounting amount after recorded sale returns.

create or replace function public.cancel_sale(p_sale_id uuid)
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
  v_contact uuid;
  v_invoice_no text;
  v_returned_amount numeric(18,4) := 0;
  v_remaining_amount numeric(18,4) := 0;
  r record;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;

  select organization_id, status, total, contact_id, invoice_no
    into v_org, v_status, v_total, v_contact, v_invoice_no
  from public.sales
  where id = p_sale_id
  for update;

  if not found then raise exception 'Sale not found'; end if;
  perform public.rpc_assert_member(v_org);

  if v_status <> 'Confirmed' then
    raise exception 'Only Confirmed sales can be cancelled';
  end if;

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
      and transaction_type in ('Sale Revenue', 'Sale Receivable')
  ) <> 2
  or (
    select count(*)
    from public.account_transactions
    where organization_id = v_org
      and reference_type = 'Sale'
      and reference_id = p_sale_id
      and transaction_type = 'Sale Revenue'
  ) <> 1
  or (
    select count(*)
    from public.account_transactions
    where organization_id = v_org
      and reference_type = 'Sale'
      and reference_id = p_sale_id
      and transaction_type = 'Sale Receivable'
  ) <> 1
  then
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

  select coalesce(sum(case when transaction_type = 'Sale Return - Revenue' then debit else 0 end), 0)
  into v_returned_amount
  from public.account_transactions
  where organization_id = v_org
    and reference_type = 'Sale'
    and reference_id = p_sale_id;

  if v_returned_amount < 0 or v_returned_amount > v_total then
    raise exception 'Sale return accounting exceeds the original sale amount';
  end if;

  if exists (
    select 1
    from public.account_transactions
    where organization_id = v_org
      and reference_type = 'Sale'
      and reference_id = p_sale_id
      and transaction_type = 'Sale Return - Revenue'
    group by reference_id
    having sum(debit) <> sum(credit)
  ) then
    raise exception 'Sale return accounting ledger is unbalanced';
  end if;

  if exists (
    select 1
    from (
      select product_id, sum(quantity) as quantity
      from public.inventory_movements
      where organization_id = v_org
        and reference_type = 'Sale'
        and reference_id = p_sale_id
        and movement_direction = 'In'
        and movement_type = 'Return'
      group by product_id
    ) r
    full join (
      select product_id, sum(quantity) as quantity
      from public.sale_items
      where sale_id = p_sale_id and organization_id = v_org
      group by product_id
    ) i using (product_id)
    where coalesce(r.quantity, 0) > coalesce(i.quantity, 0)
  ) then
    raise exception 'Sale return inventory exceeds the original sold quantity';
  end if;

  for r in
    select
      i.product_id,
      greatest(
        sum(i.quantity) - coalesce((
          select sum(m.quantity)
          from public.inventory_movements m
          where m.organization_id = v_org
            and m.reference_type = 'Sale'
            and m.reference_id = p_sale_id
            and m.product_id = i.product_id
            and m.movement_direction = 'In'
            and m.movement_type = 'Return'
        ), 0),
        0
      ) as quantity
    from public.sale_items i
    where i.sale_id = p_sale_id
      and i.organization_id = v_org
    group by i.product_id
    having greatest(
      sum(i.quantity) - coalesce((
        select sum(m.quantity)
        from public.inventory_movements m
        where m.organization_id = v_org
          and m.reference_type = 'Sale'
          and m.reference_id = p_sale_id
          and m.product_id = i.product_id
          and m.movement_direction = 'In'
          and m.movement_type = 'Return'
      ), 0),
      0
    ) > 0
  loop
    insert into public.inventory_movements (
      organization_id, product_id, movement_direction, movement_type,
      quantity, reference_type, reference_id, unit_cost, movement_date, created_by
    )
    values (
      v_org, r.product_id, 'In', 'Return',
      r.quantity, 'Sale', p_sale_id, null, now(), v_user
    );

    insert into public.stock (organization_id, product_id, quantity)
    values (v_org, r.product_id, r.quantity)
    on conflict (organization_id, product_id)
    do update set quantity = public.stock.quantity + excluded.quantity,
                  updated_at = now();
  end loop;

  v_remaining_amount := greatest(v_total - v_returned_amount, 0);

  if v_remaining_amount > 0 then
    insert into public.account_transactions (
      organization_id, transaction_date, transaction_type,
      reference_type, reference_id, contact_id, description,
      debit, credit, created_by
    )
    values
      (v_org, now(), 'Sale Revenue Reversal',
       'Sale', p_sale_id, v_contact,
       'Reversal of remaining sale revenue - ' || v_invoice_no,
       v_remaining_amount, 0, v_user),
      (v_org, now(), 'Sale Receivable Reversal',
       'Sale', p_sale_id, v_contact,
       'Reversal of remaining sale receivable - ' || v_invoice_no,
       0, v_remaining_amount, v_user);
  end if;

  update public.sales
  set status = 'Cancelled',
      updated_at = now()
  where id = p_sale_id
    and status = 'Confirmed';

  if not found then raise exception 'Sale cancellation failed'; end if;
  return p_sale_id;
end;
$function$;

revoke all on function public.cancel_sale(uuid) from public;
revoke all on function public.cancel_sale(uuid) from anon;
grant execute on function public.cancel_sale(uuid) to authenticated;
