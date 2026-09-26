"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";

type Props = {
  exportUrl: string;
  importUrl: string;
};

export default function CsvActions({ exportUrl, importUrl }: Props) {
  const inputRef = useRef<HTMLInputElement>(null);
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");

  async function importCsv(file: File) {
    setBusy(true);
    setMessage("");

    try {
      const formData = new FormData();
      formData.append("file", file);

      const response = await fetch(importUrl, { method: "POST", body: formData });
      const result = await response.json();

      if (!response.ok) {
        setMessage(result.error || "Unable to import CSV.");
        return;
      }

      const summary = `Imported ${result.imported} row${result.imported === 1 ? "" : "s"}.${result.skipped ? ` Skipped ${result.skipped}.` : ""}`;
      const details = result.errors?.length ? ` First errors: ${result.errors.slice(0, 3).join(" | ")}` : "";
      setMessage(summary + details);
      router.refresh();
    } catch {
      setMessage("Unable to import CSV. Please check the file and try again.");
    } finally {
      setBusy(false);
      if (inputRef.current) inputRef.current.value = "";
    }
  }

  return (
    <div className="csv-actions">
      <input
        ref={inputRef}
        className="csv-file-input"
        type="file"
        accept=".csv,text/csv"
        onChange={(event) => {
          const file = event.target.files?.[0];
          if (file) void importCsv(file);
        }}
      />
      <button className="secondary-button csv-button" type="button" onClick={() => inputRef.current?.click()} disabled={busy}>
        {busy ? "Importing…" : "Import CSV"}
      </button>
      <a className="secondary-button csv-button" href={exportUrl}>
        Export CSV
      </a>
      {message && <span className="csv-result" role="status">{message}</span>}
    </div>
  );
}
