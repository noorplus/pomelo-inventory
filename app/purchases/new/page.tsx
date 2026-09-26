import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { createPurchase } from "@/app/purchases/actions";
import PurchaseForm from "@/app/purchases/purchase-form";

export const dynamic = "force-dynamic";

type SearchParams = { error?: string };

export default async function NewPurchasePage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const params = await searchParams;

  const [{ data: contacts, error: contactsError }, { data: products, error: productsError }, { data: stockList }] = await Promise.all([
    supabase.from("contacts").select("id, id_no, name, phone").eq("organization_id", organizationId).eq("status", "Active").order("name").limit(500),
    supabase.from("products").select("id, product_name, retail_price, uom_id").eq("organization_id", organizationId).eq("status", "Active").order("product_name").limit(500),
    supabase.from("stock").select("product_id, quantity").eq("organization_id", organizationId),
  ]);

  const error = contactsError?.message || productsError?.message || (params.error ? decodeURIComponent(params.error) : "");

  const stockMap = new Map<string, number>();
  (stockList ?? []).forEach((s) => stockMap.set(s.product_id, Number(s.quantity || 0)));
  const productsWithStock = (products ?? []).map((product) => ({
    ...product,
    retail_price: Number(product.retail_price),
    stock_quantity: stockMap.get(product.id) ?? 0,
  }));

  return (
    <WorkspaceShell active="purchases">
      <section className="form-page">
        <div className="form-page-header">
          <div>
            <p className="eyebrow">PURCHASES</p>
            <h1>New Purchase</h1>
            <p className="muted">Create a Draft purchase invoice. Confirming it will update stock and payable ledger entries atomically.</p>
          </div>
          <Link className="secondary-button" href="/purchases">Back to Purchases</Link>
        </div>

        {contactsError || productsError ? (
          <section className="form-error" role="alert">Unable to load purchase data: {error}</section>
        ) : !contacts?.length ? (
          <section className="form-error" role="alert">Add an active contact before creating a purchase. <Link href="/contacts/new">Go to Contacts</Link>.</section>
        ) : (
          <PurchaseForm
            contacts={contacts.map((contact) => ({ ...contact, id_no: Number(contact.id_no) }))}
            products={productsWithStock}
            action={createPurchase}
            submitLabel="Save Draft"
            error={params.error ? decodeURIComponent(params.error) : ""}
          />
        )}
      </section>
    </WorkspaceShell>
  );
}
