import Link from "next/link";
import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";

export default async function DashboardPage() {
  const { supabase, organization } = await getWorkspaceContext();

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

  const [{ count: productsCount }, { count: contactsCount }, { count: uomCount }] = await Promise.all([
    supabase.from("products").select("id", { count: "exact", head: true }),
    supabase.from("contacts").select("id", { count: "exact", head: true }),
    supabase.from("units_of_measure").select("id", { count: "exact", head: true }),
  ]);

  return (
    <WorkspaceShell active="dashboard">
      <header className="topbar">
        <div>
          <p className="eyebrow">DASHBOARD</p>
          <h1>Dashboard</h1>
          <p className="muted">A quick overview of your inventory workspace.</p>
        </div>
        <div className="topbar-org" title={organization.organization_name}>
          <span className="status-dot" />
          <span>{organization.organization_name}</span>
        </div>
      </header>

      <section className="welcome-card" aria-labelledby="dashboard-title">
        <div>
          <span className="section-kicker">WORKSPACE OVERVIEW</span>
          <h2 id="dashboard-title">Welcome to {organization.organization_name}</h2>
          <p>Keep your products, contacts, and units organized from one place.</p>
        </div>
        <div className="org-number">
          <span>Organization</span>
          <strong>#{organization.organization_number}</strong>
        </div>
      </section>

      <section className="section-heading">
        <div>
          <h2>Inventory overview</h2>
          <p className="muted">Current totals from your workspace.</p>
        </div>
      </section>

      <section className="dashboard-grid" aria-label="Inventory overview">
        <Link className="dashboard-stat-card" href="/products">
          <span className="section-kicker">PRODUCTS</span>
          <strong>{productsCount ?? 0}</strong>
          <span>Manage products</span>
        </Link>
        <Link className="dashboard-stat-card" href="/contacts">
          <span className="section-kicker">CONTACTS</span>
          <strong>{contactsCount ?? 0}</strong>
          <span>Manage contacts</span>
        </Link>
        <Link className="dashboard-stat-card" href="/uom">
          <span className="section-kicker">UNITS</span>
          <strong>{uomCount ?? 0}</strong>
          <span>Manage units of measure</span>
        </Link>
      </section>

      <section className="section-heading">
        <div>
          <h2>Quick actions</h2>
          <p className="muted">Jump directly to common workspace tasks.</p>
        </div>
      </section>

      <section className="quick-actions">
        <Link className="secondary-button" href="/products/new">+ Add product</Link>
        <Link className="secondary-button" href="/contacts/new">+ Add contact</Link>
        <Link className="secondary-button" href="/uom">Manage UoM</Link>
        <Link className="secondary-button" href="/settings">Organization settings</Link>
      </section>
    </WorkspaceShell>
  );
}
