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

function allocateOverallDiscount(lines, overallDiscount) {
  const netTotal = lines.reduce((sum, line) => sum + line.lineTotal, 0);
  if (overallDiscount < 0) throw new Error("Overall discount cannot be negative");
  if (overallDiscount > netTotal) throw new Error("Overall discount cannot exceed net purchase value");

  let allocated = 0;
  return lines.map((line, index) => {
    const isLast = index === lines.length - 1;
    const allocation = isLast
      ? Number((overallDiscount - allocated).toFixed(4))
      : Number((overallDiscount * line.lineTotal / netTotal).toFixed(4));
    allocated = Number((allocated + allocation).toFixed(4));
    const effectiveUnitCost = Number(((line.lineTotal - allocation) / line.quantity).toFixed(4));
    return { ...line, allocatedOverallDiscount: allocation, effectiveUnitCost };
  });
}

const purchaseLines = [
  { quantity: 11, lineTotal: 22094 },
  { quantity: 51, lineTotal: 104307 },
  { quantity: 21, lineTotal: 42539 },
];
const allocated = allocateOverallDiscount(purchaseLines, 1000);
assert.equal(allocated.reduce((sum, line) => sum + line.allocatedOverallDiscount, 0), 1000);
assert.equal(
  Number(allocated.reduce((sum, line) => sum + line.effectiveUnitCost * line.quantity, 0).toFixed(4)),
  167940,
);
assert.equal(
  allocated[0].effectiveUnitCost,
  1996.6563,
);

const singleItem = allocateOverallDiscount([{ quantity: 1, lineTotal: 2000 }], 550);
assert.equal(singleItem[0].effectiveUnitCost, 1450);

console.log("Overall discount allocation regression tests passed.");
