import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";

export const dynamic = "force-dynamic";

type SearchParams = { error?: string };

export default async function NewProductPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const params = await searchParams;

  const { data: units, error: unitsError } = await supabase
    .from("units_of_measure")
    .select("id, name")
    .eq("organization_id", organizationId)
    .eq("status", "Active")
    .order("name");

  const errorMessage = params.error ? decodeURIComponent(params.error) : "";

  return (
    <WorkspaceShell active="products">
      <section className="form-page">
        <div className="form-page-header">
          <div>
            <p className="eyebrow">PRODUCTS</p>
            <h1>Add Product</h1>
            <p className="muted">Create a product with its unit of measure and current retail price.</p>
          </div>
          <Link className="secondary-button" href="/products">Back to Products</Link>
        </div>

        {unitsError ? (
          <section className="form-error" role="alert">Unable to load units of measure: {unitsError.message}</section>
        ) : !units?.length ? (
          <section className="form-error" role="alert">
            Add at least one active unit of measure before creating a product. <Link href="/uom">Go to UoM</Link>.
          </section>
        ) : (
          <section className="data-card">
            <form className="contact-form contact-form-page" action={createProduct}>
              <label>
                Product name<span className="required-mark">*</span>
                <input name="product_name" placeholder="Product name" required />
              </label>
              <label>
                Unit of measure<span className="required-mark">*</span>
                <select name="uom_id" defaultValue="" required>
                  <option value="" disabled>Select UoM</option>
                  {units.map((unit) => <option key={unit.id} value={unit.id}>{unit.name}</option>)}
                </select>
              </label>
              <label>
                Retail price<span className="required-mark">*</span>
                <div className="price-input">
                  <span>৳</span>
                  <input name="retail_price" type="number" min="0" step="0.01" inputMode="decimal" placeholder="0.00" required />
                </div>
              </label>
              {errorMessage && <div className="form-error contact-address" role="alert">{errorMessage}</div>}
              <button className="primary-button" type="submit">Save Product</button>
            </form>
          </section>
        )}
      </section>
    </WorkspaceShell>
  );
}

async function createProduct(formData: FormData) {
  "use server";

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .limit(1);

  if (!memberships?.length) redirect("/organization/create");

  const organizationId = memberships[0].organization_id;
  const productName = String(formData.get("product_name") || "").trim();
  const uomId = String(formData.get("uom_id") || "").trim();
  const retailPrice = Number(formData.get("retail_price"));

  if (!productName || !uomId || !Number.isFinite(retailPrice) || retailPrice < 0) {
    redirect("/products/new?error=" + encodeURIComponent("Please provide a product name, unit of measure, and a valid non-negative retail price."));
  }

  const { error } = await supabase.from("products").insert({
    organization_id: organizationId,
    product_name: productName,
    uom_id: uomId,
    retail_price: retailPrice,
    created_by: user.id,
  });

  if (error) {
    redirect("/products/new?error=" + encodeURIComponent(error.message));
  }

  redirect("/products");
}
