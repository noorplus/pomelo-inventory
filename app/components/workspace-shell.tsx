import Link from "next/link";
import { SignOutButton } from "@/app/components/sign-out-button";
import { MobileNavDrawer } from "@/app/components/mobile-nav-drawer";
import { getWorkspaceContext } from "@/lib/auth/workspace";

type IconName = "dashboard" | "reports" | "purchases" | "sales" | "inventory" | "accounting" | "products" | "contacts" | "uom" | "settings";

type NavItem = readonly [key: string, href: string, icon: IconName, label: string];
type NavSection = { label: string; items: readonly NavItem[] };

const sections: readonly NavSection[] = [
  {
    label: "OVERVIEW",
    items: [
      ["dashboard", "/", "dashboard", "Dashboard"],
      ["reports", "/reports", "reports", "Reports"],
    ],
  },
  {
    label: "OPERATIONS",
    items: [
      ["purchases", "/purchases", "purchases", "Purchases"],
      ["sales", "/sales", "sales", "Sales"],
      ["inventory", "/inventory", "inventory", "Inventory"],
    ],
  },
  {
    label: "FINANCE",
    items: [["accounting", "/accounting", "accounting", "Accounting"]],
  },
  {
    label: "MASTERS",
    items: [
      ["products", "/products", "products", "Products"],
      ["contacts", "/contacts", "contacts", "Contacts"],
      ["uom", "/uom", "uom", "UoM"],
    ],
  },
  {
    label: "SYSTEM",
    items: [["settings", "/settings", "settings", "Settings"]],
  },
];

function NavIcon({ name }: { name: IconName }) {
  const paths: Record<IconName, React.ReactNode> = {
    dashboard: <><rect x="3" y="3" width="7" height="7" rx="1" /><rect x="14" y="3" width="7" height="7" rx="1" /><rect x="3" y="14" width="7" height="7" rx="1" /><rect x="14" y="14" width="7" height="7" rx="1" /></>,
    reports: <><path d="M5 19V9" /><path d="M12 19V5" /><path d="M19 19v-7" /><path d="M3 19h18" /></>,
    purchases: <><path d="M12 19V5" /><path d="m7 10 5-5 5 5" /><path d="M5 19h14" /></>,
    sales: <><path d="M12 5v14" /><path d="m7 14 5 5 5-5" /><path d="M5 5h14" /></>,
    inventory: <><path d="m12 3 8 4.5v9L12 21l-8-4.5v-9L12 3Z" /><path d="M4.5 7.8 12 12l7.5-4.2" /><path d="M12 12v9" /></>,
    accounting: <><rect x="4" y="3" width="16" height="18" rx="2" /><path d="M8 7h8M8 11h8M8 15h3M15 15h1M8 18h8" /></>,
    products: <><path d="m12 3 8 4.5-8 4.5-8-4.5L12 3Z" /><path d="m4 12 8 4.5 8-4.5" /><path d="m4 16.5 8 4.5 8-4.5" /></>,
    contacts: <><circle cx="12" cy="8" r="3" /><path d="M5 20a7 7 0 0 1 14 0" /></>,
    uom: <><path d="M6 3h12" /><path d="M6 21h12" /><path d="M8 3v4l4 5 4-5V3" /><path d="M8 21v-4l4-5 4 5v4" /></>,
    settings: <><path d="M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z" /><path d="m19.4 15 .1.1a2 2 0 0 1-2.8 2.8l-.1-.1a2 2 0 0 0-3.4 1.4v.2a2 2 0 0 1-4 0v-.2A2 2 0 0 0 5.8 17.8l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1A2 2 0 0 0 1.6 11.6h-.2a2 2 0 0 1 0-4h.2A2 2 0 0 0 3 4.2l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1A2 2 0 0 0 9.2 0h.2a2 2 0 0 1 4 0v.2a2 2 0 0 0 3.4 1.4l.1-.1a2 2 0 0 1 2.8 2.8l-.1.1A2 2 0 0 0 20.8 7.6h.2a2 2 0 0 1 0 4h-.2A2 2 0 0 0 19.4 15Z" transform="scale(.9) translate(1.3 1.3)" /></>,
  };

  return (
    <svg className="nav-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {paths[name]}
    </svg>
  );
}

function NavLinks({ active, className }: { active: string; className: string }) {
  return (
    <nav className={className} aria-label="Main navigation">
      {sections.map((section) => (
        <div key={section.label} className="nav-section">
          <p className="nav-section-label">{section.label}</p>
          {section.items.map(([key, href, icon, label]) => (
            <Link key={key} className={active === key ? "active" : ""} href={href} aria-current={active === key ? "page" : undefined}>
              <span className="nav-icon-wrap"><NavIcon name={icon} /></span>
              <span className="nav-label">{label}</span>
            </Link>
          ))}
        </div>
      ))}
    </nav>
  );
}

type Props = {
  active: "dashboard" | "settings" | "uom" | "products" | "contacts" | "purchases" | "sales" | "inventory" | "accounting" | "reports";
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
      <header className="global-header">
        <div className="global-header-brand">
          <div className="global-mobile-nav">
            <MobileNavDrawer>
              <div className="mobile-drawer-workspace">
                <span>WORKSPACE</span>
                <strong>{organization?.organization_name || "Workspace"}</strong>
              </div>
              <NavLinks active={active} className="nav mobile-nav" />
            </MobileNavDrawer>
          </div>
          <div className="brand">
            <span className="brand-mark">P</span>
            <span>Pomelo Inventory</span>
          </div>
        </div>

        <div className="global-header-workspace" title={organization?.organization_name || "Workspace"}>
          <span className="status-dot" aria-hidden="true" />
          <span>{organization?.organization_name || "Workspace"}</span>
        </div>

        <details className="global-header-profile">
          <summary className="global-profile-trigger" aria-label="Open current user menu">
            <span className="avatar">{initials || "U"}</span>
            <span className="global-profile-copy">
              <strong>{profile?.full_name || "User"}</strong>
              <span>{user.email}</span>
            </span>
            <span className="profile-chevron" aria-hidden="true">⌄</span>
          </summary>
          <div className="profile-popover">
            <div className="profile-heading">CURRENT USER</div>
            <strong>{profile?.full_name || "User"}</strong>
            <span>{user.email}</span>
            <div className="profile-divider" />
            <SignOutButton />
          </div>
        </details>
      </header>

      <aside className="sidebar">
        <div className="workspace-label">WORKSPACE</div>
        <NavLinks active={active} className="nav desktop-nav" />
      </aside>

      <main className="main">{children}</main>
    </div>
  );
}
