"use server";

import { redirect } from "next/navigation";
import { getWorkspaceMembership } from "@/lib/auth/workspace";
import { ServiceError } from "@/lib/services/common";
import { createPurchaseDraft, deletePurchaseDraft, updatePurchaseDraft } from "@/lib/services/purchases";
import type { SupabaseClient } from "@supabase/supabase-js";

type PurchaseItemInput = {
  id?: string;
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
    const quantity = Number(value.quantity);
    const unitPrice = Number(value.unit_price);
    const discount = Number(value.discount || 0);
    const tax = Number(value.tax || 0);

    if (!value.product_id) throw new Error("Product must be selected.");
    if (isNaN(quantity) || quantity <= 0) throw new Error("Quantity must be greater than zero.");
    if (isNaN(unitPrice) || unitPrice < 0) throw new Error("Unit price cannot be negative.");
    if (isNaN(discount) || discount < 0) throw new Error("Discount cannot be negative.");
    if (discount > quantity * unitPrice) throw new Error("Item discount cannot exceed item gross amount.");
    if (isNaN(tax) || tax < 0) throw new Error("Tax cannot be negative.");

    return {
      id: value.id ? String(value.id) : undefined,
      product_id: String(value.product_id),
      quantity,
      unit_price: unitPrice,
      discount,
      tax,
    };
  });
}

function errorRedirect(path: string, message: string): never {
  redirect(path + "?error=" + encodeURIComponent(message));
}

function isMissingRpc(error: unknown): boolean {
  return error instanceof ServiceError && error.code === "PGRST202";
}

// Legacy direct-write paths. Used only when the live database predates the
// draft RPC migration: they preserve the exact previously-working behavior
// (client totals, compensating delete on create failure). Once migrations
// apply, the atomic RPC path above is used and these go dormant.
async function legacyCreatePurchase(
  supabase: SupabaseClient,
  organizationId: string,
  userId: string,
  contactId: string,
  invoiceDate: string | null,
  notes: string | null,
  items: PurchaseItemInput[],
): Promise<string> {
  const subtotal = items.reduce((sum, item) => sum + item.quantity * item.unit_price, 0);
  const totalDiscount = items.reduce((sum, item) => sum + (item.discount || 0), 0);
  const totalTax = items.reduce((sum, item) => sum + (item.tax || 0), 0);
  const total = subtotal - totalDiscount + totalTax;

  const { data: purchase, error: purchaseError } = await supabase
    .from("purchases")
    .insert({
      organization_id: organizationId,
      contact_id: contactId,
      invoice_date: invoiceDate || new Date().toISOString().split("T")[0],
      status: "Draft",
      invoice_no: "000000", // Automatically replaced by trigger set_purchase_invoice_no
      subtotal,
      discount: totalDiscount,
      tax: totalTax,
      total,
      notes,
      created_by: userId,
    })
    .select("id")
    .single();

  if (purchaseError) throw new Error(purchaseError.message);
  const purchaseId = purchase.id as string;

  const { error: itemsError } = await supabase.from("purchase_items").insert(
    items.map((item) => ({
      organization_id: organizationId,
      purchase_id: purchaseId,
      product_id: item.product_id,
      quantity: item.quantity,
      unit_price: item.unit_price,
      discount: item.discount || 0,
      tax: item.tax || 0,
      line_total: item.quantity * item.unit_price - (item.discount || 0) + (item.tax || 0),
      created_by: userId,
    })),
  );
  if (itemsError) {
    await supabase.from("purchases").delete().eq("id", purchaseId);
    throw new Error(itemsError.message);
  }
  return purchaseId;
}

async function legacyUpdatePurchase(
  supabase: SupabaseClient,
  organizationId: string,
  userId: string,
  purchaseId: string,
  contactId: string,
  invoiceDate: string | null,
  notes: string | null,
  items: PurchaseItemInput[],
): Promise<void> {
  const subtotal = items.reduce((sum, item) => sum + item.quantity * item.unit_price, 0);
  const totalDiscount = items.reduce((sum, item) => sum + (item.discount || 0), 0);
  const totalTax = items.reduce((sum, item) => sum + (item.tax || 0), 0);
  const total = subtotal - totalDiscount + totalTax;

  const { error: purchaseError } = await supabase
    .from("purchases")
    .update({
      contact_id: contactId,
      invoice_date: invoiceDate || new Date().toISOString().split("T")[0],
      subtotal,
      discount: totalDiscount,
      tax: totalTax,
      total,
      notes,
    })
    .eq("id", purchaseId)
    .eq("organization_id", organizationId)
    .eq("status", "Draft");

  if (purchaseError) throw new Error(purchaseError.message);

  await supabase
    .from("purchase_items")
    .delete()
    .eq("purchase_id", purchaseId)
    .eq("organization_id", organizationId);

  const { error: itemsError } = await supabase.from("purchase_items").insert(
    items.map((item) => ({
      organization_id: organizationId,
      purchase_id: purchaseId,
      product_id: item.product_id,
      quantity: item.quantity,
      unit_price: item.unit_price,
      discount: item.discount || 0,
      tax: item.tax || 0,
      line_total: item.quantity * item.unit_price - (item.discount || 0) + (item.tax || 0),
      created_by: userId,
    })),
  );
  if (itemsError) throw new Error(itemsError.message);
}

async function legacyDeletePurchase(
  supabase: SupabaseClient,
  organizationId: string,
  purchaseId: string,
): Promise<void> {
  const { error } = await supabase
    .from("purchases")
    .delete()
    .eq("id", purchaseId)
    .eq("organization_id", organizationId)
    .eq("status", "Draft");
  if (error) throw new Error(error.message);
}

export async function createPurchase(formData: FormData) {
  const { supabase, organizationId, user } = await getWorkspaceMembership();
  const contactId = String(formData.get("contact_id") || "").trim();
  const invoiceDate = String(formData.get("invoice_date") || "").trim() || null;
  const notes = String(formData.get("notes") || "").trim() || null;

  let purchaseId = "";

  try {
    if (!contactId) throw new Error("Please select a supplier contact.");
    const items = parseItems(formData);

    try {
      // Single atomic transaction server-side: header + lines, server totals.
      ({ purchase_id: purchaseId } = await createPurchaseDraft(supabase, {
        organizationId,
        contactId,
        invoiceDate,
        notes,
        items,
      }));
    } catch (error) {
      if (!isMissingRpc(error)) throw error;
      purchaseId = await legacyCreatePurchase(supabase, organizationId, user.id, contactId, invoiceDate, notes, items);
    }
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/purchases/new", error.message);
    errorRedirect("/purchases/new", "Unable to create purchase.");
  }

  redirect("/purchases/" + purchaseId);
}

export async function updatePurchase(formData: FormData) {
  const { supabase, organizationId, user } = await getWorkspaceMembership();
  const purchaseId = String(formData.get("purchase_id") || "").trim();
  const contactId = String(formData.get("contact_id") || "").trim();
  const invoiceDate = String(formData.get("invoice_date") || "").trim() || null;
  const notes = String(formData.get("notes") || "").trim() || null;

  try {
    if (!purchaseId) throw new Error("Missing purchase ID.");
    if (!contactId) throw new Error("Please select a supplier contact.");
    const items = parseItems(formData);

    try {
      // Single atomic transaction server-side; line creators stay immutable.
      await updatePurchaseDraft(supabase, {
        purchaseId,
        contactId,
        invoiceDate,
        notes,
        items,
      });
    } catch (error) {
      if (!isMissingRpc(error)) throw error;
      await legacyUpdatePurchase(supabase, organizationId, user.id, purchaseId, contactId, invoiceDate, notes, items);
    }
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/purchases/" + purchaseId, error.message);
    errorRedirect("/purchases/" + purchaseId, "Unable to update purchase.");
  }

  redirect("/purchases/" + purchaseId);
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

export async function deletePurchase(formData: FormData) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const purchaseId = String(formData.get("purchase_id") || "").trim();

  try {
    try {
      await deletePurchaseDraft(supabase, purchaseId);
    } catch (error) {
      if (!isMissingRpc(error)) throw error;
      await legacyDeletePurchase(supabase, organizationId, purchaseId);
    }
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/purchases/" + purchaseId, error.message);
    errorRedirect("/purchases/" + purchaseId, "Unable to delete purchase.");
  }
  redirect("/purchases");
}

export async function clonePurchase(formData: FormData) {
  const { supabase, organizationId, user } = await getWorkspaceMembership();
  const sourceId = String(formData.get("purchase_id") || "").trim();

  let newId = "";

  try {
    if (!sourceId) throw new Error("Missing purchase ID.");

    const [{ data: source, error: sourceError }, { data: sourceItems, error: itemsError }] = await Promise.all([
      supabase
        .from("purchases")
        .select("contact_id, subtotal, discount, tax, total, notes")
        .eq("id", sourceId)
        .eq("organization_id", organizationId)
        .single(),
      supabase
        .from("purchase_items")
        .select("product_id, quantity, unit_price, discount, tax, line_total")
        .eq("purchase_id", sourceId)
        .eq("organization_id", organizationId),
    ]);

    if (sourceError || !source) throw new Error("Source purchase not found.");
    if (itemsError) throw new Error(itemsError.message);
    if (!sourceItems?.length) throw new Error("Source purchase has no items to clone.");

    const { data: created, error: createError } = await supabase
      .from("purchases")
      .insert({
        organization_id: organizationId,
        contact_id: source.contact_id,
        invoice_date: new Date().toISOString().split("T")[0],
        status: "Draft",
        invoice_no: "000000", // Automatically replaced by trigger set_purchase_invoice_no
        subtotal: source.subtotal,
        discount: source.discount,
        tax: source.tax,
        total: source.total,
        notes: source.notes,
        created_by: user.id,
      })
      .select("id")
      .single();

    if (createError) throw new Error(createError.message);
    newId = created.id;

    const { error: linesError } = await supabase.from("purchase_items").insert(
      sourceItems.map((item) => ({
        organization_id: organizationId,
        purchase_id: newId,
        product_id: item.product_id,
        quantity: item.quantity,
        unit_price: item.unit_price,
        discount: item.discount,
        tax: item.tax,
        line_total: item.line_total,
        created_by: user.id,
      })),
    );

    if (linesError) {
      await supabase.from("purchases").delete().eq("id", newId);
      throw new Error(linesError.message);
    }
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/purchases/" + sourceId, error.message);
    errorRedirect("/purchases/" + sourceId, "Unable to clone purchase.");
  }

  redirect("/purchases/" + newId);
}
