import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";

export const dynamic = "force-dynamic";

type TrendPoint = {
  date: string;
  label: string;
  sales: number;
  purchases: number;
};

const money = (value: number) =>
  `৳${value.toLocaleString("en-BD", { maximumFractionDigits: 0 })}`;

const number = (value: number) => value.toLocaleString("en-BD", { maximumFractionDigits: 4 });

function getDhakaToday() {
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Dhaka" }).format(new Date());
}

function shiftDate(dateText: string, days: number) {
  const date = new Date(`${dateText}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

function buildTrend(
  today: string,
  salesRows: { invoice_date: string; total: number }[],
  purchaseRows: { invoice_date: string; total: number }[],
): TrendPoint[] {
  return Array.from({ length: 7 }, (_, index) => {
    const date = shiftDate(today, index - 6);
    const sales = salesRows
      .filter((row) => row.invoice_date === date)
      .reduce((sum, row) => sum + Number(row.total || 0), 0);
    const purchases = purchaseRows
      .filter((row) => row.invoice_date === date)
      .reduce((sum, row) => sum + Number(row.total || 0), 0);

    return {
      date,
      label: new Intl.DateTimeFormat("en-BD", { day: "2-digit", month: "short", timeZone: "Asia/Dhaka" }).format(
        new Date(`${date}T00:00:00Z`),
      ),
      sales,
      purchases,
    };
  });
}

export default async function DashboardPage() {
  const { supabase, organization, organizationId } = await getWorkspaceContext();

  if (!organization) {
    return (
      <WorkspaceShell active="dashboard">
        <section className="data-card">
          <h1>Dashboard</h1>
          <p className="muted">Your organization could not be found.</p>
        </section>
      </WorkspaceShell>
    );
  }

  const today = getDhakaToday();
  const trendStart = shiftDate(today, -6);

  const [
    { count: productsCount },
    { count: contactsCount },
    { count: purchasesCount },
    { count: salesCount },
    { data: stockData },
    { data: productsData },
    { data: paymentsData },
    { count: draftPurchases },
    { count: draftSales },
    { count: draftPayments },
    { count: draftExpenses },
    { data: confirmedSales },
    { data: confirmedPurchases },
    { data: confirmedExpenses },
    { data: trendSales },
    { data: trendPurchases },
    { data: todayPayments },
    { data: recentMovements },
    { data: recentSales },
    { data: recentPurchases },
  ] = await Promise.all([
    supabase.from("products").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("contacts").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("purchases").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("sales").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("stock").select("product_id, quantity").eq("organization_id", organizationId),
    supabase.from("products").select("id, product_name, retail_price").eq("organization_id", organizationId),
    supabase.from("payments").select("payment_type, amount").eq("organization_id", organizationId).eq("status", "Confirmed"),
    supabase.from("purchases").select("id", { count: "exact", head: true }).eq("organization_id", organizationId).eq("status", "Draft"),
    supabase.from("sales").select("id", { count: "exact", head: true }).eq("organization_id", organizationId).eq("status", "Draft"),
    supabase.from("payments").select("id", { count: "exact", head: true }).eq("organization_id", organizationId).eq("status", "Draft"),
    supabase.from("expenses").select("id", { count: "exact", head: true }).eq("organization_id", organizationId).eq("status", "Draft"),
    supabase.from("sales").select("id, total").eq("organization_id", organizationId).eq("status", "Confirmed").limit(200),
    supabase.from("purchases").select("id, total").eq("organization_id", organizationId).eq("status", "Confirmed").limit(200),
    supabase.from("expenses").select("id, amount").eq("organization_id", organizationId).eq("status", "Confirmed").limit(200),
    supabase
      .from("sales")
      .select("invoice_date, total")
      .eq("organization_id", organizationId)
      .eq("status", "Confirmed")
      .gte("invoice_date", trendStart)
      .lte("invoice_date", today)
      .order("invoice_date", { ascending: true })
      .limit(1000),
    supabase
      .from("purchases")
      .select("invoice_date, total")
      .eq("organization_id", organizationId)
      .eq("status", "Confirmed")
      .gte("invoice_date", trendStart)
      .lte("invoice_date", today)
      .order("invoice_date", { ascending: true })
      .limit(1000),
    supabase
      .from("payments")
      .select("payment_type, amount")
      .eq("organization_id", organizationId)
      .eq("status", "Confirmed")
      .eq("payment_date", today),
    supabase
      .from("inventory_movements")
      .select("movement_date, movement_direction, movement_type, quantity, products(product_name)")
      .eq("organization_id", organizationId)
      .order("movement_date", { ascending: false })
      .limit(5),
    supabase
      .from("sales")
      .select("id, invoice_no, invoice_date, total")
      .eq("organization_id", organizationId)
      .eq("status", "Confirmed")
      .order("invoice_date", { ascending: false })
      .limit(5),
    supabase
      .from("purchases")
      .select("id, invoice_no, invoice_date, total")
      .eq("organization_id", organizationId)
      .eq("status", "Confirmed")
      .order("invoice_date", { ascending: false })
      .limit(5),
  ]);

  const productPrices = new Map((productsData ?? []).map((product) => [product.id, Number(product.retail_price || 0)]));

  const totalStockUnits = (stockData ?? []).reduce((sum, row) => sum + Number(row.quantity || 0), 0);
  const lowStockLines = (stockData ?? []).filter((row) => {
    const qty = Number(row.quantity || 0);
    return qty > 0 && qty <= 5;
  }).length;
  const outOfStockLines = (stockData ?? []).filter((row) => Number(row.quantity || 0) <= 0).length;
  const stockValue = (stockData ?? []).reduce(
    (sum, row) => sum + Number(row.quantity || 0) * (productPrices.get(row.product_id) || 0),
    0,
  );

  const totalReceived = (paymentsData ?? [])
    .filter((p) => p.payment_type === "In")
    .reduce((sum, p) => sum + Number(p.amount || 0), 0);
  const totalPaidOut = (paymentsData ?? [])
    .filter((p) => p.payment_type === "Out")
    .reduce((sum, p) => sum + Number(p.amount || 0), 0);

  const todaySales = (trendSales ?? [])
    .filter((row) => row.invoice_date === today)
    .reduce((sum, row) => sum + Number(row.total || 0), 0);
  const todayPurchases = (trendPurchases ?? [])
    .filter((row) => row.invoice_date === today)
    .reduce((sum, row) => sum + Number(row.total || 0), 0);
  const todayCollections = (todayPayments ?? [])
    .filter((p) => p.payment_type === "In")
    .reduce((sum, p) => sum + Number(p.amount || 0), 0);
  const todayPaymentsOut = (todayPayments ?? [])
    .filter((p) => p.payment_type === "Out")
    .reduce((sum, p) => sum + Number(p.amount || 0), 0);

  const saleIds = (confirmedSales ?? []).map((s) => s.id);
  const purchaseIds = (confirmedPurchases ?? []).map((p) => p.id);
  const expenseIds = (confirmedExpenses ?? []).map((e) => e.id);
  const [
    { data: saleAllocs },
    { data: purchaseAllocs },
    { data: expenseAllocs },
    { data: saleReturns },
    { data: purchaseReturns },
  ] = await Promise.all([
    saleIds.length
      ? supabase.from("payment_allocations").select("sale_id, allocated_amount, payments!inner(status)").eq("organization_id", organizationId).in("sale_id", saleIds)
      : Promise.resolve({ data: [] as { sale_id: string; allocated_amount: number; payments: { status: string } | { status: string }[] }[] }),
    purchaseIds.length
      ? supabase.from("payment_allocations").select("purchase_id, allocated_amount, payments!inner(status)").eq("organization_id", organizationId).in("purchase_id", purchaseIds)
      : Promise.resolve({ data: [] as { purchase_id: string; allocated_amount: number; payments: { status: string } | { status: string }[] }[] }),
    expenseIds.length
      ? supabase.from("payment_allocations").select("expense_id, allocated_amount, payments!inner(status)").eq("organization_id", organizationId).in("expense_id", expenseIds)
      : Promise.resolve({ data: [] as { expense_id: string; allocated_amount: number; payments: { status: string } | { status: string }[] }[] }),
    saleIds.length
      ? supabase.from("account_transactions").select("reference_id, credit").eq("organization_id", organizationId).eq("reference_type", "Sale").in("reference_id", saleIds).like("transaction_type", "Sale Return%")
      : Promise.resolve({ data: [] as { reference_id: string; credit: number }[] }),
    purchaseIds.length
      ? supabase.from("account_transactions").select("reference_id, debit").eq("organization_id", organizationId).eq("reference_type", "Purchase").in("reference_id", purchaseIds).like("transaction_type", "Purchase Return%")
      : Promise.resolve({ data: [] as { reference_id: string; debit: number }[] }),
  ]);

  type ConfirmedAlloc = {
    sale_id?: string;
    purchase_id?: string;
    expense_id?: string;
    allocated_amount: number;
    payments: { status: string } | { status: string }[];
  };
  const sumConfirmed = (rows: ConfirmedAlloc[], key: "sale_id" | "purchase_id" | "expense_id"): Map<string, number> => {
    const map = new Map<string, number>();
    for (const row of rows) {
      const payment = Array.isArray(row.payments) ? row.payments[0] : row.payments;
      if (!payment || payment.status !== "Confirmed") continue;
      const id = row[key];
      if (!id) continue;
      map.set(id, (map.get(id) || 0) + Number(row.allocated_amount || 0));
    }
    return map;
  };
  const sumByRef = (rows: { reference_id: string; debit?: number; credit?: number }[], column: "debit" | "credit") => {
    const map = new Map<string, number>();
    for (const row of rows) {
      map.set(row.reference_id, (map.get(row.reference_id) || 0) + Number(row[column] || 0));
    }
    return map;
  };

  const salePaid = sumConfirmed((saleAllocs ?? []) as ConfirmedAlloc[], "sale_id");
  const purchasePaid = sumConfirmed((purchaseAllocs ?? []) as ConfirmedAlloc[], "purchase_id");
  const expensePaid = sumConfirmed((expenseAllocs ?? []) as ConfirmedAlloc[], "expense_id");
  const saleReturned = sumByRef((saleReturns ?? []) as { reference_id: string; credit: number }[], "credit");
  const purchaseReturned = sumByRef((purchaseReturns ?? []) as { reference_id: string; debit: number }[], "debit");

  const receivableDue = (confirmedSales ?? []).reduce(
    (sum, sale) => sum + Math.max(0, Number(sale.total || 0) - (salePaid.get(sale.id) || 0) - (saleReturned.get(sale.id) || 0)),
    0,
  );
  const payableDue =
    (confirmedPurchases ?? []).reduce(
      (sum, purchase) => sum + Math.max(0, Number(purchase.total || 0) - (purchasePaid.get(purchase.id) || 0) - (purchaseReturned.get(purchase.id) || 0)),
      0,
    ) +
    (confirmedExpenses ?? []).reduce(
      (sum, expense) => sum + Math.max(0, Number(expense.amount || 0) - (expensePaid.get(expense.id) || 0)),
      0,
    );

  const trend = buildTrend(
    today,
    (trendSales ?? []) as { invoice_date: string; total: number }[],
    (trendPurchases ?? []) as { invoice_date: string; total: number }[],
  );
  const trendMax = Math.max(1, ...trend.flatMap((point) => [point.sales, point.purchases]));

  const recentDocuments = [
    ...(recentSales ?? []).map((row) => ({ kind: "Sale", no: row.invoice_no, date: row.invoice_date, total: Number(row.total || 0) })),
    ...(recentPurchases ?? []).map((row) => ({ kind: "Purchase", no: row.invoice_no, date: row.invoice_date, total: Number(row.total || 0) })),
  ]
    .sort((a, b) => b.date.localeCompare(a.date))
    .slice(0, 6);

  return (
    <WorkspaceShell active="dashboard">
      <header className="topbar dashboard-topbar">
        <div>
          <p className="eyebrow">DASHBOARD</p>
          <h1>Dashboard</h1>
          <p className="muted">A focused operational view of stock, transactions, cash flow, and attention items.</p>
        </div>
        <div className="topbar-org" title={organization.organization_name}>
          <span className="status-dot" />
          <span>{organization.organization_name}</span>
        </div>
      </header>

      <section className="welcome-card dashboard-welcome" aria-labelledby="dashboard-title">
        <div>
          <span className="section-kicker">ENTERPRISE WORKSPACE</span>
          <h2 id="dashboard-title">{organization.organization_name}</h2>
          <p>Monitor the business at a glance, then jump directly into the work that needs attention.</p>
        </div>
        <div className="org-number">
          <span>Organization</span>
          <strong>#{organization.organization_number}</strong>
        </div>
      </section>

      <section className="section-heading dashboard-section-heading">
        <div>
          <h2>Today at a glance</h2>
          <p className="muted">{today} · Confirmed transactions only</p>
        </div>
      </section>

      <section className="dashboard-kpi-grid" aria-label="Today's dashboard KPIs">
        <Link className="dashboard-kpi-card dashboard-kpi-primary" href="/sales">
          <span className="section-kicker">TODAY'S SALES</span>
          <strong>{money(todaySales)}</strong>
          <span>Confirmed sales today</span>
        </Link>
        <Link className="dashboard-kpi-card" href="/purchases">
          <span className="section-kicker">TODAY'S PURCHASES</span>
          <strong>{money(todayPurchases)}</strong>
          <span>Confirmed purchases today</span>
        </Link>
        <Link className="dashboard-kpi-card" href="/accounting?tab=payments">
          <span className="section-kicker">COLLECTIONS</span>
          <strong className="value-success">{money(todayCollections)}</strong>
          <span>Cash received today</span>
        </Link>
        <Link className="dashboard-kpi-card" href="/accounting?tab=payments">
          <span className="section-kicker">PAYMENTS OUT</span>
          <strong>{money(todayPaymentsOut)}</strong>
          <span>Cash paid out today</span>
        </Link>
        <Link className="dashboard-kpi-card" href="/inventory">
          <span className="section-kicker">STOCK VALUE</span>
          <strong>{money(stockValue)}</strong>
          <span>Current units × retail price</span>
        </Link>
        <Link className="dashboard-kpi-card" href="/contacts">
          <span className="section-kicker">CONTACTS</span>
          <strong>{contactsCount ?? 0}</strong>
          <span>Customers & suppliers</span>
        </Link>
      </section>

      <section className="dashboard-two-column">
        <div className="dashboard-panel">
          <div className="dashboard-panel-header">
            <div>
              <span className="section-kicker">7-DAY ACTIVITY</span>
              <h2>Sales vs Purchases</h2>
            </div>
            <span className="dashboard-panel-meta">Confirmed</span>
          </div>
          <div className="trend-chart" aria-label="Seven day sales and purchases comparison">
            {trend.map((point) => (
              <div className="trend-column" key={point.date}>
                <div className="trend-bars">
                  <div className="trend-bar sales" style={{ height: `${Math.max(4, (point.sales / trendMax) * 100)}%` }} title={`Sales ${money(point.sales)}`} />
                  <div className="trend-bar purchases" style={{ height: `${Math.max(4, (point.purchases / trendMax) * 100)}%` }} title={`Purchases ${money(point.purchases)}`} />
                </div>
                <span>{point.label}</span>
              </div>
            ))}
          </div>
          <div className="trend-legend">
            <span><i className="trend-dot sales" />Sales</span>
            <span><i className="trend-dot purchases" />Purchases</span>
          </div>
        </div>

        <div className="dashboard-panel">
          <div className="dashboard-panel-header">
            <div>
              <span className="section-kicker">INVENTORY HEALTH</span>
              <h2>Warehouse status</h2>
            </div>
            <Link href="/inventory" className="dashboard-panel-link">Open stock →</Link>
          </div>
          <div className="inventory-health">
            <div className="health-row">
              <div><span>Total units</span><strong>{number(totalStockUnits)}</strong></div>
              <span className="health-badge neutral">{productsCount ?? 0} products</span>
            </div>
            <div className="health-row">
              <div><span>Low stock</span><strong>{lowStockLines}</strong></div>
              <span className="health-badge warning">≤ 5 units</span>
            </div>
            <div className="health-row">
              <div><span>Out of stock</span><strong>{outOfStockLines}</strong></div>
              <span className="health-badge danger">Needs restock</span>
            </div>
            <div className="health-row">
              <div><span>Retail value</span><strong>{money(stockValue)}</strong></div>
              <span className="health-badge success">Current stock</span>
            </div>
          </div>
        </div>
      </section>

      <section className="section-heading dashboard-section-heading">
        <div>
          <h2>Financial position</h2>
          <p className="muted">Outstanding balances and all-time confirmed cash movement.</p>
        </div>
      </section>

      <section className="dashboard-grid dashboard-finance-grid" aria-label="Financial overview">
        <Link className="dashboard-stat-card" href="/reports?tab=due">
          <span className="section-kicker">RECEIVABLE DUE</span>
          <strong className="value-success">{money(receivableDue)}</strong>
          <span>Customers owe us</span>
        </Link>
        <Link className="dashboard-stat-card" href="/reports?tab=due">
          <span className="section-kicker">PAYABLE DUE</span>
          <strong>{money(payableDue)}</strong>
          <span>Suppliers & vendors</span>
        </Link>
        <Link className="dashboard-stat-card" href="/accounting?tab=payments">
          <span className="section-kicker">TOTAL COLLECTIONS</span>
          <strong className="value-success">{money(totalReceived)}</strong>
          <span>All confirmed cash in</span>
        </Link>
        <Link className="dashboard-stat-card" href="/accounting?tab=payments">
          <span className="section-kicker">TOTAL PAYMENTS OUT</span>
          <strong>{money(totalPaidOut)}</strong>
          <span>All confirmed cash out</span>
        </Link>
      </section>

      <section className="dashboard-two-column dashboard-lower-grid">
        <div className="dashboard-panel">
          <div className="dashboard-panel-header">
            <div>
              <span className="section-kicker">RECENT DOCUMENTS</span>
              <h2>Latest Sales & Purchases</h2>
            </div>
          </div>
          {recentDocuments.length ? (
            <div className="dashboard-document-list">
              {recentDocuments.map((document) => (
                <Link
                  className="dashboard-document-row"
                  href={document.kind === "Sale" ? "/sales" : "/purchases"}
                  key={`${document.kind}-${document.no}`}
                >
                  <span className={document.kind === "Sale" ? "document-kind sale" : "document-kind purchase"}>
                    {document.kind}
                  </span>
                  <span className="document-main">
                    <strong>#{document.no}</strong>
                    <small>{document.date}</small>
                  </span>
                  <strong>{money(document.total)}</strong>
                </Link>
              ))}
            </div>
          ) : (
            <div className="dashboard-empty">No confirmed sales or purchases yet.</div>
          )}
        </div>

        <div className="dashboard-panel">
          <div className="dashboard-panel-header">
            <div>
              <span className="section-kicker">NEEDS ATTENTION</span>
              <h2>Open work</h2>
            </div>
          </div>
          <div className="attention-list">
            <Link href="/inventory" className="attention-row">
              <span><strong>{outOfStockLines}</strong> out-of-stock lines</span>
              <span className={outOfStockLines ? "attention-badge danger" : "attention-badge success"}>{outOfStockLines ? "Restock" : "Clear"}</span>
            </Link>
            <Link href="/inventory" className="attention-row">
              <span><strong>{lowStockLines}</strong> low-stock lines</span>
              <span className={lowStockLines ? "attention-badge warning" : "attention-badge success"}>{lowStockLines ? "Review" : "Clear"}</span>
            </Link>
            <Link href="/sales?status=Draft" className="attention-row">
              <span><strong>{draftSales ?? 0}</strong> draft sales</span>
              <span className={draftSales ? "attention-badge warning" : "attention-badge success"}>{draftSales ? "Review" : "Clear"}</span>
            </Link>
            <Link href="/purchases?status=Draft" className="attention-row">
              <span><strong>{draftPurchases ?? 0}</strong> draft purchases</span>
              <span className={draftPurchases ? "attention-badge warning" : "attention-badge success"}>{draftPurchases ? "Review" : "Clear"}</span>
            </Link>
            <Link href="/accounting?tab=payments" className="attention-row">
              <span><strong>{draftPayments ?? 0}</strong> draft payments</span>
              <span className={draftPayments ? "attention-badge warning" : "attention-badge success"}>{draftPayments ? "Review" : "Clear"}</span>
            </Link>
            <Link href="/accounting?tab=expenses" className="attention-row">
              <span><strong>{draftExpenses ?? 0}</strong> draft expenses</span>
              <span className={draftExpenses ? "attention-badge warning" : "attention-badge success"}>{draftExpenses ? "Review" : "Clear"}</span>
            </Link>
          </div>
        </div>
      </section>

      {!!recentMovements?.length && (
        <>
          <section className="section-heading dashboard-section-heading">
            <div>
              <h2>Latest movements</h2>
              <p className="muted">The five most recent inventory ledger entries.</p>
            </div>
          </section>
          <section className="table-card dashboard-movement-card">
            <div className="table-scroll">
              <table className="spreadsheet-table">
                <thead>
                  <tr>
                    <th>Date & Time</th>
                    <th>Product</th>
                    <th>Direction</th>
                    <th>Type</th>
                    <th className="numeric">Quantity</th>
                  </tr>
                </thead>
                <tbody>
                  {recentMovements.map((movement, index) => {
                    const product = Array.isArray(movement.products) ? movement.products[0] : movement.products;
                    const isIn = movement.movement_direction === "In";
                    return (
                      <tr key={`${movement.movement_date}-${index}`}>
                        <td className="dashboard-date-cell">{new Date(movement.movement_date).toLocaleString("en-BD")}</td>
                        <td><strong>{product?.product_name || "—"}</strong></td>
                        <td><span className={isIn ? "badge-in" : "badge-out"}>{isIn ? "↓ In" : "↑ Out"}</span></td>
                        <td><span className="status-badge">{movement.movement_type}</span></td>
                        <td className="numeric"><strong>{number(Number(movement.quantity || 0))}</strong></td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </section>
        </>
      )}

      <section className="section-heading dashboard-section-heading">
        <div>
          <h2>Quick actions</h2>
          <p className="muted">Jump straight into the most common operations.</p>
        </div>
      </section>

      <section className="quick-actions dashboard-quick-actions">
        <Link className="primary-button" href="/sales/new">+ New Sale Order</Link>
        <Link className="secondary-button" href="/purchases/new">+ New Purchase Bill</Link>
        <Link className="secondary-button" href="/inventory">📦 View Warehouse Stock</Link>
        <Link className="secondary-button" href="/accounting/payments/new">💳 Record Payment</Link>
        <Link className="secondary-button" href="/accounting/expenses/new">📉 Record Expense</Link>
        <Link className="secondary-button" href="/products/new">+ Add Product</Link>
        <Link className="secondary-button" href="/contacts/new">+ Add Contact</Link>
      </section>

      <section className="dashboard-module-summary" aria-label="Module totals">
        <span>{productsCount ?? 0} products</span>
        <span>{contactsCount ?? 0} contacts</span>
        <span>{salesCount ?? 0} sales</span>
        <span>{purchasesCount ?? 0} purchases</span>
      </section>
    </WorkspaceShell>
  );
}
