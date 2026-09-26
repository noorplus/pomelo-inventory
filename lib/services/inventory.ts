import { callRpc, toServiceError, type Db } from "./common";

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

export type StockAdjustmentInput = {
  organizationId: string;
  productId: string;
  quantity: number;
  direction: "In" | "Out";
  movementType: "Opening" | "Adjustment";
  unitCost?: number | null;
};

export type ReturnLineInput = {
  product_id: string;
  quantity: number;
};

// Opening / Adjustment corrections (see
// 20260927110000_inventory_adjustments_returns.sql). Never drive stock
// negative on Out adjustments; one atomic transaction per call.
export async function recordStockAdjustment(db: Db, input: StockAdjustmentInput): Promise<string> {
  const data = await callRpc<string>(
    db,
    "record_stock_adjustment",
    {
      p_organization_id: input.organizationId,
      p_product_id: input.productId,
      p_quantity: input.quantity,
      p_direction: input.direction,
      p_movement_type: input.movementType,
      p_unit_cost: input.unitCost ?? null,
    },
    "Unable to record stock adjustment.",
  );
  return data;
}

// Quantity-based returns against Confirmed invoices. Blocked while confirmed
// payments are allocated; returns accumulate until the invoiced quantity is
// fully returned. Returns the reversed financial amount.
export async function returnPurchaseItems(db: Db, purchaseId: string, lines: ReturnLineInput[]): Promise<number> {
  const data = await callRpc<number | string>(
    db,
    "return_purchase_items",
    { p_purchase_id: purchaseId, p_lines: lines },
    "Unable to return purchase items.",
  );
  return Number(data);
}

export async function returnSaleItems(db: Db, saleId: string, lines: ReturnLineInput[]): Promise<number> {
  const data = await callRpc<number | string>(
    db,
    "return_sale_items",
    { p_sale_id: saleId, p_lines: lines },
    "Unable to return sale items.",
  );
  return Number(data);
}
