import { getWorkspaceMembership } from "@/lib/auth/workspace";
import { parseCsv } from "@/lib/csv";

const MAX_ROWS = 2000;
const MAX_FILE_SIZE = 2 * 1024 * 1024;

export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const { supabase, user, organizationId } = await getWorkspaceMembership();
  const formData = await request.formData();
  const file = formData.get("file");

  if (!(file instanceof File)) return Response.json({ error: "Please select a CSV file." }, { status: 400 });
  if (file.size > MAX_FILE_SIZE) return Response.json({ error: "CSV file is too large. Maximum size is 2 MB." }, { status: 400 });

  let rows: string[][];
  try {
    rows = parseCsv(await file.text());
  } catch (error) {
    return Response.json({ error: error instanceof Error ? error.message : "Invalid CSV file." }, { status: 400 });
  }

  if (rows.length < 2) return Response.json({ error: "CSV must contain a header row and at least one data row." }, { status: 400 });
  if (rows.length - 1 > MAX_ROWS) return Response.json({ error: `CSV can contain at most ${MAX_ROWS} data rows.` }, { status: 400 });

  const headers = rows[0].map((value) => value.trim().toLowerCase());
  const nameIndex = headers.indexOf("name");
  if (nameIndex < 0) return Response.json({ error: "Missing required column: Name." }, { status: 400 });

  const index = (name: string) => headers.indexOf(name);
  const phoneIndex = index("phone");
  const emailIndex = index("email");
  const addressIndex = index("address");
  const statusIndex = index("status");

  const valid: Array<{ organization_id: string; name: string; phone: string | null; email: string | null; address: string | null; status: "Active" | "Inactive"; created_by: string }> = [];
  const errors: string[] = [];

  rows.slice(1).forEach((row, offset) => {
    const line = offset + 2;
    const name = String(row[nameIndex] || "").trim();
    const phone = String(phoneIndex >= 0 ? row[phoneIndex] || "" : "").trim();
    const email = String(emailIndex >= 0 ? row[emailIndex] || "" : "").trim();
    const address = String(addressIndex >= 0 ? row[addressIndex] || "" : "").trim();
    const statusText = String(statusIndex >= 0 ? row[statusIndex] || "" : "").trim() || "Active";

    if (!name) errors.push(`Row ${line}: Name is required.`);
    else if (statusText !== "Active" && statusText !== "Inactive") errors.push(`Row ${line}: Status must be Active or Inactive.`);
    else {
      valid.push({
        organization_id: organizationId,
        name,
        phone: phone || null,
        email: email || null,
        address: address || null,
        status: statusText as "Active" | "Inactive",
        created_by: user.id,
      });
    }
  });

  if (!valid.length) return Response.json({ imported: 0, skipped: rows.length - 1, errors: errors.slice(0, 20) });

  const { error: insertError } = await supabase.from("contacts").insert(valid);
  if (insertError) return Response.json({ error: insertError.message, imported: 0, skipped: rows.length - 1, errors: errors.slice(0, 20) }, { status: 400 });

  return Response.json({ imported: valid.length, skipped: errors.length, errors: errors.slice(0, 20) });
}
