import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import Pager from "@/app/components/pager";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { PAGE_SIZE, pageRange, parsePageParam } from "@/lib/pagination";

export const dynamic = "force-dynamic";

type SearchParams = { search?: string; status?: string; sort?: string; direction?: string; page?: string };

export default async function SalesPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const params = await searchParams;
  const search = String(params.search || "").trim();
  const status = ["Draft", "Confirmed", "Cancelled"].includes(String(params.status)) ? String(params.status) : "";
  const sort = ["invoice_no", "invoice_date", "total", "status"].includes(String(params.sort)) ? String(params.sort) : "invoice_date";
  const direction = params.direction === "asc" ? "asc" : "desc";
  const page = parsePageParam(params.page);
  const { from, to } = pageRange(page);

  let query = supabase
    .from("sales")
    .select("id, invoice_no, invoice_date, contact_id, total, status, contacts(name)", { count: "exact" })
    .eq("organization_id", organizationId)
    .order(sort, { ascending: direction === "asc" })
    .range(from, to);

  if (search) query = query.ilike("invoice_no", "%" + search.replace(/[\\%_]/g, "\\$&") + "%");
  if (status) query = query.eq("status", status);

  // Summary cards need org-wide numbers without pulling full rows: one narrow
  // confirmed-totals pull for revenue plus cheap head counts for the rest.
  const [{ data: sales, error, count }, { data: confirmedTotals }, { count: draftCount }, { count: confirmedCount }, { count: totalCount }] = await Promise.all([
    query,
    supabase
      .from("sales")
      .select("total")
      .eq("organization_id", organizationId)
      .eq("status", "Confirmed"),
    supabase
      .from("sales")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", organizationId)
      .eq("status", "Draft"),
    supabase
      .from("sales")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", organizationId)
      .eq("status", "Confirmed"),
    supabase
      .from("sales")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", organizationId),
  ]);

  const confirmedSalesTotal = (confirmedTotals ?? []).reduce((sum, s) => sum + Number(s.total || 0), 0);
  const exportParams = new URLSearchParams();
  if (search) exportParams.set("search", search);
  if (status) exportParams.set("status", status);
  const exportUrl = `/sales/export${exportParams.toString() ? `?${exportParams.toString()}` : ""}`;

  return (
    <WorkspaceShell active="sales">
      <section className="module-toolbar">
        <div>
          <p className="eyebrow">SALES MANAGEMENT</p>
          <h1>Sales Orders & Invoices</h1>
          <p className="muted">Manage customer invoices, stock dispatch, accounts receivable, and payment allocations.</p>
        </div>
        <div className="module-actions">
          <Link className="secondary-button" href={exportUrl}>
            ⇩ Export CSV
          </Link>
          <Link className="primary-button" href="/sales/new">
            + New Sale
          </Link>
        </div>
      </section>

      <section className="summary-grid">
        <div className="summary-card">
          <span>Confirmed Revenue</span>
          <strong>৳{confirmedSalesTotal.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</strong>
        </div>
        <div className="summary-card">
          <span>Confirmed Invoices</span>
          <strong>{confirmedCount ?? 0}</strong>
        </div>
        <div className="summary-card">
          <span>Draft Invoices</span>
          <strong>{draftCount ?? 0}</strong>
        </div>
        <div className="summary-card">
          <span>Total Orders</span>
          <strong>{totalCount ?? 0}</strong>
        </div>
      </section>

      <section className="filter-card" aria-label="Sale filters">
        <form className="contact-filter" method="get">
          <label>
            Invoice no.
            <input name="search" defaultValue={search} placeholder="000001" />
          </label>
          <label>
            Status
            <select name="status" defaultValue={status}>
              <option value="">All statuses</option>
              <option value="Draft">Draft</option>
              <option value="Confirmed">Confirmed</option>
              <option value="Cancelled">Cancelled</option>
            </select>
          </label>
          <button className="secondary-button" type="submit">
            Filter
          </button>
          {(search || status) && (
            <Link className="filter-clear" href="/sales">
              Clear
            </Link>
          )}
        </form>
      </section>

      {error ? (
        <section className="form-error" role="alert">
          Unable to load sales: {error.message}
        </section>
      ) : (
        <section className="table-card">
          <div className="table-meta">
            <strong>
              {sales?.length ?? 0} sale{sales?.length === 1 ? "" : "s"}
            </strong>
            {(search || status) && <span>Filtered results</span>}
          </div>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <SortableHeader label="Invoice" field="invoice_no" search={search} status={status} sort={sort} direction={direction} />
                  <SortableHeader label="Date" field="invoice_date" search={search} status={status} sort={sort} direction={direction} />
                  <th>Customer</th>
                  <SortableHeader label="Total" field="total" search={search} status={status} sort={sort} direction={direction} className="numeric" />
                  <SortableHeader label="Status" field="status" search={search} status={status} sort={sort} direction={direction} />
                </tr>
              </thead>
              <tbody>
                {sales?.map((sale) => {
                  const contact = Array.isArray(sale.contacts) ? sale.contacts[0] : sale.contacts;
                  const statusClass =
                    sale.status === "Confirmed"
                      ? "badge-confirmed"
                      : sale.status === "Cancelled"
                      ? "badge-cancelled"
                      : "badge-draft";

                  return (
                    <tr key={sale.id}>
                      <td>
                        <Link href={"/sales/" + sale.id}>
                          <strong className="mono">{sale.invoice_no}</strong>
                        </Link>
                      </td>
                      <td>{sale.invoice_date}</td>
                      <td>{contact?.name || "—"}</td>
                      <td className="numeric">
                        <strong>
                          ৳{Number(sale.total).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                        </strong>
                      </td>
                      <td>
                        <span className={statusClass}>{sale.status}</span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {!sales?.length && (
            <div className="empty-state">
              <div className="empty-icon">↧</div>
              <div>
                <h2>No sales found</h2>
                <p>{search || status ? "Try changing your filters." : "Create your first sales invoice."}</p>
              </div>
            </div>
          )}
          <Pager
            basePath="/sales"
            params={{ search: search || undefined, status: status || undefined, sort, direction }}
            page={page}
            shown={sales?.length ?? 0}
            total={count}
            pageSize={PAGE_SIZE}
          />
        </section>
      )}
    </WorkspaceShell>
  );
}

function SortableHeader({
  label,
  field,
  search,
  status,
  sort,
  direction,
  className = "",
}: {
  label: string;
  field: string;
  search: string;
  status: string;
  sort: string;
  direction: string;
  className?: string;
}) {
  const nextDirection = sort === field && direction === "asc" ? "desc" : "asc";
  const query = new URLSearchParams();
  if (search) query.set("search", search);
  if (status) query.set("status", status);
  query.set("sort", field);
  query.set("direction", nextDirection);
  const indicator = sort === field ? (direction === "asc" ? " ↑" : " ↓") : "";
  return (
    <th className={"sortable-header " + className}>
      <Link href={"/sales?" + query.toString()}>
        {label}
        {indicator}
      </Link>
    </th>
  );
}
