import Link from "next/link";
import { PAGE_SIZE, pageSummary } from "@/lib/pagination";

type PagerProps = {
  basePath: string;
  params: Record<string, string | undefined>;
  page: number;
  shown: number;
  total: number | null;
  pageSize?: number;
};

// Server-rendered Prev/Next pager that preserves all current filters/sorts.
export default function Pager({ basePath, params, page, shown, total, pageSize = PAGE_SIZE }: PagerProps) {
  const totalPages = total === null ? null : Math.max(1, Math.ceil(total / pageSize));

  function href(target: number): string {
    const query = new URLSearchParams();
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined && value !== "") query.set(key, value);
    }
    if (target > 1) query.set("page", String(target));
    const suffix = query.toString();
    return suffix ? `${basePath}?${suffix}` : basePath;
  }

  const hasPrev = page > 1;
  const hasNext = totalPages === null ? shown >= pageSize : page < totalPages;

  return (
    <nav className="pager" aria-label="Pagination">
      <span className="pager-summary">{pageSummary(page, shown, total, pageSize)}</span>
      <span className="pager-controls">
        {hasPrev ? (
          <Link className="secondary-button pager-button" href={href(page - 1)}>
            ← Prev
          </Link>
        ) : (
          <span className="secondary-button pager-button pager-disabled" aria-disabled="true">
            ← Prev
          </span>
        )}
        {hasNext ? (
          <Link className="secondary-button pager-button" href={href(page + 1)}>
            Next →
          </Link>
        ) : (
          <span className="secondary-button pager-button pager-disabled" aria-disabled="true">
            Next →
          </span>
        )}
      </span>
    </nav>
  );
}
