"use client";

import { FormEvent, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function CreateOrganizationPage() {
  const router = useRouter();
  const [name, setName] = useState(""); const [phone, setPhone] = useState(""); const [email, setEmail] = useState("");
  const [address, setAddress] = useState(""); const [tin, setTin] = useState(""); const [bin, setBin] = useState("");
  const [error, setError] = useState(""); const [loading, setLoading] = useState(true); const [saving, setSaving] = useState(false);

  useEffect(() => {
    let active = true; const supabase = createClient();
    (async () => {
      const { data: { user }, error: userError } = await supabase.auth.getUser();
      if (!active) return;
      if (userError || !user) { router.replace("/login"); return; }
      const { data: memberships, error: membershipError } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).limit(1);
      if (!active) return;
      if (membershipError) { setError(membershipError.message); setLoading(false); return; }
      if (memberships?.length) { router.replace("/"); return; }
      setLoading(false);
    })();
    return () => { active = false; };
  }, [router]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setError(""); setSaving(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("create_organization", {
      p_organization_name: name.trim(), p_phone_number: phone.trim(), p_email: email.trim(),
      p_address: address.trim(), p_tin: tin.trim() || null, p_bin: bin.trim() || null,
    });
    if (error) { setError(error.message); setSaving(false); return; }
    router.replace("/"); router.refresh();
  }

  if (loading) return <main className="auth-shell"><section className="auth-card"><div className="auth-brand"><span className="brand-mark">P</span><span>Pomelo Inventory</span></div><div className="loading-state"><span className="loading-dot" /> Preparing your workspace…</div></section></main>;

  return (
    <main className="auth-shell">
      <section className="auth-card wide">
        <div className="auth-brand"><span className="brand-mark">P</span><span>Pomelo Inventory</span></div>
        <p className="eyebrow">FIRST STEP</p>
        <h1>Create your organization</h1>
        <p className="muted">Set up the organization profile used by your inventory workspace. A six-digit organization number is generated automatically.</p>
        <form onSubmit={submit} className="form">
          <label>Organization name<span className="required-mark">*</span><input required autoComplete="organization" placeholder="e.g. Noor Plus Trading" value={name} onChange={(e) => setName(e.target.value)} /></label>
          <div className="info-grid">
            <label>Phone number<span className="required-mark">*</span><input required type="tel" autoComplete="tel" placeholder="+880 1XXXXXXXXX" value={phone} onChange={(e) => setPhone(e.target.value)} /></label>
            <label>Organization email<span className="required-mark">*</span><input required type="email" autoComplete="email" placeholder="office@example.com" value={email} onChange={(e) => setEmail(e.target.value)} /></label>
          </div>
          <label>Address<span className="required-mark">*</span><textarea required rows={3} autoComplete="street-address" placeholder="Full business address" value={address} onChange={(e) => setAddress(e.target.value)} /></label>
          <div className="info-grid">
            <label>TIN <span className="muted">(optional)</span><input inputMode="numeric" placeholder="Tax identification number" value={tin} onChange={(e) => setTin(e.target.value)} /></label>
            <label>BIN <span className="muted">(optional)</span><input inputMode="numeric" placeholder="Business identification number" value={bin} onChange={(e) => setBin(e.target.value)} /></label>
          </div>
          {error && <div className="form-error" role="alert">{error}</div>}
          <button className="primary-button" disabled={saving}>{saving ? "Creating workspace…" : "Create organization"}</button>
        </form>
      </section>
    </main>
  );
}
