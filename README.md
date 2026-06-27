# SHESHE — Tienda de ropa de noche

E-commerce con front-end estático y un backend seguro en Node.js que:

- calcula los precios del lado del servidor (no confía en el navegador),
- cobra con **Mercado Pago** (Checkout Pro),
- **guarda los pedidos** en una base de datos y confirma el pago vía webhook,
- **envía emails** (consultas de contacto y aviso de pedido pagado).

## ¿Por qué hay un backend?

Una tienda **no puede ser segura solo con HTML/CSS/JS** en el navegador:
cualquiera puede abrir las herramientas de desarrollo y cambiar un precio
antes de pagar. Por eso:

- El **catálogo y los precios viven en el servidor** (`server/catalog.js`).
- El navegador solo manda **id + cantidad + talle**; el servidor calcula el total.
- El **token secreto de Mercado Pago nunca llega al navegador**.

## Requisitos

- Node.js 18 o superior.
- Cuenta de [Mercado Pago Developers](https://www.mercadopago.com.ar/developers).
- (Opcional) un proveedor SMTP para enviar emails.

## Puesta en marcha (local)

```bash
npm install
cp .env.example .env     # completar MP_ACCESS_TOKEN (token TEST- para probar)
npm start                # http://localhost:3000
```

Sin `MP_ACCESS_TOKEN`, el sitio funciona completo pero "Finalizar compra"
avisa que el pago no está configurado (no rompe nada).

## Estructura

```
.
├── index.html        # Front-end (sin JS inline, compatible con CSP estricta)
├── styles.css
├── app.js            # Lógica del cliente (carrito, validación, checkout)
├── package.json
├── render.yaml       # Deploy en Render (Blueprint)
├── Procfile          # Deploy en Railway/Heroku
├── .env.example      # Plantilla de variables (copiar a .env)
└── server/
    ├── server.js     # API + servidor estático + seguridad
    ├── catalog.js    # Precios autoritativos (fuente de verdad)
    ├── db.js         # Base de datos de pedidos (SQLite)
    └── email.js      # Envío de emails (Nodemailer / SMTP)
```

## Base de datos (pedidos)

Usa **SQLite** (un archivo, sin instalar nada). Se crea solo en `./data/sheshe.db`.

- En `/api/checkout` se guarda el pedido como `pending`.
- El webhook de Mercado Pago consulta el pago real y lo marca
  `approved` / `rejected` / etc.
- Cuando un pedido queda `approved`, se envía el email de aviso.

Ver pedidos (panel mínimo, requiere `ADMIN_TOKEN`):

```bash
curl -H "x-admin-token: TU_ADMIN_TOKEN" http://localhost:3000/api/admin/orders
```

## Emails

Configurá las variables `SMTP_*`, `MAIL_FROM` y `MAIL_TO` en el `.env`.
Sirve cualquier proveedor SMTP (Gmail, Brevo, Mailgun, Resend…). Si lo dejás
vacío, los emails se registran en consola y el sitio sigue funcionando.

## Webhook de Mercado Pago

En el panel de Mercado Pago configurá la notificación a:

```
https://TU-DOMINIO/api/webhook
```

y poné la clave secreta en `MP_WEBHOOK_SECRET` (el servidor valida la firma
`x-signature`). En local, el webhook se omite porque la URL no es pública.

## Deploy

### Render (recomendado, tiene plan free con HTTPS)

1. Subí el repo a GitHub.
2. En Render: **New → Blueprint**, elegí este repo (usa `render.yaml`).
3. Cargá las variables secretas en el panel: `MP_ACCESS_TOKEN`,
   `PUBLIC_BASE_URL` (la URL que te da Render, ej.
   `https://sheshe-store.onrender.com`) y, si querés, las de SMTP.
4. Volvé a desplegar. Render te da **HTTPS** automático.

> El plan free no tiene disco persistente: la base SQLite se reinicia en
> cada redeploy. Para conservar pedidos en producción, agregá un disco
> persistente (plan pago) montado en `/data` con `DB_PATH=/data/sheshe.db`,
> o migrá a Postgres.

### Railway / Heroku

Usan el `Procfile` (`web: npm start`). Cargá las mismas variables de entorno.

## Medidas de seguridad incluidas

| Riesgo | Mitigación |
|---|---|
| Manipulación de precios | Precios calculados en el servidor desde el catálogo |
| XSS | CSP estricta, sin JS inline, escapado de HTML |
| Token de pago expuesto | El Access Token solo se usa en el backend |
| Cabeceras inseguras | `helmet` (CSP, HSTS, nosniff, etc.) |
| Abuso / fuerza bruta | `express-rate-limit` |
| Payloads gigantes | Límite de tamaño del body (16 kb) |
| Datos inválidos | Validación de ítems, cantidades, talles y formulario |
| Webhooks falsos | Verificación de firma `x-signature` + reconsulta del pago |
| Pedidos no confirmados | El pago se reconfirma contra la API de MP en el webhook |
| Secretos en el repo | `.env` y `data/` ignorados por git |
