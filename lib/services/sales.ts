import { callRpc, type Db } from "./common";

export type SaleLineInput = {
  id?: string;
  product_id: string;
  quantity: number;
  unit_price: number;
  discount?: number;
  tax?: number;
};

export type SaleDraftResult = {
  sale_id: string;
};

// Draft lifecycle RPCs are defined in
// supabase/migrations/20260927120000_sale_draft_operations.sql.

export async function createSaleDraft(
  db: Db,
  input: {
    organizationId: string;
    contactId: string;
    invoiceDate?: string | null;
    notes?: string | null;
    items: SaleLineInput[];
  },
): Promise<SaleDraftResult> {
  const data = await callRpc<{ sale_id: string } | string>(
    db,
    "create_sale_draft",
    {
      p_organization_id: input.organizationId,
      p_contact_id: input.contactId,
      p_invoice_date: input.invoiceDate ?? null,
      p_notes: input.notes ?? null,
      p_items: input.items,
    },
    "Unable to create sale draft.",
  );
  if (typeof data === "string") return { sale_id: data };
  return { sale_id: data.sale_id };
}

export async function updateSaleDraft(
  db: Db,
  input: {
    saleId: string;
    contactId: string;
    invoiceDate?: string | null;
    notes?: string | null;
    items: SaleLineInput[];
  },
): Promise<SaleDraftResult> {
  const data = await callRpc<{ sale_id: string } | string>(
    db,
    "update_sale_draft",
    {
      p_sale_id: input.saleId,
      p_contact_id: input.contactId,
      p_invoice_date: input.invoiceDate ?? null,
      p_notes: input.notes ?? null,
      p_items: input.items,
    },
    "Unable to update sale draft.",
  );
  if (typeof data === "string") return { sale_id: data };
  return { sale_id: data?.sale_id ?? input.saleId };
}

export async function deleteSaleDraft(db: Db, saleId: string): Promise<void> {
  await callRpc<unknown>(db, "delete_sale_draft", { p_sale_id: saleId }, "Unable to delete sale draft.");
}

export async function confirmSale(db: Db, saleId: string): Promise<string> {
  const data = await callRpc<string>(db, "confirm_sale", { p_sale_id: saleId }, "Unable to confirm sale.");
  return data ?? saleId;
}

export async function cancelSale(db: Db, saleId: string): Promise<string> {
  const data = await callRpc<string>(db, "cancel_sale", { p_sale_id: saleId }, "Unable to cancel sale.");
  return data ?? saleId;
}

export async function getSaleOutstanding(db: Db, saleId: string): Promise<number> {
  const data = await callRpc<number | string>(
    db,
    "sale_outstanding",
    { p_sale_id: saleId },
    "Unable to load sale outstanding balance.",
  );
  return Number(data);
}
