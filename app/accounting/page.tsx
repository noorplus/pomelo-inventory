import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import Pager from "@/app/components/pager";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { createExpenseCategory } from "@/app/accounting/actions";
import { PAGE_SIZE, pageRange, parsePageParam } from "@/lib/pagination";

export const dynamic = "force-dynamic";

type SearchParams = {
  tab?: string;
  search?: string;
  type?: string;
  status?: string;
  page?: string;
};

export default async function AccountingPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const params = await searchParams;
  const currentTab = ["payments", "expenses", "categories", "ledger"].includes(String(params.tab))
    ? String(params.tab)
    : "payments";
  const page = parsePageParam(params.page);
  const { from, to } = pageRange(page);

  // Fetch only what the active tab needs. Summary cards use narrow
  // status-filtered pulls plus a head count instead of full tables.
  const [
    { data: confirmedPayments },
    { data: confirmedExpenses },
    { count: pendingPaymentsCount },
    { data: payments, count: paymentsCount },
    { data: expenses, count: expensesCount },
    { data: categories },
    { data: ledger },
  ] = await Promise.all([
    supabase
      .from("payments")
      .select("payment_type, amount")
      .eq("organization_id", organizationId)
      .eq("status", "Confirmed"),
    supabase
      .from("expenses")
      .select("amount")
      .eq("organization_id", organizationId)
      .eq("status", "Confirmed"),
    supabase
      .from("payments")
      .select("id", { count: "exact", head: true })
      .eq("organization_id", organizationId)
      .eq("status", "Draft"),
    currentTab === "payments"
      ? supabase
          .from("payments")
          .select("id, payment_no, payment_date, payment_type, contact_id, amount, payment_method, reference_no, status, contacts(name)", { count: "exact" })
          .eq("organization_id", organizationId)
          .order("payment_date", { ascending: false })
          .range(from, to)
      : Promise.resolve({ data: null, count: null }),
    currentTab === "expenses"
      ? supabase
          .from("expenses")
          .select("id, expense_no, expense_date, description, amount, status, expense_categories(name), contacts(name)", { count: "exact" })
          .eq("organization_id", organizationId)
          .order("expense_date", { ascending: false })
          .range(from, to)
      : Promise.resolve({ data: null, count: null }),
    currentTab === "categories"
      ? supabase
          .from("expense_categories")
          .select("id, name, status, created_at")
          .eq("organization_id", organizationId)
          .order("name")
      : Promise.resolve({ data: null }),
    currentTab === "ledger"
      ? supabase
          .from("account_transactions")
          .select("id, transaction_date, transaction_type, reference_type, reference_id, description, debit, credit, contacts(name)")
          .eq("organization_id", organizationId)
          .order("transaction_date", { ascending: false })
          .limit(100)
      : Promise.resolve({ data: null }),
  ]);

  // Aggregate metrics
  const totalReceived = (confirmedPayments ?? [])
    .filter((p) => p.payment_type === "In")
    .reduce((sum, p) => sum + Number(p.amount || 0), 0);

  const totalPaidOut = (confirmedPayments ?? [])
    .filter((p) => p.payment_type === "Out")
    .reduce((sum, p) => sum + Number(p.amount || 0), 0);

  const totalConfirmedExpenses = (confirmedExpenses ?? []).reduce((sum, e) => sum + Number(e.amount || 0), 0);

  return (
    <WorkspaceShell active="accounting">
      <section className="module-toolbar">
        <div>
          <p className="eyebrow">FINANCE & ACCOUNTING</p>
          <h1>Accounting & Cash Flow</h1>
          <p className="muted">Customer receipts, supplier payments, operational expenses, and double-entry ledger entries.</p>
        </div>
        <div className="module-actions">
          <Link className="secondary-button" href="/accounting/expenses/new">
            + New Expense
          </Link>
          <Link className="primary-button" href="/accounting/payments/new">
            + Record Payment
          </Link>
        </div>
      </section>

      <section className="summary-grid">
        <div className="summary-card">
          <span>Total Received (In)</span>
          <strong style={{ color: "var(--success)" }}>
            ৳{totalReceived.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
          </strong>
        </div>
        <div className="summary-card">
          <span>Total Paid Out (Out)</span>
          <strong style={{ color: "var(--primary-dark)" }}>
            ৳{totalPaidOut.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
          </strong>
        </div>
        <div className="summary-card">
          <span>Confirmed Expenses</span>
          <strong style={{ color: "var(--danger)" }}>
            ৳{totalConfirmedExpenses.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
          </strong>
        </div>
        <div className="summary-card">
          <span>Pending Draft Payments</span>
          <strong>{pendingPaymentsCount ?? 0}</strong>
        </div>
      </section>

      <div className="module-tabs">
        <Link
          className={`tab-link ${currentTab === "payments" ? "active" : ""}`}
          href="/accounting?tab=payments"
        >
          <span>💳 Payments (In/Out)</span>
          <span className="tab-badge">{paymentsCount ?? 0}</span>
        </Link>
        <Link
          className={`tab-link ${currentTab === "expenses" ? "active" : ""}`}
          href="/accounting?tab=expenses"
        >
          <span>📉 Expenses</span>
          <span className="tab-badge">{expensesCount ?? 0}</span>
        </Link>
        <Link
          className={`tab-link ${currentTab === "categories" ? "active" : ""}`}
          href="/accounting?tab=categories"
        >
          <span>🏷️ Expense Categories</span>
          <span className="tab-badge">{categories?.length ?? 0}</span>
        </Link>
        <Link
          className={`tab-link ${currentTab === "ledger" ? "active" : ""}`}
          href="/accounting?tab=ledger"
        >
          <span>📖 General Ledger</span>
          <span className="tab-badge">{ledger?.length ?? 0}</span>
        </Link>
      </div>

      {currentTab === "payments" && (
        <section className="table-card">
          <div className="table-meta">
            <strong>{payments?.length ?? 0} payment(s)</strong>
            <span>Recorded customer collections and vendor payouts</span>
          </div>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Payment No</th>
                  <th>Date</th>
                  <th>Type</th>
                  <th>Contact</th>
                  <th className="numeric">Amount</th>
                  <th>Method</th>
                  <th>Reference</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {payments?.map((p) => {
                  const contact = Array.isArray(p.contacts) ? p.contacts[0] : p.contacts;
                  const isTypeIn = p.payment_type === "In";
                  const statusClass =
                    p.status === "Confirmed"
                      ? "badge-confirmed"
                      : p.status === "Cancelled"
                      ? "badge-cancelled"
                      : "badge-draft";

                  return (
                    <tr key={p.id}>
                      <td>
                        <Link href={`/accounting/payments/${p.id}`}>
                          <strong className="mono">{p.payment_no}</strong>
                        </Link>
                      </td>
                      <td>{p.payment_date}</td>
                      <td>
                        <span className={isTypeIn ? "badge-in" : "badge-out"}>
                          {isTypeIn ? "↓ Payment In" : "↑ Payment Out"}
                        </span>
                      </td>
                      <td>{contact?.name || "—"}</td>
                      <td className="numeric">
                        <strong>
                          ৳{Number(p.amount).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                        </strong>
                      </td>
                      <td>{p.payment_method}</td>
                      <td>{p.reference_no || "—"}</td>
                      <td>
                        <span className={statusClass}>{p.status}</span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {!payments?.length && (
            <div className="empty-state">
              <div className="empty-icon">💳</div>
              <div>
                <h2>No payments recorded</h2>
                <p>Record your first customer receipt or supplier payout.</p>
              </div>
            </div>
          )}
          <Pager
            basePath="/accounting"
            params={{ tab: "payments" }}
            page={page}
            shown={payments?.length ?? 0}
            total={paymentsCount}
            pageSize={PAGE_SIZE}
          />
        </section>
      )}

      {currentTab === "expenses" && (
        <section className="table-card">
          <div className="table-meta">
            <strong>{expenses?.length ?? 0} expense(s)</strong>
            <span>Operating and capital expenses</span>
          </div>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Expense No</th>
                  <th>Date</th>
                  <th>Category</th>
                  <th>Vendor / Payee</th>
                  <th>Description</th>
                  <th className="numeric">Amount</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {expenses?.map((e) => {
                  const cat = Array.isArray(e.expense_categories) ? e.expense_categories[0] : e.expense_categories;
                  const contact = Array.isArray(e.contacts) ? e.contacts[0] : e.contacts;
                  const statusClass =
                    e.status === "Confirmed"
                      ? "badge-confirmed"
                      : e.status === "Cancelled"
                      ? "badge-cancelled"
                      : "badge-draft";

                  return (
                    <tr key={e.id}>
                      <td>
                        <Link href={`/accounting/expenses/${e.id}`}>
                          <strong className="mono">{e.expense_no}</strong>
                        </Link>
                      </td>
                      <td>{e.expense_date}</td>
                      <td>
                        <strong>{cat?.name || "General"}</strong>
                      </td>
                      <td>{contact?.name || "—"}</td>
                      <td>{e.description}</td>
                      <td className="numeric">
                        <strong>
                          ৳{Number(e.amount).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                        </strong>
                      </td>
                      <td>
                        <span className={statusClass}>{e.status}</span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {!expenses?.length && (
            <div className="empty-state">
              <div className="empty-icon">📉</div>
              <div>
                <h2>No expenses recorded</h2>
                <p>Track bills, rent, logistics, and operational expenses.</p>
              </div>
            </div>
          )}
          <Pager
            basePath="/accounting"
            params={{ tab: "expenses" }}
            page={page}
            shown={expenses?.length ?? 0}
            total={expensesCount}
            pageSize={PAGE_SIZE}
          />
        </section>
      )}

      {currentTab === "categories" && (
        <div style={{ display: "grid", gap: "16px" }}>
          <section className="data-card">
            <div className="form-section-heading">
              <div>
                <p className="eyebrow">NEW CATEGORY</p>
                <h2>Create Expense Category</h2>
              </div>
            </div>
            <form action={createExpenseCategory} style={{ display: "flex", gap: "8px", maxWidth: "450px" }}>
              <input name="name" placeholder="e.g. Rent, Utilities, Packaging..." required />
              <button className="primary-button" type="submit" style={{ whiteSpace: "nowrap" }}>
                Add Category
              </button>
            </form>
          </section>

          <section className="table-card">
            <div className="table-meta">
              <strong>{categories?.length ?? 0} category / categories</strong>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Category Name</th>
                    <th>Status</th>
                    <th>Created</th>
                  </tr>
                </thead>
                <tbody>
                  {categories?.map((c) => (
                    <tr key={c.id}>
                      <td>
                        <strong>{c.name}</strong>
                      </td>
                      <td>
                        <span className="badge-confirmed">{c.status}</span>
                      </td>
                      <td style={{ fontSize: "11px", color: "var(--muted)" }}>
                        {new Date(c.created_at).toLocaleDateString("en-BD")}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>
        </div>
      )}

      {currentTab === "ledger" && (
        <section className="table-card">
          <div className="table-meta">
            <strong>{ledger?.length ?? 0} transaction(s)</strong>
            <span>Double-entry accounting journal entries</span>
          </div>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Date & Time</th>
                  <th>Transaction Type</th>
                  <th>Description</th>
                  <th>Reference</th>
                  <th>Contact</th>
                  <th className="numeric">Debit (৳)</th>
                  <th className="numeric">Credit (৳)</th>
                </tr>
              </thead>
              <tbody>
                {ledger?.map((t) => {
                  const contact = Array.isArray(t.contacts) ? t.contacts[0] : t.contacts;
                  return (
                    <tr key={t.id}>
                      <td style={{ fontSize: "11px", color: "var(--muted)" }}>
                        {new Date(t.transaction_date).toLocaleString("en-BD")}
                      </td>
                      <td>
                        <span className="status-badge">{t.transaction_type}</span>
                      </td>
                      <td>{t.description}</td>
                      <td>
                        {t.reference_type && t.reference_id ? (
                          <span className="mono" style={{ fontSize: "11px" }}>
                            {t.reference_type} #{String(t.reference_id).slice(0, 8)}
                          </span>
                        ) : (
                          "—"
                        )}
                      </td>
                      <td>{contact?.name || "—"}</td>
                      <td className="numeric">
                        {Number(t.debit) > 0 ? (
                          <strong>৳{Number(t.debit).toLocaleString("en-BD", { minimumFractionDigits: 2 })}</strong>
                        ) : (
                          "—"
                        )}
                      </td>
                      <td className="numeric">
                        {Number(t.credit) > 0 ? (
                          <strong style={{ color: "var(--success)" }}>
                            ৳{Number(t.credit).toLocaleString("en-BD", { minimumFractionDigits: 2 })}
                          </strong>
                        ) : (
                          "—"
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          {!ledger?.length && (
            <div className="empty-state">
              <div className="empty-icon">📖</div>
              <div>
                <h2>No ledger entries yet</h2>
                <p>Transactions will appear automatically when confirming invoices, payments, and expenses.</p>
              </div>
            </div>
          )}
        </section>
      )}
    </WorkspaceShell>
  );
}
