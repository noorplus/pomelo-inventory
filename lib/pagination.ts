// Shared server-side pagination helpers for list pages.
// Every large list must use .range() + exact count instead of pulling full
// tables into memory; the Pager component renders Prev/Next controls.

export const PAGE_SIZE = 25;

export function parsePageParam(value: unknown): number {
  const page = Number(Array.isArray(value) ? value[0] : value);
  if (!Number.isFinite(page) || page < 1) return 1;
  return Math.floor(page);
}

export function pageRange(page: number, size: number = PAGE_SIZE): { from: number; to: number } {
  const from = (page - 1) * size;
  return { from, to: from + size - 1 };
}

export function pageSummary(page: number, shown: number, total: number | null, size: number = PAGE_SIZE): string {
  if (total === null || total === 0) return shown === 1 ? "1 record" : `${shown} records`;
  const from = (page - 1) * size + 1;
  const to = Math.min(page * size, total);
  return `Showing ${from}–${to} of ${total}`;
}
