begin;

create or replace function public.confirm_purchase(p_purchase_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_user uuid=(select auth.uid());
  v_org uuid;
  v_contact uuid;
  v_status public.invoice_status;
  v_total numeric;
  v_discount numeric;
  v_item_total numeric;
  v_expected_total numeric;
  v_item_count int;
  r record;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select p.organization_id,p.contact_id,p.status,p.total,p.discount
    into v_org,v_contact,v_status,v_total,v_discount
  from public.purchases p
  where p.id=p_purchase_id
  for update;

  if not found then raise exception 'Purchase not found'; end if;

  if not exists(
    select 1 from public.organization_users ou
    where ou.organization_id=v_org and ou.user_id=v_user
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  if v_status<>'Draft' then
    raise exception 'Only Draft purchase invoices can be confirmed';
  end if;

  select count(*),coalesce(sum(pi.line_total),0)
    into v_item_count,v_item_total
  from public.purchase_items pi
  where pi.purchase_id=p_purchase_id and pi.organization_id=v_org;

  if v_item_count=0 then raise exception 'A purchase must contain at least one item'; end if;

  v_discount=coalesce(v_discount,0);
  v_expected_total=v_item_total-v_discount;

  if v_discount<0 or v_discount>v_item_total or v_expected_total<>v_total then
    raise exception 'Purchase total does not match its item totals after overall discount';
  end if;

  if exists(
    select 1 from public.inventory_movements im
    where im.organization_id=v_org
      and im.reference_type='Purchase'
      and im.reference_id=p_purchase_id
  ) or exists(
    select 1 from public.account_transactions at
    where at.organization_id=v_org
      and at.reference_type='Purchase'
      and at.reference_id=p_purchase_id
  ) then
    raise exception 'Purchase already has ledger effects';
  end if;

  insert into public.inventory_movements(
    organization_id,product_id,movement_direction,movement_type,quantity,
    reference_type,reference_id,unit_cost,movement_date,created_by
  )
  with x as(
    select pi.product_id,pi.quantity,pi.line_total,
           row_number() over(order by pi.product_id,pi.id) rn,
           count(*) over() cnt,
           sum(pi.line_total) over() net
    from public.purchase_items pi
    where pi.purchase_id=p_purchase_id and pi.organization_id=v_org
  ),
  a as(
    select x.*,
      case
        when rn=cnt then v_discount-coalesce(
          (select sum(round(v_discount*y.line_total/nullif(y.net,0),4))
           from x y where y.rn<x.rn),0)
        else round(v_discount*x.line_total/nullif(x.net,0),4)
      end allocated_discount
    from x
  )
  select v_org,product_id,'In','Purchase',quantity,'Purchase',p_purchase_id,
         round((line_total-allocated_discount)/nullif(quantity,0),4),
         now(),v_user
  from a;

  for r in
    select im.product_id,im.quantity,im.unit_cost
    from public.inventory_movements im
    where im.organization_id=v_org
      and im.reference_type='Purchase'
      and im.reference_id=p_purchase_id
    order by im.created_at,im.id
  loop
    perform private.wac_in(v_org,r.product_id,r.quantity,r.unit_cost);
  end loop;

  insert into public.account_transactions(
    organization_id,transaction_date,transaction_type,reference_type,reference_id,
    contact_id,description,debit,credit,created_by
  )
  values(
    v_org,now(),'Purchase','Purchase',p_purchase_id,v_contact,
    'Purchase payable - invoice '||(select p.invoice_no from public.purchases p where p.id=p_purchase_id),
    0,v_total,v_user
  );

  update public.purchases p
  set status='Confirmed',updated_at=now()
  where p.id=p_purchase_id;

  return jsonb_build_object(
    'purchase_id',p_purchase_id,'status','Confirmed','total',v_total
  );
end
$function$;

create or replace function public.confirm_sale(p_sale_id uuid)
returns uuid
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_user uuid=(select auth.uid());
  v_org uuid;
  v_status public.invoice_status;
  v_total numeric;
  v_discount numeric;
  v_item_total numeric;
  v_expected_total numeric;
  v_item_count int;
  r record;
  v_unit_cost numeric;
  v_cogs numeric;
  v_date date;
  v_contact uuid;
  v_invoice_no text;
begin
  if v_user is null then raise exception 'Authentication required'; end if;

  select s.organization_id,s.status,s.total,s.discount,s.invoice_date,s.contact_id,s.invoice_no
    into v_org,v_status,v_total,v_discount,v_date,v_contact,v_invoice_no
  from public.sales s
  where s.id=p_sale_id
  for update;

  if not found then raise exception 'Sale not found'; end if;

  perform public.rpc_assert_member(v_org);

  if v_status<>'Draft' then raise exception 'Only Draft sales can be confirmed'; end if;

  select count(*),coalesce(sum(si.line_total),0)
    into v_item_count,v_item_total
  from public.sale_items si
  where si.sale_id=p_sale_id and si.organization_id=v_org;

  if v_item_count=0 then raise exception 'Sale must contain at least one item'; end if;

  v_discount=coalesce(v_discount,0);
  v_expected_total=v_item_total-v_discount;

  if v_discount<0 or v_discount>v_item_total or v_expected_total<>v_total then
    raise exception 'Sale total does not match its item totals after overall discount';
  end if;

  if exists(
    select 1 from public.inventory_movements im
    where im.organization_id=v_org
      and im.reference_type='Sale'
      and im.reference_id=p_sale_id
  ) or exists(
    select 1 from public.account_transactions at
    where at.organization_id=v_org
      and at.reference_type='Sale'
      and at.reference_id=p_sale_id
  ) then
    raise exception 'Sale already has ledger effects';
  end if;

  for r in
    select si.product_id,sum(si.quantity) quantity
    from public.sale_items si
    where si.sale_id=p_sale_id and si.organization_id=v_org
    group by si.product_id
    order by si.product_id
  loop
    v_unit_cost=private.wac_out(v_org,r.product_id,r.quantity);
    v_cogs=round(r.quantity*v_unit_cost,4);

    insert into public.inventory_movements(
      organization_id,product_id,movement_direction,movement_type,quantity,
      reference_type,reference_id,unit_cost,movement_date,created_by
    )
    values(
      v_org,r.product_id,'Out','Sale',r.quantity,'Sale',p_sale_id,
      round(v_unit_cost,4),v_date,v_user
    );

    insert into public.account_transactions(
      organization_id,transaction_date,transaction_type,reference_type,reference_id,
      contact_id,description,debit,credit,created_by
    )
    values
      (v_org,v_date::timestamptz,'COGS','Sale',p_sale_id,v_contact,
       'COGS - '||v_invoice_no,v_cogs,0,v_user),
      (v_org,v_date::timestamptz,'Inventory - COGS','Sale',p_sale_id,v_contact,
       'Inventory reduction - '||v_invoice_no,0,v_cogs,v_user);
  end loop;

  insert into public.account_transactions(
    organization_id,transaction_date,transaction_type,reference_type,reference_id,
    contact_id,description,debit,credit,created_by
  )
  values
    (v_org,v_date::timestamptz,'Sale Receivable','Sale',p_sale_id,v_contact,
     'Sale receivable - '||v_invoice_no,v_total,0,v_user),
    (v_org,v_date::timestamptz,'Sale Revenue','Sale',p_sale_id,v_contact,
     'Sale revenue - '||v_invoice_no,0,v_total,v_user);

  update public.sales s
  set status='Confirmed',updated_at=now()
  where s.id=p_sale_id;

  return p_sale_id;
end
$function$;

revoke execute on function public.confirm_purchase(uuid) from public;
grant execute on function public.confirm_purchase(uuid) to authenticated;

revoke execute on function public.confirm_sale(uuid) from public;
grant execute on function public.confirm_sale(uuid) to authenticated;

commit;
