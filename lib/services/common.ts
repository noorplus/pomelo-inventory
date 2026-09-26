import type { SupabaseClient } from "@supabase/supabase-js";

// Service-layer contract: every business mutation runs inside ONE PostgreSQL
// transaction via a canonical RPC (see
// supabase/migrations/20260926230000_canonical_atomic_operations.sql).
// Application code must never fan out stock/ledger/status writes as separate
// queries. Services pass only business inputs, handle errors consistently,
// and return typed results.

export type Db = SupabaseClient;

export class ServiceError extends Error {
  readonly code?: string;

  constructor(message: string, code?: string) {
    super(message);
    this.name = "ServiceError";
    this.code = code;
  }
}

export function toServiceError(error: unknown, fallback: string): ServiceError {
  if (error instanceof ServiceError) return error;
  if (typeof error === "object" && error !== null) {
    const record = error as { message?: unknown; code?: unknown };
    const message = typeof record.message === "string" && record.message ? record.message : fallback;
    const code = typeof record.code === "string" ? record.code : undefined;
    return new ServiceError(message, code);
  }
  return new ServiceError(fallback);
}

export async function callRpc<T>(db: Db, fn: string, args: Record<string, unknown>, fallback: string): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) {
    const code = typeof error.code === "string" ? error.code : "";
    const raw = typeof error.message === "string" ? error.message : "";
    // PostgREST schema cache only knows functions that exist in the LIVE
    // database. This means a repo migration was never applied there.
    if (code === "PGRST202" || /schema cache/i.test(raw)) {
      throw new ServiceError(
        `Database update pending: the live database does not have ${fn} yet. Apply the pending Supabase migrations, wait about a minute, then retry.`,
        "PGRST202",
      );
    }
    if (code === "42501" || /permission denied/i.test(raw)) {
      throw new ServiceError(
        `Database permission pending: the live database blocked ${fn}. Apply the pending Supabase migrations, then retry.`,
        code || "42501",
      );
    }
    throw toServiceError(error, fallback);
  }
  return data as T;
}
