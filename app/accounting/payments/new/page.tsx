import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { createPayment } from "@/app/accounting/actions";

export const dynamic = "force-dynamic";

type SearchParams = {
  error?: string;
  type?: string;
  contact_id?: string;
  amount?: string;
};

export default async function NewPaymentPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const query = await searchParams;

  const defaultType = query.type === "Out" ? "Out" : "In";
  const defaultContactId = query.contact_id || "";
  const defaultAmount = query.amount || "";
  const error = query.error ? decodeURIComponent(query.error) : "";

  const { data: contacts } = await supabase
    .from("contacts")
    .select("id, name, phone")
    .eq("organization_id", organizationId)
    .eq("status", "Active")
    .order("name")
    .limit(500);

  return (
    <WorkspaceShell active="accounting">
      <section className="form-page">
        <div className="form-page-header">
          <div>
            <p className="eyebrow">PAYMENTS • NEW</p>
            <h1>Record Payment</h1>
            <p className="muted">
              Record money received from customers (In) or paid to suppliers/vendors (Out).
            </p>
          </div>
          <Link className="secondary-button" href="/accounting?tab=payments">
            Back to Payments
          </Link>
        </div>

        {error && <div className="form-error" role="alert">{error}</div>}

        <form action={createPayment} className="purchase-form">
          <section className="data-card">
            <div className="form-section-heading">
              <div>
                <p className="eyebrow">PAYMENT DETAILS</p>
                <h2>Transaction information</h2>
              </div>
            </div>
            <div className="form-grid">
              <label>
                Payment Direction *
                <select name="payment_type" defaultValue={defaultType} required>
                  <option value="In">Payment In (Receive money from Customer)</option>
                  <option value="Out">Payment Out (Pay money to Supplier/Vendor)</option>
                </select>
              </label>

              <label>
                Contact (Customer or Supplier)
                <select name="contact_id" defaultValue={defaultContactId}>
                  <option value="">Select contact (optional)</option>
                  {contacts?.map((c) => (
                    <option key={c.id} value={c.id}>
                      {c.name} {c.phone ? `(${c.phone})` : ""}
                    </option>
                  ))}
                </select>
              </label>

              <label>
                Payment Date *
                <input
                  name="payment_date"
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
                  defaultValue={defaultAmount}
                  required
                />
              </label>

              <label>
                Payment Method *
                <select name="payment_method" defaultValue="Cash" required>
                  <option value="Cash">Cash</option>
                  <option value="Bank">Bank Transfer</option>
                  <option value="Mobile Banking">Mobile Banking (bKash/Nagad/Rocket)</option>
                  <option value="Card">Card</option>
                  <option value="Other">Other</option>
                </select>
              </label>

              <label>
                Reference / Transaction ID
                <input name="reference_no" placeholder="e.g. Bank slip #, TxnID" />
              </label>

              <label className="full-width">
                Notes
                <textarea name="notes" rows={2} placeholder="Optional payment notes" />
              </label>
            </div>
          </section>

          <div className="form-actions">
            <Link className="secondary-button" href="/accounting?tab=payments">
              Cancel
            </Link>
            <button className="primary-button" type="submit">
              Save Draft Payment & Allocate
            </button>
          </div>
        </form>
      </section>
    </WorkspaceShell>
  );
}
