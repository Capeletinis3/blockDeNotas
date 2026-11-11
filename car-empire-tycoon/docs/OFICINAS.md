# Oficinas decorables

Solo datos y servicios. Sin editor, cámara, cuadrícula visible ni modelos 3D. No probado en Roblox Studio ni con DataStore real.

## Módulos
- `src/shared/OfficeCatalog.luau`: categorías, muebles (8 registros de prueba de 1970), acabados, planos por nivel de oficinas (habitaciones con id estable, tamaño en casillas de 2 studs y accesos obligatorios), `ROOM_MAP` para habitaciones que cambien de id y mobiliario inicial.
- `src/shared/Office.luau`: reglas puras (sin servicios de Roblox): creación, validación, reparación, catálogo histórico, inventario, cuadrícula y giros, validación de ubicaciones, mobiliario inicial, ampliaciones, bonificaciones aisladas, cotización de remodelaciones y puntos de interacción del avatar.
- `src/server/OfficeService.luau`: operaciones económicas atómicas (`place`, `move`, `remove`). **No están expuestas al cliente** (Sessions no las registra).

## Datos por empresa (`g.office`, esquema 18)
```
version, level (sigue a g.sede), seq (ids de instancia),
inventory = { [idMueble] = cantidad ≥ 1 }           -- guardados
placed    = { { id, item, room, x, y, rot } }        -- colocados (x, y = centro en casillas de la habitación, múltiplos de 0,5; rot múltiplo de 45)
finishes  = { [idHabitación] = { floor, wall, covering, lighting } }
storedFinishes? = acabados de habitaciones que el plano actual no tiene
starter = true (mobiliario inicial ya entregado), ops = últimos opId aplicados
```
Un mueble propio está guardado o colocado, nunca en los dos.

## Reglas
- **Compra:** solo al colocar. Si hay uno en el inventario se usa ese (gratis). Si no, se cobra el precio del catálogo con este orden de validación: año, ubicación, fondos. Si algo falla no se toca nada. Mover y girar es gratis; retirar devuelve el mueble al inventario sin reembolso. Una solicitud repetida (`opId`) se aplica una sola vez.
- **Cuadrícula:** se valida la habitación del plano actual, el giro permitido, la alineación (con giros rectos un lado par se centra en una línea y uno impar en una casilla), los límites, las casillas ocupadas y los accesos. `Office.extraCheck` queda para las colisiones 3D (etapa 2).
- **Histórico:** `Office.available(item, año)`: desde su año y para siempre. No depende de la investigación.
- **Bonificaciones (sin conectar):** `Office.furnitureRaw` suma solo lo colocado, con rendimientos decrecientes (×0,5 por copia). `Office.sharedBonus(personal, muebles, tope)` aplica el tope único de la habilidad. Para conectarlo, `Rules.staff` debe usar esa función (una sola aplicación).
- **Remodelaciones:** `Office.remodelQuote` cotiza el piso por casilla, las paredes y revestimientos por tramo y la iluminación por luminaria (una cada 12 casillas). Cotizar es gratis; el cobro llega con el editor.
- **Ampliación:** al terminar la obra de oficinas (`Simulation.stepBuilds`), `Office.remap` conserva los muebles y acabados de las habitaciones equivalentes, manda al inventario lo que no entra y da acabados básicos a las habitaciones nuevas.
- **Carga:** `GameState.loadProfile` repara la oficina con `Office.sanitize` (los muebles inválidos vuelven al inventario) antes de validar, para que un dato de decoración no dañe la empresa.

## Pendiente para la etapa 2
Editor isométrico (cámara, cuadrícula visible, techo oculto, paredes semitransparentes) que previsualice con `Office.validatePlacement`. Registrar `OfficeService.place/move/remove` y una acción de remodelación en Sessions. Ubicación del plano en el mundo (origen de cada habitación) y modelos 3D (`model`). Colisiones 3D en `Office.extraCheck`. Conectar `Office.interactionSpots` a OwnerAvatar y `Office.sharedBonus` a `Rules.staff`.

## Etapa 2: editor 3D (sin probar en Roblox Studio)

### Correcciones de la etapa 1 (esquema 19, migración aditiva e idempotente)
- El escritorio y la silla iniciales empiezan **guardados en el inventario**. Las partidas del esquema 18 que los tenían colocados en su lugar inicial los recuperan en el inventario (`Office.unplaceStarter`), sin crear ni perder muebles. Si el escritorio ya no estaba en su lugar inicial, no se toca.
- Colisiones con la intersección real de rectángulos girados (`Office.overlaps`, eje separador), límites por esquinas (`Office.insideRoom`) y accesos como casillas completas.
- Todos los muebles giran de a 45°.
- `office.seq` se sincroniza con los ids existentes (`Office.syncSeq`): nunca se reutiliza un id.

### Acciones del servidor
`officePlace`, `officeMove` y `officeRemove` (Actions → OfficeService) son económicas en Sessions:
- Exigen `requestId`; un reenvío devuelve la respuesta original (instancia y monto cobrado incluidos).
- El `requestId` es además el `opId` de la oficina, así que tampoco se aplica dos veces después de recargar.
- Guardan enseguida, respetando el intervalo mínimo del guardado.
- Cada cambio sube `office.rev`, de modo que el cliente recibe la oficina actualizada.

### Cliente
- `OfficeScene`: escena aislada en este cliente, lejos del mapa. Muestra las habitaciones del plano con su cuadrícula, los accesos en azul y paredes bajas sin techo que se aclaran cuando tapan la vista. Los muebles se sincronizan por diferencias y la vista previa usa Highlight (verde o rojo).
- `OfficeModels`: los 8 muebles provisionales con Parts y las medidas del catálogo. Se reemplazan solos si existe `ReplicatedStorage.CarEmpireAssets.Muebles.<item.model>` (Model con PrimaryPart en la base y el frente hacia −Z).
- `OfficeCamera`: cámara isométrica, con control exclusivo cuando `App.cameraOwner == "office"`. Clic derecho + arrastrar o Q/E giran; la rueda hace zoom; W A S D o clic de la rueda desplazan.
- `OfficeEditor`: estado y colocación con `Office.validatePlacement`, las mismas reglas que el servidor. La API (`startPlace`, `hover`, `rotate`, `confirm`, `selectAt`, `startMove`, `rotateSelected`, `removeSelected`, `cancel`) la usan el mouse y las pruebas, y queda preparada para controles táctiles.
- `ScreenOffice`: barra superior, panel lateral (habitaciones, catálogo por categorías, inventario) y barra contextual. Se entra desde Compañía › Instalaciones › Oficinas centrales › **Personalizar oficina** (ruta `oficina`, pausa la empresa).

### Pendiente (etapas siguientes)
- Bonificaciones del mobiliario: conectar `Office.sharedBonus` a `Rules.staff`.
- Que el avatar use los muebles colocados (`Office.interactionSpots`).
- Remodelación de acabados con cobro (`Office.remodelQuote`).
- Controles táctiles y modelos 3D definitivos.
- Ubicar las oficinas dentro de los edificios reales de la parcela.

### Estabilización de la etapa 2
- Inventario del editor: `Office.inventoryList` recorre lo guardado sin filtrar por año (antes `catalogFor(0)` devolvía una lista vacía).
- Cursor fuera de las habitaciones: se olvida la posición anterior y la vista previa desaparece. Confirmar no envía nada.
- Reintentos: cada operación del editor lleva su `requestId`. Si no hay respuesta (`App.request` devuelve `noResponse`) o el servidor no la procesó (`retry`: acción en curso o límite de acciones), queda pendiente con ese mismo id. «Reintentar», o cualquier confirmación siguiente, la reenvía igual y el servidor responde `duplicate` si ya la había aplicado; después se pide el estado con `sync`.
- Medidas: el tamaño declarado de cada mueble nunca supera sus casillas. El sofá pasó de 2,4 a 2 studs de profundidad, y una prueba mide todas las piezas de los 8 modelos provisionales.

## Etapa 3: remodelación de interiores (sin probar en Roblox Studio)

Sin cambios de esquema (19). Los acabados ya vivían en `g.office.finishes[habitación]`.
- **Catálogo** (`OfficeCatalog`): mismos precios. Se agregaron datos visuales a cada acabado: `materialName`, `color`, `variant` opcional (MaterialVariant definitivo), `height` del revestimiento, y `light` y `fixture` de la iluminación. También `FINISH_KINDS`, `FINISH_UNITS` y `finishList(tipo)`. Un acabado nuevo aparece en el editor y en la escena solo con sus datos.
- **Servidor** (`OfficeService.remodel`, acción `officeRemodel`, económica):
  - El cliente manda la habitación, los ids elegidos por categoría, `rev` y `quote`.
  - El servidor recalcula con `Office.remodelQuote` (plano real del nivel y año de la empresa).
  - Rechaza sin cambiar nada:
    - habitaciones de otro nivel, categorías o ids desconocidos, materiales futuros;
    - pedidos sin cambios efectivos;
    - `rev` distinta (la oficina cambió) o `quote` distinto (presupuesto desactualizado);
    - fondos insuficientes;
    - una operación de otra empresa (`companyId`).
  - Lo instalado no se cobra. Volver a un acabado gratis cuesta 0 y no reembolsa.
  - Cobra, actualiza los acabados, sube `rev`, registra el `opId` y guarda enseguida.
- **Escena** (`OfficeScene`): la geometría se arma una vez por nivel y `applyLook(habitación, acabados)` cambia solo lo que difiere:
  - material y color del piso;
  - pintura de las paredes;
  - revestimiento como banda apoyada en la cara interior de cada pared (sin superficies superpuestas; se aclara con su pared);
  - luminarias provisionales con hasta 4 PointLight por habitación.
  - No toca Lighting ni muebles. Cuadrícula normal, tenue u oculta. La habitación elegida se marca con un SelectionBox.
- **Editor** (`OfficeEditor`): secciones Mobiliario y Remodelación.
  - `drafts[habitación]` es solo vista previa: no toca la partida, no cobra y no envía nada.
  - Funciones: `choose`, `quote`, `restoreRoom` (Restaurar selección), `cancelRemodel` (Cancelar cambios) y `confirmRemodel`.
  - Al salir del editor o cambiar de empresa los borradores se descartan.
- **Operaciones inciertas**:
  - Se guardan por empresa (`pendingByCompany`) con su `requestId` y `companyId`, y sobreviven a salir del editor y a cambiar de empresa.
  - Solo se resuelven con una respuesta del servidor a ese mismo `requestId`; «Actualizar vista» no las descarta.
  - Una respuesta tardía de otra empresa no toca la empresa abierta.
- **Pantalla** (`ScreenOffice`):
  - Selector Mobiliario / Remodelación.
  - Panel lateral con habitaciones (marca «sin confirmar»), las cuatro categorías y tarjetas de acabado: categoría, material, año, precio por unidad, cantidad para la habitación y costo.
  - Panel de presupuesto: actual → elegido, cantidad y costo por línea, total, dinero disponible y restante, y los botones Confirmar (con el costo), Restaurar selección y Cancelar cambios.

### Ajustes de la etapa 3
- **Tramos de pared:** `Office.wallRuns(habitación)` es la única regla de paredes (perímetro con una abertura en cada casilla de acceso pegada al borde). `Office.wallLength` suma esos tramos y lo usan el presupuesto del cliente y del servidor; `OfficeScene` arma las paredes con los mismos tramos. Antes se cobraba el perímetro completo; por ejemplo, la oficina principal del nivel 1 pasó de 36 a 34 tramos. Precios unitarios sin cambios.
- **MaterialVariant:** `applySurface` siempre reescribe la variante. Si el acabado nuevo no tiene una, o no está cargada en MaterialService, se quita la anterior.

## Etapa 4: bonificaciones del mobiliario (sin probar en Roblox Studio)

Sin cambios de esquema (19) ni datos guardados nuevos: todo se calcula desde `g.office.placed`.
- **Cálculo** (`Office.furnitureRaw`):
  - Solo cuentan los muebles colocados en una habitación del plano actual; lo guardado no suma.
  - Por tipo de mueble con n copias: `value × (1 − 0,5ⁿ) / (1 − 0,5)` (1 → 1 %, 2 → 1,5 %, 3 → 1,75 %).
  - Determinista: depende solo de la cantidad de copias por tipo, y los tipos se suman en orden fijo.
  - No cuentan los muebles desconocidos, los ids repetidos ni las habitaciones de otro nivel.
  - Hay una caché por oficina que se invalida cuando cambian la revisión, el nivel o la cantidad de colocados.
- **Combinación** (`Staff.bonusDetail`): `min(tope, personal + mobiliario)` con `Office.sharedBonus`.
  - Devuelve además el aporte del personal y el del mobiliario por separado.
  - Es el único lugar donde se combinan: `Rules.staff → Staff.bonus → Staff.bonusDetail`, así que toda la economía lo recibe una sola vez.
  - `Staff.previewHire` y `Staff.deptSummary` usan el valor combinado, por lo que la mejora de una contratación es la efectiva hasta el tope compartido.
  - Adaptación, capacitación y deuda salarial afectan solo al aporte del personal.
- **Actividades ya iniciadas** (mismo criterio que el personal):
  - Lo pagado o fijado al empezar no cambia: el costo de una obra (gestión), los PI y el dinero de una investigación (conocimiento, precisión) y las expansiones ya compradas.
  - Los ritmos en curso sí se actualizan: el avance diario de las obras (organización) y el mantenimiento que se cobra cada mes (finanzas).
  - Nada se recalcula hacia atrás.
- **Interfaz:**
  - Las tarjetas de muebles muestran la habilidad y su efecto, el beneficio base, la cantidad colocada, el aporte actual, lo que sumaría otra unidad de verdad (con el tope) y el aviso de tope alcanzado. La compra nunca se bloquea.
  - La pestaña «Beneficios» del editor muestra, por departamento, personal, mobiliario, total sobre el tope y lo que se desperdicia.
  - En Personal, cada bonificación muestra el desglose personal / mobiliario y el aviso de tope compartido.
- **Interacciones (preparadas, sin NPC):**
  - Convención: `facing` es hacia dónde mira quien usa el mueble (0 = +x, 90 = +y); los modelos miran a −y.
  - `Office.checkInteraction` valida el catálogo.
  - `Office.interactionSpots` devuelve el punto girado con el mueble (también a 45°), si es accesible, el motivo y el lugar de llegada.
  - `Office.toWorld` pasa coordenadas de la habitación al mundo.
  - Un punto inaccesible no cambia el beneficio.

## Etapa 5: empleados visibles, navegación e interacciones (sin probar en Roblox Studio)

Los empleados visibles son **representaciones** de `g.employees`: solo existen en el cliente mientras el editor
está abierto, no son entidades económicas y no guardan nada (posiciones, rutas, reservas ni actividades).

### Módulos

| Módulo | Lado | Qué hace |
| --- | --- | --- |
| `shared/OfficeGeometry` | compartido | Geometría del plano (antes dentro de `Office`, que la reexporta con los mismos nombres) + distancia exacta punto–mueble. |
| `shared/OfficeNavigation` | compartido | Zona transitable por habitación, A*, rutas, accesibilidad desde la entrada. |
| `client/OfficeActivities` | cliente | Máquina de estados, elección de actividades, reservas, visibles y rotación (lógica pura). |
| `client/OfficeNPC` | cliente | Personaje provisional (rig de Parts) o modelo definitivo de `CarEmpireAssets.Empleados`. |
| `client/OfficeAnimations` | cliente | Poses procedurales con mezcla; `AnimationTrack` si el modelo definitivo trae `Animator` y `Animaciones`. |
| `client/OfficeNPCManager` | cliente | Ciclo de vida: abrir, sincronizar, ocultar, seleccionar, cerrar. Una sola conexión a `Heartbeat`. |

Modificados: `Office` (puntos múltiples, accesibilidad por ruta), `OfficeCatalog` (asientos del sofá, lugares de
la mesa de reuniones, `seatH`), `OfficeEditor` (abrir/cerrar empleados, selección, «Mostrar empleados»),
`OfficeScene` (`Scene.folder`), `OfficeCamera` (`focusOn`), `ScreenOffice` (interruptor, contador y panel).

### Navegación

- **Por qué no `PathfindingService`**: las piezas del editor no tienen colisión; la navegación se calcula sobre el
  plano (`OfficeCatalog.PLANS` + `g.office.placed`) con la misma geometría que valida la colocación.
- Nodos cada media casilla; un nodo es transitable si un disco de radio `RADIUS` = 0,35 casillas (0,7 studs) cabe
  sin tocar paredes ni muebles (rectángulos girados reales, también a 45°). Un pasillo de una casilla es
  transitable; uno de media casilla, no.
- 8 vecinos; en diagonal solo si los dos vecinos rectos están libres (no se cortan esquinas). Cada paso entre nodos
  y cada tramo suavizado se comprueba **en todo su recorrido** (distancia exacta, partiendo el tramo hasta poder
  asegurarlo), no con muestras sueltas.
- Entradas = nodos dentro de las casillas de acceso. Componentes conexos: un destino en otro componente se informa
  al instante como imposible (sin búsqueda).
- La grilla se guarda en caché por firma de los muebles de cada habitación: se rearma solo cuando cambian.
- Cada empleado se queda en su habitación: no hay pasillos entre ellas. `OfficeNavigation.LINKS` queda vacío y
  preparado para una escena futura con puertas reales.
- `Office.interactionAccess` exige un recorrido completo desde una entrada. No afecta `Office.furnitureRaw`: un
  mueble inaccesible conserva su beneficio pasivo.

### Actividades

Estados: `Idle`, `Walking`, `Working`, `Sitting`, `Browsing`, `Resting`, `Meeting`. Cada actividad reserva sus
puntos (instancia#slot); escritorio o mesa con una silla a ≤ 0,75 casillas de su punto = se usa sentado (reserva los
dos). Duraciones, pausas, velocidad, preferencias por departamento (solo pesos visuales), límite visible
(`MAX_VISIBLE_NPCS = 10`), rotación (`ROTATE_EVERY = 150` s) y lugar por habitación (`AREA_PER_NPC`) están al
principio de `OfficeActivities`. Las reuniones necesitan al menos dos personas en la habitación. Quien está
detenido se rodea al calcular rutas (si así no hay ruta, se calcula sin rodearlo).

Cambios de muebles: solo con la oficina **confirmada** por el servidor. Se rearman las habitaciones afectadas,
se liberan las reservas de puntos que desaparecieron o se movieron, nadie queda dentro de un mueble y las rutas
tapadas se recalculan (o se interrumpe la actividad). Los empleados nunca bloquean una operación del editor.

### Cómo verlos

Compañía › Instalaciones › Oficinas centrales › Personalizar oficina. Arriba a la izquierda: «Mostrar empleados»
y «Empleados visibles: N / M contratados». Clic sobre un personaje (modo normal, sin mueble en la mano) abre su
panel: nombre, departamento y habitación, actividad, navegación, «Enfocar». Esc lo cierra.

### Pendiente de verificar en Roblox Studio

Aspecto de los personajes y de las poses, fluidez del movimiento a 30 pasos por segundo, la selección con el
mouse sobre el personaje, el nombre sobre la cabeza y el rendimiento real con 10 empleados en el nivel 5.
