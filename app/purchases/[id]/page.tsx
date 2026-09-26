import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { cancelPurchase, confirmPurchase, deletePurchase, updatePurchase } from "@/app/purchases/actions";
import PurchaseForm from "@/app/purchases/purchase-form";

export const dynamic = "force-dynamic";

type Params = { id: string };
type SearchParams = { error?: string };

export default async function PurchaseDetailPage({
  params,
  searchParams,
}: {
  params: Promise<Params>;
  searchParams: Promise<SearchParams>;
}) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const { id } = await params;
  const query = await searchParams;

  const { data: purchase, error: purchaseError } = await supabase
    .from("purchases")
    .select("id, invoice_no, invoice_date, contact_id, status, subtotal, discount, tax, total, notes, created_at, created_by, contacts(id_no, name, phone, email)")
    .eq("organization_id", organizationId)
    .eq("id", id)
    .single();

  if (purchaseError || !purchase) {
    return (
      <WorkspaceShell active="purchases">
        <section className="form-page">
          <div className="form-page-header"><div><p className="eyebrow">PURCHASES</p><h1>Purchase not found</h1><p className="muted">{purchaseError?.message || "The purchase does not exist or is outside this workspace."}</p></div><Link className="secondary-button" href="/purchases">Back to Purchases</Link></div>
        </section>
      </WorkspaceShell>
    );
  }

  const [{ data: items, error: itemsError }, { data: contacts }, { data: products }, { data: allocations }] = await Promise.all([
    supabase.from("purchase_items").select("id, product_id, quantity, unit_price, discount, tax, line_total, products(product_name, retail_price, uom_id)").eq("organization_id", organizationId).eq("purchase_id", id).order("created_at"),
    supabase.from("contacts").select("id, id_no, name, phone").eq("organization_id", organizationId).eq("status", "Active").order("name"),
    supabase.from("products").select("id, product_name, retail_price, uom_id").eq("organization_id", organizationId).eq("status", "Active").order("product_name"),
    supabase.from("payment_allocations").select("allocated_amount, payments!inner(status)").eq("organization_id", organizationId).eq("purchase_id", id),
  ]);

  const paid = (allocations ?? []).reduce((sum, allocation) => {
    const payment = Array.isArray(allocation.payments) ? allocation.payments[0] : allocation.payments;
    return payment?.status === "Confirmed" ? sum + Number(allocation.allocated_amount) : sum;
  }, 0);
  const due = Math.max(0, Number(purchase.total) - paid);
  const contact = Array.isArray(purchase.contacts) ? purchase.contacts[0] : purchase.contacts;
  const error = query.error ? decodeURIComponent(query.error) : "";

  if (itemsError) {
    return (
      <WorkspaceShell active="purchases">
        <section className="form-page"><div className="form-page-header"><div><p className="eyebrow">PURCHASES</p><h1>{purchase.invoice_no}</h1><p className="muted">Unable to load purchase items: {itemsError.message}</p></div><Link className="secondary-button" href="/purchases">Back</Link></div></section>
      </WorkspaceShell>
    );
  }

  if (purchase.status === "Draft") {
    return (
      <WorkspaceShell active="purchases">
        <section className="form-page">
          <div className="form-page-header">
            <div><p className="eyebrow">PURCHASE • DRAFT</p><h1>Edit Purchase {purchase.invoice_no}</h1><p className="muted">Drafts are editable. Confirmation atomically updates stock and payable ledger entries.</p></div>
            <Link className="secondary-button" href="/purchases">Back to Purchases</Link>
          </div>
          <PurchaseForm
            contacts={(contacts ?? []).map((entry) => ({ ...entry, id_no: Number(entry.id_no) }))}
            products={(products ?? []).map((entry) => ({ ...entry, retail_price: Number(entry.retail_price) }))}
            action={updatePurchase}
            submitLabel="Save Draft"
            purchaseId={purchase.id}
            initialContactId={purchase.contact_id}
            initialDate={purchase.invoice_date}
            initialNotes={purchase.notes || ""}
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
            <div><strong>Ready to confirm?</strong><p className="muted">Make sure the items and totals are correct. Confirmation is a financial and inventory operation.</p></div>
            <div className="module-actions">
              <form action={deletePurchase}><input type="hidden" name="purchase_id" value={purchase.id} /><button className="secondary-button" type="submit">Delete Draft</button></form>
              <form action={confirmPurchase}><input type="hidden" name="purchase_id" value={purchase.id} /><button className="primary-button" type="submit">Confirm Purchase</button></form>
            </div>
          </section>
        </section>
      </WorkspaceShell>
    );
  }

  return (
    <WorkspaceShell active="purchases">
      <section className="form-page">
        <div className="form-page-header">
          <div><p className="eyebrow">PURCHASE • {purchase.status.toUpperCase()}</p><h1>Purchase {purchase.invoice_no}</h1><p className="muted">{purchase.invoice_date} · {contact?.name || "Unknown contact"}</p></div>
          <div className="module-actions"><Link className="secondary-button" href="/purchases">Back to Purchases</Link>{purchase.status === "Confirmed" && <form action={cancelPurchase}><input type="hidden" name="purchase_id" value={purchase.id} /><button className="secondary-button" type="submit">Cancel Purchase</button></form>}</div>
        </div>

        {error && <div className="form-error" role="alert">{error}</div>}

        <section className="summary-grid">
          <div className="summary-card"><span>Status</span><strong>{purchase.status}</strong></div>
          <div className="summary-card"><span>Total</span><strong>৳{Number(purchase.total).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</strong></div>
          <div className="summary-card"><span>Paid</span><strong>৳{paid.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</strong></div>
          <div className="summary-card"><span>Due</span><strong>৳{due.toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</strong></div>
        </section>

        <section className="data-card">
          <div className="form-section-heading"><div><p className="eyebrow">INVOICE</p><h2>Purchase details</h2></div></div>
          <div className="detail-grid">
            <div><span>Contact</span><strong>{contact?.name || "—"}</strong></div>
            <div><span>Phone</span><strong>{contact?.phone || "—"}</strong></div>
            <div><span>Invoice date</span><strong>{purchase.invoice_date}</strong></div>
            <div><span>Created</span><strong>{new Date(purchase.created_at).toLocaleString("en-BD")}</strong></div>
          </div>
        </section>

        <section className="data-card">
          <div className="form-section-heading"><div><p className="eyebrow">ITEMS</p><h2>Purchase items</h2></div></div>
          <div className="table-scroll"><table><thead><tr><th>Product</th><th className="numeric">Qty</th><th className="numeric">Unit price</th><th className="numeric">Discount</th><th className="numeric">Tax</th><th className="numeric">Line total</th></tr></thead>
            <tbody>{items?.map((item) => {
              const product = Array.isArray(item.products) ? item.products[0] : item.products;
              return <tr key={item.id}><td><strong>{product?.product_name || "—"}</strong></td><td className="numeric">{Number(item.quantity).toLocaleString("en-BD", { maximumFractionDigits: 4 })}</td><td className="numeric">৳{Number(item.unit_price).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</td><td className="numeric">৳{Number(item.discount).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</td><td className="numeric">৳{Number(item.tax).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</td><td className="numeric"><strong>৳{Number(item.line_total).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</strong></td></tr>;
            })}</tbody></table></div>
          <div className="purchase-total-card"><div><span>Subtotal</span><strong>৳{Number(purchase.subtotal).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</strong></div><div><span>Discount</span><strong>− ৳{Number(purchase.discount).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</strong></div><div><span>Tax</span><strong>+ ৳{Number(purchase.tax).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</strong></div><div className="purchase-grand-total"><span>Total</span><strong>৳{Number(purchase.total).toLocaleString("en-BD", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}</strong></div></div>
        </section>

        {purchase.notes && <section className="data-card"><p className="eyebrow">NOTES</p><p>{purchase.notes}</p></section>}
      </section>
    </WorkspaceShell>
  );
}
