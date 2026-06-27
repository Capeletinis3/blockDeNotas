/* ===========================================================
   SHESHE — Lógica del front-end
   - Sin código inline (compatible con Content-Security-Policy estricta)
   - Renderizado del carrito con escapado anti-XSS
   - Persistencia en localStorage
   - Checkout contra el backend (precios autoritativos en el servidor)
   =========================================================== */
'use strict';

(function () {
  /* ---- CONFIG ---- */
  // URL base de la API. Si el front se sirve desde el mismo origen que el
  // backend, dejar '' (mismo origen). Si no, poner la URL del servidor.
  const API_BASE = '';
  const CART_KEY = 'sheshe_cart_v1';
  const MAX_QTY_PER_ITEM = 10;

  /* ---- ESTADO ---- */
  let cart = loadCart();
  let currentProduct = null;
  let lastFocusedEl = null;

  /* ---- UTILIDADES ---- */

  // Escapa texto para insertarlo de forma segura como HTML (anti-XSS).
  function escapeHTML(value) {
    return String(value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function formatPrice(n) {
    return '$' + Number(n).toLocaleString('es-AR');
  }

  function $(id) { return document.getElementById(id); }

  function loadCart() {
    try {
      const raw = localStorage.getItem(CART_KEY);
      if (!raw) return [];
      const data = JSON.parse(raw);
      if (!Array.isArray(data)) return [];
      // Saneamos: solo aceptamos la forma esperada y tipos válidos.
      return data
        .filter(i => i && typeof i.id === 'string' && typeof i.name === 'string')
        .map(i => ({
          id: String(i.id),
          name: String(i.name),
          price: Number(i.price) || 0,
          size: String(i.size || 'M'),
          grad: /^grad-[1-6]$/.test(i.grad) ? i.grad : 'grad-1',
          qty: Math.min(MAX_QTY_PER_ITEM, Math.max(1, parseInt(i.qty, 10) || 1)),
        }));
    } catch (e) {
      return [];
    }
  }

  function saveCart() {
    try {
      localStorage.setItem(CART_KEY, JSON.stringify(cart));
    } catch (e) { /* almacenamiento lleno o deshabilitado: se ignora */ }
  }

  /* ---- NAVBAR scroll ---- */
  window.addEventListener('scroll', () => {
    $('navbar').classList.toggle('scrolled', window.scrollY > 60);
  }, { passive: true });

  /* ---- MENÚ MÓVIL ---- */
  const menuBtn = $('menuBtn');
  const mobileMenu = $('mobileMenu');
  function setMobileMenu(open) {
    mobileMenu.hidden = !open;
    menuBtn.setAttribute('aria-expanded', String(open));
    menuBtn.setAttribute('aria-label', open ? 'Cerrar menú' : 'Abrir menú');
  }
  menuBtn.addEventListener('click', () => setMobileMenu(mobileMenu.hidden));
  mobileMenu.querySelectorAll('[data-close-menu]').forEach(a => {
    a.addEventListener('click', () => setMobileMenu(false));
  });

  /* ---- FILTROS TIENDA ---- */
  document.querySelectorAll('.filter-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.filter-btn').forEach(b => {
        b.classList.remove('active');
        b.setAttribute('aria-pressed', 'false');
      });
      btn.classList.add('active');
      btn.setAttribute('aria-pressed', 'true');
      const filter = btn.dataset.filter;
      document.querySelectorAll('.product-card').forEach(card => {
        const show = filter === 'all' || card.dataset.category === filter;
        card.style.display = show ? '' : 'none';
      });
    });
  });

  /* ---- LECTURA DE PRODUCTO DESDE LA TARJETA ---- */
  function productFromCard(card) {
    return {
      id: card.dataset.id,
      name: card.dataset.name,
      price: parseInt(card.dataset.price, 10),
      cat: card.dataset.cat,
      desc: card.dataset.desc,
      grad: card.dataset.grad,
    };
  }

  /* ---- MODAL PRODUCTO ---- */
  const modalOverlay = $('modalOverlay');

  function openModal(card) {
    const p = productFromCard(card);
    currentProduct = p;
    lastFocusedEl = document.activeElement;

    $('modalCat').textContent = p.cat;
    $('modalName').textContent = p.name;
    $('modalPrice').textContent = formatPrice(p.price);
    $('modalDesc').textContent = p.desc;

    const img = $('modalImage');
    img.className = 'modal__image ' + (/^grad-[1-6]$/.test(p.grad) ? p.grad : 'grad-1');
    // SVG estático y controlado (no proviene de datos de usuario).
    img.innerHTML = '<svg width="80" height="130" viewBox="0 0 80 130" fill="none" opacity="0.3" aria-hidden="true">' +
      '<ellipse cx="40" cy="22" rx="14" ry="16" stroke="#9A8472" stroke-width="1.2"/>' +
      '<path d="M26 38 C18 65 16 95 18 130 L62 130 C64 95 62 65 54 38" stroke="#9A8472" stroke-width="1.2" fill="none"/></svg>';

    // Reset de talle por defecto (M).
    document.querySelectorAll('#modalSizes .size-opt').forEach(s => {
      const isM = s.dataset.size === 'M';
      s.classList.toggle('selected', isM);
      s.setAttribute('aria-pressed', String(isM));
    });

    modalOverlay.classList.add('open');
    document.body.classList.add('no-scroll');
    $('modalCloseBtn').focus();
  }

  function closeModal() {
    modalOverlay.classList.remove('open');
    document.body.classList.remove('no-scroll');
    if (lastFocusedEl) lastFocusedEl.focus();
  }

  document.querySelectorAll('.product-card').forEach(card => {
    const openBtn = card.querySelector('[data-open-modal]');
    if (openBtn) openBtn.addEventListener('click', () => openModal(card));

    const addBtn = card.querySelector('[data-add-to-cart]');
    if (addBtn) addBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const p = productFromCard(card);
      addToCartDirect(p, 'M');
    });
  });

  modalOverlay.addEventListener('click', (e) => {
    if (e.target === modalOverlay) closeModal();
  });
  $('modalCloseBtn').addEventListener('click', closeModal);

  document.querySelectorAll('#modalSizes .size-opt').forEach(opt => {
    opt.addEventListener('click', () => {
      document.querySelectorAll('#modalSizes .size-opt').forEach(s => {
        s.classList.remove('selected');
        s.setAttribute('aria-pressed', 'false');
      });
      opt.classList.add('selected');
      opt.setAttribute('aria-pressed', 'true');
    });
  });

  $('modalAddBtn').addEventListener('click', () => {
    if (!currentProduct) return;
    const selected = document.querySelector('#modalSizes .size-opt.selected');
    const size = selected ? selected.dataset.size : 'M';
    addToCartDirect(currentProduct, size);
    closeModal();
  });

  /* ---- CARRITO ---- */
  const cartOverlay = $('cartOverlay');
  const cartSidebar = $('cartSidebar');

  function openCart() {
    lastFocusedEl = document.activeElement;
    cartOverlay.classList.add('open');
    cartSidebar.classList.add('open');
    cartSidebar.setAttribute('aria-hidden', 'false');
    document.body.classList.add('no-scroll');
    $('cartCloseBtn').focus();
  }
  function closeCart() {
    cartOverlay.classList.remove('open');
    cartSidebar.classList.remove('open');
    cartSidebar.setAttribute('aria-hidden', 'true');
    document.body.classList.remove('no-scroll');
    if (lastFocusedEl) lastFocusedEl.focus();
  }
  $('cartBtn').addEventListener('click', openCart);
  $('cartCloseBtn').addEventListener('click', closeCart);
  cartOverlay.addEventListener('click', closeCart);
  document.querySelectorAll('[data-close-cart]').forEach(el => {
    el.addEventListener('click', closeCart);
  });

  function addToCartDirect(product, size) {
    const existing = cart.find(i => i.id === product.id && i.size === size);
    if (existing) {
      existing.qty = Math.min(MAX_QTY_PER_ITEM, existing.qty + 1);
    } else {
      cart.push({
        id: product.id,
        name: product.name,
        price: product.price,
        size: size,
        qty: 1,
        grad: product.grad,
      });
    }
    saveCart();
    updateCartUI();
    showToast(product.name + ' agregado al carrito');
  }

  function changeQty(idx, delta) {
    if (!cart[idx]) return;
    cart[idx].qty += delta;
    if (cart[idx].qty <= 0) cart.splice(idx, 1);
    else if (cart[idx].qty > MAX_QTY_PER_ITEM) cart[idx].qty = MAX_QTY_PER_ITEM;
    saveCart();
    updateCartUI();
  }
  function removeFromCart(idx) {
    cart.splice(idx, 1);
    saveCart();
    updateCartUI();
  }

  function updateCartUI() {
    const total = cart.reduce((s, i) => s + i.price * i.qty, 0);
    const count = cart.reduce((s, i) => s + i.qty, 0);
    const countEl = $('cartCount');
    countEl.textContent = count;
    countEl.classList.toggle('visible', count > 0);
    countEl.setAttribute('aria-hidden', count > 0 ? 'false' : 'true');
    $('cartTotal').textContent = formatPrice(total);

    const itemsEl = $('cartItems');
    const emptyEl = $('cartEmpty');

    if (cart.length === 0) {
      emptyEl.style.display = 'block';
      itemsEl.innerHTML = '';
      itemsEl.appendChild(emptyEl);
      return;
    }
    emptyEl.style.display = 'none';

    // Construcción del DOM con escapado de todos los valores dinámicos.
    itemsEl.innerHTML = cart.map((item, idx) => {
      const name = escapeHTML(item.name);
      const size = escapeHTML(item.size);
      const grad = /^grad-[1-6]$/.test(item.grad) ? item.grad : 'grad-1';
      const lineTotal = formatPrice(item.price * item.qty);
      return (
        '<div class="cart-item">' +
          '<div class="cart-item__img"><div class="cart-item__img-bg ' + grad + '"></div></div>' +
          '<div>' +
            '<p class="cart-item__name">' + name + '</p>' +
            '<p class="cart-item__size">Talle: ' + size + '</p>' +
            '<div class="cart-item__qty">' +
              '<button class="qty-btn" type="button" data-qty="-1" data-idx="' + idx + '" aria-label="Quitar una unidad">−</button>' +
              '<span class="qty-num">' + item.qty + '</span>' +
              '<button class="qty-btn" type="button" data-qty="1" data-idx="' + idx + '" aria-label="Agregar una unidad">+</button>' +
            '</div>' +
            '<p class="cart-item__line">' + lineTotal + '</p>' +
          '</div>' +
          '<button class="cart-item__remove" type="button" data-remove="' + idx + '" aria-label="Eliminar ' + name + '">✕</button>' +
        '</div>'
      );
    }).join('');
  }

  // Delegación de eventos para los botones del carrito (creados dinámicamente).
  $('cartItems').addEventListener('click', (e) => {
    const qtyBtn = e.target.closest('[data-qty]');
    if (qtyBtn) {
      changeQty(parseInt(qtyBtn.dataset.idx, 10), parseInt(qtyBtn.dataset.qty, 10));
      return;
    }
    const rmBtn = e.target.closest('[data-remove]');
    if (rmBtn) removeFromCart(parseInt(rmBtn.dataset.remove, 10));
  });

  /* ---- CHECKOUT (contra el backend) ---- */
  const checkoutBtn = $('checkoutBtn');
  checkoutBtn.addEventListener('click', async () => {
    if (cart.length === 0) { showToast('Tu carrito está vacío'); return; }

    checkoutBtn.disabled = true;
    const originalText = checkoutBtn.textContent;
    checkoutBtn.textContent = 'Procesando...';

    try {
      // Solo se envían id, cantidad y talle. El servidor calcula los precios.
      const payload = {
        items: cart.map(i => ({ id: i.id, qty: i.qty, size: i.size })),
      };
      const res = await fetch(API_BASE + '/api/checkout', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });

      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        throw new Error(err.error || 'No se pudo iniciar el pago');
      }

      const data = await res.json();
      if (data && typeof data.init_point === 'string' && /^https:\/\//.test(data.init_point)) {
        // Redirección a Mercado Pago (Checkout Pro).
        window.location.assign(data.init_point);
      } else {
        throw new Error('Respuesta de pago inválida');
      }
    } catch (err) {
      showToast(err.message || 'Error al procesar el pago');
      checkoutBtn.disabled = false;
      checkoutBtn.textContent = originalText;
    }
  });

  /* ---- FORMULARIO DE CONTACTO ---- */
  const form = $('contactForm');
  const mensaje = $('mensaje');
  const mensajeCount = $('mensaje-count');
  const MAX_MSG = 1000;

  if (mensaje) {
    const updateCount = () => {
      const len = mensaje.value.length;
      mensajeCount.textContent = len + ' / ' + MAX_MSG;
      mensajeCount.classList.toggle('form-char-count--limit', len >= MAX_MSG);
    };
    mensaje.addEventListener('input', updateCount);
    updateCount();
  }

  function setError(id, msg) {
    const el = $(id + '-error');
    if (el) el.textContent = msg || '';
    const field = $(id);
    if (field) field.classList.toggle('form-input--error', Boolean(msg));
  }

  function validateField(field) {
    const id = field.id;
    const value = field.value.trim();

    if (id === 'nombre') {
      if (value.length < 2) { setError(id, 'Ingresá tu nombre (mínimo 2 caracteres).'); return false; }
    }
    if (id === 'email') {
      // Validación de formato razonable (la verificación real es del lado del servidor).
      const ok = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(value);
      if (!ok) { setError(id, 'Ingresá un email válido.'); return false; }
    }
    if (id === 'mensaje') {
      if (value.length < 10) { setError(id, 'El mensaje debe tener al menos 10 caracteres.'); return false; }
    }
    setError(id, '');
    return true;
  }

  if (form) {
    ['nombre', 'email', 'mensaje'].forEach(id => {
      const f = $(id);
      if (f) f.addEventListener('blur', () => validateField(f));
    });

    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      const fields = ['nombre', 'email', 'mensaje'].map(id => $(id));
      const valid = fields.map(validateField).every(Boolean);
      if (!valid) {
        const firstInvalid = fields.find(f => f.classList.contains('form-input--error'));
        if (firstInvalid) firstInvalid.focus();
        return;
      }

      const submitBtn = form.querySelector('[type="submit"]');
      submitBtn.disabled = true;

      try {
        const res = await fetch(API_BASE + '/api/contact', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            nombre: $('nombre').value.trim(),
            email: $('email').value.trim(),
            asunto: $('asunto').value.trim(),
            mensaje: $('mensaje').value.trim(),
          }),
        });
        if (!res.ok) throw new Error('No se pudo enviar el mensaje');
        showToast('¡Mensaje enviado! Te respondemos pronto.');
        form.reset();
        if (mensaje) mensajeCount.textContent = '0 / ' + MAX_MSG;
      } catch (err) {
        // Si el backend no está disponible, igual damos respuesta al usuario.
        showToast('No pudimos enviar el mensaje. Probá más tarde.');
      } finally {
        submitBtn.disabled = false;
      }
    });
  }

  /* ---- TOAST ---- */
  let toastTimer = null;
  function showToast(msg) {
    const t = $('toast');
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.remove('show'), 2800);
  }

  /* ---- TECLA ESC: cierra modal / carrito / menú ---- */
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    if (modalOverlay.classList.contains('open')) closeModal();
    else if (cartSidebar.classList.contains('open')) closeCart();
    else if (!mobileMenu.hidden) setMobileMenu(false);
  });

  /* ---- ANIMACIÓN FADE-UP al scroll ---- */
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const animatable = document.querySelectorAll('.product-card, .look-item, .contact-info__detail');
  if (reduceMotion) {
    animatable.forEach(el => { el.style.opacity = '1'; });
  } else {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          entry.target.style.opacity = '1';
          entry.target.style.transform = 'translateY(0)';
          observer.unobserve(entry.target);
        }
      });
    }, { threshold: 0.1 });
    animatable.forEach(el => {
      el.style.opacity = '0';
      el.style.transform = 'translateY(24px)';
      el.style.transition = 'opacity 0.6s ease, transform 0.6s ease';
      observer.observe(el);
    });
  }

  /* ---- INICIALIZACIÓN ---- */
  updateCartUI();
})();
