import assert from "node:assert/strict";
import test from "node:test";

function documentTotal(lines, overallDiscount = 0) {
  const gross = lines.reduce((sum, l) => sum + l.quantity * l.unitPrice, 0);
  const lineDiscount = lines.reduce((sum, l) => sum + l.discount, 0);
  const net = gross - lineDiscount;
  if (overallDiscount < 0) throw new Error("Overall discount cannot be negative");
  if (overallDiscount > net) throw new Error("Overall discount cannot exceed net subtotal");
  return net - overallDiscount;
}

function allocateOverallDiscount(lines, overallDiscount) {
  const netTotal = lines.reduce((sum, l) => sum + l.lineTotal, 0);
  if (overallDiscount < 0 || overallDiscount > netTotal) throw new Error("Invalid overall discount");
  let allocated = 0;
  return lines.map((line, index) => {
    const allocation = index === lines.length - 1
      ? Number((overallDiscount - allocated).toFixed(4))
      : Number((overallDiscount * line.lineTotal / netTotal).toFixed(4));
    allocated = Number((allocated + allocation).toFixed(4));
    return { ...line, allocatedOverallDiscount: allocation };
  });
}

function wacIn(state, quantity, unitCost) {
  assert(quantity > 0);
  assert(unitCost >= 0);
  const nextQty = state.quantity + quantity;
  const nextValue = state.inventoryValue + quantity * unitCost;
  return {
    quantity: nextQty,
    averageCost: nextQty === 0 ? 0 : nextValue / nextQty,
    inventoryValue: nextValue,
  };
}

function wacOut(state, quantity) {
  assert(quantity > 0);
  assert(quantity <= state.quantity);
  const cost = quantity * state.averageCost;
  const nextQty = state.quantity - quantity;
  return {
    quantity: nextQty,
    averageCost: nextQty === 0 ? 0 : state.averageCost,
    inventoryValue: state.inventoryValue - cost,
    issuedCost: cost,
  };
}

function balanced(entries) {
  const debit = entries.filter(e => e.side === "debit").reduce((s, e) => s + e.amount, 0);
  const credit = entries.filter(e => e.side === "credit").reduce((s, e) => s + e.amount, 0);
  return Number((debit - credit).toFixed(4)) === 0;
}

function returnTransactionsForOutstanding(entries, kind) {
  const exactType = kind === "sale" ? "Sale Return - Revenue" : "Purchase Return - Payable";
  return entries.filter(e => e.transactionType === exactType).reduce((s, e) => s + e.amount, 0);
}

test("overall discount never changes the document formula unexpectedly", () => {
  const lines = [
    { quantity: 2, unitPrice: 5000, discount: 250 },
    { quantity: 3, unitPrice: 2000, discount: 100 },
  ];
  assert.equal(documentTotal(lines), 15200);
  assert.equal(documentTotal(lines, 750), 14450);
  assert.throws(() => documentTotal(lines, -1), /negative/);
  assert.throws(() => documentTotal(lines, 15201), /exceed/);
});

test("overall discount allocation preserves the exact document discount", () => {
  const lines = [
    { quantity: 11, lineTotal: 22094 },
    { quantity: 51, lineTotal: 104307 },
    { quantity: 21, lineTotal: 42539 },
  ];
  const allocated = allocateOverallDiscount(lines, 1000);
  assert.equal(allocated.reduce((s, l) => s + l.allocatedOverallDiscount, 0), 1000);
  assert.equal(
    Number(allocated.reduce((s, l) => s + l.lineTotal - l.allocatedOverallDiscount, 0).toFixed(4)),
    167940,
  );
});

test("WAC inbound/outbound preserves stock valuation invariant", () => {
  let state = { quantity: 0, averageCost: 0, inventoryValue: 0 };
  state = wacIn(state, 10, 100);
  state = wacIn(state, 5, 160);
  assert.equal(state.quantity, 15);
  assert.equal(Number(state.averageCost.toFixed(4)), 120);
  assert.equal(Number(state.inventoryValue.toFixed(4)), 1800);

  const issued = wacOut(state, 6);
  state = { quantity: issued.quantity, averageCost: issued.averageCost, inventoryValue: issued.inventoryValue };
  assert.equal(Number(issued.issuedCost.toFixed(4)), 720);
  assert.equal(Number(state.inventoryValue.toFixed(4)), 1080);
  assert.equal(Number((state.quantity * state.averageCost - state.inventoryValue).toFixed(4)), 0);
});

test("double-entry references remain balanced", () => {
  assert.equal(balanced([
    { side: "debit", amount: 1000 },
    { side: "credit", amount: 1000 },
  ]), true);
  assert.equal(balanced([
    { side: "debit", amount: 1000 },
    { side: "credit", amount: 900 },
  ]), false);
});

test("outstanding calculations use exact return transaction types", () => {
  const entries = [
    { transactionType: "Sale Return - Revenue", amount: 100 },
    { transactionType: "Sale Return - Inventory", amount: 100 },
    { transactionType: "Sale Return - COGS", amount: 60 },
    { transactionType: "Purchase Return - Payable", amount: 50 },
    { transactionType: "Purchase Return - Inventory", amount: 50 },
    { transactionType: "Purchase Return - Cost Variance", amount: 5 },
  ];
  assert.equal(returnTransactionsForOutstanding(entries, "sale"), 100);
  assert.equal(returnTransactionsForOutstanding(entries, "purchase"), 50);
});

test("stock underflow is rejected", () => {
  const state = { quantity: 3, averageCost: 100, inventoryValue: 300 };
  assert.throws(() => wacOut(state, 4));
});

test("sale COGS and inventory credit must be equal", () => {
  const entries = [
    { side: "debit", amount: 147601.6069, account: "COGS" },
    { side: "credit", amount: 147601.6069, account: "Inventory - COGS" },
  ];
  assert.equal(balanced(entries), true);
});
