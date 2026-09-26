import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { createSale } from "@/app/sales/actions";
import SalesForm from "@/app/sales/sales-form";

export const dynamic = "force-dynamic";

type SearchParams = { error?: string };

export default async function NewSalePage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const query = await searchParams;

  const [{ data: contacts }, { data: products }, { data: stockList }] = await Promise.all([
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
  ]);

  const stockMap = new Map<string, number>();
  (stockList ?? []).forEach((s) => stockMap.set(s.product_id, Number(s.quantity || 0)));

  const productsWithStock = (products ?? []).map((p) => ({
    ...p,
    retail_price: Number(p.retail_price || 0),
    stock_quantity: stockMap.get(p.id) ?? 0,
  }));

  const error = query.error ? decodeURIComponent(query.error) : "";

  return (
    <WorkspaceShell active="sales">
      <section className="form-page">
        <div className="form-page-header">
          <div>
            <p className="eyebrow">SALES • NEW</p>
            <h1>Create Sales Order</h1>
            <p className="muted">Create a draft sale order. Confirming it dispatches stock and posts accounts receivable.</p>
          </div>
          <Link className="secondary-button" href="/sales">
            Back to Sales
          </Link>
        </div>

        <SalesForm
          contacts={contacts ?? []}
          products={productsWithStock}
          action={createSale}
          submitLabel="Save Draft Sale"
          error={error}
        />
      </section>
    </WorkspaceShell>
  );
}
