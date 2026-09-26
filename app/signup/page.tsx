import Link from "next/link";
import SignupForm from "@/app/auth/signup/signup-form";

export default function SignupPage() {
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
        <SignupForm />
        <p className="auth-link">Already registered? <Link href="/login">Sign in</Link></p>
      </section>
    </main>
  );
}
