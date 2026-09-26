import Link from "next/link";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";

export const dynamic = "force-dynamic";

type SearchParams = { tab?: string };

const TABS = [
  "due",
  "aging",
  "cashflow",
  "profit",
  "valuation",
  "tax",
  "top",
  "expenses",
  "velocity",
  "audit",
  "efficiency",
] as const;

type Tab = (typeof TABS)[number];

const TAB_DEFS: { key: Tab; label: string }[] = [
  { key: "due", label: "Due follow-up" },
  { key: "aging", label: "Aging" },
  { key: "cashflow", label: "Cash flow" },
  { key: "profit", label: "Profit" },
  { key: "valuation", label: "Valuation" },
  { key: "tax", label: "Tax" },
  { key: "top", label: "Top contacts" },
  { key: "expenses", label: "Expenses" },
  { key: "velocity", label: "Velocity" },
  { key: "audit", label: "Audit" },
  { key: "efficiency", label: "Efficiency" },
];

// Exact money format from the database contract.
const money = (v: unknown): string =>
  `৳${Number(v || 0).toLocaleString("en-BD", { minimumFractionDigits: 2 })}`;

const num = (v: unknown): number => Number(v || 0);

const DAY_MS = 86400000;

const daysOverdue = (dateStr: string): number => {
  const t = new Date(dateStr).getTime();
  if (Number.isNaN(t)) return 0;
  return Math.max(0, Math.floor((Date.now() - t) / DAY_MS));
};

const monthKey = (dateStr: string): string => String(dateStr || "").slice(0, 7);

const bucketOf = (days: number): string =>
  days <= 30 ? "Current" : days <= 60 ? "31–60" : days <= 90 ? "61–90" : "90d+";

type JoinedName = { name: string } | { name: string }[] | null | undefined;

const joinedName = (c: JoinedName): string => {
  if (!c) return "—";
  if (Array.isArray(c)) return c[0]?.name || "—";
  return c.name || "—";
};

type JoinedProduct = { product_name: string } | { product_name: string }[] | null | undefined;

const joinedProductName = (p: JoinedProduct): string => {
  if (!p) return "—";
  if (Array.isArray(p)) return p[0]?.product_name || "—";
  return p.product_name || "—";
};

type AllocRow = {
  allocated_amount: unknown;
  sale_id?: string | null;
  purchase_id?: string | null;
  expense_id?: string | null;
  payments: JoinedPayment;
};

type JoinedPayment =
  | { status: string; payment_no?: string; payment_date?: string }
  | { status: string; payment_no?: string; payment_date?: string }[]
  | null;

const allocConfirmed = (a: AllocRow): boolean => {
  const p = Array.isArray(a.payments) ? a.payments[0] : a.payments;
  return p?.status === "Confirmed";
};

// Batch-aggregated Confirmed allocation totals keyed by target document id.
const sumConfirmedBy = (
  rows: AllocRow[],
  key: "sale_id" | "purchase_id" | "expense_id",
): Map<string, number> => {
  const m = new Map<string, number>();
  for (const r of rows) {
    if (!allocConfirmed(r)) continue;
    const id = r[key];
    if (!id) continue;
    m.set(id, (m.get(id) || 0) + num(r.allocated_amount));
  }
  return m;
};

type DueRow = {
  kind: string;
  ref: string;
  contact: string;
  date: string;
  days: number;
  total: number;
  settled: number;
  outstanding: number;
};

export default async function ReportsPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const params = await searchParams;
  const rawTab = String(params.tab || "due");
  const currentTab: Tab = (TABS as readonly string[]).includes(rawTab)
    ? (rawTab as Tab)
    : "due";

  // WorkspaceShell does not list "reports" in its nav union; cast keeps
  // TypeScript strict happy without touching the shared shell component.
  const shellActive = "reports" as const;

  let activeCount = 0;

  // ---- due + aging (shared outstanding computation) ----
  let dueRows: DueRow[] = [];
  let dueReceivable = 0;
  let duePayable = 0;

  if (currentTab === "due" || currentTab === "aging") {
    type DocRow = {
      id: string;
      invoice_no?: string;
      expense_no?: string;
      invoice_date?: string;
      expense_date?: string;
      total?: unknown;
      amount?: unknown;
      status: string;
      contacts: JoinedName;
    };
    const [{ data: salesRaw }, { data: purchasesRaw }, { data: expensesRaw }] =
      await Promise.all([
        supabase
          .from("sales")
          .select("id, invoice_no, invoice_date, total, status, contacts(name)")
          .eq("organization_id", organizationId)
          .eq("status", "Confirmed")
          .order("invoice_date", { ascending: true })
          .limit(200),
        supabase
          .from("purchases")
          .select("id, invoice_no, invoice_date, total, status, contacts(name)")
          .eq("organization_id", organizationId)
          .eq("status", "Confirmed")
          .order("invoice_date", { ascending: true })
          .limit(200),
        supabase
          .from("expenses")
          .select("id, expense_no, expense_date, amount, status, contacts(name)")
          .eq("organization_id", organizationId)
          .eq("status", "Confirmed")
          .order("expense_date", { ascending: true })
          .limit(200),
      ]);
    const sales = (salesRaw ?? []) as DocRow[];
    const purchases = (purchasesRaw ?? []) as DocRow[];
    const expenses = (expensesRaw ?? []) as DocRow[];

    const saleIds = sales.map((s) => s.id);
    const purchaseIds = purchases.map((p) => p.id);
    const expenseIds = expenses.map((e) => e.id);

    // Batched allocation lookups with .in() — never one query per row.
    const [{ data: saleAllocsRaw }, { data: purchaseAllocsRaw }, { data: expenseAllocsRaw }] =
      await Promise.all([
        saleIds.length
          ? supabase
              .from("payment_allocations")
              .select("sale_id, allocated_amount, payments!inner(status)")
              .eq("organization_id", organizationId)
              .in("sale_id", saleIds)
          : Promise.resolve({ data: [] as AllocRow[] }),
        purchaseIds.length
          ? supabase
              .from("payment_allocations")
              .select("purchase_id, allocated_amount, payments!inner(status)")
              .eq("organization_id", organizationId)
              .in("purchase_id", purchaseIds)
          : Promise.resolve({ data: [] as AllocRow[] }),
        expenseIds.length
          ? supabase
              .from("payment_allocations")
              .select("expense_id, allocated_amount, payments!inner(status)")
              .eq("organization_id", organizationId)
              .in("expense_id", expenseIds)
          : Promise.resolve({ data: [] as AllocRow[] }),
      ]);
    const salePaid = sumConfirmedBy((saleAllocsRaw ?? []) as AllocRow[], "sale_id");
    const purchasePaid = sumConfirmedBy((purchaseAllocsRaw ?? []) as AllocRow[], "purchase_id");
    const expensePaid = sumConfirmedBy((expenseAllocsRaw ?? []) as AllocRow[], "expense_id");

    const rows: DueRow[] = [];
    for (const s of sales) {
      const total = num(s.total);
      const settled = salePaid.get(s.id) || 0;
      const outstanding = total - settled;
      if (outstanding <= 0) continue;
      rows.push({
        kind: "Sale",
        ref: `#${s.invoice_no}`,
        contact: joinedName(s.contacts),
        date: s.invoice_date || "",
        days: daysOverdue(s.invoice_date || ""),
        total,
        settled,
        outstanding,
      });
      dueReceivable += outstanding;
    }
    for (const p of purchases) {
      const total = num(p.total);
      const settled = purchasePaid.get(p.id) || 0;
      const outstanding = total - settled;
      if (outstanding <= 0) continue;
      rows.push({
        kind: "Purchase",
        ref: `#${p.invoice_no}`,
        contact: joinedName(p.contacts),
        date: p.invoice_date || "",
        days: daysOverdue(p.invoice_date || ""),
        total,
        settled,
        outstanding,
      });
      duePayable += outstanding;
    }
    for (const e of expenses) {
      const total = num(e.amount);
      const settled = expensePaid.get(e.id) || 0;
      const outstanding = total - settled;
      if (outstanding <= 0) continue;
      rows.push({
        kind: "Expense",
        ref: e.expense_no || "",
        contact: joinedName(e.contacts),
        date: e.expense_date || "",
        days: daysOverdue(e.expense_date || ""),
        total,
        settled,
        outstanding,
      });
      duePayable += outstanding;
    }
    // Oldest first.
    rows.sort((a, b) => (a.date < b.date ? -1 : a.date > b.date ? 1 : 0));
    dueRows = rows;
    activeCount = dueRows.length;
  }

  // ---- cashflow ----
  type CashMonth = { month: string; count: number; inflow: number; outflow: number };
  let cashMonths: CashMonth[] = [];
  let cashIn = 0;
  let cashOut = 0;
  let cashMethodSplit = "";

  if (currentTab === "cashflow") {
    type PayRow = {
      payment_date: string;
      payment_type: string;
      amount: unknown;
      payment_method: string;
    };
    const { data: paysRaw } = await supabase
      .from("payments")
      .select("payment_date, payment_type, amount, payment_method")
      .eq("organization_id", organizationId)
      .eq("status", "Confirmed")
      .order("payment_date", { ascending: false })
      .limit(200);
    const pays = (paysRaw ?? []) as PayRow[];
    const byMonth = new Map<string, CashMonth>();
    const byMethod = new Map<string, number>();
    for (const p of pays) {
      const m = monthKey(p.payment_date);
      if (!m) continue;
      const amt = num(p.amount);
      const entry = byMonth.get(m) || { month: m, count: 0, inflow: 0, outflow: 0 };
      entry.count += 1;
      if (p.payment_type === "In") {
        entry.inflow += amt;
        cashIn += amt;
      } else {
        entry.outflow += amt;
        cashOut += amt;
      }
      byMonth.set(m, entry);
      const method = p.payment_method || "Unknown";
      byMethod.set(method, (byMethod.get(method) || 0) + amt);
    }
    cashMonths = Array.from(byMonth.values()).sort((a, b) =>
      a.month < b.month ? 1 : a.month > b.month ? -1 : 0,
    );
    cashMethodSplit = Array.from(byMethod.entries())
      .sort((a, b) => b[1] - a[1])
      .slice(0, 6)
      .map(([method, total]) => `${method}: ${money(total)}`)
      .join(" · ");
    activeCount = cashMonths.length;
  }

  // ---- profit ----
  type ProfitProduct = {
    productId: string;
    name: string;
    qty: number;
    revenue: number;
    cost: number;
    profit: number;
    marginPct: number;
  };
  type ProfitInvoice = {
    invoiceNo: string;
    date: string;
    contact: string;
    revenue: number;
    cost: number;
    margin: number;
    marginPct: number;
  };
  let profitProducts: ProfitProduct[] = [];
  let profitInvoices: ProfitInvoice[] = [];
  let profitRevenue = 0;
  let profitCost = 0;

  if (currentTab === "profit") {
    type SaleHead = {
      id: string;
      invoice_no: string;
      invoice_date: string;
      total: unknown;
      contacts: JoinedName;
    };
    type SaleItemRow = {
      sale_id: string;
      product_id: string;
      quantity: unknown;
      line_total: unknown;
    };
    type MoveCostRow = {
      product_id: string;
      quantity: unknown;
      unit_cost: unknown;
      reference_id: string | null;
    };
    const { data: headsRaw } = await supabase
      .from("sales")
      .select("id, invoice_no, invoice_date, total, contacts(name)")
      .eq("organization_id", organizationId)
      .eq("status", "Confirmed")
      .order("invoice_date", { ascending: false })
      .limit(50);
    const heads = (headsRaw ?? []) as SaleHead[];
    const saleIds = heads.map((h) => h.id);

    const [{ data: itemsRaw }, { data: movesRaw }] = await Promise.all([
      saleIds.length
        ? supabase
            .from("sale_items")
            .select("sale_id, product_id, quantity, line_total")
            .eq("organization_id", organizationId)
            .in("sale_id", saleIds)
            .limit(200)
        : Promise.resolve({ data: [] as SaleItemRow[] }),
      saleIds.length
        ? supabase
            .from("inventory_movements")
            .select("product_id, quantity, unit_cost, reference_id")
            .eq("organization_id", organizationId)
            .eq("movement_direction", "Out")
            .eq("movement_type", "Sale")
            .in("reference_id", saleIds)
            .limit(200)
        : Promise.resolve({ data: [] as MoveCostRow[] }),
    ]);
    const items = (itemsRaw ?? []) as SaleItemRow[];
    const moves = (movesRaw ?? []) as MoveCostRow[];
    const productIds = Array.from(new Set(items.map((i) => i.product_id)));

    const [{ data: prodsRaw }, { data: pricesRaw }] = await Promise.all([
      productIds.length
        ? supabase
            .from("products")
            .select("id, product_name")
            .eq("organization_id", organizationId)
            .in("id", productIds.slice(0, 200))
        : Promise.resolve({ data: null }),
      productIds.length
        ? supabase
            .from("purchase_items")
            .select("product_id, unit_price")
            .eq("organization_id", organizationId)
            .in("product_id", productIds.slice(0, 200))
            .limit(200)
        : Promise.resolve({ data: null }),
    ]);
    const prods = (prodsRaw ?? []) as { id: string; product_name: string }[];
    const prices = (pricesRaw ?? []) as { product_id: string; unit_price: unknown }[];

    const nameMap = new Map(prods.map((p) => [p.id, p.product_name]));
    // Fallback purchase price: average purchase unit_price per product.
    const priceSum = new Map<string, { sum: number; n: number }>();
    for (const pr of prices) {
      const agg = priceSum.get(pr.product_id) || { sum: 0, n: 0 };
      agg.sum += num(pr.unit_price);
      agg.n += 1;
      priceSum.set(pr.product_id, agg);
    }
    const fallbackPrice = (productId: string): number => {
      const agg = priceSum.get(productId);
      return agg && agg.n ? agg.sum / agg.n : 0;
    };
    const effectiveUnitCost = (m: MoveCostRow): number => {
      const raw = m.unit_cost;
      if (raw === null || raw === undefined || raw === "") return fallbackPrice(m.product_id);
      const c = Number(raw);
      return Number.isNaN(c) ? fallbackPrice(m.product_id) : c;
    };

    const revenueByProduct = new Map<string, { qty: number; revenue: number }>();
    for (const it of items) {
      const agg = revenueByProduct.get(it.product_id) || { qty: 0, revenue: 0 };
      agg.qty += num(it.quantity);
      agg.revenue += num(it.line_total);
      revenueByProduct.set(it.product_id, agg);
    }
    const costByProduct = new Map<string, number>();
    const costBySale = new Map<string, number>();
    for (const m of moves) {
      const c = num(m.quantity) * effectiveUnitCost(m);
      costByProduct.set(m.product_id, (costByProduct.get(m.product_id) || 0) + c);
      if (m.reference_id) {
        costBySale.set(m.reference_id, (costBySale.get(m.reference_id) || 0) + c);
      }
    }

    profitProducts = Array.from(revenueByProduct.entries()).map(([productId, agg]) => {
      const cost = costByProduct.get(productId) || 0;
      const profit = agg.revenue - cost;
      return {
        productId,
        name: nameMap.get(productId) || "—",
        qty: agg.qty,
        revenue: agg.revenue,
        cost,
        profit,
        marginPct: agg.revenue ? (profit / agg.revenue) * 100 : 0,
      };
    });
    profitProducts.sort((a, b) => b.profit - a.profit);

    profitInvoices = heads.map((h) => {
      const revenue = num(h.total);
      const cost = costBySale.get(h.id) || 0;
      const margin = revenue - cost;
      return {
        invoiceNo: h.invoice_no,
        date: h.invoice_date,
        contact: joinedName(h.contacts),
        revenue,
        cost,
        margin,
        marginPct: revenue ? (margin / revenue) * 100 : 0,
      };
    });
    profitRevenue = heads.reduce((s, h) => s + num(h.total), 0);
    profitCost = Array.from(costBySale.values()).reduce((s, c) => s + c, 0);
    activeCount = profitProducts.length;
  }

  // ---- valuation ----
  type ValuationRow = {
    productId: string;
    name: string;
    qty: number;
    unitCost: number;
    source: string;
    value: number;
  };
  let valuationRows: ValuationRow[] = [];
  let valuationTotal = 0;
  let valuationFallbackCount = 0;

  if (currentTab === "valuation") {
    type StockRow = { product_id: string; quantity: unknown };
    type ProductRow = { id: string; product_name: string; retail_price: unknown };
    type InMoveRow = { product_id: string; unit_cost: unknown; movement_date: string };
    const [{ data: stockRaw }, { data: prodsRaw }, { data: movesRaw }] = await Promise.all([
      supabase
        .from("stock")
        .select("product_id, quantity")
        .eq("organization_id", organizationId)
        .limit(200),
      supabase
        .from("products")
        .select("id, product_name, retail_price")
        .eq("organization_id", organizationId)
        .limit(200),
      supabase
        .from("inventory_movements")
        .select("product_id, unit_cost, movement_date")
        .eq("organization_id", organizationId)
        .eq("movement_direction", "In")
        .eq("movement_type", "Purchase")
        .order("movement_date", { ascending: false })
        .limit(200),
    ]);
    const stock = (stockRaw ?? []) as StockRow[];
    const prods = (prodsRaw ?? []) as ProductRow[];
    const inMoves = (movesRaw ?? []) as InMoveRow[];

    // Latest In-Purchase unit_cost per product (rows already newest-first).
    const latestCost = new Map<string, number>();
    for (const m of inMoves) {
      if (latestCost.has(m.product_id)) continue;
      if (m.unit_cost === null || m.unit_cost === undefined || m.unit_cost === "") continue;
      const c = Number(m.unit_cost);
      if (Number.isNaN(c)) continue;
      latestCost.set(m.product_id, c);
    }
    const stockMap = new Map(stock.map((s) => [s.product_id, num(s.quantity)]));
    valuationRows = prods.map((p) => {
      const qty = stockMap.get(p.id) || 0;
      const cost = latestCost.get(p.id);
      const useFallback = cost === undefined;
      const unitCost = useFallback ? num(p.retail_price) : (cost as number);
      if (useFallback && qty > 0) valuationFallbackCount += 1;
      return {
        productId: p.id,
        name: p.product_name,
        qty,
        unitCost,
        source: useFallback ? "Retail" : "Purchase",
        value: qty * unitCost,
      };
    });
    valuationRows.sort((a, b) => b.value - a.value);
    valuationTotal = valuationRows.reduce((s, r) => s + r.value, 0);
    activeCount = valuationRows.length;
  }

  // ---- tax ----
  type TaxMonth = {
    month: string;
    salesTax: number;
    salesDiscount: number;
    purchaseTax: number;
    purchaseDiscount: number;
  };
  let taxMonths: TaxMonth[] = [];
  let taxSalesTotal = 0;
  let taxPurchaseTotal = 0;
  let taxDiscountTotal = 0;

  if (currentTab === "tax") {
    type TaxHead = { invoice_date: string; discount: unknown; tax: unknown };
    const [{ data: salesTaxRaw }, { data: purchasesTaxRaw }] = await Promise.all([
      supabase
        .from("sales")
        .select("invoice_date, discount, tax")
        .eq("organization_id", organizationId)
        .eq("status", "Confirmed")
        .order("invoice_date", { ascending: false })
        .limit(200),
      supabase
        .from("purchases")
        .select("invoice_date, discount, tax")
        .eq("organization_id", organizationId)
        .eq("status", "Confirmed")
        .order("invoice_date", { ascending: false })
        .limit(200),
    ]);
    const byMonth = new Map<string, TaxMonth>();
    const getEntry = (month: string): TaxMonth => {
      const e = byMonth.get(month) || {
        month,
        salesTax: 0,
        salesDiscount: 0,
        purchaseTax: 0,
        purchaseDiscount: 0,
      };
      byMonth.set(month, e);
      return e;
    };
    for (const s of ((salesTaxRaw ?? []) as TaxHead[])) {
      const m = monthKey(s.invoice_date);
      if (!m) continue;
      const e = getEntry(m);
      e.salesTax += num(s.tax);
      e.salesDiscount += num(s.discount);
      taxSalesTotal += num(s.tax);
      taxDiscountTotal += num(s.discount);
    }
    for (const p of ((purchasesTaxRaw ?? []) as TaxHead[])) {
      const m = monthKey(p.invoice_date);
      if (!m) continue;
      const e = getEntry(m);
      e.purchaseTax += num(p.tax);
      e.purchaseDiscount += num(p.discount);
      taxPurchaseTotal += num(p.tax);
      taxDiscountTotal += num(p.discount);
    }
    taxMonths = Array.from(byMonth.values()).sort((a, b) =>
      a.month < b.month ? 1 : a.month > b.month ? -1 : 0,
    );
    activeCount = taxMonths.length;
  }

  // ---- top contacts ----
  type TopRow = { rank: number; kind: string; name: string; docs: number; total: number };
  let topRows: TopRow[] = [];
  let topCustomerName = "—";
  let topCustomerTotal = 0;
  let topSupplierName = "—";
  let topSupplierTotal = 0;

  if (currentTab === "top") {
    type ContactTotal = { contact_id: string | null; total: unknown };
    const [{ data: salesTopRaw }, { data: purchasesTopRaw }] = await Promise.all([
      supabase
        .from("sales")
        .select("contact_id, total")
        .eq("organization_id", organizationId)
        .eq("status", "Confirmed")
        .limit(200),
      supabase
        .from("purchases")
        .select("contact_id, total")
        .eq("organization_id", organizationId)
        .eq("status", "Confirmed")
        .limit(200),
    ]);
    const aggregate = (rows: ContactTotal[]) => {
      const m = new Map<string, { docs: number; total: number }>();
      for (const r of rows) {
        if (!r.contact_id) continue;
        const agg = m.get(r.contact_id) || { docs: 0, total: 0 };
        agg.docs += 1;
        agg.total += num(r.total);
        m.set(r.contact_id, agg);
      }
      return Array.from(m.entries())
        .sort((a, b) => b[1].total - a[1].total)
        .slice(0, 10);
    };
    const topCustomers = aggregate((salesTopRaw ?? []) as ContactTotal[]);
    const topSuppliers = aggregate((purchasesTopRaw ?? []) as ContactTotal[]);
    const ids = Array.from(
      new Set([...topCustomers, ...topSuppliers].map(([id]) => id)),
    ).slice(0, 200);
    const { data: contactsRaw } = ids.length
      ? await supabase
          .from("contacts")
          .select("id, name")
          .eq("organization_id", organizationId)
          .in("id", ids)
      : { data: null };
    const nameMap = new Map(
      (((contactsRaw ?? []) as { id: string; name: string }[]) || []).map((c) => [c.id, c.name]),
    );
    if (topCustomers.length) {
      topCustomerName = nameMap.get(topCustomers[0][0]) || "—";
      topCustomerTotal = topCustomers[0][1].total;
    }
    if (topSuppliers.length) {
      topSupplierName = nameMap.get(topSuppliers[0][0]) || "—";
      topSupplierTotal = topSuppliers[0][1].total;
    }
    topRows = [
      ...topCustomers.map(([id, agg], i) => ({
        rank: i + 1,
        kind: "Customer",
        name: nameMap.get(id) || "—",
        docs: agg.docs,
        total: agg.total,
      })),
      ...topSuppliers.map(([id, agg], i) => ({
        rank: i + 1,
        kind: "Supplier",
        name: nameMap.get(id) || "—",
        docs: agg.docs,
        total: agg.total,
      })),
    ];
    activeCount = topRows.length;
  }

  // ---- expenses by category by month ----
  type ExpenseCatRow = {
    category: string;
    month: string;
    entries: number;
    total: number;
  };
  let expenseRows: ExpenseCatRow[] = [];
  let expenseGrandTotal = 0;
  let expenseTopCategory = "—";
  let expenseCategoryCount = 0;

  if (currentTab === "expenses") {
    type ExpRow = {
      expense_date: string;
      amount: unknown;
      expense_category_id: string | null;
    };
    const [{ data: expsRaw }, { data: catsRaw }] = await Promise.all([
      supabase
        .from("expenses")
        .select("expense_date, amount, expense_category_id")
        .eq("organization_id", organizationId)
        .eq("status", "Confirmed")
        .order("expense_date", { ascending: false })
        .limit(200),
      supabase
        .from("expense_categories")
        .select("id, name")
        .eq("organization_id", organizationId)
        .limit(200),
    ]);
    const catMap = new Map(
      (((catsRaw ?? []) as { id: string; name: string }[]) || []).map((c) => [c.id, c.name]),
    );
    const byKey = new Map<string, ExpenseCatRow>();
    const catTotals = new Map<string, number>();
    for (const e of ((expsRaw ?? []) as ExpRow[])) {
      const m = monthKey(e.expense_date);
      if (!m) continue;
      const category = (e.expense_category_id && catMap.get(e.expense_category_id)) || "General";
      const key = `${category}|||${m}`;
      const entry = byKey.get(key) || { category, month: m, entries: 0, total: 0 };
      entry.entries += 1;
      entry.total += num(e.amount);
      byKey.set(key, entry);
      catTotals.set(category, (catTotals.get(category) || 0) + num(e.amount));
      expenseGrandTotal += num(e.amount);
    }
    expenseRows = Array.from(byKey.values()).sort((a, b) =>
      a.category < b.category
        ? -1
        : a.category > b.category
          ? 1
          : a.month < b.month
            ? 1
            : -1,
    );
    expenseCategoryCount = catTotals.size;
    const topCat = Array.from(catTotals.entries()).sort((a, b) => b[1] - a[1])[0];
    if (topCat) expenseTopCategory = `${topCat[0]} (${money(topCat[1])})`;
    activeCount = expenseRows.length;
  }

  // ---- velocity ----
  type VelocityRow = {
    productId: string;
    name: string;
    inQty: number;
    outQty: number;
    stock: number;
    flag: string;
  };
  let velocityRows: VelocityRow[] = [];
  let velocityFast = 0;
  let velocitySlow = 0;
  let velocityInTotal = 0;
  let velocityOutTotal = 0;

  if (currentTab === "velocity") {
    type VelMove = {
      product_id: string;
      movement_direction: string;
      quantity: unknown;
    };
    const since = new Date(Date.now() - 90 * DAY_MS).toISOString();
    const [{ data: movesRaw }, { data: stockRaw }, { data: prodsRaw }] = await Promise.all([
      supabase
        .from("inventory_movements")
        .select("product_id, movement_direction, quantity")
        .eq("organization_id", organizationId)
        .gte("movement_date", since)
        .limit(200),
      supabase
        .from("stock")
        .select("product_id, quantity")
        .eq("organization_id", organizationId)
        .limit(200),
      supabase
        .from("products")
        .select("id, product_name")
        .eq("organization_id", organizationId)
        .limit(200),
    ]);
    const inQty = new Map<string, number>();
    const outQty = new Map<string, number>();
    for (const m of ((movesRaw ?? []) as VelMove[])) {
      const q = num(m.quantity);
      if (m.movement_direction === "In") {
        inQty.set(m.product_id, (inQty.get(m.product_id) || 0) + q);
        velocityInTotal += q;
      } else {
        outQty.set(m.product_id, (outQty.get(m.product_id) || 0) + q);
        velocityOutTotal += q;
      }
    }
    const stockMap = new Map(
      (((stockRaw ?? []) as { product_id: string; quantity: unknown }[]) || []).map((s) => [
        s.product_id,
        num(s.quantity),
      ]),
    );
    velocityRows = (
      ((prodsRaw ?? []) as { id: string; product_name: string }[]) || []
    ).map((p) => {
      const out = outQty.get(p.id) || 0;
      const flag = out > 0 ? "Fast" : "Slow";
      if (flag === "Fast") velocityFast += 1;
      else velocitySlow += 1;
      return {
        productId: p.id,
        name: p.product_name,
        inQty: inQty.get(p.id) || 0,
        outQty: out,
        stock: stockMap.get(p.id) || 0,
        flag,
      };
    });
    // Slow movers first so they get attention.
    velocityRows.sort((a, b) => a.outQty - b.outQty);
    activeCount = velocityRows.length;
  }

  // ---- audit ----
  type TxnRow = {
    id: string;
    transaction_date: string;
    transaction_type: string;
    reference_type: string | null;
    reference_id: string | null;
    description: string;
    debit: unknown;
    credit: unknown;
    created_by: string | null;
    contacts: JoinedName;
  };
  type AuditMove = {
    id: string;
    movement_date: string;
    product_id: string;
    movement_direction: string;
    movement_type: string;
    quantity: unknown;
    reference_type: string | null;
    reference_id: string | null;
    unit_cost: unknown;
    created_by: string | null;
    products: JoinedProduct;
  };
  let auditTxns: TxnRow[] = [];
  let auditMoves: AuditMove[] = [];
  let auditActorNames = new Map<string, string>();
  let auditDebitTotal = 0;
  let auditCreditTotal = 0;

  if (currentTab === "audit") {
    const [{ data: txnsRaw }, { data: movesRaw }] = await Promise.all([
      supabase
        .from("account_transactions")
        .select(
          "id, transaction_date, transaction_type, reference_type, reference_id, description, debit, credit, created_by, contacts(name)",
        )
        .eq("organization_id", organizationId)
        .order("transaction_date", { ascending: false })
        .limit(100),
      supabase
        .from("inventory_movements")
        .select(
          "id, movement_date, product_id, movement_direction, movement_type, quantity, reference_type, reference_id, unit_cost, created_by, products(product_name)",
        )
        .eq("organization_id", organizationId)
        .order("movement_date", { ascending: false })
        .limit(100),
    ]);
    auditTxns = (txnsRaw ?? []) as TxnRow[];
    auditMoves = (movesRaw ?? []) as AuditMove[];
    auditDebitTotal = auditTxns.reduce((s, t) => s + num(t.debit), 0);
    auditCreditTotal = auditTxns.reduce((s, t) => s + num(t.credit), 0);
    const actorIds = Array.from(
      new Set(
        [...auditTxns.map((t) => t.created_by), ...auditMoves.map((m) => m.created_by)].filter(
          (id): id is string => !!id,
        ),
      ),
    ).slice(0, 200);
    if (actorIds.length) {
      const { data: profilesRaw } = await supabase
        .from("profiles")
        .select("id, full_name")
        .in("id", actorIds);
      const profiles = (profilesRaw ?? []) as { id: string; full_name: string }[];
      auditActorNames = new Map(profiles.map((p) => [p.id, p.full_name]));
    }
    activeCount = auditTxns.length + auditMoves.length;
  }

  const auditActor = (id: string | null): string => {
    if (!id) return "—";
    return auditActorNames.get(id) || `${id.slice(0, 8)}…`;
  };

  // ---- efficiency ----
  type EffMonth = {
    month: string;
    billed: number;
    received: number;
    outstanding: number;
    pct: number;
  };
  let effMonths: EffMonth[] = [];
  let effBilled = 0;
  let effReceived = 0;

  if (currentTab === "efficiency") {
    type EffSale = {
      id: string;
      invoice_no: string;
      invoice_date: string;
      total: unknown;
    };
    const { data: effSalesRaw } = await supabase
      .from("sales")
      .select("id, invoice_no, invoice_date, total")
      .eq("organization_id", organizationId)
      .eq("status", "Confirmed")
      .order("invoice_date", { ascending: false })
      .limit(200);
    const effSales = (effSalesRaw ?? []) as EffSale[];
    const effSaleIds = effSales.map((s) => s.id);
    const { data: effAllocsRaw } = effSaleIds.length
      ? await supabase
          .from("payment_allocations")
          .select("sale_id, allocated_amount, payments!inner(status)")
          .eq("organization_id", organizationId)
          .in("sale_id", effSaleIds)
      : { data: [] as AllocRow[] };
    const receivedBySale = sumConfirmedBy((effAllocsRaw ?? []) as AllocRow[], "sale_id");
    const byMonth = new Map<string, EffMonth>();
    for (const s of effSales) {
      const m = monthKey(s.invoice_date);
      if (!m) continue;
      const billed = num(s.total);
      const received = receivedBySale.get(s.id) || 0;
      const entry = byMonth.get(m) || { month: m, billed: 0, received: 0, outstanding: 0, pct: 0 };
      entry.billed += billed;
      entry.received += received;
      byMonth.set(m, entry);
      effBilled += billed;
      effReceived += received;
    }
    effMonths = Array.from(byMonth.values())
      .map((e) => ({
        ...e,
        outstanding: e.billed - e.received,
        pct: e.billed ? (e.received / e.billed) * 100 : 0,
      }))
      .sort((a, b) => (a.month < b.month ? 1 : a.month > b.month ? -1 : 0));
    activeCount = effMonths.length;
  }

  const effOverallPct = effBilled ? (effReceived / effBilled) * 100 : 0;
  const profitMarginPct = profitRevenue ? ((profitRevenue - profitCost) / profitRevenue) * 100 : 0;
  const oldestDueDays = dueRows.length ? Math.max(...dueRows.map((r) => r.days)) : 0;

  return (
    <WorkspaceShell active={shellActive}>
      <section className="module-toolbar">
        <div>
          <p className="eyebrow">READ-ONLY ANALYTICS</p>
          <h1>Reports</h1>
          <p className="muted">
            SELECT-only summaries across sales, purchases, expenses, payments, and inventory.
          </p>
        </div>
        <div className="module-actions">
          <Link className="secondary-button" href="/">
            Back to Dashboard
          </Link>
        </div>
      </section>

      <div className="module-tabs">
        {TAB_DEFS.map((t) => (
          <Link
            key={t.key}
            className={`tab-link ${currentTab === t.key ? "active" : ""}`}
            href={`/reports?tab=${t.key}`}
          >
            <span>{t.label}</span>
            {t.key === currentTab && <span className="tab-badge">{activeCount}</span>}
          </Link>
        ))}
      </div>

      {currentTab === "due" && (
        <>
          <section className="summary-grid">
            <div className="summary-card">
              <span>Receivable Due (owed to us)</span>
              <strong style={{ color: "var(--success)" }}>{money(dueReceivable)}</strong>
            </div>
            <div className="summary-card">
              <span>Payable Due (we owe)</span>
              <strong style={{ color: "var(--primary-dark)" }}>{money(duePayable)}</strong>
            </div>
            <div className="summary-card">
              <span>Open Documents</span>
              <strong>{dueRows.length}</strong>
            </div>
            <div className="summary-card">
              <span>Oldest Overdue</span>
              <strong>{oldestDueDays} day(s)</strong>
            </div>
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{dueRows.length} open document(s)</strong>
              <span>Confirmed sales, purchases, and expenses with outstanding balance · oldest first</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Type</th>
                    <th>Reference</th>
                    <th>Contact</th>
                    <th>Date</th>
                    <th className="numeric">Days Overdue</th>
                    <th className="numeric">Total</th>
                    <th className="numeric">Settled</th>
                    <th className="numeric">Outstanding</th>
                  </tr>
                </thead>
                <tbody>
                  {dueRows.map((r, i) => (
                    <tr key={`${r.kind}-${r.ref}-${i}`}>
                      <td>
                        <span className="status-badge">{r.kind}</span>
                      </td>
                      <td>
                        <strong className="mono">{r.ref}</strong>
                      </td>
                      <td>{r.contact}</td>
                      <td>{r.date}</td>
                      <td className="numeric">{r.days}</td>
                      <td className="numeric">{money(r.total)}</td>
                      <td className="numeric">{money(r.settled)}</td>
                      <td className="numeric">
                        <strong>{money(r.outstanding)}</strong>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!dueRows.length && (
              <div className="empty-state">
                <div className="empty-icon">✓</div>
                <div>
                  <h2>Nothing overdue</h2>
                  <p>All confirmed documents are fully settled.</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}

      {currentTab === "aging" && (
        <>
          <section className="summary-grid">
            {["Current", "31–60", "61–90", "90d+"].map((bucket) => {
              const inBucket = dueRows.filter((r) => bucketOf(r.days) === bucket);
              const total = inBucket.reduce((s, r) => s + r.outstanding, 0);
              return (
                <div className="summary-card" key={bucket}>
                  <span>
                    {bucket === "Current" ? "Current (≤30d)" : `${bucket}d`} · {inBucket.length} doc(s)
                  </span>
                  <strong>{money(total)}</strong>
                </div>
              );
            })}
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{dueRows.length} open document(s)</strong>
              <span>Receivables and payables grouped by age since invoice / expense date</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Bucket</th>
                    <th>Type</th>
                    <th>Reference</th>
                    <th>Contact</th>
                    <th>Date</th>
                    <th className="numeric">Total</th>
                    <th className="numeric">Settled</th>
                    <th className="numeric">Outstanding</th>
                  </tr>
                </thead>
                <tbody>
                  {dueRows.map((r, i) => (
                    <tr key={`${r.kind}-${r.ref}-${i}`}>
                      <td>
                        <span className="status-badge">{bucketOf(r.days)}</span>
                      </td>
                      <td>{r.kind}</td>
                      <td>
                        <strong className="mono">{r.ref}</strong>
                      </td>
                      <td>{r.contact}</td>
                      <td>{r.date}</td>
                      <td className="numeric">{money(r.total)}</td>
                      <td className="numeric">{money(r.settled)}</td>
                      <td className="numeric">
                        <strong>{money(r.outstanding)}</strong>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!dueRows.length && (
              <div className="empty-state">
                <div className="empty-icon">✓</div>
                <div>
                  <h2>No aging balances</h2>
                  <p>All confirmed documents are fully settled.</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}

      {currentTab === "cashflow" && (
        <>
          <section className="summary-grid">
            <div className="summary-card">
              <span>Total In (Confirmed)</span>
              <strong style={{ color: "var(--success)" }}>{money(cashIn)}</strong>
            </div>
            <div className="summary-card">
              <span>Total Out (Confirmed)</span>
              <strong style={{ color: "var(--primary-dark)" }}>{money(cashOut)}</strong>
            </div>
            <div className="summary-card">
              <span>Net Flow</span>
              <strong>{money(cashIn - cashOut)}</strong>
            </div>
            <div className="summary-card">
              <span>Months Covered</span>
              <strong>{cashMonths.length}</strong>
            </div>
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{cashMonths.length} month(s)</strong>
              <span>
                {cashMethodSplit
                  ? `Method split — ${cashMethodSplit}`
                  : "No confirmed payments yet"}
              </span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Month</th>
                    <th className="numeric">Payments</th>
                    <th className="numeric">In</th>
                    <th className="numeric">Out</th>
                    <th className="numeric">Net</th>
                  </tr>
                </thead>
                <tbody>
                  {cashMonths.map((m) => (
                    <tr key={m.month}>
                      <td>
                        <strong className="mono">{m.month}</strong>
                      </td>
                      <td className="numeric">{m.count}</td>
                      <td className="numeric">{money(m.inflow)}</td>
                      <td className="numeric">{money(m.outflow)}</td>
                      <td className="numeric">
                        <strong>{money(m.inflow - m.outflow)}</strong>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!cashMonths.length && (
              <div className="empty-state">
                <div className="empty-icon">∅</div>
                <div>
                  <h2>No confirmed payments</h2>
                  <p>Cash flow appears once payments are confirmed.</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}

      {currentTab === "profit" && (
        <>
          <section className="summary-grid">
            <div className="summary-card">
              <span>Revenue (latest 50 sales)</span>
              <strong style={{ color: "var(--success)" }}>{money(profitRevenue)}</strong>
            </div>
            <div className="summary-card">
              <span>Cost of Goods Sold</span>
              <strong style={{ color: "var(--primary-dark)" }}>{money(profitCost)}</strong>
            </div>
            <div className="summary-card">
              <span>Gross Profit</span>
              <strong>{money(profitRevenue - profitCost)}</strong>
            </div>
            <div className="summary-card">
              <span>Margin %</span>
              <strong>{profitMarginPct.toFixed(2)}%</strong>
            </div>
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{profitProducts.length} product(s)</strong>
              <span>Revenue from sale lines minus Out-Sale movement cost (purchase price fallback)</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Product</th>
                    <th className="numeric">Qty Sold</th>
                    <th className="numeric">Revenue</th>
                    <th className="numeric">Cost</th>
                    <th className="numeric">Profit</th>
                    <th className="numeric">Margin %</th>
                  </tr>
                </thead>
                <tbody>
                  {profitProducts.map((p) => (
                    <tr key={p.productId}>
                      <td>
                        <strong>{p.name}</strong>
                      </td>
                      <td className="numeric">{p.qty}</td>
                      <td className="numeric">{money(p.revenue)}</td>
                      <td className="numeric">{money(p.cost)}</td>
                      <td className="numeric">
                        <strong>{money(p.profit)}</strong>
                      </td>
                      <td className="numeric">{p.marginPct.toFixed(2)}%</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!profitProducts.length && (
              <div className="empty-state">
                <div className="empty-icon">∅</div>
                <div>
                  <h2>No profit data</h2>
                  <p>Confirm sales to see per-product gross profit.</p>
                </div>
              </div>
            )}
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{profitInvoices.length} invoice(s)</strong>
              <span>Per-invoice margin for the latest 50 confirmed sales</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Invoice</th>
                    <th>Date</th>
                    <th>Customer</th>
                    <th className="numeric">Revenue</th>
                    <th className="numeric">Cost</th>
                    <th className="numeric">Margin</th>
                    <th className="numeric">Margin %</th>
                  </tr>
                </thead>
                <tbody>
                  {profitInvoices.map((inv) => (
                    <tr key={inv.invoiceNo}>
                      <td>
                        <strong className="mono">#{inv.invoiceNo}</strong>
                      </td>
                      <td>{inv.date}</td>
                      <td>{inv.contact}</td>
                      <td className="numeric">{money(inv.revenue)}</td>
                      <td className="numeric">{money(inv.cost)}</td>
                      <td className="numeric">
                        <strong>{money(inv.margin)}</strong>
                      </td>
                      <td className="numeric">{inv.marginPct.toFixed(2)}%</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!profitInvoices.length && (
              <div className="empty-state">
                <div className="empty-icon">∅</div>
                <div>
                  <h2>No confirmed sales</h2>
                  <p>Per-invoice margin appears once sales are confirmed.</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}

      {currentTab === "valuation" && (
        <>
          <section className="summary-grid">
            <div className="summary-card">
              <span>Total Stock Value</span>
              <strong style={{ color: "var(--success)" }}>{money(valuationTotal)}</strong>
            </div>
            <div className="summary-card">
              <span>Products Valued</span>
              <strong>{valuationRows.length}</strong>
            </div>
            <div className="summary-card">
              <span>Using Retail Fallback</span>
              <strong>{valuationFallbackCount}</strong>
            </div>
            <div className="summary-card">
              <span>In Stock (qty &gt; 0)</span>
              <strong>{valuationRows.filter((r) => r.qty > 0).length}</strong>
            </div>
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{valuationRows.length} product(s)</strong>
              <span>Stock quantity × latest In-Purchase unit cost (retail price fallback)</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Product</th>
                    <th className="numeric">Qty on Hand</th>
                    <th className="numeric">Unit Cost</th>
                    <th>Cost Source</th>
                    <th className="numeric">Value</th>
                  </tr>
                </thead>
                <tbody>
                  {valuationRows.map((r) => (
                    <tr key={r.productId}>
                      <td>
                        <strong>{r.name}</strong>
                      </td>
                      <td className="numeric">{r.qty}</td>
                      <td className="numeric">{money(r.unitCost)}</td>
                      <td>
                        <span className="status-badge">{r.source}</span>
                      </td>
                      <td className="numeric">
                        <strong>{money(r.value)}</strong>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!valuationRows.length && (
              <div className="empty-state">
                <div className="empty-icon">∅</div>
                <div>
                  <h2>No products</h2>
                  <p>Add products and receive stock to see valuation.</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}

      {currentTab === "tax" && (
        <>
          <section className="summary-grid">
            <div className="summary-card">
              <span>Sales Tax (Confirmed)</span>
              <strong style={{ color: "var(--success)" }}>{money(taxSalesTotal)}</strong>
            </div>
            <div className="summary-card">
              <span>Purchase Tax (Confirmed)</span>
              <strong style={{ color: "var(--primary-dark)" }}>{money(taxPurchaseTotal)}</strong>
            </div>
            <div className="summary-card">
              <span>Total Discounts</span>
              <strong>{money(taxDiscountTotal)}</strong>
            </div>
            <div className="summary-card">
              <span>Months Covered</span>
              <strong>{taxMonths.length}</strong>
            </div>
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{taxMonths.length} month(s)</strong>
              <span>Tax and discount totals from confirmed sales and purchase headers</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Month</th>
                    <th className="numeric">Sales Tax</th>
                    <th className="numeric">Purchase Tax</th>
                    <th className="numeric">Sales Discount</th>
                    <th className="numeric">Purchase Discount</th>
                    <th className="numeric">Combined Tax</th>
                  </tr>
                </thead>
                <tbody>
                  {taxMonths.map((m) => (
                    <tr key={m.month}>
                      <td>
                        <strong className="mono">{m.month}</strong>
                      </td>
                      <td className="numeric">{money(m.salesTax)}</td>
                      <td className="numeric">{money(m.purchaseTax)}</td>
                      <td className="numeric">{money(m.salesDiscount)}</td>
                      <td className="numeric">{money(m.purchaseDiscount)}</td>
                      <td className="numeric">
                        <strong>{money(m.salesTax + m.purchaseTax)}</strong>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!taxMonths.length && (
              <div className="empty-state">
                <div className="empty-icon">∅</div>
                <div>
                  <h2>No tax data</h2>
                  <p>Confirm sales or purchases to see monthly tax totals.</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}

      {currentTab === "top" && (
        <>
          <section className="summary-grid">
            <div className="summary-card">
              <span>Top Customer</span>
              <strong>{topCustomerName}</strong>
              <span>{money(topCustomerTotal)}</span>
            </div>
            <div className="summary-card">
              <span>Top Supplier</span>
              <strong>{topSupplierName}</strong>
              <span>{money(topSupplierTotal)}</span>
            </div>
            <div className="summary-card">
              <span>Customers Ranked</span>
              <strong>{topRows.filter((r) => r.kind === "Customer").length}</strong>
            </div>
            <div className="summary-card">
              <span>Suppliers Ranked</span>
              <strong>{topRows.filter((r) => r.kind === "Supplier").length}</strong>
            </div>
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{topRows.length} ranked contact(s)</strong>
              <span>Top 10 customers by confirmed sales and top 10 suppliers by confirmed purchases</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th className="numeric">Rank</th>
                    <th>Type</th>
                    <th>Contact</th>
                    <th className="numeric">Documents</th>
                    <th className="numeric">Total</th>
                  </tr>
                </thead>
                <tbody>
                  {topRows.map((r, i) => (
                    <tr key={`${r.kind}-${i}`}>
                      <td className="numeric">{r.rank}</td>
                      <td>
                        <span className="status-badge">{r.kind}</span>
                      </td>
                      <td>
                        <strong>{r.name}</strong>
                      </td>
                      <td className="numeric">{r.docs}</td>
                      <td className="numeric">
                        <strong>{money(r.total)}</strong>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!topRows.length && (
              <div className="empty-state">
                <div className="empty-icon">∅</div>
                <div>
                  <h2>No ranked contacts</h2>
                  <p>Confirm sales or purchases to rank customers and suppliers.</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}

      {currentTab === "expenses" && (
        <>
          <section className="summary-grid">
            <div className="summary-card">
              <span>Total Expenses (Confirmed)</span>
              <strong style={{ color: "var(--danger)" }}>{money(expenseGrandTotal)}</strong>
            </div>
            <div className="summary-card">
              <span>Categories</span>
              <strong>{expenseCategoryCount}</strong>
            </div>
            <div className="summary-card">
              <span>Top Category</span>
              <strong>{expenseTopCategory}</strong>
            </div>
            <div className="summary-card">
              <span>Category-Month Rows</span>
              <strong>{expenseRows.length}</strong>
            </div>
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{expenseRows.length} row(s)</strong>
              <span>Confirmed expense totals by category by month</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Category</th>
                    <th>Month</th>
                    <th className="numeric">Entries</th>
                    <th className="numeric">Total</th>
                  </tr>
                </thead>
                <tbody>
                  {expenseRows.map((r, i) => (
                    <tr key={`${r.category}-${r.month}-${i}`}>
                      <td>
                        <strong>{r.category}</strong>
                      </td>
                      <td>
                        <span className="mono">{r.month}</span>
                      </td>
                      <td className="numeric">{r.entries}</td>
                      <td className="numeric">
                        <strong>{money(r.total)}</strong>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!expenseRows.length && (
              <div className="empty-state">
                <div className="empty-icon">∅</div>
                <div>
                  <h2>No confirmed expenses</h2>
                  <p>Confirm expenses to see category totals by month.</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}

      {currentTab === "velocity" && (
        <>
          <section className="summary-grid">
            <div className="summary-card">
              <span>Fast Movers</span>
              <strong style={{ color: "var(--success)" }}>{velocityFast}</strong>
            </div>
            <div className="summary-card">
              <span>Slow Movers (no Out in 90d)</span>
              <strong>{velocitySlow}</strong>
            </div>
            <div className="summary-card">
              <span>Total In (90d)</span>
              <strong>{velocityInTotal}</strong>
            </div>
            <div className="summary-card">
              <span>Total Out (90d)</span>
              <strong>{velocityOutTotal}</strong>
            </div>
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{velocityRows.length} product(s)</strong>
              <span>Movement quantities over the last 90 days plus current stock</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Product</th>
                    <th className="numeric">In (90d)</th>
                    <th className="numeric">Out (90d)</th>
                    <th className="numeric">Stock on Hand</th>
                    <th>Movement</th>
                  </tr>
                </thead>
                <tbody>
                  {velocityRows.map((r) => (
                    <tr key={r.productId}>
                      <td>
                        <strong>{r.name}</strong>
                      </td>
                      <td className="numeric">{r.inQty}</td>
                      <td className="numeric">{r.outQty}</td>
                      <td className="numeric">
                        <strong>{r.stock}</strong>
                      </td>
                      <td>
                        <span className="status-badge">{r.flag}</span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!velocityRows.length && (
              <div className="empty-state">
                <div className="empty-icon">∅</div>
                <div>
                  <h2>No products</h2>
                  <p>Add products to track movement velocity.</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}

      {currentTab === "audit" && (
        <>
          <section className="summary-grid">
            <div className="summary-card">
              <span>Ledger Transactions</span>
              <strong>{auditTxns.length}</strong>
            </div>
            <div className="summary-card">
              <span>Total Debit</span>
              <strong>{money(auditDebitTotal)}</strong>
            </div>
            <div className="summary-card">
              <span>Total Credit</span>
              <strong>{money(auditCreditTotal)}</strong>
            </div>
            <div className="summary-card">
              <span>Inventory Movements</span>
              <strong>{auditMoves.length}</strong>
            </div>
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{auditTxns.length} transaction(s)</strong>
              <span>Latest 100 account_transactions with actor, date, and description</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Date</th>
                    <th>Type</th>
                    <th>Description</th>
                    <th>Reference</th>
                    <th>Contact</th>
                    <th className="numeric">Debit</th>
                    <th className="numeric">Credit</th>
                    <th>Actor</th>
                  </tr>
                </thead>
                <tbody>
                  {auditTxns.map((t) => (
                    <tr key={t.id}>
                      <td style={{ fontSize: "11px" }}>
                        {new Date(t.transaction_date).toLocaleString("en-BD")}
                      </td>
                      <td>
                        <span className="status-badge">{t.transaction_type}</span>
                      </td>
                      <td>{t.description}</td>
                      <td>
                        {t.reference_type && t.reference_id ? (
                          <span className="mono" style={{ fontSize: "11px" }}>
                            {t.reference_type} #{String(t.reference_id).slice(0, 8)}
                          </span>
                        ) : (
                          "—"
                        )}
                      </td>
                      <td>{joinedName(t.contacts)}</td>
                      <td className="numeric">
                        {num(t.debit) > 0 ? money(t.debit) : "—"}
                      </td>
                      <td className="numeric">
                        {num(t.credit) > 0 ? money(t.credit) : "—"}
                      </td>
                      <td>{auditActor(t.created_by)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!auditTxns.length && (
              <div className="empty-state">
                <div className="empty-icon">∅</div>
                <div>
                  <h2>No ledger entries</h2>
                  <p>Transactions appear when documents are confirmed or cancelled.</p>
                </div>
              </div>
            )}
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{auditMoves.length} movement(s)</strong>
              <span>Latest 100 inventory_movements with actor, date, and description</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Date</th>
                    <th>Product</th>
                    <th>Direction</th>
                    <th>Type</th>
                    <th className="numeric">Qty</th>
                    <th className="numeric">Unit Cost</th>
                    <th>Reference</th>
                    <th>Actor</th>
                  </tr>
                </thead>
                <tbody>
                  {auditMoves.map((m) => (
                    <tr key={m.id}>
                      <td style={{ fontSize: "11px" }}>
                        {new Date(m.movement_date).toLocaleString("en-BD")}
                      </td>
                      <td>
                        <strong>{joinedProductName(m.products)}</strong>
                      </td>
                      <td>
                        <span className="status-badge">{m.movement_direction}</span>
                      </td>
                      <td>{m.movement_type}</td>
                      <td className="numeric">{num(m.quantity)}</td>
                      <td className="numeric">
                        {m.unit_cost === null || m.unit_cost === undefined
                          ? "—"
                          : money(m.unit_cost)}
                      </td>
                      <td>
                        {m.reference_type && m.reference_id ? (
                          <span className="mono" style={{ fontSize: "11px" }}>
                            {m.reference_type} #{String(m.reference_id).slice(0, 8)}
                          </span>
                        ) : (
                          "—"
                        )}
                      </td>
                      <td>{auditActor(m.created_by)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!auditMoves.length && (
              <div className="empty-state">
                <div className="empty-icon">∅</div>
                <div>
                  <h2>No movements</h2>
                  <p>Movements appear when purchases, sales, or adjustments post stock.</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}

      {currentTab === "efficiency" && (
        <>
          <section className="summary-grid">
            <div className="summary-card">
              <span>Total Billed (Confirmed)</span>
              <strong>{money(effBilled)}</strong>
            </div>
            <div className="summary-card">
              <span>Total Received</span>
              <strong style={{ color: "var(--success)" }}>{money(effReceived)}</strong>
            </div>
            <div className="summary-card">
              <span>Overall Collected</span>
              <strong>{effOverallPct.toFixed(2)}%</strong>
            </div>
            <div className="summary-card">
              <span>Months Covered</span>
              <strong>{effMonths.length}</strong>
            </div>
          </section>
          <section className="table-card">
            <div className="table-meta">
              <strong>{effMonths.length} month(s)</strong>
              <span>Per-month sales billed vs Confirmed-payment receipts attributed to invoice month</span>
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Month</th>
                    <th className="numeric">Billed</th>
                    <th className="numeric">Received</th>
                    <th className="numeric">Outstanding</th>
                    <th className="numeric">Collected %</th>
                  </tr>
                </thead>
                <tbody>
                  {effMonths.map((m) => (
                    <tr key={m.month}>
                      <td>
                        <strong className="mono">{m.month}</strong>
                      </td>
                      <td className="numeric">{money(m.billed)}</td>
                      <td className="numeric">{money(m.received)}</td>
                      <td className="numeric">
                        <strong>{money(m.outstanding)}</strong>
                      </td>
                      <td className="numeric">{m.pct.toFixed(2)}%</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            {!effMonths.length && (
              <div className="empty-state">
                <div className="empty-icon">∅</div>
                <div>
                  <h2>No confirmed sales</h2>
                  <p>Collection efficiency appears once sales are confirmed.</p>
                </div>
              </div>
            )}
          </section>
        </>
      )}
    </WorkspaceShell>
  );
}
