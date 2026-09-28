import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import Pager from "@/app/components/pager";
import SortableHeader from "@/app/components/sortable-header";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { PAGE_SIZE, pageRange, parsePageParam } from "@/lib/pagination";

import DataTable from "@/app/components/data-table";
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
  const exportParams = new URLSearchParams();
  if (search) exportParams.set("search", search);
  if (status) exportParams.set("status", status);
  const exportUrl = `/purchases/export${exportParams.toString() ? `?${exportParams.toString()}` : ""}`;

  return (
    <WorkspaceShell active="purchases">
      <section className="module-toolbar">
        <div><h1>Purchases</h1><p className="muted">Purchase invoices, stock receipts, payables, and lifecycle status.</p></div>
        <div className="module-actions"><Link className="secondary-button" href={exportUrl}>⇩ Export CSV</Link><Link className="primary-button" href="/purchases/new">+ New Purchase</Link></div>
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
          <div className="table-scroll"><DataTable><thead><tr>
            <SortableHeader label="Invoice" field="invoice_no" sort={sort} direction={direction} basePath="/purchases" params={{ search, status }} />
            <SortableHeader label="Date" field="invoice_date" sort={sort} direction={direction} basePath="/purchases" params={{ search, status }} />
            <th>Contact</th>
            <SortableHeader label="Total" field="total" sort={sort} direction={direction} basePath="/purchases" params={{ search, status }} className="numeric" />
            <SortableHeader label="Status" field="status" sort={sort} direction={direction} basePath="/purchases" params={{ search, status }} />
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
          })}</tbody></DataTable></div>
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

