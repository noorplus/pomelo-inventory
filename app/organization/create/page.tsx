"use client";

import { FormEvent, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function CreateOrganizationPage() {
  const router = useRouter();
  const supabase = createClient();
  const [name, setName] = useState("");
  const [phone, setPhone] = useState("");
  const [email, setEmail] = useState("");
  const [address, setAddress] = useState("");
  const [tin, setTin] = useState("");
  const [bin, setBin] = useState("");
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    let active = true;
    (async () => {
      const { data: { user } } = await supabase.auth.getUser();
      if (!active) return;
      if (!user) {
        router.replace("/auth/login");
        return;
      }

      const { data: memberships } = await supabase
        .from("organization_users")
        .select("organization_id")
        .eq("user_id", user.id)
        .limit(1);

      if (memberships?.length) {
        router.replace("/");
        return;
      }
      setLoading(false);
    })();
    return () => { active = false; };
  }, [router, supabase]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError("");
    setSaving(true);

    const { error } = await supabase.rpc("create_organization", {
      p_organization_name: name,
      p_phone_number: phone,
      p_email: email,
      p_address: address,
      p_tin: tin || null,
      p_bin: bin || null,
    });

    if (error) {
      setError(error.message);
      setSaving(false);
      return;
    }

    router.replace("/");
    router.refresh();
  }

  if (loading) return <main className="auth-shell"><section className="auth-card"><p className="muted">Loading...</p></section></main>;

  return (
    <main className="auth-shell">
      <section className="auth-card wide">
        <div className="auth-brand">Pomelo Inventory</div>
        <h1>Create your organization</h1>
        <p className="muted">Your organization will receive a six-digit organization number automatically.</p>
        <form onSubmit={submit} className="form">
          <label>Organization Name<input required value={name} onChange={(e) => setName(e.target.value)} /></label>
          <label>Phone Number<input required type="tel" value={phone} onChange={(e) => setPhone(e.target.value)} /></label>
          <label>Organization Email<input required type="email" value={email} onChange={(e) => setEmail(e.target.value)} /></label>
          <label>Address<textarea required rows={3} value={address} onChange={(e) => setAddress(e.target.value)} /></label>
          <label>TIN <span className="muted">(optional)</span><input value={tin} onChange={(e) => setTin(e.target.value)} /></label>
          <label>BIN <span className="muted">(optional)</span><input value={bin} onChange={(e) => setBin(e.target.value)} /></label>
          {error && <div className="form-error" role="alert">{error}</div>}
          <button className="primary-button" disabled={saving}>{saving ? "Creating..." : "Create organization"}</button>
        </form>
      </section>
    </main>
  );
}
