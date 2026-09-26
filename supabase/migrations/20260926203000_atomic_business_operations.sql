-- Pomelo Inventory - Atomic business operations
-- RPC/service layer only. No tables are introduced or altered.
-- All lifecycle transitions and protected ledger writes are atomic.

create or replace function public.assert_organization_member(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if (select auth.uid()) is null then raise exception 'Authentication required'; end if;
  if not exists (
    select 1 from public.organization_users
    where organization_id = p_organization_id and user_id = (select auth.uid())
  ) then raise exception 'User is not a member of this organization'; end if;
end;
$$;

revoke all on function public.assert_organization_member(uuid) from public, anon, authenticated;

create or replace function public.allocate_payment(
  p_payment_id uuid,
  p_purchase_id uuid default null,
  p_sale_id uuid default null,
  p_expense_id uuid default null,
  p_allocated_amount numeric default null
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_payment public.payments%rowtype;
  v_target_contact uuid;
  v_target_total numeric(18,4);
  v_target_reserved numeric(18,4);
  v_payment_allocated numeric(18,4);
  v_id uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if p_allocated_amount is null or p_allocated_amount <= 0 then raise exception 'Allocation amount must be greater than zero'; end if;
  if num_nonnulls(p_purchase_id, p_sale_id, p_expense_id) <> 1 then raise exception 'Exactly one allocation target is required'; end if;

  select * into v_payment from public.payments where id = p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  perform public.assert_organization_member(v_payment.organization_id);
  if v_payment.status <> 'Draft' then raise exception 'Only Draft payments can be allocated'; end if;

  if p_purchase_id is not null then
    if v_payment.payment_type <> 'Out' then raise exception 'Payment Out is required for purchase allocation'; end if;
    select contact_id, total into v_target_contact, v_target_total
    from public.purchases
    where id = p_purchase_id and organization_id = v_payment.organization_id and status = 'Confirmed'
    for update;
    if not found then raise exception 'Confirmed purchase not found'; end if;
    if v_payment.contact_id is distinct from v_target_contact then raise exception 'Payment contact must match purchase contact'; end if;
    select coalesce(sum(pa.allocated_amount),0) into v_target_reserved
    from public.payment_allocations pa join public.payments p on p.id = pa.payment_id
    where pa.purchase_id = p_purchase_id and p.status <> 'Cancelled';

  elsif p_sale_id is not null then
    if v_payment.payment_type <> 'In' then raise exception 'Payment In is required for sale allocation'; end if;
    select contact_id, total into v_target_contact, v_target_total
    from public.sales
    where id = p_sale_id and organization_id = v_payment.organization_id and status = 'Confirmed'
    for update;
    if not found then raise exception 'Confirmed sale not found'; end if;
    if v_payment.contact_id is distinct from v_target_contact then raise exception 'Payment contact must match sale contact'; end if;
    select coalesce(sum(pa.allocated_amount),0) into v_target_reserved
    from public.payment_allocations pa join public.payments p on p.id = pa.payment_id
    where pa.sale_id = p_sale_id and p.status <> 'Cancelled';

  else
    if v_payment.payment_type <> 'Out' then raise exception 'Payment Out is required for expense allocation'; end if;
    select contact_id, amount into v_target_contact, v_target_total
    from public.expenses
    where id = p_expense_id and organization_id = v_payment.organization_id and status = 'Confirmed'
    for update;
    if not found then raise exception 'Confirmed expense not found'; end if;
    if v_target_contact is not null and v_payment.contact_id is distinct from v_target_contact then
      raise exception 'Payment contact must match expense contact';
    end if;
    select coalesce(sum(pa.allocated_amount),0) into v_target_reserved
    from public.payment_allocations pa join public.payments p on p.id = pa.payment_id
    where pa.expense_id = p_expense_id and p.status <> 'Cancelled';
  end if;

  if v_target_reserved + p_allocated_amount > v_target_total then raise exception 'Allocation exceeds target outstanding balance'; end if;

  select coalesce(sum(allocated_amount),0) into v_payment_allocated
  from public.payment_allocations where payment_id = p_payment_id;
  if v_payment_allocated + p_allocated_amount > v_payment.amount then raise exception 'Allocations exceed payment amount'; end if;

  insert into public.payment_allocations(
    organization_id, payment_id, purchase_id, sale_id, expense_id, allocated_amount, created_by
  ) values (
    v_payment.organization_id, p_payment_id, p_purchase_id, p_sale_id, p_expense_id, p_allocated_amount, v_uid
  ) returning id into v_id;

  return v_id;
end;
$$;

create or replace function public.remove_payment_allocation(p_allocation_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_org_id uuid; v_status public.payment_status;
begin
  select pa.organization_id, p.status into v_org_id, v_status
  from public.payment_allocations pa join public.payments p on p.id = pa.payment_id
  where pa.id = p_allocation_id for update of p;
  if not found then raise exception 'Payment allocation not found'; end if;
  perform public.assert_organization_member(v_org_id);
  if v_status <> 'Draft' then raise exception 'Only Draft payment allocations can be removed'; end if;
  delete from public.payment_allocations where id = p_allocation_id;
end;
$$;

create or replace function public.confirm_purchase(p_purchase_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v public.purchases%rowtype; r record; v_sum numeric(18,4);
begin
  select * into v from public.purchases where id = p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  perform public.assert_organization_member(v.organization_id);
  if v.status <> 'Draft' then raise exception 'Only Draft purchases can be confirmed'; end if;
  select coalesce(sum(line_total),0) into v_sum from public.purchase_items where purchase_id=p_purchase_id and organization_id=v.organization_id;
  if not exists (select 1 from public.purchase_items where purchase_id=p_purchase_id and organization_id=v.organization_id) then raise exception 'Purchase must contain at least one item'; end if;
  if v_sum <> v.total then raise exception 'Purchase total does not match item totals'; end if;
  if v.total <= 0 then raise exception 'Purchase total must be greater than zero'; end if;

  for r in select product_id, quantity, unit_price from public.purchase_items where purchase_id=p_purchase_id order by id loop
    insert into public.stock(organization_id,product_id,quantity) values(v.organization_id,r.product_id,r.quantity)
    on conflict (organization_id,product_id) do update set quantity=public.stock.quantity+excluded.quantity,updated_at=now();
    insert into public.inventory_movements(organization_id,product_id,movement_direction,movement_type,quantity,reference_type,reference_id,unit_cost,created_by)
    values(v.organization_id,r.product_id,'In','Purchase',r.quantity,'purchase',p_purchase_id,r.unit_price,(select auth.uid()));
  end loop;

  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by)
  values(v.organization_id,now(),'Purchase','purchase',p_purchase_id,v.contact_id,'Purchase confirmed '||v.invoice_no,0,v.total,(select auth.uid()));
  update public.purchases set status='Confirmed',updated_at=now() where id=p_purchase_id;
end;
$$;

create or replace function public.cancel_purchase(p_purchase_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v public.purchases%rowtype; r record; v_paid numeric(18,4);
begin
  select * into v from public.purchases where id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  perform public.assert_organization_member(v.organization_id);
  if v.status <> 'Confirmed' then raise exception 'Only Confirmed purchases can be cancelled'; end if;
  select coalesce(sum(pa.allocated_amount),0) into v_paid from public.payment_allocations pa join public.payments p on p.id=pa.payment_id
  where pa.purchase_id=p_purchase_id and p.status<>'Cancelled';
  if v_paid>0 then raise exception 'Cancel active payments before cancelling this purchase'; end if;

  for r in select product_id,quantity,unit_price from public.purchase_items where purchase_id=p_purchase_id order by id loop
    update public.stock set quantity=quantity-r.quantity,updated_at=now()
    where organization_id=v.organization_id and product_id=r.product_id and quantity>=r.quantity;
    if not found then raise exception 'Cannot reverse purchase: insufficient stock for product %',r.product_id; end if;
    insert into public.inventory_movements(organization_id,product_id,movement_direction,movement_type,quantity,reference_type,reference_id,unit_cost,created_by)
    values(v.organization_id,r.product_id,'Out','Return',r.quantity,'purchase_cancel',p_purchase_id,r.unit_price,(select auth.uid()));
  end loop;

  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by)
  values(v.organization_id,now(),'Purchase Reversal','purchase',p_purchase_id,v.contact_id,'Purchase cancelled '||v.invoice_no,v.total,0,(select auth.uid()));
  update public.purchases set status='Cancelled',updated_at=now() where id=p_purchase_id;
end;
$$;

create or replace function public.confirm_sale(p_sale_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v public.sales%rowtype; r record; v_sum numeric(18,4);
begin
  select * into v from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Sale not found'; end if;
  perform public.assert_organization_member(v.organization_id);
  if v.status <> 'Draft' then raise exception 'Only Draft sales can be confirmed'; end if;
  select coalesce(sum(line_total),0) into v_sum from public.sale_items where sale_id=p_sale_id and organization_id=v.organization_id;
  if not exists (select 1 from public.sale_items where sale_id=p_sale_id and organization_id=v.organization_id) then raise exception 'Sale must contain at least one item'; end if;
  if v_sum <> v.total then raise exception 'Sale total does not match item totals'; end if;
  if v.total <= 0 then raise exception 'Sale total must be greater than zero'; end if;

  for r in select product_id,quantity,unit_price from public.sale_items where sale_id=p_sale_id order by id loop
    update public.stock set quantity=quantity-r.quantity,updated_at=now()
    where organization_id=v.organization_id and product_id=r.product_id and quantity>=r.quantity;
    if not found then raise exception 'Insufficient stock for product %',r.product_id; end if;
    insert into public.inventory_movements(organization_id,product_id,movement_direction,movement_type,quantity,reference_type,reference_id,unit_cost,created_by)
    values(v.organization_id,r.product_id,'Out','Sale',r.quantity,'sale',p_sale_id,r.unit_price,(select auth.uid()));
  end loop;

  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by)
  values(v.organization_id,now(),'Sale','sale',p_sale_id,v.contact_id,'Sale confirmed '||v.invoice_no,v.total,0,(select auth.uid()));
  update public.sales set status='Confirmed',updated_at=now() where id=p_sale_id;
end;
$$;

create or replace function public.cancel_sale(p_sale_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v public.sales%rowtype; r record; v_paid numeric(18,4);
begin
  select * into v from public.sales where id=p_sale_id for update;
  if not found then raise exception 'Sale not found'; end if;
  perform public.assert_organization_member(v.organization_id);
  if v.status <> 'Confirmed' then raise exception 'Only Confirmed sales can be cancelled'; end if;
  select coalesce(sum(pa.allocated_amount),0) into v_paid from public.payment_allocations pa join public.payments p on p.id=pa.payment_id
  where pa.sale_id=p_sale_id and p.status<>'Cancelled';
  if v_paid>0 then raise exception 'Cancel active payments before cancelling this sale'; end if;

  for r in select product_id,quantity,unit_price from public.sale_items where sale_id=p_sale_id order by id loop
    insert into public.stock(organization_id,product_id,quantity) values(v.organization_id,r.product_id,r.quantity)
    on conflict (organization_id,product_id) do update set quantity=public.stock.quantity+excluded.quantity,updated_at=now();
    insert into public.inventory_movements(organization_id,product_id,movement_direction,movement_type,quantity,reference_type,reference_id,unit_cost,created_by)
    values(v.organization_id,r.product_id,'In','Return',r.quantity,'sale_cancel',p_sale_id,r.unit_price,(select auth.uid()));
  end loop;

  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by)
  values(v.organization_id,now(),'Sale Reversal','sale',p_sale_id,v.contact_id,'Sale cancelled '||v.invoice_no,0,v.total,(select auth.uid()));
  update public.sales set status='Cancelled',updated_at=now() where id=p_sale_id;
end;
$$;

create or replace function public.confirm_expense(p_expense_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v public.expenses%rowtype;
begin
  select * into v from public.expenses where id=p_expense_id for update;
  if not found then raise exception 'Expense not found'; end if;
  perform public.assert_organization_member(v.organization_id);
  if v.status<>'Draft' then raise exception 'Only Draft expenses can be confirmed'; end if;
  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by)
  values(v.organization_id,now(),'Expense','expense',p_expense_id,v.contact_id,'Expense confirmed '||v.expense_no,v.amount,0,(select auth.uid()));
  update public.expenses set status='Confirmed',updated_at=now() where id=p_expense_id;
end;
$$;

create or replace function public.cancel_expense(p_expense_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v public.expenses%rowtype; v_paid numeric(18,4);
begin
  select * into v from public.expenses where id=p_expense_id for update;
  if not found then raise exception 'Expense not found'; end if;
  perform public.assert_organization_member(v.organization_id);
  if v.status<>'Confirmed' then raise exception 'Only Confirmed expenses can be cancelled'; end if;
  select coalesce(sum(pa.allocated_amount),0) into v_paid from public.payment_allocations pa join public.payments p on p.id=pa.payment_id
  where pa.expense_id=p_expense_id and p.status<>'Cancelled';
  if v_paid>0 then raise exception 'Cancel active payments before cancelling this expense'; end if;
  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by)
  values(v.organization_id,now(),'Expense Reversal','expense',p_expense_id,v.contact_id,'Expense cancelled '||v.expense_no,0,v.amount,(select auth.uid()));
  update public.expenses set status='Cancelled',updated_at=now() where id=p_expense_id;
end;
$$;

create or replace function public.confirm_payment(p_payment_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  v public.payments%rowtype; v_allocated numeric(18,4); r record; v_status text;
begin
  select * into v from public.payments where id=p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  perform public.assert_organization_member(v.organization_id);
  if v.status<>'Draft' then raise exception 'Only Draft payments can be confirmed'; end if;
  select coalesce(sum(allocated_amount),0) into v_allocated from public.payment_allocations where payment_id=p_payment_id;
  if v_allocated<>v.amount then raise exception 'Payment must be fully allocated before confirmation'; end if;

  for r in
    select pa.*, pu.contact_id purchase_contact, sa.contact_id sale_contact, ex.contact_id expense_contact
    from public.payment_allocations pa
    left join public.purchases pu on pu.id=pa.purchase_id
    left join public.sales sa on sa.id=pa.sale_id
    left join public.expenses ex on ex.id=pa.expense_id
    where pa.payment_id=p_payment_id order by pa.id
  loop
    if r.purchase_id is not null then
      if v.payment_type<>'Out' or r.purchase_contact is distinct from v.contact_id then raise exception 'Invalid purchase payment allocation'; end if;
      select status::text into v_status from public.purchases where id=r.purchase_id;
    elsif r.sale_id is not null then
      if v.payment_type<>'In' or r.sale_contact is distinct from v.contact_id then raise exception 'Invalid sale payment allocation'; end if;
      select status::text into v_status from public.sales where id=r.sale_id;
    else
      if v.payment_type<>'Out' then raise exception 'Invalid expense payment allocation'; end if;
      select status::text into v_status from public.expenses where id=r.expense_id;
      if r.expense_contact is not null and r.expense_contact is distinct from v.contact_id then raise exception 'Invalid expense payment contact'; end if;
    end if;
    if v_status<>'Confirmed' then raise exception 'All payment targets must remain Confirmed'; end if;
  end loop;

  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by)
  values(
    v.organization_id,now(),case when v.payment_type='In' then 'Payment In' else 'Payment Out' end,
    'payment',p_payment_id,v.contact_id,
    case when v.payment_type='In' then 'Payment received ' else 'Payment made ' end||v.payment_no,
    case when v.payment_type='Out' then v.amount else 0 end,
    case when v.payment_type='In' then v.amount else 0 end,
    (select auth.uid())
  );
  update public.payments set status='Confirmed',updated_at=now() where id=p_payment_id;
end;
$$;

create or replace function public.cancel_payment(p_payment_id uuid)
returns void
language plpgsql security definer set search_path = public, pg_temp
as $$
declare v public.payments%rowtype;
begin
  select * into v from public.payments where id=p_payment_id for update;
  if not found then raise exception 'Payment not found'; end if;
  perform public.assert_organization_member(v.organization_id);
  if v.status<>'Confirmed' then raise exception 'Only Confirmed payments can be cancelled'; end if;
  insert into public.account_transactions(organization_id,transaction_date,transaction_type,reference_type,reference_id,contact_id,description,debit,credit,created_by)
  values(
    v.organization_id,now(),case when v.payment_type='In' then 'Payment In Reversal' else 'Payment Out Reversal' end,
    'payment',p_payment_id,v.contact_id,'Payment cancelled '||v.payment_no,
    case when v.payment_type='In' then v.amount else 0 end,
    case when v.payment_type='Out' then v.amount else 0 end,
    (select auth.uid())
  );
  update public.payments set status='Cancelled',updated_at=now() where id=p_payment_id;
end;
$$;

revoke all on function public.allocate_payment(uuid,uuid,uuid,uuid,numeric) from public, anon;
revoke all on function public.remove_payment_allocation(uuid) from public, anon;
revoke all on function public.confirm_purchase(uuid) from public, anon;
revoke all on function public.cancel_purchase(uuid) from public, anon;
revoke all on function public.confirm_sale(uuid) from public, anon;
revoke all on function public.cancel_sale(uuid) from public, anon;
revoke all on function public.confirm_expense(uuid) from public, anon;
revoke all on function public.cancel_expense(uuid) from public, anon;
revoke all on function public.confirm_payment(uuid) from public, anon;
revoke all on function public.cancel_payment(uuid) from public, anon;

grant execute on function public.allocate_payment(uuid,uuid,uuid,uuid,numeric) to authenticated, service_role;
grant execute on function public.remove_payment_allocation(uuid) to authenticated, service_role;
grant execute on function public.confirm_purchase(uuid) to authenticated, service_role;
grant execute on function public.cancel_purchase(uuid) to authenticated, service_role;
grant execute on function public.confirm_sale(uuid) to authenticated, service_role;
grant execute on function public.cancel_sale(uuid) to authenticated, service_role;
grant execute on function public.confirm_expense(uuid) to authenticated, service_role;
grant execute on function public.cancel_expense(uuid) to authenticated, service_role;
grant execute on function public.confirm_payment(uuid) to authenticated, service_role;
grant execute on function public.cancel_payment(uuid) to authenticated, service_role;

comment on function public.allocate_payment(uuid,uuid,uuid,uuid,numeric) is 'Atomically allocates a Draft payment to one Confirmed purchase, sale, or expense without exceeding payment or target outstanding balance.';
comment on function public.remove_payment_allocation(uuid) is 'Removes a payment allocation only while the payment is Draft.';
comment on function public.confirm_purchase(uuid) is 'Atomically confirms purchase, increases stock, writes inventory and payable ledger effects, and changes status to Confirmed.';
comment on function public.cancel_purchase(uuid) is 'Atomically cancels purchase by reversing stock and payable ledger effects; active payments must be cancelled first.';
comment on function public.confirm_sale(uuid) is 'Atomically confirms sale, decrements stock without allowing negative balance, writes inventory and receivable ledger effects, and changes status to Confirmed.';
comment on function public.cancel_sale(uuid) is 'Atomically cancels sale by reversing stock and receivable ledger effects; active payments must be cancelled first.';
comment on function public.confirm_expense(uuid) is 'Atomically confirms an expense and writes its financial ledger effect.';
comment on function public.cancel_expense(uuid) is 'Atomically cancels an expense by writing a reversing financial ledger effect; active payments must be cancelled first.';
comment on function public.confirm_payment(uuid) is 'Atomically confirms a fully allocated payment after revalidating target status, type, contact, and allocation total.';
comment on function public.cancel_payment(uuid) is 'Atomically cancels a confirmed payment by writing the exact financial reversal; historical allocations remain and cancelled payments no longer count toward outstanding balances.';
