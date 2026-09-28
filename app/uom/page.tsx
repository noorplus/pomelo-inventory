import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import WorkspaceShell from "@/app/components/workspace-shell";
import SortableHeader from "@/app/components/sortable-header";
import { getWorkspaceContext, getWorkspaceMembership } from "@/lib/auth/workspace";

export const dynamic = "force-dynamic";

type SearchParams = { sort?: string; direction?: string };

export default async function UomPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const { supabase, organizationId } = await getWorkspaceContext();
  const params = await searchParams;
  const sort = ["name", "status", "created_at"].includes(params.sort || "") ? String(params.sort) : "name";
  const direction = params.direction === "desc" ? "desc" : "asc";

  const { data: units, error } = await supabase
    .from("units_of_measure")
    .select("id, name, status, created_at")
    .eq("organization_id", organizationId)
    .order(sort, { ascending: direction === "asc" });

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
          <div className="table-scroll"><table className="spreadsheet-table"><thead><tr><SortableHeader label="Name" field="name" sort={sort} direction={direction} basePath="/uom" /><SortableHeader label="Status" field="status" sort={sort} direction={direction} basePath="/uom" /><SortableHeader label="Created" field="created_at" sort={sort} direction={direction} basePath="/uom" /><th>Action</th></tr></thead>
            <tbody>{units?.map((unit) => <tr key={unit.id}>
              <td><strong>{unit.name}</strong></td>
              <td><span className="status-badge">{unit.status}</span></td>
              <td>{new Date(unit.created_at).toLocaleDateString("en-GB", { day: "2-digit", month: "short", year: "numeric" })}</td>
              <td>
                <form action={toggleUomStatus}>
                  <input type="hidden" name="id" value={unit.id} />
                  <input type="hidden" name="status" value={unit.status === "Active" ? "Inactive" : "Active"} />
                  <button className="secondary-button table-action-button" type="submit">
                    {unit.status === "Active" ? "Deactivate" : "Activate"}
                  </button>
                </form>
              </td>
            </tr>)}</tbody>
          </table></div>
          {!units?.length && <EmptyState icon="◈" title="No UoM yet" text="Add your first unit of measure above." />}
        </section>
      )}
    </WorkspaceShell>
  );
}

async function toggleUomStatus(formData: FormData) {
  "use server";
  const { supabase, organizationId } = await getWorkspaceMembership();
  const id = String(formData.get("id") || "").trim();
  const status = String(formData.get("status") || "").trim();
  if (!id || !["Active", "Inactive"].includes(status)) return;
  const { error } = await supabase
    .from("units_of_measure")
    .update({ status })
    .eq("id", id)
    .eq("organization_id", organizationId);
  if (error) return;
  revalidatePath("/uom");
}

async function createUom(formData: FormData) {
  "use server";
  const { supabase, user, organizationId } = await getWorkspaceMembership();
  const name = String(formData.get("name") || "").trim();
  if (!name) return;
  const { error } = await supabase.from("units_of_measure").insert({ organization_id: organizationId, name, created_by: user.id });
  if (error) return;
  redirect("/uom");
}

function EmptyState({ icon, title, text }: { icon: string; title: string; text: string }) {
  return <div className="empty-state"><div className="empty-icon">{icon}</div><div><h2>{title}</h2><p>{text}</p></div></div>;
}
