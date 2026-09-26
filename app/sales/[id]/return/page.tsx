import Link from "next/link";
import { redirect } from "next/navigation";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext, getWorkspaceMembership } from "@/lib/auth/workspace";
import { returnSaleItems } from "@/lib/services/inventory";

export const dynamic = "force-dynamic";

type Params = { id: string };
type SearchParams = { error?: string };

export async function returnSale(formData: FormData) {
  "use server";
  const { supabase } = await getWorkspaceMembership();
  const saleId = String(formData.get("sale_id") || "").trim();

  try {
    const lines: { product_id: string; quantity: number }[] = [];
    for (const [key, value] of formData.entries()) {
      if (!key.startsWith("qty_")) continue;
      const qty = Number(value);
      if (!Number.isFinite(qty) || qty <= 0) continue;
      lines.push({ product_id: key.slice(4), quantity: qty });
    }
    if (!lines.length) throw new Error("Enter at least one return quantity.");
    await returnSaleItems(supabase, saleId, lines);
  } catch (error) {
    const message = error instanceof Error && error.message ? error.message : "Unable to record return.";
    redirect(`/sales/${saleId}/return?error=` + encodeURIComponent(message));
  }

  redirect("/sales/" + saleId);
}

export default async function SaleReturnPage({
  params,
  searchParams,
}: {
  params: Promise<Params>;
  searchParams: Promise<SearchParams>;
}) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const { id } = await params;
  const query = await searchParams;
  const error = query.error ? decodeURIComponent(query.error) : "";

  const { data: sale } = await supabase
    .from("sales")
    .select("id, invoice_no, status")
    .eq("organization_id", organizationId)
    .eq("id", id)
    .single();

  if (!sale || sale.status !== "Confirmed") {
    return (
      <WorkspaceShell active="sales">
        <section className="form-page">
          <div className="form-page-header">
            <div>
              <p className="eyebrow">SALES RETURN</p>
              <h1>Return unavailable</h1>
              <p className="muted">Only Confirmed sales can be returned.</p>
            </div>
            <Link className="secondary-button" href={`/sales/${id}`}>Back</Link>
          </div>
        </section>
      </WorkspaceShell>
    );
  }

  const [{ data: items }, { data: movements }] = await Promise.all([
    supabase
      .from("sale_items")
      .select("product_id, quantity, products(product_name)")
      .eq("organization_id", organizationId)
      .eq("sale_id", id),
    supabase
      .from("inventory_movements")
      .select("product_id, quantity")
      .eq("organization_id", organizationId)
      .eq("reference_type", "Sale")
      .eq("reference_id", id)
      .eq("movement_direction", "In")
      .eq("movement_type", "Return"),
  ]);

  const returnedByProduct = new Map<string, number>();
  (movements ?? []).forEach((m) =>
    returnedByProduct.set(m.product_id, (returnedByProduct.get(m.product_id) || 0) + Number(m.quantity)),
  );

  const soldByProduct = new Map<string, { name: string; qty: number }>();
  (items ?? []).forEach((item) => {
    const product = Array.isArray(item.products) ? item.products[0] : item.products;
    const entry = soldByProduct.get(item.product_id) || { name: product?.product_name || "—", qty: 0 };
    entry.qty += Number(item.quantity);
    soldByProduct.set(item.product_id, entry);
  });

  const rows = [...soldByProduct.entries()].map(([productId, entry]) => ({
    productId,
    name: entry.name,
    sold: entry.qty,
    returned: returnedByProduct.get(productId) || 0,
    remaining: Math.max(0, entry.qty - (returnedByProduct.get(productId) || 0)),
  }));

  return (
    <WorkspaceShell active="sales">
      <section className="form-page">
        <div className="form-page-header">
          <div>
            <p className="eyebrow">SALES RETURN</p>
            <h1>Return #{sale.invoice_no}</h1>
            <p className="muted">Returned quantities restore warehouse stock and reverse revenue value atomically. Blocked while confirmed payments are allocated.</p>
          </div>
          <Link className="secondary-button" href={`/sales/${id}`}>Back</Link>
        </div>

        {error && <div className="form-error" role="alert">{error}</div>}

        <form action={returnSale}>
          <input type="hidden" name="sale_id" value={id} />
          <section className="table-card">
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Product</th>
                    <th className="numeric">Sold</th>
                    <th className="numeric">Already Returned</th>
                    <th className="numeric">Return Now</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row) => (
                    <tr key={row.productId}>
                      <td><strong>{row.name}</strong></td>
                      <td className="numeric">{row.sold.toLocaleString("en-BD", { maximumFractionDigits: 4 })}</td>
                      <td className="numeric">{row.returned.toLocaleString("en-BD", { maximumFractionDigits: 4 })}</td>
                      <td className="numeric">
                        <input
                          name={"qty_" + row.productId}
                          type="number"
                          min="0"
                          max={row.remaining}
                          step="0.0001"
                          placeholder="0"
                          disabled={row.remaining <= 0}
                          className="compact-number"
                        />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!rows.length && (
              <div className="empty-state">
                <div className="empty-icon">↧</div>
                <div><h2>No items</h2><p>This sale has no line items.</p></div>
              </div>
            )}
          </section>
          {!!rows.length && (
            <div className="form-actions" style={{ marginTop: 12 }}>
              <button className="primary-button" type="submit">Record Return</button>
            </div>
          )}
        </form>
      </section>
    </WorkspaceShell>
  );
}
