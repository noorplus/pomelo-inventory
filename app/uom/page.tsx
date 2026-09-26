import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import WorkspaceShell from "@/app/components/workspace-shell";
import { getWorkspaceContext } from "@/lib/auth/workspace";
import { getCachedUnitsOfMeasure, invalidateCachedUnitsOfMeasure } from "@/lib/cache/reference-data";

export const dynamic = "force-dynamic";

export default async function UomPage() {
  const { supabase, organizationId, user } = await getWorkspaceContext();

  let units: Awaited<ReturnType<typeof getCachedUnitsOfMeasure>> = [];
  let error: Error | null = null;
  try {
    units = await getCachedUnitsOfMeasure(supabase, organizationId, user.id);
  } catch (caught) {
    error = caught instanceof Error ? caught : new Error("Unable to load units.");
  }

  return (
    <WorkspaceShell active="uom">
      <header className="topbar">
        <div><p className="eyebrow">MASTER DATA</p><h1>Units of Measure</h1><p className="muted">Define the measurement units used by products.</p></div>
        <span className="page-count">{units?.length ?? 0} records</span>
      </header>

      <section className="data-card form-panel">
        <div className="panel-heading"><div><h2>Add unit of measure</h2><p className="muted">Use a clear, reusable name such as Piece, Kilogram, or Liter.</p></div></div>
        <form className="inline-form" action={createUom}>
          <label>UoM name<span className="required-mark">*</span><input name="name" placeholder="e.g. Piece, Kilogram, Liter" required /></label>
          <button className="primary-button" type="submit">Add UoM</button>
        </form>
      </section>

      <section className="section-heading"><div><h2>UoM list</h2><p className="muted">All units belonging to this organization.</p></div></section>
      {error ? <section className="form-error" role="alert">Unable to load units: {error.message}</section> : (
        <section className="table-card">
          <div className="table-scroll"><table><thead><tr><th>Name</th><th>Status</th><th>Created</th></tr></thead>
            <tbody>{units?.map((unit) => <tr key={unit.id}><td><strong>{unit.name}</strong></td><td><span className="status-badge">{unit.status}</span></td><td>{new Date(unit.created_at).toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" })}</td></tr>)}</tbody>
          </table></div>
          {!units?.length && <EmptyState icon="◈" title="No UoM yet" text="Add your first unit of measure above." />}
        </section>
      )}
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
  const organizationId = memberships[0].organization_id;
  const { error } = await supabase.from("units_of_measure").insert({ organization_id: organizationId, name, created_by: user.id });
  if (error) return;
  await invalidateCachedUnitsOfMeasure(organizationId, user.id);
  redirect("/uom");
}

function EmptyState({ icon, title, text }: { icon: string; title: string; text: string }) {
  return <div className="empty-state"><div className="empty-icon">{icon}</div><div><h2>{title}</h2><p>{text}</p></div></div>;
}
