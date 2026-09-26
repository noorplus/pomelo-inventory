import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import PrintButton from "@/app/components/print-button";
import { getWorkspaceContext } from "@/lib/auth/workspace";

export const dynamic = "force-dynamic";

type Params = { id: string };

type LedgerRow = {
  key: string;
  date: string;
  ref: string;
  href: string | null;
  status: string;
  billed: number;
  settled: number;
  balance: number;
};

const money = (value: number) =>
  `৳${Number(value || 0).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

function buildStatement(
  docs: { key: string; date: string; ref: string; href: string; status: string; amount: number }[],
  settlements: { key: string; date: string; ref: string; href: string; amount: number }[],
): LedgerRow[] {
  const events = [
    ...docs.map((d) => ({ ...d, kind: "bill" as const })),
    ...settlements.map((s) => ({ ...s, status: "Confirmed", kind: "settle" as const })),
  ].sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));

  let balance = 0;
  return events.map((e) => {
    const billed = e.kind === "bill" && e.status === "Confirmed" ? e.amount : 0;
    const settled = e.kind === "settle" ? e.amount : 0;
    balance = Math.max(0, balance + billed - settled);
    return {
      key: e.key,
      date: e.date,
      ref: e.ref,
      href: e.href,
      status: e.status,
      billed,
      settled,
      balance,
    };
  });
}

function StatementTable({
  title,
  subtitle,
  rows,
  billedLabel,
  settledLabel,
  balanceLabel,
}: {
  title: string;
  subtitle: string;
  rows: LedgerRow[];
  billedLabel: string;
  settledLabel: string;
  balanceLabel: string;
}) {
  const totalBilled = rows.reduce((s, r) => s + r.billed, 0);
  const totalSettled = rows.reduce((s, r) => s + r.settled, 0);
  const balance = rows.length ? rows[rows.length - 1].balance : 0;

  return (
    <section className="table-card">
      <div className="table-meta">
        <strong>{title}</strong>
        <span>{subtitle}</span>
      </div>
      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              <th>Date</th>
              <th>Reference</th>
              <th>Status</th>
              <th className="numeric">{billedLabel}</th>
              <th className="numeric">{settledLabel}</th>
              <th className="numeric">{balanceLabel}</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.key}>
                <td>{row.date}</td>
                <td>
                  {row.href ? (
                    <Link href={row.href}>
                      <strong className="mono">{row.ref}</strong>
                    </Link>
                  ) : (
                    <strong className="mono">{row.ref}</strong>
                  )}
                </td>
                <td>
                  <span className="status-badge">{row.status}</span>
                </td>
                <td className="numeric">{row.billed ? money(row.billed) : "—"}</td>
                <td className="numeric">{row.settled ? money(row.settled) : "—"}</td>
                <td className="numeric">
                  <strong>{money(row.balance)}</strong>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {!rows.length && (
        <div className="empty-state">
          <div className="empty-icon">∅</div>
          <div>
            <h2>No entries</h2>
            <p>No confirmed documents for this statement yet.</p>
          </div>
        </div>
      )}
      <div className="table-meta">
        <strong>
          Billed {money(totalBilled)} · Settled {money(totalSettled)} · Balance {money(balance)}
        </strong>
      </div>
    </section>
  );
}

export default async function ContactLedgerPage({ params }: { params: Promise<Params> }) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const { id } = await params;

  const { data: contact, error: contactError } = await supabase
    .from("contacts")
    .select("id, id_no, name, phone, email, address, status")
    .eq("organization_id", organizationId)
    .eq("id", id)
    .single();

  if (contactError || !contact) {
    return (
      <WorkspaceShell active="contacts">
        <section className="form-page">
          <div className="form-page-header">
            <div>
              <p className="eyebrow">CONTACTS</p>
              <h1>Contact not found</h1>
              <p className="muted">{contactError?.message || "The contact does not exist or is outside this workspace."}</p>
            </div>
            <Link className="secondary-button" href="/contacts">
              Back to Contacts
            </Link>
          </div>
        </section>
      </WorkspaceShell>
    );
  }

  const [
    { data: sales },
    { data: purchases },
    { data: expenses },
    { data: payments },
  ] = await Promise.all([
    supabase
      .from("sales")
      .select("id, invoice_no, invoice_date, total, status")
      .eq("organization_id", organizationId)
      .eq("contact_id", id)
      .order("invoice_date")
      .limit(200),
    supabase
      .from("purchases")
      .select("id, invoice_no, invoice_date, total, status")
      .eq("organization_id", organizationId)
      .eq("contact_id", id)
      .order("invoice_date")
      .limit(200),
    supabase
      .from("expenses")
      .select("id, expense_no, expense_date, amount, status")
      .eq("organization_id", organizationId)
      .eq("contact_id", id)
      .order("expense_date")
      .limit(200),
    supabase
      .from("payments")
      .select("id, payment_no, payment_date, payment_type, amount, status")
      .eq("organization_id", organizationId)
      .eq("contact_id", id)
      .order("payment_date")
      .limit(200),
  ]);

  const saleIds = (sales ?? []).map((s) => s.id);
  const purchaseIds = (purchases ?? []).map((p) => p.id);
  const expenseIds = (expenses ?? []).map((e) => e.id);

  const [
    { data: saleAllocs },
    { data: purchaseAllocs },
    { data: expenseAllocs },
  ] = await Promise.all([
    saleIds.length
      ? supabase
          .from("payment_allocations")
          .select("sale_id, allocated_amount, payments!inner(payment_no, payment_date, status)")
          .eq("organization_id", organizationId)
          .in("sale_id", saleIds)
      : Promise.resolve({ data: [] as unknown[] }),
    purchaseIds.length
      ? supabase
          .from("payment_allocations")
          .select("purchase_id, allocated_amount, payments!inner(payment_no, payment_date, status)")
          .eq("organization_id", organizationId)
          .in("purchase_id", purchaseIds)
      : Promise.resolve({ data: [] as unknown[] }),
    expenseIds.length
      ? supabase
          .from("payment_allocations")
          .select("expense_id, allocated_amount, payments!inner(payment_no, payment_date, status)")
          .eq("organization_id", organizationId)
          .in("expense_id", expenseIds)
      : Promise.resolve({ data: [] as unknown[] }),
  ]);

  type AllocRow = {
    allocated_amount: number;
    payments: { payment_no: string; payment_date: string; status: string } | { payment_no: string; payment_date: string; status: string }[] | null;
  };

  const confirmedSettlements = (rows: AllocRow[], keyOf: (r: AllocRow, i: number) => string, hrefOf: (r: AllocRow) => string) =>
    (rows as AllocRow[])
      .map((a, i) => {
        const p = Array.isArray(a.payments) ? a.payments[0] : a.payments;
        if (!p || p.status !== "Confirmed") return null;
        return {
          key: keyOf(a, i),
          date: p.payment_date,
          ref: `Receipt ${p.payment_no}`,
          href: hrefOf(a),
          amount: Number(a.allocated_amount),
        };
      })
      .filter((r): r is NonNullable<typeof r> => r !== null);

  const receivable = buildStatement(
    (sales ?? []).map((s) => ({
      key: `sale-${s.id}`,
      date: s.invoice_date,
      ref: `Sale #${s.invoice_no}`,
      href: `/sales/${s.id}`,
      status: s.status,
      amount: Number(s.total),
    })),
    confirmedSettlements(saleAllocs as AllocRow[], (a, i) => `salloc-${i}`, () => "/accounting?tab=payments"),
  );

  const payable = buildStatement(
    [
      ...(purchases ?? []).map((p) => ({
        key: `purchase-${p.id}`,
        date: p.invoice_date,
        ref: `Purchase #${p.invoice_no}`,
        href: `/purchases/${p.id}`,
        status: p.status,
        amount: Number(p.total),
      })),
      ...(expenses ?? []).map((e) => ({
        key: `expense-${e.id}`,
        date: e.expense_date,
        ref: `Expense ${e.expense_no}`,
        href: `/accounting/expenses/${e.id}`,
        status: e.status,
        amount: Number(e.amount),
      })),
    ],
    [
      ...confirmedSettlements(purchaseAllocs as AllocRow[], (a, i) => `palloc-${i}`, () => "/accounting?tab=payments"),
      ...confirmedSettlements(expenseAllocs as AllocRow[], (a, i) => `ealloc-${i}`, () => "/accounting?tab=payments"),
    ],
  );

  const receivableDue = receivable.length ? receivable[receivable.length - 1].balance : 0;
  const payableDue = payable.length ? payable[payable.length - 1].balance : 0;
  const confirmedPayments = (payments ?? []).filter((p) => p.status === "Confirmed").length;

  return (
    <WorkspaceShell active="contacts">
      <section className="form-page" style={{ maxWidth: 980 }}>
        <div className="form-page-header">
          <div>
            <p className="eyebrow">CONTACT LEDGER</p>
            <h1>{contact.name}</h1>
            <p className="muted">
              #{contact.id_no} · {contact.phone || "No phone"} · {contact.email || "No email"}
            </p>
          </div>
          <div className="module-actions">
            <PrintButton />
            <Link className="secondary-button" href="/contacts">
              Back to Contacts
            </Link>
          </div>
        </div>

        <section className="summary-grid">
          <div className="summary-card">
            <span>Status</span>
            <span style={{ width: "fit-content" }} className="status-badge">
              {contact.status}
            </span>
          </div>
          <div className="summary-card">
            <span>Receivable Due (owes us)</span>
            <strong style={{ color: "var(--success)" }}>{money(receivableDue)}</strong>
          </div>
          <div className="summary-card">
            <span>Payable Due (we owe)</span>
            <strong style={{ color: "var(--primary-dark)" }}>{money(payableDue)}</strong>
          </div>
          <div className="summary-card">
            <span>Confirmed Payments</span>
            <strong>{confirmedPayments}</strong>
          </div>
        </section>

        <section className="data-card">
          <div className="form-section-heading">
            <div>
              <p className="eyebrow">PROFILE</p>
              <h2>Contact details</h2>
            </div>
          </div>
          <div className="detail-grid">
            <div>
              <span>Address</span>
              <strong>{contact.address || "—"}</strong>
            </div>
            <div>
              <span>Documents</span>
              <strong>
                {(sales ?? []).length} sales · {(purchases ?? []).length} purchases · {(expenses ?? []).length} expenses
              </strong>
            </div>
            <div>
              <span>Payments</span>
              <strong>{(payments ?? []).length} recorded</strong>
            </div>
          </div>
        </section>

        <div className="print-area" style={{ display: "grid", gap: 16 }}>
          <StatementTable
            title="Receivable Statement"
            subtitle="Sales billed vs customer receipts · balance is what the contact owes us"
            rows={receivable}
            billedLabel="Billed"
            settledLabel="Received"
            balanceLabel="Balance Due"
          />
          <StatementTable
            title="Payable Statement"
            subtitle="Purchases & expenses vs our payouts · balance is what we owe the contact"
            rows={payable}
            billedLabel="Billed"
            settledLabel="Paid"
            balanceLabel="Balance Owed"
          />
        </div>
      </section>
    </WorkspaceShell>
  );
}
