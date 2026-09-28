import Link from "next/link";
import CsvActions from "@/app/components/csv-actions";
import WorkspaceShell from "@/app/components/workspace-shell";
import Pager from "@/app/components/pager";
import SortableHeader from "@/app/components/sortable-header";

import { getWorkspaceContext } from "@/lib/auth/workspace";
import { PAGE_SIZE, pageRange, parsePageParam } from "@/lib/pagination";

import DataTable from "@/app/components/data-table";
export const dynamic = "force-dynamic";

type SearchParams = { search?: string; status?: string; sort?: string; direction?: string; page?: string };

export default async function ContactsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const params = await searchParams;
  const search = String(params.search || "").trim();
  const status = params.status === "Inactive" ? "Inactive" : params.status === "Active" ? "Active" : "";
  const sort = ["id_no", "name", "phone", "email", "address", "status"].includes(params.sort || "") ? String(params.sort) : "id_no";
  const direction = params.direction === "desc" ? "desc" : "asc";
  const page = parsePageParam(params.page);
  const { from, to } = pageRange(page);

  let query = supabase.from("contacts").select("id, id_no, name, phone, email, address, status", { count: "exact" }).eq("organization_id", organizationId).order(sort, { ascending: direction === "asc" }).range(from, to);

  if (search) {
    const escaped = search.replace(/[\\%,_]/g, (character) => `\\${character}`).replace(/,/g, "");
    query = query.or(`name.ilike.%${escaped}%,phone.ilike.%${escaped}%,email.ilike.%${escaped}%,address.ilike.%${escaped}%`);
  }
  if (status) query = query.eq("status", status);

  const { data: contacts, error, count } = await query;
  const exportParams = new URLSearchParams();
  if (search) exportParams.set("search", search);
  if (status) exportParams.set("status", status);
  const exportUrl = `/contacts/export${exportParams.toString() ? `?${exportParams.toString()}` : ""}`;

  return (
    <WorkspaceShell active="contacts">
      <section className="module-toolbar">
        <div><h1>Contacts</h1><p className="muted">Customers, suppliers, and other business contacts.</p></div>
        <div className="module-actions">
          <Link className="primary-button" href="/contacts/new">+ Add Contact</Link>
          <CsvActions exportUrl={exportUrl} importUrl="/contacts/import" />
        </div>
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
          <div className="table-scroll"><DataTable><thead><tr><SortableHeader label="ID No." field="id_no" sort={sort} direction={direction} basePath="/contacts" params={{ search, status }} />
              <SortableHeader label="Name" field="name" sort={sort} direction={direction} basePath="/contacts" params={{ search, status }} />
              <SortableHeader label="Phone" field="phone" sort={sort} direction={direction} basePath="/contacts" params={{ search, status }} />
              <SortableHeader label="Email" field="email" sort={sort} direction={direction} basePath="/contacts" params={{ search, status }} />
              <SortableHeader label="Address" field="address" sort={sort} direction={direction} basePath="/contacts" params={{ search, status }} />
              <SortableHeader label="Status" field="status" sort={sort} direction={direction} basePath="/contacts" params={{ search, status }} /><th>Action</th></tr></thead>
            <tbody>{contacts?.map((contact) => <tr key={contact.id}><td><strong className="mono">{contact.id_no}</strong></td><td><Link href={"/contacts/" + contact.id}><strong>{contact.name}</strong></Link></td><td>{contact.phone || "—"}</td><td>{contact.email || "—"}</td><td className="truncate-cell">{contact.address || "—"}</td><td><span className="status-badge">{contact.status}</span></td><td><form action={toggleContactStatus}><input type="hidden" name="id" value={contact.id} /><input type="hidden" name="status" value={contact.status === "Active" ? "Inactive" : "Active"} /><button className="secondary-button table-action-button" type="submit">{contact.status === "Active" ? "Deactivate" : "Activate"}</button></form></td></tr>)}</tbody>
          </DataTable></div>
          {!contacts?.length && <EmptyState icon="◎" title="No contacts found" text={search || status ? "Try changing your filters." : "Add your first customer or supplier contact."} />}
          <Pager
            basePath="/contacts"
            params={{ search: search || undefined, status: status || undefined, sort, direction }}
            page={page}
            shown={contacts?.length ?? 0}
            total={count}
            pageSize={PAGE_SIZE}
          />
        </section>
      )}
    </WorkspaceShell>
  );
}

function EmptyState({ icon, title, text }: { icon: string; title: string; text: string }) {
  return <div className="empty-state"><div className="empty-icon">{icon}</div><div><h2>{title}</h2><p>{text}</p></div></div>;
}

async function toggleContactStatus(formData: FormData) {
  "use server";
  const { supabase, organizationId } = await getWorkspaceContext();
  const id = String(formData.get("id") || "").trim();
  const nextStatus = String(formData.get("status") || "").trim();
  if (!id || !["Active", "Inactive"].includes(nextStatus)) return;
  await supabase.from("contacts").update({ status: nextStatus }).eq("id", id).eq("organization_id", organizationId);
}

