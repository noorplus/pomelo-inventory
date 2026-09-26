import { callRpc, type Db } from "./common";

export type PurchaseLineInput = {
  id?: string;
  product_id: string;
  quantity: number;
  unit_price: number;
  discount?: number;
  tax?: number;
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
  if (typeof data === "string") return { purchase_id: data };
  return { purchase_id: data.purchase_id };
}

export async function updatePurchaseDraft(
  db: Db,
  input: {
    purchaseId: string;
    contactId: string;
    invoiceDate?: string | null;
    notes?: string | null;
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
      p_items: input.items,
    },
    "Unable to update purchase draft.",
  );
  if (typeof data === "string") return { purchase_id: data };
  return { purchase_id: data?.purchase_id ?? input.purchaseId };
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
