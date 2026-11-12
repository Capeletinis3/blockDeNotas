# Etapa 11 · Auditoría integral, pruebas y optimización

**Estado final: validado solamente mediante pruebas automatizadas externas.**

Nada de esta etapa se ejecutó en Roblox Studio: el entorno de trabajo no tiene Studio ni el motor de Roblox. Todas las pruebas corrieron en **Lune** (el intérprete de Luau) con el código real del juego:

- la lógica del servidor sin cambios;
- el cliente sobre un doble de las APIs de Roblox (`tests/mock.luau`).

Lo que solo se puede comprobar en Studio quedó preparado en:

- `docs/PRUEBAS_ROBLOX_STUDIO.md`, la guía para el propietario;
- `ServerStorage.CarEmpireStudioTests.AutoPrueba`, la autoprueba para la barra de comandos.

Los criterios de la fase 17 que requieren Studio figuran como **pendientes** en el punto 7.

---

## 1. Respaldo y versión de partida

| Elemento | Dónde |
|---|---|
| Etiqueta de respaldo | `respaldo-pre-etapa11` (commit `d2bba92`, en GitHub) |
| Copia del `.rbxl` original | `scratchpad/respaldo/CarEmpireTycoon-pre-etapa11.rbxl` |

El SHA-256 de la copia es `39b95445…d0` y coincide con el archivo entregado en la corrección de la etapa 10.

El archivo `CarEmpireTycoon(20261112-122209).rbxl` que menciona el pedido no estaba en el entorno. Por la fecha, es la descarga de esa misma entrega. Se trabajó sobre el repositorio, que es la fuente de ese archivo.

---

## 2. Auditoría de arranque (fase 1)

### 2.1 Estructura

| Carpeta | Contenido | Destino en el place |
|---|---|---|
| `src/shared` | 11 módulos | `ReplicatedStorage.CarEmpireShared` |
| `src/server` | 11 módulos y `Main` (Script) | `ServerScriptService.CarEmpireServer` |
| `src/client` | 36 módulos y `Main` (LocalScript) | `StarterPlayerScripts.CarEmpireClient` |
| `src/studio` (nuevo) | `AutoPrueba` (ModuleScript, no se ejecuta solo) | `ServerStorage.CarEmpireStudioTests` |

### 2.2 Inicialización del servidor (`Main.server.luau`)

Orden de arranque:

1. Publica las carrocerías 3D sin scripts en `ReplicatedStorage.CarEmpireAssets`.
2. Requiere `GameState`, `DataService`, `Sessions`, `Garage`, `EmployeeAvatars` y `FriendIdentity`.
3. Crea los cinco remotos (`Request`, `State`, `Notice`, `Open`, `Avatares`). La carpeta `CarEmpireRemotes` se publica **después** de crear todos sus hijos.
4. Abre el DataStore. En Studio sin acceso a los servicios, usa la memoria (con aviso). En un servidor publicado sin DataStore no usa memoria: las cargas fallan y no se pisa nada.
5. Crea `Sessions` y conecta `PlayerAdded`, `PlayerRemoving`, `BindToClose`, `OnServerInvoke` y `Heartbeat`.

### 2.3 Inicialización del cliente (`Main.client.luau` y `App.luau`)

- Espera `CarEmpireShared`, `CarEmpireRemotes` y sus remotos.
- Registra pantallas y diálogos y escucha `State`, `Notice` y `Open`.

### 2.4 Resultado de la auditoría estática (`tests/audit_static.luau`)

```
módulos: 60 · dependencias: 254 · ciclos: 0
remotos creados por el servidor: Avatares, Notice, Open, Request, State
remotos usados por el cliente: Avatares, Notice, Open, Request, State
auditoría estática: sin problemas
```

- **Sin dependencias circulares.**
- **Sin módulos inexistentes.**
- **El cliente no requiere módulos del servidor.**
- **Esperas sin límite (`WaitForChild` sin tiempo máximo):** solo sobre objetos que existen siempre.
  - `CarEmpireShared` lo pone Rojo.
  - `CarEmpireRemotes` y sus cinco remotos los crea el servidor antes de publicar la carpeta.
  - `PlayerGui` lo crea Roblox.
- **Un `require` dinámico:** el `PlayerModule` de Roblox, buscado con `FindFirstChild` y cargado dentro de `pcall`. Es correcto.
- **Lint (selene) sobre `src` y `tests`:** 0 errores, 0 avisos.
- **Analizador de tipos** (`luau-analyze`) sobre `Sessions`, `Actions` y `GameState`: sin avisos nuevos respecto del respaldo.
- **Place compilado con Rojo y comparado archivo por archivo** (`tests/verify_place.luau`): todos los scripts coinciden.

**Primera comprobación en Studio** (servidor y cliente inician, sin errores en Output, menú construido, estado inicial recibido): **no ejecutada**. Está en la guía, secciones 2 a 4.

---

## 3. Registro de errores

Prioridades: P0 bloqueante · P1 crítico · P2 importante · P3 menor.

**No se encontraron errores P0 ni P1.**

### E11-01 · P3 · Sesiones (menú) · `setSetting` con una solicitud que no es una tabla

| Campo | Detalle |
|---|---|
| Pasos | Enviar `Request:InvokeServer("setSetting", 5)`, con un número en lugar de una tabla |
| Esperado | Rechazo «Opción inválida.» |
| Observado | Excepción `attempt to index number with 'key'`, capturada por `pcall`. El jugador recibe «Error interno del servidor» y se escribe una línea en Output |
| Causa | `payload and payload.key` no comprueba el tipo |
| Impacto | Ninguno sobre la partida. Un cliente malicioso podía llenar Output con avisos, limitado por el tope de acciones |
| Corrección | `Sessions.luau`: se comprueba `type(payload) == "table"` |
| Regresión | `[E11-F1]`, 6.000 solicitudes aleatorias sin errores internos |
| Estado | **Corregido** |

### E11-02 · P3 · Fabricación · Un lote rechazado modificaba la partida

| Campo | Detalle |
|---|---|
| Pasos | Pedir `createLot` con más unidades de las que se pueden pagar, o con un precio inválido |
| Esperado | Rechazo sin ningún cambio |
| Observado | Rechazo correcto, sin cobro, pero el contador de identificadores (`g.nextId`) avanzaba |
| Causa | `Simulation.makeLot` (que reserva un id) se llamaba antes de validar fondos y precio |
| Impacto | Sin efecto económico. Violaba la regla «una acción rechazada no cambia nada» y marcaba la partida para guardar |
| Corrección | `Actions.createLot`: el costo se calcula con la misma fórmula (`Rules.lotUnitCost`) y se valida todo antes de crear el lote. Mismo costo y mismo precio que antes |
| Regresión | `[E11-F2]` y `[E11-F3]` comprueban que ninguna acción rechazada cambia la partida. La autoprueba comprueba que un lote impagable se rechaza sin cambiar nada |
| Estado | **Corregido** |

### E11-03 · P2 · Red (servidor → cliente) · El historial completo viajaba en cada envío

| Campo | Detalle |
|---|---|
| Pasos | Partida avanzada (≈2030); cualquier clic o cambio de estado |
| Esperado | Envíos proporcionales a lo que cambió |
| Observado | Cada envío completo pesaba ≈266 KB, de los cuales ≈152 KB eran `modelHistory` y ≈52 KB `lotHistory`, aunque no hubieran cambiado. Sin tocar nada, ≈5,6 envíos completos por minuto daban **26,6 KB/s por jugador** |
| Causa | `GameState.view` copiaba la partida entera en cada envío |
| Impacto | Riesgo de demoras de red en partidas avanzadas: Roblox recomienda pocas decenas de KB/s por cliente. Medido fuera de Roblox: el tamaño real en la red puede ser algo menor que el JSON |
| Corrección | `Sessions:push` omite los dos historiales si su firma (`GameState.historyKey`) no cambió desde el último envío a esa sesión y esa partida. Igual los manda completos cada 120 s y cuando el cliente pide `sync` con `full = true`. El cliente (`App.onState`) conserva su copia de esa misma empresa; si no tiene una que coincida, pide todo |
| Regresión | `[E11-N]` (22 comprobaciones): el cliente siempre tiene el historial idéntico al del servidor después de acciones, cierres de lotes, 400 s de simulación, el resguardo periódico y un cambio de empresa. Además, la suite de interfaz completa |
| Estado | **Corregido y medido** (punto 5) |

### E11-04 · P3 · Interfaz (cliente) · La firma de cambios codificaba el historial cada segundo

| Campo | Detalle |
|---|---|
| Observado | `App.structuralSig` codificaba en JSON todo el estado, historial incluido (≈150 KB), en cada actualización: una vez por segundo |
| Causa | El historial no estaba reducido en la firma, a diferencia de `lotHistory` y `ledger` |
| Corrección | La firma usa la cantidad de entradas del historial. El historial solo cambia junto con los lotes, que ya están en la firma, así que las pantallas se reconstruyen en los mismos momentos |
| Regresión | Suite de interfaz completa (reconstrucciones, ventas, historial, HUD) |
| Estado | **Corregido.** El ahorro de CPU del cliente no se midió en Roblox |

### E11-05 · P3 · Editor de autos · Abrir el editor sin empresa activa daba error

| Campo | Detalle |
|---|---|
| Pasos | `App.go("editor")` cuando el estado ya no tiene empresa; por ejemplo, un clic justo cuando llega la vuelta al menú |
| Observado | `ScreenEditor:540: attempt to index nil with 'drafts'` |
| Corrección | `ScreenEditor.enter` no hace nada sin empresa activa; `App.render` lleva al menú |
| Regresión | `[E11-E]` |
| Estado | **Corregido** |

### E11-06 · Falso positivo de la herramienta · «Fuga» de conexiones del mapa mundial

| Campo | Detalle |
|---|---|
| Observado | En `[E11-J]`, dos conexiones nuevas por ciclo (`InputChanged` y `InputEnded` de `WorldMap`) |
| Causa | El doble de Roblox no emitía `AncestryChanged`, el evento con el que el mapa libera sus conexiones. Roblox sí lo emite |
| Corrección | Solo en `tests/mock.luau`: `AncestryChanged` en la instancia y sus descendientes, como en Roblox. **No se cambió código del juego** |
| Resultado | 163 → 163 conexiones después de 5 ciclos |
| Estado | **No era un error del juego** |

### E11-07 · Riesgo medido, no corregido · Costo de CPU de cada guardado en partidas avanzadas

| Campo | Detalle |
|---|---|
| Observado | Cada guardado de una partida de ≈2030 cuesta ≈58 ms en Lune: tres copias de ≈270 KB (instantánea, validación y almacén en memoria). Son los picos de `máx` del punto 5 |
| Por qué no se tocó | Es el núcleo de la persistencia (copia consistente antes de `UpdateAsync`). En Roblox la copia es nativa y el almacén en memoria no existe, así que el costo real es menor y desconocido |
| Pendiente | Medirlo con el MicroProfiler en Studio (guía, sección 9, escenario D). Si los picos molestan, optimizar `DataService` en una etapa propia |

### Riesgo residual sin error observado

Si una acción fallara a mitad de camino, `Sessions:request` responde «no se aplicó», pero lo hecho antes del fallo quedaría.

En 16.000 solicitudes aleatorias (`[E11-F1]` a `[E11-F3]`) ninguna acción falló: no hay un caso reproducible que justifique cambiar el diseño.

---

## 4. Pruebas

### 4.1 Pruebas ejecutadas

Todas corrieron en Lune 0.11.1, fuera de Roblox. Comando: `lune run <archivo>` desde `car-empire-tycoon/`.

| Suite | Qué cubre | Resultado |
|---|---|---|
| `tests/run.luau` | Reglas, economía, diseño, fabricación, ventas, investigación, instalaciones, oficinas, NPC (lógica), mercado, marketing, expansión, guardado y seguridad, por las rutas reales (`Sessions:request`, `Simulation`, `DataService`) | **14.726 correctas, 0 fallidas** |
| `tests/ui.luau` | Servidor y cliente reales sobre el doble de Roblox: menús, editor, fábrica, ventas, oficinas, NPC, mapa, HUD y tutorial | **3.481 correctas, 0 fallidas** |
| `tests/audit_static.luau` | Arranque, dependencias, remotos y esperas | sin problemas |
| `selene src tests` | Lint | 0 errores, 0 avisos |
| `tests/verify_place.luau` | `.rbxl` compilado frente a `src/` | 61 scripts coinciden, 0 diferencias |

### 4.2 Pruebas nuevas de esta etapa

| Prueba | Qué comprueba |
|---|---|
| `[E11-F1]` | 6.000 solicitudes válidas y malformadas sobre una empresa nueva |
| `[E11-F2]` | 6.000 solicitudes sobre una empresa de ≈1990 |
| `[E11-F3]` | 4.000 solicitudes sobre una empresa de fin de partida (sede 5, 8 países, 112 tecnologías) |
| `[E11-M]` | Tres jugadores en un servidor (ver detalle abajo) |
| `[E11-D]` | Guardado con fallos intermitentes del almacén (ver detalle abajo) |
| `[E11-N]` | Optimización de red: el cliente siempre tiene el historial correcto |
| `[E11-J]` (interfaz) | Escenario J: 7 ciclos por todas las pantallas, seis diálogos, el editor de autos y el de oficinas. Conexiones, instancias de la interfaz y del mundo estables |
| `[E11-S]` (interfaz) | La autoprueba de Studio corre completa con los módulos reales (21/0) |
| `[E11-E]` (interfaz) | Editor sin empresa activa (E11-05) |

**Invariantes de `[E11-F1]` a `[E11-F3]`, comprobados después de cada solicitud:**

- sin errores internos;
- partida válida (`GameState.validate`);
- una acción rechazada no cambia nada;
- el dinero solo cambia con acciones económicas;
- saldo final = saldo inicial + ingresos − egresos, contado en el libro diario, también durante la simulación.

**`[E11-M]`, tres jugadores en un servidor:**

- cada uno manda solicitudes armadas con los identificadores de otro (lotes, diseños, empleados, `companyId`), y ninguna cambia una partida ajena;
- pausas y velocidades independientes;
- volver al menú no afecta a los demás;
- desconexión y reconexión.

**`[E11-D]`, guardado con fallos intermitentes del almacén:**

- 12 ráfagas de fallos durante 20 minutos de juego;
- lo guardado siempre es válido;
- se avisa al jugador;
- la salida guarda lo último;
- otro servidor recupera dinero, fecha, ventas y diseños;
- una escritura del servidor anterior se rechaza por el candado.

### 4.3 Cobertura de las fases con pruebas automáticas anteriores (siguen pasando)

| Fase | Pruebas |
|---|---|
| 2 · Empresas | Creación, validación, ranuras, varias empresas, prémium sin producto configurado y recibos (`[P14]`, «Dos jugadores…», «Correcciones…») |
| 3 · Primer ciclo | Integración `[I10]` (20 pasos), `[C*]` del ciclo principal y la autoprueba |
| 4 · Investigación | Etapa 7 (`[F1]`: 1970 → 2030 sin perder progreso, 112 tecnologías; dependencias, adelantos, familias, niveles y variantes) |
| 5 · Instalaciones | Etapa 8 (costos, requisitos, obras, PI por hora de juego, superficie en casillas, línea 2 y línea 3 sin producto configurado) |
| 6 · Oficinas | Pruebas O, R y B (colocación, giros de 45°, colisiones, compra única, remodelación con presupuesto y revisión, bonificaciones con tope) |
| 7 · NPC con amigos | Pruebas N y AM (A*, reservas, actividades, identidad persistente, sin duplicados, recuperación de avatares, límites de reintentos) |
| 8 · Expansión | Etapa 9 (mapa, marcadores DE/PL, celebración única, demanda potencial e incorporada) |
| 9 · Rivales y marketing | Etapa 10 y su corrección (`[RV1]` a `[RV7]`) |

### 4.4 Pruebas preparadas y NO ejecutadas (pendientes en Studio)

- La **autoprueba en Studio** (`AutoPrueba`, guía 4.3). Se verificó solo en el entorno simulado.
- **Todo lo visual:** cámaras, showroom, transiciones, textos cortados, paneles superpuestos, mapa a distintos zooms, paredes semitransparentes del editor de oficinas.
- **APIs reales de Roblox:** `GetFriendsAsync`, carga de avatares R15, `TextService` (filtro), `MarketplaceService`, `DataStoreService`.
- **Varios clientes reales** (Local Server con 2 jugadores).
- **DataStore real** en una experiencia de prueba separada.
- **MicroProfiler, FPS y memoria** (escenarios A–J).

---

## 5. Rendimiento

### 5.1 Servidor (medido en Lune, `tests/perf.luau`)

Misma partida generada por el bot, antes (`respaldo-pre-etapa11`) y después. Velocidad 3×, 300 ticks (60 con 8 jugadores avanzados).

| Escenario | Antes: tick medio · p95 | Después: tick medio · p95 | Antes: red por jugador | Después: red por jugador |
|---|---|---|---|---|
| A/B · Empresa nueva | 0,10 · 0,45 ms | 0,10 · 0,41 ms | 1,1 KB/s | 1,1 KB/s |
| D · Empresa ≈1995 | 1,82 · 8,03 ms | 1,19 · 3,01 ms | 17,7 KB/s | **8,6 KB/s** |
| H · Empresa ≈2030 | 3,04 · 13,65 ms | 1,90 · 3,91 ms | 26,6 KB/s | **12,3 KB/s** |
| I · 8 jugadores ≈1995 | 15,21 · 72,96 ms | 9,91 · 40,89 ms | 18,5 KB/s | **8,2 KB/s** |
| I · 8 jugadores ≈2030 | 25,52 · 104,18 ms | 15,97 · 61,91 ms | 33,5 KB/s | **13,0 KB/s** |

**Envío completo medio** (≈2030): 265,9 KB → 112,8 KB. Sin cambios en el historial: ≈60–70 KB.

**Guardado** (sin cambios): 262 KB por partida de ≈2030.

**Picos máximos:** antes 79–233 ms, después 58–103 ms. Son los guardados (E11-07): simulación 0,33 ms por tick, armado del envío 2,2 ms y guardado 58 ms (sondeo separado).

**Mejoras:** −35 a −38 % de CPU del servidor por segundo y −54 a −61 % de red en partidas avanzadas. **Regresiones:** ninguna medida.

### 5.2 Cliente (medido en el doble de Roblox, `[E11-J]`)

- Conexiones activas estables (163 → 163).
- Instancias de la interfaz estables (1.479 → 1.479).
- Instancias del mundo estables (155 → 155).

Un ciclo por todas las pantallas tarda ≈400 ms en Lune; no es representativo de Roblox.

**FPS, memoria del cliente, render, MicroProfiler: no medidos.** Requieren Studio (guía, sección 9).

---

## 6. Módulos modificados

| Archivo | Cambio |
|---|---|
| `src/server/Sessions.luau` | E11-01; envío sin historial repetido (E11-03); `sync` con `full` |
| `src/server/Actions.luau` | E11-02 (orden de validaciones de `createLot`; mismos costos) |
| `src/server/GameState.luau` | `historyKey`; `view` con historial opcional (E11-03) |
| `src/client/App.luau` | Conserva el historial sin cambios (E11-03); firma estructural liviana (E11-04) |
| `src/client/ScreenEditor.luau` | E11-05 |
| `src/studio/AutoPrueba.luau` (nuevo) | Autoprueba para la barra de comandos de Studio |
| `place.project.json` | Mapea `src/studio` a `ServerStorage.CarEmpireStudioTests` |
| `tests/run.luau`, `tests/ui.luau` | Pruebas `[E11-*]`. El arnés del servidor conserva el historial como el cliente real |
| `tests/mock.luau` | `AncestryChanged` como en Roblox; registro de conexiones e instancias |
| `tests/build.luau`, `tests/verify_place.luau` | Incluyen `src/studio` |
| `tests/audit_static.luau`, `tests/perf.luau` (nuevos) | Auditoría de arranque y medición del servidor |
| `docs/PRUEBAS_ROBLOX_STUDIO.md` (nuevo) | Guía de pruebas en Studio para el propietario |

**Sin cambios en:**

- parámetros económicos, costos o precios;
- catálogo de marcas y rivales, vehículos, tecnologías y países;
- monetización y configuración de publicación;
- DataStore: no se activó el acceso a los servicios.

`default.project.json` (sincronización con Studio) no cambió: la autoprueba solo está en el place compilado.

---

## 7. Criterios de aprobación (fase 17)

| # | Criterio | Estado |
|---|---|---|
| 1 | Arranca sin errores bloqueantes | Automático: sí (auditoría y suite de interfaz). **Studio: pendiente** |
| 2 | Se puede crear una empresa | Automático: sí. **Studio: pendiente** |
| 3 | Primer ciclo de fabricación y ventas | Automático: sí ($90.000 → $111.520 con 30 autos). **Studio: pendiente** |
| 4 | Sin duplicaciones económicas | Automático: sí (contabilidad, reenvíos e idempotencia en 16.000 solicitudes) |
| 5 | Guardado y recuperación | Automático: sí con almacén simulado, fallos incluidos. **DataStore real: pendiente** |
| 6 | Sistemas usables desde la interfaz | Automático: sí (interfaz simulada). **Visual en Studio: pendiente** |
| 7 | Operaciones remotas validadas | Automático: sí (fuzz, multijugador, avatares) |
| 8 | Independencia al cambiar de empresa | Automático: sí |
| 9 | Los NPC no alteran la economía | Automático: sí (pruebas N y AM) |
| 10 | Sin P0 ni P1 conocidos | Sí: no se encontraron |
| 11 | Regresión relevante pasa | Automático: sí (14.726 correctas, 0 fallidas · 3.481 correctas, 0 fallidas) |
| 12 | Rendimiento medido sin degradaciones | Servidor medido fuera de Roblox: mejora. **Cliente en Studio: pendiente** |

**Conclusión: validado solamente mediante pruebas automatizadas externas.**

Para pasar a «aprobado en Roblox Studio» hay que seguir `docs/PRUEBAS_ROBLOX_STUDIO.md` y obtener:

- `0 fallidas` en la autoprueba;
- el primer ciclo completo;
- la prueba con dos jugadores;
- la prueba con amigos reales;
- las mediciones A–J.

---

## 8. Limitaciones y pendientes

- **Sin Studio en este entorno:** ningún resultado de esta etapa es una ejecución en Roblox.
- **E11-07:** costo de CPU de los guardados de partidas grandes, pendiente de medir en Studio.
- **Línea 3 y espacios prémium:** siguen sin identificador de producto (`Catalog.PRODUCTS`, id 0). La compra queda deshabilitada y no se inventó ningún identificador.
- **Doble de Roblox:** reproduce eventos, instancias y conexiones, pero no la física, el render, la red real ni los tiempos del motor.
- **`AutoPrueba`:** está en `ServerStorage` del place compilado. Conviene borrarla antes de publicar, aunque no se ejecuta sola.
