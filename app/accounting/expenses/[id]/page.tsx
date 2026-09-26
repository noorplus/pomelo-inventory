import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import {
  cancelExpenseAction,
  confirmExpenseAction,
  deleteExpenseDraft,
} from "@/app/accounting/actions";

export const dynamic = "force-dynamic";

type Params = { id: string };
type SearchParams = { error?: string };

export default async function ExpenseDetailPage({
  params,
  searchParams,
}: {
  params: Promise<Params>;
  searchParams: Promise<SearchParams>;
}) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const { id } = await params;
  const query = await searchParams;
  const error = query.error ? decodeURIComponent(query.error) : "";

  const { data: expense, error: expenseError } = await supabase
    .from("expenses")
    .select("id, expense_no, expense_date, description, amount, status, notes, created_at, expense_categories(name), contacts(name, phone)")
    .eq("organization_id", organizationId)
    .eq("id", id)
    .single();

  if (expenseError || !expense) {
    return (
      <WorkspaceShell active="accounting">
        <section className="form-page">
          <div className="form-page-header">
            <div>
              <p className="eyebrow">EXPENSE</p>
              <h1>Expense not found</h1>
              <p className="muted">{expenseError?.message || "Expense record does not exist."}</p>
            </div>
            <Link className="secondary-button" href="/accounting?tab=expenses">
              Back to Expenses
            </Link>
          </div>
        </section>
      </WorkspaceShell>
    );
  }

  const category = Array.isArray(expense.expense_categories)
    ? expense.expense_categories[0]
    : expense.expense_categories;
  const contact = Array.isArray(expense.contacts) ? expense.contacts[0] : expense.contacts;

  const statusClass =
    expense.status === "Confirmed"
      ? "badge-confirmed"
      : expense.status === "Cancelled"
      ? "badge-cancelled"
      : "badge-draft";

  return (
    <WorkspaceShell active="accounting">
      <section className="form-page">
        <div className="form-page-header">
          <div>
            <p className="eyebrow">EXPENSE • {expense.status.toUpperCase()}</p>
            <h1>{expense.expense_no}</h1>
            <p className="muted">
              {expense.expense_date} · {category?.name || "General Expense"}
            </p>
          </div>
          <div className="module-actions">
            <Link className="secondary-button" href="/accounting?tab=expenses">
              Back to Expenses
            </Link>
            {expense.status === "Draft" && (
              <>
                <form action={deleteExpenseDraft}>
                  <input type="hidden" name="expense_id" value={expense.id} />
                  <button className="secondary-button" type="submit">
                    Delete Draft
                  </button>
                </form>
                <form action={confirmExpenseAction}>
                  <input type="hidden" name="expense_id" value={expense.id} />
                  <button className="primary-button" type="submit">
                    Confirm Expense
                  </button>
                </form>
              </>
            )}
            {expense.status === "Confirmed" && (
              <form action={cancelExpenseAction}>
                <input type="hidden" name="expense_id" value={expense.id} />
                <button className="secondary-button" type="submit">
                  Cancel Expense
                </button>
              </form>
            )}
          </div>
        </div>

        {error && <div className="form-error" role="alert">{error}</div>}

        <section className="summary-grid">
          <div className="summary-card">
            <span>Status</span>
            <span style={{ width: "fit-content" }} className={statusClass}>
              {expense.status}
            </span>
          </div>
          <div className="summary-card">
            <span>Amount</span>
            <strong>
              ৳{Number(expense.amount).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
            </strong>
          </div>
          <div className="summary-card">
            <span>Category</span>
            <strong>{category?.name || "General"}</strong>
          </div>
          <div className="summary-card">
            <span>Date</span>
            <strong>{expense.expense_date}</strong>
          </div>
        </section>

        <section className="data-card">
          <div className="form-section-heading">
            <div>
              <p className="eyebrow">DETAILS</p>
              <h2>Expense description</h2>
            </div>
          </div>
          <div className="detail-grid">
            <div style={{ gridColumn: "1 / -1" }}>
              <span>Description</span>
              <strong style={{ fontSize: "14px" }}>{expense.description}</strong>
            </div>
            <div>
              <span>Vendor / Payee</span>
              <strong>{contact?.name || "—"}</strong>
            </div>
            <div>
              <span>Vendor Phone</span>
              <strong>{contact?.phone || "—"}</strong>
            </div>
            <div>
              <span>Created Timestamp</span>
              <strong>{new Date(expense.created_at).toLocaleString("en-BD")}</strong>
            </div>
          </div>
        </section>

        {expense.notes && (
          <section className="data-card">
            <p className="eyebrow">NOTES</p>
            <p>{expense.notes}</p>
          </section>
        )}
      </section>
    </WorkspaceShell>
  );
}
