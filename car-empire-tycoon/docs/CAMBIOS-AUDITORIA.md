# Auditoría, corrección y mejora integral · cambios

Este documento resume la auditoría del juego, lo que se cambió y en qué estado queda cada parte.
No se recreó el juego: se reutilizaron el editor, la interfaz con el estilo de la V3, el guardado con
candado de sesión, los garajes 3D y las pruebas, y se reemplazaron las mecánicas que contradecían el
objetivo (inventario unidad por unidad, negociación, compra de materiales, averías, cansancio).

> **Studio:** este trabajo se hizo sin poder abrir Roblox Studio. Lo verificado son las pruebas
> automáticas (lógica e interfaz sobre un entorno Roblox simulado), el análisis estático, el bot de
> balance, la generación del `.rbxl` y la vista previa de la interfaz. **Nada de esto prueba el aspecto
> real, el 3D, el DataStore real ni el multijugador real.** La lista para probar en Studio está al final.

## 1. Lo que encontró la auditoría

| Problema | Dónde estaba | Qué pasaba |
|---|---|---|
| Producción por orden de hasta 50 unidades (`maxQty = 50`) | `Catalog.RULES`, `Actions.createOrder` | No se podían pedir lotes grandes; cada unidad era un objeto guardado. |
| «Producción automática» | `Simulation`, investigación `p3` | Al terminar una orden se creaba otra sola: la fábrica seguía fabricando el mismo modelo. |
| Venta unidad por unidad con clientes y negociación | `Simulation` (clientes), `Dialogs.counter` | Había que mandar cada auto al salón y responder cada oferta. |
| Materiales, averías, desgaste, cansancio | `Simulation`, `Actions` | Tareas repetitivas obligatorias. |
| Calendario desde 2026, en días | `Util.gameDate` | No había épocas ni progresión histórica. |
| Investigación por laboratorio y PI diarios | `Catalog.RESEARCH`, `Rules.rpPerDay` | Sin relación con la sede; tecnologías modernas desde el inicio (caja de 8 velocidades, eléctricos). |
| Costo de fabricación contado dos veces en finanzas | `Rules.finance` | Se restaba lo pagado al fabricar y también el costo de lo vendido. |
| Gemas sin uso | HUD, compañía, recompensas | Moneda visible sin nada en qué gastarla. |
| Mercado de compraventa simulado | `Market.luau` | Se confundía con la competencia; no explicaba las ventas. |

## 2. Cambios por prioridad

### Prioridad 1 · Lotes, ventas automáticas y Cerrar venta
- **Lotes** (`Simulation.makeLot`, `Actions.createLot`): cantidad libre de 1 a 1.000.000 (atajos 100,
  1.000, 10.000 y 50.000 en el diálogo). Cada lote guarda id, copia del diseño (modelo, generación,
  año), encargadas, fabricadas, vendidas, descartadas, precio, precio de referencia, costo por unidad,
  ingresos, costo pagado, estado de producción (`cola`, `produciendo`, `pausado`, `sin fondos`,
  `completado`, `cancelado`) y estado comercial (`en venta`, `agotado`, `retirado`). Son contadores
  agregados: 50.000 autos no crean 50.000 registros.
- **Producción** (`Simulation.stepProduction`): cada línea de la sede fabrica un lote a la vez; cada
  unidad se cobra al terminarse. Si no alcanza el dinero se fabrican solo las que se pueden pagar, el
  lote queda «sin fondos» y sigue solo cuando entra dinero. Nunca hay dinero negativo ni unidades de la
  nada. Al llegar a la cantidad el lote pasa a «completado» y **no se repite nunca**.
- **Ventas automáticas** (`Rules.market`, `Simulation.stepSales`): la demanda de cada tipo de vehículo y
  año (autos por minuto real) se reparte entre el resto del mercado, las marcas rivales y los lotes del
  jugador según: atractivo frente a lo que espera la época, precio respecto del de referencia,
  reputación, alcance de la sede, tecnologías comerciales, campaña y personal de ventas. Es
  determinista (no hay tiradas) y la misma función la usan el servidor, el diálogo de lote, el editor y
  la pantalla Mercado, así que lo que se ve explica lo que pasa.
- **Cerrar venta** (`Actions.closeSale`): confirmación que dice cuántas unidades sin vender se pierden y
  su costo; descarta el stock sin reintegro, cancela lo no fabricado sin cobrar, deja el lote como
  «Retirado» en el historial con sus números y nunca vuelve a vender.
- **Modificar precio** (`Actions.setLotPrice`): entre la mitad del costo y 3 veces el de referencia;
  avisa si queda por debajo del costo.

### Prioridad 2 · Calendario e investigación por sede
- Calendario mensual desde **enero de 1970** (`Catalog.CALENDAR`): un año dura **660 s reales** (11 min)
  a 1×. Llega a 2030 y sigue funcionando después (prueba con 2040).
- **PI por minuto según la sede** (`Rules.piPerMinute`): 3 · 8 · 20 · 45 · 90. El personal del
  laboratorio suma hasta +30 %. Bonos: ventas (1 PI cada 50 autos, con tope mensual), lote agotado con
  ganancia y misiones. Sin proyecto activo se ahorran hasta 3 minutos de generación.
- **Árbol histórico** de 56 tecnologías en 9 ramas (motores, carrocerías, transmisiones y tracción,
  seguridad, comodidad e interiores, producción industrial, electrónica/híbridos/eléctricos,
  materiales y aerodinámica, marketing), cada una con año, requisitos y un efecto real que se prueba
  (estadística, costo, velocidad, demanda o una pieza/opción que habilita). Costos dimensionados para
  ≈ 1,5 / 4 / 8 / 12,5 minutos con la sede esperada de su época.

### Prioridad 3 · Economía, épocas y competidores
- Precios de época (un compacto de 1970 cuesta ≈ $1.800 de fabricar y ≈ $2.900 de referencia).
- Capital inicial 150k / 90k / 50k; sedes de $300.000 a $100.000.000 con requisitos de ventas y
  reputación. Finanzas en base de caja: el costo de lo vendido es informativo y no se descuenta dos veces.
- Piezas, bases, llantas, acabados y opciones con año de aparición: en 1970 no hay caja de 8
  velocidades, turbo, ABS, LED, híbridos ni eléctricos (prueba «Épocas»).
- Seis marcas rivales ficticias (Kodiak Motors, Nordia, Halcón, Kairo Cars, Velox Auto, Imperial) con
  modelos por tipo, generación cada 6 años, segmento, precio, atractivo y ventas por minuto.
- Gemas ocultas: se conserva el valor guardado (no se borra), pero no se muestran ni se otorgan.

### Prioridad 4 · Interfaz
- **Producción**: lanzar lote, lotes en línea y en cola (subir/bajar/pausar), lotes terminados que se
  siguen vendiendo, estaciones y capacidad.
- **Centro de ventas**: por modelo, miniatura 3D, año/generación, precio, fabricadas, vendidas,
  disponibles, avance del lote, ventas por minuto, ingresos, resultado, estado de producción y estado
  comercial, «Modificar precio» y «Cerrar venta»; pestaña de agotados y retirados.
- **Catálogo**: diseños con estimación de ventas, lanzar lote, editar, **nueva generación**, duplicar,
  eliminar; historia de cada modelo con todas sus generaciones y lotes.
- **Mercado y competidores**: demanda por tipo, reparto entre tu empresa y cada rival, y ficha de cada
  marca. **Investigación** por década con tiempo estimado y PI/min. **Compañía** con las cinco sedes.
  **Estadísticas** por mes. **HUD** con la fecha («Ene 1970»), PI/min y noticias de la época.
- **Editor**: opciones bloqueadas por época o investigación con el motivo, rodado máximo por año,
  generación y año fijados al guardar, ventas estimadas y atractivo en la revisión, diagnóstico de la
  vista 3D (ver Studio, punto 4).
- Celular: los chips del encabezado se omiten en pantallas angostas y el botón del menú pasa a ícono.

### Prioridad 5 · Pruebas y entrega
- `tests/run.luau` reescrito (622 comprobaciones) y `tests/ui.luau` actualizado (250).
- `tests/balance.luau`: bot que juega la partida completa y muestra el ritmo.
- `tests/fixtures/save_v2.json`: partida real de la versión anterior para probar la migración.

## 3. Migración de partidas guardadas (esquema 2 → 3)

`GameState.MIGRATIONS[2]`. Nada se pierde ni aparece de la nada; lo que deja de existir se reintegra:
autos sin vender → su costo; unidad en curso → lo cobrado al empezarla; materiales y piezas → su precio
de proveedor; investigaciones del árbol anterior → su costo. Se conservan dinero, diseños (como 1.ª
generación), sede, personal, nivel de estaciones, estadísticas, contadores, reputación y gemas. Cada día
anterior pasa a ser un mes desde enero de 1970. La empresa recibe un aviso con el detalle.

## 4. Estado de cada parte

| Estado | Parte |
|---|---|
| **Completo (verificado con pruebas automáticas)** | Lotes con cantidad libre; producción que se detiene y no se repite; pago por unidad sin deuda; ventas automáticas sin negociación; ventas ≤ fabricadas; varios modelos a la vez; Cerrar venta; Retirado no vuelve a vender; historial y contabilidad; calendario desde 1970; PI por sede; investigación bloqueada por época y requisitos; efectos reales de cada tecnología; guardado y carga con lotes; migración desde la versión anterior; reenvíos idempotentes; candado de sesión; tutorial completable en las tres dificultades; pantallas en las cuatro resoluciones sin errores ni desbordes. |
| **Completo en código, sin probar en Studio** | Aspecto final de todas las pantallas; vista 3D del editor (ViewportFrame) y miniaturas; garaje 3D (muestra el lote en fabricación, el stock por modelo y dos modelos en el concesionario); ProximityPrompts; DataStore real. |
| **Parcial** | **Equilibrio de largo plazo**: con la estrategia del bot la Corporación llega hacia 1983 y el Imperio no antes de 2000 (150.000 autos vendidos); a partir de los 90 el dinero se acumula sin mucho en qué gastarlo. Faltan sumideros o metas tardías. **Modelos 3D por época**: los autos son el modelo provisional por tipo (cambian pintura, llantas, faros LED, etc.), no hay carrocerías distintas por década. **Competidores**: compiten en el reparto y se muestran; no reaccionan a tus precios. |
| **Pendiente** | Eventos de temporada, amigos y tienda (marcados como «no implementado»); conducir o probar los autos en 3D; animación de producción en el garaje más allá de un auto por línea. |

## 5. Equilibrio actual (bot `tests/balance.luau`)

Estrategia: dos diseños al empezar, lotes de ≈ 8 minutos de ventas pagables con la mitad de la caja,
mejoras de estaciones, investigación más barata disponible, ampliación apenas se puede.

| Hito | Relajado | Normal | Magnate |
|---|---|---|---|
| Primera venta | 0,3 min | 0,3 min | 0,3 min |
| Tutorial completo | ≈ 2 min | ≈ 2 min | ≈ 2 min |
| Empresa pequeña | 14 min (1971) | 15 min (1971) | 15 min (1971) |
| Sede empresarial | 51 min (1974) | 52 min (1974) | 52 min (1974) |
| Corporación automotriz | 145 min (1983) | 150 min (1983) | 160 min (1984) |
| Dinero mínimo | $101.388 | $41.388 | $15.910 |

Parámetros centrales: `Catalog.CALENDAR.realSecondsPerYear`, `Catalog.ECON`, `Catalog.DEMAND`,
`Catalog.SEDES`, `Catalog.RESEARCH_TIERS` y `Catalog.EXPECTED_PI`. Después de cambiarlos:
`lune run tests/balance.luau normal 120`.

## 6. Las 16 pruebas obligatorias

| # | Prueba | Dónde |
|---|---|---|
| 1 | Una empresa nueva comienza en 1970 | `run.luau` «[P1] …» |
| 2 | Diseñar y guardar | `run.luau` «[P2] …», `ui.luau` recorrido completo |
| 3 | Se fabrica exactamente el lote | `run.luau` «[P3][P4][P5] …» (10.000 unidades) |
| 4 | La producción se detiene al terminar | ídem |
| 5 | No se crean pedidos automáticos | ídem (también después de agotarse) |
| 6 | Se vende sin negociar | `run.luau` «[P6][P7][P8] …», `ui.luau` |
| 7 | Nunca se vende más de lo fabricado | invariantes en cada paso de todas las pruebas |
| 8 | Varios modelos se venden a la vez | `run.luau` «[P6][P7][P8] …» |
| 9 | Cerrar venta descarta lo que queda | `run.luau` «[P9][P10][P11] …», `ui.luau` |
| 10 | Un retirado no vuelve a vender | ídem |
| 11 | Historial y contabilidad correctos | ídem y «[P11] Contabilidad …» (conciliación exacta) |
| 12 | Ampliar la sede sube los PI/min | `run.luau` «[P12] …» |
| 13 | Investigación bloqueada por requisitos y época | `run.luau` «[P13] …» |
| 14 | Guardar y cargar con lotes | `run.luau` «[P14] …» (50.000 unidades, otro servidor) |
| 15 | La interfaz se adapta a PC y celular | `ui.luau` «[P15] …» (1600×900, 1280×720, 844×390, 390×844) |
| 16 | El tutorial se completa sin trabarse | `run.luau` «[P16] …» (las tres dificultades) |

La prueba 15 comprueba que todas las pantallas se construyen sin errores y que ningún panel ni el HUD
se salen del ancho de la pantalla en un entorno simulado; **no** reemplaza mirar el juego en Studio.

## 7. Cómo abrir y probar en Studio

1. Abrir `CarEmpireTycoon.rbxl` (o `rojo serve` + plugin). Para guardar de verdad: publicar y activar
   *Game Settings › Security › Enable Studio Access to API Services*.
2. Play. Crear una empresa: el HUD debe decir **Ene 1970**. A 1× el mes cambia cada ≈ 55 s.
3. Diseño → guardar. Producción → **Lanzar lote** con 1.000: la barra avanza y, al terminar, el lote
   dice «Lote completo» y no se crea otro.
4. **Vista 3D del editor:** al abrir Diseño, en *Output* tiene que aparecer
   `[CarEmpire] Editor 3D: el auto se ve (N piezas, vista de …)`. Si aparece «posible auto invisible»,
   el mensaje dice qué falta (ScreenGui, tamaño, cámara, modelo o encuadre). Además mirar que el auto
   quede centrado entre las herramientas y el panel en cada cámara (teclas 1–7) y en celular.
5. Ventas: el modelo vende solo; probar «Modificar precio» (el ritmo cambia) y «Cerrar venta» (la
   confirmación dice cuántas unidades se pierden; queda en «Agotados y retirados»).
6. Lanzar un lote de 50.000 con poco dinero: la línea pasa a «Sin fondos» y sigue sola con las ventas.
7. Investigación: el turbo dice «Disponible desde 1977»; ampliar la sede sube los PI/min.
8. Mercado: la cuota de tu empresa coincide con las ventas por minuto del Centro de ventas.
9. Garaje: el cartel de la línea muestra el lote en fabricación; en el depósito aparece un auto por
   modelo con stock y en el concesionario dos modelos en venta con su precio.
10. Con una partida guardada de la versión anterior: al abrirla aparece el aviso de actualización con
    el reintegro y la empresa se puede seguir jugando.
11. Device Emulator en 1600×900, 1280×720, 844×390 y 390×844: HUD, menú, Centro de ventas, diálogo de lote.
12. Guardado: salir y volver; abrir la misma cuenta en dos servidores (el segundo no pisa los datos).
