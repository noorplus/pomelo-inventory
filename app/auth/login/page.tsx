import Link from "next/link";
import LoginForm from "@/app/auth/login/login-form";

type Props = {
  searchParams: Promise<{ error?: string }>;
};

function getInitialError(code?: string) {
  if (code === "confirmation_failed") {
    return "Email confirmation failed. Please request a new confirmation email.";
  }
  if (code === "missing_code") {
    return "The confirmation link is incomplete.";
  }
  return "";
}

export default async function LoginPage({ searchParams }: Props) {
  const { error } = await searchParams;

  return (
    <main className="auth-shell">
      <section className="auth-card">
        <div className="auth-brand"><span className="brand-mark">P</span><span>Pomelo Inventory</span></div>
        <p className="eyebrow">WELCOME BACK</p>
        <h1>Sign in</h1>
        <p className="muted">Access your inventory workspace securely.</p>
        <LoginForm initialError={getInitialError(error)} />
        <p className="auth-link">New here? <Link href="/auth/signup">Create an account</Link></p>
      </section>
    </main>
  );
}
