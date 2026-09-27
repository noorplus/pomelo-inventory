alter table public.organization_users add column if not exists role text;
update public.organization_users set role='owner' where role is null;
alter table public.organization_users alter column role set default 'member';
alter table public.organization_users alter column role set not null;
alter table public.organization_users drop constraint if exists organization_users_role_check;
alter table public.organization_users add constraint organization_users_role_check check (role in ('owner','member'));
create unique index if not exists organization_users_one_owner_idx on public.organization_users (organization_id) where role='owner';

create or replace function public.create_organization(p_organization_name text,p_phone_number text,p_email text,p_address text,p_tin text default null,p_bin text default null)
returns public.organizations language plpgsql security definer set search_path='' as $$
declare v_user_id uuid:=auth.uid(); v_organization public.organizations;
begin
if v_user_id is null then raise exception using errcode='42501',message='Authentication required'; end if;
if exists(select 1 from public.organization_users where user_id=v_user_id) then raise exception using errcode='42501',message='User already belongs to an organization'; end if;
insert into public.organizations(organization_name,phone_number,email,address,tin,bin) values(p_organization_name,p_phone_number,p_email,p_address,nullif(p_tin,''),nullif(p_bin,'')) returning * into v_organization;
insert into public.organization_users(organization_id,user_id,role) values(v_organization.id,v_user_id,'owner');
return v_organization;
end $$;

create or replace function public.organization_members(p_organization_id uuid)
returns table(user_id uuid,full_name text,email text,role text,created_at timestamptz)
language plpgsql security definer set search_path='' stable as $$
begin
if auth.uid() is null then raise exception using errcode='42501',message='Authentication required'; end if;
if not exists(select 1 from public.organization_users where organization_id=p_organization_id and user_id=auth.uid()) then raise exception using errcode='42501',message='User is not a member of this organization'; end if;
return query select ou.user_id,p.full_name,au.email::text,ou.role,ou.created_at from public.organization_users ou join public.profiles p on p.id=ou.user_id join auth.users au on au.id=ou.user_id where ou.organization_id=p_organization_id order by case when ou.role='owner' then 0 else 1 end,p.full_name;
end $$;

create or replace function public.add_organization_member(p_organization_id uuid,p_email text)
returns public.organization_users language plpgsql security definer set search_path='' as $$
declare v_target uuid; v_row public.organization_users;
begin
if not exists(select 1 from public.organization_users where organization_id=p_organization_id and user_id=auth.uid() and role='owner') then raise exception using errcode='42501',message='Only an organization owner can manage members'; end if;
select id into v_target from auth.users where lower(email)=lower(btrim(p_email)) limit 1;
if v_target is null then raise exception using errcode='P0002',message='No registered user exists with that email address'; end if;
insert into public.organization_users(organization_id,user_id,role) values(p_organization_id,v_target,'member') returning * into v_row; return v_row;
exception when unique_violation then raise exception using errcode='23505',message='That user is already a member of this organization';
end $$;

create or replace function public.set_organization_member_role(p_organization_id uuid,p_user_id uuid,p_role text)
returns public.organization_users language plpgsql security definer set search_path='' as $$
declare v_row public.organization_users;
begin
if p_role not in('owner','member') then raise exception using errcode='22023',message='Invalid member role'; end if;
if not exists(select 1 from public.organization_users where organization_id=p_organization_id and user_id=auth.uid() and role='owner') then raise exception using errcode='42501',message='Only an organization owner can manage roles'; end if;
if not exists(select 1 from public.organization_users where organization_id=p_organization_id and user_id=p_user_id) then raise exception using errcode='P0002',message='Member not found'; end if;
if p_role='owner' then update public.organization_users set role='member' where organization_id=p_organization_id and role='owner' and user_id<>p_user_id; update public.organization_users set role='owner' where organization_id=p_organization_id and user_id=p_user_id;
else if p_user_id=auth.uid() then raise exception using errcode='42501',message='Transfer ownership before leaving the owner role'; end if; update public.organization_users set role='member' where organization_id=p_organization_id and user_id=p_user_id; end if;
select * into v_row from public.organization_users where organization_id=p_organization_id and user_id=p_user_id; return v_row;
end $$;

create or replace function public.remove_organization_member(p_organization_id uuid,p_user_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_role text;
begin
if not exists(select 1 from public.organization_users where organization_id=p_organization_id and user_id=auth.uid() and role='owner') then raise exception using errcode='42501',message='Only an organization owner can remove members'; end if;
select role into v_role from public.organization_users where organization_id=p_organization_id and user_id=p_user_id;
if v_role is null then raise exception using errcode='P0002',message='Member not found'; end if;
if v_role='owner' then raise exception using errcode='42501',message='Transfer ownership before removing the owner'; end if;
delete from public.organization_users where organization_id=p_organization_id and user_id=p_user_id;
end $$;

revoke execute on function public.organization_members(uuid) from public,anon;
revoke execute on function public.add_organization_member(uuid,text) from public,anon;
revoke execute on function public.set_organization_member_role(uuid,uuid,text) from public,anon;
revoke execute on function public.remove_organization_member(uuid,uuid) from public,anon;
grant execute on function public.organization_members(uuid) to authenticated;
grant execute on function public.add_organization_member(uuid,text) to authenticated;
grant execute on function public.set_organization_member_role(uuid,uuid,text) to authenticated;
grant execute on function public.remove_organization_member(uuid,uuid) to authenticated;