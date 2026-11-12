# Etapa 7 · Investigación y progresión tecnológica

Auditoría y estabilización del sistema de I+D existente. No se rehízo la arquitectura, no se agregaron
tecnologías, familias ni mecánicas, y no cambiaron los valores de balance (costos, PI, adelanto, días).
El esquema de guardado sigue en 19.

## Auditoría

Módulos revisados: Catalog, Rules, Actions, Simulation, GameState, Sessions, DesignCalc, ScreenResearch,
ScreenEditor, ScreenHud, Dialogs y FacilitiesView.

### Lo que ya funcionaba (y ahora tiene pruebas)

- **Árbol:** 112 tecnologías, todas investigables, en 4 categorías.
  - 58 normales: Chasis 17, Motores 20, Seguridad 6, Tecnología 15.
  - 54 niveles de motor: 6 familias × niveles 2–10.
  - Ids únicos, requisitos existentes y nunca posteriores al nodo, sin ciclos.
  - Ninguna es imposible: la última se puede empezar desde 2025.
  - Cada una tiene un efecto automático o desbloquea algo del editor.
- **PI:**
  - El centro da 3/8/20/45/90 PI por minuto real a 1×, según su nivel.
  - Cada línea que está fabricando suma 2; una terminada o en cola no suma.
  - 2× y 3× multiplican; la pausa y los menús detienen la generación.
  - `g.rp` no tiene tope y se guarda con sus decimales.
  - Personal y mobiliario no suman PI por minuto. Su descuento de PI y dinero se aplica una sola vez, por
    `Staff.bonus`, al empezar.
- **Proyectos:**
  - Hasta 6 a la vez; PI y dinero se cobran una vez al empezar.
  - La duración se fija al empezar y el avance sigue los días del calendario.
  - No se cancelan ni se reinvestigan.
  - El mismo `requestId` no cobra dos veces. Se completa una sola vez, con aviso y XP.
- **Adelanto:**
  - Hasta 5 años; cada año suma +15 % de PI, +15 % de dinero y +10 % de días.
  - El servidor recalcula todo con `Rules.researchCost` e ignora precio, días o avance enviados por el cliente.
  - El adelanto y los costos quedan guardados en el proyecto.
  - Lo adelantado se usa enseguida.
  - La difusión abarata lo viejo: −8 % por año después del primero, con un piso del 40 %.
- **Motores y variantes:**
  - Cada nivel pide el anterior; el nivel 2 pide solo lo que habilita la familia.
  - Los niveles anteriores siguen elegibles y el servidor rechaza niveles no investigados.
  - Económica y Deportiva se investigan en cualquier orden y sirven para todas las familias a combustión;
    el eléctrico solo usa la Equilibrada.
- **Diseños:**
  - Un diseño guarda su nivel y su variante, y un lote lanzado conserva su copia (`design.calc`).
  - El servidor (`DesignCalc.sanitize`) rechaza chasis, piezas, niveles, variantes, equipamiento y opciones no
    investigados.

### Problemas encontrados y corregidos

| # | Problema | Corrección |
|---|---|---|
| 1 | La misión s12 tenía `goal = 56` escrito a mano. Al cargar se pisaba con el total (112), pero el contador era `counters.researchDone`: investigaciones terminadas en la historia de la partida, que en partidas migradas incluye tecnologías de árboles anteriores. La meta y el avance no usaban la misma definición. | Contador nuevo `researchTree` → `Rules.researchTreeDone(g)`: tecnologías del catálogo actual presentes en `g.research.done`, sin repetidos. La meta sigue siendo `Catalog.RESEARCH_TOTAL` y la descripción se arma con el total real. Las misiones reclamadas (`g.claimed.s12`) se conservan y no hay doble premio. |
| 2 | Los niveles del motor eléctrico prometían "−X % de consumo", pero `DesignCalc` no aplicaba `ENGINE_LEVEL_FX.cons` al consumo eléctrico. | El consumo eléctrico usa el mismo factor `(1 + cons × nivel)`. Ejemplo: Rayo E nivel 1 → nivel 5 pasa de 17,6 a 15,8 kWh/100 km. |
| 3 | Textos de beneficio incompletos: los niveles de motor no mencionaban la calidad (+0,4 por nivel); la Deportiva no decía "+1 de calidad"; la Económica decía "un poco más barata" (es −3 %). | Textos generados con los valores reales del catálogo. |
| 4 | Comentarios del "banco de PI" con tope de 20 min y aceleración: ya no existe. | Se marcaron `piBankMinutes` y `bankSpeedup` como obsoletos (ningún cálculo los usa) y se corrigieron los comentarios de GameState y Simulation. |
| 5 | Al completarse una investigación el guardado esperaba el autoguardado periódico (hasta 45 s). | `Sessions:tick` pide guardar enseguida (`pendingSave`, respetando el intervalo mínimo del DataStore). |
| 6 | La tarjeta de una tecnología a más de 5 años mostraba "Adelantada 13 años" y un recargo de +195 % que nunca se puede pagar. | Muestra "Futura", el costo base ("sin recargo"), desde qué año se puede adelantar y el recargo máximo (+75 % / +75 % / +50 %). |
| 7 | La tarjeta en curso mostraba el costo recalculado con la fecha de hoy, no lo pagado. | Muestra lo pagado al empezar (dinero, PI y días) y, si se adelantó, "recargo ya pagado". |
| 8 | La tarjeta no distinguía las tecnologías de efecto automático de las que solo habilitan opciones. | Línea "Categoría · tipo": "Efecto automático", "Se elige en el editor" o "Efecto automático + opción del editor" (con el índice nuevo `Catalog.RESEARCH_UNLOCKS`). También "Sin tecnologías previas" cuando no hay requisitos, y "✓ Incluida desde el inicio" para lo de serie. |
| 9 | En el editor, un nivel de motor bloqueado decía "Requiere investigar I3 nivel 4" (id interno de la familia). | Usa el nombre real de la tecnología: «I3 turbo · nivel 4». |

### Comportamientos que se mantienen a propósito

- **Efectos automáticos de la empresa** (por ejemplo, "Inyección electrónica" +6 % de potencia y −8 % de
  consumo):
  - Se aplican al calcular cada auto, como el nivel de la fábrica. Un diseño terminado que todavía no se fabricó
    los recibe al crear su lote.
  - Lo que nunca cambia es la especificación del diseño (nivel y variante del motor, piezas, equipamiento) ni
    la copia de un lote ya lanzado.
- **"I3 turbo":** la familia dice 2012, pero su motor 1.0 turbo se habilita con "Inyección directa" (2006, o
  desde 2001 con adelanto). Es coherente con la regla "lo investigado se usa enseguida"; los niveles 2–10 siguen
  repartidos desde 2012. Se dejó así para no cambiar el balance.

## Progresión 1970–2030 (prueba [IN8], reglas reales)

Estrategia de la prueba: investigar lo más barato que se pueda pagar con los PI reales, sin tocar la economía
(dinero de sobra). No se completa nada sin empezarlo y nada aparece antes de lo que permite el adelanto.

| Año | Centro siempre en nivel 1 (3 PI/min) | Centro ampliado en cuanto se puede |
|---|---|---|
| 1970 | 0 completadas · 15 disponibles (10 adelantables) | igual |
| 1975 | 11 | 25 (centro en nivel 5) |
| 1980 | 19 | 33 |
| 1990 | 32 | 51 |
| 2000 | 43 | 70 |
| 2010 | 53 | 90 |
| 2020 | 60 | 106 |
| 2030 | 66 de 112 | 112 de 112 (s12 lista) |

Con la economía real, la prueba existente del bot (`Árbol completo 1970–2030`, `[F5]`) completa las 112.

## Ejemplos de desbloqueos y su efecto en el Sedán 1970

| Paso | Potencia | Consumo | Seguridad | Calidad | Costo/u |
|---|---|---|---|---|---|
| I4 nivel 1, Equilibrada | 95 hp | 6,8 | 45 | 66 | $2.226 |
| + Carburador de doble cuerpo (automático) | 100 | 6,8 | 45 | 66 | $2.226 |
| + I4 nivel 5 (se elige en el diseño) | 124 | 6,3 | 45 | 68 | $2.300 |
| · variante Deportiva | 142 | 7,3 | 45 | 69 | $2.334 |
| · variante Económica | 109 | 5,2 | 45 | 68 | $2.290 |
| + Cinturones de tres puntos (pieza) | 124 | 6,3 | 53 | 68 | $2.336 |
| + Aire acondicionado (equipamiento) | 124 | 6,3 | 53 | 68 | $2.414 |
| + Inyección electrónica (automático) | 131 | 5,9 | 53 | 68 | $2.414 |

Un diseño guardado antes conserva su nivel 1 y su variante.

## Pruebas

- `tests/run.luau`, `[IN1]`–`[IN8]` (servidor y reglas, entorno simulado). Cubren los casos 1–30 y el
  recorrido 1970–2030:
  - catálogo, motores y variantes;
  - PI en una partida real;
  - reglas de proyectos;
  - guardado y empresas;
  - editor;
  - misión s12;
  - recorrido histórico.
- `tests/ui.luau`, "Investigación (etapa 7)" (interfaz simulada):
  - tarjeta completa y tipo de efecto;
  - "Incluida desde el inicio";
  - tecnología futura sin recargo imposible;
  - en curso con lo pagado;
  - franja con todos los proyectos;
  - completar jugando con aviso, y la tarjeta pasa a "Completada" sin reiniciar.
- `TEST_ONLY=texto` en las dos suites corre solo las pruebas cuyo nombre contiene ese texto.

## Compatibilidad con partidas guardadas

- **Sin cambio de esquema (19):**
  - `g.rp`, `g.research.done` y `g.research.projects` conservan su forma. Cada proyecto guarda `id`,
    `progress`, `days`, `paidMoney`, `paidPi`, `ahead` y `startDay`.
  - `counters.researchDone` se conserva y lo siguen usando t5 y s3.
- **Misión s12:** ahora cuenta las tecnologías del árbol presentes en la partida.
  - Una partida que ya la reclamó la conserva.
  - Su meta ya era 112 en ejecución. La única diferencia es una partida migrada cuyo contador histórico
    llegaba a 112 sin tener el árbol completo: antes la veía "lista" por error y ahora la ve "en progreso".
