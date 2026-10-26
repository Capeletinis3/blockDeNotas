# Segunda auditoría · correcciones y mejoras

Se trabajó sobre el proyecto existente: se conservaron los sistemas que funcionaban (lotes, ventas
automáticas, Cerrar venta, calendario, guardado con candado, interfaz V3) y se corrigieron o completaron
los puntos de abajo. No se trabajó en modelos 3D (decisión de esta etapa; ver `FASE-3D.md`).

> **Studio:** no hubo acceso a Roblox Studio. Lo verificado son las pruebas automáticas (lógica e
> interfaz sobre un entorno Roblox simulado), Selene, el bot de balance, el `.rbxl` generado con Rojo y la
> vista previa de la interfaz. La guía para probar en Studio está al final.

## Errores corregidos

| Problema | Dónde | Corrección |
|---|---|---|
| El servidor mandaba la partida completa al cliente **cada segundo** (≈115 KB con historial lleno) | `Sessions:tick` | Segundo a segundo se manda solo lo que cambia (`GameState.live`, < 4 KB); la partida completa solo cuando cambia la estructura o cada 30 s (`Sessions:pushTick`, `Util.mergeLive`). |
| **PI farmeables**: cada lote agotado con ganancia daba 2 min de PI, aunque fuera de 1 unidad | `Simulation.stepSales` | Bonificaciones (ventas, lotes ≥ 100 agotados con ganancia, lanzamiento exitoso) con **un tope mensual compartido** (`ECON.bonusPiCapMinutes`). |
| **PI perdidos en silencio**: al terminar una investigación el banco se recortaba al tope | `Simulation.stepResearch` | Ya no se recorta; la generación se detiene en el tope y avisa una vez; misiones y bonificaciones se suman aunque el banco esté lleno. |
| Banco de PI de solo 3 minutos | `Catalog.RULES` | `piBankMinutes = 20` (configurable). |
| **Campaña gratis**: se podía activar justo después del cobro mensual y apagar antes del siguiente | `Actions.toggleCampaign` | El primer mes se cobra al activar o subir de nivel (`Actions.setCampaign`). |
| **Duplicar** un diseño viejo creaba un modelo nuevo sin costo | `Actions.dupDesign` | Paga la ingeniería de un modelo nuevo. |
| El descuento del estudio de diseño nunca se aplicaba (miraba un campo de personal eliminado) | `DesignCalc.designDiscount` | Corregido. |
| Estadísticas sin efecto (velocidad máxima, frenado) | `Rules.indices` | Cuentan en el atractivo (prestaciones y seguridad). |
| Historial limitado a 60 lotes completos: se perdía la historia de los modelos y engordaba la partida | `GameState`, `Simulation.archiveLot` | Historial **permanente** por modelo y generación + historial **reciente** liviano (40 lotes). |
| Rivales con precio decorativo (no influía en las ventas) | `Rules.rivalOffers` | El precio de cada rival frente a su precio justo cambia su peso en el reparto, igual que para el jugador. |
| Navegación cortada en 1600×900 con contadores; diálogo de lote cortado en 390×844 | `ScreenHud`, `App` | Distribución compacta y alto de diálogo ajustados (la prueba de desbordes ahora revisa también la barra de navegación). |

## Mejoras implementadas

- **Sedes** (5 niveles): beneficios inmediatos (PI/min 3·8·20·45·90, líneas 1–5, alcance, personal,
  nivel máximo de estaciones 2·4·6·8·10). Costos: $300.000 · $2,5 M · $60 M · $400 M. Preparadas para un
  edificio 3D por nivel (`SEDES[n].asset`, `Garage:applySedeModel`).
- **Editor**: categoría **Seguridad** (paquetes por época: cinturones, bolsas de aire, estabilidad,
  asistentes); motores nuevos por época (1.3 económico, 2.0 16V de 1984, V6 3.5 de 1993, V8 6.2 de 2006,
  1.0 turbo de 2012); cada pieza muestra sus efectos; «Fiabilidad»; la ingeniería del modelo se ve en los
  costos. Cada generación conserva su configuración.
- **Economía**: ingeniería por modelo, generación o versión con cambios mecánicos (crece con la época;
  los cambios estéticos no pagan); campañas por nivel (radio y prensa → TV → digital, cada una con su
  investigación); estaciones hasta nivel 10; investigación con costo en dinero según la época.
- **Rivales**: estrategia propia (volumen, eficiencia, deportivos premium, precio bajo y ascenso,
  económicos, lujo), generación nueva cada 5–8 años, alcance que cambia con los años, bajan precios si
  les quitás mercado; novedades anuales. Pantalla con clasificación y tu posición.
- **Historial**: por modelo y generación se guardan configuración, estadísticas, lotes, fabricadas,
  vendidas, descartadas, ingresos, gastos, beneficio y récords (mejor lote, lote más rentable, mejor mes),
  aunque se elimine el diseño. Hasta 60 diseños guardados.
- **Interfaz**: Ventas con encargadas, fabricadas, por fabricar, disponibles, vendidas, ritmo, ingresos,
  gastos y beneficio; diálogo de lote con ingresos y ganancia potenciales marcados como estimación,
  capacidad y advertencias; Investigación con barra del banco, aviso de banco lleno e investigación
  sugerida; HUD con ventas por minuto; tutorial que guía con el botón principal y resalta la sección del
  paso; animaciones 2D livianas (barras, botones, diálogos) que respetan «Reducir movimiento».

## Migración (esquema 3 → 4)

Cada lote del historial suma sus números al resumen de su modelo antes de quedar en versión liviana;
los diseños reciben «Seguridad básica»; una campaña activa pasa al primer nivel. No cambia el dinero ni se
borra nada. Probado con una partida de la versión anterior (`tests/run.luau`, «Migración 3 → 4») y con la
partida real de la versión 2 (`tests/fixtures/save_v2.json`).

## Equilibrio (bot `tests/balance.luau`, jugador que optimiza)

| | Normal | Magnate |
|---|---|---|
| Primera venta / primera ganancia | 0,3 / 1,3 min | 0,3 / 1,0 min |
| Empresa pequeña | 14,5 min (1971) | 14,5 min (1971) |
| Sede empresarial | 46 min (1974) | 46 min (1974) |
| Corporación automotriz | 120 min (1980) | 128 min (1981) |
| Imperio automotriz | 300 min (1997) | 335 min (2000) |
| Tecnologías | una cada 10,8 min (las 56 hacia 2025) | igual |

Con la estrategia mínima («plano», dos modelos sin generaciones nuevas) la Corporación llega recién en
2009: decidir bien importa. Inversión total del jugador normal: producción $1.600 M, sede y estaciones
$565 M, ingeniería $269 M, campañas $181 M, investigación $121 M.

**Parcial:** desde 2000, con todo comprado, el dinero vuelve a acumularse (≈ $45 M por año para un
jugador que optimiza; $1.500 M en 2030). Ya no es por falta de inversiones —cada una tiene efecto—
sino porque el juego todavía no tiene metas después del Imperio. Los parámetros están en
`Catalog.ECON` / `Catalog.SEDES` para seguir ajustando.

## Pruebas automáticas

- `lune run tests/run.luau` → **902 comprobaciones, 0 fallas**: los 26 casos obligatorios (marcados
  [C4]…[C25] más los [P1]…[P16] anteriores), farmeo de PI, banco lleno, competidores, migraciones,
  salir y volver durante una producción, envío liviano, candados y reenvíos.
- `lune run tests/ui.luau` → **260 comprobaciones, 0 fallas**, incluidas las cuatro resoluciones.
- `selene src tests` sin avisos · `tests/verify_place.luau`: el `.rbxl` coincide con las fuentes.

## Pendiente

- Probar en Roblox Studio (lista abajo).
- Metas para después del Imperio (para el dinero acumulado de 2000 en adelante).
- Eventos de temporada, amigos y tienda (marcados «no implementado»).
- Modelos 3D definitivos (fase futura).

## Cómo probar en Studio

1. Abrir `CarEmpireTycoon.rbxl` (o `rojo serve`). Para guardar de verdad: publicar y activar
   *Enable Studio Access to API Services*.
2. Crear una empresa: «Ene 1970» en el HUD y el botón **Diseño** resaltado en violeta.
3. Diseño: en el paso 2 la categoría **Seguridad** y los **efectos** de cada pieza; el V8 bloqueado con
   el motivo. En Output: `[CarEmpire] Editor 3D: el auto se ve …`.
4. Guardar: el costo incluye licencia e ingeniería. Lanzar un lote de 1.000 → se detiene al terminar.
5. Ventas: encargadas / por fabricar / gastos / beneficio; Modificar precio; Cerrar venta (dice cuántas
   se pierden). Campañas: solo «Radio y prensa» disponible al principio.
6. Investigación: barra del banco; con 20 min sin investigar aparece «banco lleno»; la sugerida.
7. Mercado › Marcas rivales: clasificación y tu posición. Catálogo › Historia: récords.
8. Compañía: ampliar con el dinero justo (se descuenta y suben PI/min y líneas al instante).
9. Salir con un lote a medio fabricar y volver: el lote sigue donde estaba (el calendario no avanza sin
   conexión).
10. Device Emulator en 1600×900, 1280×720, 844×390 y 390×844.
11. Con la red lenta del emulador, verificar que el HUD y las barras sigan actualizándose (envío liviano).
