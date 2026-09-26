"use server";

import { redirect } from "next/navigation";
import { getWorkspaceMembership } from "@/lib/auth/workspace";

type PurchaseItemInput = {
  product_id: string;
  quantity: number;
  unit_price: number;
  discount?: number;
  tax?: number;
};

function parseItems(formData: FormData): PurchaseItemInput[] {
  const raw = String(formData.get("items_json") || "[]");
  let items: unknown;

  try {
    items = JSON.parse(raw);
  } catch {
    throw new Error("Invalid purchase items.");
  }

  if (!Array.isArray(items) || !items.length) {
    throw new Error("Add at least one product.");
  }

  return items.map((item) => {
    const value = item as Record<string, unknown>;
    return {
      product_id: String(value.product_id || ""),
      quantity: Number(value.quantity),
      unit_price: Number(value.unit_price),
      discount: Number(value.discount || 0),
      tax: Number(value.tax || 0),
    };
  });
}

function errorRedirect(path: string, message: string): never {
  redirect(path + "?error=" + encodeURIComponent(message));
}

export async function createPurchase(formData: FormData) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const contactId = String(formData.get("contact_id") || "").trim();
  const invoiceDate = String(formData.get("invoice_date") || "").trim() || null;
  const notes = String(formData.get("notes") || "").trim() || null;

  try {
    const items = parseItems(formData);
    const { data, error } = await supabase.rpc("create_purchase_draft", {
      p_organization_id: organizationId,
      p_contact_id: contactId,
      p_invoice_date: invoiceDate,
      p_notes: notes,
      p_items: items,
    });

    if (error) throw new Error(error.message);
    const purchaseId = String((data as { purchase_id?: string } | null)?.purchase_id || "");
    if (!purchaseId) throw new Error("Purchase was created without an ID.");
    redirect("/purchases/" + purchaseId);
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/purchases/new", error.message);
    errorRedirect("/purchases/new", "Unable to create purchase.");
  }
}

export async function updatePurchase(formData: FormData) {
  const { supabase } = await getWorkspaceMembership();
  const purchaseId = String(formData.get("purchase_id") || "").trim();
  const contactId = String(formData.get("contact_id") || "").trim();
  const invoiceDate = String(formData.get("invoice_date") || "").trim() || null;
  const notes = String(formData.get("notes") || "").trim() || null;

  try {
    const items = parseItems(formData);
    const { error } = await supabase.rpc("update_purchase_draft", {
      p_purchase_id: purchaseId,
      p_contact_id: contactId,
      p_invoice_date: invoiceDate,
      p_notes: notes,
      p_items: items,
    });

    if (error) throw new Error(error.message);
    redirect("/purchases/" + purchaseId);
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/purchases/" + purchaseId, error.message);
    errorRedirect("/purchases/" + purchaseId, "Unable to update purchase.");
  }
}

export async function confirmPurchase(formData: FormData) {
  const { supabase } = await getWorkspaceMembership();
  const purchaseId = String(formData.get("purchase_id") || "").trim();

  const { error } = await supabase.rpc("confirm_purchase", { p_purchase_id: purchaseId });
  if (error) errorRedirect("/purchases/" + purchaseId, error.message);
  redirect("/purchases/" + purchaseId);
}

export async function cancelPurchase(formData: FormData) {
  const { supabase } = await getWorkspaceMembership();
  const purchaseId = String(formData.get("purchase_id") || "").trim();

  const { error } = await supabase.rpc("cancel_purchase", { p_purchase_id: purchaseId });
  if (error) errorRedirect("/purchases/" + purchaseId, error.message);
  redirect("/purchases/" + purchaseId);
}
