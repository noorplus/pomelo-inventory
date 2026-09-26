create policy "organizations_update_member"
on public.organizations
for update
to authenticated
using (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = organizations.id
      and ou.user_id = (select auth.uid())
  )
)
with check (
  exists (
    select 1
    from public.organization_users ou
    where ou.organization_id = organizations.id
      and ou.user_id = (select auth.uid())
  )
);
