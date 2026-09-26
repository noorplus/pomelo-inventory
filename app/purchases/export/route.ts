import { getWorkspaceMembership } from "@/lib/auth/workspace";
import { csvResponse } from "@/lib/csv";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const url = new URL(request.url);
  const search = String(url.searchParams.get("search") || "").trim();
  const status = ["Draft", "Confirmed", "Cancelled"].includes(String(url.searchParams.get("status")))
    ? String(url.searchParams.get("status"))
    : "";

  let query = supabase
    .from("purchases")
    .select("invoice_no, invoice_date, total, status, contacts(name)")
    .eq("organization_id", organizationId)
    .order("invoice_date", { ascending: false })
    .limit(2000);

  if (search) query = query.ilike("invoice_no", "%" + search.replace(/[\\%_]/g, "\\$&") + "%");
  if (status) query = query.eq("status", status);

  const { data: purchases, error } = await query;
  if (error) return Response.json({ error: error.message || "Unable to export purchases." }, { status: 500 });

  return csvResponse("purchases.csv", [
    ["Invoice No", "Date", "Contact", "Total", "Status"],
    ...(purchases ?? []).map((p) => {
      const contact = Array.isArray(p.contacts) ? p.contacts[0] : p.contacts;
      return [p.invoice_no, p.invoice_date, contact?.name || "", String(p.total), p.status];
    }),
  ]);
}
