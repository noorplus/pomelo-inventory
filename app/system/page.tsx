'use server';

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import WorkspaceShell from "@/app/components/workspace-shell";
import { createClient } from "@/lib/supabase/server";

export async function updateSystemProfile(formData: FormData) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships, error: membershipError } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .limit(1);

  if (membershipError || !memberships?.length) redirect("/organization/create");

  const organizationId = memberships[0].organization_id;
  const organizationName = String(formData.get("organization_name") || "").trim();
  const email = String(formData.get("email") || "").trim();
  const phoneNumber = String(formData.get("phone_number") || "").trim();
  const address = String(formData.get("address") || "").trim();
  const tin = String(formData.get("tin") || "").trim() || null;
  const bin = String(formData.get("bin") || "").trim() || null;
  const fullName = String(formData.get("full_name") || "").trim();

  if (!organizationName || !email || !phoneNumber || !address || !fullName) {
    redirect("/system?error=required");
  }

  const { error: organizationError } = await supabase
    .from("organizations")
    .update({
      organization_name: organizationName,
      email,
      phone_number: phoneNumber,
      address,
      tin,
      bin,
    })
    .eq("id", organizationId);

  if (organizationError) redirect("/system?error=" + encodeURIComponent(organizationError.message));

  const { error: profileError } = await supabase
    .from("profiles")
    .update({ full_name: fullName })
    .eq("id", user.id);

  if (profileError) redirect("/system?error=" + encodeURIComponent(profileError.message));

  revalidatePath("/");
  revalidatePath("/system");
  redirect("/system?saved=1");
}

export default async function SystemPage({ searchParams }: { searchParams: Promise<{ saved?: string; error?: string }> }) {
  const params = await searchParams;
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .limit(1);

  if (!memberships?.length) redirect("/organization/create");

  const organizationId = memberships[0].organization_id;
  const [{ data: organization }, { data: profile }] = await Promise.all([
    supabase
      .from("organizations")
      .select("id, organization_number, organization_name, email, phone_number, address, tin, bin, status, created_at")
      .eq("id", organizationId)
      .single(),
    supabase.from("profiles").select("full_name").eq("id", user.id).single(),
  ]);

  if (!organization) {
    return <WorkspaceError title="Organization unavailable" message="Your organization could not be found." />;
  }

  const errorMessage = params.error === "required" ? "Please complete all required fields." : params.error;

  return (
    <WorkspaceShell active="system">
      <header className="topbar">
        <div>
          <p className="eyebrow">SYSTEM</p>
          <h1>System</h1>
          <p className="muted">Organization and current user information.</p>
        </div>
        <div className="topbar-org" title={organization.organization_name}>
          <span className="status-dot" />
          <span>{organization.organization_name}</span>
        </div>
      </header>

      {params.saved === "1" && <div className="form-success" role="status">System information updated successfully.</div>}
      {errorMessage && <div className="form-error" role="alert">{errorMessage}</div>}

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
          <p className="muted">Update the organization details used across this workspace.</p>
        </div>
      </section>

      <section className="data-card form-panel">
        <form action={updateSystemProfile} className="form">
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
          <div className="info-grid">
            <div className="info-item"><span>Organization number</span><strong>#{organization.organization_number}</strong></div>
            <div className="info-item"><span>Status</span><strong className="status-badge">{organization.status}</strong></div>
          </div>
          <input type="hidden" name="full_name" value={profile?.full_name || user.email || "User"} />
          <button className="primary-button" type="submit">Save organization</button>
        </form>
      </section>

      <section className="section-heading">
        <div>
          <h2>Current user information</h2>
          <p className="muted">Your account information for this workspace.</p>
        </div>
      </section>

      <section className="data-card form-panel">
        <form action={updateSystemProfile} className="form">
          <input type="hidden" name="organization_name" value={organization.organization_name} />
          <input type="hidden" name="email" value={organization.email} />
          <input type="hidden" name="phone_number" value={organization.phone_number} />
          <input type="hidden" name="address" value={organization.address} />
          <input type="hidden" name="tin" value={organization.tin || ""} />
          <input type="hidden" name="bin" value={organization.bin || ""} />
          <label>Full name<span className="required-mark">*</span><input name="full_name" required defaultValue={profile?.full_name || ""} autoComplete="name" /></label>
          <div className="info-grid">
            <div className="info-item"><span>Email</span><strong>{user.email || "Not available"}</strong></div>
            <div className="info-item"><span>User ID</span><strong className="mono">{user.id}</strong></div>
          </div>
          <button className="primary-button" type="submit">Save user information</button>
        </form>
      </section>

      <section className="section-heading">
        <div><h2>Organization details</h2><p className="muted">Reference information from the organization record.</p></div>
      </section>
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
    </WorkspaceShell>
  );
}

function InfoItem({ label, value, wide = false, badge = false }: { label: string; value: string; wide?: boolean; badge?: boolean }) {
  return <div className={wide ? "info-item wide" : "info-item"}><span>{label}</span>{badge ? <strong className="status-badge">{value}</strong> : <strong>{value}</strong>}</div>;
}

function WorkspaceError({ title, message }: { title: string; message: string }) {
  return <main className="auth-shell"><section className="auth-card"><div className="auth-brand"><span className="brand-mark">P</span><span>Pomelo Inventory</span></div><p className="eyebrow">WORKSPACE ERROR</p><h1>{title}</h1><p className="form-error" role="alert">{message}</p><a className="secondary-button" href="/auth/login">Return to sign in</a></section></main>;
}
