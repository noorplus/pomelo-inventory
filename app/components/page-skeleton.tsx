type Props = { variant?: "dashboard" | "table" | "form" };

export default function PageSkeleton({ variant = "table" }: Props) {
  const rows = variant === "table" ? 7 : 4;

  return (
    <div className="app-shell skeleton-shell" aria-busy="true" aria-label="Loading page">
      <aside className="sidebar">
        <div className="sidebar-header">
          <div className="brand skeleton-brand">
            <span className="brand-mark skeleton-block skeleton-mark" />
            <span className="skeleton-line skeleton-brand-text" />
          </div>
        </div>
        <div className="workspace-label">WORKSPACE</div>
        <nav className="nav desktop-nav" aria-hidden="true">
          {["System", "Contacts", "UoM", "Products"].map((label) => (
            <span key={label} className="skeleton-nav-item">
              <span className="skeleton-block skeleton-nav-icon" />
              <span className="skeleton-line" />
            </span>
          ))}
        </nav>
      </aside>

      <main className="main">
        {variant === "dashboard" ? <DashboardSkeleton /> : variant === "form" ? <FormSkeleton /> : <TableSkeleton rows={rows} />}
      </main>
    </div>
  );
}

function DashboardSkeleton() {
  return (
    <>
      <SkeletonHeader />
      <section className="welcome-card skeleton-card">
        <div className="skeleton-stack">
          <span className="skeleton-line skeleton-title" />
          <span className="skeleton-line skeleton-subtitle" />
        </div>
        <span className="skeleton-block skeleton-org-number" />
      </section>
      <section className="section-heading skeleton-heading">
        <span className="skeleton-line skeleton-section-title" />
        <span className="skeleton-line skeleton-section-subtitle" />
      </section>
      <section className="info-grid">
        {Array.from({ length: 8 }).map((_, index) => (
          <div className="info-item skeleton-card" key={index}>
            <span className="skeleton-line skeleton-label" />
            <span className="skeleton-line skeleton-value" />
          </div>
        ))}
      </section>
    </>
  );
}

function TableSkeleton({ rows }: { rows: number }) {
  return (
    <>
      <SkeletonHeader />
      <section className="filter-card skeleton-card">
        <div className="skeleton-filter-row">
          <span className="skeleton-block skeleton-input" />
          <span className="skeleton-block skeleton-input skeleton-filter-short" />
          <span className="skeleton-block skeleton-button" />
        </div>
      </section>
      <section className="table-card skeleton-card">
        <div className="table-meta">
          <span className="skeleton-line skeleton-meta" />
        </div>
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                {Array.from({ length: 4 }).map((_, index) => (
                  <th key={index}><span className="skeleton-line skeleton-th" /></th>
                ))}
              </tr>
            </thead>
            <tbody>
              {Array.from({ length: rows }).map((_, row) => (
                <tr key={row}>
                  {Array.from({ length: 4 }).map((_, column) => (
                    <td key={column}><span className="skeleton-line skeleton-td" /></td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>
    </>
  );
}

function FormSkeleton() {
  return (
    <>
      <SkeletonHeader />
      <section className="data-card skeleton-card">
        <div className="skeleton-stack skeleton-form-stack">
          <span className="skeleton-line skeleton-section-title" />
          <span className="skeleton-line skeleton-section-subtitle" />
          <span className="skeleton-block skeleton-form-input" />
          <span className="skeleton-block skeleton-form-input" />
          <span className="skeleton-block skeleton-form-textarea" />
          <span className="skeleton-block skeleton-button skeleton-form-button" />
        </div>
      </section>
    </>
  );
}

function SkeletonHeader() {
  return (
    <header className="topbar skeleton-card">
      <div className="skeleton-stack">
        <span className="skeleton-line skeleton-eyebrow" />
        <span className="skeleton-line skeleton-title" />
        <span className="skeleton-line skeleton-subtitle" />
      </div>
      <span className="skeleton-block skeleton-header-badge" />
    </header>
  );
}
