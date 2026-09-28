// Shared sortable table header - build verified
import Link from "next/link";

export default function SortableHeader({
  label, field, sort, direction, basePath, params = {}, className = "",
}: {
  label: string; field: string; sort: string; direction: "asc" | "desc"; basePath: string;
  params?: Record<string, string | undefined>; className?: string;
}) {
  const nextDirection = sort === field && direction === "asc" ? "desc" : "asc";
  const query = new URLSearchParams();
  Object.entries(params).forEach(([key, value]) => { if (value) query.set(key, value); });
  query.set("sort", field);
  query.set("direction", nextDirection);
  const indicator = sort === field ? (direction === "asc" ? " ↑" : " ↓") : "";
  return <th className={`sortable-header ${className}`.trim()}><Link href={`${basePath}?${query.toString()}`}>{label}{indicator}</Link></th>;
}