-- Pomelo Inventory - RLS on the contact counter table
-- Repository migration only. Do NOT apply to Supabase unless explicitly requested.
--
-- public.contact_id_counters is fully revoked from anon/authenticated (only
-- SECURITY DEFINER internals touch it), but it never got ENABLE ROW LEVEL
-- SECURITY, which the Supabase security advisor flags. Enabling RLS with no
-- policies and no grants changes nothing functionally. No new tables.
alter table public.contact_id_counters enable row level security;
