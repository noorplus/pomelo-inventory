import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import WorkspaceShell from "@/app/components/workspace-shell";

export const dynamic = "force-dynamic";

export default async function NewProductPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).limit(1);
  if (!memberships?.length) redirect("/organization/create");

  const { data: units } = await supabase.from("units_of_measure").select("id, name").eq("organization_id", memberships[0].organization_id).eq("status", "Active").order("name");

  return (
    <WorkspaceShell active="products">
      <section className="form-page">
        <div className="form-page-header">
          <div><p className="eyebrow">PRODUCTS</p><h1>Add Product</h1><p className="muted">Create a product using an active unit of measure.</p></div>
          <Link className="secondary-button" href="/products">Back to Products</Link>
        </div>
        <section className="data-card">
          <form className="product-form product-form-page" action={createProduct}>
            <label>Product name<span className="required-mark">*</span><input name="product_name" placeholder="Product name" required /></label>
            <label>UoM<span className="required-mark">*</span><select name="uom_id" required><option value="">Select UoM</option>{units?.map((unit) => <option key={unit.id} value={unit.id}>{unit.name}</option>)}</select></label>
            <label>Retail price<span className="required-mark">*</span><div className="price-input"><span>৳</span><input name="retail_price" type="number" min="0" step="0.0001" placeholder="0.00" required /></div></label>
            <button className="primary-button" type="submit">Save Product</button>
          </form>
          {!units?.length && <div className="form-hint">No active UoM is available. Add a unit of measure first.</div>}
        </section>
      </section>
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

  const productName = String(formData.get("product_name") || "").trim();
  const uomId = String(formData.get("uom_id") || "");
  const retailPrice = Number(formData.get("retail_price") || 0);
  if (!productName || !uomId || !Number.isFinite(retailPrice) || retailPrice < 0) return;

  const { error } = await supabase.from("products").insert({
    organization_id: memberships[0].organization_id,
    product_name: productName,
    uom_id: uomId,
    retail_price: retailPrice,
    created_by: user.id,
  });

  if (error) return;
  redirect("/products");
}
