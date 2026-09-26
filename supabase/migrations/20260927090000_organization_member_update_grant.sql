-- Pomelo Inventory - Organization member update grant
-- Repository migration only. Do NOT apply to Supabase unless explicitly requested.
--
-- The 20260926090000_organization_update_policy.sql migration allows organization
-- members to update their own organization row, but the initial schema
-- (20260925000100_initial_schema.sql) revoked table-level UPDATE on
-- public.organizations from the authenticated role and nothing ever re-granted
-- it, so the policy can never fire and Settings saves fail with
-- "permission denied". Grant UPDATE only: INSERT stays behind the
-- create_organization RPC and DELETE is never client-allowed. No new tables.

grant update on table public.organizations to authenticated;
