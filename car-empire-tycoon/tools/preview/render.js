/*
  Dibuja los árboles volcados por tests/preview.luau y guarda una captura PNG por escena.
  Uso (desde car-empire-tycoon):  node tools/preview/render.js <carpeta-json> <carpeta-png> [filtro]
  Requiere Playwright con Chromium (en el entorno de la nube ya está instalado).
*/
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const [jsonDir, outDir, filter] = process.argv.slice(2);
if (!jsonDir || !outDir) { console.error('Uso: node tools/preview/render.js <json> <png> [filtro]'); process.exit(1); }
fs.mkdirSync(outDir, { recursive: true });
const layoutSrc = fs.readFileSync(path.join(__dirname, 'roblox-layout.js'), 'utf8');

// Botones de Roblox (menú y chat) arriba a la izquierda: se dibujan para detectar superposiciones.
const CORE = '<div style="position:absolute;left:16px;top:8px;width:44px;height:44px;border-radius:22px;background:rgba(18,18,21,.75);z-index:99999"></div>' +
  '<div style="position:absolute;left:68px;top:8px;width:44px;height:44px;border-radius:22px;background:rgba(18,18,21,.75);z-index:99999"></div>';

(async () => {
  const browser = await chromium.launch();
  const files = fs.readdirSync(jsonDir).filter((f) => f.endsWith('.json') && f !== 'index.json' && (!filter || f.includes(filter)));
  for (const f of files) {
    const data = JSON.parse(fs.readFileSync(path.join(jsonDir, f), 'utf8'));
    const [vw, vh] = data.viewport;
    const page = await browser.newPage({ viewport: { width: vw, height: vh } });
    const errors = [];
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.setContent('<!doctype html><html><head><meta charset="utf-8"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#151821}' +
      '#world{position:absolute;inset:0;background:linear-gradient(180deg,#2b3140 0%,#3a4152 55%,#4a5163 56%,#3b4150 100%)}' +
      '#world:after{content:"Mundo 3D de Roblox (no se dibuja en la vista previa)";position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);font:600 13px Inter;color:rgba(255,255,255,.18);letter-spacing:.06em}</style></head>' +
      '<body><div id="world"></div><div id="mount" style="position:absolute;inset:0"></div><div id="core">' + CORE + '</div></body></html>');
    await page.addScriptTag({ content: layoutSrc });
    // La PlayerGui del jugador: el árbol completo es la raíz del volcado (PlayerGui).
    await page.evaluate(([tree, w, h]) => window.RobloxLayout.renderScreen(tree, w, h, document.getElementById('mount')), [data.tree, vw, vh]);
    await page.waitForTimeout(50);
    const out = path.join(outDir, f.replace(/\.json$/, '.png'));
    await page.screenshot({ path: out });
    console.log((errors.length ? '✗ ' : '✓ ') + f + (errors.length ? ' ' + errors[0] : ''));
    await page.close();
  }
  await browser.close();
})();
