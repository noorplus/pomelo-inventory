import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import WorkspaceShell from "@/app/components/workspace-shell";

export const dynamic = "force-dynamic";

export default async function ProductsPage() {
  const supabase = await createClient();
  const { data: memberships } = await supabase.from("organization_users").select("organization_id").eq("user_id", (await supabase.auth.getUser()).data.user?.id || "").limit(1);
  if (!memberships?.length) redirect("/organization/create");
  const organizationId = memberships[0].organization_id;

  const [{ data: organization }, { data: products }, { data: units }] = await Promise.all([
    supabase.from("organizations").select("organization_name").eq("id", organizationId).single(),
    supabase.from("products").select("id, product_name, retail_price, status, created_at, uom_id").eq("organization_id", organizationId).order("product_name"),
    supabase.from("units_of_measure").select("id, name").eq("organization_id", organizationId).eq("status", "Active").order("name"),
  ]);

  return (
    <WorkspaceShell active="products">
      <header className="topbar"><div><p className="eyebrow">MASTER DATA</p><h1>Products</h1><p className="muted">Manage products and their retail prices for this organization.</p></div></header>
      <section className="data-card">
        <form className="product-form" action={createProduct}>
          <label>Product name<input name="product_name" placeholder="Product name" required /></label>
          <label>UoM<select name="uom_id" required><option value="">Select UoM</option>{units?.map((unit) => <option key={unit.id} value={unit.id}>{unit.name}</option>)}</select></label>
          <label>Retail price<input name="retail_price" type="number" min="0" step="0.0001" placeholder="0.00" required /></label>
          <button className="primary-button" type="submit">Add Product</button>
        </form>
      </section>
      <section className="section-heading"><div><h2>Product list</h2><p className="muted">{products?.length ?? 0} products in this organization.</p></div></section>
      <section className="table-card"><table><thead><tr><th>Product</th><th>UoM</th><th>Retail price</th><th>Status</th></tr></thead><tbody>{products?.map((product) => <tr key={product.id}><td><strong>{product.product_name}</strong></td><td>{units?.find((unit) => unit.id === product.uom_id)?.name || "—"}</td><td>{Number(product.retail_price).toFixed(2)}</td><td><span className="status-badge">{product.status}</span></td></tr>)}</tbody></table>{!products?.length && <div className="empty-state"><div className="empty-icon">▦</div><div><h2>No products yet</h2><p>Add a product after creating at least one active UoM.</p></div></div>}</section>
    </WorkspaceShell>
  );
}

async function createProduct(formData: FormData) {
  "use server";
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");
  const { data: memberships } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).limit(1);
  if (!memberships?.length) redirect("/organization/create");
  const organizationId = memberships[0].organization_id;
  const productName = String(formData.get("product_name") || "").trim();
  const uomId = String(formData.get("uom_id") || "");
  const retailPrice = Number(formData.get("retail_price") || 0);
  if (!productName || !uomId || !Number.isFinite(retailPrice) || retailPrice < 0) return;
  await supabase.from("products").insert({ organization_id: organizationId, product_name: productName, uom_id: uomId, retail_price: retailPrice, created_by: user.id });
  redirect("/products");
}
