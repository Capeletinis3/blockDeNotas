/*
  Capturas de referencia de la V3 (reference/Car-Empire-Tycoon-V3.html) con los mismos nombres de escena
  que tests/scenes.luau, para compararlas con la vista previa de Roblox.
  Uso (desde car-empire-tycoon):  node tools/preview/v3.js <carpeta-png> [ancho] [alto] [filtro]
  El azar se fija con una semilla para que las capturas se puedan repetir.
*/
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const [outDir, wArg, hArg, filter] = process.argv.slice(2);
const W = +wArg || 1600, H = +hArg || 900;
fs.mkdirSync(outDir, { recursive: true });
const FILE = 'file://' + path.resolve(__dirname, '../../reference/Car-Empire-Tycoon-V3.html');

const SEED = `(() => { let s = 1234567; Math.random = () => { s |= 0; s = s + 0x6D2B79F5 | 0; let t = Math.imul(s ^ s >>> 15, 1 | s); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; })();`;

// Cada escena corre dentro de la página de la V3 (tiene acceso a G, UI, ROOT, ACT, go, render…).
const S = {};
const fresh = `ROOT.settings.showIndex = false; NEW.name = 'Vortex Motors'; NEW.slot = 0; ACT.createCompany(); document.querySelectorAll('#toasts > *').forEach((t) => t.remove());`;
const demo = (k) => `ROOT.settings.showIndex = false; G = makeDemo('${k}'); ROOT.activeSlot = null; UI.panels = true; go('juego');`;
const quiet = `document.querySelectorAll('#toasts > *').forEach((t) => t.remove());`;
S['menu'] = `ROOT.settings.showIndex = false; go('menu');`;
S['menu-empresas'] = `ROOT.settings.showIndex = false; ROOT.slots[0] = newGame({ name: 'Vortex Motors' }); ROOT.slots[0].level = 4; ROOT.slots[0].money = 185000; ROOT.slots[1] = newGame({ name: 'Ruta Norte', color: '#F7C95C', logo: 'rayo', difficulty: 'dificil' }); go('menu');`;
S['menu-renombrar'] = S['menu-empresas'] + ` ACT.renameStart({ dataset: { v: 0 } });`;
S['menu-eliminar'] = S['menu-empresas'] + ` ACT.deleteSlot({ dataset: { v: 1 } });`;
S['nueva'] = `ROOT.settings.showIndex = false; ACT.newCompany({ dataset: { v: 0 } });`;
S['nueva-escrita'] = S['nueva'] + ` NEW.name = 'Vortex Motors'; NEW.diff = 'dificil'; NEW.logo = 'rayo'; NEW.color = '#F7C95C'; render();`;
S['juego-nuevo'] = fresh + ` go('juego');`;
for (const r of ['editor', 'autos', 'fabrica', 'ventas', 'mercado', 'investigacion', 'personal', 'compania', 'misiones', 'estadisticas']) S[r + '-nuevo'] = fresh + ` go('${r}');`;
S['juego-op'] = demo('operacion') + quiet;
S['juego-op-ocultos'] = demo('operacion') + quiet + ` UI.panels = false; render();`;
S['juego-op-mas'] = demo('operacion') + quiet + ` UI.popX = 1180; UI.pop = 'more'; render();`;
S['juego-avanzada'] = demo('avanzada') + quiet;
for (const r of ['autos', 'fabrica', 'ventas', 'mercado', 'investigacion', 'personal', 'compania', 'misiones', 'estadisticas']) S[r + '-op'] = demo('operacion') + quiet + ` go('${r}');`;
S['fabrica-avanzada'] = demo('avanzada') + quiet + ` go('fabrica');`;
const tab = (k, v) => ` UI.tabs['${k}'] = '${v}'; render();`;
S['autos-op-piezas'] = demo('operacion') + quiet + ` go('autos');` + tab('inv', 'parts');
S['autos-op-materiales'] = demo('operacion') + quiet + ` go('autos');` + tab('inv', 'mats');
S['autos-op-disenos'] = demo('operacion') + quiet + ` go('autos');` + tab('inv', 'designs');
S['ventas-op-historial'] = demo('operacion') + quiet + ` go('ventas');` + tab('ven', 'hist');
for (const t of ['pieza', 'diseno', 'material', 'fav', 'mine', 'offers']) S['mercado-op-' + t] = demo('operacion') + quiet + ` go('mercado');` + tab('mkt', t);
S['personal-op-contratar'] = demo('operacion') + quiet + ` go('personal');` + tab('per', 'hire');
S['misiones-op-historia'] = demo('operacion') + quiet + ` go('misiones');` + tab('mis', 'historia');
S['misiones-op-diarias'] = demo('operacion') + quiet + ` go('misiones');` + tab('mis', 'diaria');
S['misiones-op-eventos'] = demo('operacion') + quiet + ` go('misiones');` + tab('mis', 'evento');
S['estadisticas-op-30'] = demo('operacion') + quiet + ` go('estadisticas'); UI.statRange = 30; render();`;
// Editor
S['editor-paso1'] = fresh + ` go('editor');` + quiet;
S['editor-paso2'] = fresh + ` go('editor'); ACT.edStep({ dataset: { v: 2 } });` + quiet;
S['editor-paso2-pieza'] = fresh + ` go('editor'); ACT.edStep({ dataset: { v: 2 } }); UI.edCat = 'frenos'; UI.edSel = 'deportivos'; render();` + quiet;
S['editor-paso3'] = fresh + ` go('editor'); ACT.edStep({ dataset: { v: 3 } });` + quiet;
S['editor-paso3-interior'] = fresh + ` go('editor'); ACT.edStep({ dataset: { v: 3 } }); UI.edTab = 'int'; render();` + quiet;
S['editor-paso4'] = fresh + ` go('editor'); ACT.edStep({ dataset: { v: 4 } });` + quiet;
S['editor-comparar'] = fresh + ` go('editor'); ACT.edStep({ dataset: { v: 3 } }); change((d) => { d.paint.primary = '#D6333F'; }); UI.compare = true; render();` + quiet;
S['editor-oculto'] = fresh + ` go('editor'); UI.hideUI = true; render();` + quiet;
S['editor-modelos'] = demo('operacion') + quiet + ` go('editor'); ACT.prevModels();`;
S['editor-salir'] = fresh + ` go('editor'); change((d) => { d.name = 'Prueba sin guardar'; }); go('juego');` + quiet;
// Diálogos
S['dlg-configuracion'] = demo('operacion') + quiet + ` ACT.settings();`;
S['dlg-notificaciones'] = demo('operacion') + quiet + ` notify(G, 'ok', 'Producción completada: Aurora GT v1 (VM-0063)', 'autos'); notify(G, 'aviso', 'Orden detenida: faltan materiales', 'fabrica'); ACT.notifs();`;
S['dlg-ayuda'] = demo('operacion') + quiet + ` go('fabrica'); ACT.help({ dataset: { v: 'fabrica' } });`;
S['dlg-diaria'] = demo('operacion') + quiet + ` ACT.daily();`;
S['dlg-orden'] = demo('operacion') + quiet + ` go('fabrica'); ACT.newOrder();`;
S['dlg-negociar'] = demo('operacion') + quiet + ` go('ventas'); const c = G.customers.find((x) => x.state === 'oferta') || G.customers[0]; c.state = 'oferta'; c.offer = c.offer || 20000; negotiate(c.id);`;
S['dlg-unidad'] = demo('operacion') + quiet + ` go('autos'); unitDialog(G.units.find((u) => u.status !== 'vendido').id);`;
S['dlg-mayorista'] = demo('operacion') + quiet + ` go('autos'); ACT.wholesale({ dataset: { id: G.units.find((u) => u.status === 'almacen' || u.status === 'salon').id } });`;
S['dlg-publicacion'] = demo('operacion') + quiet + ` go('mercado'); listingDialog(G.market.listings.find((l) => l.kind === 'vehiculo').id);`;
S['dlg-publicar'] = demo('operacion') + quiet + ` go('mercado'); G.units.find((u) => u.status === 'salon').status = 'almacen'; publishDialog();`;
S['dlg-prueba'] = fresh + ` go('editor'); ACT.testDrive();` + quiet;
S['dlg-novedades'] = `ROOT.settings.showIndex = false; go('menu'); ACT.newsDlg();`;
S['dlg-tienda'] = demo('operacion') + quiet + ` ACT.shop();`;
S['dlg-amigos'] = demo('operacion') + quiet + ` ACT.friends();`;
S['dlg-evento'] = demo('operacion') + quiet + ` ACT.event();`;
S['dlg-saltar-tutorial'] = fresh + ` go('juego'); ACT.skipTutorial();` + quiet;
S['dlg-cancelar-orden'] = demo('operacion') + quiet + ` go('fabrica'); ACT.oCancel({ dataset: { id: G.production.orders[0].id } });`;
S['dlg-comprar-material'] = demo('operacion') + quiet + ` go('fabrica'); ACT.buyMat({ dataset: { v: 'acero', n: 20 } });`;
S['dlg-ampliar'] = demo('operacion') + quiet + ` G.counters.unitsSold = 99; G.reputation = 4.5; G.money = 2e6; go('compania'); ACT.expand();`;

(async () => {
  const browser = await chromium.launch({ args: ['--use-gl=swiftshader', '--enable-webgl', '--ignore-gpu-blocklist'] });
  for (const [name, code] of Object.entries(S)) {
    if (filter && !name.includes(filter)) continue;
    const ctx = await browser.newContext({ viewport: { width: W, height: H }, deviceScaleFactor: 1, hasTouch: W <= 900, isMobile: false });
    await ctx.addInitScript(SEED);
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(String(e)));
    await page.goto(FILE);
    await page.waitForTimeout(1200);
    try { await page.evaluate(code); } catch (e) { errors.push(String(e)); }
    await page.waitForTimeout(900);
    await page.evaluate(() => { const t = document.getElementById('toasts'); if (t) t.style.display = 'none'; const i = document.getElementById('index-btn'); if (i) i.style.display = 'none'; });
    await page.screenshot({ path: path.join(outDir, name + '.png') });
    console.log((errors.length ? '✗ ' : '✓ ') + name + (errors.length ? ' ' + errors[0] : ''));
    await ctx.close();
  }
  await browser.close();
})();
