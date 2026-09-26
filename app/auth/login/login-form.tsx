"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type Props = {
  initialError?: string;
};

export default function LoginForm({ initialError = "" }: Props) {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState(initialError);
  const [loading, setLoading] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError("");
    setLoading(true);
    const supabase = createClient();
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
    <form onSubmit={submit} className="form">
      <label>Email<input type="email" required autoComplete="email" placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} /></label>
      <label>Password<input type="password" required autoComplete="current-password" placeholder="Your password" value={password} onChange={(e) => setPassword(e.target.value)} /></label>
      {error && <div className="form-error" role="alert">{error}</div>}
      <button className="primary-button" disabled={loading}>{loading ? "Signing in..." : "Sign in"}</button>
    </form>
  );
}
