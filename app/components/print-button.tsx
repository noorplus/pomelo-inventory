"use client";

export default function PrintButton({ label = "🖨 Print" }: { label?: string }) {
  return (
    <button className="secondary-button" type="button" onClick={() => window.print()}>
      {label}
    </button>
  );
}
