# Supabase Security Advisor triage — 2026-09-27

Source: Supabase Dashboard → Advisors → Security (13 WARN findings).
Repo state at triage: `effd05f` plus numbering/draft fallbacks.

## Findings 1–12: `authenticated_security_definer_function_executable` — ACCEPTED (intentional)

Affected functions (all in `public`, all `EXECUTE` to `authenticated`):

| Function | Why DEFINER is required |
|---|---|
| `confirm_purchase`, `cancel_purchase` | Must write `stock`, `inventory_movements`, `account_transactions` — all client read-only (no INSERT grant, SELECT-only RLS). INVOKER could never perform the ledger writes. |
| `confirm_sale`, `cancel_sale` | Same as above. |
| `confirm_expense`, `cancel_expense` | Must write `account_transactions` (client read-only). |
| `confirm_payment(uuid, jsonb)`, `cancel_payment` | Must write `payment_allocations` + `account_transactions` (both client read-only). |
| `create_organization` | Must insert `organizations` + `organization_users` (both client insert-revoked). |
| `next_contact_id_no`, `next_purchase_invoice_no`, `next_sales_invoice_no` | Must upsert the fully-revoked counter / lock the org row from inside insert triggers firing in any client context. |

Every flagged function satisfies the full hardening checklist from the
project security model, which the linter cannot see:

- fixed `search_path` (`''` on the hardened RPCs, `public, pg_temp` on the older helpers),
- first statement validates `auth.uid()` (rejects anonymous),
- organization membership re-checked inside the function (`rpc_assert_member` / inline),
- never trusts client-supplied `organization_id` / `created_by`; actor derived from `auth.uid()`,
- `REVOKE ALL ... FROM public` (+ `anon` where applicable); `GRANT EXECUTE` to `authenticated` only,
- no `user_metadata` authorization anywhere.

Switching these to `SECURITY INVOKER` would not improve security — it would
break them, because the ledgers are intentionally unwritable by clients.
This is the exact case the linter docs describe as "if that is not
intentional": here it is intentional, so the correct action is documented
acceptance, not a code change.

Internal-only DEFINER helpers (`rpc_assert_member`, `handle_new_user`) are
already revoked from `public, anon, authenticated` and are correctly NOT
flagged.

## Finding 13: `auth_leaked_password_protection` — ACTION FOR PROJECT OWNER

HaveIBeenPwned password screening is off. Not fixable from this repo.
Dashboard → Authentication → Policies → enable **Leaked password
protection**. One toggle, no code or migration involved.

## Re-check procedure

After applying pending migrations, Dashboard → Advisors → **Rescan**.
Expect: the 12 DEFINER rows persist (accepted), `contact_id_counters`
(`rls_disabled_in_public`, fixed in `20260927150000`) clears, and no new
rows appear. If any NEW finding appears, triage it here before changing code.
