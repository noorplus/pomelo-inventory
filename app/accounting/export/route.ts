import { getWorkspaceMembership } from "@/lib/auth/workspace";
import { csvResponse } from "@/lib/csv";

export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const { supabase, organizationId } = await getWorkspaceMembership();
  const url = new URL(request.url);
  const scope = ["ledger", "payments", "expenses"].includes(String(url.searchParams.get("scope")))
    ? String(url.searchParams.get("scope"))
    : "ledger";

  if (scope === "payments") {
    const { data, error } = await supabase
      .from("payments")
      .select("payment_no, payment_date, payment_type, amount, payment_method, status, contacts(name)")
      .eq("organization_id", organizationId)
      .order("payment_date", { ascending: false })
      .limit(2000);
    if (error) return Response.json({ error: error.message || "Unable to export payments." }, { status: 500 });
    return csvResponse("payments.csv", [
      ["Payment No", "Date", "Type", "Contact", "Amount", "Method", "Status"],
      ...(data ?? []).map((p) => {
        const contact = Array.isArray(p.contacts) ? p.contacts[0] : p.contacts;
        return [p.payment_no, p.payment_date, p.payment_type, contact?.name || "", String(p.amount), p.payment_method, p.status];
      }),
    ]);
  }

  if (scope === "expenses") {
    const { data, error } = await supabase
      .from("expenses")
      .select("expense_no, expense_date, description, amount, status, expense_categories(name), contacts(name)")
      .eq("organization_id", organizationId)
      .order("expense_date", { ascending: false })
      .limit(2000);
    if (error) return Response.json({ error: error.message || "Unable to export expenses." }, { status: 500 });
    return csvResponse("expenses.csv", [
      ["Expense No", "Date", "Category", "Payee", "Description", "Amount", "Status"],
      ...(data ?? []).map((e) => {
        const cat = Array.isArray(e.expense_categories) ? e.expense_categories[0] : e.expense_categories;
        const contact = Array.isArray(e.contacts) ? e.contacts[0] : e.contacts;
        return [e.expense_no, e.expense_date, cat?.name || "", contact?.name || "", e.description, String(e.amount), e.status];
      }),
    ]);
  }

  const { data, error } = await supabase
    .from("account_transactions")
    .select("transaction_date, transaction_type, reference_type, reference_id, description, debit, credit, contacts(name)")
    .eq("organization_id", organizationId)
    .order("transaction_date", { ascending: false })
    .limit(2000);
  if (error) return Response.json({ error: error.message || "Unable to export ledger." }, { status: 500 });
  return csvResponse("ledger.csv", [
    ["Date", "Type", "Reference", "Description", "Contact", "Debit", "Credit"],
    ...(data ?? []).map((t) => {
      const contact = Array.isArray(t.contacts) ? t.contacts[0] : t.contacts;
      return [
        t.transaction_date,
        t.transaction_type,
        t.reference_type && t.reference_id ? `${t.reference_type} ${String(t.reference_id).slice(0, 8)}` : "",
        t.description,
        contact?.name || "",
        String(t.debit),
        String(t.credit),
      ];
    }),
  ]);
}
