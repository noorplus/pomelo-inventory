import { callRpc, type Db } from "./common";

export type PurchaseLineInput = {
  id?: string;
  product_id: string;
  quantity: number;
  unit_price: number;
  discount?: number;
};

export type PurchaseDraftResult = {
  purchase_id: string;
};

// Draft lifecycle RPCs are defined in
// supabase/migrations/20260926210500_purchase_atomic_operations.sql.
// Confirm/cancel are canonical in
// supabase/migrations/20260926230000_canonical_atomic_operations.sql.

export async function createPurchaseDraft(
  db: Db,
  input: {
    organizationId: string;
    contactId: string;
    invoiceDate?: string | null;
    notes?: string | null;
    overallDiscount?: number;
    items: PurchaseLineInput[];
  },
): Promise<PurchaseDraftResult> {
  const data = await callRpc<{ purchase_id: string } | string>(
    db,
    "create_purchase_draft",
    {
      p_organization_id: input.organizationId,
      p_contact_id: input.contactId,
      p_invoice_date: input.invoiceDate ?? null,
      p_notes: input.notes ?? null,
      p_items: input.items,
    },
    "Unable to create purchase draft.",
  );
  const purchaseId = typeof data === "string" ? data : data.purchase_id;
  const gross = input.items.reduce((sum, item) => sum + Number(item.quantity || 0) * Number(item.unit_price || 0), 0);
  const itemDiscount = input.items.reduce((sum, item) => sum + Number(item.discount || 0), 0);
  const netSubtotal = Math.max(0, gross - itemDiscount);
  const overallDiscount = Number(input.overallDiscount || 0);
  if (overallDiscount < 0 || overallDiscount > netSubtotal) throw new Error("Overall discount cannot exceed subtotal after item discounts.");
  const { error } = await db.from("purchases").update({ subtotal: netSubtotal, discount: overallDiscount, total: netSubtotal - overallDiscount }).eq("id", purchaseId);
  if (error) throw new Error(error.message);
  return { purchase_id: purchaseId };
}

export async function updatePurchaseDraft(
  db: Db,
  input: {
    purchaseId: string;
    contactId: string;
    invoiceDate?: string | null;
    notes?: string | null;
    overallDiscount?: number;
    items: PurchaseLineInput[];
  },
): Promise<PurchaseDraftResult> {
  const data = await callRpc<{ purchase_id: string } | string>(
    db,
    "update_purchase_draft",
    {
      p_purchase_id: input.purchaseId,
      p_contact_id: input.contactId,
      p_invoice_date: input.invoiceDate ?? null,
      p_notes: input.notes ?? null,
      p_overall_discount: input.overallDiscount ?? 0,
      p_items: input.items,
    },
    "Unable to update purchase draft.",
  );
  const purchaseId = typeof data === "string" ? data : data?.purchase_id ?? input.purchaseId;
  const gross = input.items.reduce((sum, item) => sum + Number(item.quantity || 0) * Number(item.unit_price || 0), 0);
  const itemDiscount = input.items.reduce((sum, item) => sum + Number(item.discount || 0), 0);
  const netSubtotal = Math.max(0, gross - itemDiscount);
  const overallDiscount = Number(input.overallDiscount || 0);
  if (overallDiscount < 0 || overallDiscount > netSubtotal) throw new Error("Overall discount cannot exceed subtotal after item discounts.");
  const { error } = await db.from("purchases").update({ subtotal: netSubtotal, discount: overallDiscount, total: netSubtotal - overallDiscount }).eq("id", purchaseId);
  if (error) throw new Error(error.message);
  return { purchase_id: purchaseId };
}

export async function deletePurchaseDraft(db: Db, purchaseId: string): Promise<void> {
  await callRpc<unknown>(db, "delete_purchase_draft", { p_purchase_id: purchaseId }, "Unable to delete purchase draft.");
}

export async function confirmPurchase(db: Db, purchaseId: string): Promise<string> {
  const data = await callRpc<string>(db, "confirm_purchase", { p_purchase_id: purchaseId }, "Unable to confirm purchase.");
  return data ?? purchaseId;
}

export async function cancelPurchase(db: Db, purchaseId: string): Promise<string> {
  const data = await callRpc<string>(db, "cancel_purchase", { p_purchase_id: purchaseId }, "Unable to cancel purchase.");
  return data ?? purchaseId;
}

export async function getPurchaseOutstanding(db: Db, purchaseId: string): Promise<number> {
  const data = await callRpc<number | string>(
    db,
    "purchase_outstanding",
    { p_purchase_id: purchaseId },
    "Unable to load purchase outstanding balance.",
  );
  return Number(data);
}
