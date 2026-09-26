"use server";

import { redirect } from "next/navigation";
import { getWorkspaceMembership } from "@/lib/auth/workspace";
import { ServiceError } from "@/lib/services/common";
import { createSaleDraft, deleteSaleDraft, updateSaleDraft } from "@/lib/services/sales";
import type { SupabaseClient } from "@supabase/supabase-js";

type SaleItemInput = {
  id?: string;
  product_id: string;
  quantity: number;
  unit_price: number;
  discount?: number;
  tax?: number;
};

function parseItems(formData: FormData): SaleItemInput[] {
  const raw = String(formData.get("items_json") || "[]");
  let items: unknown;

  try {
    items = JSON.parse(raw);
  } catch {
    throw new Error("Invalid sale items.");
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
// draft RPC migration: they preserve the exact previously-working behavior.
// Once migrations apply, the atomic RPC path is used and these go dormant.
async function legacyCreateSale(
  supabase: SupabaseClient,
  organizationId: string,
  userId: string,
  contactId: string,
  invoiceDate: string | null,
  notes: string | null,
  items: SaleItemInput[],
): Promise<string> {
  const subtotal = items.reduce((sum, item) => sum + item.quantity * item.unit_price, 0);
  const totalDiscount = items.reduce((sum, item) => sum + (item.discount || 0), 0);
  const totalTax = items.reduce((sum, item) => sum + (item.tax || 0), 0);
  const total = subtotal - totalDiscount + totalTax;

  const { data: sale, error: saleError } = await supabase
    .from("sales")
    .insert({
      organization_id: organizationId,
      contact_id: contactId,
      invoice_date: invoiceDate || new Date().toISOString().split("T")[0],
      status: "Draft",
      invoice_no: "000000",
      subtotal,
      discount: totalDiscount,
      tax: totalTax,
      total,
      notes,
      created_by: userId,
    })
    .select("id")
    .single();

  if (saleError) throw new Error(saleError.message);
  const saleId = sale.id as string;

  const { error: itemsError } = await supabase.from("sale_items").insert(
    items.map((item) => ({
      organization_id: organizationId,
      sale_id: saleId,
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
    await supabase.from("sales").delete().eq("id", saleId);
    throw new Error(itemsError.message);
  }
  return saleId;
}

async function legacyUpdateSale(
  supabase: SupabaseClient,
  organizationId: string,
  userId: string,
  saleId: string,
  contactId: string,
  invoiceDate: string | null,
  notes: string | null,
  items: SaleItemInput[],
): Promise<void> {
  const subtotal = items.reduce((sum, item) => sum + item.quantity * item.unit_price, 0);
  const totalDiscount = items.reduce((sum, item) => sum + (item.discount || 0), 0);
  const totalTax = items.reduce((sum, item) => sum + (item.tax || 0), 0);
  const total = subtotal - totalDiscount + totalTax;

  const { error: saleError } = await supabase
    .from("sales")
    .update({
      contact_id: contactId,
      invoice_date: invoiceDate || new Date().toISOString().split("T")[0],
      subtotal,
      discount: totalDiscount,
      tax: totalTax,
      total,
      notes,
    })
    .eq("id", saleId)
    .eq("organization_id", organizationId)
    .eq("status", "Draft");

  if (saleError) throw new Error(saleError.message);

  await supabase.from("sale_items").delete().eq("sale_id", saleId).eq("organization_id", organizationId);

  const { error: itemsError } = await supabase.from("sale_items").insert(
    items.map((item) => ({
      organization_id: organizationId,
      sale_id: saleId,
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

async function legacyDeleteSale(
  supabase: SupabaseClient,
  organizationId: string,
  saleId: string,
): Promise<void> {
  const { error } = await supabase
    .from("sales")
    .delete()
    .eq("id", saleId)
    .eq("organization_id", organizationId)
    .eq("status", "Draft");
  if (error) throw new Error(error.message);
}

export async function createSale(formData: FormData) {
  const { supabase, organizationId, user } = await getWorkspaceMembership();
  const contactId = String(formData.get("contact_id") || "").trim();
  const invoiceDate = String(formData.get("invoice_date") || "").trim() || null;
  const notes = String(formData.get("notes") || "").trim() || null;

  let saleId = "";

  try {
    if (!contactId) throw new Error("Please select a customer.");
    const items = parseItems(formData);

    try {
      // Single atomic transaction server-side: header + lines, server totals.
      ({ sale_id: saleId } = await createSaleDraft(supabase, {
        organizationId,
        contactId,
        invoiceDate,
        notes,
        items,
      }));
    } catch (error) {
      if (!isMissingRpc(error)) throw error;
      saleId = await legacyCreateSale(supabase, organizationId, user.id, contactId, invoiceDate, notes, items);
    }
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/sales/new", error.message);
    errorRedirect("/sales/new", "Unable to create sale.");
  }

  redirect("/sales/" + saleId);
}

export async function updateSale(formData: FormData) {
  const { supabase, organizationId, user } = await getWorkspaceMembership();
  const saleId = String(formData.get("sale_id") || "").trim();
  const contactId = String(formData.get("contact_id") || "").trim();
  const invoiceDate = String(formData.get("invoice_date") || "").trim() || null;
  const notes = String(formData.get("notes") || "").trim() || null;

  try {
    if (!saleId) throw new Error("Missing sale ID.");
    if (!contactId) throw new Error("Please select a customer.");
    const items = parseItems(formData);

    try {
      // Single atomic transaction server-side; line creators stay immutable.
      await updateSaleDraft(supabase, {
        saleId,
        contactId,
        invoiceDate,
        notes,
        items,
      });
    } catch (error) {
      if (!isMissingRpc(error)) throw error;
      await legacyUpdateSale(supabase, organizationId, user.id, saleId, contactId, invoiceDate, notes, items);
    }
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/sales/" + saleId, error.message);
    errorRedirect("/sales/" + saleId, "Unable to update sale.");
  }

  redirect("/sales/" + saleId);
}

export async function confirmSale(formData: FormData) {
  const { supabase } = await getWorkspaceMembership();
  const saleId = String(formData.get("sale_id") || "").trim();

  const { error } = await supabase.rpc("confirm_sale", { p_sale_id: saleId });
  if (error) errorRedirect("/sales/" + saleId, error.message);
  redirect("/sales/" + saleId);
}

export async function cancelSale(formData: FormData) {
  const { supabase } = await getWorkspaceMembership();
  const saleId = String(formData.get("sale_id") || "").trim();

  const { error } = await supabase.rpc("cancel_sale", { p_sale_id: saleId });
  if (error) errorRedirect("/sales/" + saleId, error.message);
  redirect("/sales/" + saleId);
}

export async function deleteSale(formData: FormData) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const saleId = String(formData.get("sale_id") || "").trim();

  try {
    try {
      await deleteSaleDraft(supabase, saleId);
    } catch (error) {
      if (!isMissingRpc(error)) throw error;
      await legacyDeleteSale(supabase, organizationId, saleId);
    }
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/sales/" + saleId, error.message);
    errorRedirect("/sales/" + saleId, "Unable to delete sale.");
  }
  redirect("/sales");
}

export async function cloneSale(formData: FormData) {
  const { supabase, organizationId, user } = await getWorkspaceMembership();
  const sourceId = String(formData.get("sale_id") || "").trim();

  let newId = "";

  try {
    if (!sourceId) throw new Error("Missing sale ID.");

    const [{ data: source, error: sourceError }, { data: sourceItems, error: itemsError }] = await Promise.all([
      supabase
        .from("sales")
        .select("contact_id, subtotal, discount, tax, total, notes")
        .eq("id", sourceId)
        .eq("organization_id", organizationId)
        .single(),
      supabase
        .from("sale_items")
        .select("product_id, quantity, unit_price, discount, tax, line_total")
        .eq("sale_id", sourceId)
        .eq("organization_id", organizationId),
    ]);

    if (sourceError || !source) throw new Error("Source sale not found.");
    if (itemsError) throw new Error(itemsError.message);
    if (!sourceItems?.length) throw new Error("Source sale has no items to clone.");

    const { data: created, error: createError } = await supabase
      .from("sales")
      .insert({
        organization_id: organizationId,
        contact_id: source.contact_id,
        invoice_date: new Date().toISOString().split("T")[0],
        status: "Draft",
        invoice_no: "000000", // Automatically replaced by trigger set_sales_invoice_no
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

    const { error: linesError } = await supabase.from("sale_items").insert(
      sourceItems.map((item) => ({
        organization_id: organizationId,
        sale_id: newId,
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
      await supabase.from("sales").delete().eq("id", newId);
      throw new Error(linesError.message);
    }
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/sales/" + sourceId, error.message);
    errorRedirect("/sales/" + sourceId, "Unable to clone sale.");
  }

  redirect("/sales/" + newId);
}
