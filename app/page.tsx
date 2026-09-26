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
  ] = await Promise.all([
    supabase.from("products").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("contacts").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("purchases").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("sales").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("stock").select("quantity").eq("organization_id", organizationId),
    // Only Confirmed payments feed the cash-flow cards; Draft/Cancelled rows
    // are never summed, so don't transfer them.
    supabase.from("payments").select("payment_type, amount").eq("organization_id", organizationId).eq("status", "Confirmed"),
  ]);

  const totalStockUnits = (stockData ?? []).reduce((sum, s) => sum + Number(s.quantity || 0), 0);
  const totalReceived = (paymentsData ?? [])
    .filter((p) => p.payment_type === "In")
    .reduce((sum, p) => sum + Number(p.amount || 0), 0);
  const totalPaidOut = (paymentsData ?? [])
    .filter((p) => p.payment_type === "Out")
    .reduce((sum, p) => sum + Number(p.amount || 0), 0);

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
