# Supabase schema reconciliation

Production Supabase was compared with the repository migration contract on 2026-09-29.

## Current schema

- Required application tables and columns are present.
- Sales and purchases no longer expose Tax columns.
- Sales and purchases use separate overall-discount fields.
- Production has the canonical six-argument draft RPCs for sales and purchases.
- The five-argument `*_base` RPCs are retained as implementation helpers.
- Current RLS policies, foreign keys, constraints, indexes, and triggers match the current application contract.

## Historical migration provenance

Production migration history is not a literal filename mirror of the repository. Supabase has recorded several migrations under generated timestamps/names while later repository migrations contain the canonical current definitions.

Known historical differences are intentionally preserved:

1. Production records Tax removal as `20260928053922 remove_tax_from_sales_purchases_v3`; the repository contains the canonical current migration `20260928120000_remove_tax_from_sales_purchases.sql`.
2. Production contains historical hardening steps whose original SQL is not present in the current repository tree.

Do not reconstruct or rewrite applied historical migrations. Preserve production history and add only forward migrations when the live schema actually differs from the repository contract.

## Overall discount

The repository now records the production overall-discount RPC chain in:

- `20260928123000_separate_overall_discount.sql`
- `20260928180748_fix_overall_discount_rpc_overload.sql`

Application services pass `p_overall_discount` directly to the canonical RPCs; no second post-RPC header update is used.

## Verification

GitHub Actions Build Verification passed for main commit `4614396f995131ce0b61662f8ea1f7ef1640cbe0`.

This file documents provenance only and does not apply database changes.
