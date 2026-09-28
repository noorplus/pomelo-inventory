import type { ReactNode } from "react";

type DataTableProps = {
  children: ReactNode;
  className?: string;
};

export default function DataTable({ children, className = "" }: DataTableProps) {
  return <table className={`spreadsheet-table${className ? ` ${className}` : ""}`}>{children}</table>;
}
