export default function WorkspaceLoading() {
  return (
    <main className="workspace-loading" aria-busy="true" aria-label="Loading workspace">
      <div className="workspace-loading-card">
        <div className="workspace-loading-mark" aria-hidden="true">P</div>
        <div className="workspace-loading-copy">
          <div className="workspace-loading-brand">Pomelo Inventory</div>
          <div className="workspace-loading-message">
            <span className="workspace-loading-spinner" aria-hidden="true" />
            Loading your workspace
          </div>
        </div>
      </div>
    </main>
  );
}
