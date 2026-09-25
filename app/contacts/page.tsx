import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import WorkspaceShell from "@/app/components/workspace-shell";

export const dynamic = "force-dynamic";

export default async function ContactsPage() {
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
  const { data: contacts } = await supabase
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
          <p className="muted">Manage centralized customer and supplier contacts for this organization.</p>
        </div>
      </header>

      <section className="data-card">
        <form className="contact-form" action={createContact}>
          <label>Name<input name="name" placeholder="Contact name" required /></label>
          <label>Phone<input name="phone" placeholder="+880..." /></label>
          <label>Email<input name="email" type="email" placeholder="name@example.com" /></label>
          <label>Address<textarea name="address" placeholder="Address" rows={2} /></label>
          <button className="primary-button" type="submit">Add Contact</button>
        </form>
      </section>

      <section className="section-heading">
        <div>
          <h2>Contact list</h2>
          <p className="muted">{contacts?.length ?? 0} contacts in this organization.</p>
        </div>
      </section>

      <section className="table-card">
        <table>
          <thead>
            <tr><th>ID No.</th><th>Name</th><th>Phone</th><th>Email</th><th>Address</th><th>Status</th></tr>
          </thead>
          <tbody>
            {contacts?.map((contact) => (
              <tr key={contact.id}>
                <td><strong>{contact.id_no}</strong></td>
                <td>{contact.name}</td>
                <td>{contact.phone || "—"}</td>
                <td>{contact.email || "—"}</td>
                <td>{contact.address || "—"}</td>
                <td><span className="status-badge">{contact.status}</span></td>
              </tr>
            ))}
          </tbody>
        </table>

        {!contacts?.length && (
          <div className="empty-state">
            <div className="empty-icon">◎</div>
            <div><h2>No contacts yet</h2><p>Add your first customer or supplier contact above.</p></div>
          </div>
        )}
      </section>
    </WorkspaceShell>
  );
}

async function createContact(formData: FormData) {
  "use server";

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .limit(1);

  if (!memberships?.length) redirect("/organization/create");

  const name = String(formData.get("name") || "").trim();
  const phone = String(formData.get("phone") || "").trim();
  const email = String(formData.get("email") || "").trim();
  const address = String(formData.get("address") || "").trim();

  if (!name) return;

  const { error } = await supabase.from("contacts").insert({
    organization_id: memberships[0].organization_id,
    name,
    phone: phone || null,
    email: email || null,
    address: address || null,
    created_by: user.id,
  });

  if (error) return;

  redirect("/contacts");
}
