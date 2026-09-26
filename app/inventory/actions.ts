"use server";

import { redirect } from "next/navigation";
import { getWorkspaceMembership } from "@/lib/auth/workspace";
import { recordStockAdjustment } from "@/lib/services/inventory";

function errorRedirect(message: string): never {
  redirect("/inventory/adjust?error=" + encodeURIComponent(message));
}

export async function adjustStock(formData: FormData) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const productId = String(formData.get("product_id") || "").trim();
  const movementType = String(formData.get("movement_type") || "").trim();
  const direction = String(formData.get("direction") || "").trim();
  const quantity = Number(formData.get("quantity") || 0);
  const unitCostRaw = String(formData.get("unit_cost") || "").trim();
  const unitCost = unitCostRaw === "" ? null : Number(unitCostRaw);

  try {
    if (!productId) throw new Error("Please select a product.");
    if (!["Opening", "Adjustment"].includes(movementType)) throw new Error("Invalid movement type.");
    if (!["In", "Out"].includes(direction)) throw new Error("Invalid direction.");
    if (!Number.isFinite(quantity) || quantity <= 0) throw new Error("Quantity must be greater than zero.");
    if (unitCost !== null && (!Number.isFinite(unitCost) || unitCost < 0)) throw new Error("Unit cost cannot be negative.");

    await recordStockAdjustment(supabase, {
      organizationId,
      productId,
      quantity,
      direction: direction as "In" | "Out",
      movementType: movementType as "Opening" | "Adjustment",
      unitCost,
    });
  } catch (error) {
    if (error instanceof Error && error.message) errorRedirect(error.message);
    errorRedirect("Unable to record stock adjustment.");
  }

  redirect("/inventory?tab=movements");
}
