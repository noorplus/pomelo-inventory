import { callRpc, type Db } from "./common";

export async function confirmSale(db: Db, saleId: string): Promise<string> {
  const data = await callRpc<string>(db, "confirm_sale", { p_sale_id: saleId }, "Unable to confirm sale.");
  return data ?? saleId;
}

export async function cancelSale(db: Db, saleId: string): Promise<string> {
  const data = await callRpc<string>(db, "cancel_sale", { p_sale_id: saleId }, "Unable to cancel sale.");
  return data ?? saleId;
}

export async function getSaleOutstanding(db: Db, saleId: string): Promise<number> {
  const data = await callRpc<number | string>(
    db,
    "sale_outstanding",
    { p_sale_id: saleId },
    "Unable to load sale outstanding balance.",
  );
  return Number(data);
}
