# Etapa 8 · Instalaciones y crecimiento empresarial

Auditoría e integración del sistema de instalaciones existente, sin rehacerlo.

- No se agregaron instalaciones, niveles, bonificaciones, tecnologías ni compras.
- No cambió ningún valor de balance.
- El esquema de guardado sigue en 19: los campos nuevos de las obras son opcionales.

## Auditoría: contratos reales

| Pieza | Dónde | Contrato |
|---|---|---|
| Catálogo | `Catalog.SEDES` (oficinas, `g.sede`), `Catalog.FACILITIES.factory/research.levels`, `FACILITIES.line2`, `PRODUCTS.line3` | Niveles 1–5 con costo, días y beneficios |
| Reglas | `Rules.facilityLevel`, `facilityDef`, `nextFacility`, `facilityChecks`, `expansionCost` (gestión), `buildSpeed` (organización), `maintenance` (finanzas), `lineRate`, `caps`, `piPerMinute`, `ownsLine` | Todo cálculo sale de acá |
| Acción | `Actions.upgradeFacility { kind }` (kind ∈ offices, factory, research, line2) | Valida requisitos, cobra al empezar y crea la obra en `g.facilities.builds` |
| Simulación | `Simulation.stepBuilds` | Avanza por días de juego × `buildSpeed`. Al terminar aplica el nivel una vez; las oficinas llaman a `Office.remap` |
| Línea 3 | `Sessions.processReceipt` → `profile.owned.line3` → `GameState.applyAccount` → `facilities.accountLine3` | Solo un recibo de Roblox la concede; vale para toda la cuenta |
| Interfaz | `client/FacilitiesView` (dentro de Compañía) | Lista a la izquierda y detalle a la derecha |
| Mundo | `server/Garage` | Parcela provisional; `Sedes.<asset>` opcional por nivel de fábrica |

## Tabla de instalaciones y niveles (catálogo real)

| Instalación | Nivel | Nombre | Costo | Días | Requisitos | Beneficio |
|---|---|---|---|---|---|---|
| Oficinas | 1 | Oficinas básicas · Garaje inicial | — | — | — | 3 empleados, alcance ×1, plano de 1 habitación |
| Oficinas | 2 | Oficinas ampliadas · Empresa pequeña | $300.000 | 60 | 300 vendidos, reputación 3,0 | 8 empleados, alcance ×2,5, 2 habitaciones |
| Oficinas | 3 | Sede corporativa · Sede empresarial | $2.500.000 | 120 | 3.000 vendidos, 3,4 | 16 empleados, alcance ×6, 3 habitaciones |
| Oficinas | 4 | Torre corporativa · Corporación automotriz | $60.000.000 | 200 | 20.000 vendidos, 3,9 | 30 empleados, alcance ×11, 4 habitaciones |
| Oficinas | 5 | Casa matriz global · Imperio automotriz | $400.000.000 | 300 | 100.000 vendidos, 4,3 | 50 empleados, alcance ×20, 5 habitaciones; habilita la expansión internacional |
| Fábrica | 1 | Garaje pequeño | — | — | — | 15 autos/min por línea |
| Fábrica | 2 | Taller mecánico | $200.000 | 45 | Oficinas 2 | 25/min, calidad +1, −3 % costo por unidad |
| Fábrica | 3 | Fábrica | $1.500.000 | 90 | Oficinas 3 | 55/min, +3, −6 %, acabados perlado y cromado |
| Fábrica | 4 | Planta industrial | $30.000.000 | 150 | Oficinas 4 | 100/min, +4, −10 % |
| Fábrica | 5 | Complejo automotriz | $200.000.000 | 240 | Oficinas 5 | 170/min, +5, −15 % |
| Centro de I+D | 1 → 5 | Centro inicial → Campus de innovación | $150.000 / $1,2 M / $25 M / $150 M | 45 / 90 / 150 / 240 | Oficinas del mismo nivel | 3 / 8 / 20 / 45 / 90 PI por minuto |
| Línea 2 | — | Línea de producción 2 | $150.000 | 30 | Dinero | Una línea más (progreso normal) |
| Línea 3 | — | Prémium (Robux, de la cuenta) | — | — | Recibo de Roblox | Una línea más, independiente de la 2 |

Reglas comunes:
- Una obra por instalación a la vez; instalaciones distintas pueden estar en obra simultáneamente.
- No hay cancelaciones.
- El costo lleva el descuento de gestión y queda fijo al empezar.
- La duración del catálogo queda fija; la organización del personal acelera el avance diario desde ese momento.
- Mantenimiento mensual: 0,3 % de lo invertido × (1 − finanzas), con un tope del 10 % de las ventas del mes
  anterior.

## Problemas encontrados y corregidos

| # | Problema | Corrección |
|---|---|---|
| 1 | Una obra no guardaba su nivel de origen ni el día de inicio, y la interfaz no mostraba lo pagado. | `upgradeFacility` guarda `from` y `startDay` (opcionales; validados al cargar). `Rules.buildInfo` deduce el origen en partidas viejas. La interfaz muestra "Nivel X → Y · pagado $… al empezar", el avance y los días que faltan. |
| 2 | Al terminar una obra, el guardado esperaba al autoguardado periódico (hasta 45 s). | `Sessions:tick` detecta el cambio de instalaciones (`Rules.facilitiesKey`) y guarda enseguida. |
| 3 | `Office.remap` no cambiaba la revisión de la oficina: un borrador del editor hecho sobre el plano anterior no se invalidaba. | La revisión sube al cambiar de plano. |
| 4 | Durante una obra, la vista previa del mantenimiento sumaba dos veces el costo ya pagado (encontrado por la prueba de interfaz). | Durante la obra no se vuelve a sumar. |
| 5 | La comparación antes/después era parcial: el centro solo mostraba sus PI y la fábrica no mostraba la capacidad total. | Filas calculadas con las reglas reales: <ul><li>PI totales y por hora;</li><li>capacidad total de la fábrica;</li><li>habitaciones y superficie de la oficina;</li><li>"fábrica y centro hasta nivel";</li><li>mantenimiento mensual;</li><li>ocupación de empleados.</li></ul> Si no hay mejora, se explica por qué: obra en curso, nivel máximo o línea ya comprada. |
| 6 | El mundo no reflejaba el crecimiento: siempre una línea, y ni centro ni oficinas. El cartel de la línea 1 mostraba el primer lote de cualquier línea. | Módulo puro nuevo `shared/FacilityVisuals.luau` (ver abajo). El cartel y el auto en fabricación son ahora por línea. |

Comprobado sin cambios:
- **Cobros y validación:** se cobra una vez y el pedido reenviado no vuelve a cobrar. Una solicitud rechazada no cobra nada. El cliente no puede fijar nivel, costo ni días.
- **Obras:** una obra pendiente no adelanta beneficios. Al terminar se aplica una sola vez. Las obras se detienen con la pausa y con los menús; 2× y 3× son proporcionales.
- **Producción durante una ampliación:** el lote conserva el costo por unidad y la cantidad (se pagó al crearlo); solo se fabrica más rápido al terminar la obra, según la regla actual.
- **Línea 3:** sin la 2 se usan la 1 y la 3, y la 2 nunca aparece sola.
- **Empresas:** cada empresa tiene sus instalaciones, y una empresa cerrada no avanza.

## Crecimiento visual provisional (`FacilityVisuals` + `Garage`)

- **Líneas 2 y 3:** cinta, rodillos y pórtico cuando son propias. Si no, el lugar marcado en el piso:
  - gris para la línea 2 ("se compra en Instalaciones");
  - amarillo para la línea 3 ("prémium").
- **Nave de la fábrica:**
  - nivel 2: vigas y columnas;
  - nivel 3: techo con lucernarios;
  - nivel 4: silos y pared más alta;
  - nivel 5: chimeneas y puente grúa.
- **Centro de investigación** (fondo derecho): un piso por nivel, cúpula desde el 3 y antena en el 5.
- **Oficinas:** torre detrás de la pared del fondo, de 10 a 38 studs. Asoma desde el nivel 2 y suma un ala en el 4.
- **Obra en curso:** andamio amarillo con el cartel "En obra".
- **Modelos definitivos:** cada grupo tiene `asset` (`NaveFabrica1–5`, `CentroInvestigacion1–5`, `Oficinas1–5`, `Linea2`, `Linea3`). Si existe `ServerStorage.CarEmpireAssets.Instalaciones.<asset>`, se clona ese modelo en `anchor`. Con un edificio de fábrica definitivo (`Sedes.<asset>`) no se dibuja la nave provisional.
- **Sin interacción:** las piezas no tienen colisión y la gestión sigue por menús.
- **Sin cambios:** el showroom y el menú principal no se tocaron.

**No verificado en Roblox Studio:** el aspecto, la escala y la legibilidad de los carteles. Las pruebas solo verifican las piezas en el entorno simulado: niveles, que no se superpongan con lo existente al nivel del piso, que queden dentro del terreno y que el resultado sea determinista.

## Comparación numérica antes y después

**Centro de investigación** (prueba [IS3], sin líneas fabricando):

| Mejora | PI por minuto real a 1× | PI por hora real a 1× | PI por hora de juego | Costo | Días |
|---|---|---|---|---|---|
| 1 → 2 | 3 → 8 | 180 → 480 | 0,3 → 0,8 | $150.000 | 45 |
| 2 → 3 | 8 → 20 | 480 → 1.200 | 0,8 → 2 | $1.200.000 | 90 |
| 3 → 4 | 20 → 45 | 1.200 → 2.700 | 2 → 4,5 | $25.000.000 | 150 |
| 4 → 5 | 45 → 90 | 2.700 → 5.400 | 4,5 → 9 | $150.000.000 | 240 |

- La hora de juego se calcula con `Rules.perGameMinutes(pi, 60)`. Como 1 s real equivale a 10 min de juego,
  una hora de juego son 6 s reales.
  - A 2× y 3× pasan más horas de juego por segundo real, pero los PI por hora de juego son los mismos.
  - Corrección posterior a la entrega de la etapa 8: se mostraba la hora real (PI por minuto × 60) con la
    etiqueta "por hora de juego".
- Cada línea fabricando suma 2 PI por minuto real en cualquier nivel.
- **Superficie de las oficinas:** se mide en casillas de la cuadrícula (ancho × fondo). Cada casilla mide
  `OfficeCatalog.CELL` = 2 studs de lado; no hay escala física definida, así que no se muestran metros.
  - Antes se mostraba la misma cifra con la etiqueta m².

| Plano | Casillas | studs² |
|---|---|---|
| 1 | 80 | 320 |
| 2 | 156 | 624 |
| 3 | 251 | 1.004 |
| 4 | 398 | 1.592 |
| 5 | 584 | 2.336 |

**Fábrica** (sin mejoras de estaciones ni personal):

| Nivel | Autos/min por línea | 1 línea | 2 líneas | 3 líneas |
|---|---|---|---|---|
| 1 | 15 | 15 | 30 | 45 |
| 2 | 25 | 25 | 50 | 75 |
| 3 | 55 | 55 | 110 | 165 |
| 4 | 100 | 100 | 200 | 300 |
| 5 | 170 | 170 | 340 | 510 |

**Mantenimiento:** cada obra suma el 0,3 % de su costo por mes. Por ejemplo, la línea 2 suma $450 por mes y el centro 2 otros $450 (antes del tope por ventas y del descuento de finanzas).

## Recorrido de crecimiento con la economía real (bot, prueba [IS7])

| Obra | Año de inicio → fin | Costo |
|---|---|---|
| Línea 2 | 1970 → 1970 | $150.000 |
| Oficinas 2 | 1971 → 1972 | $300.000 |
| Fábrica 2 y centro 2 | 1972 → 1972 | $200.000 y $150.000 |
| Oficinas 3 | 1975 → 1976 | $2.500.000 |
| Fábrica 3 y centro 3 | 1976 → 1977 | $1.500.000 y $1.200.000 |
| Oficinas 4 | 1984 → 1984 | $60.000.000 |
| Fábrica 4 y centro 4 | 1984 → 1985 | $30.000.000 y $25.000.000 |
| Oficinas 5 | 2003 → 2004 | $400.000.000 |
| Fábrica 5 y centro 5 | 2004 → 2005 | $200.000.000 y $150.000.000 |

- Se hicieron 13 obras y cada una se cobró exactamente una vez.
- Lo invertido es igual a lo cobrado.
- La fábrica y el centro nunca superaron a las oficinas, y los niveles se completaron en orden.

## Pruebas

**Servidor y reglas** (entorno simulado), en `tests/run.luau`:

| Prueba | Cubre |
|---|---|
| `[IS1]` | Casos 1–10 |
| `[IS2]` | Casos 11–17 |
| `[IS3]` | Casos 18–20 |
| `[IS4]` | Casos 21–28 |
| `[IS5]` | Casos 29–33, 35 y 36 |
| `[IS6]` | Crecimiento visual provisional |
| `[IS7]` | Recorrido de crecimiento con la economía real |

**Interfaz** (entorno simulado), en `tests/ui.luau`: "Instalaciones (etapa 8)", caso 34. Cubre:
- la comparación con los valores reales;
- la obra en curso;
- el motivo cuando no hay mejora.

**Roblox Studio:** no se ejecutó nada.

## Pendientes y decisiones

- **Organización durante una obra:** acelera el avance diario de las obras ya iniciadas. Es la regla actual, igual que la creatividad en la investigación; el costo y la duración guardados no cambian.
- **Mantenimiento de obras en curso:** cuenta lo invertido desde que se paga, no desde que termina. Es la regla actual.
- **Línea 2:** su único requisito es el dinero. Es lo que define el catálogo actual.
- **Ampliar la fábrica con lotes en curso:** los lotes se fabrican más rápido desde que termina la obra. El costo de cada lote no cambia.
- **Recuperación de muebles al ampliar la oficina:** si un mueble queda en el paso de una puerta del plano nuevo, vuelve al inventario sin reembolso ni pérdida. Los muebles siguen siendo del jugador.
- **Expansión internacional:** ya existe tras las oficinas 5 (`Catalog.EXPANSION`, `expandGlobal`); no se tocó.
  - El sistema de instalaciones queda listo para sumar sedes por país sin cambiar el formato de las obras: `kind`, `from`, `level`, `cost`, `days` y `progress`, con validación por tipo.
  - El crecimiento visual admite grupos nuevos.

## Compatibilidad con partidas anteriores

- Sin cambio de esquema.
- Las obras guardadas antes de esta versión (sin `from` ni `startDay`) se validan y se muestran: el origen se deduce como destino − 1.
- Niveles, líneas (incluida `lines["3"]` de partidas migradas), lo invertido, la oficina y su plano se cargan igual.
- No se guardan estadísticas derivadas: bonos, capacidades y PI por minuto se recalculan.
