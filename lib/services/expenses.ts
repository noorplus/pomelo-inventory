import { callRpc, type Db } from "./common";

// Serialized numbering (see 20260927100000_payment_expense_numbering.sql).
export async function nextExpenseNo(db: Db, organizationId: string): Promise<string> {
  const data = await callRpc<string>(
    db,
    "next_expense_no",
    { p_organization_id: organizationId },
    "Unable to generate expense number.",
  );
  return data;
}

export async function confirmExpense(db: Db, expenseId: string): Promise<string> {
  const data = await callRpc<string>(db, "confirm_expense", { p_expense_id: expenseId }, "Unable to confirm expense.");
  return data ?? expenseId;
}

export async function cancelExpense(db: Db, expenseId: string): Promise<string> {
  const data = await callRpc<string>(db, "cancel_expense", { p_expense_id: expenseId }, "Unable to cancel expense.");
  return data ?? expenseId;
}

export async function getExpenseOutstanding(db: Db, expenseId: string): Promise<number> {
  const data = await callRpc<number | string>(
    db,
    "expense_outstanding",
    { p_expense_id: expenseId },
    "Unable to load expense outstanding balance.",
  );
  return Number(data);
}
