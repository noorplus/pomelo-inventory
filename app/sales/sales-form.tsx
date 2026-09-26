"use client";

import { useId, useState } from "react";
import Link from "next/link";

type ContactOption = {
  id: string;
  name: string;
  phone?: string | null;
};

type ProductOption = {
  id: string;
  product_name: string;
  retail_price: number;
  stock_quantity?: number;
};

export type SaleItemState = {
  id?: string;
  product_id: string;
  quantity: number;
  unit_price: number;
  discount: number;
  tax: number;
};

type Props = {
  contacts: ContactOption[];
  products: ProductOption[];
  action: (formData: FormData) => Promise<void>;
  submitLabel: string;
  saleId?: string;
  initialContactId?: string;
  initialDate?: string;
  initialNotes?: string;
  initialItems?: SaleItemState[];
  error?: string;
};

export default function SalesForm({
  contacts,
  products,
  action,
  submitLabel,
  saleId,
  initialContactId,
  initialDate,
  initialNotes = "",
  initialItems = [],
  error,
}: Props) {
  const formId = useId();
  const [items, setItems] = useState<SaleItemState[]>(
    initialItems.length > 0
      ? initialItems
      : [
          {
            product_id: products[0]?.id || "",
            quantity: 1,
            unit_price: Number(products[0]?.retail_price || 0),
            discount: 0,
            tax: 0,
          },
        ],
  );

  function addItem() {
    setItems((prev) => [
      ...prev,
      {
        product_id: products[0]?.id || "",
        quantity: 1,
        unit_price: Number(products[0]?.retail_price || 0),
        discount: 0,
        tax: 0,
      },
    ]);
  }

  function removeItem(index: number) {
    setItems((prev) => prev.filter((_, i) => i !== index));
  }

  function updateItem(index: number, patch: Partial<SaleItemState>) {
    setItems((prev) =>
      prev.map((item, i) => {
        if (i !== index) return item;
        const next = { ...item, ...patch };
        if (patch.product_id && patch.product_id !== item.product_id) {
          const prod = products.find((p) => p.id === patch.product_id);
          if (prod) {
            next.unit_price = Number(prod.retail_price || 0);
          }
        }
        return next;
      }),
    );
  }

  const subtotal = items.reduce((sum, item) => sum + (item.quantity || 0) * (item.unit_price || 0), 0);
  const discountTotal = items.reduce((sum, item) => sum + (item.discount || 0), 0);
  const taxTotal = items.reduce((sum, item) => sum + (item.tax || 0), 0);
  const grandTotal = Math.max(0, subtotal - discountTotal + taxTotal);

  return (
    <form action={action} className="purchase-form" id={formId}>
      {saleId && <input type="hidden" name="sale_id" value={saleId} />}
      <input type="hidden" name="items_json" value={JSON.stringify(items)} />

      {error && <div className="form-error" role="alert">{error}</div>}

      <section className="data-card">
        <div className="form-section-heading">
          <div>
            <p className="eyebrow">SALE ORDER</p>
            <h2>General information</h2>
          </div>
        </div>
        <div className="form-grid">
          <label>
            Customer *
            <select name="contact_id" defaultValue={initialContactId || ""} required>
              <option value="">Select customer</option>
              {contacts.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name} {c.phone ? `(${c.phone})` : ""}
                </option>
              ))}
            </select>
          </label>
          <label>
            Invoice date *
            <input
              name="invoice_date"
              type="date"
              defaultValue={initialDate || new Date().toISOString().split("T")[0]}
              required
            />
          </label>
          <label className="full-width">
            Notes / memo
            <textarea
              name="notes"
              rows={2}
              defaultValue={initialNotes}
              placeholder="Terms, payment instructions, or delivery notes"
            />
          </label>
        </div>
      </section>

      <section className="data-card">
        <div className="form-section-heading">
          <div>
            <p className="eyebrow">LINE ITEMS</p>
            <h2>Sale items</h2>
          </div>
          <button type="button" onClick={addItem} className="secondary-button">
            + Add line
          </button>
        </div>

        <div className="table-scroll purchase-items-table">
          <table>
            <thead>
              <tr>
                <th style={{ width: "35%" }}>Product</th>
                <th className="numeric" style={{ width: "12%" }}>Qty</th>
                <th className="numeric" style={{ width: "15%" }}>Unit Price</th>
                <th className="numeric" style={{ width: "12%" }}>Discount</th>
                <th className="numeric" style={{ width: "10%" }}>Tax</th>
                <th className="numeric" style={{ width: "16%" }}>Line Total</th>
                <th style={{ width: "40px" }} />
              </tr>
            </thead>
            <tbody>
              {items.map((item, index) => {
                const prod = products.find((p) => p.id === item.product_id);
                const lineTotal =
                  (item.quantity || 0) * (item.unit_price || 0) - (item.discount || 0) + (item.tax || 0);
                const availableStock = prod?.stock_quantity ?? 0;
                const isOutOfStock = availableStock <= 0;
                const isInsufficient = item.quantity > availableStock;
                // A product picked in another row is hidden here, so the
                // same product cannot be selected twice in one document.
                const availableProducts = products.filter(
                  (p) => p.id === item.product_id || !items.some((other, oi) => oi !== index && other.product_id === p.id),
                );

                return (
                  <tr key={index}>
                    <td>
                      <select
                        value={item.product_id}
                        onChange={(e) => updateItem(index, { product_id: e.target.value })}
                        required
                      >
                        {availableProducts.map((p) => (
                          <option key={p.id} value={p.id}>
                            {p.product_name} (Stock: {p.stock_quantity ?? 0})
                          </option>
                        ))}
                      </select>
                      {isInsufficient && (
                        <span style={{ fontSize: "10px", color: "var(--danger)", display: "block", marginTop: "2px" }}>
                          ⚠ Stock is {availableStock} (Order qty: {item.quantity})
                        </span>
                      )}
                    </td>
                    <td>
                      <input
                        type="number"
                        min="0.0001"
                        step="any"
                        className="compact-number"
                        value={item.quantity}
                        onChange={(e) => updateItem(index, { quantity: parseFloat(e.target.value) || 0 })}
                        required
                      />
                    </td>
                    <td>
                      <input
                        type="number"
                        min="0"
                        step="0.01"
                        className="compact-number"
                        value={item.unit_price}
                        onChange={(e) => updateItem(index, { unit_price: parseFloat(e.target.value) || 0 })}
                        required
                      />
                    </td>
                    <td>
                      <input
                        type="number"
                        min="0"
                        max={(item.quantity || 0) * (item.unit_price || 0)}
                        step="0.01"
                        className="compact-number"
                        value={item.discount}
                        onChange={(e) => updateItem(index, { discount: parseFloat(e.target.value) || 0 })}
                      />
                    </td>
                    <td>
                      <input
                        type="number"
                        min="0"
                        step="0.01"
                        className="compact-number"
                        value={item.tax}
                        onChange={(e) => updateItem(index, { tax: parseFloat(e.target.value) || 0 })}
                      />
                    </td>
                    <td className="numeric">
                      <strong>
                        ৳
                        {lineTotal.toLocaleString("en-BD", {
                          minimumFractionDigits: 2,
                          maximumFractionDigits: 2,
                        })}
                      </strong>
                    </td>
                    <td>
                      <button
                        type="button"
                        onClick={() => removeItem(index)}
                        disabled={items.length <= 1}
                        className="icon-button"
                        title="Remove item"
                      >
                        ×
                      </button>
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
              ৳{subtotal.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
            </strong>
          </div>
          <div>
            <span>Discount</span>
            <strong>
              − ৳{discountTotal.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
            </strong>
          </div>
          <div>
            <span>Tax</span>
            <strong>
              + ৳{taxTotal.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
            </strong>
          </div>
          <div className="purchase-grand-total">
            <span>Net Total</span>
            <strong>
              ৳{grandTotal.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
            </strong>
          </div>
        </div>
      </section>

      <div className="form-actions">
        <Link className="secondary-button" href="/sales">
          Cancel
        </Link>
        <button className="primary-button" type="submit">
          {submitLabel}
        </button>
      </div>
    </form>
  );
}
