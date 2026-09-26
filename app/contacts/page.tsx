import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import WorkspaceShell from "@/app/components/workspace-shell";

export const dynamic = "force-dynamic";

export default async function ContactsPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).limit(1);
  if (!memberships?.length) redirect("/organization/create");

  const organizationId = memberships[0].organization_id;
  const { data: contacts, error } = await supabase
    .from("contacts")
    .select("id, id_no, name, phone, email, address, status, created_at")
    .eq("organization_id", organizationId)
    .order("id_no");

  return (
    <WorkspaceShell active="contacts">
      <header className="topbar">
        <div>
          <p className="eyebrow">MASTER DATA</p>
          <h1>Contacts</h1>
          <p className="muted">Centralized customer and supplier contact records.</p>
        </div>
        <span className="page-count">{contacts?.length ?? 0} records</span>
      </header>

      <section className="data-card form-panel" aria-labelledby="new-contact-title">
        <div className="panel-heading">
          <div><h2 id="new-contact-title">Add contact</h2><p className="muted">Create a contact for this organization.</p></div>
        </div>
        <form className="contact-form" action={createContact}>
          <label>Name<span className="required-mark">*</span><input name="name" placeholder="Contact name" required /></label>
          <label>Phone<input name="phone" type="tel" placeholder="+880..." /></label>
          <label>Email<input name="email" type="email" placeholder="name@example.com" /></label>
          <label className="contact-address">Address<textarea name="address" placeholder="Business or delivery address" rows={2} /></label>
          <button className="primary-button" type="submit">Add Contact</button>
        </form>
      </section>

      <section className="section-heading">
        <div><h2>Contact list</h2><p className="muted">All contacts belonging to this organization.</p></div>
      </section>

      {error ? (
        <section className="form-error" role="alert">Unable to load contacts: {error.message}</section>
      ) : (
        <section className="table-card">
          <div className="table-scroll">
            <table>
              <thead><tr><th>ID No.</th><th>Name</th><th>Phone</th><th>Email</th><th>Address</th><th>Status</th></tr></thead>
              <tbody>
                {contacts?.map((contact) => (
                  <tr key={contact.id}>
                    <td><strong className="mono">{contact.id_no}</strong></td>
                    <td><strong>{contact.name}</strong></td>
                    <td>{contact.phone || "—"}</td>
                    <td>{contact.email || "—"}</td>
                    <td className="truncate-cell">{contact.address || "—"}</td>
                    <td><span className="status-badge">{contact.status}</span></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {!contacts?.length && <EmptyState icon="◎" title="No contacts yet" text="Add your first customer or supplier contact above." />}
        </section>
      )}
    </WorkspaceShell>
  );
}

async function createContact(formData: FormData) {
  "use server";
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");
  const { data: memberships } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).limit(1);
  if (!memberships?.length) redirect("/organization/create");

  const name = String(formData.get("name") || "").trim();
  const phone = String(formData.get("phone") || "").trim();
  const email = String(formData.get("email") || "").trim();
  const address = String(formData.get("address") || "").trim();
  if (!name) return;

  const { error } = await supabase.from("contacts").insert({
    organization_id: memberships[0].organization_id, name,
    phone: phone || null, email: email || null, address: address || null, created_by: user.id,
  });
  if (error) return;
  redirect("/contacts");
}

function EmptyState({ icon, title, text }: { icon: string; title: string; text: string }) {
  return <div className="empty-state"><div className="empty-icon">{icon}</div><div><h2>{title}</h2><p>{text}</p></div></div>;
}
