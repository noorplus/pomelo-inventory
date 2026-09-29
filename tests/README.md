# Phase 8 regression and concurrency tests

The repository now contains deterministic regression tests for:

- overall-discount validation and allocation
- weighted-average-cost (WAC) stock valuation invariants
- double-entry balancing
- exact return transaction types used by outstanding calculations
- stock-underflow rejection
- sale COGS/inventory reconciliation
- duplicate/parallel confirmation state transitions
- concurrent payment-allocation boundaries

## Running

`npm test` runs the complete Node test suite.

The concurrency tests are deliberately deterministic state-boundary models. They do not mutate the production Supabase database.

## Database-level concurrency

Production concurrency tests must run against a disposable PostgreSQL/Supabase test database, never the live production dataset. The required DB-level scenarios are documented by the application contracts and should use isolated fixtures for:

1. two simultaneous `confirm_purchase` calls for one draft
2. two simultaneous `confirm_sale` calls for one draft
3. two simultaneous payment allocations against the same document
4. simultaneous sale return/cancellation against the same stock
5. simultaneous purchase return/cancellation against the same stock
6. cross-organization draft updates and RPC calls

The production database was not mutated by this Phase 8 test implementation.
