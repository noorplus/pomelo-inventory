import { getWorkspaceMembership } from "@/lib/auth/workspace";
import { csvResponse } from "@/lib/csv";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const url = new URL(request.url);
  const search = String(url.searchParams.get("search") || "").trim();
  const selectedUom = String(url.searchParams.get("uom_id") || "").trim();
  const status = url.searchParams.get("status") === "Inactive" ? "Inactive" : url.searchParams.get("status") === "Active" ? "Active" : "";

  let query = supabase
    .from("products")
    .select("product_name, retail_price, status, uom_id")
    .eq("organization_id", organizationId)
    .order("product_name");

  if (search) query = query.ilike("product_name", `%${search.replace(/[\\%_]/g, "\\$&")}%`);
  if (selectedUom) query = query.eq("uom_id", selectedUom);
  if (status) query = query.eq("status", status);

  const [{ data: products, error }, { data: units, error: unitsError }] = await Promise.all([
    query,
    supabase.from("units_of_measure").select("id, name").eq("organization_id", organizationId),
  ]);

  if (error || unitsError) {
    return Response.json({ error: error?.message || unitsError?.message || "Unable to export products." }, { status: 500 });
  }

  const unitMap = new Map((units ?? []).map((unit) => [unit.id, unit.name]));
  return csvResponse("products.csv", [
    ["Product Name", "UoM", "Retail Price", "Status"],
    ...(products ?? []).map((product) => [
      product.product_name,
      unitMap.get(product.uom_id) || "",
      product.retail_price,
      product.status,
    ]),
  ]);
}
