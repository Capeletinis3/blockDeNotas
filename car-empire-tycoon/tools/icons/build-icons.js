/*
  Genera src/client/IconData.luau a partir de los trazos SVG de la V3 (ICONS y LOGOS).
  Cada trazo se muestrea en el navegador (SVGPathElement.getPointAtLength) y se simplifica en
  polilíneas dentro de la caja de 24×24; el cliente las dibuja con marcos rotados de extremos redondos.
  Uso (desde car-empire-tycoon):  node tools/icons/build-icons.js
*/
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const html = fs.readFileSync(path.join(__dirname, '../../reference/Car-Empire-Tycoon-V3.html'), 'utf8');
function grab(re) { const m = html.match(re); if (!m) throw new Error('No se encontró ' + re); return m[1]; }
// eslint-disable-next-line no-eval
const ICONS = eval('(' + grab(/const ICONS = (\{[\s\S]*?\});/) + ')');
const LOGOS = eval('(' + grab(/const LOGOS = (\[[\s\S]*?\]);/) + ')');
const all = Object.assign({}, ICONS);
for (const l of LOGOS) all['logo_' + l.id] = l.d;

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  const data = await page.evaluate((icons) => {
    const NS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(NS, 'svg'); document.body.appendChild(svg);
    const out = {};
    // Ramer–Douglas–Peucker
    function simplify(pts, tol) {
      if (pts.length < 3) return pts;
      const [a, b] = [pts[0], pts[pts.length - 1]];
      let idx = -1, dmax = 0;
      for (let i = 1; i < pts.length - 1; i++) {
        const p = pts[i]; const dx = b[0] - a[0], dy = b[1] - a[1]; const len = Math.hypot(dx, dy);
        const d = len < 1e-6 ? Math.hypot(p[0] - a[0], p[1] - a[1]) : Math.abs(dy * p[0] - dx * p[1] + b[0] * a[1] - b[1] * a[0]) / len;
        if (d > dmax) { dmax = d; idx = i; }
      }
      if (dmax > tol) { const l = simplify(pts.slice(0, idx + 1), tol); const r = simplify(pts.slice(idx), tol); return l.slice(0, -1).concat(r); }
      return [a, b];
    }
    for (const [name, d] of Object.entries(icons)) {
      // Se separa en subtrazos por cada «M» absoluta (los íconos usan M para empezar cada trazo).
      const subs = d.match(/M[^M]*/g) || [d];
      const lines = [];
      for (const sd of subs) {
        const p = document.createElementNS(NS, 'path'); p.setAttribute('d', sd); svg.appendChild(p);
        const len = p.getTotalLength();
        if (len < 0.05) { const q = p.getPointAtLength(0); lines.push([[+q.x.toFixed(2), +q.y.toFixed(2)]]); p.remove(); continue; }
        // Si el subtrazo tiene una «m» relativa o una «z», getPointAtLength igual lo recorre completo.
        const n = Math.max(2, Math.ceil(len / 0.35));
        const pts = [];
        for (let i = 0; i <= n; i++) { const q = p.getPointAtLength((len * i) / n); pts.push([q.x, q.y]); }
        // Cortes por saltos (subtrazos con m relativa): un salto mayor al paso indica un movimiento sin trazo.
        let cur = [pts[0]];
        for (let i = 1; i < pts.length; i++) {
          const jump = Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]) > (len / n) * 3 + 0.5;
          if (jump) { lines.push(cur); cur = []; }
          cur.push(pts[i]);
        }
        lines.push(cur);
        p.remove();
      }
      out[name] = lines.map((l) => (l.length === 1 ? l : simplify(l, 0.12)).map(([x, y]) => [+x.toFixed(2), +y.toFixed(2)]));
    }
    return out;
  }, all);
  await browser.close();
  let lua = '--!strict\n-- Generado por tools/icons/build-icons.js a partir de los íconos SVG de la V3 (no editar a mano).\n' +
    '-- Cada ícono es una lista de polilíneas { x1, y1, x2, y2, … } en una caja de 24×24; un solo punto es un punto.\nreturn {\n';
  for (const name of Object.keys(data).sort()) {
    lua += '\t' + (/^[a-z_][a-z0-9_]*$/i.test(name) ? name : '["' + name + '"]') + ' = { ' + data[name].map((l) => '{ ' + l.map((p) => p[0] + ', ' + p[1]).join(', ') + ' }').join(', ') + ' },\n';
  }
  lua += '}\n';
  const out = path.join(__dirname, '../../src/client/IconData.luau');
  fs.writeFileSync(out, lua);
  console.log('Íconos: ' + Object.keys(data).length + ' → ' + out + ' (' + lua.length + ' bytes)');
})();
