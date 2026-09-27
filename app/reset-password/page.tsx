"use client";

import { FormEvent, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";

export default function ResetPasswordPage() {
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMessage("");
    setError("");
    if (password.length < 8) {
      setError("Password must be at least 8 characters.");
      return;
    }
    if (password !== confirmPassword) {
      setError("Passwords do not match.");
      return;
    }
    setLoading(true);
    const supabase = createClient();
    const { error } = await supabase.auth.updateUser({ password });
    if (error) {
      setError("Unable to update the password. Please request a new reset link.");
    } else {
      setMessage("Your password has been updated. You can continue to your workspace.");
      setPassword("");
      setConfirmPassword("");
    }
    setLoading(false);
  }

  return (
    <main className="auth-shell">
      <section className="auth-card">
        <div className="auth-brand"><span className="brand-mark">P</span><span>Pomelo Inventory</span></div>
        <p className="eyebrow">ACCOUNT RECOVERY</p>
        <h1>Choose a new password</h1>
        <p className="muted">Use at least 8 characters and keep the password unique to this account.</p>
        <form onSubmit={submit} className="form">
          <label>New password<input type="password" required minLength={8} autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} /></label>
          <label>Confirm password<input type="password" required minLength={8} autoComplete="new-password" value={confirmPassword} onChange={(e) => setConfirmPassword(e.target.value)} /></label>
          {error && <div className="form-error" role="alert">{error}</div>}
          {message && <div className="form-success" role="status">{message}</div>}
          <button className="primary-button" disabled={loading}>{loading ? "Updating…" : "Update password"}</button>
        </form>
        <p className="auth-link"><Link href="/">Continue to workspace</Link></p>
      </section>
    </main>
  );
}
