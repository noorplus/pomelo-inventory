import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";

export const dynamic = "force-dynamic";

export default async function NewContactPage() {
  await getWorkspaceContext();

  return (
    <WorkspaceShell active="contacts">
      <section className="form-page">
        <div className="form-page-header">
          <div><p className="eyebrow">CONTACTS</p><h1>Add Contact</h1><p className="muted">Create a customer, supplier, or other business contact.</p></div>
          <a className="secondary-button" href="/contacts">Back to Contacts</a>
        </div>
        <section className="data-card">
          <form className="contact-form contact-form-page" action={createContact}>
            <label>Name<span className="required-mark">*</span><input name="name" placeholder="Contact name" required /></label>
            <label>Phone<input name="phone" type="tel" placeholder="+880..." /></label>
            <label>Email<input name="email" type="email" placeholder="name@example.com" /></label>
            <label className="contact-address">Address<textarea name="address" placeholder="Business or delivery address" rows={4} /></label>
            <button className="primary-button" type="submit">Save Contact</button>
          </form>
        </section>
      </section>
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
  if (!name) return;

  const phone = String(formData.get("phone") || "").trim();
  const email = String(formData.get("email") || "").trim();
  const address = String(formData.get("address") || "").trim();

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
