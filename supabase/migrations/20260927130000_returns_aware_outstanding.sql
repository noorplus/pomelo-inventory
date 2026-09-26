-- Pomelo Inventory - Returns-aware outstanding balances
-- Repository migration only. Do NOT apply to Supabase unless explicitly requested.
--
-- The 20260927110000 returns feature posts proportional reversal entries that
-- shrink the true payable/receivable, but outstanding was derived as
-- (confirmed total - confirmed allocations) only. From here outstanding means
-- NET: total - confirmed allocations - posted return reversals (floored at 0).
-- The confirm_payment over-allocation guard uses the same net figure, so a
-- returned invoice can never be over-paid afterwards.
-- Redefines confirm_payment(uuid, jsonb), purchase_outstanding(uuid) and
-- sale_outstanding(uuid) with minimal guard changes; all other logic is
-- byte-identical to the canonical 20260926230000 definitions. No new tables.

drop function if exists public.confirm_payment(uuid, jsonb);
drop function if exists public.purchase_outstanding(uuid);
drop function if exists public.sale_outstanding(uuid);

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
  v_returned numeric(18,4) := 0;
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

      select coalesce(sum(credit), 0)
        into v_returned
      from public.account_transactions
      where organization_id = v_org
        and reference_type = 'Sale'
        and reference_id = a.sale_id
        and transaction_type like 'Sale Return%';

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

      select coalesce(sum(debit), 0)
        into v_returned
      from public.account_transactions
      where organization_id = v_org
        and reference_type = 'Purchase'
        and reference_id = a.purchase_id
        and transaction_type like 'Purchase Return%';

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

    v_outstanding := greatest(v_target_total - v_paid - coalesce(v_returned, 0), 0);

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
  v_returned numeric(18,4) := 0;
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

  select coalesce(sum(debit), 0)
    into v_returned
  from public.account_transactions
  where organization_id = v_org
    and reference_type = 'Purchase'
    and reference_id = p_purchase_id
    and transaction_type like 'Purchase Return%';

  return greatest(v_total - v_paid - coalesce(v_returned, 0), 0);
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
  v_returned numeric(18,4) := 0;
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

  select coalesce(sum(credit), 0)
    into v_returned
  from public.account_transactions
  where organization_id = v_org
    and reference_type = 'Sale'
    and reference_id = p_sale_id
    and transaction_type like 'Sale Return%';

  return greatest(v_total - v_paid - coalesce(v_returned, 0), 0);
end;
$func$;

revoke all on function public.confirm_payment(uuid, jsonb) from public;
revoke all on function public.purchase_outstanding(uuid) from public;
revoke all on function public.sale_outstanding(uuid) from public;
grant execute on function public.confirm_payment(uuid, jsonb) to authenticated;
grant execute on function public.purchase_outstanding(uuid) to authenticated;
grant execute on function public.sale_outstanding(uuid) to authenticated;

comment on function public.confirm_payment(uuid, jsonb) is 'Atomically confirms a Draft payment with validated full-amount allocations and accounting entries. Allocation room is net of posted return reversals.';
comment on function public.purchase_outstanding(uuid) is 'Returns net balance due for a Confirmed purchase: total - confirmed allocations - posted return reversals.';
comment on function public.sale_outstanding(uuid) is 'Returns net balance due for a Confirmed sale: total - confirmed allocations - posted return reversals.';
