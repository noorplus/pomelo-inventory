import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import WorkspaceShell from "@/app/components/workspace-shell";

export const dynamic = "force-dynamic";

export default async function ProductsPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).limit(1);
  if (!memberships?.length) redirect("/organization/create");
  const organizationId = memberships[0].organization_id;

  const [{ data: products, error: productsError }, { data: units, error: unitsError }] = await Promise.all([
    supabase.from("products").select("id, product_name, retail_price, status, created_at, uom_id").eq("organization_id", organizationId).order("product_name"),
    supabase.from("units_of_measure").select("id, name").eq("organization_id", organizationId).eq("status", "Active").order("name"),
  ]);

  const unitMap = new Map((units ?? []).map((unit) => [unit.id, unit.name]));
  const error = productsError || unitsError;

  return (
    <WorkspaceShell active="products">
      <header className="topbar">
        <div><p className="eyebrow">MASTER DATA</p><h1>Products</h1><p className="muted">Manage products, units, and current retail prices.</p></div>
        <span className="page-count">{products?.length ?? 0} records</span>
      </header>

      <section className="data-card form-panel">
        <div className="panel-heading"><div><h2>Add product</h2><p className="muted">Create a product using an active unit of measure.</p></div></div>
        <form className="product-form" action={createProduct}>
          <label>Product name<span className="required-mark">*</span><input name="product_name" placeholder="Product name" required /></label>
          <label>UoM<span className="required-mark">*</span><select name="uom_id" required><option value="">Select UoM</option>{units?.map((unit) => <option key={unit.id} value={unit.id}>{unit.name}</option>)}</select></label>
          <label>Retail price<span className="required-mark">*</span><div className="price-input"><span>৳</span><input name="retail_price" type="number" min="0" step="0.0001" placeholder="0.00" required /></div></label>
          <button className="primary-button" type="submit">Add Product</button>
        </form>
        {!units?.length && <div className="form-hint">No active UoM is available. Add a unit of measure first.</div>}
      </section>

      <section className="section-heading"><div><h2>Product list</h2><p className="muted">All products belonging to this organization.</p></div></section>
      {error ? <section className="form-error" role="alert">Unable to load products: {error.message}</section> : (
        <section className="table-card">
          <div className="table-scroll"><table><thead><tr><th>Product</th><th>UoM</th><th className="numeric">Retail price</th><th>Status</th></tr></thead>
            <tbody>{products?.map((product) => <tr key={product.id}><td><strong>{product.product_name}</strong></td><td>{unitMap.get(product.uom_id) || "—"}</td><td className="numeric"><span className="price-value">৳{Number(product.retail_price).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</span></td><td><span className="status-badge">{product.status}</span></td></tr>)}</tbody>
          </table></div>
          {!products?.length && <EmptyState icon="▦" title="No products yet" text={units?.length ? "Add your first product above." : "Add an active UoM first, then create a product."} />}
        </section>
      )}
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

  const { error } = await supabase.from("products").insert({ organization_id: organizationId, product_name: productName, uom_id: uomId, retail_price: retailPrice, created_by: user.id });
  if (error) return;
  redirect("/products");
}

function EmptyState({ icon, title, text }: { icon: string; title: string; text: string }) {
  return <div className="empty-state"><div className="empty-icon">{icon}</div><div><h2>{title}</h2><p>{text}</p></div></div>;
}
