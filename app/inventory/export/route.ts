import { getWorkspaceMembership } from "@/lib/auth/workspace";
import { csvResponse } from "@/lib/csv";

export const dynamic = "force-dynamic";

export async function GET() {
  const { supabase, organizationId } = await getWorkspaceMembership();

  const [{ data: products, error: productsError }, { data: stockItems, error: stockError }] = await Promise.all([
    supabase
      .from("products")
      .select("id, product_name, retail_price, status")
      .eq("organization_id", organizationId)
      .order("product_name")
      .limit(2000),
    supabase.from("stock").select("product_id, quantity").eq("organization_id", organizationId).limit(5000),
  ]);

  if (productsError) return Response.json({ error: productsError.message || "Unable to export stock." }, { status: 500 });
  if (stockError) return Response.json({ error: stockError.message || "Unable to export stock." }, { status: 500 });

  const stockMap = new Map((stockItems ?? []).map((s) => [s.product_id, Number(s.quantity || 0)]));

  return csvResponse("stock.csv", [
    ["Product", "Retail Price", "Stock on Hand", "Status"],
    ...(products ?? []).map((p) => [
      p.product_name,
      String(p.retail_price),
      String(stockMap.get(p.id) ?? 0),
      p.status,
    ]),
  ]);
}
