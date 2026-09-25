"use client";

import { FormEvent, useState } from "react";
import { createClient } from "@/lib/supabase/client";

export default function SignupPage() {
  const [fullName, setFullName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirmPassword, setConfirmPassword] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError("");
    setMessage("");

    if (password !== confirmPassword) {
      setError("Passwords do not match.");
      return;
    }
    if (password.length < 8) {
      setError("Password must be at least 8 characters.");
      return;
    }

    setLoading(true);
    const origin = window.location.origin;
    const supabase = createClient();
    const { data, error } = await supabase.auth.signUp({
      email: email.trim(),
      password,
      options: {
        data: { full_name: fullName.trim() },
        emailRedirectTo: `${origin}/auth/callback?next=/organization/create`,
      },
    });

    if (error) {
      const message = error.message.toLowerCase().includes("rate limit")
        ? "Email sending is temporarily rate-limited. Please wait and try again later."
        : error.message;
      setError(message);
      setLoading(false);
      return;
    }

    if (data.session) {
      window.location.assign("/organization/create");
      return;
    }

    setMessage("Account created. Check your email to confirm your account, then continue to organization setup.");
    setLoading(false);
  }

  return (
    <main className="auth-shell">
      <section className="auth-card wide">
        <div className="auth-brand">
          <span className="brand-mark">P</span>
          <span>Pomelo Inventory</span>
        </div>
        <p className="eyebrow">GET STARTED</p>
        <h1>Create your account</h1>
        <p className="muted">Create your secure account to start your inventory workspace.</p>

        <form onSubmit={submit} className="form">
          <label>
            Full name
            <input required autoComplete="name" placeholder="Your full name" value={fullName} onChange={(e) => setFullName(e.target.value)} />
          </label>
          <label>
            Email
            <input type="email" required autoComplete="email" placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} />
          </label>
          <label>
            Password
            <input type="password" required minLength={8} autoComplete="new-password" placeholder="At least 8 characters" value={password} onChange={(e) => setPassword(e.target.value)} />
          </label>
          <label>
            Confirm password
            <input type="password" required minLength={8} autoComplete="new-password" placeholder="Re-enter your password" value={confirmPassword} onChange={(e) => setConfirmPassword(e.target.value)} />
          </label>
          {error && <div className="form-error" role="alert">{error}</div>}
          {message && <div className="form-success" role="status">{message}</div>}
          <button className="primary-button" disabled={loading}>
            {loading ? "Creating account…" : "Create account"}
          </button>
        </form>
        <p className="auth-link">Already registered? <a href="/auth/login">Sign in</a></p>
      </section>
    </main>
  );
}
