import { callRpc, type Db } from "./common";

export type PaymentAllocationInput = {
  sale_id?: string;
  purchase_id?: string;
  expense_id?: string;
  allocated_amount: number;
};

// Atomic model: allocations travel WITH the confirmation call and are
// validated + written inside the same PostgreSQL transaction
// (confirm_payment(uuid, jsonb)). Payment In -> Sales only;
// Payment Out -> Purchases/Expenses only; allocations must equal the full
// payment amount and must not exceed any target's outstanding balance.

// Serialized numbering (see 20260927100000_payment_expense_numbering.sql).
// Never compute payment numbers client-side via count-then-insert: concurrent
// creates would collide on the unique constraint.
export async function nextPaymentNo(db: Db, organizationId: string): Promise<string> {
  const data = await callRpc<string>(
    db,
    "next_payment_no",
    { p_organization_id: organizationId },
    "Unable to generate payment number.",
  );
  return data;
}

export async function confirmPayment(db: Db, paymentId: string, allocations: PaymentAllocationInput[]): Promise<string> {
  const data = await callRpc<string>(
    db,
    "confirm_payment",
    { p_payment_id: paymentId, p_allocations: allocations },
    "Unable to confirm payment.",
  );
  return data ?? paymentId;
}

export async function cancelPayment(db: Db, paymentId: string): Promise<string> {
  const data = await callRpc<string>(db, "cancel_payment", { p_payment_id: paymentId }, "Unable to cancel payment.");
  return data ?? paymentId;
}
