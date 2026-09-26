import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";

export const dynamic = "force-dynamic";

type SearchParams = {
  tab?: string;
  search?: string;
  direction?: string;
  type?: string;
};

export default async function InventoryPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const params = await searchParams;
  const currentTab = params.tab === "movements" ? "movements" : "stock";
  const search = String(params.search || "").trim();
  const filterDirection = String(params.direction || "");
  const filterType = String(params.type || "");

  // Load stock overview
  const [{ data: products }, { data: stockItems }, { data: uoms }] = await Promise.all([
    supabase
      .from("products")
      .select("id, product_name, retail_price, uom_id, status")
      .eq("organization_id", organizationId)
      .order("product_name"),
    supabase
      .from("stock")
      .select("product_id, quantity, updated_at")
      .eq("organization_id", organizationId),
    supabase
      .from("units_of_measure")
      .select("id, name")
      .eq("organization_id", organizationId),
  ]);

  const uomMap = new Map<string, string>();
  (uoms ?? []).forEach((u) => uomMap.set(u.id, u.name));

  const stockMap = new Map<string, { quantity: number; updated_at: string }>();
  (stockItems ?? []).forEach((s) =>
    stockMap.set(s.product_id, {
      quantity: Number(s.quantity || 0),
      updated_at: s.updated_at,
    }),
  );

  const inventoryItems = (products ?? []).map((p) => {
    const stockInfo = stockMap.get(p.id);
    const qty = stockInfo?.quantity ?? 0;
    return {
      id: p.id,
      name: p.product_name,
      retail_price: Number(p.retail_price || 0),
      uom: uomMap.get(p.uom_id) || "—",
      quantity: qty,
      updated_at: stockInfo?.updated_at || null,
      status: p.status,
    };
  });

  const totalProducts = inventoryItems.length;
  const inStockCount = inventoryItems.filter((i) => i.quantity > 0).length;
  const lowStockCount = inventoryItems.filter((i) => i.quantity > 0 && i.quantity <= 5).length;
  const outOfStockCount = inventoryItems.filter((i) => i.quantity <= 0).length;
  const totalUnits = inventoryItems.reduce((sum, i) => sum + i.quantity, 0);

  // Filtered Stock list
  const filteredStock = inventoryItems.filter((item) => {
    if (!search) return true;
    const q = search.toLowerCase();
    return (
      item.name.toLowerCase().includes(q) ||
      item.id.toLowerCase().includes(q) ||
      item.uom.toLowerCase().includes(q)
    );
  });

  // Load movements if on movements tab
  let movementsQuery = supabase
    .from("inventory_movements")
    .select("id, movement_date, product_id, movement_direction, movement_type, quantity, reference_type, reference_id, unit_cost, products(product_name)")
    .eq("organization_id", organizationId)
    .order("movement_date", { ascending: false })
    .limit(100);

  if (filterDirection && ["In", "Out"].includes(filterDirection)) {
    movementsQuery = movementsQuery.eq("movement_direction", filterDirection);
  }
  if (filterType && ["Purchase", "Sale", "Adjustment", "Opening", "Return"].includes(filterType)) {
    movementsQuery = movementsQuery.eq("movement_type", filterType);
  }

  const { data: movements } = await movementsQuery;

  return (
    <WorkspaceShell active="inventory">
      <section className="module-toolbar">
        <div>
          <p className="eyebrow">INVENTORY CONTROL</p>
          <h1>Inventory & Stock Ledger</h1>
          <p className="muted">Real-time stock on hand, inventory movements, stock receipts, and warehouse dispatch.</p>
        </div>
        <div className="module-actions">
          <Link className="secondary-button" href="/purchases/new">
            + Receive Stock (Purchase)
          </Link>
          <Link className="primary-button" href="/sales/new">
            + Dispatch Stock (Sale)
          </Link>
        </div>
      </section>

      <section className="summary-grid">
        <div className="summary-card">
          <span>Total Products</span>
          <strong>{totalProducts}</strong>
        </div>
        <div className="summary-card">
          <span>In Stock</span>
          <strong style={{ color: "var(--success)" }}>{inStockCount}</strong>
        </div>
        <div className="summary-card">
          <span>Low Stock (&le; 5)</span>
          <strong style={{ color: "#c2410c" }}>{lowStockCount}</strong>
        </div>
        <div className="summary-card">
          <span>Out of Stock</span>
          <strong style={{ color: "var(--danger)" }}>{outOfStockCount}</strong>
        </div>
      </section>

      <div className="module-tabs">
        <Link
          className={`tab-link ${currentTab === "stock" ? "active" : ""}`}
          href="/inventory?tab=stock"
        >
          <span>📦 Stock on Hand</span>
          <span className="tab-badge">{totalProducts}</span>
        </Link>
        <Link
          className={`tab-link ${currentTab === "movements" ? "active" : ""}`}
          href="/inventory?tab=movements"
        >
          <span>📑 Movement Ledger</span>
          <span className="tab-badge">{movements?.length ?? 0}</span>
        </Link>
      </div>

      {currentTab === "stock" && (
        <>
          <section className="filter-card" aria-label="Stock filters">
            <form className="contact-filter" method="get">
              <input type="hidden" name="tab" value="stock" />
              <label>
                Search product
                <input name="search" defaultValue={search} placeholder="Filter by product name, code..." />
              </label>
              <button className="secondary-button" type="submit">
                Filter
              </button>
              {search && (
                <Link className="filter-clear" href="/inventory?tab=stock">
                  Clear
                </Link>
              )}
            </form>
          </section>

          <section className="table-card">
            <div className="table-meta">
              <strong>
                {filteredStock.length} product{filteredStock.length === 1 ? "" : "s"}
              </strong>
              <span>
                Total warehouse balance: <strong>{totalUnits.toLocaleString("en-BD")} units</strong>
              </span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Code</th>
                    <th>Product Name</th>
                    <th>UoM</th>
                    <th className="numeric">Retail Price</th>
                    <th className="numeric">Stock on Hand</th>
                    <th>Status</th>
                    <th className="numeric">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredStock.map((item) => {
                    const isZero = item.quantity <= 0;
                    const isLow = item.quantity > 0 && item.quantity <= 5;
                    const statusBadgeClass = isZero
                      ? "badge-zero-stock"
                      : isLow
                      ? "badge-low-stock"
                      : "badge-confirmed";

                    return (
                      <tr key={item.id}>
                        <td>
                          <span className="mono">#{item.id.slice(0, 8)}</span>
                        </td>
                        <td>
                          <strong>{item.name}</strong>
                        </td>
                        <td>{item.uom}</td>
                        <td className="numeric">
                          ৳{item.retail_price.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                        </td>
                        <td className="numeric">
                          <strong>{item.quantity.toLocaleString("en-BD", { maximumFractionDigits: 4 })}</strong>
                        </td>
                        <td>
                          <span className={statusBadgeClass}>
                            {isZero ? "Out of Stock" : isLow ? `Low (${item.quantity})` : "In Stock"}
                          </span>
                        </td>
                        <td className="numeric">
                          <Link
                            className="secondary-button"
                            style={{ fontSize: "11px", padding: "4px 8px" }}
                            href={`/purchases/new`}
                          >
                            + Restock
                          </Link>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            {!filteredStock.length && (
              <div className="empty-state">
                <div className="empty-icon">📦</div>
                <div>
                  <h2>No products found</h2>
                  <p>{search ? "Try a different search query." : "No inventory records found."}</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}

      {currentTab === "movements" && (
        <>
          <section className="filter-card" aria-label="Movement filters">
            <form className="contact-filter" method="get">
              <input type="hidden" name="tab" value="movements" />
              <label>
                Direction
                <select name="direction" defaultValue={filterDirection}>
                  <option value="">All directions</option>
                  <option value="In">In (Inbound)</option>
                  <option value="Out">Out (Outbound)</option>
                </select>
              </label>
              <label>
                Movement Type
                <select name="type" defaultValue={filterType}>
                  <option value="">All types</option>
                  <option value="Purchase">Purchase</option>
                  <option value="Sale">Sale</option>
                  <option value="Adjustment">Adjustment</option>
                  <option value="Opening">Opening</option>
                  <option value="Return">Return</option>
                </select>
              </label>
              <button className="secondary-button" type="submit">
                Filter
              </button>
              {(filterDirection || filterType) && (
                <Link className="filter-clear" href="/inventory?tab=movements">
                  Clear
                </Link>
              )}
            </form>
          </section>

          <section className="table-card">
            <div className="table-meta">
              <strong>{movements?.length ?? 0} movement record(s)</strong>
              <span>Immutable inventory audit ledger</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Date & Time</th>
                    <th>Product</th>
                    <th>Direction</th>
                    <th>Type</th>
                    <th className="numeric">Quantity</th>
                    <th>Reference</th>
                    <th className="numeric">Unit Cost</th>
                  </tr>
                </thead>
                <tbody>
                  {movements?.map((m) => {
                    const prod = Array.isArray(m.products) ? m.products[0] : m.products;
                    const isDirIn = m.movement_direction === "In";
                    const refLink =
                      m.reference_type === "Purchase" && m.reference_id
                        ? `/purchases/${m.reference_id}`
                        : m.reference_type === "Sale" && m.reference_id
                        ? `/sales/${m.reference_id}`
                        : null;

                    return (
                      <tr key={m.id}>
                        <td style={{ fontSize: "11px", color: "var(--muted)" }}>
                          {new Date(m.movement_date).toLocaleString("en-BD")}
                        </td>
                        <td>
                          <strong>{prod?.product_name || "—"}</strong>
                        </td>
                        <td>
                          <span className={isDirIn ? "badge-in" : "badge-out"}>
                            {isDirIn ? "↓ In" : "↑ Out"}
                          </span>
                        </td>
                        <td>
                          <span className="status-badge">{m.movement_type}</span>
                        </td>
                        <td className="numeric">
                          <strong style={{ color: isDirIn ? "var(--success)" : "var(--primary-dark)" }}>
                            {isDirIn ? "+" : "−"}
                            {Number(m.quantity).toLocaleString("en-BD", { maximumFractionDigits: 4 })}
                          </strong>
                        </td>
                        <td>
                          {refLink ? (
                            <Link href={refLink} style={{ color: "var(--primary)", textDecoration: "underline" }}>
                              {m.reference_type} #{String(m.reference_id).slice(0, 8)}
                            </Link>
                          ) : (
                            m.reference_type || "—"
                          )}
                        </td>
                        <td className="numeric">
                          {m.unit_cost !== null && m.unit_cost !== undefined
                            ? `৳${Number(m.unit_cost).toLocaleString("en-BD", { minimumFractionDigits: 2 })}`
                            : "—"}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
            {!movements?.length && (
              <div className="empty-state">
                <div className="empty-icon">📑</div>
                <div>
                  <h2>No inventory movements recorded</h2>
                  <p>Confirming purchases or sales will automatically record ledger transactions here.</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}
    </WorkspaceShell>
  );
}
