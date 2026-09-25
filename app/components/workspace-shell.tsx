import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { SignOutButton } from "@/app/components/sign-out-button";

type Props = {
  active: "system" | "uom" | "products" | "contacts";
  children: React.ReactNode;
};

export default async function WorkspaceShell({ active, children }: Props) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", user.id)
    .limit(1);

  if (!memberships?.length) redirect("/organization/create");

  const organizationId = memberships[0].organization_id;
  const [{ data: organization }, { data: profile }] = await Promise.all([
    supabase.from("organizations").select("organization_name").eq("id", organizationId).single(),
    supabase.from("profiles").select("full_name").eq("id", user.id).single(),
  ]);

  const nav = [
    ["system", "/", "⌂", "System"],
    ["contacts", "/contacts", "◎", "Contacts"],
    ["uom", "/uom", "◈", "UoM"],
    ["products", "/products", "▦", "Products"],
  ] as const;

  const initials = (profile?.full_name || user.email || "U")
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .map((part: string) => part[0]?.toUpperCase())
    .join("");

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div>
          <div className="brand">
            <span className="brand-mark">P</span>
            <span>Pomelo Inventory</span>
          </div>
          <div className="workspace-label">WORKSPACE</div>
          <nav className="nav" aria-label="Main navigation">
            {nav.map(([key, href, icon, label]) => (
              <a key={key} className={active === key ? "active" : ""} href={href}>
                <span>{icon}</span>{label}
              </a>
            ))}
          </nav>
        </div>
        <div className="sidebar-footer">
          <div className="sidebar-user">
            <div className="avatar">{initials || "U"}</div>
            <div className="sidebar-user-copy">
              <strong>{profile?.full_name || organization?.organization_name || "User"}</strong>
              <span>{user.email}</span>
            </div>
          </div>
          <SignOutButton />
        </div>
      </aside>
      <main className="main">{children}</main>
    </div>
  );
}
