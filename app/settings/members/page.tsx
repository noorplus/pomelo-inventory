import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import SortableHeader from "@/app/components/sortable-header";
import { getWorkspaceMembership } from "@/lib/auth/workspace";
import { addMember, changeMemberRole, removeMember } from "./actions";

type Member = {
  user_id: string;
  full_name: string;
  email: string;
  role: "owner" | "member";
  created_at: string;
};

export default async function MembersPage({ searchParams }: { searchParams: Promise<{ error?: string; sort?: string; direction?: string }> }) {
  const params = await searchParams;
  const sort = ["full_name", "email", "role", "created_at"].includes(params.sort || "") ? String(params.sort) : "full_name";
  const direction = params.direction === "desc" ? "desc" : "asc";
  const { supabase, organizationId, user } = await getWorkspaceMembership();
  const { data, error } = await supabase.rpc("organization_members", { p_organization_id: organizationId });
  const members = [...((data ?? []) as Member[])].sort((a, b) => {
    const av = String(a[sort as keyof Member] ?? "").toLowerCase();
    const bv = String(b[sort as keyof Member] ?? "").toLowerCase();
    const cmp = av.localeCompare(bv, undefined, { numeric: true });
    return direction === "asc" ? cmp : -cmp;
  });
  const currentMember = members.find((member) => member.user_id === user.id);
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
      {isOwner && <section className="data-card form-panel"><form action={addMember} className="form"><label>Add registered user<span className="muted"> — enter their sign-in email</span><input name="email" type="email" required placeholder="member@example.com" autoComplete="email" /></label><div className="form-actions"><button className="primary-button" type="submit">Add member</button></div></form><p className="muted">The user must already have an account. This does not send an invitation email.</p></section>}
      <section className="data-card">
        {members.length ? <div className="table-wrap"><table className="spreadsheet-table data-table"><thead><tr><SortableHeader label="Name" field="full_name" sort={sort} direction={direction} basePath="/settings/members" /><SortableHeader label="Email" field="email" sort={sort} direction={direction} basePath="/settings/members" /><SortableHeader label="Role" field="role" sort={sort} direction={direction} basePath="/settings/members" /><SortableHeader label="Joined" field="created_at" sort={sort} direction={direction} basePath="/settings/members" />{isOwner && <th>Actions</th>}</tr></thead><tbody>
          {members.map((member) => <tr key={member.user_id}><td>{member.full_name}</td><td>{member.email}</td><td><span className="status-badge">{member.role}</span></td><td>{new Date(member.created_at).toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" })}</td>{isOwner && <td><div className="member-actions">
            {member.role === "member" ? <form action={changeMemberRole}><input type="hidden" name="user_id" value={member.user_id} /><input type="hidden" name="role" value="owner" /><button className="secondary-button" type="submit">Make owner</button></form> : member.user_id === user.id ? null : <form action={changeMemberRole}><input type="hidden" name="user_id" value={member.user_id} /><input type="hidden" name="role" value="member" /><button className="secondary-button" type="submit">Make member</button></form>}
            {member.role !== "owner" && <form action={removeMember}><input type="hidden" name="user_id" value={member.user_id} /><button className="secondary-button" type="submit">Remove</button></form>}
          </div></td>}</tr>)}
        </tbody></table></div> : <div className="empty-state">No members found.</div>}
      </section>
    </WorkspaceShell>
  );
}
