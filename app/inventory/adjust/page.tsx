import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { adjustStock } from "@/app/inventory/actions";

export const dynamic = "force-dynamic";

type SearchParams = { error?: string };

export default async function AdjustStockPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const query = await searchParams;
  const error = query.error ? decodeURIComponent(query.error) : "";

  const { data: products } = await supabase
    .from("products")
    .select("id, product_name")
    .eq("organization_id", organizationId)
    .eq("status", "Active")
    .order("product_name")
    .limit(500);

  return (
    <WorkspaceShell active="inventory">
      <section className="form-page">
        <div className="form-page-header">
          <div>
            <p className="eyebrow">INVENTORY • ADJUSTMENT</p>
            <h1>Adjust Stock</h1>
            <p className="muted">Opening balances and corrections post append-only ledger movements atomically.</p>
          </div>
          <Link className="secondary-button" href="/inventory">
            Back to Inventory
          </Link>
        </div>

        {error && <div className="form-error" role="alert">{error}</div>}

        <section className="data-card form-panel">
          <form action={adjustStock} className="form-grid">
            <label>
              Product<span className="required-mark">*</span>
              <select name="product_id" required defaultValue="">
                <option value="" disabled>Select product</option>
                {(products ?? []).map((p) => (
                  <option key={p.id} value={p.id}>{p.product_name}</option>
                ))}
              </select>
            </label>
            <label>
              Movement type<span className="required-mark">*</span>
              <select name="movement_type" required defaultValue="Adjustment">
                <option value="Adjustment">Adjustment (correction, damage, found)</option>
                <option value="Opening">Opening balance</option>
              </select>
            </label>
            <label>
              Direction<span className="required-mark">*</span>
              <select name="direction" required defaultValue="In">
                <option value="In">In (increase stock)</option>
                <option value="Out">Out (decrease stock)</option>
              </select>
            </label>
            <label>
              Quantity<span className="required-mark">*</span>
              <input name="quantity" type="number" min="0" step="0.0001" required placeholder="0" />
            </label>
            <label className="full-width">
              Unit cost (optional, ৳)
              <input name="unit_cost" type="number" min="0" step="0.0001" placeholder="Valuation reference only" />
            </label>
            <div className="full-width form-actions">
              <button className="primary-button" type="submit">Record Adjustment</button>
            </div>
          </form>
          <p className="form-hint">Out adjustments are rejected if stock would go negative. Adjustments change stock only — they never touch the financial ledger.</p>
        </section>
      </section>
    </WorkspaceShell>
  );
}
