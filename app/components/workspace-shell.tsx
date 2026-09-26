import { SignOutButton } from "@/app/components/sign-out-button";
import { getWorkspaceContext } from "@/lib/auth/workspace";

type Props = {
  active: "dashboard" | "settings" | "uom" | "products" | "contacts";
  children: React.ReactNode;
};

export default async function WorkspaceShell({ active, children }: Props) {
  const { user, organization, profile } = await getWorkspaceContext();

  const nav = [
    ["dashboard", "/", "⌂", "Dashboard"],
    ["settings", "/settings", "⚙", "Settings"],
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
        <div className="sidebar-header">
          <div className="mobile-header-controls">
            <details className="mobile-menu">
              <summary aria-label="Open navigation menu">☰</summary>
              <nav className="nav mobile-nav" aria-label="Main navigation">
                {nav.map(([key, href, icon, label]) => (
                  <a key={key} className={active === key ? "active" : ""} href={href}>
                    <span>{icon}</span>{label}
                  </a>
                ))}
              </nav>
            </details>
            <div className="brand">
              <span className="brand-mark">P</span>
              <span>Pomelo Inventory</span>
            </div>
            <details className="mobile-profile">
              <summary className="profile-trigger" aria-label="Open current user menu">
                <span className="avatar">{initials || "U"}</span>
              </summary>
              <div className="profile-popover">
                <div className="profile-heading">CURRENT USER</div>
                <strong>{profile?.full_name || organization?.organization_name || "User"}</strong>
                <span>{user.email}</span>
                <div className="profile-divider" />
                <SignOutButton />
              </div>
            </details>
          </div>
        </div>
        <div className="workspace-label">WORKSPACE</div>
        <nav className="nav desktop-nav" aria-label="Main navigation">
          {nav.map(([key, href, icon, label]) => (
            <a key={key} className={active === key ? "active" : ""} href={href}>
              <span>{icon}</span>{label}
            </a>
          ))}
        </nav>
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
