# Oficinas decorables — etapa 1 (arquitectura)

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
