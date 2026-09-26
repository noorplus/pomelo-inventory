import { toServiceError, type Db } from "./common";

export type StockRow = {
  product_id: string;
  quantity: number;
  updated_at: string;
};

export type InventoryMovementRow = {
  id: string;
  product_id: string;
  movement_direction: "In" | "Out";
  movement_type: "Purchase" | "Sale" | "Adjustment" | "Opening" | "Return";
  quantity: number;
  reference_type: string | null;
  reference_id: string | null;
  unit_cost: number | null;
  movement_date: string;
};

// Read-only views over the system-maintained stock balance and the immutable
// movement ledger. Writes happen only inside confirm/cancel RPCs.

export async function getProductStock(db: Db, organizationId: string, productId: string): Promise<StockRow | null> {
  const { data, error } = await db
    .from("stock")
    .select("product_id, quantity, updated_at")
    .eq("organization_id", organizationId)
    .eq("product_id", productId)
    .maybeSingle();
  if (error) throw toServiceError(error, "Unable to load stock.");
  return (data as StockRow | null) ?? null;
}

export async function listStock(db: Db, organizationId: string): Promise<StockRow[]> {
  const { data, error } = await db
    .from("stock")
    .select("product_id, quantity, updated_at")
    .eq("organization_id", organizationId)
    .order("updated_at", { ascending: false });
  if (error) throw toServiceError(error, "Unable to load stock.");
  return (data ?? []) as StockRow[];
}

export async function listInventoryMovements(
  db: Db,
  organizationId: string,
  productId?: string,
  limit = 100,
): Promise<InventoryMovementRow[]> {
  let query = db
    .from("inventory_movements")
    .select("id, product_id, movement_direction, movement_type, quantity, reference_type, reference_id, unit_cost, movement_date")
    .eq("organization_id", organizationId)
    .order("movement_date", { ascending: false })
    .limit(limit);
  if (productId) query = query.eq("product_id", productId);
  const { data, error } = await query;
  if (error) throw toServiceError(error, "Unable to load inventory movements.");
  return (data ?? []) as InventoryMovementRow[];
}
