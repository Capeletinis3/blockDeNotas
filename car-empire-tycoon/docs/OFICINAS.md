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
