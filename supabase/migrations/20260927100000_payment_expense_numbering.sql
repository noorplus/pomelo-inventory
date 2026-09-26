-- Pomelo Inventory - Serialized payment/expense numbering
-- Repository migration only. Do NOT apply to Supabase unless explicitly requested.
--
-- The application previously generated payment_no / expense_no client-side via
-- count-then-insert (PAY-000001 / EXP-000001). Under concurrent creates two
-- transactions compute the same number and the second fails on the unique
-- constraint. These RPCs serialize numbering per organization by taking a row
-- lock on the organization before counting, so concurrent creates get distinct
-- numbers. Gaps may occur on rollback; numbers are never reused while the
-- referenced row still exists. No new tables.

create or replace function public.next_payment_no(p_organization_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $func$
declare
  v_user uuid := (select auth.uid());
  v_count integer;
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

  select count(*) into v_count
  from public.payments
  where organization_id = p_organization_id;

  return 'PAY-' || lpad((v_count + 1)::text, 6, '0');
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
  v_count integer;
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

  select count(*) into v_count
  from public.expenses
  where organization_id = p_organization_id;

  return 'EXP-' || lpad((v_count + 1)::text, 6, '0');
end;
$func$;

revoke all on function public.next_payment_no(uuid) from public;
revoke all on function public.next_expense_no(uuid) from public;
grant execute on function public.next_payment_no(uuid) to authenticated;
grant execute on function public.next_expense_no(uuid) to authenticated;

comment on function public.next_payment_no(uuid) is 'Returns the next serialized payment number (PAY-000001 style) for an organization.';
comment on function public.next_expense_no(uuid) is 'Returns the next serialized expense number (EXP-000001 style) for an organization.';
