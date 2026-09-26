# Pomelo Inventory

Multi-organization inventory, purchasing, sales, and accounting workspace built with **Next.js 16**, **React 19**, **TypeScript**, **Supabase (PostgreSQL + Auth)**.

## What it does

| Module | Features |
|---|---|
| Dashboard | Stock value, cash in/out, net receivable & payable dues, draft backlog, low-stock lines, latest movements |
| Purchases | Draft → Confirmed → Cancelled lifecycle, atomic server totals, line-level audit, item returns, clone-as-draft, printable purchase bill, CSV export |
| Sales | Same lifecycle as purchases, concurrency-safe stock decrement (never negative), returns, quotations/proforma print from drafts, printable invoice, CSV export |
| Payments | In/Out with full-amount allocation to sales (In) or purchases/expenses (Out), allocator UI with pre-selected targets, one-click Pay from due lists, money receipt / payment voucher print |
| Expenses | Categories, draft → confirm → cancel, printable vouchers, CSV export |
| Inventory | Stock on hand, immutable movement ledger (Purchase/Sale/Adjustment/Opening/Return), opening balances, stock adjustments, CSV export |
| Contacts | Unified customer/supplier master, CSV import/export, per-contact ledger with receivable & payable statements and running balances |
| Products & UoM | Product master with retail prices, units of measure, CSV import/export |
| Reports | Due follow-up, aging, cash flow, profit, stock valuation, tax, top contacts, expense trends, movement velocity, audit trail, collection efficiency |
| Settings | Numbered sections (workspace, data, organization, user) with view-cards and edit toggles scoped to writable columns |

Every list is server-paginated; destructive financial actions go through single-transaction PostgreSQL RPCs, never multi-step client writes.

## Database architecture

- `supabase/migrations/` holds the full history. `20260926180000_*_schema.sql` is the **frozen** schema migration — never edited; everything after it adds RPCs, grants, or probes only. No new tables exist beyond the frozen 11 business tables plus masters.
- **Ledgers are append-only and client read-only** (`stock`, `inventory_movements`, `payment_allocations`, `account_transactions`). All effects run inside atomic `SECURITY DEFINER` RPCs with row locking, idempotency guards, and proportional reversals; cancellations never delete history.
- **Outstanding is always derived** (`total − confirmed allocations − posted returns`, floored at 0). No `paid_amount` / payment-status columns anywhere.
- Contacts are the single shared customer/supplier master. Single-organization model per user.

Key files: `supabase/catchup/apply_pending_rpc_layer.sql` (one-paste bundle of pending RPC migrations), `supabase/probes/live_db_probe.sql` (what is applied live?), `supabase/probes/ledger_reconciliation.sql` (R1–R10 health checks, empty = healthy), `supabase/security-advisor-triage.md` (accepted linter findings).

## Applying database changes

Migrations are **repo-only by default**. To bring a Supabase project up to date, paste the catch-up bundle (or individual files in version order) into the Dashboard SQL editor, then wait ~1 minute for PostgREST's schema cache to reload. Verify with the probes afterward.

## Project structure

```text
app/                routes (dashboard, purchases, sales, accounting, inventory,
                    contacts, products, reports, settings, organization)
  components/       workspace-shell, pager, invoice-document, print-button, …
lib/
  auth/workspace    single-org membership (cached per request)
  services/         typed RPC wrappers (purchases, sales, payments, expenses, inventory)
  pagination.ts     shared server-side paging helpers
  csv.ts            CSV export helper
supabase/
  migrations/       versioned history (see above)
  catchup/          generated apply bundle (do not hand-edit)
  probes/           read-only live-DB diagnostics
```

## Development

```bash
npm install
npm run dev      # http://localhost:3000
```

Configure `.env.local` with `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (anon key also accepted). The app targets whichever project those point at — use a disposable project for experiments.

```bash
npx tsc --noEmit  # typecheck
npm run build     # production build
```

## Operational notes

- Features degrade gracefully when the live database predates a migration (RPC-first with legacy fallback for numbering and draft writes); new capabilities (returns, adjustments) require the bundle applied.
- The Supabase security advisor flags the intentional `SECURITY DEFINER` RPCs — triaged and accepted in `supabase/security-advisor-triage.md`. Enable **leaked password protection** in Dashboard → Authentication → Policies (not code-fixable).
