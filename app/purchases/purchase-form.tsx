"use client";

import { useMemo, useState } from "react";

type Product = { id: string; product_name: string; retail_price: number; uom_id: string; stock_quantity?: number };
type Contact = { id: string; id_no: number; name: string; phone: string | null };
type Item = { id?: string; product_id: string; quantity: number; unit_price: number; discount: number; tax: number };

type Props = {
  products: Product[];
  contacts: Contact[];
  action: (formData: FormData) => void | Promise<void>;
  submitLabel: string;
  purchaseId?: string;
  initialContactId?: string;
  initialDate?: string;
  initialNotes?: string;
  initialItems?: Item[];
  error?: string;
};

const money = (value: number) => value.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 });

export default function PurchaseForm({
  products,
  contacts,
  action,
  submitLabel,
  purchaseId,
  initialContactId = "",
  initialDate = new Date().toISOString().slice(0, 10),
  initialNotes = "",
  initialItems = [],
  error = "",
}: Props) {
  const [contactId, setContactId] = useState(initialContactId);
  const [invoiceDate, setInvoiceDate] = useState(initialDate);
  const [notes, setNotes] = useState(initialNotes);
  const [items, setItems] = useState<Item[]>(
    initialItems.length ? initialItems : [{ product_id: "", quantity: 1, unit_price: 0, discount: 0, tax: 0 }],
  );

  const totals = useMemo(() => {
    let subtotal = 0, discount = 0, tax = 0;
    for (const item of items) {
      subtotal += Number(item.quantity || 0) * Number(item.unit_price || 0);
      discount += Number(item.discount || 0);
      tax += Number(item.tax || 0);
    }
    return { subtotal, discount, tax, total: subtotal - discount + tax };
  }, [items]);

  function updateItem(index: number, patch: Partial<Item>) {
    setItems((current) => current.map((item, i) => (i === index ? { ...item, ...patch } : item)));
  }

  function selectProduct(index: number, productId: string) {
    const product = products.find((entry) => entry.id === productId);
    updateItem(index, { product_id: productId, unit_price: product ? Number(product.retail_price) : 0 });
  }

  function addItem() {
    setItems((current) => [...current, { product_id: "", quantity: 1, unit_price: 0, discount: 0, tax: 0 }]);
  }

  function removeItem(index: number) {
    setItems((current) => current.length === 1 ? current : current.filter((_, i) => i !== index));
  }

  return (
    <form className="purchase-form" action={action}>
      {purchaseId && <input type="hidden" name="purchase_id" value={purchaseId} />}
      <input type="hidden" name="items_json" value={JSON.stringify(items)} />

      <section className="data-card">
        <div className="form-section-heading"><div><p className="eyebrow">PURCHASE</p><h2>Invoice details</h2></div></div>
        <div className="form-grid">
          <label>
            Supplier / Contact<span className="required-mark">*</span>
            <select name="contact_id" value={contactId} onChange={(event) => setContactId(event.target.value)} required>
              <option value="" disabled>Select contact</option>
              {contacts.map((contact) => (
                <option key={contact.id} value={contact.id}>{contact.id_no} — {contact.name}{contact.phone ? " · " + contact.phone : ""}</option>
              ))}
            </select>
          </label>
          <label>
            Invoice date<span className="required-mark">*</span>
            <input name="invoice_date" type="date" value={invoiceDate} onChange={(event) => setInvoiceDate(event.target.value)} required />
          </label>
          <label className="full-width">
            Notes
            <textarea name="notes" value={notes} onChange={(event) => setNotes(event.target.value)} rows={3} placeholder="Optional notes" />
          </label>
        </div>
      </section>

      <section className="data-card">
        <div className="form-section-heading">
          <div><p className="eyebrow">ITEMS</p><h2>Purchase items</h2><p className="muted">Add products, quantities, purchase prices, discount and tax.</p></div>
          <button className="secondary-button" type="button" onClick={addItem}>+ Add item</button>
        </div>

        {!products.length ? (
          <div className="form-error" role="alert">No active products are available. Add an active product before creating a purchase.</div>
        ) : (
          <div className="table-scroll purchase-items-table">
            <table>
              <thead><tr><th>Product</th><th className="numeric">Qty</th><th className="numeric">Unit price</th><th className="numeric">Discount</th><th className="numeric">Tax</th><th className="numeric">Line total</th><th /></tr></thead>
              <tbody>
                {items.map((item, index) => {
                  const base = Number(item.quantity || 0) * Number(item.unit_price || 0);
                  const lineTotal = base - Number(item.discount || 0) + Number(item.tax || 0);
                  const prod = products.find((p) => p.id === item.product_id);
                  const currentStock = prod?.stock_quantity ?? 0;
                  // A product picked in another row is hidden here, so the
                  // same product cannot be selected twice in one document.
                  const availableProducts = products.filter(
                    (p) => p.id === item.product_id || !items.some((other, oi) => oi !== index && other.product_id === p.id),
                  );
                  return (
                    <tr key={index}>
                      <td>
                        <select value={item.product_id} onChange={(event) => selectProduct(index, event.target.value)} required aria-label="Product">
                          <option value="" disabled>Select product</option>
                          {availableProducts.map((product) => <option key={product.id} value={product.id}>{product.product_name} (Stock: {product.stock_quantity ?? 0})</option>)}
                        </select>
                        {item.product_id && (
                          <span style={{ fontSize: "10px", color: "var(--muted)", display: "block", marginTop: "2px" }}>
                            In stock: {currentStock} → after receive: {currentStock + Number(item.quantity || 0)}
                          </span>
                        )}
                      </td>
                      <td className="numeric"><input className="compact-number" type="number" min="0.0001" step="0.0001" value={item.quantity} onChange={(event) => updateItem(index, { quantity: Number(event.target.value) })} aria-label="Quantity" required /></td>
                      <td className="numeric"><input className="compact-number" type="number" min="0" step="0.01" value={item.unit_price} onChange={(event) => updateItem(index, { unit_price: Number(event.target.value) })} aria-label="Unit price" required /></td>
                      <td className="numeric"><input className="compact-number" type="number" min="0" step="0.01" value={item.discount} onChange={(event) => updateItem(index, { discount: Number(event.target.value) })} aria-label="Discount" /></td>
                      <td className="numeric"><input className="compact-number" type="number" min="0" step="0.01" value={item.tax} onChange={(event) => updateItem(index, { tax: Number(event.target.value) })} aria-label="Tax" /></td>
                      <td className="numeric"><strong>৳{money(lineTotal)}</strong></td>
                      <td><button className="icon-button" type="button" onClick={() => removeItem(index)} disabled={items.length === 1} aria-label="Remove item">×</button></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        <div className="purchase-total-card">
          <div><span>Subtotal</span><strong>৳{money(totals.subtotal)}</strong></div>
          <div><span>Discount</span><strong>− ৳{money(totals.discount)}</strong></div>
          <div><span>Tax</span><strong>+ ৳{money(totals.tax)}</strong></div>
          <div className="purchase-grand-total"><span>Total</span><strong>৳{money(totals.total)}</strong></div>
        </div>
      </section>

      {error && <div className="form-error" role="alert">{error}</div>}
      <div className="form-actions">
        <button className="primary-button" type="submit" disabled={!products.length}>{submitLabel}</button>
      </div>
    </form>
  );
}
