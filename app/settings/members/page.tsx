import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceMembership } from "@/lib/auth/workspace";

function go(message?: string) {
  redirect(message ? `/settings/members?error=${encodeURIComponent(message)}` : "/settings/members");
}

export async function addMember(formData: FormData) {
  "use server";
  const { supabase, organizationId } = await getWorkspaceMembership();
  const email = String(formData.get("email") || "").trim();
  if (!email) go("email-required");
  const { error } = await supabase.rpc("add_organization_member", { p_organization_id: organizationId, p_email: email });
  if (error) go(error.message.includes("No registered user") ? "user-not-found" : error.message.includes("already a member") ? "already-member" : "member-action-failed");
  revalidatePath("/settings/members");
  go();
}

export async function changeMemberRole(formData: FormData) {
  "use server";
  const { supabase, organizationId } = await getWorkspaceMembership();
  const userId = String(formData.get("user_id") || "");
  const role = String(formData.get("role") || "");
  if (!userId || !["owner", "member"].includes(role)) go("invalid-role");
  const { error } = await supabase.rpc("set_organization_member_role", { p_organization_id: organizationId, p_user_id: userId, p_role: role });
  if (error) go(error.message.includes("Transfer ownership") ? "transfer-ownership-first" : "member-action-failed");
  revalidatePath("/settings/members");
  go();
}

export async function removeMember(formData: FormData) {
  "use server";
  const { supabase, organizationId } = await getWorkspaceMembership();
  const userId = String(formData.get("user_id") || "");
  if (!userId) go("invalid-member");
  const { error } = await supabase.rpc("remove_organization_member", { p_organization_id: organizationId, p_user_id: userId });
  if (error) go(error.message.includes("owner") ? "owner-protected" : "member-action-failed");
  revalidatePath("/settings/members");
  go();
}

export default async function MembersPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  const params = await searchParams;
  const { supabase, organizationId, user } = await getWorkspaceMembership();
  const { data: members, error } = await supabase.rpc("organization_members", { p_organization_id: organizationId });
  const currentMember = (members || []).find((member) => member.user_id === user.id);
  const isOwner = currentMember?.role === "owner";
  const message =
    params.error === "email-required" ? "Enter a member email address." :
    params.error === "user-not-found" ? "No registered user exists with that email address." :
    params.error === "already-member" ? "That user is already a member of this organization." :
    params.error === "owner-protected" ? "Ownership must be transferred before the owner can be removed." :
    params.error === "transfer-ownership-first" ? "Transfer ownership before leaving the owner role." :
    params.error === "invalid-role" ? "Invalid member role." :
    params.error === "invalid-member" ? "Member information is invalid." :
    params.error === "member-action-failed" ? "The member operation could not be completed." :
    error ? "Unable to load organization members." : "";

  return (
    <WorkspaceShell active="settings">
      <header className="topbar"><div><p className="eyebrow">SETTINGS · MEMBERS</p><h1>Organization Members</h1><p className="muted">Manage access to this organization using the existing membership records.</p></div><Link className="secondary-button" href="/settings">← Settings</Link></header>
      {message && <div className="form-error" role="alert">{message}</div>}
      <section className="section-heading"><div><h2>Members</h2><p className="muted">Owners can add registered users, transfer ownership, and remove members.</p></div></section>
      {isOwner && <section className="data-card form-panel"><form action={addMember} className="form"><label>Add registered user<span className="muted"> — enter their sign-in email</span><input name="email" type="email" required placeholder="member@example.com" autoComplete="email" /></label><div className="form-actions"><button className="primary-button" type="submit">Add member</button></div></form><p className="muted" style={{ marginTop: 12 }}>The user must already have an account. This does not send an invitation email.</p></section>}
      <section className="data-card">
        {members?.length ? <div className="table-wrap"><table className="data-table"><thead><tr><th>Name</th><th>Email</th><th>Role</th><th>Joined</th>{isOwner && <th>Actions</th>}</tr></thead><tbody>
          {members.map((member) => <tr key={member.user_id}><td>{member.full_name}</td><td>{member.email}</td><td><span className="status-badge">{member.role}</span></td><td>{new Date(member.created_at).toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" })}</td>{isOwner && <td><div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
            {member.role === "member" ? <form action={changeMemberRole}><input type="hidden" name="user_id" value={member.user_id} /><input type="hidden" name="role" value="owner" /><button className="secondary-button" type="submit">Make owner</button></form> : member.user_id === user.id ? null : <form action={changeMemberRole}><input type="hidden" name="user_id" value={member.user_id} /><input type="hidden" name="role" value="member" /><button className="secondary-button" type="submit">Make member</button></form>}
            {member.role !== "owner" && <form action={removeMember}><input type="hidden" name="user_id" value={member.user_id} /><button className="secondary-button" type="submit">Remove</button></form>}
          </div></td>}</tr>)}
        </tbody></table></div> : <div className="empty-state">No members found.</div>}
      </section>
    </WorkspaceShell>
  );
}
