# Car Empire Tycoon · Roblox (etapa 6: correcciones finales)

Juego tycoon de autos en Roblox (Rojo + Luau). Empezás un taller en **1970**, diseñás autos, elegís
cuántas unidades fabricar en cada **lote**, se **venden solos** según la demanda, el precio y la
competencia, y con lo ganado ampliás la empresa e investigás tecnologías de cada época hasta 2030.
El prototipo `reference/Car-Empire-Tycoon-V3.html` sigue siendo la referencia visual.

**Etapa 6 (correcciones finales):** después de 2030 el año visible queda fijo y la empresa sigue en
años comerciales extra; expansión global en 10 regiones y misiones de fin de partida; margen distinto por
tipo de vehículo; banco de PI como acelerador y difusión tecnológica; historial de modelos que no borra
nada (resumen + récords permanentes); demostración «Imperio (después de 2030)»:
[`docs/CORRECCIONES-FINALES.md`](docs/CORRECCIONES-FINALES.md).

**Etapa 5 (segunda auditoría):** envío liviano al cliente, PI sin farmeo y banco de 20 minutos,
historial permanente por modelo y generación, rivales con estrategia y precios que cuentan, seguridad y
motores por época en el editor, economía con inversiones de peso (ingeniería, campañas por nivel,
estaciones hasta nivel 10) y pruebas de los 26 casos pedidos: [`docs/SEGUNDA-AUDITORIA.md`](docs/SEGUNDA-AUDITORIA.md).
Los modelos 3D siguen siendo provisionales por decisión de esta etapa: [`docs/FASE-3D.md`](docs/FASE-3D.md).

**Etapa 4 (auditoría):** producción por lotes de cualquier tamaño que se detiene al terminar, ventas
automáticas sin negociación con «Cerrar venta», calendario desde 1970, investigación histórica con PI
por minuto según la sede, marcas rivales, finanzas sin doble conteo, pantallas nuevas (Producción,
Centro de ventas, Catálogo, Mercado y competidores) y migración de las partidas anteriores. Detalle,
estado de cada parte (completo / parcial / pendiente), equilibrio y pruebas:
[`docs/CAMBIOS-AUDITORIA.md`](docs/CAMBIOS-AUDITORIA.md).

> **Importante:** este trabajo se hizo sin poder ejecutar Roblox Studio. Lo verificado es: pruebas de
> lógica (Lune), pruebas de interfaz sin pantalla sobre un entorno Roblox simulado, análisis estático
> (Selene), un bot de balance, la generación del `.rbxl` con Rojo y una **vista previa** de la interfaz
> (el árbol de la interfaz real dibujado con una emulación del diseño de Roblox). La vista previa no
> dibuja el mundo 3D ni los ViewportFrame: el aspecto final, la física, las cámaras, el DataStore real y
> el multijugador real **no están probados en Studio**. Ver la lista de pruebas en Studio.
> No hay que considerar el juego terminado hasta pasar esa lista.

## Estructura

```
car-empire-tycoon/
├─ default.project.json        Proyecto Rojo
├─ src/shared/  → ReplicatedStorage.CarEmpireShared
│   ├─ Catalog.luau            Catálogos y parámetros de equilibrio: calendario, economía, demanda por
│   │                          tipo y año, bases y piezas con su año, sedes, investigación 1970–2030,
│   │                          marcas rivales, misiones y noticias
│   ├─ Rules.luau              Reglas comunes a cliente y servidor: calendario, capacidades, PI/min,
│   │                          lotes, reparto de la demanda (mercado), investigación, finanzas, misiones
│   ├─ DesignCalc.luau         computeDesign, bloqueos por época/investigación, desarrollo, saneamiento
│   ├─ CarModel.luau           Auto provisional con Parts (editor, miniaturas y garaje)
│   └─ Util.luau               Redondeo como JS, dinero "$28.700", fechas "Ene 1970"
├─ src/server/  → ServerScriptService.CarEmpireServer
│   ├─ Main.server.luau        Remotos, servicios de Roblox, reloj
│   ├─ Sessions.luau           Sesiones por jugador: carga, ranuras, candado, guardado, límites
│   ├─ Actions.luau            Acciones validadas (diseños, lotes, precio, cerrar venta, investigación…)
│   ├─ Simulation.luau         Reloj mensual, producción de lotes, ventas automáticas, PI, cierre de mes
│   ├─ GameState.luau          Partida nueva, validación, migraciones (2 → 3), vista para el cliente
│   ├─ Demo.luau               Demostraciones (tutorial 1970, empresa en 1974, corporación en 1992)
│   ├─ DataService.luau        DataStore: candado de sesión, reintentos, datos dañados intactos
│   └─ Garage.luau             Vestíbulo + 8 garajes con el lote en fabricación y el stock por modelo
├─ src/client/  → StarterPlayer.StarterPlayerScripts.CarEmpireClient
│   ├─ Main.client.luau        Registro de pantallas y diálogos, eventos, atajos
│   ├─ App.luau                Estado, navegación, distribuciones, diálogos, valores en vivo
│   ├─ Ui.luau                 Componentes con las medidas y colores de la V3
│   ├─ Icons.luau, IconData    Íconos
│   ├─ WorldPrompts.luau       Indicaciones «E …» y puntos del garaje
│   ├─ ScreenMenu/Company      Inicio con ranuras de empresas y creación de empresa
│   ├─ ScreenHud/Sheet         HUD de la sede y hojas de cada sección
│   ├─ ScreenEditor            Editor de 4 pasos con vista 3D (y diagnóstico del ViewportFrame)
│   ├─ ScreenFactory           Producción por lotes      ScreenSales      Centro de ventas
│   ├─ ScreenInventory         Catálogo e historia       ScreenMarket     Mercado y competidores
│   ├─ ScreenResearch, ScreenStaff, ScreenCompania, ScreenMissions, ScreenStats, ScreenStatus
│   └─ Dialogs.luau            Lanzar lote, modificar precio, confirmaciones, ajustes, ayuda…
├─ tests/run.luau              Pruebas de lógica, guardado y las 16 obligatorias (Lune)
├─ tests/ui.luau + mock.luau   Pruebas de interfaz sin pantalla (cliente y servidor reales)
├─ tests/balance.luau          Bot de balance: juega una partida y muestra el ritmo
├─ tests/fixtures/             Partida real de la versión anterior (prueba de migración)
├─ tests/verify_place.luau     Verifica que un .rbxl contenga exactamente los scripts de src/
├─ tests/preview, scenes, dump Vista previa: lleva la partida a escenas y vuelca la interfaz
├─ tools/preview/              Dibuja la interfaz de Roblox y la compara con capturas de la V3
├─ docs/CORRECCIONES-FINALES.md Calendario después de 2030, fin de partida, historial, pruebas y Studio (etapa 6)
├─ docs/SEGUNDA-AUDITORIA.md  Errores corregidos, mejoras, equilibrio, pruebas y guía de Studio (etapa 5)
├─ docs/FASE-3D.md            Qué modelos provisionales reemplazar y cómo, sin tocar las mecánicas
├─ docs/CAMBIOS-AUDITORIA.md   Cambios, estado de cada parte, equilibrio y pruebas en Studio (etapa 4)
├─ docs/COMPARACION-V3.md      Comparación visual con la V3 (etapa 3)
└─ reference/                  Prototipo V3 original
```

## Cómo abrir el proyecto

**Opción A — archivo listo:** abrir `CarEmpireTycoon.rbxl` en Roblox Studio (generado con
`rojo build` a partir de estos mismos scripts; se comprobó con `tests/verify_place.luau`).

**Opción B — Rojo (para seguir desarrollando):**
1. Instalar [Rojo](https://rojo.space) 7 y su plugin de Studio.
2. En esta carpeta: `rojo serve`; en Studio: plugin Rojo → **Connect**.
3. O generar el archivo: `rojo build -o CarEmpireTycoon.rbxl`.

**Ajustes manuales en Studio**
- Guardado real: publicar el place y activar *Game Settings › Security › Enable Studio Access to API Services*.
  Sin esto el juego usa guardado temporal en memoria y lo avisa con una banda amarilla.
- Recomendado: *Max Players = 8* (hay 8 garajes por servidor; si no hay garaje libre se juega
  con los paneles y el garaje aparece cuando se libere uno).

**Comprobaciones fuera de Studio** (requieren [Lune](https://lune-org.github.io/docs) ≥ 0.10):
```
lune run tests/run.luau                 # lógica del servidor, guardado y las 16 pruebas obligatorias
lune run tests/ui.luau                  # interfaz sin pantalla (incluye 4 resoluciones)
lune run tests/balance.luau normal 680  # partida completa 1970–2030 con métricas (agregá «plano» para la estrategia mínima)
lune run tests/verify_place.luau CarEmpireTycoon.rbxl
selene src                              # análisis estático
```

**Comparación visual con la V3** (requiere Node y Playwright con Chromium):
```
node tools/preview/v3.js out/v3 1600 900            # capturas de la V3 (filtro opcional: 4.º argumento)
lune run tests/preview.luau out/rbx 1600 900        # vuelca la interfaz de Roblox en las mismas escenas
node tools/preview/render.js out/rbx out/rbx-png    # la dibuja
node tools/preview/compare.js out/v3 out/rbx-png out/cmp
```

## Historial de etapas anteriores

> Las etapas 1 a 3 describen mecánicas que la etapa 4 reemplazó (órdenes de hasta 50 unidades,
> salón y negociación con clientes, materiales, averías, cansancio, mercado de compraventa simulado,
> investigación por laboratorio). Se conservan como registro; el estado actual está en
> `docs/CAMBIOS-AUDITORIA.md`.

### Revisión inicial (estado que tenía la etapa 1)

| Estado | Elementos |
|---|---|
| Completo | Recorrido base diseño → orden → fabricación → salón → venta; validación en el servidor; dos jugadores independientes; candado de sesión básico. |
| Parcial | Editor (sin cámaras, deshacer, comparar ni muchas opciones visuales); fábrica (una línea, sin prioridades ni estaciones); inventario y ventas sin filtros, historial ni detalle; negociación con probabilidad aproximada en el cliente. |
| Faltante | Investigación, personal, compañía y sedes, misiones, mercado, estadísticas, configuración, ayuda, notificaciones, menú de empresas con ranuras, distribución para celular, íconos. |
| Problemas | Botón *Comenzar mi empresa* que quedaba deshabilitado al escribir (capturaba el estado inicial); Magnate imposible de empezar; textos de dificultad que prometían efectos inexistentes; renovación del candado atada a la simulación; sesión perdida sin bloqueo claro; carreras entre carga, reintento, salida y cierre; validación de datos incompleta; probabilidad de negociación distinta entre cliente y servidor; capacidad de almacén calculada de dos formas; cancelar una orden con depósito lleno perdía materiales; cambio de día después de la fabricación. |
| Necesita Studio | Aspecto visual, cámaras del editor, garajes, ProximityPrompts, teclado en celular, DataStore real, multijugador real. |

### Qué se hizo, qué se verificó y qué falta (por etapa)

#### 1. Bloqueos y guardado
- **Hecho:** botón de crear empresa reactivo; recompensas del tutorial de la V3 (primer diseño guardado
  → +$10.000) que hacen viable Magnate; textos de dificultad con solo efectos reales; candado renovado por
  su propio temporizador (60 s, vence a 300 s) aunque la partida esté en pausa; sesión perdida →
  estado «lost» que bloquea acciones con explicación; carga/reintento/salida/cierre serializados;
  validación completa de la partida (nivel, xp, reputación, reloj, contadores, investigación,
  configuración de diseños, unidades, estados permitidos, órdenes, historiales y referencias) con
  migración que separa campos viejos recuperables de daño real; ranuras dañadas se conservan sin
  tocar y no bloquean la pantalla de carga; negociación con probabilidad exacta del servidor, monto
  redondeado a $100, revisión (`rev`) que invalida consultas viejas y tirada fuera de los mensajes;
  una sola regla de capacidad; cancelar devuelve todo el material reservado; el cambio de día corre
  antes de producir.
- **Verificado:** `tests/run.luau` (204 comprobaciones), incluidas primera venta en las 3 dificultades sin
  dinero manual, candado en pausa larga, dos sesiones sobre la misma partida, salida durante carga y
  guardado, fallo de carga sin escritura, ranura dañada, migración y orden del cambio de día.
- **Falta:** probar con el DataStore real y cierres reales del servidor (Studio/publicado).

#### 2. Recorrido básico
- **Hecho:** entorno Roblox simulado (`tests/mock.luau`) que ejecuta el servidor y el cliente reales.
- **Verificado:** `tests/ui.luau` (143 comprobaciones): crear empresa escribiendo solo el nombre, recorrido
  completo con clics (diseñar, reclamar el tutorial una sola vez, orden de 6, fabricar, salón, vender),
  segunda empresa Magnate en otra ranura hasta su primera orden, independencia entre ranuras,
  eliminar empresa escribiendo el nombre, límite de acciones seguidas.
- **Falta:** el mismo recorrido en Studio (lista al final).

#### 3. Editor, fábrica, inventario y ventas
- **Hecho:** cámaras predefinidas sincronizadas con la vista, giro y zoom con límites, restablecer,
  encuadre por las dimensiones reales, deshacer/rehacer (Ctrl+Z/Ctrl+Y), comparar antes/después,
  puntos de identificación de piezas, estilos de llanta, intensidad y brillo, paragolpes, capó, difusor,
  faldones, faros, polarizado, vinilos, número, emblema e interior visibles en el modelo; cambios sin
  guardar protegidos al salir, crear proyecto, abrir otro y cambiar de empresa (guardar / descartar /
  seguir editando; si guardar falla se conserva el borrador); nombres duplicados, duplicar y eliminar
  como la V3 sin tocar unidades ni órdenes. Fábrica con líneas, prioridades, botones para reordenar y
  arrastre, estaciones con desgaste, averías, reparación y mejoras, producción automática por
  investigación, aceleración con recargo, repetir «misma versión» o «última versión guardada», cobro
  real por unidad registrado y limpieza de detenciones resueltas. Inventario con búsqueda, filtros,
  orden, detalle con vista reconocible, versión y lo cobrado. Ventas con precio de lista, descuentos,
  precio final, efecto en el interés, promoción, mayorista, detalle e historial con filtros; lista,
  oferta, ingreso y margen separados; el diálogo se actualiza o se bloquea si el auto se vende o retira;
  reenvíos idempotentes.
- **Verificado:** pruebas de lógica (repetir orden, recargo, capacidad, cancelación, probabilidad) y de
  interfaz (cambios sin guardar, deshacer/rehacer, negociación que se invalida, todos los diálogos).
- **Falta en Studio:** cámaras, encuadre, puntos sobre el auto, arrastre de órdenes, legibilidad de
  las miniaturas.

#### 4. Misiones, investigación, personal y ampliaciones
- **Hecho:** tutorial/historia/diarias con reclamo persistente y pago único; recompensa diaria por fecha
  UTC; árbol de investigación con efectos reales; personal (contratar, despedir, descansar, asignar a
  estaciones o departamentos); identidad de marca y 4 sedes con requisitos.
- **Verificado:** pruebas de lógica dedicadas (efectos, salarios, PI, requisitos, doble reclamo).

#### 5. Mercado, finanzas y pantallas secundarias
- **Hecho:** mercado simulado con vendedores ficticios (no hay intercambio entre jugadores reales):
  compra directa, subastas, publicar y retirar, ofertas; estadísticas de 7/14/30 días desde agregados
  diarios comunes (no se calculan con listas recortadas); configuración guardada en el servidor
  (tamaño de interfaz, velocidad de cámara, reducir movimiento, atajos, sonidos); ayuda por pantalla;
  historial de notificaciones. Amigos, Tienda y Eventos marcados como funciones futuras.
- **Verificado:** pruebas de lógica (mercado, estadísticas tras recortar historiales) e interfaz
  (configuración persistida y valores fuera de rango rechazados).

#### 6. Interfaz, imagen y mapa
- **Hecho:** identidad de la V3; distribuciones escritorio / computadora chica / tableta / celular
  (navegación con menú, columnas que se apilan, paneles plegables, diálogos arriba para no quedar
  bajo el teclado, áreas seguras; el tamaño del texto se elige en Configuración); íconos dibujados
  en lugar de emojis; miniaturas 3D de los autos; estados de proceso/error sin perder lo escrito.
  Garajes provisionales que muestran fábrica, almacén y salón; si no hay parcela libre se espera y
  se asigna al liberarse. Los autos son modelos provisionales, no se conducen; no hay carreras.
- **Verificado:** todas las pantallas y diálogos se construyen en escritorio y en celular sin errores
  (prueba de interfaz). **No** verificado: cómo se ven.

#### Etapa 3. Fidelidad con la V3
- **Hecho:** menú, nueva empresa, HUD de la sede, las nueve secciones, el editor completo (barra
  superior, cámaras con tecla, estadísticas, pasos, barra de herramientas, panel de 440 px, selector de
  color, antes/después con divisor, ocultar interfaz, puntos de piezas), todos los diálogos y la
  distribución de celular siguen la V3. Atajos de la V3 (Esc, Enter, Tab, 0–8, [ ] H 1–7, Ctrl+Z/Y).
  Demostraciones de la V3 desde el menú. Indicaciones del garaje con la píldora y los puntos de la V3.
- **Correcciones respecto de la V3 que se mantienen:** textos de dificultad honestos, probabilidad de la
  negociación calculada por el servidor y sin detalles de la tirada, una sola regla de capacidad,
  promoción solo con «Promociones» investigada, estadísticas desde agregados diarios, pestañas
  Exterior/Interior visibles en el editor.
- **Verificado:** 75 escenas de escritorio y 12 de celular comparadas con la V3 en la vista previa
  (ver `docs/COMPARACION-V3.md`); 235 pruebas de lógica y 157 de interfaz sin fallas; Selene sin avisos.
- **No verificado:** el aspecto en Studio (fuente real, 3D, ViewportFrame, BillboardGui) y los toques.

## Lista de pruebas pendientes en Roblox Studio

Primero los 11 pasos de [`docs/SEGUNDA-AUDITORIA.md`](docs/SEGUNDA-AUDITORIA.md#cómo-probar-en-studio) y después los 12 de [`docs/CAMBIOS-AUDITORIA.md`](docs/CAMBIOS-AUDITORIA.md#7-cómo-abrir-y-probar-en-studio)
(lotes, ventas automáticas, Cerrar venta, calendario, investigación, **vista 3D del editor con el
diagnóstico en Output**, garaje, migración, resoluciones y guardado). Además, de las etapas anteriores:

1. Crear empresa escribiendo solo el nombre: el botón se habilita mientras escribís.
2. Editor: cada cámara, giro con arrastre, zoom con rueda y botones, restablecer; cambiar cada opción
   visual (llantas, faros, vinilos, número, emblema, interior…) y verla en el auto; comparar; Ctrl+Z/Y.
3. Intentar salir del editor, abrir otro proyecto y volver al menú con cambios: debe preguntar.
4. Garaje: ProximityPrompts (tecla E), que el cartel muestre tu empresa, cámara y obstáculos del camino.
5. Celular (*Device Emulator*): navegación, paneles, diálogos con el teclado abierto, áreas seguras.
6. Con API activada: cerrar el servidor durante un guardado; abrir la misma cuenta en dos servidores.
7. *Test › Clients and Servers* con 2 y con 9 jugadores: empresas independientes y el noveno espera garaje.
8. Sonido de los avisos y la opción Configuración › Sonidos.
9. Demostraciones del menú: se juegan sin tocar las ranuras y «Salir» vuelve al menú.

## Reglas de seguridad y guardado

- El cliente envía intenciones e identificadores; el servidor recalcula costos, precios, producción,
  ventas, investigación y desbloqueos, y valida pertenencia, cantidades, rangos de precio, época y
  dinero. Si algo falla no se cambia nada. Los lotes son contadores agregados: un lote de 50.000 autos
  ocupa lo mismo en el guardado que uno de 10.
- Nombres de empresas y diseños pasan por `TextService` (se ven en el garaje para todos).
- Una acción por jugador a la vez, límite de 14 solicitudes cada 2 s, identificador por solicitud
  para que un reenvío no se aplique dos veces.
- Clave por jugador `player_<UserId>` con 3 ranuras; `UpdateAsync` con candado de sesión.
- Si la carga falla: se informa con *Reintentar* y esa sesión no guarda nada. Las ranuras dañadas
  se conservan tal cual.
- Autoguardado cada 45 s con cambios, guardado tras acciones importantes, al salir y al cerrar.
