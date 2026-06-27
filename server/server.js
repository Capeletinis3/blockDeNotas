'use strict';

/* ===========================================================
   SHESHE — Backend seguro
   - Sirve el sitio estático
   - Calcula precios del lado del servidor (no confía en el cliente)
   - Crea preferencias de pago en Mercado Pago (Checkout Pro)
   - Cabeceras de seguridad (helmet), rate limiting, CORS y validación
   =========================================================== */

require('dotenv').config();

const path = require('path');
const crypto = require('crypto');
const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const rateLimit = require('express-rate-limit');

const { getProduct, VALID_SIZES } = require('./catalog');

const app = express();

const {
  PORT = 3000,
  NODE_ENV = 'development',
  MP_ACCESS_TOKEN,
  MP_WEBHOOK_SECRET,
  PUBLIC_BASE_URL = `http://localhost:${PORT}`,
  ALLOWED_ORIGIN = '',
} = process.env;

/* --- Confianza en proxy (necesario para rate-limit detrás de Nginx/Render/etc.) --- */
app.set('trust proxy', 1);
app.disable('x-powered-by');

/* --- Cabeceras de seguridad --- */
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

/* --- CORS: por defecto, mismo origen. Permitir uno externo si se configura. --- */
if (ALLOWED_ORIGIN) {
  app.use(cors({ origin: ALLOWED_ORIGIN.split(',').map(s => s.trim()), methods: ['GET', 'POST'] }));
}

/* --- Body parser con límite de tamaño (evita payloads enormes) --- */
app.use(express.json({ limit: '16kb' }));

/* --- Rate limiting general para la API --- */
const apiLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 min
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Demasiadas solicitudes. Intentá más tarde.' },
});
app.use('/api/', apiLimiter);

// Límite más estricto para acciones sensibles.
const sensitiveLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 20,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: 'Demasiados intentos. Esperá unos minutos.' },
});

/* ===================== RUTAS API ===================== */

// Listado de productos (sin datos sensibles).
app.get('/api/products', (req, res) => {
  const { PRODUCTS } = require('./catalog');
  res.json({ products: Object.values(PRODUCTS) });
});

/* --- Validación del carrito recibido --- */
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
      title: `${product.name} (Talle ${size})`,
      quantity: qty,
      unit_price: product.price, // PRECIO DEL SERVIDOR, no del cliente
      currency_id: 'ARS',
    });
  }

  return { lineItems, total };
}

// Checkout: crea una preferencia de pago en Mercado Pago.
app.post('/api/checkout', sensitiveLimiter, async (req, res) => {
  try {
    const { items } = req.body || {};
    const result = validateAndPrice(items);
    if (result.error) return res.status(400).json({ error: result.error });

    if (!MP_ACCESS_TOKEN) {
      // Sin credenciales no se puede cobrar de verdad.
      return res.status(503).json({
        error: 'El pago no está configurado todavía. Falta MP_ACCESS_TOKEN.',
      });
    }

    // SDK oficial de Mercado Pago (v2).
    const { MercadoPagoConfig, Preference } = require('mercadopago');
    const client = new MercadoPagoConfig({ accessToken: MP_ACCESS_TOKEN });
    const preference = new Preference(client);

    const externalRef = crypto.randomUUID();

    const mpResult = await preference.create({
      body: {
        items: result.lineItems,
        external_reference: externalRef,
        back_urls: {
          success: `${PUBLIC_BASE_URL}/?pago=exito`,
          failure: `${PUBLIC_BASE_URL}/?pago=error`,
          pending: `${PUBLIC_BASE_URL}/?pago=pendiente`,
        },
        auto_return: 'approved',
        notification_url: `${PUBLIC_BASE_URL}/api/webhook`,
        statement_descriptor: 'SHESHE',
      },
    });

    return res.json({
      id: mpResult.id,
      init_point: mpResult.init_point, // URL de pago de Mercado Pago
    });
  } catch (err) {
    console.error('[checkout] error:', err && err.message ? err.message : err);
    // No filtramos detalles internos al cliente.
    return res.status(502).json({ error: 'No se pudo iniciar el pago. Probá de nuevo.' });
  }
});

// Webhook de Mercado Pago: notificaciones de estado de pago.
app.post('/api/webhook', (req, res) => {
  // Verificación de firma (si está configurado el secret del webhook).
  if (MP_WEBHOOK_SECRET) {
    try {
      const signature = req.get('x-signature') || '';
      const requestId = req.get('x-request-id') || '';
      const parts = Object.fromEntries(
        signature.split(',').map(p => p.split('=').map(s => s.trim()))
      );
      const ts = parts.ts;
      const v1 = parts.v1;
      const dataId = (req.query['data.id'] || (req.body && req.body.data && req.body.data.id) || '').toString();

      const manifest = `id:${dataId};request-id:${requestId};ts:${ts};`;
      const hmac = crypto.createHmac('sha256', MP_WEBHOOK_SECRET).update(manifest).digest('hex');

      const valid = v1 && hmac.length === v1.length &&
        crypto.timingSafeEqual(Buffer.from(hmac), Buffer.from(v1));
      if (!valid) {
        console.warn('[webhook] firma inválida');
        return res.sendStatus(401);
      }
    } catch (e) {
      return res.sendStatus(401);
    }
  }

  // TODO: acá deberías confirmar el pago consultando la API de Mercado Pago
  // con el data.id y actualizar el pedido en tu base de datos.
  console.log('[webhook] notificación recibida:', req.body && req.body.type);
  return res.sendStatus(200);
});

// Contacto: validación y (placeholder) envío.
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

  // TODO: integrar envío real de email (ej. Nodemailer + SMTP, Resend, etc.).
  console.log('[contact] mensaje de', email);
  return res.json({ ok: true });
});

/* ===================== ARCHIVOS ESTÁTICOS ===================== */
const rootDir = path.join(__dirname, '..');
app.use(express.static(rootDir, {
  extensions: ['html'],
  setHeaders(res) {
    res.setHeader('X-Content-Type-Options', 'nosniff');
  },
}));

// Fallback al index para rutas no-API.
app.get('*', (req, res, next) => {
  if (req.path.startsWith('/api/')) return next();
  res.sendFile(path.join(rootDir, 'index.html'));
});

/* ===================== ARRANQUE ===================== */
app.listen(PORT, () => {
  console.log(`SHESHE escuchando en http://localhost:${PORT} (${NODE_ENV})`);
  if (!MP_ACCESS_TOKEN) {
    console.warn('⚠  MP_ACCESS_TOKEN no configurado: el checkout responderá 503 hasta que lo agregues en .env');
  }
});

module.exports = app;
