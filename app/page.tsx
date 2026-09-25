const stats = [
  { label: "Total Products", value: "1,248" },
  { label: "Warehouses", value: "8" },
  { label: "Low Stock", value: "23" },
  { label: "Pending Purchases", value: "17" },
];

const movements = [
  { product: "Office Chair", warehouse: "Main Warehouse", type: "Received", qty: "+120", status: "Completed" },
  { product: "Oak Table", warehouse: "Production Store", type: "Issued", qty: "-24", status: "Completed" },
  { product: "LED Desk Lamp", warehouse: "Main Warehouse", type: "Transferred", qty: "+40", status: "Completed" },
  { product: "Filing Cabinet", warehouse: "Dhaka Warehouse", type: "Received", qty: "+60", status: "Completed" },
];

export default function Home() {
  return (
    <div className="dashboard">
      <aside className="sidebar">
        <div className="brand">Pomelo Inventory</div>
        <nav className="nav" aria-label="Main navigation">
          <a className="active" href="/">Dashboard</a>
          <a href="#">Products</a>
          <a href="#">Warehouses</a>
          <a href="#">Stock Movements</a>
          <a href="#">Purchases</a>
          <a href="#">Transfers</a>
          <a href="#">Suppliers</a>
          <a href="#">Reports</a>
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
          {stats.map((stat) => (
            <div className="card" key={stat.label}>
              <div className="card-label">{stat.label}</div>
              <div className="card-value">{stat.value}</div>
            </div>
          ))}
        </section>

        <section className="card table-card">
          <div className="table-title">Recent Stock Movements</div>
          <table>
            <thead>
              <tr>
                <th>Product</th>
                <th>Warehouse</th>
                <th>Type</th>
                <th>Quantity</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {movements.map((movement) => (
                <tr key={movement.product}>
                  <td>{movement.product}</td>
                  <td>{movement.warehouse}</td>
                  <td>{movement.type}</td>
                  <td>{movement.qty}</td>
                  <td><span className="status">{movement.status}</span></td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      </main>
    </div>
  );
}