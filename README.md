# SHESHE — Tienda de ropa de noche

Sitio de e-commerce con front-end estático y un backend seguro en Node.js
que procesa pagos con **Mercado Pago** (Checkout Pro).

## ¿Por qué hay un backend?

Una tienda **no puede ser segura solo con HTML/CSS/JS en el navegador**.
Cualquier persona puede abrir las herramientas de desarrollo y cambiar un
precio antes de "pagar". Por eso:

- El **catálogo y los precios viven en el servidor** (`server/catalog.js`).
- El navegador solo manda **id + cantidad + talle**. El servidor calcula
  el total con sus propios precios. El cliente nunca decide cuánto se cobra.
- El **token secreto de Mercado Pago nunca llega al navegador**.

## Requisitos

- Node.js 18 o superior.
- Una cuenta de [Mercado Pago Developers](https://www.mercadopago.com.ar/developers).

## Puesta en marcha

```bash
# 1. Instalar dependencias
npm install

# 2. Configurar variables de entorno
cp .env.example .env
#   y completar MP_ACCESS_TOKEN (usá el token TEST- para probar)

# 3. Levantar el servidor (sirve el sitio + la API)
npm start
```

Abrí http://localhost:3000

> Mientras no cargues `MP_ACCESS_TOKEN`, el sitio funciona completo pero el
> botón "Finalizar compra" responde con un aviso de que el pago no está
> configurado (no rompe nada).

## Estructura

```
.
├── index.html        # Front-end (sin JS inline, compatible con CSP estricta)
├── styles.css        # Estilos
├── app.js            # Lógica del cliente (carrito, validación, checkout)
├── package.json
├── .env.example      # Plantilla de variables (copiar a .env)
└── server/
    ├── server.js     # API + servidor estático + seguridad
    └── catalog.js    # Precios autoritativos (fuente de verdad)
```

## Medidas de seguridad incluidas

| Riesgo | Mitigación |
|---|---|
| Manipulación de precios | Precios calculados en el servidor desde el catálogo |
| XSS | CSP estricta, sin JS inline, escapado de HTML en el carrito |
| Token de pago expuesto | El Access Token solo se usa en el backend |
| Cabeceras inseguras | `helmet` (CSP, HSTS, nosniff, etc.) |
| Abuso / fuerza bruta | `express-rate-limit` (límite general y para checkout/contacto) |
| Payloads gigantes | Límite de tamaño del body (16 kb) |
| Datos inválidos | Validación de ítems, cantidades, talles y formulario |
| Webhooks falsos | Verificación de firma `x-signature` de Mercado Pago |
| Secretos en el repo | `.env` ignorado por git; solo se versiona `.env.example` |

## Lo que todavía conviene agregar para producción

- **Base de datos** para guardar pedidos y confirmar pagos desde el webhook.
- **Envío real de emails** en `/api/contact` (Nodemailer, Resend, etc.).
- **Control de stock** (que el catálogo refleje disponibilidad real).
- Servir todo por **HTTPS** (la HSTS ya queda activa en producción).
- Páginas legales reales (Términos, Privacidad, Cookies).
