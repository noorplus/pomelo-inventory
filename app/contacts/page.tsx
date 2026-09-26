import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import WorkspaceShell from "@/app/components/workspace-shell";

export const dynamic = "force-dynamic";

type SearchParams = { search?: string; status?: string; sort?: string; direction?: string };

export default async function ContactsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).limit(1);
  if (!memberships?.length) redirect("/organization/create");

  const organizationId = memberships[0].organization_id;
  const params = await searchParams;
  const search = String(params.search || "").trim();
  const status = params.status === "Inactive" ? "Inactive" : params.status === "Active" ? "Active" : "";
  const sort = ["id_no", "name", "phone", "email", "address", "status"].includes(params.sort || "") ? String(params.sort) : "id_no";
  const direction = params.direction === "desc" ? "desc" : "asc";

  let query = supabase.from("contacts")
    .select("id, id_no, name, phone, email, address, status, created_at")
    .eq("organization_id", organizationId).order(sort, { ascending: direction === "asc" });

  if (search) {
    const escaped = search.replace(/[,]/g, "");
    query = query.or(`name.ilike.%${escaped}%,phone.ilike.%${escaped}%,email.ilike.%${escaped}%,address.ilike.%${escaped}%`);
  }
  if (status) query = query.eq("status", status);

  const { data: contacts, error } = await query;

  return (
    <WorkspaceShell active="contacts">
      <section className="module-toolbar">
        <div><h1>Contacts</h1><p className="muted">Customers, suppliers, and other business contacts.</p></div>
        <Link className="primary-button" href="/contacts/new">+ Add Contact</Link>
      </section>

      <section className="filter-card" aria-label="Contact filters">
        <form className="contact-filter" method="get">
          <label>Search<input name="search" defaultValue={search} placeholder="Name, phone, email, address" /></label>
          <label>Status<select name="status" defaultValue={status}><option value="">All statuses</option><option value="Active">Active</option><option value="Inactive">Inactive</option></select></label>
          <button className="secondary-button" type="submit">Filter</button>
          {(search || status) && <Link className="filter-clear" href="/contacts">Clear</Link>}
        </form>
      </section>

      {error ? <section className="form-error" role="alert">Unable to load contacts: {error.message}</section> : (
        <section className="table-card">
          <div className="table-meta"><strong>{contacts?.length ?? 0} contact{contacts?.length === 1 ? "" : "s"}</strong>{(search || status) && <span>Filtered results</span>}</div>
          <div className="table-scroll"><table><thead><tr><SortableHeader label="ID No." field="id_no" search={search} status={status} sort={sort} direction={direction} />
              <SortableHeader label="Name" field="name" search={search} status={status} sort={sort} direction={direction} />
              <SortableHeader label="Phone" field="phone" search={search} status={status} sort={sort} direction={direction} />
              <SortableHeader label="Email" field="email" search={search} status={status} sort={sort} direction={direction} />
              <SortableHeader label="Address" field="address" search={search} status={status} sort={sort} direction={direction} />
              <SortableHeader label="Status" field="status" search={search} status={status} sort={sort} direction={direction} /></tr></thead>
            <tbody>{contacts?.map((contact) => <tr key={contact.id}><td><strong className="mono">{contact.id_no}</strong></td><td><strong>{contact.name}</strong></td><td>{contact.phone || "—"}</td><td>{contact.email || "—"}</td><td className="truncate-cell">{contact.address || "—"}</td><td><span className="status-badge">{contact.status}</span></td></tr>)}</tbody>
          </table></div>
          {!contacts?.length && <EmptyState icon="◎" title="No contacts found" text={search || status ? "Try changing your filters." : "Add your first customer or supplier contact."} />}
        </section>
      )}
    </WorkspaceShell>
  );
}

function EmptyState({ icon, title, text }: { icon: string; title: string; text: string }) {
  return <div className="empty-state"><div className="empty-icon">{icon}</div><div><h2>{title}</h2><p>{text}</p></div></div>;
}
