import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import InvoiceDocument from "@/app/components/invoice-document";
import PrintButton from "@/app/components/print-button";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { cancelSale, cloneSale, confirmSale, deleteSale, updateSale } from "@/app/sales/actions";
import SalesForm from "@/app/sales/sales-form";

export const dynamic = "force-dynamic";

type Params = { id: string };
type SearchParams = { error?: string };

export default async function SaleDetailPage({
  params,
  searchParams,
}: {
  params: Promise<Params>;
  searchParams: Promise<SearchParams>;
}) {
  const { supabase, organizationId, organization } = await getWorkspaceContext();
  const { id } = await params;
  const query = await searchParams;

  const orgName = organization?.organization_name || "Pomelo Inventory";

  const { data: sale, error: saleError } = await supabase
    .from("sales")
    .select("id, invoice_no, invoice_date, contact_id, status, subtotal, discount, tax, total, notes, created_at, created_by, contacts(id_no, name, phone, email)")
    .eq("organization_id", organizationId)
    .eq("id", id)
    .single();

  if (saleError || !sale) {
    return (
      <WorkspaceShell active="sales">
        <section className="form-page">
          <div className="form-page-header">
            <div>
              <p className="eyebrow">SALES</p>
              <h1>Sale not found</h1>
              <p className="muted">{saleError?.message || "The sales order does not exist or is outside this workspace."}</p>
            </div>
            <Link className="secondary-button" href="/sales">
              Back to Sales
            </Link>
          </div>
        </section>
      </WorkspaceShell>
    );
  }

  const [
    { data: items, error: itemsError },
    { data: contacts },
    { data: products },
    { data: stockList },
    { data: allocations },
  ] = await Promise.all([
    supabase
      .from("sale_items")
      .select("id, product_id, quantity, unit_price, discount, tax, line_total, products(product_name, retail_price)")
      .eq("organization_id", organizationId)
      .eq("sale_id", id)
      .order("created_at"),
    supabase
      .from("contacts")
      .select("id, name, phone")
      .eq("organization_id", organizationId)
      .eq("status", "Active")
      .order("name")
      .limit(500),
    supabase
      .from("products")
      .select("id, product_name, retail_price")
      .eq("organization_id", organizationId)
      .eq("status", "Active")
      .order("product_name")
      .limit(500),
    supabase
      .from("stock")
      .select("product_id, quantity")
      .eq("organization_id", organizationId),
    supabase
      .from("payment_allocations")
      .select("allocated_amount, payments!inner(id, payment_no, payment_date, status, payment_method)")
      .eq("organization_id", organizationId)
      .eq("sale_id", id),
  ]);

  const stockMap = new Map<string, number>();
  (stockList ?? []).forEach((s) => stockMap.set(s.product_id, Number(s.quantity || 0)));

  const productsWithStock = (products ?? []).map((p) => ({
    ...p,
    retail_price: Number(p.retail_price || 0),
    stock_quantity: stockMap.get(p.id) ?? 0,
  }));

  const paid = (allocations ?? []).reduce((sum, allocation) => {
    const payment = Array.isArray(allocation.payments) ? allocation.payments[0] : allocation.payments;
    return payment?.status === "Confirmed" ? sum + Number(allocation.allocated_amount) : sum;
  }, 0);
  const due = Math.max(0, Number(sale.total) - paid);
  const contact = Array.isArray(sale.contacts) ? sale.contacts[0] : sale.contacts;
  const error = query.error ? decodeURIComponent(query.error) : "";

  if (itemsError) {
    return (
      <WorkspaceShell active="sales">
        <section className="form-page">
          <div className="form-page-header">
            <div>
              <p className="eyebrow">SALES</p>
              <h1>{sale.invoice_no}</h1>
              <p className="muted">Unable to load sale items: {itemsError.message}</p>
            </div>
            <Link className="secondary-button" href="/sales">
              Back
            </Link>
          </div>
        </section>
      </WorkspaceShell>
    );
  }

  if (sale.status === "Draft") {
    return (
      <WorkspaceShell active="sales">
        <section className="form-page">
          <div className="form-page-header">
            <div>
              <p className="eyebrow">SALE • DRAFT</p>
              <h1>Edit Sale {sale.invoice_no}</h1>
              <p className="muted">Drafts can be edited. Confirming will deduct stock and record accounts receivable.</p>
            </div>
            <div className="module-actions">
              <PrintButton label="🖨 Print Quotation" />
              <Link className="secondary-button" href="/sales">
                Back to Sales
              </Link>
            </div>
          </div>

          <SalesForm
            contacts={contacts ?? []}
            products={productsWithStock}
            action={updateSale}
            submitLabel="Save Changes"
            saleId={sale.id}
            initialContactId={sale.contact_id}
            initialDate={sale.invoice_date}
            initialNotes={sale.notes || ""}
            initialItems={(items ?? []).map((item) => ({
              id: item.id,
              product_id: item.product_id,
              quantity: Number(item.quantity),
              unit_price: Number(item.unit_price),
              discount: Number(item.discount),
              tax: Number(item.tax),
            }))}
            error={error}
          />

          <section className="action-card">
            <div>
              <strong>Ready to confirm and dispatch?</strong>
              <p className="muted">Confirming this invoice will atomically reduce warehouse stock and post to accounts receivable.</p>
            </div>
            <div className="module-actions">
              <form action={deleteSale}>
                <input type="hidden" name="sale_id" value={sale.id} />
                <button className="secondary-button" type="submit">
                  Delete Draft
                </button>
              </form>
              <form action={confirmSale}>
                <input type="hidden" name="sale_id" value={sale.id} />
                <button className="primary-button" type="submit">
                  Confirm Sale
                </button>
              </form>
            </div>
          </section>

          <div className="print-area">
            <InvoiceDocument
              orgName={orgName}
              orgPhone={organization?.phone_number}
              orgEmail={organization?.email}
              orgAddress={organization?.address}
              title="QUOTATION"
              docNo={"#" + sale.invoice_no}
              date={sale.invoice_date}
              status="Draft"
              partyLabel="Customer"
              partyName={contact?.name || "—"}
              partyPhone={contact?.phone}
              partyEmail={contact?.email}
              lines={(items ?? []).map((item) => {
                const product = Array.isArray(item.products) ? item.products[0] : item.products;
                return {
                  name: product?.product_name || "—",
                  qty: Number(item.quantity),
                  unitPrice: Number(item.unit_price),
                  discount: Number(item.discount),
                  tax: Number(item.tax),
                  total: Number(item.line_total),
                };
              })}
              lineMode="items"
              subtotal={Number(sale.subtotal)}
              discount={Number(sale.discount)}
              tax={Number(sale.tax)}
              total={Number(sale.total)}
              notes={sale.notes}
            />
          </div>
        </section>
      </WorkspaceShell>
    );
  }

  const statusClass =
    sale.status === "Confirmed" ? "badge-confirmed" : sale.status === "Cancelled" ? "badge-cancelled" : "badge-draft";

  return (
    <WorkspaceShell active="sales">
      <section className="form-page">
        <div className="form-page-header">
          <div>
            <p className="eyebrow">SALE • {sale.status.toUpperCase()}</p>
            <h1>Sale Invoice {sale.invoice_no}</h1>
            <p className="muted">
              {sale.invoice_date} · {contact?.name || "Customer"}
            </p>
          </div>
          <div className="module-actions">
            <PrintButton />
            <Link className="secondary-button" href="/sales">
              Back to Sales
            </Link>
            <form action={cloneSale}>
              <input type="hidden" name="sale_id" value={sale.id} />
              <button className="secondary-button" type="submit">
                ⧉ Clone as Draft
              </button>
            </form>
            {sale.status === "Confirmed" && (
              <Link className="secondary-button" href={`/sales/${sale.id}/return`}>
                + Record Return
              </Link>
            )}
            {sale.status === "Confirmed" && (
              <form action={cancelSale}>
                <input type="hidden" name="sale_id" value={sale.id} />
                <button className="secondary-button" type="submit">
                  Cancel Sale
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
              {sale.status}
            </span>
          </div>
          <div className="summary-card">
            <span>Total Amount</span>
            <strong>
              ৳{Number(sale.total).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
            </strong>
          </div>
          <div className="summary-card">
            <span>Paid Amount</span>
            <strong>
              ৳{paid.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
            </strong>
          </div>
          <div className="summary-card">
            <span>Due Amount</span>
            <strong>
              ৳{due.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
            </strong>
          </div>
        </section>

        <section className="data-card">
          <div className="form-section-heading">
            <div>
              <p className="eyebrow">CUSTOMER</p>
              <h2>Invoice details</h2>
            </div>
            {due > 0 && sale.status === "Confirmed" && (
              <Link
                className="secondary-button"
                href={`/accounting/payments/new?type=In&contact_id=${sale.contact_id}&sale_id=${sale.id}&amount=${due}`}
              >
                + Receive Payment (৳{due.toFixed(2)})
              </Link>
            )}
          </div>
          <div className="detail-grid">
            <div>
              <span>Customer</span>
              <strong>{contact?.name || "—"}</strong>
            </div>
            <div>
              <span>Phone</span>
              <strong>{contact?.phone || "—"}</strong>
            </div>
            <div>
              <span>Invoice Date</span>
              <strong>{sale.invoice_date}</strong>
            </div>
            <div>
              <span>Created Timestamp</span>
              <strong>{new Date(sale.created_at).toLocaleString("en-BD")}</strong>
            </div>
          </div>
        </section>

        <section className="data-card">
          <div className="form-section-heading">
            <div>
              <p className="eyebrow">ITEMS</p>
              <h2>Sale line items</h2>
            </div>
          </div>
          <div className="table-scroll">
            <table>
              <thead>
                <tr>
                  <th>Product</th>
                  <th className="numeric">Qty</th>
                  <th className="numeric">Unit Price</th>
                  <th className="numeric">Discount</th>
                  <th className="numeric">Tax</th>
                  <th className="numeric">Line Total</th>
                </tr>
              </thead>
              <tbody>
                {items?.map((item) => {
                  const product = Array.isArray(item.products) ? item.products[0] : item.products;
                  return (
                    <tr key={item.id}>
                      <td>
                        <strong>{product?.product_name || "—"}</strong>
                      </td>
                      <td className="numeric">
                        {Number(item.quantity).toLocaleString("en-BD", { maximumFractionDigits: 4 })}
                      </td>
                      <td className="numeric">
                        ৳{Number(item.unit_price).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                      </td>
                      <td className="numeric">
                        ৳{Number(item.discount).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                      </td>
                      <td className="numeric">
                        ৳{Number(item.tax).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                      </td>
                      <td className="numeric">
                        <strong>
                          ৳{Number(item.line_total).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
                        </strong>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          <div className="purchase-total-card">
            <div>
              <span>Subtotal</span>
              <strong>
                ৳{Number(sale.subtotal).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
              </strong>
            </div>
            <div>
              <span>Discount</span>
              <strong>
                − ৳{Number(sale.discount).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
              </strong>
            </div>
            <div>
              <span>Tax</span>
              <strong>
                + ৳{Number(sale.tax).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
              </strong>
            </div>
            <div className="purchase-grand-total">
              <span>Total</span>
              <strong>
                ৳{Number(sale.total).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
              </strong>
            </div>
          </div>
        </section>

        {allocations && allocations.length > 0 && (
          <section className="data-card">
            <div className="form-section-heading">
              <div>
                <p className="eyebrow">SETTLEMENTS</p>
                <h2>Payment allocations</h2>
              </div>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Payment No</th>
                    <th>Payment Date</th>
                    <th>Method</th>
                    <th>Status</th>
                    <th className="numeric">Allocated Amount</th>
                  </tr>
                </thead>
                <tbody>
                  {allocations.map((alloc, idx) => {
                    const payment = Array.isArray(alloc.payments) ? alloc.payments[0] : alloc.payments;
                    return (
                      <tr key={idx}>
                        <td>
                          {payment ? (
                            <Link href={`/accounting/payments/${payment.id}`}>
                              <strong className="mono">{payment.payment_no}</strong>
                            </Link>
                          ) : (
                            "—"
                          )}
                        </td>
                        <td>{payment?.payment_date || "—"}</td>
                        <td>{payment?.payment_method || "—"}</td>
                        <td>
                          <span
                            className={
                              payment?.status === "Confirmed"
                                ? "badge-confirmed"
                                : payment?.status === "Cancelled"
                                ? "badge-cancelled"
                                : "badge-draft"
                            }
                          >
                            {payment?.status}
                          </span>
                        </td>
                        <td className="numeric">
                          <strong>
                            ৳{Number(alloc.allocated_amount).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
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

        {sale.notes && (
          <section className="data-card">
            <p className="eyebrow">NOTES</p>
            <p>{sale.notes}</p>
          </section>
        )}

        <div className="print-area">
          <InvoiceDocument
            orgName={orgName}
            orgPhone={organization?.phone_number}
            orgEmail={organization?.email}
            orgAddress={organization?.address}
            title="SALES INVOICE"
            docNo={"#" + sale.invoice_no}
            date={sale.invoice_date}
            status={sale.status}
            partyLabel="Customer"
            partyName={contact?.name || "—"}
            partyPhone={contact?.phone}
            partyEmail={contact?.email}
            lines={(items ?? []).map((item) => {
              const product = Array.isArray(item.products) ? item.products[0] : item.products;
              return {
                name: product?.product_name || "—",
                qty: Number(item.quantity),
                unitPrice: Number(item.unit_price),
                discount: Number(item.discount),
                tax: Number(item.tax),
                total: Number(item.line_total),
              };
            })}
            lineMode="items"
            subtotal={Number(sale.subtotal)}
            discount={Number(sale.discount)}
            tax={Number(sale.tax)}
            total={Number(sale.total)}
            paid={paid}
            due={due}
            notes={sale.notes}
          />
        </div>
      </section>
    </WorkspaceShell>
  );
}
