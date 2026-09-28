import assert from "node:assert/strict";

function calculate(lines, overallDiscount = 0) {
  const grossSubtotal = lines.reduce((sum, line) => sum + line.quantity * line.unitPrice, 0);
  const itemDiscountTotal = lines.reduce((sum, line) => sum + line.discount, 0);
  const netSubtotal = grossSubtotal - itemDiscountTotal;
  if (overallDiscount < 0) throw new Error("Overall discount cannot be negative");
  if (overallDiscount > netSubtotal) throw new Error("Overall discount cannot exceed net subtotal");
  return {
    grossSubtotal,
    itemDiscountTotal,
    netSubtotal,
    overallDiscount,
    total: netSubtotal - overallDiscount,
  };
}

const lines = [
  { quantity: 1, unitPrice: 10000, discount: 500 },
  { quantity: 1, unitPrice: 5000, discount: 200 },
];

assert.deepEqual(calculate(lines), {
  grossSubtotal: 15000,
  itemDiscountTotal: 700,
  netSubtotal: 14300,
  overallDiscount: 0,
  total: 14300,
});

assert.deepEqual(calculate(lines, 300), {
  grossSubtotal: 15000,
  itemDiscountTotal: 700,
  netSubtotal: 14300,
  overallDiscount: 300,
  total: 14000,
});

assert.equal(calculate([{ quantity: 2, unitPrice: 1250, discount: 0 }], 2500).total, 0);
assert.throws(() => calculate(lines, 14301), /cannot exceed/);
assert.throws(() => calculate(lines, -1), /cannot be negative/);

console.log("Discount regression tests passed.");
