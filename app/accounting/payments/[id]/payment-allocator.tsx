"use client";

import { useState } from "react";

type InvoiceCandidate = {
  id: string;
  type: "sale" | "purchase" | "expense";
  number: string;
  date: string;
  total: number;
  paid: number;
  outstanding: number;
};

type Props = {
  paymentId: string;
  paymentType: "In" | "Out";
  paymentAmount: number;
  candidates: InvoiceCandidate[];
  action: (formData: FormData) => Promise<void>;
  initialTargetId?: string;
};

export default function PaymentAllocator({
  paymentId,
  paymentType,
  paymentAmount,
  candidates,
  action,
  initialTargetId,
}: Props) {
  const [allocations, setAllocations] = useState<Record<string, number>>(() => {
    // Initial auto-allocation: a pre-selected target (from a Pay link) is
    // filled first, then any remainder flows to the other candidates.
    const ordered = initialTargetId
      ? [...candidates.filter((c) => c.id === initialTargetId), ...candidates.filter((c) => c.id !== initialTargetId)]
      : candidates;
    let remaining = paymentAmount;
    const initial: Record<string, number> = {};
    for (const c of ordered) {
      if (remaining <= 0) break;
      const alloc = Math.min(remaining, c.outstanding);
      if (alloc > 0) {
        initial[c.id] = alloc;
        remaining -= alloc;
      }
    }
    return initial;
  });

  function autoAllocate() {
    let remaining = paymentAmount;
    const next: Record<string, number> = {};
    for (const c of candidates) {
      if (remaining <= 0) break;
      const alloc = Math.min(remaining, c.outstanding);
      if (alloc > 0) {
        next[c.id] = alloc;
        remaining -= alloc;
      }
    }
    setAllocations(next);
  }

  function clearAllocations() {
    setAllocations({});
  }

  function setAmount(id: string, value: number, max: number) {
    const safeVal = Math.max(0, Math.min(value, max));
    setAllocations((prev) => {
      const copy = { ...prev };
      if (safeVal === 0) {
        delete copy[id];
      } else {
        copy[id] = safeVal;
      }
      return copy;
    });
  }

  const totalAllocated = Object.values(allocations).reduce((sum, v) => sum + (v || 0), 0);
  const diff = Math.round((paymentAmount - totalAllocated) * 100) / 100;
  const isBalanced = Math.abs(diff) < 0.01 && totalAllocated > 0;

  // Format array for confirm_payment RPC
  const payload = Object.entries(allocations)
    .filter(([_, amt]) => amt > 0)
    .map(([targetId, amt]) => {
      const candidate = candidates.find((c) => c.id === targetId);
      if (!candidate) return null;
      if (candidate.type === "sale") {
        return { sale_id: targetId, allocated_amount: amt };
      }
      if (candidate.type === "purchase") {
        return { purchase_id: targetId, allocated_amount: amt };
      }
      return { expense_id: targetId, allocated_amount: amt };
    })
    .filter(Boolean);

  return (
    <div className="allocation-card">
      <div className="allocation-header">
        <div>
          <p className="eyebrow">ALLOCATION MANAGER</p>
          <h2 style={{ margin: 0, fontSize: "16px" }}>
            Allocate Payment to {paymentType === "In" ? "Sales Invoices" : "Purchases & Expenses"}
          </h2>
          <p className="muted" style={{ margin: "4px 0 0", fontSize: "11px" }}>
            Supabase requires confirmed payments to be fully allocated against outstanding documents.
          </p>
        </div>
        <div style={{ display: "flex", gap: "6px" }}>
          <button type="button" className="secondary-button" onClick={autoAllocate}>
            Auto-Allocate
          </button>
          <button type="button" className="secondary-button" onClick={clearAllocations}>
            Clear
          </button>
        </div>
      </div>

      <div
        style={{
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          padding: "10px 14px",
          background: isBalanced ? "#ecfdf5" : "#fffbeb",
          borderRadius: "8px",
          border: isBalanced ? "1px solid #a7f3d0" : "1px solid #fde68a",
        }}
      >
        <div style={{ display: "flex", gap: "16px", fontSize: "12px" }}>
          <div>
            Payment Amount: <strong>৳{paymentAmount.toFixed(2)}</strong>
          </div>
          <div>
            Allocated: <strong style={{ color: isBalanced ? "var(--success)" : "#b45309" }}>৳{totalAllocated.toFixed(2)}</strong>
          </div>
          <div>
            Remaining to Allocate:{" "}
            <strong style={{ color: diff === 0 ? "var(--success)" : "var(--danger)" }}>
              ৳{diff.toFixed(2)}
            </strong>
          </div>
        </div>
        <span className={isBalanced ? "allocated-tag" : "unallocated-tag"}>
          {isBalanced ? "✓ Ready to Confirm" : `Needs ৳${Math.abs(diff).toFixed(2)} ${diff > 0 ? "more" : "less"}`}
        </span>
      </div>

      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              <th>Target Document</th>
              <th>Date</th>
              <th className="numeric">Invoice Total</th>
              <th className="numeric">Outstanding Due</th>
              <th className="numeric" style={{ width: "160px" }}>
                Allocate Amount (৳)
              </th>
              <th style={{ width: "80px" }}>Action</th>
            </tr>
          </thead>
          <tbody>
            {candidates.map((c) => {
              const currentVal = allocations[c.id] || "";
              return (
                <tr key={c.id}>
                  <td>
                    <strong>
                      {c.type === "sale" ? "Sale Invoice" : c.type === "purchase" ? "Purchase Bill" : "Expense"}{" "}
                      #{c.number}
                    </strong>
                  </td>
                  <td>{c.date}</td>
                  <td className="numeric">৳{c.total.toFixed(2)}</td>
                  <td className="numeric">
                    <strong style={{ color: "var(--danger)" }}>৳{c.outstanding.toFixed(2)}</strong>
                  </td>
                  <td className="numeric">
                    <input
                      type="number"
                      step="0.01"
                      min="0"
                      max={c.outstanding}
                      className="compact-number"
                      placeholder="0.00"
                      value={currentVal}
                      onChange={(e) =>
                        setAmount(c.id, parseFloat(e.target.value) || 0, c.outstanding)
                      }
                      style={{ width: "120px" }}
                    />
                  </td>
                  <td>
                    <button
                      type="button"
                      className="secondary-button"
                      style={{ fontSize: "11px", padding: "3px 7px" }}
                      onClick={() => {
                        const needed = Math.max(0, paymentAmount - (totalAllocated - (allocations[c.id] || 0)));
                        setAmount(c.id, Math.min(c.outstanding, needed), c.outstanding);
                      }}
                    >
                      Fill
                    </button>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {!candidates.length && (
        <div style={{ textAlign: "center", padding: "20px", color: "var(--muted)", fontSize: "12px" }}>
          No unpaid confirmed {paymentType === "In" ? "sales invoices" : "purchases or expenses"} found for this contact.
          <p style={{ margin: "4px 0 0" }}>
            Create or confirm {paymentType === "In" ? "a sales invoice" : "a purchase bill"} first to allocate this payment.
          </p>
        </div>
      )}

      <form action={action} style={{ display: "flex", justifyContent: "flex-end", gap: "8px", marginTop: "8px" }}>
        <input type="hidden" name="payment_id" value={paymentId} />
        <input type="hidden" name="allocations_json" value={JSON.stringify(payload)} />
        <button className="primary-button" type="submit" disabled={!isBalanced}>
          Confirm Payment & Post Entries
        </button>
      </form>
    </div>
  );
}
