import Link from "next/link";
import { SignOutButton } from "@/app/components/sign-out-button";
import { getWorkspaceContext } from "@/lib/auth/workspace";

type NavItem = readonly [key: string, href: string, icon: string, label: string];
type NavSection = { label: string; items: readonly NavItem[] };

const sections: readonly NavSection[] = [
  {
    label: "OVERVIEW",
    items: [
      ["dashboard", "/", "⌂", "Dashboard"],
      ["reports", "/reports", "▣", "Reports"],
    ],
  },
  {
    label: "OPERATIONS",
    items: [
      ["purchases", "/purchases", "↥", "Purchases"],
      ["sales", "/sales", "↧", "Sales"],
      ["inventory", "/inventory", "▤", "Inventory"],
    ],
  },
  {
    label: "FINANCE",
    items: [["accounting", "/accounting", "❖", "Accounting"]],
  },
  {
    label: "MASTERS",
    items: [
      ["products", "/products", "▦", "Products"],
      ["contacts", "/contacts", "◎", "Contacts"],
      ["uom", "/uom", "◈", "UoM"],
    ],
  },
  {
    label: "SYSTEM",
    items: [
      ["organizations", "/organization", "⇄", "Organizations"],
      ["settings", "/settings", "⚙", "Settings"],
    ],
  },
];

function NavLinks({ active, className }: { active: string; className: string }) {
  return (
    <nav className={className} aria-label="Main navigation">
      {sections.map((section) => (
        <div key={section.label} className="nav-section">
          <p className="nav-section-label">{section.label}</p>
          {section.items.map(([key, href, icon, label]) => (
            <Link key={key} className={active === key ? "active" : ""} href={href}>
              <span>{icon}</span>
              {label}
            </Link>
          ))}
        </div>
      ))}
    </nav>
  );
}

type Props = {
  active: "dashboard" | "settings" | "uom" | "products" | "contacts" | "purchases" | "sales" | "inventory" | "accounting" | "reports" | "organizations";
  children: React.ReactNode;
};

export default async function WorkspaceShell({ active, children }: Props) {
  const { user, organization, profile } = await getWorkspaceContext();


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
              <NavLinks active={active} className="nav mobile-nav" />
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
        <NavLinks active={active} className="nav desktop-nav" />
        <div className="sidebar-footer">
          <div className="sidebar-user">
            <div className="avatar">{initials || "U"}</div>
            <div className="sidebar-user-copy">
              <strong>{profile?.full_name || organization?.organization_name || "User"}</strong>
              <span>{user.email}</span>
            </div>
          </div>
          <Link className="filter-clear" href="/organization" title="Switch workspace">⇄ Switch</Link>
          <SignOutButton />
        </div>
      </aside>
      <main className="main">{children}</main>
    </div>
  );
}
