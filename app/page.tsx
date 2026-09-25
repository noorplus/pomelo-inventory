export default function Home() {
  return (
    <div className="dashboard">
      <aside className="sidebar">
        <div className="brand">Pomelo Inventory</div>
        <nav className="nav" aria-label="Main navigation">
          <a className="active" href="/">Dashboard</a>
          <a href="/products">Products</a>
          <a href="/warehouses">Warehouses</a>
          <a href="/stock-movements">Stock Movements</a>
          <a href="/purchases">Purchases</a>
          <a href="/transfers">Transfers</a>
          <a href="/suppliers">Suppliers</a>
          <a href="/reports">Reports</a>
        </nav>
      </aside>

      <main className="main">
        <header className="header">
          <div>
            <h1>Dashboard</h1>
            <div className="muted">Inventory overview and recent activity</div>
          </div>
        </header>

        <section className="grid" aria-label="Inventory summary">
          <div className="card">
            <div className="card-label">Total Products</div>
            <div className="card-value">—</div>
          </div>
          <div className="card">
            <div className="card-label">Warehouses</div>
            <div className="card-value">—</div>
          </div>
          <div className="card">
            <div className="card-label">Low Stock</div>
            <div className="card-value">—</div>
          </div>
          <div className="card">
            <div className="card-label">Pending Purchases</div>
            <div className="card-value">—</div>
          </div>
        </section>

        <section className="card table-card">
          <div className="table-title">Recent Stock Movements</div>
          <div className="muted" style={{ padding: "20px" }}>
            No inventory data is available yet.
          </div>
        </section>
      </main>
    </div>
  );
}
