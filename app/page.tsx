import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import WorkspaceShell from "@/app/components/workspace-shell";

export const dynamic = "force-dynamic";

export default async function Home() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships, error: membershipError } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .limit(1);

  if (membershipError) return <WorkspaceError message={membershipError.message} />;
  if (!memberships?.length) redirect("/organization/create");

  const organizationId = memberships[0].organization_id;
  const [{ data: organization, error: organizationError }, { data: profile }] = await Promise.all([
    supabase.from("organizations").select(
      "organization_number, organization_name, email, phone_number, address, tin, bin, status, created_at"
    ).eq("id", organizationId).single(),
    supabase.from("profiles").select("full_name").eq("id", user.id).single(),
  ]);

  if (organizationError || !organization) {
    return <WorkspaceError title="Organization unavailable" message={organizationError?.message ?? "Your organization could not be found."} />;
  }

  return (
    <WorkspaceShell active="system">
      <header className="topbar">
        <div>
          <p className="eyebrow">WORKSPACE</p>
          <h1>System</h1>
          <p className="muted">A concise overview of your organization workspace.</p>
        </div>
        <div className="topbar-org" title={organization.organization_name}>
          <span className="status-dot" />
          <span>{organization.organization_name}</span>
        </div>
      </header>

      <section className="welcome-card" aria-labelledby="workspace-title">
        <div>
          <span className="section-kicker">ORGANIZATION</span>
          <h2 id="workspace-title">{organization.organization_name}</h2>
          <p>Organization #{organization.organization_number} · {organization.status}</p>
        </div>
        <div className="org-number">
          <span>Organization ID</span>
          <strong>#{organization.organization_number}</strong>
        </div>
      </section>

      <section className="section-heading">
        <div>
          <h2>Organization information</h2>
          <p className="muted">Core details currently configured for this workspace.</p>
        </div>
      </section>

      <section className="info-grid" aria-label="Organization information">
        <InfoItem label="Organization name" value={organization.organization_name} />
        <InfoItem label="Email" value={organization.email} />
        <InfoItem label="Phone number" value={organization.phone_number} />
        <InfoItem label="Address" value={organization.address} wide />
        <InfoItem label="TIN" value={organization.tin || "Not provided"} />
        <InfoItem label="BIN" value={organization.bin || "Not provided"} />
        <InfoItem label="Status" value={organization.status} badge />
        <InfoItem label="Created" value={new Date(organization.created_at).toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" })} />
      </section>
    </WorkspaceShell>
  );
}

function InfoItem({ label, value, wide = false, badge = false }: {
  label: string; value: string; wide?: boolean; badge?: boolean;
}) {
  return (
    <div className={wide ? "info-item wide" : "info-item"}>
      <span>{label}</span>
      {badge ? <strong className="status-badge">{value}</strong> : <strong>{value}</strong>}
    </div>
  );
}

function WorkspaceError({ title = "Unable to load workspace", message }: { title?: string; message: string }) {
  return (
    <main className="auth-shell">
      <section className="auth-card">
        <div className="auth-brand"><span className="brand-mark">P</span><span>Pomelo Inventory</span></div>
        <p className="eyebrow">WORKSPACE ERROR</p>
        <h1>{title}</h1>
        <p className="form-error" role="alert">{message}</p>
        <a className="secondary-button" href="/auth/login">Return to sign in</a>
      </section>
    </main>
  );
}
