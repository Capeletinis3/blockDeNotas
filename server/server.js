'use strict';

require('dotenv').config();

const path = require('path');
const crypto = require('crypto');
const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const rateLimit = require('express-rate-limit');

const { getProduct, VALID_SIZES } = require('./catalog');
const orders = require('./db');
const mailer = require('./email');

const app = express();

const {
  PORT = 3000,
  NODE_ENV = 'development',
  MP_ACCESS_TOKEN,
  MP_WEBHOOK_SECRET,
  PUBLIC_BASE_URL = `http://localhost:${PORT}`,
  ALLOWED_ORIGIN = '',
  ADMIN_TOKEN = '',
} = process.env;

app.set('trust proxy', 1);
app.disable('x-powered-by');

app.use(helmet({
  contentSecurityPolicy: {
    useDefaults: true,
    directives: {
      'default-src': ["'self'"],
      'base-uri': ["'self'"],
      'object-src': ["'none'"],
      'frame-ancestors': ["'none'"],
      'img-src': ["'self'", 'data:'],
      'font-src': ["'self'", 'https://fonts.gstatic.com'],
      'style-src': ["'self'", "'unsafe-inline'", 'https://fonts.googleapis.com'],
      'script-src': ["'self'"],
      'connect-src': ["'self'"],
      'form-action': ["'self'"],
      'upgrade-insecure-requests': [],
    },
  },
  crossOriginEmbedderPolicy: false,
  hsts: NODE_ENV === 'production'
    ? { maxAge: 15552000, includeSubDomains: true, preload: true }
    : false,
}));

if (ALLOWED_ORIGIN) {
  app.use(cors({ origin: ALLOWED_ORIGIN.split(',').map(s => s.trim()), methods: ['GET', 'POST'] }));
}

app.use(express.json({ limit: '16kb' }));

const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Demasiadas solicitudes. Intentá más tarde.' },
});
app.use('/api/', apiLimiter);

const sensitiveLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Demasiados intentos. Esperá unos minutos.' },
});

app.get('/api/products', (req, res) => {
  const { PRODUCTS } = require('./catalog');
  res.json({ products: Object.values(PRODUCTS) });
});

function validateAndPrice(items) {
  if (!Array.isArray(items) || items.length === 0) {
    return { error: 'El carrito está vacío.' };
  }
  if (items.length > 50) {
    return { error: 'Demasiados ítems en el carrito.' };
  }

  const lineItems = [];
  let total = 0;

  for (const raw of items) {
    if (!raw || typeof raw !== 'object') return { error: 'Ítem inválido.' };

    const product = getProduct(String(raw.id));
    if (!product) return { error: `Producto inexistente: ${String(raw.id).slice(0, 40)}` };

    const qty = Number(raw.qty);
    if (!Number.isInteger(qty) || qty < 1 || qty > 10) {
      return { error: 'Cantidad inválida (1 a 10 por producto).' };
    }

    const size = String(raw.size || 'M').toUpperCase();
    if (!VALID_SIZES.includes(size)) return { error: 'Talle inválido.' };

    total += product.price * qty;
    lineItems.push({
      id: product.id,
      name: product.name,
      size: size,
      title: `${product.name} (Talle ${size})`,
      quantity: qty,
      unit_price: product.price,
      currency_id: 'ARS',
    });
  }

  return { lineItems, total };
}

app.post('/api/checkout', sensitiveLimiter, async (req, res) => {
  try {
    const { items } = req.body || {};
    const result = validateAndPrice(items);
    if (result.error) return res.status(400).json({ error: result.error });

    if (!MP_ACCESS_TOKEN) {
      return res.status(503).json({
        error: 'El pago no está configurado todavía. Falta MP_ACCESS_TOKEN.',
      });
    }

    const externalRef = crypto.randomUUID();

    orders.createOrder({
      ref: externalRef,
      total: result.total,
      currency: 'ARS',
      items: result.lineItems.map(li => ({
        id: li.id, name: li.name, size: li.size, qty: li.quantity, unit_price: li.unit_price,
      })),
    });

    const { MercadoPagoConfig, Preference } = require('mercadopago');
    const client = new MercadoPagoConfig({ accessToken: MP_ACCESS_TOKEN });
    const preference = new Preference(client);

    const isPublic = /^https?:\/\//.test(PUBLIC_BASE_URL) && !/localhost|127\.0\.0\.1/.test(PUBLIC_BASE_URL);
    const prefBody = {
      items: result.lineItems.map(({ id, name, size, ...rest }) => rest),
      external_reference: externalRef,
      back_urls: {
        success: `${PUBLIC_BASE_URL}/?pago=exito`,
        failure: `${PUBLIC_BASE_URL}/?pago=error`,
        pending: `${PUBLIC_BASE_URL}/?pago=pendiente`,
      },
      statement_descriptor: 'SHESHE',
    };
    if (isPublic) {
      prefBody.auto_return = 'approved';
      prefBody.notification_url = `${PUBLIC_BASE_URL}/api/webhook`;
    }

    const mpResult = await preference.create({ body: prefBody });

    orders.setPreferenceId(externalRef, mpResult.id);

    return res.json({
      id: mpResult.id,
      init_point: mpResult.init_point,
    });
  } catch (err) {
    console.error('[checkout] error:', err && err.message ? err.message : err);
    return res.status(502).json({ error: 'No se pudo iniciar el pago. Probá de nuevo.' });
  }
});

app.post('/api/webhook', async (req, res) => {
  const dataId = (req.query['data.id'] || (req.body && req.body.data && req.body.data.id) || '').toString();

  if (MP_WEBHOOK_SECRET) {
    try {
      const signature = req.get('x-signature') || '';
      const requestId = req.get('x-request-id') || '';
      const parts = Object.fromEntries(
        signature.split(',').map(p => p.split('=').map(s => s.trim()))
      );
      const manifest = `id:${dataId};request-id:${requestId};ts:${parts.ts};`;
      const hmac = crypto.createHmac('sha256', MP_WEBHOOK_SECRET).update(manifest).digest('hex');
      const v1 = parts.v1 || '';
      const valid = v1.length === hmac.length &&
        crypto.timingSafeEqual(Buffer.from(hmac), Buffer.from(v1));
      if (!valid) {
        console.warn('[webhook] firma inválida');
        return res.sendStatus(401);
      }
    } catch (e) {
      return res.sendStatus(401);
    }
  }

  res.sendStatus(200);

  const type = (req.body && req.body.type) || req.query.type;
  if (type !== 'payment' || !dataId || !MP_ACCESS_TOKEN) return;

  try {
    const { MercadoPagoConfig, Payment } = require('mercadopago');
    const client = new MercadoPagoConfig({ accessToken: MP_ACCESS_TOKEN });
    const payment = await new Payment(client).get({ id: dataId });

    const ref = payment.external_reference;
    if (!ref) return;

    const statusMap = { approved: 'approved', rejected: 'rejected', cancelled: 'cancelled', refunded: 'refunded' };
    const status = statusMap[payment.status] || 'pending';

    const updated = orders.markStatus(ref, {
      status,
      paymentId: String(payment.id),
      payerEmail: payment.payer && payment.payer.email,
    });

    if (updated && status === 'approved') {
      const order = orders.getOrder(ref);
      if (order) mailer.sendOrderPaidNotification(order);
      console.log('[webhook] pedido aprobado:', ref);
    }
  } catch (err) {
    console.error('[webhook] error procesando pago:', err && err.message ? err.message : err);
  }
});

app.get('/api/orders/:ref', (req, res) => {
  const order = orders.getOrder(req.params.ref);
  if (!order) return res.status(404).json({ error: 'Pedido no encontrado.' });
  res.json({ ref: order.ref, status: order.status, total: order.total });
});

app.get('/api/admin/orders', (req, res) => {
  if (!ADMIN_TOKEN || req.get('x-admin-token') !== ADMIN_TOKEN) {
    return res.status(401).json({ error: 'No autorizado.' });
  }
  res.json({ orders: orders.listOrders(200) });
});

app.post('/api/contact', sensitiveLimiter, (req, res) => {
  const { nombre, email, asunto, mensaje } = req.body || {};

  const errors = [];
  if (typeof nombre !== 'string' || nombre.trim().length < 2 || nombre.length > 80) {
    errors.push('nombre');
  }
  if (typeof email !== 'string' || !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email) || email.length > 120) {
    errors.push('email');
  }
  if (typeof mensaje !== 'string' || mensaje.trim().length < 10 || mensaje.length > 1000) {
    errors.push('mensaje');
  }
  if (typeof asunto === 'string' && asunto.length > 120) {
    errors.push('asunto');
  }
  if (errors.length) {
    return res.status(400).json({ error: 'Datos inválidos.', fields: errors });
  }

  mailer.sendContactNotification({
    nombre: nombre.trim(),
    email: email.trim(),
    asunto: typeof asunto === 'string' ? asunto.trim() : '',
    mensaje: mensaje.trim(),
  });
  return res.json({ ok: true });
});

const rootDir = path.join(__dirname, '..');
app.use(express.static(rootDir, {
  extensions: ['html'],
  setHeaders(res) {
    res.setHeader('X-Content-Type-Options', 'nosniff');
  },
}));

app.get('*', (req, res, next) => {
  if (req.path.startsWith('/api/')) return next();
  res.sendFile(path.join(rootDir, 'index.html'));
});

app.listen(PORT, () => {
  console.log(`SHESHE escuchando en http://localhost:${PORT} (${NODE_ENV})`);
  if (!MP_ACCESS_TOKEN) {
    console.warn('⚠  MP_ACCESS_TOKEN no configurado: el checkout responderá 503 hasta que lo agregues en .env');
  }
});

module.exports = app;
