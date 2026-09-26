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
  const requiredHeaders = ["product name", "uom", "retail price"];
  const missing = requiredHeaders.filter((header) => !headers.includes(header));
  if (missing.length) return Response.json({ error: `Missing required column(s): ${missing.join(", ")}.` }, { status: 400 });

  const index = (name: string) => headers.indexOf(name);
  const nameIndex = index("product name");
  const uomIndex = index("uom");
  const priceIndex = index("retail price");
  const statusIndex = index("status");

  const { data: units, error: unitsError } = await supabase
    .from("units_of_measure")
    .select("id, name")
    .eq("organization_id", organizationId)
    .eq("status", "Active");

  if (unitsError) return Response.json({ error: unitsError.message }, { status: 500 });

  const unitMap = new Map((units ?? []).map((unit) => [unit.name.trim().toLowerCase(), unit.id]));
  const { data: existingProducts, error: productsError } = await supabase
    .from("products")
    .select("product_name")
    .eq("organization_id", organizationId);

  if (productsError) return Response.json({ error: productsError.message }, { status: 500 });

  const existingNames = new Set((existingProducts ?? []).map((product) => product.product_name));
  const seenNames = new Set<string>();
  const valid: Array<{ organization_id: string; product_name: string; uom_id: string; retail_price: number; status: "Active" | "Inactive"; created_by: string }> = [];
  const errors: string[] = [];

  rows.slice(1).forEach((row, offset) => {
    const line = offset + 2;
    const productName = String(row[nameIndex] || "").trim();
    const uomName = String(row[uomIndex] || "").trim();
    const priceText = String(row[priceIndex] || "").trim();
    const statusText = String(statusIndex >= 0 ? row[statusIndex] || "" : "").trim() || "Active";
    const price = Number(priceText);
    const key = productName;

    if (!productName) errors.push(`Row ${line}: Product Name is required.`);
    else if (existingNames.has(key) || seenNames.has(key)) errors.push(`Row ${line}: Product Name "${productName}" already exists.`);
    else if (!uomName) errors.push(`Row ${line}: UoM is required.`);
    else if (!unitMap.has(uomName.toLowerCase())) errors.push(`Row ${line}: UoM "${uomName}" is not an active unit.`);
    else if (!priceText || !Number.isFinite(price) || price < 0) errors.push(`Row ${line}: Retail Price must be a non-negative number.`);
    else if (statusText !== "Active" && statusText !== "Inactive") errors.push(`Row ${line}: Status must be Active or Inactive.`);
    else {
      seenNames.add(key);
      valid.push({ organization_id: organizationId, product_name: productName, uom_id: unitMap.get(uomName.toLowerCase())!, retail_price: price, status: statusText, created_by: user.id });
    }
  });

  if (!valid.length) return Response.json({ imported: 0, skipped: rows.length - 1, errors: errors.slice(0, 20) });

  const { error: insertError } = await supabase.from("products").insert(valid);
  if (insertError) return Response.json({ error: insertError.message, imported: 0, skipped: rows.length - 1, errors: errors.slice(0, 20) }, { status: 400 });

  return Response.json({ imported: valid.length, skipped: errors.length, errors: errors.slice(0, 20) });
}
