import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { SignOutButton } from "@/app/components/sign-out-button";

export const dynamic = "force-dynamic";

export default async function Home() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  if (!user) redirect("/auth/login");

  const { data: memberships, error } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .limit(1);

  if (error) {
    return <main className="auth-shell"><section className="auth-card"><h1>Unable to load workspace</h1><p className="form-error">{error.message}</p></section></main>;
  }

  if (!memberships?.length) redirect("/organization/create");

  const { data: organization, error: organizationError } = await supabase
    .from("organizations")
    .select("organization_number, organization_name, email, phone_number, status")
    .eq("id", memberships[0].organization_id)
    .single();

  if (organizationError || !organization) {
    return <main className="auth-shell"><section className="auth-card"><h1>Unable to load organization</h1><p className="form-error">{organizationError?.message ?? "Organization not found."}</p></section></main>;
  }

  return (
    <div className="dashboard">
      <aside className="sidebar">
        <div className="brand">Pomelo Inventory</div>
        <nav className="nav" aria-label="Main navigation">
          <a className="active" href="/">Dashboard</a>
          <a href="/products">Products</a>
          <a href="/warehouses">Warehouses</a>
          <a href="/stock-movements">Stock Movements</a>
          <a href="/purchases">Purchases</a>
          <a href="/transfers">Transfers</a>
          <a href="/suppliers">Suppliers</a>
          <a href="/reports">Reports</a>
        </nav>
        <div className="sidebar-bottom"><SignOutButton /></div>
      </aside>

      <main className="main">
        <header className="header">
          <div>
            <h1>Dashboard</h1>
            <div className="muted">{organization.organization_name} · #{organization.organization_number}</div>
          </div>
          <span className="status">{organization.status}</span>
        </header>

        <section className="grid" aria-label="Inventory summary">
          <div className="card"><div className="card-label">Total Products</div><div className="card-value">—</div></div>
          <div className="card"><div className="card-label">Warehouses</div><div className="card-value">—</div></div>
          <div className="card"><div className="card-label">Low Stock</div><div className="card-value">—</div></div>
          <div className="card"><div className="card-label">Pending Purchases</div><div className="card-value">—</div></div>
        </section>

        <section className="card org-card">
          <h2>Organization</h2>
          <div className="org-grid">
            <div><span className="card-label">Organization Number</span><strong>{organization.organization_number}</strong></div>
            <div><span className="card-label">Email</span><strong>{organization.email}</strong></div>
            <div><span className="card-label">Phone</span><strong>{organization.phone_number}</strong></div>
          </div>
        </section>

        <section className="card table-card">
          <div className="table-title">Recent Stock Movements</div>
          <div className="muted" style={{ padding: "20px" }}>No inventory data is available yet.</div>
        </section>
      </main>
    </div>
  );
}
