"use client";

import { useEffect } from "react";

export default function GlobalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <main className="auth-shell">
      <section className="auth-card">
        <div className="auth-brand">Pomelo Inventory</div>
        <h1>Something went wrong</h1>
        <p className="muted">The application could not complete this request.</p>
        <button className="primary-button" onClick={() => reset()}>Try again</button>
      </section>
    </main>
  );
}
