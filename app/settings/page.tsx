import Link from "next/link";
import { redirect } from "next/navigation";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext, getWorkspaceMembership } from "@/lib/auth/workspace";

export async function updateOrganization(formData: FormData) {
  "use server";
  const { supabase, organizationId } = await getWorkspaceMembership();
  const organizationName = String(formData.get("organization_name") || "").trim();
  const email = String(formData.get("email") || "").trim();
  const phoneNumber = String(formData.get("phone_number") || "").trim();
  const address = String(formData.get("address") || "").trim();
  const tin = String(formData.get("tin") || "").trim() || null;
  const bin = String(formData.get("bin") || "").trim() || null;

  if (!organizationName || !email || !phoneNumber || !address) {
    redirect("/settings?edit=org&error=organization-required");
  }

  const { error } = await supabase
    .from("organizations")
    .update({ organization_name: organizationName, email, phone_number: phoneNumber, address, tin, bin })
    .eq("id", organizationId);

  if (error) redirect("/settings?edit=org&error=" + encodeURIComponent(error.message));

  redirect("/settings?saved=organization");
}

export async function updateCurrentUser(formData: FormData) {
  "use server";
  const { supabase, user } = await getWorkspaceMembership();
  const fullName = String(formData.get("full_name") || "").trim();

  if (!fullName) redirect("/settings?edit=user&error=user-required");

  const { error } = await supabase
    .from("profiles")
    .update({ full_name: fullName })
    .eq("id", user.id);

  if (error) redirect("/settings?edit=user&error=" + encodeURIComponent(error.message));

  redirect("/settings?saved=user");
}

export default async function SettingsPage({ searchParams }: { searchParams: Promise<{ saved?: string; error?: string; edit?: string }> }) {
  const params = await searchParams;
  const { supabase, user, organization, profile } = await getWorkspaceContext();
  const { organizationId, organizationIds } = await getWorkspaceMembership();

  // View-first cards; edit forms open only for fields the database lets
  // members write (org profile columns, own full_name). System-managed
  // values (org number/status/created, auth email/id) stay read-only.
  const editingOrg = params.edit === "org";
  const editingUser = params.edit === "user";

  if (!organization) {
    return <WorkspaceError title="Organization unavailable" message="Your organization could not be found." />;
  }

  const [
    { count: productsCount },
    { count: contactsCount },
    { count: purchasesCount },
    { count: salesCount },
  ] = await Promise.all([
    supabase.from("products").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("contacts").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("purchases").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
    supabase.from("sales").select("id", { count: "exact", head: true }).eq("organization_id", organizationId),
  ]);

  const errorMessage =
    params.error === "organization-required"
      ? "Organization name, email, phone, and address are required."
      : params.error === "user-required"
        ? "Your full name is required."
        : params.error;

  return (
    <WorkspaceShell active="settings">
      <header className="topbar">
        <div>
          <p className="eyebrow">SETTINGS</p>
          <h1>Settings</h1>
          <p className="muted">Organization and current user settings.</p>
        </div>
        <div className="topbar-org" title={organization.organization_name}>
          <span className="status-dot" />
          <span>{organization.organization_name}</span>
        </div>
      </header>

      {params.saved === "organization" && <div className="form-success" role="status">Organization information updated successfully.</div>}
      {params.saved === "user" && <div className="form-success" role="status">User information updated successfully.</div>}
      {errorMessage && <div className="form-error" role="alert">{errorMessage}</div>}

      <section className="section-heading">
        <div>
          <h2>01 · Workspace</h2>
          <p className="muted">The organization you are currently working in.</p>
        </div>
        <Link className="secondary-button" href="/organization">
          ⇄ Switch Workspace ({organizationIds.length})
        </Link>
      </section>

      <section className="welcome-card" aria-label="Current workspace">
        <div>
          <span className="section-kicker">ACTIVE WORKSPACE</span>
          <h2>{organization.organization_name}</h2>
          <p>Organization #{organization.organization_number} · {organization.status}</p>
        </div>
        <div className="org-number">
          <span>You belong to</span>
          <strong>{organizationIds.length} workspace{organizationIds.length === 1 ? "" : "s"}</strong>
        </div>
      </section>

      <section className="section-heading">
        <div>
          <h2>02 · Workspace Data</h2>
          <p className="muted">Live record counts across your modules.</p>
        </div>
      </section>

      <section className="summary-grid" aria-label="Workspace data overview">
        <Link className="summary-card" href="/products">
          <span>Products</span>
          <strong>{productsCount ?? 0}</strong>
        </Link>
        <Link className="summary-card" href="/contacts">
          <span>Contacts</span>
          <strong>{contactsCount ?? 0}</strong>
        </Link>
        <Link className="summary-card" href="/purchases">
          <span>Purchases</span>
          <strong>{purchasesCount ?? 0}</strong>
        </Link>
        <Link className="summary-card" href="/sales">
          <span>Sales</span>
          <strong>{salesCount ?? 0}</strong>
        </Link>
      </section>

      <section className="section-heading">
        <div>
          <h2>03 · Organization</h2>
          <p className="muted">Details used across this workspace. Number, status and created date are system-managed.</p>
        </div>
        {!editingOrg && <Link className="secondary-button" href="/settings?edit=org">✎ Edit</Link>}
      </section>

      {editingOrg ? (
        <section className="data-card form-panel">
          <form action={updateOrganization} className="form">
            <label>Organization name<span className="required-mark">*</span><input name="organization_name" required defaultValue={organization.organization_name} autoComplete="organization" /></label>
            <div className="info-grid">
              <label>Email<span className="required-mark">*</span><input name="email" required type="email" defaultValue={organization.email} autoComplete="email" /></label>
              <label>Phone<span className="required-mark">*</span><input name="phone_number" required type="tel" defaultValue={organization.phone_number} autoComplete="tel" /></label>
            </div>
            <label>Address<span className="required-mark">*</span><textarea name="address" required rows={3} defaultValue={organization.address} autoComplete="street-address" /></label>
            <div className="info-grid">
              <label>TIN<input name="tin" defaultValue={organization.tin || ""} inputMode="numeric" /></label>
              <label>BIN<input name="bin" defaultValue={organization.bin || ""} inputMode="numeric" /></label>
            </div>
            <div className="form-actions">
              <Link className="secondary-button" href="/settings">Cancel</Link>
              <button className="primary-button" type="submit">Save organization</button>
            </div>
          </form>
        </section>
      ) : (
        <section className="info-grid" aria-label="Organization details">
          <InfoItem label="Organization Name" value={organization.organization_name} />
          <InfoItem label="Email" value={organization.email} />
          <InfoItem label="Phone" value={organization.phone_number} />
          <InfoItem label="Address" value={organization.address} wide />
          <InfoItem label="TIN" value={organization.tin || "Not provided"} />
          <InfoItem label="BIN" value={organization.bin || "Not provided"} />
          <InfoItem label="Status" value={organization.status} badge />
          <InfoItem label="Created date" value={new Date(organization.created_at).toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" })} />
        </section>
      )}

      <section className="section-heading">
        <div>
          <h2>04 · Current User</h2>
          <p className="muted">Your account information. Email and ID are managed by sign-in.</p>
        </div>
        {!editingUser && <Link className="secondary-button" href="/settings?edit=user">✎ Edit</Link>}
      </section>

      {editingUser ? (
        <section className="data-card form-panel">
          <form action={updateCurrentUser} className="form">
            <label>Full name<span className="required-mark">*</span><input name="full_name" required defaultValue={profile?.full_name || ""} autoComplete="name" /></label>
            <div className="form-actions">
              <Link className="secondary-button" href="/settings">Cancel</Link>
              <button className="primary-button" type="submit">Save user information</button>
            </div>
          </form>
        </section>
      ) : (
        <section className="info-grid" aria-label="Current user details">
          <InfoItem label="Full Name" value={profile?.full_name || "Not set"} />
          <InfoItem label="Email" value={user.email || "Not available"} />
          <InfoItem label="User ID" value={user.id} wide />
        </section>
      )}
    </WorkspaceShell>
  );
}

function InfoItem({ label, value, wide = false, badge = false }: { label: string; value: string; wide?: boolean; badge?: boolean }) {
  return <div className={wide ? "info-item wide" : "info-item"}><span>{label}</span>{badge ? <strong className="status-badge">{value}</strong> : <strong>{value}</strong>}</div>;
}

function WorkspaceError({ title, message }: { title: string; message: string }) {
  return <main className="auth-shell"><section className="auth-card"><div className="auth-brand"><span className="brand-mark">P</span><span>Pomelo Inventory</span></div><p className="eyebrow">WORKSPACE ERROR</p><h1>{title}</h1><p className="form-error" role="alert">{message}</p><Link className="secondary-button" href="/login">Return to sign in</Link></section></main>;
}
