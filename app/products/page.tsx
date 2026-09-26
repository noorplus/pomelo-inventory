import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import WorkspaceShell from "@/app/components/workspace-shell";

export const dynamic = "force-dynamic";

type SearchParams = { search?: string; uom_id?: string; status?: string };

export default async function ProductsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).limit(1);
  if (!memberships?.length) redirect("/organization/create");

  const organizationId = memberships[0].organization_id;
  const params = await searchParams;
  const search = String(params.search || "").trim();
  const selectedUom = String(params.uom_id || "").trim();
  const status = params.status === "Inactive" ? "Inactive" : params.status === "Active" ? "Active" : "";

  const [{ data: units, error: unitsError }, productsResult] = await Promise.all([
    supabase.from("units_of_measure").select("id, name").eq("organization_id", organizationId).order("name"),
    supabase.from("products").select("id, product_name, retail_price, status, created_at, uom_id").eq("organization_id", organizationId).order("product_name"),
  ]);

  const products = (productsResult.data ?? []).filter((product) => {
    const matchesSearch = !search || product.product_name.toLowerCase().includes(search.toLowerCase());
    const matchesUom = !selectedUom || product.uom_id === selectedUom;
    const matchesStatus = !status || product.status === status;
    return matchesSearch && matchesUom && matchesStatus;
  });
  const error = productsResult.error || unitsError;
  const unitMap = new Map((units ?? []).map((unit) => [unit.id, unit.name]));

  return (
    <WorkspaceShell active="products">
      <section className="module-toolbar">
        <div><h1>Products</h1><p className="muted">Products, units, and current retail prices.</p></div>
        <Link className="primary-button" href="/products/new">+ Add Product</Link>
      </section>

      <section className="filter-card" aria-label="Product filters">
        <form className="contact-filter" method="get">
          <label>Search<input name="search" defaultValue={search} placeholder="Product name" /></label>
          <label>UoM<select name="uom_id" defaultValue={selectedUom}><option value="">All UoM</option>{units?.map((unit) => <option key={unit.id} value={unit.id}>{unit.name}</option>)}</select></label>
          <label>Status<select name="status" defaultValue={status}><option value="">All statuses</option><option value="Active">Active</option><option value="Inactive">Inactive</option></select></label>
          <button className="secondary-button" type="submit">Filter</button>
          {(search || selectedUom || status) && <Link className="filter-clear" href="/products">Clear</Link>}
        </form>
      </section>

      {error ? <section className="form-error" role="alert">Unable to load products: {error.message}</section> : (
        <section className="table-card">
          <div className="table-meta"><strong>{products.length} product{products.length === 1 ? "" : "s"}</strong>{(search || selectedUom || status) && <span>Filtered results</span>}</div>
          <div className="table-scroll"><table><thead><tr><th>Product</th><th>UoM</th><th className="numeric">Retail price</th><th>Status</th></tr></thead>
            <tbody>{products.map((product) => <tr key={product.id}><td><strong>{product.product_name}</strong></td><td>{unitMap.get(product.uom_id) || "—"}</td><td className="numeric"><span className="price-value">৳{Number(product.retail_price).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</span></td><td><span className="status-badge">{product.status}</span></td></tr>)}</tbody>
          </table></div>
          {!products.length && <EmptyState icon="▦" title="No products found" text={search || selectedUom || status ? "Try changing your filters." : "Add your first product."} />}
        </section>
      )}
    </WorkspaceShell>
  );
}

function EmptyState({ icon, title, text }: { icon: string; title: string; text: string }) {
  return <div className="empty-state"><div className="empty-icon">{icon}</div><div><h2>{title}</h2><p>{text}</p></div></div>;
}
