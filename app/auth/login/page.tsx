"use client";

import { FormEvent, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function LoginPage() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const supabase = createClient();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState(() => {
    const code = searchParams.get("error");
    return code === "confirmation_failed" ? "Email confirmation failed. Please request a new confirmation email." :
      code === "missing_code" ? "The confirmation link is incomplete." : "";
  });
  const [loading, setLoading] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError("");
    setLoading(true);
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (error) {
      setError(error.message);
      setLoading(false);
      return;
    }
    router.replace("/");
    router.refresh();
  }

  return (
    <main className="auth-shell">
      <section className="auth-card">
        <div className="auth-brand">Pomelo Inventory</div>
        <h1>Sign in</h1>
        <p className="muted">Access your inventory workspace.</p>
        <form onSubmit={submit} className="form">
          <label>Email<input type="email" required autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} /></label>
          <label>Password<input type="password" required autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} /></label>
          {error && <div className="form-error" role="alert">{error}</div>}
          <button className="primary-button" disabled={loading}>{loading ? "Signing in..." : "Sign in"}</button>
        </form>
        <p className="auth-link">New here? <a href="/auth/signup">Create an account</a></p>
      </section>
    </main>
  );
}
