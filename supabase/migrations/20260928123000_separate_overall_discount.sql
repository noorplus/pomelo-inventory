-- Separate item-level discounts from the document-level discount.
-- sales.discount / purchases.discount now represent the overall discount only.
-- subtotal is the net subtotal after item-level discounts; total = subtotal - overall discount.

create or replace function public.create_sale_draft(
  p_organization_id uuid, p_contact_id uuid, p_invoice_date date default null,
  p_notes text default null, p_items jsonb default '[]'::jsonb,
  p_overall_discount numeric default 0
) returns jsonb language plpgsql security definer set search_path to public, pg_temp as $$
declare v_result jsonb; v_id uuid; v_gross numeric; v_item_discount numeric; v_net numeric; v_overall numeric := coalesce(p_overall_discount,0);
begin
  if v_overall < 0 then raise exception 'Overall discount cannot be negative'; end if;
  v_result := public.create_sale_draft(p_organization_id,p_contact_id,p_invoice_date,p_notes,p_items);
  v_id := (v_result->>'sale_id')::uuid;
  select coalesce(sum(x.quantity*x.unit_price),0),coalesce(sum(coalesce(x.discount,0)),0) into v_gross,v_item_discount
  from jsonb_to_recordset(p_items) x(product_id uuid,quantity numeric,unit_price numeric,discount numeric);
  v_net := v_gross-v_item_discount;
  if v_overall > v_net then raise exception 'Overall discount cannot exceed subtotal after item discounts'; end if;
  update public.sales set subtotal=v_net,discount=v_overall,total=v_net-v_overall,updated_at=now() where id=v_id;
  return jsonb_build_object('sale_id',v_id);
end $$;

create or replace function public.update_sale_draft(
  p_sale_id uuid, p_contact_id uuid, p_invoice_date date default null,
  p_notes text default null, p_items jsonb default '[]'::jsonb,
  p_overall_discount numeric default 0
) returns jsonb language plpgsql security definer set search_path to public, pg_temp as $$
declare v_result jsonb; v_gross numeric; v_item_discount numeric; v_net numeric; v_overall numeric := coalesce(p_overall_discount,0);
begin
  if v_overall < 0 then raise exception 'Overall discount cannot be negative'; end if;
  v_result := public.update_sale_draft(p_sale_id,p_contact_id,p_invoice_date,p_notes,p_items);
  select coalesce(sum(x.quantity*x.unit_price),0),coalesce(sum(coalesce(x.discount,0)),0) into v_gross,v_item_discount
  from jsonb_to_recordset(p_items) x(id uuid,product_id uuid,quantity numeric,unit_price numeric,discount numeric);
  v_net := v_gross-v_item_discount;
  if v_overall > v_net then raise exception 'Overall discount cannot exceed subtotal after item discounts'; end if;
  update public.sales set subtotal=v_net,discount=v_overall,total=v_net-v_overall,updated_at=now() where id=p_sale_id;
  return jsonb_build_object('sale_id',p_sale_id);
end $$;

create or replace function public.create_purchase_draft(
  p_organization_id uuid, p_contact_id uuid, p_invoice_date date default null,
  p_notes text default null, p_items jsonb default '[]'::jsonb,
  p_overall_discount numeric default 0
) returns jsonb language plpgsql security definer set search_path to public, pg_temp as $$
declare v_result jsonb; v_id uuid; v_gross numeric; v_item_discount numeric; v_net numeric; v_overall numeric := coalesce(p_overall_discount,0);
begin
  if v_overall < 0 then raise exception 'Overall discount cannot be negative'; end if;
  v_result := public.create_purchase_draft(p_organization_id,p_contact_id,p_invoice_date,p_notes,p_items);
  v_id := (v_result->>'purchase_id')::uuid;
  select coalesce(sum(x.quantity*x.unit_price),0),coalesce(sum(coalesce(x.discount,0)),0) into v_gross,v_item_discount
  from jsonb_to_recordset(p_items) x(product_id uuid,quantity numeric,unit_price numeric,discount numeric);
  v_net := v_gross-v_item_discount;
  if v_overall > v_net then raise exception 'Overall discount cannot exceed subtotal after item discounts'; end if;
  update public.purchases set subtotal=v_net,discount=v_overall,total=v_net-v_overall,updated_at=now() where id=v_id;
  return jsonb_build_object('purchase_id',v_id);
end $$;

create or replace function public.update_purchase_draft(
  p_purchase_id uuid, p_contact_id uuid, p_invoice_date date default null,
  p_notes text default null, p_items jsonb default '[]'::jsonb,
  p_overall_discount numeric default 0
) returns jsonb language plpgsql security definer set search_path to public, pg_temp as $$
declare v_result jsonb; v_gross numeric; v_item_discount numeric; v_net numeric; v_overall numeric := coalesce(p_overall_discount,0);
begin
  if v_overall < 0 then raise exception 'Overall discount cannot be negative'; end if;
  v_result := public.update_purchase_draft(p_purchase_id,p_contact_id,p_invoice_date,p_notes,p_items);
  select coalesce(sum(x.quantity*x.unit_price),0),coalesce(sum(coalesce(x.discount,0)),0) into v_gross,v_item_discount
  from jsonb_to_recordset(p_items) x(id uuid,product_id uuid,quantity numeric,unit_price numeric,discount numeric);
  v_net := v_gross-v_item_discount;
  if v_overall > v_net then raise exception 'Overall discount cannot exceed subtotal after item discounts'; end if;
  update public.purchases set subtotal=v_net,discount=v_overall,total=v_net-v_overall,updated_at=now() where id=p_purchase_id;
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;
