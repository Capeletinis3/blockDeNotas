# Etapa 9 · Expansión internacional y mercado mundial

Se completó la expansión comercial existente sobre la misma arquitectura:
- mapa mundial interactivo;
- preferencias de mercado por país;
- estadísticas del mercado internacional;
- integración con la demanda real.

**Sin cambios:**
- costos, crecimiento, demanda (+15 %), capacidad (+12 %) y ventas requeridas de `Catalog.EXPANSION`;
- los diez países, sus ids y su orden;
- el esquema de guardado (19).

## 1. Auditoría de la expansión anterior

| Pieza | Contrato real |
|---|---|
| `Catalog.EXPANSION` | `cost` 80.000.000 · `growth` 1,4 · `demand` 0,15 · `line` 0,12 · `soldBase` 110.000 · `soldStep` 35.000 · `countries` (10, ids estables) · `regions` (nombres, por compatibilidad) |
| `Rules.expansion(g)` | `g.expansion` (cantidad de aperturas) |
| `Rules.marketFactor(g)` | 1 + 0,15 × aperturas: crecimiento global. Lo usan las campañas corporativas y las metas de misiones escaladas |
| `Rules.openedCountries(g)` | `g.countries`; en partidas viejas que solo guardaban la cantidad, se completa con los primeros N del catálogo |
| `Rules.nextExpansion` / `expansionChecks` | Cotización y requisitos, solo con oficinas 5. Sin oficinas 5 devolvían nada, y la interfaz no podía mostrar qué faltaba |
| `Rules.demand(g, tipo)` | **Antes:** curva(año) × `marketFactor`, es decir, +15 % igual en todos los tipos |
| `Rules.marketPool()` | **No existe** en el código. El reparto con rivales y el resto del mercado está en `Rules.market(g, tipo)`, que usa `Rules.demand` una sola vez |
| `Actions.expandGlobal` | Valida país, duplicado, oficinas 5, ventas y dinero; cobra y agrega a `g.countries`. Está en `Actions.important`, así que se guarda enseguida |
| `Simulation.stepSales` | Vende por tipo a escala mundial con `Rules.market`. No hay ventas por país |
| Interfaz | Lista de diez tarjetas en Compañía (sin mapa) |

## 2. Módulos

**Nuevos:**
- `client/WorldMap.luau`: mapa, solo visual.
- `client/ScreenExpansion.luau`: pantalla Compañía › Expansión internacional.

**Modificados:**

| Módulo | Cambio |
|---|---|
| `Catalog` | `prefs` por país; textos de las misiones s13, s16 y s18 |
| `Rules` | `baseDemand`, `countryWeights`, `typeMarketFactor`, `demand`, `countryDemand`, `worldDemand`, `expansionQuote`, `expansionRequirements`, `countryState` |
| `Actions.expandGlobal` | Verificación de coherencia y datos para la confirmación |
| `ScreenCompania` | Resumen y botón "Abrir el mapa mundial" |
| `ScreenMarket` | Pestaña "Mercado internacional" |
| `ScreenHud` | Accesos a la expansión |
| `App` | Ruta en pausa |
| `Main.client` | Registro de la pantalla |
| `Dialogs` | Ayuda de la pantalla |
| `Ui.between` | Nombre opcional |

## 3. Mapa interactivo

- **Proyección:** equirectangular recortada. La longitud −180…180 va a x 0…1 y la latitud 82…−58 a y 0…1. Los marcadores se ubican en la latitud y longitud aproximadas de cada país (`WorldMap.COUNTRY_GEO`).
- **Continentes:** 34 siluetas estilizadas (rectángulos redondeados en grados), con océano degradado y paralelos y meridianos cada 30°. Son provisionales y no dependen de assets externos. Para usar un mapa definitivo, poner su id en `WorldMap.TEXTURE` (misma proyección): se dibuja en lugar de las siluetas.
- **Estados de los marcadores:**
  - Disponible: azul con pulso suave.
  - Bloqueado: gris.
  - Abierto: color de la marca del jugador.
  - Seleccionado: aro blanco y un poco más grande.

  Hay una leyenda en el mapa.
- **Controles:**
  - clic en un marcador para seleccionarlo;
  - rueda del mouse para hacer zoom hacia el cursor, con un tope de 1× a 4×;
  - arrastre para desplazarse, con límites;
  - botones + y −, y "Ver todo" para volver al encuadre completo;
  - tooltip con nombre y estado al pasar el cursor.

  En celular, el mapa va arriba y el panel debajo, con arrastre y botones de zoom.
- **Rendimiento:**
  - diez marcadores y unas cuarenta piezas de fondo;
  - elegir otro país solo reconstruye el panel lateral;
  - la vista (zoom y centro) y la selección viven en `App.ui`, no en la partida;
  - una sola conexión global de arrastre, que se desconecta al destruir el mapa;
  - los pulsos se cancelan al salir;
  - al cambiar de empresa, la selección y la vista se reinician.
- **Panel del país:**
  - nombre y estado;
  - costo de apertura (el mismo para cualquier país: depende de cuántos abriste);
  - autos vendidos requeridos;
  - requisitos con su progreso: oficinas 5, ventas y dinero;
  - impacto en la demanda mundial (×actual → ×nuevo) y autos/min que suma este año;
  - autos/min por línea antes → después;
  - preferencias por tipo, indicando qué tipos todavía no fabricás;
  - botón de expansión con confirmación.

  Si el país ya está abierto, el botón se reemplaza por la presencia comercial: número de apertura, demanda que aporta, peso en la demanda mundial y capacidad que suma.
- **Confirmación:** se pide antes de cobrar. Al abrir aparece un aviso breve de 6 s ("¡Nueva expansión internacional! Tu compañía llegó a Japón.", con demanda, producción y países abiertos) y el marcador destella. No bloquea la partida.

## 4. Preferencias de mercado

`prefs` es un peso por tipo de `Catalog.TYPE_ORDER` (compacto, sedán, clásico, pickup, deportivo, SUV, superdeportivo y eléctrico). Son parámetros ficticios del juego, entre 0,6 y 1,6, no estadísticas reales.

Para el año `y`, con `D[t]` = demanda base del tipo y `S = Σ D[t]`:

```
w[c][t] = p[c][t] × S / Σ_s p[c][s] × D[s]          (pesos normalizados del país c)
demanda[t] = D[t] × (1 + 0,15 × Σ_{c abierto} w[c][t])
```

- **Mismo volumen:** Σ_t D[t] × w[c][t] = S. Cada país suma exactamente +15 % de la demanda mundial base, igual que antes; solo cambia su reparto entre tipos.
- **Pesos iguales:** dan w = 1, el comportamiento anterior.
- **Tipo sin demanda en su época** (D = 0, por ejemplo SUV antes de 1983 o eléctrico antes de 2010): sigue en 0 aunque su peso sea alto.
- **Simulación:** determinista y sin economía paralela. `Rules.market` reparte esa demanda con los rivales y el resto del mercado con las reglas de siempre. Los rivales no cambian, la demanda se aplica una sola vez y la expansión no genera ingresos directos ni cambia precios ni costos.

## 5. Comparación de la demanda (autos/min, un país abierto)

| Tipo · 2000 | Base | Antes (+15 % parejo) | Japón | Estados Unidos | Brasil | Emiratos |
|---|---|---|---|---|---|---|
| Compacto | 252,0 | 289,8 | 306,2 | 271,9 | 301,9 | 273,5 |
| Sedán | 270,0 | 310,5 | 313,5 | 309,1 | 309,2 | 312,2 |
| Clásico | 43,0 | 49,4 | 47,0 | 49,8 | 47,5 | 48,5 |
| Pickup | 153,0 | 175,9 | 165,3 | 185,3 | 179,2 | 172,6 |
| Deportivo | 86,0 | 98,9 | 101,0 | 99,6 | 93,9 | 101,9 |
| SUV | 189,0 | 217,3 | 209,3 | 226,3 | 211,4 | 232,0 |
| Superdeportivo | 18,0 | 20,7 | 20,2 | 20,6 | 19,4 | 22,1 |
| Eléctrico | 0 | 0 | 0 | 0 | 0 | 0 |
| **Total** | 1.011,0 | 1.162,7 | 1.162,7 | 1.162,7 | 1.162,6* | 1.162,7 |

\* Diferencia de redondeo de la tabla; la prueba verifica la igualdad con precisión de 1e-9.

En 2020 el total es 1.213,0 de base y 1.394,9–1.395,0 con un país, también según la tabla. El eléctrico ya tiene demanda: Japón suma 160,6 contra 155,2 del reparto parejo.

## 6. Mercado internacional (Mercado › pestaña "Mercado internacional")

- **Presencia:**
  - países abiertos y pendientes;
  - demanda mundial y aporte de las expansiones;
  - capacidad extra por línea;
  - próximo costo y progreso de ventas hacia la próxima apertura;
  - aviso si faltan las oficinas 5.
- **Preferencias por mercado:** botones de país y barras por tipo. Elegir un país actualiza solo las barras.
- **Evolución comercial:**
  - demanda mundial base → con tus países en el año actual, +5, +10 y 2030;
  - por tipo, demanda ahora → en 10 años, con el motivo si todavía no podés fabricar ese tipo (por ejemplo, "Requiere investigar «Plataforma SUV»").

## 7. Pruebas

**Servidor y reglas** (entorno simulado), en `tests/run.luau`:

| Prueba | Cubre |
|---|---|
| `[EX1]` | Casos 1–14 |
| `[EX2]` | Casos 15–24 |
| `[EX3]` | Casos 34–39 |

Además se actualizó `[F8]`: el +15 % ahora se verifica en el total mundial y el sedán según el peso de Sudáfrica.

**Interfaz** (entorno simulado), en `tests/ui.luau`:
- "Expansión internacional (etapa 9)": casos 25–33, la pestaña de mercado internacional y el texto de los diez abiertos;
- "Fin de partida": la pantalla de expansión no se desborda en 1600×900, 1280×720, 844×390 ni 390×844.

**Caso 40** (compatibilidad con las etapas 1 a 8): las suites completas siguen en verde.

| Comprobación | Resultado |
|---|---|
| Servidor | 11.274 correctas, 0 fallidas |
| Interfaz | 3.188 correctas, 0 fallidas |
| Linter | 0 errores, 0 avisos |
| Place | 60 scripts verificados |

**Roblox Studio:** no se ejecutó nada.

## 8. Compatibilidad con partidas antiguas

- Sin migración nueva.
- `g.expansion` y `g.countries` se conservan.
- Una partida que solo tenía la cantidad de regiones (por ejemplo 3) ve abiertos Brasil, Estados Unidos y Alemania, como ya hacía `Rules.openedCountries`. Al abrir otro país, la lista se completa y se guarda.
- Cada empresa conserva su expansión.
- Las misiones s13, s16 y s18 siguen contando `g.expansion`; las ya reclamadas no se repiten.
- Cambio esperado: en una partida con países abiertos, la demanda por tipo pasa a repartirse según las preferencias. La demanda mundial total es la misma.

## 9. Limitaciones y pendientes

- **No verificado en Roblox Studio:**
  - el aspecto del mapa;
  - el arrastre y la rueda con mouse real;
  - el tooltip;
  - las animaciones;
  - el rendimiento.

  En el entorno simulado se ejercitaron la selección, los botones, la rueda y el desplazamiento, pero no se vio el resultado visual.
- **Celular:** no hay zoom con pellizco, solo botones y arrastre. La disposición del celular está preparada y probada contra desbordes.
- **Continentes:** son siluetas provisionales; Alemania y Polonia quedan juntas con el zoom al mínimo.
- **Ventas por país:** no hay. La simulación vende por tipo a escala mundial, y el panel muestra demanda aportada, no ventas.
- **Aviso de apertura:** se ve si la apertura se hace desde el mapa. Desde otras pantallas queda la notificación de siempre.

## 10. Cómo usarla en el juego

1. Llegar a las oficinas centrales de nivel 5 y a las ventas requeridas: 110.000 autos para la primera apertura, 35.000 más por cada siguiente.
2. Compañía › "Abrir el mapa mundial", o el acceso del HUD cuando la expansión está disponible.
3. Tocar el país en el mapa y revisar el panel: costo, requisitos, demanda que suma y preferencias.
4. "Expandirme a …" → confirmar. El costo lo calcula el servidor y se cobra una sola vez.
5. Mercado › "Mercado internacional" para ver la presencia mundial, las preferencias y la evolución.

## 11. Ajustes posteriores

### Marcadores cercanos (Alemania y Polonia)

- `WorldMap.separate(puntos, ancho, alto, zoom)`: función pura y determinista.
  - Corre visualmente, en píxeles y de forma simétrica, los marcadores que quedan a menos de `MIN_SEP` = 30 px.
  - Se calcula con el tamaño real del mapa y el zoom actual. Se recalcula al hacer zoom y al cambiar el tamaño del mapa.
  - Las coordenadas geográficas (atributos `x`, `y`) no cambian.
- Cuando un marcador está corrido:
  - queda un punto en su ubicación real;
  - con poco zoom, la etiqueta muestra el código del país (DE / PL) para distinguirlos.
- Con zoom suficiente (por ejemplo 4× en PC), el corrimiento vuelve a 0.
- **Ejemplo:** en un celular a 1× Alemania y Polonia quedaban a unos 10 px; ahora quedan a 30 px.

### Confirmación visual de la expansión

- **Problema:** el aviso podía perderse. En el entorno simulado, el estado nuevo del servidor llega (`App.onState`, que reconstruye la pantalla) antes de que vuelva `App.request`. El aviso pendiente se dejaba recién después, cuando la pantalla ya estaba armada. La prueba anterior solo lo veía porque volvía a abrir la pantalla.
- **Ahora el aviso es de un solo uso:**
  - un pedido aceptado deja el aviso pendiente y llama a `Screen.celebrate()`;
  - la pantalla también lo llama al armarse;
  - se muestra solo cuando la partida ya tiene el país abierto y en ese momento se consume. No importa en qué orden lleguen la respuesta y el estado, y nunca aparece dos veces;
  - un pedido rechazado no deja aviso;
  - un aviso pendiente vence a los 20 s y se descarta al cambiar de empresa.
- No fuerza reconstrucciones: el mapa actual actualiza los estados y destella una vez.

### Demanda real y potencial

- **Mercado internacional › Preferencias por mercado:**
  - un país abierto muestra la "demanda incorporada" (en verde y azul);
  - uno cerrado muestra la "demanda potencial … si lo abrís (no está en el mercado todavía)" (en amarillo).
- **Panel del país:**
  - cerrado: "Demanda potencial este año";
  - abierto: "Demanda incorporada este año".
- **Resumen mundial:** sigue contando solo las expansiones adquiridas.
- **Sin cambios:** las fórmulas y los perfiles.

### Pruebas (entorno simulado)

| Comprobación | Resultado |
|---|---|
| Servidor | 11.274 correctas, 0 fallidas |
| Interfaz | 3.422 correctas, 0 fallidas |

La prueba nueva "Ajustes de la etapa 9" cubre:
1. selección de los diez países con clic, en 390×844 y 1600×900;
2. Alemania y Polonia separadas al menos 30 px en cuatro tamaños de mapa, sin tocar sus coordenadas;
3. zoom y desplazamiento con límites;
4. apertura aceptada con un solo aviso;
5. rechazo sin aviso;
6. un solo destello, sin repetirse al reconstruir la pantalla;
7. demanda potencial de un país cerrado;
8. demanda incorporada de uno abierto;
9. +15 % con un país;
10. compatibilidad: las suites completas siguen en verde.

Comprobé que la prueba depende de la corrección: sin la llamada desde la respuesta del pedido, fallan 5 comprobaciones.

**Pendiente en Roblox Studio:**
- cómo se ven los marcadores corridos y el punto de ubicación;
- la legibilidad de los códigos DE / PL;
- el arrastre y la rueda con un mouse real;
- el aviso en el juego real, que depende del orden real de red entre la respuesta y el estado.

El entorno simulado no calcula los tamaños reales: le da al mapa 100×30 px.
