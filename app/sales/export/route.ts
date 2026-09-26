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
    .from("sales")
    .select("invoice_no, invoice_date, total, status, contacts(name)")
    .eq("organization_id", organizationId)
    .order("invoice_date", { ascending: false })
    .limit(2000);

  if (search) query = query.ilike("invoice_no", "%" + search.replace(/[\\%_]/g, "\\$&") + "%");
  if (status) query = query.eq("status", status);

  const { data: sales, error } = await query;
  if (error) return Response.json({ error: error.message || "Unable to export sales." }, { status: 500 });

  return csvResponse("sales.csv", [
    ["Invoice No", "Date", "Contact", "Total", "Status"],
    ...(sales ?? []).map((s) => {
      const contact = Array.isArray(s.contacts) ? s.contacts[0] : s.contacts;
      return [s.invoice_no, s.invoice_date, contact?.name || "", String(s.total), s.status];
    }),
  ]);
}
