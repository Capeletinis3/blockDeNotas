/*
  Une las capturas de la V3 y de la vista previa de Roblox con el mismo nombre en una imagen lado a lado
  (arriba la V3, abajo Roblox) y arma un índice HTML para recorrerlas.
  Uso (desde car-empire-tycoon):  node tools/preview/compare.js <v3-png> <roblox-png> <salida> [filtro]
*/
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const [v3Dir, rbDir, outDir, filter] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const names = fs.readdirSync(v3Dir).filter((f) => f.endsWith('.png') && (!filter || f.includes(filter))).map((f) => f.slice(0, -4));

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1600, height: 1860 } });
  const rows = [];
  for (const n of names) {
    const a = path.join(v3Dir, n + '.png'), b = path.join(rbDir, n + '.png');
    const has = fs.existsSync(b);
    const img = (p) => 'data:image/png;base64,' + fs.readFileSync(p).toString('base64');
    await page.setContent('<html><body style="margin:0;background:#000;font:600 14px Inter;color:#fff">' +
      '<div style="height:30px;display:flex;align-items:center;padding:0 10px;background:#7667FF">V3 · ' + n + '</div><img src="' + img(a) + '" style="display:block;width:1600px">' +
      '<div style="height:30px;display:flex;align-items:center;padding:0 10px;background:' + (has ? '#2E7D5B' : '#FF5F68') + '">Roblox (vista previa) · ' + n + (has ? '' : ' · SIN CAPTURA') + '</div>' + (has ? '<img src="' + img(b) + '" style="display:block;width:1600px">' : '') + '</body></html>');
    const h = await page.evaluate(() => document.body.scrollHeight);
    await page.setViewportSize({ width: 1600, height: h });
    await page.screenshot({ path: path.join(outDir, n + '.png') });
    rows.push(n);
    console.log('✓ ' + n + (has ? '' : ' (falta Roblox)'));
  }
  fs.writeFileSync(path.join(outDir, 'index.html'), '<html><body style="background:#111;color:#eee;font:14px sans-serif">' + rows.map((n) => '<h3>' + n + '</h3><img src="' + n + '.png" style="width:100%">').join('') + '</body></html>');
  await browser.close();
})();
