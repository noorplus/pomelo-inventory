import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import InvoiceDocument from "@/app/components/invoice-document";
import PrintButton from "@/app/components/print-button";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import {
  cancelPaymentAction,
  confirmPaymentAction,
  deletePaymentDraft,
} from "@/app/accounting/actions";
import PaymentAllocator from "./payment-allocator";

export const dynamic = "force-dynamic";

type Params = { id: string };
type SearchParams = { error?: string; target?: string };

export default async function PaymentDetailPage({
  params,
  searchParams,
}: {
  params: Promise<Params>;
  searchParams: Promise<SearchParams>;
}) {
  const { supabase, organizationId, organization } = await getWorkspaceContext();
  const { id } = await params;
  const query = await searchParams;
  const error = query.error ? decodeURIComponent(query.error) : "";

  const orgName = organization?.organization_name || "Pomelo Inventory";

  // Deep-link pre-selection (?target=sale:<uuid>): the allocator fills this
  // candidate first. Silently ignored when it isn't a current candidate.
  const targetMatch = /^(sale|purchase|expense):([0-9a-f-]{36})$/i.exec(String(query.target || "").trim());
  const initialTargetId = targetMatch ? targetMatch[2] : undefined;

  const { data: payment, error: paymentError } = await supabase
    .from("payments")
    .select("id, payment_no, payment_date, payment_type, contact_id, amount, payment_method, reference_no, status, notes, created_at, contacts(id, name, phone)")
    .eq("organization_id", organizationId)
    .eq("id", id)
    .single();

  if (paymentError || !payment) {
    return (
      <WorkspaceShell active="accounting">
        <section className="form-page">
          <div className="form-page-header">
            <div>
              <p className="eyebrow">PAYMENT</p>
              <h1>Payment not found</h1>
              <p className="muted">{paymentError?.message || "Payment record does not exist."}</p>
            </div>
            <Link className="secondary-button" href="/accounting?tab=payments">
              Back to Payments
            </Link>
          </div>
        </section>
      </WorkspaceShell>
    );
  }

  const contact = Array.isArray(payment.contacts) ? payment.contacts[0] : payment.contacts;

  // Load existing allocations (if confirmed or existing)
  const { data: existingAllocations } = await supabase
    .from("payment_allocations")
    .select("id, allocated_amount, purchase_id, sale_id, expense_id, purchases(invoice_no), sales(invoice_no), expenses(expense_no)")
    .eq("organization_id", organizationId)
    .eq("payment_id", id);

  // If Draft, load candidate invoices for allocation
  let candidates: {
    id: string;
    type: "sale" | "purchase" | "expense";
    number: string;
    date: string;
    total: number;
    paid: number;
    outstanding: number;
  }[] = [];

  if (payment.status === "Draft") {
    if (payment.payment_type === "In") {
      // Find confirmed sales
      let salesQuery = supabase
        .from("sales")
        .select("id, invoice_no, invoice_date, total")
        .eq("organization_id", organizationId)
        .eq("status", "Confirmed");

      if (payment.contact_id) {
        salesQuery = salesQuery.eq("contact_id", payment.contact_id);
      }

      const { data: salesList } = await salesQuery.order("invoice_date").limit(500);

      if (salesList && salesList.length > 0) {
        const saleIds = salesList.map((s) => s.id);
        const [{ data: allocList }, { data: returnList }] = await Promise.all([
          supabase
            .from("payment_allocations")
            .select("sale_id, allocated_amount, payments!inner(status)")
            .eq("organization_id", organizationId)
            .in("sale_id", saleIds),
          supabase
            .from("account_transactions")
            .select("reference_id, credit")
            .eq("organization_id", organizationId)
            .eq("reference_type", "Sale")
            .in("reference_id", saleIds)
            .like("transaction_type", "Sale Return%"),
        ]);

        const paidBySale = new Map<string, number>();
        (allocList ?? []).forEach((a) => {
          const p = Array.isArray(a.payments) ? a.payments[0] : a.payments;
          if (p?.status === "Confirmed" && a.sale_id) {
            paidBySale.set(a.sale_id, (paidBySale.get(a.sale_id) || 0) + Number(a.allocated_amount));
          }
        });

        const returnedBySale = new Map<string, number>();
        ((returnList ?? []) as { reference_id: string; credit: number }[]).forEach((r) => {
          returnedBySale.set(r.reference_id, (returnedBySale.get(r.reference_id) || 0) + Number(r.credit || 0));
        });

        candidates = salesList
          .map((s) => {
            const tot = Number(s.total || 0);
            const pd = paidBySale.get(s.id) || 0;
            const ret = returnedBySale.get(s.id) || 0;
            const outstanding = Math.max(0, tot - pd - ret);
            return {
              id: s.id,
              type: "sale" as const,
              number: s.invoice_no,
              date: s.invoice_date,
              total: tot,
              paid: pd,
              outstanding,
            };
          })
          .filter((c) => c.outstanding > 0);
      }
    } else {
      // Payment Out -> Purchases & Expenses
      let purchasesQuery = supabase
        .from("purchases")
        .select("id, invoice_no, invoice_date, total")
        .eq("organization_id", organizationId)
        .eq("status", "Confirmed");

      let expensesQuery = supabase
        .from("expenses")
        .select("id, expense_no, expense_date, amount")
        .eq("organization_id", organizationId)
        .eq("status", "Confirmed");

      if (payment.contact_id) {
        purchasesQuery = purchasesQuery.eq("contact_id", payment.contact_id);
        // Match the confirm_payment RPC rule: a payment contact must match the
        // expense contact only when the expense HAS a contact, so contact-less
        // general expenses stay allocatable.
        expensesQuery = expensesQuery.or(`contact_id.eq.${payment.contact_id},contact_id.is.null`);
      }

      const [{ data: purchasesList }, { data: expensesList }] = await Promise.all([
        purchasesQuery.order("invoice_date").limit(500),
        expensesQuery.order("expense_date").limit(500),
      ]);

      const purchaseIds = (purchasesList ?? []).map((p) => p.id);
      const expenseIds = (expensesList ?? []).map((e) => e.id);

      const [
        { data: purchaseAllocList },
        { data: expenseAllocList },
        { data: purchaseReturnList },
      ] = await Promise.all([
        purchaseIds.length > 0
          ? supabase
              .from("payment_allocations")
              .select("purchase_id, allocated_amount, payments!inner(status)")
              .eq("organization_id", organizationId)
              .in("purchase_id", purchaseIds)
          : Promise.resolve({ data: [] }),
        expenseIds.length > 0
          ? supabase
              .from("payment_allocations")
              .select("expense_id, allocated_amount, payments!inner(status)")
              .eq("organization_id", organizationId)
              .in("expense_id", expenseIds)
          : Promise.resolve({ data: [] }),
        purchaseIds.length > 0
          ? supabase
              .from("account_transactions")
              .select("reference_id, debit")
              .eq("organization_id", organizationId)
              .eq("reference_type", "Purchase")
              .in("reference_id", purchaseIds)
              .like("transaction_type", "Purchase Return%")
          : Promise.resolve({ data: [] }),
      ]);

      const paidByPurchase = new Map<string, number>();
      (purchaseAllocList ?? []).forEach((a) => {
        const p = Array.isArray(a.payments) ? a.payments[0] : a.payments;
        if (p?.status === "Confirmed" && a.purchase_id) {
          paidByPurchase.set(a.purchase_id, (paidByPurchase.get(a.purchase_id) || 0) + Number(a.allocated_amount));
        }
      });

      const returnedByPurchase = new Map<string, number>();
      ((purchaseReturnList ?? []) as { reference_id: string; debit: number }[]).forEach((r) => {
        returnedByPurchase.set(r.reference_id, (returnedByPurchase.get(r.reference_id) || 0) + Number(r.debit || 0));
      });

      const paidByExpense = new Map<string, number>();
      (expenseAllocList ?? []).forEach((a) => {
        const p = Array.isArray(a.payments) ? a.payments[0] : a.payments;
        if (p?.status === "Confirmed" && a.expense_id) {
          paidByExpense.set(a.expense_id, (paidByExpense.get(a.expense_id) || 0) + Number(a.allocated_amount));
        }
      });

      const candPurchases = (purchasesList ?? [])
        .map((p) => {
          const tot = Number(p.total || 0);
          const pd = paidByPurchase.get(p.id) || 0;
          const ret = returnedByPurchase.get(p.id) || 0;
          const outstanding = Math.max(0, tot - pd - ret);
          return {
            id: p.id,
            type: "purchase" as const,
            number: p.invoice_no,
            date: p.invoice_date,
            total: tot,
            paid: pd,
            outstanding,
          };
        })
        .filter((c) => c.outstanding > 0);

      const candExpenses = (expensesList ?? [])
        .map((e) => {
          const tot = Number(e.amount || 0);
          const pd = paidByExpense.get(e.id) || 0;
          const outstanding = Math.max(0, tot - pd);
          return {
            id: e.id,
            type: "expense" as const,
            number: e.expense_no,
            date: e.expense_date,
            total: tot,
            paid: pd,
            outstanding,
          };
        })
        .filter((c) => c.outstanding > 0);

      candidates = [...candPurchases, ...candExpenses];
    }
  }

  const isTypeIn = payment.payment_type === "In";
  const statusClass =
    payment.status === "Confirmed"
      ? "badge-confirmed"
      : payment.status === "Cancelled"
      ? "badge-cancelled"
      : "badge-draft";

  return (
    <WorkspaceShell active="accounting">
      <section className="form-page">
        <div className="form-page-header">
          <div>
            <p className="eyebrow">
              PAYMENT • {isTypeIn ? "IN (RECEIPT)" : "OUT (PAYMENT)"} • {payment.status.toUpperCase()}
            </p>
            <h1>{payment.payment_no}</h1>
            <p className="muted">
              {payment.payment_date} · {contact?.name || "General Contact"}
            </p>
          </div>
          <div className="module-actions">
            {payment.status !== "Draft" && <PrintButton />}
            <Link className="secondary-button" href="/accounting?tab=payments">
              Back to Payments
            </Link>
            {payment.status === "Draft" && (
              <form action={deletePaymentDraft}>
                <input type="hidden" name="payment_id" value={payment.id} />
                <button className="secondary-button" type="submit">
                  Delete Draft
                </button>
              </form>
            )}
            {payment.status === "Confirmed" && (
              <form action={cancelPaymentAction}>
                <input type="hidden" name="payment_id" value={payment.id} />
                <button className="secondary-button" type="submit">
                  Cancel & Reverse Payment
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
              {payment.status}
            </span>
          </div>
          <div className="summary-card">
            <span>Direction</span>
            <span style={{ width: "fit-content" }} className={isTypeIn ? "badge-in" : "badge-out"}>
              {isTypeIn ? "↓ Payment In (Receipt)" : "↑ Payment Out (Payout)"}
            </span>
          </div>
          <div className="summary-card">
            <span>Payment Amount</span>
            <strong>
              ৳{Number(payment.amount).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
            </strong>
          </div>
          <div className="summary-card">
            <span>Method</span>
            <strong>{payment.payment_method}</strong>
          </div>
        </section>

        <section className="data-card">
          <div className="form-section-heading">
            <div>
              <p className="eyebrow">PAYMENT RECORD</p>
              <h2>Transaction metadata</h2>
            </div>
          </div>
          <div className="detail-grid">
            <div>
              <span>Contact / Payee</span>
              <strong>{contact?.name || "—"}</strong>
            </div>
            <div>
              <span>Reference No</span>
              <strong>{payment.reference_no || "—"}</strong>
            </div>
            <div>
              <span>Payment Date</span>
              <strong>{payment.payment_date}</strong>
            </div>
            <div>
              <span>Created Timestamp</span>
              <strong>{new Date(payment.created_at).toLocaleString("en-BD")}</strong>
            </div>
          </div>
        </section>

        {payment.status === "Draft" && (
          <PaymentAllocator
            paymentId={payment.id}
            paymentType={payment.payment_type}
            paymentAmount={Number(payment.amount)}
            candidates={candidates}
            action={confirmPaymentAction}
            initialTargetId={initialTargetId}
          />
        )}

        {payment.status !== "Draft" && existingAllocations && existingAllocations.length > 0 && (
          <section className="data-card">
            <div className="form-section-heading">
              <div>
                <p className="eyebrow">SETTLED INVOICES</p>
                <h2>Payment allocations</h2>
              </div>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Target Document</th>
                    <th className="numeric">Allocated Amount</th>
                  </tr>
                </thead>
                <tbody>
                  {existingAllocations.map((a) => {
                    const docType = a.sale_id ? "Sale" : a.purchase_id ? "Purchase" : "Expense";
                    const saleDoc = Array.isArray(a.sales) ? a.sales[0] : a.sales;
                    const purchaseDoc = Array.isArray(a.purchases) ? a.purchases[0] : a.purchases;
                    const expenseDoc = Array.isArray(a.expenses) ? a.expenses[0] : a.expenses;
                    const docNo =
                      saleDoc?.invoice_no || purchaseDoc?.invoice_no || expenseDoc?.expense_no || "—";
                    const docLink = a.sale_id
                      ? `/sales/${a.sale_id}`
                      : a.purchase_id
                      ? `/purchases/${a.purchase_id}`
                      : `/accounting/expenses/${a.expense_id}`;

                    return (
                      <tr key={a.id}>
                        <td>
                          <Link href={docLink}>
                            <strong>
                              {docType} Invoice #{docNo}
                            </strong>
                          </Link>
                        </td>
                        <td className="numeric">
                          <strong>
                            ৳{Number(a.allocated_amount).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                          </strong>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </section>
        )}

        {payment.notes && (
          <section className="data-card">
            <p className="eyebrow">NOTES</p>
            <p>{payment.notes}</p>
          </section>
        )}

        {payment.status !== "Draft" && (
          <div className="print-area">
            <InvoiceDocument
              orgName={orgName}
              orgPhone={organization?.phone_number}
              orgEmail={organization?.email}
              orgAddress={organization?.address}
              title={isTypeIn ? "MONEY RECEIPT" : "PAYMENT VOUCHER"}
              docNo={payment.payment_no}
              date={payment.payment_date}
              status={payment.status}
              partyLabel={isTypeIn ? "Received From" : "Paid To"}
              partyName={contact?.name || "—"}
              partyPhone={contact?.phone}
              extraMeta={[
                { label: "Method", value: payment.payment_method },
                ...(payment.reference_no ? [{ label: "Reference", value: payment.reference_no }] : []),
              ]}
              lines={(existingAllocations ?? []).map((a) => {
                const docType = a.sale_id ? "Sale" : a.purchase_id ? "Purchase" : "Expense";
                const saleDoc = Array.isArray(a.sales) ? a.sales[0] : a.sales;
                const purchaseDoc = Array.isArray(a.purchases) ? a.purchases[0] : a.purchases;
                const expenseDoc = Array.isArray(a.expenses) ? a.expenses[0] : a.expenses;
                const docNo =
                  saleDoc?.invoice_no || purchaseDoc?.invoice_no || expenseDoc?.expense_no || "—";
                return { name: `${docType} #${docNo}`, total: Number(a.allocated_amount) };
              })}
              lineMode="simple"
              total={Number(payment.amount)}
              notes={payment.notes}
            />
          </div>
        )}
      </section>
    </WorkspaceShell>
  );
}
