'use strict';

/*
 * Base de datos de pedidos (SQLite).
 * Guarda cada pedido y sus ítems. El estado del pago se actualiza desde
 * el webhook de Mercado Pago una vez confirmado el pago real.
 *
 * El archivo de la base se crea solo. Por defecto en ./data/sheshe.db
 * (configurable con la variable de entorno DB_PATH).
 */

const fs = require('fs');
const path = require('path');
const Database = require('better-sqlite3');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, '..', 'data', 'sheshe.db');

// Aseguramos que exista la carpeta contenedora.
fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });

const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
  CREATE TABLE IF NOT EXISTS orders (
    ref           TEXT PRIMARY KEY,
    status        TEXT NOT NULL DEFAULT 'pending',
    total         INTEGER NOT NULL,
    currency      TEXT NOT NULL DEFAULT 'ARS',
    preference_id TEXT,
    payment_id    TEXT,
    payer_email   TEXT,
    created_at    TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS order_items (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    order_ref  TEXT NOT NULL REFERENCES orders(ref) ON DELETE CASCADE,
    product_id TEXT NOT NULL,
    name       TEXT NOT NULL,
    size       TEXT NOT NULL,
    qty        INTEGER NOT NULL,
    unit_price INTEGER NOT NULL
  );
`);

const stmtInsertOrder = db.prepare(
  `INSERT INTO orders (ref, status, total, currency, preference_id)
   VALUES (@ref, 'pending', @total, @currency, @preferenceId)`
);
const stmtInsertItem = db.prepare(
  `INSERT INTO order_items (order_ref, product_id, name, size, qty, unit_price)
   VALUES (@order_ref, @product_id, @name, @size, @qty, @unit_price)`
);
const stmtGetOrder = db.prepare('SELECT * FROM orders WHERE ref = ?');
const stmtGetItems = db.prepare('SELECT * FROM order_items WHERE order_ref = ?');
const stmtUpdateStatus = db.prepare(
  `UPDATE orders
   SET status = @status,
       payment_id = COALESCE(@paymentId, payment_id),
       payer_email = COALESCE(@payerEmail, payer_email),
       updated_at = datetime('now')
   WHERE ref = @ref`
);
const stmtListOrders = db.prepare('SELECT * FROM orders ORDER BY created_at DESC LIMIT ?');

// Crea un pedido (pendiente) con sus ítems en una transacción.
const createOrder = db.transaction(({ ref, total, currency, preferenceId, items }) => {
  stmtInsertOrder.run({ ref, total, currency: currency || 'ARS', preferenceId: preferenceId || null });
  for (const it of items) {
    stmtInsertItem.run({
      order_ref: ref,
      product_id: it.id,
      name: it.name,
      size: it.size,
      qty: it.qty,
      unit_price: it.unit_price,
    });
  }
});

function getOrder(ref) {
  const order = stmtGetOrder.get(ref);
  if (!order) return null;
  order.items = stmtGetItems.all(ref);
  return order;
}

function markStatus(ref, { status, paymentId = null, payerEmail = null }) {
  const info = stmtUpdateStatus.run({ ref, status, paymentId, payerEmail });
  return info.changes > 0;
}

function setPreferenceId(ref, preferenceId) {
  db.prepare('UPDATE orders SET preference_id = ? WHERE ref = ?').run(preferenceId, ref);
}

function listOrders(limit = 100) {
  return stmtListOrders.all(limit);
}

module.exports = { db, createOrder, getOrder, markStatus, setPreferenceId, listOrders };
