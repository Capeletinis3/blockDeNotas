# Etapa 10 · Doce marcas rivales, competencia, marketing y mercado dinámico

Las seis marcas anteriores se reemplazaron por doce fabricantes ficticios, evolucionando la arquitectura
existente.

**Qué se mantuvo:**
- el reparto `Rules.market`;
- las ofertas deterministas de `Rules.rivalOffers`;
- las campañas;
- el esquema de guardado (19).

**Qué no se agregó:** categorías, tecnologías ni sistemas económicos nuevos.

## 1. Auditoría de la arquitectura anterior

- **Ofertas:** `Rules.rivalOffers(tipo, año, g)` calcula las ofertas de forma determinista desde `Catalog.RIVALS`:
  - atractivo = curva de la marca + ciclo de generación + variación;
  - precio = precio justo × posicionamiento × (1 − baja por reacción);
  - peso = e^(atractivo/12) × factor de precio × alcance.
- **Reparto:** `Rules.market` reparte la demanda del tipo entre el resto del mercado (peso 45), las ofertas rivales y tus lotes. Las ventas solo consumen stock (`Simulation.stepSales`).
- **Persistencia:** no se guarda ningún id de rival. Lo único persistido es:
  - `g.marketShare`: tu cuota por tipo, promedio mensual, con la que reaccionan los rivales;
  - `g.rivalNews`: los textos de las novedades del último año;
  - las notificaciones, que son texto.
- **Marketing:** `Rules.campaignPlan` es el mismo cálculo en la interfaz y en el servidor. Se paga al empezar.
  - análisis: abarata el costo;
  - creatividad: potencia el efecto, en vivo;
  - comunicación: alarga la duración, en vivo;
  - la corporativa cuesta × `marketFactor` (expansión internacional) y suma reputación cada mes.

## 2. Módulos

| Módulo | Cambio |
|---|---|
| `Catalog` | `RIVALS` (doce), `RIVALS_V1` (las seis anteriores, solo calibración), `RIVAL_RULES` |
| `Rules` | `rivalLines`, `rivalBaseOffset`, `rivalReach`, `rivalScale`, `rivalOffers`, `rivalLeader`, `lotWeightAt`, `lotRateAt`, `campaignPreview`, `shareSummary` |
| `Simulation` | `rivalNewsFor` y las noticias de enero |
| `ScreenMarket` | Cuotas actual e histórica, ficha de cada marca |
| `ScreenSales` | Editor de precio |
| `Dialogs` | Campaña con comparación |
| Pruebas | `tests/run.luau` (`[RV1]`–`[RV5]`, `[C24]` y `[F6]` ajustadas) y `tests/ui.luau` (etapa 10) |

## 3. Los doce fabricantes (ficticios)

| Marca | País | Especialidad | Estrategia | Precio | Calidad / prestaciones | Respuesta |
|---|---|---|---|---|---|---|
| Baviron Motors | Alemania | Sedanes deportivos prémium | Calidad y rendimiento, precio alto | ×1,18 | +2 / +2,5 | calidad |
| Mercenza | Alemania | Lujo, seguridad, confort | Prestigio, precio muy alto | ×1,30 | +3 / +1 | calidad |
| Volkenwerk | Alemania | Compactos y familiares accesibles | Precio competitivo, gran volumen | ×0,92 | +1 / −1 | precio |
| Stuttaro | Alemania | Coupés deportivos de precisión | Poco volumen, precio alto | ×1,35 | +2,5 / +3 | prestaciones |
| Ferovento | Italia | Superdeportivos exclusivos | Precio muy alto, alcance chico | ×1,55 | +2 / +4 | prestaciones |
| Torvello | Italia | Superdeportivos extremos | Compite con prestaciones | ×1,60 | +1,5 / +4,5 | prestaciones |
| Forlan Motors | EE. UU. | Populares, pickups, deportivos accesibles | Mucha cobertura | ×0,90 | 0 / +0,5 | precio |
| Chevona | EE. UU. | Sedanes y pickups, potencia barata | Compite con Forlan | ×0,88 | −0,5 / +1 | precio |
| Tayora | Japón | Fiabilidad, eficiencia | Equilibrio calidad-precio-consumo | ×0,95 | +2 / −0,5 | precio |
| Honari | Japón | Compactos, motores eficientes | Eficiencia y calidad-precio | ×0,97 | +1,5 / +1 | precio |
| Nizora | Japón | Sedanes, deportivos, eléctricos tempranos | Precio con tecnología | ×0,93 | +0,5 / +1,5 | precio |
| Nordviken | Suecia | Seguridad, familiares, confort | Precio medio-alto | ×1,08 | +2 / 0 | calidad |

**Datos de cada marca:**
- país, color provisional, descripción, especialidades y segmentos;
- tecnología por año, reputación (suma al alcance), alcance por año;
- agresividad, sensibilidad, tipo de respuesta y ciclo;
- líneas de modelos con nombre original, tipo y año de aparición.

**Fechas de las líneas:** respetan el juego. Las SUV empiezan en 1984, los superdeportivos en 1974 y los eléctricos desde 2011, después de la tecnología de baterías de 2010.

**Sin casos especiales:** ninguna fórmula trata distinto a una marca; todo sale de los datos.

**Identidad:**
- Nombres, líneas y colores son originales y provisionales; no hay logotipos ni insignias.
- La prueba `[RV1]` verifica que ningún texto contenga nombres de fabricantes ni de modelos reales.
- El nombre visible se puede cambiar sin tocar el id.
- **Aviso legal:** varios nombres candidatos se parecen fonéticamente a marcas registradas, por ejemplo Chevona, Tayora, Honari, Mercenza, Volkenwerk y Nizora. Son nombres de desarrollo **no verificados legalmente**: conviene una revisión de marcas antes de publicar.

## 4. Ejemplos de modelos y generaciones (ofertas reales de la simulación)

| Año | Ejemplos |
|---|---|
| 1975 | Volkenwerk Kiebitz (compacto, 1.ª gen., $2.650) · Chevona Comarca / Bulevar / Labrador / Tronador · Ferovento Fiamma (superdeportivo, $22.070) |
| 2000 | Baviron Vektor '98 (sedán, 5.ª gen., $5.630) y Terraxa (SUV, 1.ª gen.) · Tayora Kumo '00 (compacto, 6.ª gen., $3.910) · Torvello Furente '97 (superdeportivo, 2.ª gen., $25.850) |
| 2025 | Mercenza Aureo Volta '24 (eléctrico, $17.310) · Forlan Potro-E (eléctrico, 1.ª gen.) · Stuttaro Vulkan '25 (superdeportivo, 6.ª gen.) · Nordviken Skogsrå '24 (SUV, 6.ª gen.) |

**Peso entre todas las ventas del mercado (estimado):**

| Año | Marcas populares | Marcas exclusivas |
|---|---|---|
| 2000 | Tayora 3,7 %, Volkenwerk 2,1 %, Chevona 2,1 % | Ferovento < 0,1 % |
| 2025 | Tayora 3,9 %, Volkenwerk 3,2 % | Ferovento < 0,1 % |

Dentro de los superdeportivos, en cambio, Ferovento y Torvello pesan más del 30 % del segmento.

## 5. Evolución 1970–2030

Cada marca combina tres cosas:
- una curva de tecnología por año, que nunca retrocede;
- líneas que aparecen en su año (eléctricos desde 2011, SUV desde 1984, superdeportivos desde 1974);
- su propio ciclo de generaciones, de 5 a 8 años.

Cada generación sale mejor que el promedio y envejece hasta la siguiente. El resultado:
- **1970–1984:** modelos simples.
- **1985–2014:** la tecnología sube y llegan las SUV.
- **Desde 2011:** eléctricos.

Todo es determinista: depende del año, del catálogo y de tu cuota.

## 6. Reparto competitivo: de 6 a 12 sin duplicar la presión

`Rules.rivalScale(tipo, año)` multiplica el peso de los doce rivales de cada tipo para que su peso **estructural** total sea el de las seis marcas anteriores en ese tipo y mes. El peso estructural es el atractivo base, el precio y el alcance, sin ciclo, variación ni reacción.

- Las doce se reparten la misma presión según sus datos.
- Sus generaciones y reacciones la mueven alrededor de ese nivel.
- El factor se guarda en caché, uno por tipo y mes.
- `Catalog.RIVALS_V1` no se ofrece ni se muestra: solo sirve para calibrar.

Ajuste durante la etapa: Ferovento y Torvello tenían tan poco alcance que, incluso en superdeportivos, los superaba la línea secundaria de Mercenza. Se subió su alcance (0,5–0,8 y 0,4–0,7) y se bajó un punto el atractivo del Fulgor. Su presencia general sigue siendo mínima porque solo venden deportivos y superdeportivos.

**Reacciones**, acotadas, deterministas y por tipo:
- **Precio:** bajan hasta 25 % (aggression × tu cuota sobre su sensibilidad).
- **Calidad** (Baviron, Mercenza, Nordviken): además suben hasta +2 de atractivo.
- **Prestaciones** (Stuttaro, Ferovento, Torvello): casi no bajan precios.

Ninguna reacción toca tu dinero, la demanda ni el historial. Un punto más de cuota cambia el peso rival menos de 5 %.

## 7. Comparación económica: seis contra doce

| Escenario idéntico | Seis marcas | Doce marcas |
|---|---|---|
| Presión rival media, todos los tipos de 1972 a 2030 | 1 | ×0,9–1,1 (prueba `[RV2]`; cada año entre ×0,6 y ×1,6) |
| Bot con la economía real, 1970 → 2030 + 2 h | 473.833 vendidos · $9.343 M | 477.356 vendidos · $9.439 M |
| Ídem: investigación · sede · países | 112 · 5 · 8 | 112 · 5 · 8 |
| Estrategia simple, resto del mercado 46 | 28.188 vendidos | 28.834 vendidos |
| Estrategia simple, resto del mercado 44 | 62.751 vendidos | 63.875 vendidos |
| Primer auto de 1970 (lote de 30, precio recomendado) | — | con ganancia (`[RV2]`) |

**La estrategia simple del bot es biestable.** Con seis marcas, pasar el resto del mercado de 44 a 46 (±2 %) la cambia de unos 63.000 a unos 28.000 autos vendidos, y lo mismo ocurre con doce. Con 45 justo, los dos catálogos caen de lados distintos del umbral; por eso `[F6]` ahora la mide en la rama buena (44). En la misma rama, seis y doce dan lo mismo.

No se modificó ningún valor de demanda, costo ni ingreso del jugador.

## 8. Marketing

**Modalidades:**
- **Modelo:** solo el modelo elegido.
- **Corporativa:** todos tus modelos a la venta, con un costo × `marketFactor` por la expansión internacional y reputación mensual.

**Qué queda fijo y qué cambia:**
- Al contratar quedan fijos el costo, el efecto base y la duración.
- La creatividad cambia el efecto en vivo y la comunicación alarga la duración en vivo.
- La campaña se paga una vez y cancelarla no devuelve dinero.
- Al terminar no queda efecto ni reconocimiento residual.
- No genera ventas ni ingresos por sí misma.

**El diálogo muestra:**
- modalidad, modelo, presupuesto, costo real y dinero después;
- bonos del personal;
- comparación **sin campaña / con campaña / diferencia**, en autos por minuto y en autos durante la campaña con tope en el stock, junto a la inversión.

La comparación sale de `Rules.campaignPreview`: el mismo reparto, sin tocar el estado, con un aviso de incertidumbre.

**Editor de precio:**
- ventas estimadas por minuto real con el precio propuesto (`Rules.lotRateAt`);
- precios actual, recomendado y costo;
- comparación con los rivales del tipo y efecto de la campaña activa.

No se guarda nada hasta confirmar.

## 9. Cuotas y noticias

- **Cuota actual estimada:** las ofertas de hoy (`Rules.shareSummary`).
- **Cuota histórica:** el promedio mensual guardado, separado. Sin autos a la venta la actual es 0, aunque la histórica se conserve.
- **Noticias de enero:** nuevos modelos, generaciones nuevas, bajas de precio (solo si suben 5 puntos sobre lo ya informado) y cambios de líder entre rivales por tipo.
  - Se muestran 4 y en Mercado quedan hasta 12.
  - Todas salen de las ofertas reales.

## 10. Pruebas ejecutadas (entorno simulado)

| Prueba | Cubre |
|---|---|
| `[RV1]` | Casos 1–10 |
| `[RV2]` | Casos 11–20 |
| `[RV2b]` | Bot seis contra doce y estrategia simple |
| `[RV3]` | Casos 21–32 |
| `[RV4]` | Casos 27, 30, 34 y 36–42 |
| `[RV5]` | Estrés 1970–2030: ofertas válidas cada trimestre, como mucho 12 rivales por tipo, rendimiento y la partida larga del bot |

**Interfaz** ("Etapa 10 en la interfaz"):
- 33: doce fichas con país, especialidades y participación;
- 34: modelos del año;
- 35: editor de precio, que se ejercitó con un lote por lanzar;
- 36: cuota actual e histórica;
- 31 y 12: diálogo de campaña con detalle y sin cobrar al abrir.

| Comprobación | Resultado |
|---|---|
| Servidor | 14.627 correctas, 0 fallidas |
| Interfaz | 3.473 correctas, 0 fallidas |
| Linter | 0 errores, 0 avisos |
| Analizador de tipos | sin avisos nuevos |
| Place | 60 scripts verificados |

**Roblox Studio:** no se ejecutó nada.

## 11. Compatibilidad y migración

- **No hace falta migrar datos:** no hay ids de rivales persistidos. Las ofertas se recalculan del catálogo nuevo al cargar.
- **Noticias antiguas:** se conservan tal cual, con los nombres de las seis marcas, y se marcan "(marcas de la versión anterior)". En el siguiente enero se reemplazan por novedades de las doce.
- **Cuota histórica:** se conserva y converge con el promedio mensual.
- **Idempotencia:** cargar dos veces no cambia nada.
- **Esquema:** sin cambios.

## 12. Limitaciones y pendientes

- **No verificado en Roblox Studio:** la presentación de las doce fichas, la legibilidad de los textos nuevos y el diálogo de campaña.
- **Comparación de campaña en la interfaz:** se ve solo con modelos a la venta con stock. En la prueba de interfaz no había ninguno a la venta en ese momento; la estimación se probó en el servidor (`[RV3]` y `[RV6]`). Ver el punto 13.
- **Normalización:** los cambios de catálogo de una marca (precio o alcance) mueven su parte dentro del tipo, pero no la presión total, que está anclada a la referencia anterior. Las reacciones en partida sí la mueven.
- **Nombres:** falta la revisión legal mencionada en el punto 3.
- **Estrategia simple del bot:** su biestabilidad es una propiedad del equilibrio actual, previa a esta etapa. Conviene vigilarla si se tocan el resto del mercado o los costos.

## 13. Corrección de la etapa 10

### 13.1 Estimación de campañas (`Rules.campaignPreview`)

Antes, las unidades adicionales salían del lote promocionado solo. Eso tenía dos errores:

- contaba como crecimiento lo que se quitaba a los otros modelos propios del mismo tipo;
- podía proyectar más autos que el stock disponible.

Ahora la estimación:

- **Suma todos los lotes propios en venta** de cada tipo afectado, con las mismas fórmulas del reparto real (`Rules.market`, `lotWeightAt`). Los modelos no promocionados pierden peso porque el total del tipo crece.
- **Da el incremento neto de la empresa:** `diff` (autos/min) y `units` (autos en la duración) restan las pérdidas de los otros modelos propios.
- **Respeta el stock:** cada lote se limita con `min(stock disponible, ritmo × minutos reales)`, sin y con campaña. `stockCap` avisa cuando algún lote llegaría al tope.
- **No modifica el estado:** se verifica comparando una copia de la partida antes y después.

Si toda la ganancia es redistribución (el modelo promocionado ya vendería todo su stock), el resultado es cero o negativo, nunca crecimiento.

### 13.2 Duración

La duración estimada es `plan.days / Rules.campaignSpeed(g)`: Comunicación alarga la campaña, como en la partida real. No cambió el costo ni el comportamiento real de las campañas.

El diálogo aclara que la estimación usa el personal actual y no garantiza ventas. Muestra:

- "Diferencia neta de la empresa";
- "Autos adicionales netos en ≈ N días", con aviso de stock si corresponde.

### 13.3 Pruebas nuevas (entorno simulado, Lune)

**`[RV6]`, 17 comprobaciones:**

- no muta el estado;
- el promocionado gana y el otro modelo propio pierde;
- el neto es menor que la ganancia bruta del promocionado;
- las unidades no superan el stock de ningún lote;
- redistribución pura da `units ≤ 0`;
- la duración sin personal es igual a la del plan, y con Comunicación es `60 × (1 + comunicación)`;
- contra la simulación real con copias idénticas: **estimado 7.4 autos netos, real 8 en 45 días**.

**`[RV7]`, 14 comprobaciones:** comparación de seis contra doce, con los números del punto 13.4.

La compatibilidad con partidas viejas sigue cubierta por `[RV4]` (migración, noticias antiguas, idempotencia).

### 13.4 Comparación seis contra doce

**Primer auto 1970:** $40.020 y 30 vendidos con ambos catálogos.

**Cuota de un lote estándar por segmento**, en %, seis → doce:

| Segmento | 1975 | 1990 | 2010 | 2025 |
|---|---|---|---|---|
| Compacto | 3.1→3.2 | 3.0→2.9 | 2.8→2.8 | 2.7→2.7 |
| Sedán | 3.1→3.1 | 2.9→2.9 | 2.6→2.7 | 2.6→2.6 |
| Clásico | 3.2→3.2 | 3.2→3.2 | 3.1→3.2 | 3.2→3.1 |
| Pickup | 3.3→3.3 | 3.2→3.2 | 3.2→3.2 | 3.2→3.2 |
| Deportivo | 3.3→3.3 | 3.2→3.2 | 3.1→3.2 | 3.2→3.1 |
| SUV | — | 3.0→3.0 | 2.8→2.8 | 2.6→2.7 |
| Superdeportivo | 3.3→3.3 | 3.2→3.2 | 3.2→3.2 | 3.1→3.2 |
| Eléctrico | — | — | 3.4→3.4 | 2.9→2.8 |

**Modelos rivales a la venta**, seis → doce:

| Año | 1970 | 1980 | 1990 | 2000 | 2010 | 2020 | 2030 |
|---|---|---|---|---|---|---|---|
| Modelos | 9→17 | 13→28 | 16→36 | 17→39 | 17→41 | 19→51 | 19→52 |

**Dos sedanes propios** (1980), ventas de un sedán → dos sedanes:

- seis: 12.13 → 23.43 autos/min;
- doce: 12.00 → 23.19 autos/min.

**Campañas** (sede 3, mismo escenario), en autos/min:

| Catálogo | Personal | Sin publicidad | Campaña de modelo | Campaña corporativa |
|---|---|---|---|---|
| Seis | Sin | 96.66 | 110.46 (+27.6 netos, bruto +36.0, $85.200) | 109.01 (+24.7 netos, $153.360) |
| Seis | Con | 96.66 | 111.87 (+33.8 netos, bruto +44.1, $77.230) | 110.29 (+30.3 netos, $139.010) |
| Doce | Sin | 95.99 | 109.75 (+27.5 netos, bruto +35.8, $85.200) | 108.30 (+24.6 netos, $153.360) |
| Doce | Con | 95.99 | 111.17 (+33.8 netos, bruto +43.9, $77.230) | 109.58 (+30.2 netos, $139.010) |

**Partida completa con el bot y la economía real:**

| Catálogo | Autos vendidos | Ingresos |
|---|---|---|
| Seis | 473.833 | $9.342.669.220 |
| Doce | 477.356 | $9.438.567.960 |

En ambos casos el bot llegó a 112 tecnologías, sede 5 y 8 países. Con la estrategia simple (resto 46), vendió 28.188 con seis y 28.834 con doce.

**Conclusión:** doce marcas duplican la variedad de modelos rivales, pero la presión sobre el jugador queda dentro de ±0,1 puntos de cuota. No hizo falta tocar costos ni fórmulas.
