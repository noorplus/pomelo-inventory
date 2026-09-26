import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";

export const dynamic = "force-dynamic";

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

  const [
    { count: productsCount },
    { count: contactsCount },
    { count: purchasesCount },
    { count: salesCount },
    { data: stockData },
    { data: paymentsData },
    { count: draftPurchases },
    { count: draftSales },
    { count: draftPayments },
    { count: draftExpenses },
    { data: confirmedSales },
    { data: confirmedPurchases },
    { data: confirmedExpenses },
    { data: recentMovements },
  ] = await Promise.all([
    supabase.from("products").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("contacts").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("purchases").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("sales").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("stock").select("quantity").eq("organization_id", organizationId),
    // Only Confirmed payments feed the cash-flow cards; Draft/Cancelled rows
    // are never summed, so don't transfer them.
    supabase.from("payments").select("payment_type, amount").eq("organization_id", organizationId).eq("status", "Confirmed"),
    supabase.from("purchases").select("id", { count: "exact", head: true }).eq("organization_id", organizationId).eq("status", "Draft"),
    supabase.from("sales").select("id", { count: "exact", head: true }).eq("organization_id", organizationId).eq("status", "Draft"),
    supabase.from("payments").select("id", { count: "exact", head: true }).eq("organization_id", organizationId).eq("status", "Draft"),
    supabase.from("expenses").select("id", { count: "exact", head: true }).eq("organization_id", organizationId).eq("status", "Draft"),
    supabase.from("sales").select("id, total").eq("organization_id", organizationId).eq("status", "Confirmed").limit(200),
    supabase.from("purchases").select("id, total").eq("organization_id", organizationId).eq("status", "Confirmed").limit(200),
    supabase.from("expenses").select("id, amount").eq("organization_id", organizationId).eq("status", "Confirmed").limit(200),
    supabase
      .from("inventory_movements")
      .select("movement_date, movement_direction, movement_type, quantity, products(product_name)")
      .eq("organization_id", organizationId)
      .order("movement_date", { ascending: false })
      .limit(5),
  ]);

  const totalStockUnits = (stockData ?? []).reduce((sum, s) => sum + Number(s.quantity || 0), 0);
  const lowStockLines = (stockData ?? []).filter((s) => {
    const qty = Number(s.quantity || 0);
    return qty > 0 && qty <= 5;
  }).length;
  const totalReceived = (paymentsData ?? [])
    .filter((p) => p.payment_type === "In")
    .reduce((sum, p) => sum + Number(p.amount || 0), 0);
  const totalPaidOut = (paymentsData ?? [])
    .filter((p) => p.payment_type === "Out")
    .reduce((sum, p) => sum + Number(p.amount || 0), 0);

  // Net dues (returns-aware): total - confirmed allocations - posted returns.
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
    const m = new Map<string, number>();
    for (const r of rows) {
      const p = Array.isArray(r.payments) ? r.payments[0] : r.payments;
      if (!p || p.status !== "Confirmed") continue;
      const id = r[key];
      if (!id) continue;
      m.set(id, (m.get(id) || 0) + Number(r.allocated_amount || 0));
    }
    return m;
  };
  const sumByRef = (rows: { reference_id: string; debit?: number; credit?: number }[], col: "debit" | "credit"): Map<string, number> => {
    const m = new Map<string, number>();
    for (const r of rows) {
      m.set(r.reference_id, (m.get(r.reference_id) || 0) + Number(r[col] || 0));
    }
    return m;
  };

  const salePaid = sumConfirmed((saleAllocs ?? []) as ConfirmedAlloc[], "sale_id");
  const purchasePaid = sumConfirmed((purchaseAllocs ?? []) as ConfirmedAlloc[], "purchase_id");
  const expensePaid = sumConfirmed((expenseAllocs ?? []) as ConfirmedAlloc[], "expense_id");
  const saleReturned = sumByRef((saleReturns ?? []) as { reference_id: string; credit: number }[], "credit");
  const purchaseReturned = sumByRef((purchaseReturns ?? []) as { reference_id: string; debit: number }[], "debit");

  const receivableDue = (confirmedSales ?? []).reduce(
    (sum, s) => sum + Math.max(0, Number(s.total || 0) - (salePaid.get(s.id) || 0) - (saleReturned.get(s.id) || 0)),
    0,
  );
  const payableDue =
    (confirmedPurchases ?? []).reduce(
      (sum, p) => sum + Math.max(0, Number(p.total || 0) - (purchasePaid.get(p.id) || 0) - (purchaseReturned.get(p.id) || 0)),
      0,
    ) +
    (confirmedExpenses ?? []).reduce(
      (sum, e) => sum + Math.max(0, Number(e.amount || 0) - (expensePaid.get(e.id) || 0)),
      0,
    );

  return (
    <WorkspaceShell active="dashboard">
      <header className="topbar">
        <div>
          <p className="eyebrow">DASHBOARD</p>
          <h1>Dashboard</h1>
          <p className="muted">Unified overview of purchasing, sales, stock, and financial cash flow.</p>
        </div>
        <div className="topbar-org" title={organization.organization_name}>
          <span className="status-dot" />
          <span>{organization.organization_name}</span>
        </div>
      </header>

      <section className="welcome-card" aria-labelledby="dashboard-title">
        <div>
          <span className="section-kicker">ENTERPRISE WORKSPACE</span>
          <h2 id="dashboard-title">{organization.organization_name}</h2>
          <p>Complete control across Purchases, Sales, Warehouse Inventory, and Accounting.</p>
        </div>
        <div className="org-number">
          <span>Organization</span>
          <strong>#{organization.organization_number}</strong>
        </div>
      </section>

      <section className="section-heading">
        <div>
          <h2>Core Operations</h2>
          <p className="muted">Live operational counters across your modules.</p>
        </div>
      </section>

      <section className="dashboard-grid" aria-label="Operations overview">
        <Link className="dashboard-stat-card" href="/inventory">
          <span className="section-kicker">INVENTORY</span>
          <strong>{totalStockUnits.toLocaleString("en-BD")}</strong>
          <span>Total units on hand ({productsCount ?? 0} products)</span>
        </Link>
        <Link className="dashboard-stat-card" href="/sales">
          <span className="section-kicker">SALES ORDERS</span>
          <strong>{salesCount ?? 0}</strong>
          <span>Customer sales & invoices</span>
        </Link>
        <Link className="dashboard-stat-card" href="/purchases">
          <span className="section-kicker">PURCHASES</span>
          <strong>{purchasesCount ?? 0}</strong>
          <span>Supplier purchase orders</span>
        </Link>
        <Link className="dashboard-stat-card" href="/accounting?tab=payments">
          <span className="section-kicker">CASH IN (COLLECTIONS)</span>
          <strong style={{ color: "var(--success)" }}>
            ৳{totalReceived.toLocaleString("en-BD", { maximumFractionDigits: 0 })}
          </strong>
          <span>Confirmed customer payments</span>
        </Link>
        <Link className="dashboard-stat-card" href="/accounting?tab=payments">
          <span className="section-kicker">CASH OUT (PAYMENTS)</span>
          <strong style={{ color: "var(--primary-dark)" }}>
            ৳{totalPaidOut.toLocaleString("en-BD", { maximumFractionDigits: 0 })}
          </strong>
          <span>Confirmed supplier payouts</span>
        </Link>
        <Link className="dashboard-stat-card" href="/contacts">
          <span className="section-kicker">CONTACTS</span>
          <strong>{contactsCount ?? 0}</strong>
          <span>Customers & Suppliers</span>
        </Link>
      </section>

      <section className="section-heading">
        <div>
          <h2>Money Owed</h2>
          <p className="muted">Net of confirmed allocations and posted returns.</p>
        </div>
      </section>

      <section className="dashboard-grid" aria-label="Dues overview">
        <Link className="dashboard-stat-card" href="/reports?tab=due">
          <span className="section-kicker">RECEIVABLE DUE</span>
          <strong style={{ color: "var(--success)" }}>
            ৳{receivableDue.toLocaleString("en-BD", { maximumFractionDigits: 0 })}
          </strong>
          <span>Customers owe us · due follow-up</span>
        </Link>
        <Link className="dashboard-stat-card" href="/reports?tab=due">
          <span className="section-kicker">PAYABLE DUE</span>
          <strong style={{ color: "var(--primary-dark)" }}>
            ৳{payableDue.toLocaleString("en-BD", { maximumFractionDigits: 0 })}
          </strong>
          <span>We owe suppliers & vendors · due follow-up</span>
        </Link>
        <Link className="dashboard-stat-card" href="/inventory">
          <span className="section-kicker">LOW STOCK LINES</span>
          <strong>{lowStockLines.toLocaleString("en-BD")}</strong>
          <span>Stock lines at 5 units or fewer</span>
        </Link>
      </section>

      <section className="section-heading">
        <div>
          <h2>Needs Attention</h2>
          <p className="muted">Unfinished drafts waiting for confirmation.</p>
        </div>
      </section>

      <section className="summary-grid" aria-label="Drafts overview">
        <Link className="summary-card" href="/purchases?status=Draft">
          <span>Draft Purchases</span>
          <strong>{draftPurchases ?? 0}</strong>
        </Link>
        <Link className="summary-card" href="/sales?status=Draft">
          <span>Draft Sales</span>
          <strong>{draftSales ?? 0}</strong>
        </Link>
        <Link className="summary-card" href="/accounting?tab=payments">
          <span>Draft Payments</span>
          <strong>{draftPayments ?? 0}</strong>
        </Link>
        <Link className="summary-card" href="/accounting?tab=expenses">
          <span>Draft Expenses</span>
          <strong>{draftExpenses ?? 0}</strong>
        </Link>
      </section>

      {!!recentMovements?.length && (
        <>
          <section className="section-heading">
            <div>
              <h2>Latest Movements</h2>
              <p className="muted">Most recent inventory ledger entries.</p>
            </div>
          </section>

          <section className="table-card">
            <div className="table-scroll">
              <table>
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
                  {recentMovements.map((m, i) => {
                    const product = Array.isArray(m.products) ? m.products[0] : m.products;
                    const isIn = m.movement_direction === "In";
                    return (
                      <tr key={i}>
                        <td style={{ fontSize: "11px", color: "var(--muted)" }}>
                          {new Date(m.movement_date).toLocaleString("en-BD")}
                        </td>
                        <td>
                          <strong>{product?.product_name || "—"}</strong>
                        </td>
                        <td>
                          <span className={isIn ? "badge-in" : "badge-out"}>
                            {isIn ? "↓ In" : "↑ Out"}
                          </span>
                        </td>
                        <td>
                          <span className="status-badge">{m.movement_type}</span>
                        </td>
                        <td className="numeric">
                          <strong>
                            {Number(m.quantity).toLocaleString("en-BD", { maximumFractionDigits: 4 })}
                          </strong>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </section>
        </>
      )}

      <section className="section-heading">
        <div>
          <h2>Quick Actions</h2>
          <p className="muted">Create transactions directly with atomic database integrity.</p>
        </div>
      </section>

      <section className="quick-actions">
        <Link className="primary-button" href="/sales/new">
          + New Sale Order
        </Link>
        <Link className="secondary-button" href="/purchases/new">
          + New Purchase Bill
        </Link>
        <Link className="secondary-button" href="/inventory">
          📦 View Warehouse Stock
        </Link>
        <Link className="secondary-button" href="/accounting/payments/new">
          💳 Record Payment
        </Link>
        <Link className="secondary-button" href="/accounting/expenses/new">
          📉 Record Expense
        </Link>
        <Link className="secondary-button" href="/products/new">
          + Add Product
        </Link>
        <Link className="secondary-button" href="/contacts/new">
          + Add Contact
        </Link>
      </section>
    </WorkspaceShell>
  );
}
