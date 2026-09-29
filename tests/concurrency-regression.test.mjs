import assert from "node:assert/strict";
import test from "node:test";

class AtomicDocument {
  constructor() {
    this.status = "Draft";
    this.confirmations = 0;
    this.ledgerEntries = 0;
  }

  async confirm() {
    // Model the database row lock/atomic status transition. Only one
    // transaction can observe Draft and commit the transition to Confirmed.
    if (this.status !== "Draft") {
      throw new Error("Document is not in Draft status");
    }
    await new Promise(resolve => setImmediate(resolve));
    if (this.status !== "Draft") {
      throw new Error("Document was confirmed concurrently");
    }
    this.status = "Confirmed";
    this.confirmations += 1;
    this.ledgerEntries += 2;
    return "confirmed";
  }
}

test("parallel confirmation permits exactly one successful confirmation", async () => {
  const document = new AtomicDocument();
  const results = await Promise.allSettled([document.confirm(), document.confirm()]);
  assert.equal(results.filter(r => r.status === "fulfilled").length, 1);
  assert.equal(results.filter(r => r.status === "rejected").length, 1);
  assert.equal(document.status, "Confirmed");
  assert.equal(document.confirmations, 1);
  assert.equal(document.ledgerEntries, 2);
});

test("repeated confirmation remains idempotent at the state boundary", async () => {
  const document = new AtomicDocument();
  await document.confirm();
  await assert.rejects(() => document.confirm(), /not in Draft status|confirmed concurrently/);
  assert.equal(document.confirmations, 1);
  assert.equal(document.ledgerEntries, 2);
});

test("parallel payment allocation model never exceeds outstanding", async () => {
  let outstanding = 1000;
  const requests = [700, 700];

  const results = await Promise.allSettled(requests.map(async amount => {
    await new Promise(resolve => setImmediate(resolve));
    if (amount > outstanding) throw new Error("Payment exceeds outstanding");
    outstanding -= amount;
    return amount;
  }));

  // This test intentionally models a lock boundary. A real DB implementation
  // must lock the target document before reading paid/outstanding and applying
  // the allocation. Without that lock both requests could observe 1000.
  const successful = results.filter(r => r.status === "fulfilled");
  assert.equal(successful.length, 1);
  assert.equal(outstanding, 300);
});
