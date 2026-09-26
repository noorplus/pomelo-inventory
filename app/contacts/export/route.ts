import { getWorkspaceMembership } from "@/lib/auth/workspace";
import { csvResponse } from "@/lib/csv";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const url = new URL(request.url);
  const search = String(url.searchParams.get("search") || "").trim();
  const status = url.searchParams.get("status") === "Inactive" ? "Inactive" : url.searchParams.get("status") === "Active" ? "Active" : "";

  let query = supabase
    .from("contacts")
    .select("name, phone, email, address, status")
    .eq("organization_id", organizationId)
    .order("id_no");

  if (search) {
    const escaped = search.replace(/[\\%,_]/g, (character) => `\\${character}`).replace(/,/g, "");
    query = query.or(`name.ilike.%${escaped}%,phone.ilike.%${escaped}%,email.ilike.%${escaped}%,address.ilike.%${escaped}%`);
  }
  if (status) query = query.eq("status", status);

  const { data: contacts, error } = await query;
  if (error) return Response.json({ error: error.message || "Unable to export contacts." }, { status: 500 });

  return csvResponse("contacts.csv", [
    ["Name", "Phone", "Email", "Address", "Status"],
    ...(contacts ?? []).map((contact) => [
      contact.name,
      contact.phone || "",
      contact.email || "",
      contact.address || "",
      contact.status,
    ]),
  ]);
}
