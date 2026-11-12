# Pruebas de Car Empire Tycoon en Roblox Studio

Esta guía explica, paso a paso, cómo probar el juego en Roblox Studio. No hace falta saber programar ni conocer Studio a fondo.

Cada prueba indica qué hacer, qué tiene que pasar y qué anotar si algo falla.

> **Importante.** Las pruebas de esta guía no publican el juego, no compran nada con Robux y no tocan partidas reales. La única excepción es la sección 6.3: está marcada y se hace solo en una experiencia de prueba separada.

---

## Índice

1. [Abrir el proyecto](#1-abrir-el-proyecto)
2. [Iniciar una prueba](#2-iniciar-una-prueba)
3. [Abrir la ventana Output](#3-abrir-la-ventana-output)
4. [Reconocer los errores importantes](#4-reconocer-los-errores-importantes)
5. [Probar el primer automóvil](#5-probar-el-primer-automóvil)
6. [Probar el guardado de forma segura](#6-probar-el-guardado-de-forma-segura)
7. [Probar con dos jugadores](#7-probar-con-dos-jugadores)
8. [Verificar los empleados con amigos de Roblox](#8-verificar-los-empleados-con-amigos-de-roblox)
9. [Medir el rendimiento](#9-medir-el-rendimiento)
10. [Resultados esperados y cómo informar fallos](#10-resultados-esperados-y-cómo-informar-fallos)
11. [Anexo: lista rápida de pruebas](#anexo-lista-rápida-de-pruebas)

---

## 1. Abrir el proyecto

1. Abrí **Roblox Studio** e iniciá sesión con tu cuenta.
2. Elegí **File → Open from File…** (o `Ctrl+O`).
3. Buscá el archivo entregado, `CarEmpireTycoon.rbxl`, y abrilo.
   - El nombre puede tener la fecha agregada por el navegador, por ejemplo `CarEmpireTycoon(20261112-122209).rbxl`. Es el mismo archivo.
4. Esperá a que termine de cargar. A la izquierda o a la derecha aparece el **Explorer**, con la lista de servicios del juego.
   - Si no lo ves, abrilo desde **View → Explorer**.

### Comprobar que el proyecto está completo

En el **Explorer** tienen que existir estas carpetas:

| Dónde | Qué tiene que haber |
|---|---|
| `ReplicatedStorage` | `CarEmpireShared` (módulos compartidos) |
| `ServerScriptService` | `CarEmpireServer` (scripts del servidor) |
| `StarterPlayer → StarterPlayerScripts` | `CarEmpireClient` (scripts del jugador) |
| `ServerStorage` | `VehicleModels → Pioneer70_World` (carrocería 3D) y `CarEmpireStudioTests → AutoPrueba` (autoprueba de esta guía) |

Si falta alguna, no sigas: anotá cuál falta (ver sección 10).

> `CarEmpireStudioTests` no se ejecuta solo y los jugadores no lo ven. Se puede borrar antes de publicar sin afectar el juego.

---

## 2. Iniciar una prueba

### Prueba de un jugador

1. Arriba, abrí la pestaña **Home** (o **Test**).
2. Presioná **Play** (`F5`). Studio abre el juego con tu cuenta.
3. Para terminar, presioná **Stop** (`Shift+F5`).

### Qué tiene que pasar al iniciar

1. Aparece una **pantalla de carga** y después el **menú principal**, con el auto en el showroom y la lista de espacios para empresas.
2. Arriba aparece una franja amarilla: *«Modo Studio: el guardado es temporal…»*. **Es lo esperado**: en Studio, sin acceso a los servicios de datos, el juego guarda en memoria y no toca datos reales (ver sección 6).
3. Los botones del menú responden al pasar el mouse y al hacer clic.

---

## 3. Abrir la ventana Output

**Output** es la ventana donde el juego y Roblox escriben mensajes y errores. Es la herramienta principal de esta guía.

1. Abrila desde **View → Output** (en versiones nuevas de Studio puede estar en **Window → Output**).
   - Suele aparecer abajo.
2. Dejala abierta durante todas las pruebas.
3. Para empezar una prueba limpia, hacé clic derecho dentro de Output y elegí **Clear Output**.

### Colores de los mensajes

| Color | Qué es | Qué hacer |
|---|---|---|
| Blanco o gris | Información normal | Nada |
| Naranja o amarillo | Aviso (`warn`) | Leer: algunos son esperados (ver 4.1) |
| Rojo | Error de un script | **Anotarlo siempre** (ver sección 10) |

---

## 4. Reconocer los errores importantes

Todos los mensajes del juego empiezan con **`[CarEmpire]`** o **`[AUTOPRUEBA]`**.

### 4.1 Mensajes esperados (no son fallas)

| Mensaje | Significado |
|---|---|
| `[CarEmpire] DataStore no disponible en Studio (…). Se usa guardado temporal en memoria.` | Studio sin acceso a los servicios de datos: el guardado es solo de prueba |
| `[CarEmpire] Carrocería 3D lista: Pioneer 70 (Pioneer70_World)` | El auto 3D se cargó bien |
| `[CarEmpire] No se pudo leer la lista de amigos: …` | Solo en las pruebas de varios jugadores locales (sección 7): esos jugadores de prueba no tienen amigos reales |

### 4.2 Mensajes que indican un problema

Anotá cualquiera de estos (sección 10):

| Mensaje | Gravedad probable |
|---|---|
| Cualquier línea **roja** que mencione `CarEmpire` | Alta |
| `[CarEmpire] Error en la acción …` | Alta: una operación falló en el servidor |
| `[CarEmpire] Error de simulación: …` | Muy alta: la empresa no avanza bien |
| `[CarEmpire] Error al construir la pantalla …` o `… el diálogo …` | Media: una pantalla no se ve bien |
| `[CarEmpire] Falta ServerStorage.VehicleModels.…` | Media: falta la carrocería 3D |
| `[CarEmpire] Editor 3D: posible auto invisible` | Media: problema visual del editor |
| `Infinite yield possible on …` | Alta: algo espera un objeto que no existe |

### 4.3 Autoprueba automática (recomendada al empezar)

Esta prueba ejecuta, dentro de Roblox, un primer ciclo completo sobre una empresa de prueba **en memoria**. No usa la partida de ningún jugador ni el DataStore.

1. Iniciá **Play** (`F5`) y esperá a ver el menú principal.
2. En la pestaña **Test**, buscá el botón que dice **Current: Client**. Hacé clic para que diga **Current: Server**.
   - Así la barra de comandos trabaja del lado del servidor.
3. Abrí **View → Command Bar**: aparece una barra de texto abajo.
4. Pegá esta línea y presioná `Enter`:

   ```lua
   require(game.ServerStorage.CarEmpireStudioTests.AutoPrueba)()
   ```

5. En **Output** aparecen líneas `[AUTOPRUEBA] ✓ …` y, al final:

   ```
   [AUTOPRUEBA] Resultado: N correctas, 0 fallidas …
   ```

**Resultado esperado:** `0 fallidas` y alrededor de 56 comprobaciones correctas: 13 del entorno, una por cada uno de los 22 módulos y 21 del primer ciclo.

Si aparece algún `✗`, copiá **todas** las líneas `[AUTOPRUEBA]` en tu informe.

---

## 5. Probar el primer automóvil

Es el recorrido más importante del juego. Hacelo sin trucos: con el dinero inicial y sin fondos extra.

| Paso | Qué hacer | Qué tiene que pasar |
|---|---|---|
| 1 | En el menú, elegí un espacio vacío → **Crear empresa** | Se abre «Nueva empresa» con nombre, símbolo y color ya completos y editables |
| 2 | Cambiá el nombre (3 a 24 letras), elegí símbolo y color → crear | Entrás a la empresa en **enero de 1970** con **$90.000** |
| 3 | Probá un nombre de 1–2 letras | El juego lo rechaza con un mensaje claro |
| 4 | Abrí el diseño de autos (botón principal del HUD o **Producción**) | Se abre el editor en 5 etapas con el auto 3D |
| 5 | Recorré las etapas, elegí componentes y mirá cómo cambian las estadísticas | Los valores se actualizan sin errores en Output |
| 6 | Salí del editor sin terminar y volvé a entrar | El borrador sigue ahí (se guarda solo) |
| 7 | Finalizá el diseño | Se cobra el desarrollo **una sola vez** y el dinero baja |
| 8 | Fabricá un lote pequeño (por ejemplo, 30 unidades) | Se cobra el lote y la línea 1 empieza a fabricar |
| 9 | Intentá fabricar el mismo modelo otra vez | El juego no lo permite (cada modelo se fabrica una vez) |
| 10 | Esperá (podés usar la velocidad 3×) | La barra de producción avanza; al terminar aparecen las **reseñas de los cuatro críticos** |
| 11 | Mirá el **precio recomendado** y poné el lote a la venta | El estado pasa a «en venta» |
| 12 | Esperá | Las unidades se venden de a poco; el dinero sube con cada venta |
| 13 | Esperá a que se agote | El lote pasa a «Agotados y retirados»; las reseñas no cambian |
| 14 | Diseñá un segundo auto | Se puede, y el desarrollo que ya pagaste no se cobra de nuevo (sale más barato) |

**Referencia medida en el entorno automático** (sedán «brisa» de 1970, 30 unidades al precio recomendado):

| Concepto | Monto |
|---|---|
| Dinero inicial | $90.000 |
| Desarrollo | −$18.500 |
| Lote (30 × $2.226) | −$66.780 |
| Ventas (30 × $3.560) | +$106.800 |
| **Dinero final** | **$111.520** |

En Studio los números pueden variar un poco según el diseño elegido.

**Contabilidad.** En **Estadísticas → Movimientos**, el dinero final tiene que ser igual al inicial más los ingresos menos los egresos.

No puede haber cobros repetidos ni ventas de autos que no se fabricaron.

---

## 6. Probar el guardado de forma segura

### 6.1 Guardado temporal (siempre seguro)

En Studio, sin acceso a los servicios de datos, el juego guarda **en memoria** mientras dura la prueba. Sirve para probar **cambiar de empresa y volver al menú**, pero **no** para probar salir y volver a entrar: al detener la prueba, se pierde todo.

1. Creá una empresa, diseñá un auto y fabricá un lote.
2. **Compañía → Guardar y volver al menú.** Tenés que volver al menú sin salir del juego.
3. Creá una **segunda empresa** en otro espacio. Tiene que empezar con $90.000, en 1970 y sin los autos de la primera.
4. Volvé al menú y elegí la primera empresa → **Continuar**. Tiene que tener su dinero, su auto y su lote.
5. Comprobá que el dinero, los empleados y las tecnologías de una empresa no aparecen en la otra.

### 6.2 Espacios prémium

Los espacios 3 y 4 y la tercera línea de producción se compran con Robux.

Mientras sus identificadores de producto no estén configurados (`Catalog.PRODUCTS`), el juego **no ofrece la compra** y muestra un aviso. Es el comportamiento correcto: **no se simula ninguna compra**.

### 6.3 Guardado real con DataStore (SOLO en una experiencia de prueba separada)

> ⚠️ **No actives «Enable Studio Access to API Services» en la experiencia publicada del juego.** Si Studio tiene acceso a los servicios, las pruebas leen y escriben **los datos reales** de esa experiencia.

Para probar el guardado real sin riesgo:

1. Guardá una copia del archivo con otro nombre, por ejemplo `CarEmpireTycoon-PRUEBA-DATOS.rbxl`.
2. Publicá **esa copia** como una **experiencia nueva y privada**. Los DataStores son independientes por experiencia: los datos de la experiencia real no se tocan.
   - Esta decisión es tuya: esta guía no publica nada.
3. En esa experiencia de prueba: **Game Settings → Security → Enable Studio Access to API Services → On**.
4. **Play.** La franja amarilla del modo memoria ya no aparece.
5. Creá una empresa, diseñá, fabricá, contratá, investigá, abrí la oficina y, si podés, abrí un país.
6. **Stop.** Volvé a presionar **Play**.
7. Elegí la empresa → **Continuar**. Comprobá que se recuperan:
   - dinero, diseños, lotes, investigaciones, empleados, oficina con sus muebles, países, campaña activa y estadísticas;
   - la fecha del juego, que tiene que seguir donde estaba.
8. **Sesión simultánea:** abrí la misma experiencia de prueba en dos sesiones a la vez con la misma cuenta. Por ejemplo, Studio y el cliente de Roblox, o dos computadoras.
   - La segunda tiene que avisar que la partida está abierta en otro servidor.
   - No se tiene que pisar el progreso.
9. Al terminar, volvé a **desactivar** el acceso a los servicios en la experiencia de prueba.

**Qué no hacer nunca en esta prueba:**
- usar la experiencia publicada del juego;
- usar «Borrar todos los datos» en una experiencia con jugadores reales;
- editar DataStores de producción.

---

## 7. Probar con dos jugadores

1. Pestaña **Test** → sección **Clients and Servers**.
2. Elegí **Local Server** y **2 Players** → **Start**.
3. Studio abre una ventana de servidor y dos ventanas de jugador (`Player1` y `Player2`).
4. Para terminar, presioná **Cleanup** en la ventana principal.

En cada ventana de jugador:

| Prueba | Resultado esperado |
|---|---|
| Cada jugador crea su empresa con otro nombre | Cada uno ve **solo la suya** |
| `Player1` diseña y fabrica | El dinero de `Player2` no cambia |
| `Player1` abre un menú (la empresa se pausa) | La empresa de `Player2` **sigue avanzando** |
| Cambian la velocidad (1× y 3×) | Cada empresa avanza a su propia velocidad |
| `Player1` vuelve al menú y entra de nuevo | `Player2` no se entera de nada |
| `Player1` abre el editor de oficinas | `Player2` no ve esa oficina ni sus personajes |
| Cerrá la ventana de `Player2` y volvé a unirte | Con el guardado en memoria, la empresa sigue en esa misma prueba |

Es esperado que en esta prueba aparezca *«No se pudo leer la lista de amigos»*: los jugadores locales de prueba no son cuentas reales.

---

## 8. Verificar los empleados con amigos de Roblox

Los empleados toman **automáticamente** la identidad y el avatar de **tus amigos reales** de Roblox. Para probarlo, usá **Play** (`F5`) con tu cuenta, que tiene amigos; los jugadores locales de la sección 7 no tienen.

1. **Personal** → contratá 2 o 3 empleados.
   - Cada uno muestra el **nombre visible** y el **@usuario** de un amigo.
   - No se repite ningún amigo dentro de la misma empresa.
2. Abrí el **editor de oficinas** (Instalaciones → Oficinas centrales → editor de oficinas).
   - Los empleados aparecen con la **apariencia R15 de tus amigos**: ropa, accesorios y proporciones.
   - Caminan entre escritorios, se sientan, usan sofás, se reúnen y consultan archivos.
3. **Más empleados que amigos:** si contratás más empleados que amigos tenés, los puestos extra funcionan igual pero **sin personaje**, con el aviso «puesto sin amigo». No aparecen personajes genéricos.
4. **Identidad estable:** con el guardado de la sección 6.3, salí y volvé a entrar. Cada empleado tiene que seguir siendo el mismo amigo.
5. **Cerrar y abrir el editor de oficinas 10 veces.** No se tienen que duplicar personajes. En el Explorer, dentro de `Workspace`, no se tienen que acumular modelos.
6. **Economía:** mirá el dinero y los PI antes y después de mirar la oficina un rato con la empresa en pausa. Las actividades de los personajes **no cambian** dinero, productividad ni puntos de investigación.

Si un avatar no carga, el juego reintenta un número limitado de veces. Si el avatar queda invisible para siempre, anotá en Output las líneas `[CarEmpire] Avatar de empleado: …`.

---

## 9. Medir el rendimiento

Las mediciones de esta etapa fueron **fuera de Roblox** (ver `docs/ETAPA11-AUDITORIA.md`). Los FPS, la memoria y el costo de render solo se pueden medir en Studio o en el cliente.

### Herramientas

| Herramienta | Cómo abrirla | Para qué |
|---|---|---|
| Consola de desarrollo | `F9` durante la prueba | Pestañas **Memory** (memoria por categoría) y **Scripts** (uso de cada script) |
| MicroProfiler | `Ctrl+Alt+F6` durante la prueba | Tiempo de cada cuadro; los picos aparecen como barras altas |
| Stats | **View → Stats** (o el menú de estadísticas de la pestaña View) | FPS, memoria, red y conteo de instancias |
| Script Performance | **View → Script Performance** | Actividad de cada script |

### Escenarios (2 minutos cada uno)

| Escenario | Qué anotar |
|---|---|
| A · Menú principal | FPS y memoria (MB) |
| B · Empresa nueva sin empleados | FPS y memoria |
| C · Editor de automóvil abierto | FPS; picos al cambiar de etapa |
| D · Fábrica y ventas activas (velocidad 3×) | FPS; picos una vez por minuto (guardado automático) |
| E · Oficina con 10 empleados visibles | FPS y memoria |
| F · Oficina de nivel máximo con mobiliario | FPS |
| G · Mapa mundial (Compañía → Expansión), con zoom y desplazamiento | FPS al arrastrar |
| H · Empresa avanzada (muchos años jugados) | FPS y **red recibida** (KB/s, en Stats) |
| I · Dos jugadores (sección 7) | FPS del servidor y de cada jugador |
| J · Abrir y cerrar 20 veces el editor de autos, el de oficinas y el mapa | La memoria no tiene que crecer sin parar y no tiene que aparecer «lag» acumulado |

**Cómo anotar:** «Escenario D: 58–60 FPS, picos de 25 ms cada ~45 s, memoria 820 MB».

No se puede afirmar que el juego corre a 60 FPS estables sin estas mediciones.

---

## 10. Resultados esperados y cómo informar fallos

### Resultado esperado general

- El juego arranca sin líneas rojas en Output.
- La autoprueba (4.3) termina con `0 fallidas`.
- El primer auto se puede diseñar, fabricar, reseñar y vender con el dinero inicial.
- Las empresas y los jugadores no se mezclan.

### Cómo informar un fallo

Copiá esta plantilla y completala:

```
Identificador: (por ejemplo, ST-01)
Sistema: (menú, empresa, editor, fábrica, ventas, investigación, instalaciones,
         oficina, empleados, expansión, mercado, marketing, guardado, varios jugadores)
Gravedad: P0 / P1 / P2 / P3
  P0 = no se puede jugar, guardar o arrancar, o se pierden datos
  P1 = economía, seguridad o progreso incorrectos
  P2 = algo funciona a medias o la pantalla tiene un problema serio
  P3 = detalle visual o de texto
Pasos para reproducirlo:
  1.
  2.
  3.
Resultado esperado:
Resultado observado:
Líneas de Output (copiar y pegar, sobre todo las rojas y las [CarEmpire]):
Captura de pantalla (si es visual):
Versión de Studio (Help → About):
```

Un fallo bien informado tiene **pasos que cualquiera puede repetir**. Si no sabés repetirlo, anotá igual lo que estabas haciendo y la hora.

---

## Anexo: lista rápida de pruebas

Marcá cada casilla:

- [ ] 1. El proyecto abre y las carpetas de la sección 1 existen
- [ ] 2. **Play**: menú principal sin líneas rojas
- [ ] 3. Autoprueba: `0 fallidas`
- [ ] 4. Crear empresa: valores editables, validación del nombre, $90.000 y enero de 1970
- [ ] 5. Primer diseño finalizado (cobro único)
- [ ] 6. Primera fabricación (cobro del lote, avance de la producción)
- [ ] 7. Reseñas de los cuatro críticos y precio recomendado
- [ ] 8. Ventas progresivas hasta agotar el lote
- [ ] 9. Segundo diseño
- [ ] 10. Guardar y volver al menú; segunda empresa independiente
- [ ] 11. Investigación: empezar un proyecto, ver los PI y terminarlo
- [ ] 12. Mejora de instalación con la comparación Antes y Después
- [ ] 13. Contratar personal y ver sus bonificaciones
- [ ] 14. Editor de oficinas: colocar, girar 45°, mover, retirar y remodelar con presupuesto
- [ ] 15. Mercado: doce marcas rivales y cuotas
- [ ] 16. Marketing: campaña de modelo y corporativa, con estimación neta
- [ ] 17. Expansión: mapa, zoom en Alemania y Polonia, abrir un país y una sola celebración
- [ ] 18. Dos jugadores (sección 7)
- [ ] 19. Empleados con amigos reales (sección 8)
- [ ] 20. Rendimiento: escenarios A–J anotados (sección 9)
- [ ] 21. Guardado real en una experiencia de prueba separada (sección 6.3), solo si decidís hacerlo
