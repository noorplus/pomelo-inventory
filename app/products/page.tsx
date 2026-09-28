import Link from "next/link";
import CsvActions from "@/app/components/csv-actions";
import WorkspaceShell from "@/app/components/workspace-shell";
import Pager from "@/app/components/pager";
import SortableHeader from "@/app/components/sortable-header";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { PAGE_SIZE, pageRange, parsePageParam } from "@/lib/pagination";

export const dynamic = "force-dynamic";

type SearchParams = { search?: string; uom_id?: string; status?: string; sort?: string; direction?: string; page?: string };

export default async function ProductsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const params = await searchParams;
  const search = String(params.search || "").trim();
  const selectedUom = String(params.uom_id || "").trim();
  const status = params.status === "Inactive" ? "Inactive" : params.status === "Active" ? "Active" : "";
  const sort = ["product_name", "uom_id", "retail_price", "status"].includes(params.sort || "") ? String(params.sort) : "product_name";
  const direction = params.direction === "desc" ? "desc" : "asc";
  const page = parsePageParam(params.page);
  const { from, to } = pageRange(page);

  const [{ data: units, error: unitsError }, productsResult] = await Promise.all([
    supabase.from("units_of_measure").select("id, name").eq("organization_id", organizationId).order("name"),
    (async () => {
      let query = supabase.from("products").select("id, product_name, retail_price, status, uom_id, units_of_measure(name)", { count: "exact" }).eq("organization_id", organizationId);
      if (search) query = query.ilike("product_name", `%${search.replace(/[\\%_]/g, "\\$&")}%`);
      if (selectedUom) query = query.eq("uom_id", selectedUom);
      if (status) query = query.eq("status", status);
      // Server-side ordering (including by joined UoM name) so pages stay
      // correctly ordered instead of sorting only the visible slice.
      if (sort === "uom_id") query = query.order("name", { referencedTable: "units_of_measure", ascending: direction === "asc" }).order("product_name");
      else query = query.order(sort, { ascending: direction === "asc" });
      return query.range(from, to);
    })(),
  ]);

  const unitMap = new Map((units ?? []).map((unit) => [unit.id, unit.name]));
  const products = productsResult.data ?? [];
  const productsCount = productsResult.count;

  const error = productsResult.error || unitsError;
  const exportParams = new URLSearchParams();
  if (search) exportParams.set("search", search);
  if (selectedUom) exportParams.set("uom_id", selectedUom);
  if (status) exportParams.set("status", status);
  const exportUrl = `/products/export${exportParams.toString() ? `?${exportParams.toString()}` : ""}`;

  return (
    <WorkspaceShell active="products">
      <section className="module-toolbar">
        <div><h1>Products</h1><p className="muted">Products, units, and current retail prices.</p></div>
        <div className="module-actions">
          <Link className="primary-button" href="/products/new">+ Add Product</Link>
          <CsvActions exportUrl={exportUrl} importUrl="/products/import" />
        </div>
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
          <div className="table-scroll"><table className="spreadsheet-table"><thead><tr><SortableHeader label="Product" field="product_name" sort={sort} direction={direction} basePath="/products" params={{ search, uom_id: selectedUom, status }} />
              <SortableHeader label="UoM" field="uom_id" sort={sort} direction={direction} basePath="/products" params={{ search, uom_id: selectedUom, status }} />
              <SortableHeader label="Retail price" field="retail_price" sort={sort} direction={direction} basePath="/products" params={{ search, uom_id: selectedUom, status }} className="numeric" />
              <SortableHeader label="Status" field="status" sort={sort} direction={direction} basePath="/products" params={{ search, uom_id: selectedUom, status }} /><th>Action</th></tr></thead>
            <tbody>{products.map((product) => <tr key={product.id}><td><strong>{product.product_name}</strong></td><td>{unitMap.get(product.uom_id) || "—"}</td><td className="numeric"><span className="price-value">৳{Number(product.retail_price).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</span></td><td><span className="status-badge">{product.status}</span></td><td><form action={toggleProductStatus}><input type="hidden" name="id" value={product.id} /><input type="hidden" name="status" value={product.status === "Active" ? "Inactive" : "Active"} /><button className="secondary-button table-action-button" type="submit">{product.status === "Active" ? "Deactivate" : "Activate"}</button></form></td></tr>)}</tbody>
          </table></div>
          {!products.length && <EmptyState icon="▦" title="No products found" text={search || selectedUom || status ? "Try changing your filters." : "Add your first product."} />}
          <Pager
            basePath="/products"
            params={{ search: search || undefined, uom_id: selectedUom || undefined, status: status || undefined, sort, direction }}
            page={page}
            shown={products.length}
            total={productsCount}
            pageSize={PAGE_SIZE}
          />
        </section>
      )}
    </WorkspaceShell>
  );
}

function EmptyState({ icon, title, text }: { icon: string; title: string; text: string }) {
  return <div className="empty-state"><div className="empty-icon">{icon}</div><div><h2>{title}</h2><p>{text}</p></div></div>;
}

async function toggleProductStatus(formData: FormData) {
  "use server";
  const { supabase, organizationId } = await getWorkspaceContext();
  const id = String(formData.get("id") || "").trim();
  const nextStatus = String(formData.get("status") || "").trim();
  if (!id || !["Active", "Inactive"].includes(nextStatus)) return;
  const { error } = await supabase.from("products").update({ status: nextStatus }).eq("id", id).eq("organization_id", organizationId);
  if (!error) {
    // The list is server-rendered, so revalidation is enough for the next request.
  }
}

