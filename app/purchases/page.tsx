import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import Pager from "@/app/components/pager";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { PAGE_SIZE, pageRange, parsePageParam } from "@/lib/pagination";

export const dynamic = "force-dynamic";

type SearchParams = { search?: string; status?: string; sort?: string; direction?: string; page?: string };

export default async function PurchasesPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const params = await searchParams;
  const search = String(params.search || "").trim();
  const status = ["Draft", "Confirmed", "Cancelled"].includes(String(params.status)) ? String(params.status) : "";
  const sort = ["invoice_no", "invoice_date", "total", "status"].includes(String(params.sort)) ? String(params.sort) : "invoice_date";
  const direction = params.direction === "asc" ? "asc" : "desc";
  const page = parsePageParam(params.page);
  const { from, to } = pageRange(page);

  let query = supabase
    .from("purchases")
    .select("id, invoice_no, invoice_date, contact_id, total, status, contacts(name)", { count: "exact" })
    .eq("organization_id", organizationId)
    .order(sort, { ascending: direction === "asc" })
    .range(from, to);

  if (search) query = query.ilike("invoice_no", "%" + search.replace(/[\\%_]/g, "\\$&") + "%");
  if (status) query = query.eq("status", status);

  const { data: purchases, error, count } = await query;

  return (
    <WorkspaceShell active="purchases">
      <section className="module-toolbar">
        <div><h1>Purchases</h1><p className="muted">Purchase invoices, stock receipts, payables, and lifecycle status.</p></div>
        <div className="module-actions"><Link className="primary-button" href="/purchases/new">+ New Purchase</Link></div>
      </section>

      <section className="filter-card" aria-label="Purchase filters">
        <form className="contact-filter" method="get">
          <label>Invoice no.<input name="search" defaultValue={search} placeholder="000001" /></label>
          <label>Status<select name="status" defaultValue={status}><option value="">All statuses</option><option value="Draft">Draft</option><option value="Confirmed">Confirmed</option><option value="Cancelled">Cancelled</option></select></label>
          <button className="secondary-button" type="submit">Filter</button>
          {(search || status) && <Link className="filter-clear" href="/purchases">Clear</Link>}
        </form>
      </section>

      {error ? <section className="form-error" role="alert">Unable to load purchases: {error.message}</section> : (
        <section className="table-card">
          <div className="table-meta"><strong>{purchases?.length ?? 0} purchase{purchases?.length === 1 ? "" : "s"}</strong>{(search || status) && <span>Filtered results</span>}</div>
          <div className="table-scroll"><table><thead><tr>
            <SortableHeader label="Invoice" field="invoice_no" search={search} status={status} sort={sort} direction={direction} />
            <SortableHeader label="Date" field="invoice_date" search={search} status={status} sort={sort} direction={direction} />
            <th>Contact</th>
            <SortableHeader label="Total" field="total" search={search} status={status} sort={sort} direction={direction} className="numeric" />
            <SortableHeader label="Status" field="status" search={search} status={status} sort={sort} direction={direction} />
          </tr></thead>
          <tbody>{purchases?.map((purchase) => {
            const contact = Array.isArray(purchase.contacts) ? purchase.contacts[0] : purchase.contacts;
            return <tr key={purchase.id}>
              <td><Link href={"/purchases/" + purchase.id}><strong className="mono">{purchase.invoice_no}</strong></Link></td>
              <td>{purchase.invoice_date}</td>
              <td>{contact?.name || "—"}</td>
              <td className="numeric"><strong>৳{Number(purchase.total).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</strong></td>
              <td><span className="status-badge">{purchase.status}</span></td>
            </tr>;
          })}</tbody></table></div>
          {!purchases?.length && <div className="empty-state"><div className="empty-icon">↥</div><div><h2>No purchases found</h2><p>{search || status ? "Try changing your filters." : "Create your first purchase invoice."}</p></div></div>}
          <Pager
            basePath="/purchases"
            params={{ search: search || undefined, status: status || undefined, sort, direction }}
            page={page}
            shown={purchases?.length ?? 0}
            total={count}
            pageSize={PAGE_SIZE}
          />
        </section>
      )}
    </WorkspaceShell>
  );
}

function SortableHeader({ label, field, search, status, sort, direction, className = "" }: { label: string; field: string; search: string; status: string; sort: string; direction: string; className?: string }) {
  const nextDirection = sort === field && direction === "asc" ? "desc" : "asc";
  const query = new URLSearchParams();
  if (search) query.set("search", search);
  if (status) query.set("status", status);
  query.set("sort", field);
  query.set("direction", nextDirection);
  const indicator = sort === field ? (direction === "asc" ? " ↑" : " ↓") : "";
  return <th className={"sortable-header " + className}><Link href={"/purchases?" + query.toString()}>{label}{indicator}</Link></th>;
}
