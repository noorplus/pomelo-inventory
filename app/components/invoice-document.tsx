// Printable business document: purchase bill, sales invoice, money receipt,
// expense voucher. Screen shows it as a clean card; @media print outputs only
// this document (shell, nav, forms and action buttons are hidden).

export type DocLine = {
  name: string;
  detail?: string;
  qty?: number;
  unitPrice?: number;
  discount?: number;
  tax?: number;
  total: number;
};

export type InvoiceDocumentProps = {
  orgName: string;
  orgPhone?: string | null;
  orgEmail?: string | null;
  orgAddress?: string | null;
  title: string;
  docNo: string;
  date: string;
  status: string;
  partyLabel: string;
  partyName: string;
  partyPhone?: string | null;
  partyEmail?: string | null;
  extraMeta?: { label: string; value: string }[];
  lines: DocLine[];
  lineMode: "items" | "simple";
  subtotal?: number;
  discount?: number;
  tax?: number;
  total: number;
  paid?: number;
  due?: number;
  notes?: string | null;
};

const money = (value: number) =>
  `৳${Number(value || 0).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export default function InvoiceDocument(props: InvoiceDocumentProps) {
  const {
    orgName,
    orgPhone,
    orgEmail,
    orgAddress,
    title,
    docNo,
    date,
    status,
    partyLabel,
    partyName,
    partyPhone,
    partyEmail,
    extraMeta = [],
    lines,
    lineMode,
    subtotal,
    discount,
    tax,
    total,
    paid,
    due,
    notes,
  } = props;

  return (
    <section className="invoice-doc" aria-label={title}>
      <div className="invoice-head">
        <div>
          <p className="invoice-org">{orgName}</p>
          {[orgAddress, [orgPhone, orgEmail].filter(Boolean).join(" · ")]
            .filter((line) => line && String(line).trim())
            .map((line, i) => (
              <p key={i} className="invoice-org-sub">
                {line}
              </p>
            ))}
        </div>
        <div className="invoice-title-block">
          <h2>{title}</h2>
          <p className="mono">{docNo}</p>
          <span className="status-badge">{status}</span>
        </div>
      </div>

      <div className="invoice-parties">
        <div>
          <span>{partyLabel}</span>
          <strong>{partyName}</strong>
          {[partyPhone, partyEmail].filter(Boolean).join(" · ") || null}
        </div>
        <div>
          <span>Date</span>
          <strong>{date}</strong>
          {extraMeta.map((m) => (
            <div key={m.label} className="invoice-meta-row">
              <span>{m.label}</span>
              <strong>{m.value}</strong>
            </div>
          ))}
        </div>
      </div>

      <div className="table-scroll">
        <table className="invoice-table">
          <thead>
            <tr>
              <th>#</th>
              <th>Description</th>
              {lineMode === "items" && (
                <>
                  <th className="numeric">Qty</th>
                  <th className="numeric">Unit Price</th>
                  <th className="numeric">Discount</th>
                  <th className="numeric">Tax</th>
                </>
              )}
              <th className="numeric">Amount</th>
            </tr>
          </thead>
          <tbody>
            {lines.map((line, i) => (
              <tr key={i}>
                <td>{i + 1}</td>
                <td>
                  <strong>{line.name}</strong>
                  {line.detail && <div className="invoice-line-detail">{line.detail}</div>}
                </td>
                {lineMode === "items" && (
                  <>
                    <td className="numeric">
                      {line.qty !== undefined
                        ? Number(line.qty).toLocaleString("en-BD", { maximumFractionDigits: 4 })
                        : "—"}
                    </td>
                    <td className="numeric">{line.unitPrice !== undefined ? money(line.unitPrice) : "—"}</td>
                    <td className="numeric">{line.discount !== undefined ? money(line.discount) : "—"}</td>
                    <td className="numeric">{line.tax !== undefined ? money(line.tax) : "—"}</td>
                  </>
                )}
                <td className="numeric">
                  <strong>{money(line.total)}</strong>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="invoice-totals">
        {subtotal !== undefined && (
          <div>
            <span>Subtotal</span>
            <strong>{money(subtotal)}</strong>
          </div>
        )}
        {discount !== undefined && discount > 0 && (
          <div>
            <span>Discount</span>
            <strong>− {money(discount)}</strong>
          </div>
        )}
        {tax !== undefined && tax > 0 && (
          <div>
            <span>Tax</span>
            <strong>+ {money(tax)}</strong>
          </div>
        )}
        <div className="invoice-grand-total">
          <span>Total</span>
          <strong>{money(total)}</strong>
        </div>
        {paid !== undefined && (
          <div>
            <span>Paid</span>
            <strong>{money(paid)}</strong>
          </div>
        )}
        {due !== undefined && (
          <div>
            <span>Balance Due</span>
            <strong>{money(due)}</strong>
          </div>
        )}
      </div>

      {notes && (
        <p className="invoice-notes">
          <span>Notes: </span>
          {notes}
        </p>
      )}

      <p className="invoice-footer">Generated by {orgName} · Pomelo Inventory</p>
    </section>
  );
}
