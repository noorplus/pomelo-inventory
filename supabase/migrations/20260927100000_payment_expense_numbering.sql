-- Pomelo Inventory - Serialized payment/expense numbering
-- Repository migration only. Do NOT apply to Supabase unless explicitly requested.
--
-- The application previously generated payment_no / expense_no client-side via
-- count-then-insert (PAY-000001 / EXP-000001). That breaks two ways: concurrent
-- creates compute the same number, and deleted rows make count + 1 reuse an
-- existing number (unique violation). These RPCs serialize numbering per
-- organization by taking a row lock before reading the current MAXIMUM numeric
-- suffix, so numbers stay ahead of every existing row even after deletes.
-- Gaps may occur on rollback. No new tables.

create or replace function public.next_payment_no(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $func$
declare
  v_user uuid := (select auth.uid());
  v_max integer;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = p_organization_id
      and ou.user_id = v_user
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  perform 1 from public.organizations o where o.id = p_organization_id for update;
  if not found then
    raise exception 'Organization not found';
  end if;

  select coalesce(max(substring(p.payment_no from '([0-9]+)$')::integer), 0)
    into v_max
  from public.payments p
  where p.organization_id = p_organization_id
    and p.payment_no ~ '[0-9]+$';

  return 'PAY-' || lpad((v_max + 1)::text, 6, '0');
end;
$func$;

create or replace function public.next_expense_no(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $func$
declare
  v_user uuid := (select auth.uid());
  v_max integer;
begin
  if v_user is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = p_organization_id
      and ou.user_id = v_user
  ) then
    raise exception 'User is not a member of this organization';
  end if;

  perform 1 from public.organizations o where o.id = p_organization_id for update;
  if not found then
    raise exception 'Organization not found';
  end if;

  select coalesce(max(substring(e.expense_no from '([0-9]+)$')::integer), 0)
    into v_max
  from public.expenses e
  where e.organization_id = p_organization_id
    and e.expense_no ~ '[0-9]+$';

  return 'EXP-' || lpad((v_max + 1)::text, 6, '0');
end;
$func$;

revoke all on function public.next_payment_no(uuid) from public;
revoke all on function public.next_expense_no(uuid) from public;
grant execute on function public.next_payment_no(uuid) to authenticated;
grant execute on function public.next_expense_no(uuid) to authenticated;

comment on function public.next_payment_no(uuid) is 'Returns the next serialized payment number (PAY-000001 style) for an organization.';
comment on function public.next_expense_no(uuid) is 'Returns the next serialized expense number (EXP-000001 style) for an organization.';
