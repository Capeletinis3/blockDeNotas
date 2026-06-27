'use strict';

/*
 * Envío de emails con Nodemailer (SMTP).
 * Funciona con cualquier proveedor SMTP (Gmail, Brevo, Resend, Mailgun, etc.).
 *
 * Si no hay credenciales SMTP configuradas, las funciones NO fallan:
 * simplemente registran el mensaje en consola. Así el sitio sigue andando
 * aunque todavía no hayas configurado el correo.
 */

const nodemailer = require('nodemailer');

const {
  SMTP_HOST,
  SMTP_PORT = 587,
  SMTP_USER,
  SMTP_PASS,
  MAIL_FROM,
  MAIL_TO, // a dónde te llegan las notificaciones (tu casilla)
} = process.env;

const isConfigured = Boolean(SMTP_HOST && SMTP_USER && SMTP_PASS);

let transporter = null;
if (isConfigured) {
  transporter = nodemailer.createTransport({
    host: SMTP_HOST,
    port: Number(SMTP_PORT),
    secure: Number(SMTP_PORT) === 465, // 465 = SSL; 587 = STARTTLS
    auth: { user: SMTP_USER, pass: SMTP_PASS },
  });
}

const FROM = MAIL_FROM || SMTP_USER;
const TO = MAIL_TO || SMTP_USER;

// Escapa texto para insertarlo de forma segura en el HTML del email.
function esc(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

async function send(opts) {
  if (!transporter) {
    console.log('[email] (SMTP no configurado) se habría enviado:', opts.subject);
    return false;
  }
  try {
    await transporter.sendMail({ from: FROM, ...opts });
    return true;
  } catch (err) {
    console.error('[email] error al enviar:', err && err.message ? err.message : err);
    return false;
  }
}

// Notificación de consulta del formulario de contacto.
function sendContactNotification({ nombre, email, asunto, mensaje }) {
  return send({
    to: TO,
    replyTo: email,
    subject: `Nueva consulta de ${nombre}`,
    text: `Nombre: ${nombre}\nEmail: ${email}\nAsunto: ${asunto || '(sin asunto)'}\n\n${mensaje}`,
    html: `<h2>Nueva consulta web</h2>
      <p><strong>Nombre:</strong> ${esc(nombre)}</p>
      <p><strong>Email:</strong> ${esc(email)}</p>
      <p><strong>Asunto:</strong> ${esc(asunto || '(sin asunto)')}</p>
      <p><strong>Mensaje:</strong></p>
      <p>${esc(mensaje).replace(/\n/g, '<br>')}</p>`,
  });
}

// Notificación de pedido pagado (te llega a vos, la tienda).
function sendOrderPaidNotification(order) {
  const rows = order.items.map(it =>
    `<tr><td>${esc(it.name)}</td><td>${esc(it.size)}</td><td>${it.qty}</td>` +
    `<td>$${(it.unit_price * it.qty).toLocaleString('es-AR')}</td></tr>`
  ).join('');

  return send({
    to: TO,
    subject: `🛍 Nuevo pedido pagado — $${order.total.toLocaleString('es-AR')}`,
    html: `<h2>Pedido pagado</h2>
      <p><strong>Referencia:</strong> ${esc(order.ref)}</p>
      <p><strong>Pago Mercado Pago:</strong> ${esc(order.payment_id || '-')}</p>
      <p><strong>Cliente:</strong> ${esc(order.payer_email || '-')}</p>
      <table border="1" cellpadding="6" cellspacing="0">
        <thead><tr><th>Producto</th><th>Talle</th><th>Cant.</th><th>Subtotal</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
      <p><strong>Total: $${order.total.toLocaleString('es-AR')}</strong></p>`,
  });
}

module.exports = { isConfigured, sendContactNotification, sendOrderPaidNotification };
