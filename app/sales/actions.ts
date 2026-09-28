"use server";

import type { SupabaseClient } from "@supabase/supabase-js";

import { redirect } from "next/navigation";
import { getWorkspaceMembership } from "@/lib/auth/workspace";
import { createSaleDraft, deleteSaleDraft, updateSaleDraft } from "@/lib/services/sales";

type SaleItemInput = {
  id?: string;
  product_id: string;
  quantity: number;
  unit_price: number;
  discount?: number;
};

function parseItems(formData: FormData): SaleItemInput[] {
  const raw = String(formData.get("items_json") || "[]");
  let items: unknown;
  try { items = JSON.parse(raw); } catch { throw new Error("Invalid sale items."); }
  if (!Array.isArray(items) || !items.length) throw new Error("Add at least one product.");
  return items.map((item) => {
    const value = item as Record<string, unknown>;
    const quantity = Number(value.quantity);
    const unitPrice = Number(value.unit_price);
    const discount = Number(value.discount || 0);
    if (!value.product_id) throw new Error("Product must be selected.");
    if (isNaN(quantity) || quantity <= 0) throw new Error("Quantity must be greater than zero.");
    if (isNaN(unitPrice) || unitPrice < 0) throw new Error("Unit price cannot be negative.");
    if (isNaN(discount) || discount < 0) throw new Error("Discount cannot be negative.");
    if (discount > quantity * unitPrice) throw new Error("Item discount cannot exceed item gross amount.");
    return { id: value.id ? String(value.id) : undefined, product_id: String(value.product_id), quantity, unit_price: unitPrice, discount };
  });
}

function parseOverallDiscount(formData: FormData): number {
  const value = Number(formData.get("overall_discount") || 0);
  if (!Number.isFinite(value) || value < 0) throw new Error("Overall discount cannot be negative.");
  return value;
}

function getNetSubtotal(items: SaleItemInput[]) {
  const gross = items.reduce((sum, item) => sum + item.quantity * item.unit_price, 0);
  const itemDiscount = items.reduce((sum, item) => sum + Number(item.discount || 0), 0);
  return Math.max(0, gross - itemDiscount);
}

function errorRedirect(path: string, message: string): never {
  redirect(path + "?error=" + encodeURIComponent(message));
}

export async function createSale(formData: FormData) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const contactId = String(formData.get("contact_id") || "").trim();
  const invoiceDate = String(formData.get("invoice_date") || "").trim() || null;
  const notes = String(formData.get("notes") || "").trim() || null;
  let saleId = "";
  try {
    if (!contactId) throw new Error("Please select a customer contact.");
    const items = parseItems(formData);
    const overallDiscount = parseOverallDiscount(formData);
    ({ sale_id: saleId } = await createSaleDraft(supabase, { organizationId, contactId, invoiceDate, notes, items, overallDiscount }));
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/sales/new", error.message);
    errorRedirect("/sales/new", "Unable to create sale.");
  }
  redirect("/sales/" + saleId);
}

export async function updateSale(formData: FormData) {
  const { supabase } = await getWorkspaceMembership();
  const saleId = String(formData.get("sale_id") || "").trim();
  const contactId = String(formData.get("contact_id") || "").trim();
  const invoiceDate = String(formData.get("invoice_date") || "").trim() || null;
  const notes = String(formData.get("notes") || "").trim() || null;
  try {
    if (!saleId) throw new Error("Missing sale ID.");
    if (!contactId) throw new Error("Please select a customer contact.");
    const items = parseItems(formData);
    const overallDiscount = parseOverallDiscount(formData);
    await updateSaleDraft(supabase, { saleId, contactId, invoiceDate, notes, items, overallDiscount });
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
  const { supabase } = await getWorkspaceMembership();
  const saleId = String(formData.get("sale_id") || "").trim();
  try { await deleteSaleDraft(supabase, saleId); }
  catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/sales/" + saleId, error.message);
    errorRedirect("/sales/" + saleId, "Unable to delete sale.");
  }
  redirect("/sales");
}

export async function cloneSale(formData: FormData) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const sourceId = String(formData.get("sale_id") || "").trim();
  let newId = "";
  try {
    if (!sourceId) throw new Error("Missing sale ID.");
    const [{ data: source, error: sourceError }, { data: sourceItems, error: itemsError }] = await Promise.all([
      supabase.from("sales").select("contact_id, notes, total").eq("id", sourceId).eq("organization_id", organizationId).single(),
      supabase.from("sale_items").select("product_id, quantity, unit_price, discount").eq("sale_id", sourceId).eq("organization_id", organizationId),
    ]);
    if (sourceError || !source) throw new Error("Source sale not found.");
    if (itemsError) throw new Error(itemsError.message);
    if (!sourceItems?.length) throw new Error("Source sale has no items to clone.");
    const items = sourceItems.map((item) => ({ product_id: item.product_id, quantity: Number(item.quantity), unit_price: Number(item.unit_price), discount: Number(item.discount || 0) }));
    const overallDiscount = Math.max(0, getNetSubtotal(items) - Number(source.total || 0));
    ({ sale_id: newId } = await createSaleDraft(supabase, {
      organizationId,
      contactId: source.contact_id,
      invoiceDate: new Date().toISOString().split("T")[0],
      notes: source.notes,
      items,
      overallDiscount,
    }));
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/sales/" + sourceId, error.message);
    errorRedirect("/sales/" + sourceId, "Unable to clone sale.");
  }
  redirect("/sales/" + newId);
}
