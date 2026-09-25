import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import WorkspaceShell from "@/app/components/workspace-shell";

export const dynamic = "force-dynamic";

export default async function UomPage() {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).limit(1);
  if (!memberships?.length) redirect("/organization/create");
  const organizationId = memberships[0].organization_id;

  const [{ data: organization }, { data: units }] = await Promise.all([
    supabase.from("organizations").select("organization_name").eq("id", organizationId).single(),
    supabase.from("units_of_measure").select("id, name, status, created_at").eq("organization_id", organizationId).order("name"),
  ]);

  return (
    <WorkspaceShell active="uom">
      <header className="topbar"><div><p className="eyebrow">MASTER DATA</p><h1>Units of Measure</h1><p className="muted">Manage the units used by products in this organization.</p></div></header>
      <section className="data-card">
        <form className="inline-form" action={createUom}>
          <label>UoM name<input name="name" placeholder="e.g. Piece, Kilogram, Liter" required /></label>
          <button className="primary-button" type="submit">Add UoM</button>
        </form>
      </section>
      <section className="section-heading"><div><h2>UoM list</h2><p className="muted">{units?.length ?? 0} units in this organization.</p></div></section>
      <section className="table-card"><table><thead><tr><th>Name</th><th>Status</th><th>Created</th></tr></thead><tbody>{units?.map((unit) => <tr key={unit.id}><td><strong>{unit.name}</strong></td><td><span className="status-badge">{unit.status}</span></td><td>{new Date(unit.created_at).toLocaleDateString("en-GB")}</td></tr>)}</tbody></table>{!units?.length && <div className="empty-state"><div className="empty-icon">◈</div><div><h2>No UoM yet</h2><p>Add your first unit of measure above.</p></div></div>}</section>
    </WorkspaceShell>
  );
}

async function createUom(formData: FormData) {
  "use server";
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");
  const { data: memberships } = await supabase.from("organization_users").select("organization_id").eq("user_id", user.id).limit(1);
  if (!memberships?.length) redirect("/organization/create");
  const name = String(formData.get("name") || "").trim();
  if (!name) return;
  await supabase.from("units_of_measure").insert({ organization_id: memberships[0].organization_id, name, created_by: user.id });
  redirect("/uom");
}
