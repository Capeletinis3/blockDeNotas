/*
  Emulación aproximada del diseño de interfaces de Roblox para la vista previa.
  Recibe el árbol volcado por tests/dump.luau y lo dibuja con elementos absolutos.

  Implementa: Size/Position/AnchorPoint (UDim2), AutomaticSize, Visible, ZIndex (Sibling),
  ClipsDescendants, UIPadding, UIListLayout (dirección, separación, alineaciones, Wraps),
  UIFlexItem (Fill/Grow/Shrink), UIGridLayout, UISizeConstraint, UIAspectRatioConstraint,
  UIScale, UICorner, UIStroke, UIGradient, ScrollingFrame (lienzo automático y posición),
  texto (TextSize, LineHeight, alineaciones, ajuste, truncado, RichText básico) y TextBox.

  NO es el motor de Roblox: sirve para comparar distribución, proporciones, colores y jerarquía.
  La fuente es Inter (sustituto de Builder Sans) y lo 3D se dibuja como un recuadro marcado.
*/
(function () {
  'use strict';
  const GUI = new Set(['Frame', 'TextLabel', 'TextButton', 'TextBox', 'ImageLabel', 'ImageButton', 'ScrollingFrame', 'ViewportFrame', 'CanvasGroup', 'VideoFrame']);
  const TEXT = new Set(['TextLabel', 'TextButton', 'TextBox']);
  const WEIGHT = { Thin: 100, ExtraLight: 200, Light: 300, Regular: 400, Medium: 500, SemiBold: 600, Bold: 700, ExtraBold: 800, Heavy: 900 };

  const val = (n, k, d) => (n.p && n.p[k] !== undefined ? n.p[k] : d);
  const u2 = (v, d) => (v && v._t === 'u2' ? v.v : d || [0, 0, 0, 0]);
  const ud = (v, d) => (v && v._t === 'u' ? v.v : d || [0, 0]);
  const v2 = (v, d) => (v && v._t === 'v2' ? v.v : d || [0, 0]);
  const en = (v, d) => (v && v._t === 'e' ? v.v : d);
  const col = (v, d) => (v && v._t === 'c' ? v.h : d);
  function rgba(hex, transp) {
    const n = parseInt(hex.slice(1), 16);
    return 'rgba(' + ((n >> 16) & 255) + ',' + ((n >> 8) & 255) + ',' + (n & 255) + ',' + Math.max(0, Math.min(1, 1 - (transp || 0))).toFixed(3) + ')';
  }
  const kids = (n) => (Array.isArray(n.k) ? n.k : []);
  const child = (n, cls) => kids(n).find((c) => c.c === cls);
  const isGui = (n) => GUI.has(n.c);
  const visible = (n) => val(n, 'Visible', true) !== false;

  /* ---------- texto ---------- */
  const meas = document.createElement('div');
  meas.style.cssText = 'position:absolute;left:-99999px;top:0;visibility:hidden;font-family:Inter,sans-serif';
  document.body.appendChild(meas);
  const cache = new Map();
  function esc(s) { return String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c])); }
  function richToHtml(s) {
    // Subconjunto de RichText de Roblox: font (color, size, weight, transparency), b, i, u, s, br, uc, sc.
    let out = '';
    const re = /<(\/?)(font|b|i|u|s|br|uc|uppercase|sc|smallcaps|stroke|mark)([^>]*)>/gi;
    let last = 0; let m;
    const stack = [];
    while ((m = re.exec(s))) {
      out += esc(s.slice(last, m.index)).replace(/&amp;(lt|gt|quot|apos|amp);/g, '&$1;');
      last = re.lastIndex;
      const close = m[1] === '/'; const tag = m[2].toLowerCase(); const attrs = m[3] || '';
      if (tag === 'br') { out += '<br>'; continue; }
      if (close) { const t = stack.pop(); out += t ? '</span>' : ''; continue; }
      let style = '';
      if (tag === 'b') style = 'font-weight:700';
      else if (tag === 'i') style = 'font-style:italic';
      else if (tag === 'u') style = 'text-decoration:underline';
      else if (tag === 's') style = 'text-decoration:line-through';
      else if (tag === 'uc' || tag === 'uppercase') style = 'text-transform:uppercase';
      else if (tag === 'sc' || tag === 'smallcaps') style = 'font-variant:small-caps';
      else if (tag === 'font') {
        const a = {}; attrs.replace(/(\w+)\s*=\s*"([^"]*)"/g, (_, k, v) => { a[k.toLowerCase()] = v; });
        if (a.color) style += 'color:' + (a.color.startsWith('#') ? a.color : 'rgb(' + a.color + ')') + ';';
        if (a.size) style += 'font-size:' + a.size + 'px;';
        if (a.weight) style += 'font-weight:' + (WEIGHT[a.weight] || ({ bold: 700, heavy: 900, medium: 500, regular: 400, light: 300, semibold: 600, extrabold: 800 }[a.weight.toLowerCase()]) || a.weight) + ';';
        if (a.transparency) style += 'opacity:' + (1 - parseFloat(a.transparency)) + ';';
      }
      stack.push(tag); out += '<span style="' + style + '">';
    }
    out += esc(s.slice(last)).replace(/&amp;(lt|gt|quot|apos|amp);/g, '&$1;');
    while (stack.pop()) out += '</span>';
    return out;
  }
  function textInfo(n) {
    let text = val(n, 'Text', '');
    let placeholder = false;
    if (n.c === 'TextBox' && text === '') { text = val(n, 'PlaceholderText', ''); placeholder = true; }
    const size = val(n, 'TextSize', 14);
    const f = val(n, 'FontFace', null);
    const weight = f ? WEIGHT[f.weight] || 400 : 400;
    const italic = f && f.style === 'Italic';
    const lh = val(n, 'LineHeight', 1);
    const rich = val(n, 'RichText', false) && !placeholder;
    const html = rich ? richToHtml(text) : esc(text);
    return { text, html, size, weight, italic, lh, placeholder, wrap: !!val(n, 'TextWrapped', false), truncate: en(val(n, 'TextTruncate'), 'None') === 'AtEnd' };
  }
  function measureText(t, wrapW) {
    if (t.text === '') return { w: 0, h: 0 };
    const key = [t.html, t.size, t.weight, t.italic, t.lh, wrapW == null ? 'n' : Math.round(wrapW)].join('|');
    if (cache.has(key)) return cache.get(key);
    meas.style.fontSize = t.size + 'px';
    meas.style.fontWeight = t.weight;
    meas.style.fontStyle = t.italic ? 'italic' : 'normal';
    meas.style.lineHeight = (t.size * t.lh) + 'px';
    if (wrapW == null) { meas.style.whiteSpace = 'pre'; meas.style.width = 'max-content'; }
    else { meas.style.whiteSpace = 'pre-wrap'; meas.style.width = Math.max(1, wrapW) + 'px'; meas.style.overflowWrap = 'break-word'; }
    meas.innerHTML = t.html;
    const r = { w: Math.ceil(wrapW == null ? meas.scrollWidth : Math.min(wrapW, maxLineWidth())), h: Math.ceil(meas.scrollHeight) };
    cache.set(key, r);
    return r;
  }
  function maxLineWidth() {
    const range = document.createRange(); range.selectNodeContents(meas);
    const rects = range.getClientRects(); let mx = 0; const base = meas.getBoundingClientRect().left;
    for (const r of rects) mx = Math.max(mx, r.right - base);
    return mx;
  }

  /* ---------- tamaño ---------- */
  function padding(n, w, h) {
    const p = child(n, 'UIPadding');
    if (!p) return { t: 0, r: 0, b: 0, l: 0 };
    const f = (k, base) => { const x = ud(val(p, k)); return x[0] * base + x[1]; };
    return { t: f('PaddingTop', h), r: f('PaddingRight', w), b: f('PaddingBottom', h), l: f('PaddingLeft', w) };
  }
  function constrain(n, w, h) {
    const sc = child(n, 'UISizeConstraint');
    if (sc) {
      const mn = v2(val(sc, 'MinSize'), [0, 0]); const mx = v2(val(sc, 'MaxSize'), [Infinity, Infinity]);
      w = Math.max(mn[0], Math.min(mx[0] == null ? Infinity : mx[0], w));
      h = Math.max(mn[1], Math.min(mx[1] == null ? Infinity : mx[1], h));
    }
    const ar = child(n, 'UIAspectRatioConstraint');
    if (ar) {
      const ratio = val(ar, 'AspectRatio', 1); const dom = en(val(ar, 'DominantAxis'), 'Width');
      if (dom === 'Width') h = w / ratio; else w = h * ratio;
    }
    return [w, h];
  }
  function baseSize(n, pw, ph) {
    const s = u2(val(n, 'Size'));
    return [s[0] * pw + s[1], s[2] * ph + s[3]];
  }
  // Mide un nodo: devuelve [w, h] con AutomaticSize. fw/fh fuerzan un eje (flex o celda de grilla).
  function measure(n, pw, ph, fw, fh) {
    let [w, h] = baseSize(n, pw, ph);
    if (fw != null) w = fw; if (fh != null) h = fh;
    const auto = en(val(n, 'AutomaticSize'), 'None');
    const ax = (auto === 'X' || auto === 'XY') && fw == null, ay = (auto === 'Y' || auto === 'XY') && fh == null;
    if (ax || ay) {
      const pad = padding(n, w, h);
      const cw = Math.max(0, w - pad.l - pad.r), ch = Math.max(0, h - pad.t - pad.b);
      const cs = contentSize(n, cw, ch, ax, ay);
      if (ax) w = Math.max(w, cs[0] + pad.l + pad.r);
      if (ay) h = Math.max(h, cs[1] + pad.t + pad.b);
    }
    return constrain(n, w, h);
  }
  function contentSize(n, cw, ch, ax, ay) {
    let w = 0, h = 0;
    if (TEXT.has(n.c)) {
      const t = textInfo(n);
      const r = measureText(t, t.wrap && !ax ? cw : null);
      w = r.w; h = r.h;
    }
    // Un ScrollingFrame con AutomaticSize crece con su contenido (Roblox lo hace; el tope lo pone un UISizeConstraint).
    if (n.c === 'ScrollingFrame' && !ax && !ay) return [w, h];
    const lay = layoutOf(n);
    if (lay) {
      const r = lay.c === 'UIGridLayout' ? gridLayout(n, lay, ax ? 0 : cw, ch, null) : listLayout(n, lay, ax ? 0 : cw, ch, null, ax);
      w = Math.max(w, r[0]); h = Math.max(h, r[1]);
    } else {
      for (const c of kids(n)) {
        if (!isGui(c) || !visible(c)) continue;
        const [cw2, ch2] = measure(c, ax ? 0 : cw, ay ? 0 : ch);
        const pos = u2(val(c, 'Position')); const ap = v2(val(c, 'AnchorPoint'));
        const x = pos[0] * cw + pos[1] - ap[0] * cw2, y = pos[2] * ch + pos[3] - ap[1] * ch2;
        w = Math.max(w, x + cw2); h = Math.max(h, y + ch2);
      }
    }
    return [w, h];
  }
  function layoutOf(n) { return kids(n).find((c) => c.c === 'UIListLayout' || c.c === 'UIGridLayout'); }
  function sorted(n) {
    return kids(n).map((c, i) => [c, i]).filter(([c]) => isGui(c) && visible(c))
      .sort((a, b) => (val(a[0], 'LayoutOrder', 0) - val(b[0], 'LayoutOrder', 0)) || (a[1] - b[1])).map((x) => x[0]);
  }
  function flexOf(c, lay, horizontal) {
    const fi = child(c, 'UIFlexItem');
    if (fi) {
      const mode = en(val(fi, 'FlexMode'), 'None');
      if (mode === 'Fill') return { grow: 1, shrink: 1 };
      if (mode === 'Grow') return { grow: val(fi, 'GrowRatio', 1), shrink: 0 };
      if (mode === 'Shrink') return { grow: 0, shrink: val(fi, 'ShrinkRatio', 1) };
      if (mode === 'Custom') return { grow: val(fi, 'GrowRatio', 0), shrink: val(fi, 'ShrinkRatio', 0) };
    }
    const lf = en(val(lay, horizontal ? 'HorizontalFlex' : 'VerticalFlex'), 'None');
    if (lf === 'Fill') return { grow: 1, shrink: 1 };
    return null;
  }
  // Distribución de UIListLayout. place(c, x, y, w, h) si se está ubicando; null si solo se mide.
  function listLayout(n, lay, cw, ch, place, measuringX) {
    const horizontal = en(val(lay, 'FillDirection'), 'Vertical') === 'Horizontal';
    const gapU = ud(val(lay, 'Padding')); const gap = gapU[0] * (horizontal ? cw : ch) + gapU[1];
    const ha = en(val(lay, 'HorizontalAlignment'), 'Left'), va = en(val(lay, 'VerticalAlignment'), 'Top');
    const wraps = !!val(lay, 'Wraps', false);
    const items = sorted(n).map((c) => ({ c, s: measure(c, cw, ch) }));
    if (!items.length) return [0, 0];
    // Flex en el eje principal (solo con espacio conocido).
    const lines = [];
    if (horizontal) {
      let cur = [], x = 0;
      for (const it of items) {
        if (wraps && cur.length && !measuringX && x + it.s[0] > cw + 0.5) { lines.push(cur); cur = []; x = 0; }
        cur.push(it); x += it.s[0] + gap;
      }
      lines.push(cur);
    } else lines.push(items);
    let maxMain = 0, totalCross = 0;
    const lineInfo = [];
    for (const line of lines) {
      const mainSize = (it) => horizontal ? it.s[0] : it.s[1];
      let used = line.reduce((a, it) => a + mainSize(it), 0) + gap * (line.length - 1);
      const avail = horizontal ? cw : ch;
      if (!measuringX && (horizontal || ch > 0)) {
        const free = avail - used;
        const flex = line.map((it) => flexOf(it.c, lay, horizontal));
        const gsum = flex.reduce((a, f) => a + (f ? f.grow : 0), 0), ssum = flex.reduce((a, f, i) => a + (f ? f.shrink * mainSize(line[i]) : 0), 0);
        if (free > 0 && gsum > 0) line.forEach((it, i) => { const f = flex[i]; if (f && f.grow) { const nw = mainSize(it) + free * f.grow / gsum; it.s = horizontal ? measure(it.c, cw, ch, nw, null) : measure(it.c, cw, ch, null, nw); } });
        else if (free < 0 && ssum > 0) line.forEach((it, i) => { const f = flex[i]; if (f && f.shrink) { const nw = Math.max(0, mainSize(it) + free * f.shrink * mainSize(it) / ssum); it.s = horizontal ? measure(it.c, cw, ch, nw, null) : measure(it.c, cw, ch, null, nw); } });
        used = line.reduce((a, it) => a + mainSize(it), 0) + gap * (line.length - 1);
      }
      const cross = line.reduce((a, it) => Math.max(a, horizontal ? it.s[1] : it.s[0]), 0);
      lineInfo.push({ line, used, cross });
      maxMain = Math.max(maxMain, used); totalCross += cross;
    }
    totalCross += gap * (lines.length - 1);
    if (place) {
      if (horizontal) {
        let y = va === 'Center' ? (ch - totalCross) / 2 : va === 'Bottom' ? ch - totalCross : 0;
        if (lines.length === 1) y = 0;
        for (const L of lineInfo) {
          let x = ha === 'Center' ? (cw - L.used) / 2 : ha === 'Right' ? cw - L.used : 0;
          const lineH = lines.length === 1 ? ch : L.cross;
          for (const it of L.line) {
            const iy = va === 'Center' ? (lineH - it.s[1]) / 2 : va === 'Bottom' ? lineH - it.s[1] : 0;
            place(it.c, x, y + iy, it.s[0], it.s[1]);
            x += it.s[0] + gap;
          }
          y += L.cross + gap;
        }
      } else {
        const L = lineInfo[0];
        let y = va === 'Center' ? (ch - L.used) / 2 : va === 'Bottom' ? ch - L.used : 0;
        for (const it of L.line) {
          const ix = ha === 'Center' ? (cw - it.s[0]) / 2 : ha === 'Right' ? cw - it.s[0] : 0;
          place(it.c, ix, y, it.s[0], it.s[1]);
          y += it.s[1] + gap;
        }
      }
    }
    return horizontal ? [maxMain, totalCross] : [totalCross, maxMain];
  }
  function gridLayout(n, lay, cw, ch, place) {
    const cell = u2(val(lay, 'CellSize'), [0, 100, 0, 100]); const cp = u2(val(lay, 'CellPadding'), [0, 5, 0, 5]);
    const w = cell[0] * cw + cell[1], h = cell[2] * ch + cell[3];
    const px = cp[0] * cw + cp[1], py = cp[2] * ch + cp[3];
    const items = sorted(n);
    const maxCells = val(lay, 'FillDirectionMaxCells', 0);
    let per = Math.max(1, Math.floor((cw + px + 0.01) / (w + px)));
    if (maxCells > 0) per = Math.min(per, maxCells);
    const rows = Math.ceil(items.length / per);
    if (place) items.forEach((c, i) => place(c, (i % per) * (w + px), Math.floor(i / per) * (h + py), w, h, true));
    return [Math.min(items.length, per) * (w + px) - px, rows ? rows * (h + py) - py : 0];
  }

  /* ---------- dibujo ---------- */
  let ROOT = null;
  function styleBox(el, n, w, h) {
    const bt = val(n, 'BackgroundTransparency', 0);
    const bg = col(val(n, 'BackgroundColor3'), '#A3A2A5');
    const grad = child(n, 'UIGradient');
    if (bt < 1) {
      if (grad && val(grad, 'Enabled', true) !== false) el.style.background = gradientCss(grad, bg, bt);
      else el.style.background = rgba(bg, bt);
    }
    const cor = child(n, 'UICorner');
    if (cor) { const r = ud(val(cor, 'CornerRadius'), [0, 8]); el.style.borderRadius = Math.min(r[0] * Math.min(w, h) + r[1], Math.min(w, h) / 2) + 'px'; }
    const st = kids(n).find((c) => c.c === 'UIStroke' && val(c, 'Enabled', true) !== false);
    if (st) {
      const mode = en(val(st, 'ApplyStrokeMode'), 'Contextual');
      const th = val(st, 'Thickness', 1); const sc = rgba(col(val(st, 'Color'), '#000000'), val(st, 'Transparency', 0));
      if (TEXT.has(n.c) && mode === 'Contextual') el.dataset.textStroke = th + 'px ' + sc;
      else el.style.boxShadow = '0 0 0 ' + th + 'px ' + sc;
    }
    if (val(n, 'ClipsDescendants', false) || n.c === 'ScrollingFrame' || n.c === 'ViewportFrame' || n.c === 'CanvasGroup') el.style.overflow = 'hidden';
    const rot = val(n, 'Rotation', 0); if (rot) el.style.transform = 'rotate(' + rot + 'deg)';
    if (n.c === 'CanvasGroup') el.style.opacity = 1 - val(n, 'GroupTransparency', 0);
  }
  function seqAt(seq, t) {
    const k = seq.k; if (!k || !k.length) return null;
    for (let i = 0; i < k.length - 1; i++) if (t >= k[i][0] && t <= k[i + 1][0]) return [k[i], k[i + 1]];
    return [k[k.length - 1], k[k.length - 1]];
  }
  function gradientCss(g, bg, bt) {
    const cs = val(g, 'Color'), ts = val(g, 'Transparency');
    const rot = val(g, 'Rotation', 0);
    const stops = new Set([0, 1]); (cs && cs.k || []).forEach((k) => stops.add(k[0])); (ts && ts.k || []).forEach((k) => stops.add(k[0]));
    const mul = (a, b) => { const x = parseInt(a.slice(1), 16), y = parseInt(b.slice(1), 16); const f = (s) => Math.round(((x >> s) & 255) * ((y >> s) & 255) / 255); return '#' + ((f(16) << 16) | (f(8) << 8) | f(0)).toString(16).padStart(6, '0'); };
    const lerp = (pair, t, get) => { const [a, b] = pair; const span = b[0] - a[0] || 1; const u = (t - a[0]) / span; return get(a[1]) + (get(b[1]) - get(a[1])) * u; };
    const parts = [...stops].sort((a, b) => a - b).map((t) => {
      let c = bg;
      if (cs && cs.k) { const p = seqAt(cs, t); const ch = (s) => (v) => (parseInt(v.h.slice(1), 16) >> s) & 255; const rgb = [16, 8, 0].map((s) => Math.round(lerp(p, t, ch(s)))); c = mul(bg, '#' + rgb.map((x) => x.toString(16).padStart(2, '0')).join('')); }
      let tr = 0; if (ts && ts.k) { const p = seqAt(ts, t); tr = lerp(p, t, (v) => (typeof v === 'number' ? v : 0)); }
      return rgba(c, 1 - (1 - bt) * (1 - tr)) + ' ' + (t * 100).toFixed(1) + '%';
    });
    return 'linear-gradient(' + (90 + rot) + 'deg,' + parts.join(',') + ')';
  }
  function drawText(el, n, w, h) {
    const t = textInfo(n);
    if (t.text === '') return;
    const pad = padding(n, w, h);
    const box = document.createElement('div');
    const xa = en(val(n, 'TextXAlignment'), 'Center'), ya = en(val(n, 'TextYAlignment'), 'Center');
    box.style.cssText = 'position:absolute;display:flex;left:' + pad.l + 'px;top:' + pad.t + 'px;width:' + Math.max(0, w - pad.l - pad.r) + 'px;height:' + Math.max(0, h - pad.t - pad.b) + 'px;' +
      'justify-content:' + ({ Left: 'flex-start', Right: 'flex-end', Center: 'center' }[xa]) + ';align-items:' + ({ Top: 'flex-start', Bottom: 'flex-end', Center: 'center' }[ya]) + ';pointer-events:none';
    const span = document.createElement('div');
    const color = t.placeholder ? col(val(n, 'PlaceholderColor3'), '#B2B2B2') : col(val(n, 'TextColor3'), '#1B2A35');
    span.style.cssText = 'font-family:Inter,sans-serif;font-size:' + t.size + 'px;font-weight:' + t.weight + ';font-style:' + (t.italic ? 'italic' : 'normal') + ';line-height:' + (t.size * t.lh) + 'px;color:' + rgba(color, val(n, 'TextTransparency', 0)) +
      ';text-align:' + xa.toLowerCase() + ';' + (t.wrap ? 'white-space:pre-wrap;overflow-wrap:break-word;width:100%' : 'white-space:pre') + (t.truncate ? ';overflow:hidden;text-overflow:ellipsis;max-width:100%' : '');
    if (el.dataset.textStroke) span.style.webkitTextStroke = el.dataset.textStroke;
    span.innerHTML = t.html;
    box.appendChild(span); el.appendChild(box);
  }
  function drawNode(n, parentEl, x, y, w, h, z) {
    const el = document.createElement('div');
    el.className = 'rbx ' + n.c;
    el.dataset.name = val(n, 'Name', '');
    el.style.cssText += 'position:absolute;left:' + x + 'px;top:' + y + 'px;width:' + w + 'px;height:' + h + 'px;z-index:' + z;
    styleBox(el, n, w, h);
    if (n.c === 'ViewportFrame') {
      el.innerHTML = '<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font:600 10px Inter;color:rgba(255,255,255,.35);letter-spacing:.1em">3D</div>';
      if (window.drawViewport) window.drawViewport(el, n, w, h);
    }
    if (n.c === 'ImageLabel' || n.c === 'ImageButton') {
      const img = val(n, 'Image', ''); if (img) el.style.backgroundImage = 'repeating-linear-gradient(45deg,rgba(255,255,255,.06) 0 4px,transparent 4px 8px)';
    }
    if (TEXT.has(n.c)) drawText(el, n, w, h);
    parentEl.appendChild(el);
    layoutChildren(n, el, w, h);
    return el;
  }
  function layoutChildren(n, el, w, h) {
    const pad = padding(n, w, h);
    let cw = Math.max(0, w - pad.l - pad.r), ch = Math.max(0, h - pad.t - pad.b);
    let host = el, ox = pad.l, oy = pad.t;
    if (n.c === 'ScrollingFrame') {
      // Lienzo: ancho de la ventana; alto automático según el contenido.
      const canvas = u2(val(n, 'CanvasSize'));
      const autoC = en(val(n, 'AutomaticCanvasSize'), 'None');
      let canW = canvas[0] * w + canvas[1], canH = canvas[2] * h + canvas[3];
      const lay = layoutOf(n);
      const fullW = w, padC = padding(n, fullW, h);
      const innerW = fullW - padC.l - padC.r;
      let content = [0, 0];
      if (lay) content = lay.c === 'UIGridLayout' ? gridLayout(n, lay, innerW, 0, null) : listLayout(n, lay, innerW, 0, null);
      else for (const c of kids(n)) { if (isGui(c) && visible(c)) { const s = measure(c, innerW, h); const p = u2(val(c, 'Position')); content = [Math.max(content[0], p[1] + s[0]), Math.max(content[1], p[3] + s[1])]; } }
      if (autoC === 'Y' || autoC === 'XY') canH = Math.max(canH, content[1] + padC.t + padC.b);
      if (autoC === 'X' || autoC === 'XY') canW = Math.max(canW, content[0] + padC.l + padC.r);
      canW = Math.max(canW, w); canH = Math.max(canH, h);
      const cpos = v2(val(n, 'CanvasPosition'), [0, 0]);
      host = document.createElement('div');
      host.style.cssText = 'position:absolute;left:' + (-cpos[0]) + 'px;top:' + (-cpos[1]) + 'px;width:' + canW + 'px;height:' + canH + 'px';
      el.appendChild(host);
      const padS = padding(n, canW, canH);
      ox = padS.l; oy = padS.t; cw = Math.max(0, canW - padS.l - padS.r); ch = Math.max(0, canH - padS.t - padS.b);
      if (canH > h + 1 && val(n, 'ScrollBarThickness', 12) > 0) {
        const bar = document.createElement('div');
        const th = val(n, 'ScrollBarThickness', 12);
        bar.style.cssText = 'position:absolute;right:0;top:' + (cpos[1] / canH * h) + 'px;width:' + th + 'px;height:' + (h * h / canH) + 'px;background:' + rgba(col(val(n, 'ScrollBarImageColor3'), '#3A3F4D'), val(n, 'ScrollBarImageTransparency', 0)) + ';border-radius:' + th + 'px;z-index:9999';
        el.appendChild(bar);
      }
    }
    const scale = child(n, 'UIScale');
    if (scale && n.c !== 'ScreenGui') {
      const s = val(scale, 'Scale', 1);
      if (s !== 1) { const inner = document.createElement('div'); inner.style.cssText = 'position:absolute;left:0;top:0;width:' + w + 'px;height:' + h + 'px;transform-origin:0 0;transform:scale(' + s + ')'; host.appendChild(inner); host = inner; }
    }
    const lay = layoutOf(n);
    const zOf = (c) => val(c, 'ZIndex', 1);
    const place = (c, x, y, cw2, ch2) => drawNode(c, host, ox + x, oy + y, cw2, ch2, zOf(c));
    if (lay && lay.c === 'UIGridLayout') gridLayout(n, lay, cw, ch, place);
    else if (lay) listLayout(n, lay, cw, ch, place);
    else {
      for (const c of kids(n)) {
        if (!isGui(c) || !visible(c)) continue;
        const [w2, h2] = measure(c, cw, ch);
        const pos = u2(val(c, 'Position')); const ap = v2(val(c, 'AnchorPoint'));
        place(c, pos[0] * cw + pos[1] - ap[0] * w2, pos[2] * ch + pos[3] - ap[1] * h2, w2, h2);
      }
    }
    // Hijos que no son GuiObject pero contienen GUI (carpetas) no se dibujan.
  }
  function renderScreen(tree, vw, vh, mount) {
    ROOT = tree;
    const guis = kids(tree).filter((c) => c.c === 'ScreenGui' && val(c, 'Enabled', true) !== false)
      .sort((a, b) => val(a, 'DisplayOrder', 0) - val(b, 'DisplayOrder', 0));
    for (const g of guis) {
      const layer = document.createElement('div');
      layer.className = 'rbx ScreenGui'; layer.dataset.name = val(g, 'Name', '');
      layer.style.cssText = 'position:absolute;left:0;top:0;width:' + vw + 'px;height:' + vh + 'px';
      mount.appendChild(layer);
      let host = layer, w = vw, h = vh;
      const sc = child(g, 'UIScale');
      if (sc && val(sc, 'Scale', 1) !== 1) {
        // UIScale bajo un ScreenGui: escala desde la esquina superior izquierda y no cambia el
        // tamaño de referencia de las escalas (un hijo de tamaño 1,0,1,0 deja de cubrir la pantalla).
        const s = val(sc, 'Scale', 1);
        const inner = document.createElement('div'); inner.style.cssText = 'position:absolute;left:0;top:0;width:' + vw + 'px;height:' + vh + 'px;transform-origin:0 0;transform:scale(' + s + ')';
        layer.appendChild(inner); host = inner;
      }
      layoutChildren(g, host, w, h);
    }
  }
  window.RobloxLayout = { renderScreen };
})();
