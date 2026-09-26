import Link from "next/link";
import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import WorkspaceShell from "@/app/components/workspace-shell";
import { ACTIVE_ORG_COOKIE, getWorkspaceMembership } from "@/lib/auth/workspace";

export const dynamic = "force-dynamic";

export async function switchOrganization(formData: FormData) {
  "use server";
  const { organizationIds } = await getWorkspaceMembership();
  const organizationId = String(formData.get("organization_id") || "").trim();

  if (!organizationIds.includes(organizationId)) redirect("/organization?error=invalid");

  const cookieStore = await cookies();
  cookieStore.set(ACTIVE_ORG_COOKIE, organizationId, {
    path: "/",
    maxAge: 60 * 60 * 24 * 365,
    sameSite: "lax",
  });
  redirect("/");
}

export default async function OrganizationPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const params = await searchParams;
  const { supabase, organizationId, organizationIds } = await getWorkspaceMembership();

  const { data: organizations } = await supabase
    .from("organizations")
    .select("id, organization_number, organization_name, status")
    .in("id", organizationIds)
    .order("organization_name");

  return (
    <WorkspaceShell active="settings">
      <section className="form-page">
        <div className="form-page-header">
          <div>
            <p className="eyebrow">WORKSPACES</p>
            <h1>Your Organizations</h1>
            <p className="muted">Switch between workspaces you belong to, or create a new one.</p>
          </div>
          <Link className="secondary-button" href="/organization/create">+ New Organization</Link>
        </div>

        {params.error && <div className="form-error" role="alert">Invalid organization selection.</div>}

        <section className="table-card">
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Organization</th>
                  <th>Number</th>
                  <th>Status</th>
                  <th className="numeric">Active</th>
                </tr>
              </thead>
              <tbody>
                {(organizations ?? []).map((org) => (
                  <tr key={org.id}>
                    <td><strong>{org.organization_name}</strong></td>
                    <td><span className="mono">#{org.organization_number}</span></td>
                    <td><span className="status-badge">{org.status}</span></td>
                    <td className="numeric">
                      {org.id === organizationId ? (
                        <span className="badge-confirmed">Current</span>
                      ) : (
                        <form action={switchOrganization}>
                          <input type="hidden" name="organization_id" value={org.id} />
                          <button className="secondary-button pager-button" type="submit">Switch</button>
                        </form>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {!organizations?.length && (
            <div className="empty-state">
              <div className="empty-icon">◎</div>
              <div><h2>No organizations</h2><p>Create your first workspace to get started.</p></div>
            </div>
          )}
        </section>
      </section>
    </WorkspaceShell>
  );
}
