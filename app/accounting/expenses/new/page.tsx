import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { createExpense } from "@/app/accounting/actions";

export const dynamic = "force-dynamic";

type SearchParams = { error?: string };

export default async function NewExpensePage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const query = await searchParams;
  const error = query.error ? decodeURIComponent(query.error) : "";

  const [{ data: categories }, { data: contacts }] = await Promise.all([
    supabase
      .from("expense_categories")
      .select("id, name")
      .eq("organization_id", organizationId)
      .eq("status", "Active")
      .order("name")
      .limit(500),
    supabase
      .from("contacts")
      .select("id, name, phone")
      .eq("organization_id", organizationId)
      .eq("status", "Active")
      .order("name")
      .limit(500),
  ]);

  return (
    <WorkspaceShell active="accounting">
      <section className="form-page">
        <div className="form-page-header">
          <div>
            <p className="eyebrow">EXPENSES • NEW</p>
            <h1>Record Expense</h1>
            <p className="muted">Log business expenses such as rent, utility bills, maintenance, or logistics.</p>
          </div>
          <Link className="secondary-button" href="/accounting?tab=expenses">
            Back to Expenses
          </Link>
        </div>

        {error && <div className="form-error" role="alert">{error}</div>}

        <form action={createExpense} className="purchase-form">
          <section className="data-card">
            <div className="form-section-heading">
              <div>
                <p className="eyebrow">EXPENSE DETAILS</p>
                <h2>Cost information</h2>
              </div>
            </div>
            <div className="form-grid">
              <label>
                Category *
                <select name="expense_category_id" required defaultValue="">
                  <option value="">Select category</option>
                  {categories?.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name}
                    </option>
                  ))}
                </select>
              </label>

              <label>
                Vendor / Payee
                <select name="contact_id" defaultValue="">
                  <option value="">Select vendor (optional)</option>
                  {contacts?.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name} {c.phone ? `(${c.phone})` : ""}
                    </option>
                  ))}
                </select>
              </label>

              <label>
                Expense Date *
                <input
                  name="expense_date"
                  type="date"
                  defaultValue={new Date().toISOString().split("T")[0]}
                  required
                />
              </label>

              <label>
                Amount (৳) *
                <input
                  name="amount"
                  type="number"
                  step="0.01"
                  min="0.01"
                  placeholder="0.00"
                  required
                />
              </label>

              <label className="full-width">
                Description / Purpose *
                <input
                  name="description"
                  placeholder="e.g. Office electricity bill for September, Packaging boxes"
                  required
                />
              </label>

              <label className="full-width">
                Notes
                <textarea name="notes" rows={2} placeholder="Optional notes or voucher references" />
              </label>
            </div>
          </section>

          <div className="form-actions">
            <Link className="secondary-button" href="/accounting?tab=expenses">
              Cancel
            </Link>
            <button className="primary-button" type="submit">
              Save Expense Draft
            </button>
          </div>
        </form>
      </section>
    </WorkspaceShell>
  );
}
