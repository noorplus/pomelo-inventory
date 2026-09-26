"use server";

import { redirect } from "next/navigation";
import { getWorkspaceMembership } from "@/lib/auth/workspace";
import { nextExpenseNoResilient } from "@/lib/services/expenses";
import { nextPaymentNoResilient } from "@/lib/services/payments";

function errorRedirect(path: string, message: string): never {
  redirect(path + "?error=" + encodeURIComponent(message));
}

export async function createPayment(formData: FormData) {
  const { supabase, organizationId, user } = await getWorkspaceMembership();
  const paymentType = String(formData.get("payment_type") || "").trim();
  const contactId = String(formData.get("contact_id") || "").trim() || null;
  const paymentDate = String(formData.get("payment_date") || "").trim() || new Date().toISOString().split("T")[0];
  const amount = Number(formData.get("amount") || 0);
  const paymentMethod = String(formData.get("payment_method") || "Cash").trim();
  const referenceNo = String(formData.get("reference_no") || "").trim() || null;
  const notes = String(formData.get("notes") || "").trim() || null;
  const targetKind = String(formData.get("target_kind") || "").trim().toLowerCase();
  const targetId = String(formData.get("target_id") || "").trim();
  const target =
    ["sale", "purchase", "expense"].includes(targetKind) && /^[0-9a-f-]{36}$/i.test(targetId)
      ? `?target=${targetKind}:${targetId}`
      : "";
  const newPath =
    "/accounting/payments/new" + (target ? `?target_kind=${targetKind}&target_id=${targetId}` : "");

  let paymentId = "";

  try {
    if (!["In", "Out"].includes(paymentType)) throw new Error("Invalid payment type. Must be In or Out.");
    if (isNaN(amount) || amount <= 0) throw new Error("Payment amount must be greater than zero.");
    if (!["Cash", "Bank", "Mobile Banking", "Card", "Other"].includes(paymentMethod)) {
      throw new Error("Invalid payment method.");
    }

    // Numbering retries on unique violations: after deleted rows or under
    // concurrent creates a candidate number may already exist, so each retry
    // advances it. (The serialized RPC path never collides, so this loop
    // exits on the first try once migrations are applied.)
    for (let attempt = 0; attempt < 8 && !paymentId; attempt++) {
      const paymentNo = await nextPaymentNoResilient(supabase, organizationId, attempt);

      const { data: payment, error } = await supabase
        .from("payments")
        .insert({
          organization_id: organizationId,
          payment_no: paymentNo,
          payment_date: paymentDate,
          payment_type: paymentType as "In" | "Out",
          contact_id: contactId,
          amount,
          payment_method: paymentMethod as "Cash" | "Bank" | "Mobile Banking" | "Card" | "Other",
          reference_no: referenceNo,
          status: "Draft",
          notes,
          created_by: user.id,
        })
        .select("id")
        .single();

      if (!error) {
        paymentId = payment.id;
      } else if (error.code === "23505" && attempt < 7) {
        continue;
      } else {
        throw new Error(error.message);
      }
    }

    if (!paymentId) throw new Error("Unable to create payment.");
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect(newPath, error.message);
    errorRedirect(newPath, "Unable to create payment.");
  }

  redirect("/accounting/payments/" + paymentId + target);
}

export async function confirmPaymentAction(formData: FormData) {
  const { supabase } = await getWorkspaceMembership();
  const paymentId = String(formData.get("payment_id") || "").trim();
  const allocationsJson = String(formData.get("allocations_json") || "[]");

  let allocations: unknown;
  try {
    allocations = JSON.parse(allocationsJson);
    if (!Array.isArray(allocations) || !allocations.length) {
      throw new Error("Payment confirmation requires at least one allocation.");
    }
  } catch {
    errorRedirect("/accounting/payments/" + paymentId, "Invalid allocations payload.");
  }

  const { error } = await supabase.rpc("confirm_payment", {
    p_payment_id: paymentId,
    p_allocations: allocations,
  });

  if (error) errorRedirect("/accounting/payments/" + paymentId, error.message);
  redirect("/accounting/payments/" + paymentId);
}

export async function cancelPaymentAction(formData: FormData) {
  const { supabase } = await getWorkspaceMembership();
  const paymentId = String(formData.get("payment_id") || "").trim();

  const { error } = await supabase.rpc("cancel_payment", { p_payment_id: paymentId });
  if (error) errorRedirect("/accounting/payments/" + paymentId, error.message);
  redirect("/accounting/payments/" + paymentId);
}

export async function deletePaymentDraft(formData: FormData) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const paymentId = String(formData.get("payment_id") || "").trim();

  const { error } = await supabase
    .from("payments")
    .delete()
    .eq("id", paymentId)
    .eq("organization_id", organizationId)
    .eq("status", "Draft");

  if (error) errorRedirect("/accounting/payments/" + paymentId, error.message);
  redirect("/accounting?tab=payments");
}

export async function createExpense(formData: FormData) {
  const { supabase, organizationId, user } = await getWorkspaceMembership();
  const categoryId = String(formData.get("expense_category_id") || "").trim();
  const contactId = String(formData.get("contact_id") || "").trim() || null;
  const expenseDate = String(formData.get("expense_date") || "").trim() || new Date().toISOString().split("T")[0];
  const description = String(formData.get("description") || "").trim();
  const amount = Number(formData.get("amount") || 0);
  const notes = String(formData.get("notes") || "").trim() || null;

  let expenseId = "";

  try {
    if (!categoryId) throw new Error("Please select an expense category.");
    if (!description) throw new Error("Expense description is required.");
    if (isNaN(amount) || amount <= 0) throw new Error("Amount must be greater than zero.");

    for (let attempt = 0; attempt < 8 && !expenseId; attempt++) {
      const expenseNo = await nextExpenseNoResilient(supabase, organizationId, attempt);

      const { data: expense, error } = await supabase
        .from("expenses")
        .insert({
          organization_id: organizationId,
          expense_no: expenseNo,
          expense_date: expenseDate,
          expense_category_id: categoryId,
          contact_id: contactId,
          description,
          amount,
          status: "Draft",
          notes,
          created_by: user.id,
        })
        .select("id")
        .single();

      if (!error) {
        expenseId = expense.id;
      } else if (error.code === "23505" && attempt < 7) {
        continue;
      } else {
        throw new Error(error.message);
      }
    }

    if (!expenseId) throw new Error("Unable to create expense.");
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/accounting/expenses/new", error.message);
    errorRedirect("/accounting/expenses/new", "Unable to create expense.");
  }

  redirect("/accounting/expenses/" + expenseId);
}

export async function confirmExpenseAction(formData: FormData) {
  const { supabase } = await getWorkspaceMembership();
  const expenseId = String(formData.get("expense_id") || "").trim();

  const { error } = await supabase.rpc("confirm_expense", { p_expense_id: expenseId });
  if (error) errorRedirect("/accounting/expenses/" + expenseId, error.message);
  redirect("/accounting/expenses/" + expenseId);
}

export async function cancelExpenseAction(formData: FormData) {
  const { supabase } = await getWorkspaceMembership();
  const expenseId = String(formData.get("expense_id") || "").trim();

  const { error } = await supabase.rpc("cancel_expense", { p_expense_id: expenseId });
  if (error) errorRedirect("/accounting/expenses/" + expenseId, error.message);
  redirect("/accounting/expenses/" + expenseId);
}

export async function deleteExpenseDraft(formData: FormData) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const expenseId = String(formData.get("expense_id") || "").trim();

  const { error } = await supabase
    .from("expenses")
    .delete()
    .eq("id", expenseId)
    .eq("organization_id", organizationId)
    .eq("status", "Draft");

  if (error) errorRedirect("/accounting/expenses/" + expenseId, error.message);
  redirect("/accounting?tab=expenses");
}

export async function createExpenseCategory(formData: FormData) {
  const { supabase, organizationId, user } = await getWorkspaceMembership();
  const name = String(formData.get("name") || "").trim();

  try {
    if (!name) throw new Error("Category name is required.");

    const { error } = await supabase.from("expense_categories").insert({
      organization_id: organizationId,
      name,
      status: "Active",
      created_by: user.id,
    });

    if (error) throw new Error(error.message);
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect("/accounting?tab=categories", error.message);
    errorRedirect("/accounting?tab=categories", "Unable to create category.");
  }

  redirect("/accounting?tab=categories");
}
