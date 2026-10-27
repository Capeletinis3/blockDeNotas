# Pioneer 70 · primer vehículo 3D integrado

El Pioneer 70 (`Pioneer70_World`) es la carrocería 3D del **sedán**. Es la predeterminada de 1970 a 1979 y
desde 1970 queda disponible para elegir en cualquier década. Es solo visual: no cambia costos,
estadísticas, ventas ni la economía. No se modificó el diseño 3D del modelo.

> **Studio:** no se probó dentro de Roblox Studio. Se probó con:
> - el modelo real, leído de `Pioneer70_World.rbxm` (38 piezas, nombres, posiciones, colores y materiales);
> - las pruebas automáticas sobre un entorno Roblox simulado;
> - el `.rbxl` generado con Rojo.

## Cómo funciona

| Paso | Dónde | Qué hace |
|---|---|---|
| Identificación | `Catalog.VEHICLE_MODELS` | Define `{ id = "pioneer70", type = "sedan", year = 1970, default = { 1970, 1979 }, asset = "Pioneer70_World", paintSuffix = "_Paint" }`. Cada diseño guarda `vehicleModel`: `"pioneer70"`, `"provisional"` o nada (= la predeterminada de su tipo y su año de modelo). `Catalog.resolveVehicleModel(spec)` decide cuál corresponde. |
| Selección | Editor › paso 3 › «Carrocería y detalles» › **Carrocería 3D** | Solo aparece en los sedanes: «Pioneer 70» o «Provisional (genérica)». Un sedán nuevo de los 70 ya viene con el Pioneer 70. Al cambiar a otro tipo de base vuelve a la carrocería de ese tipo. |
| Guardado y validación | `DesignCalc.sanitize`, `GameState` | El servidor acepta solo carrocerías del catálogo, del tipo correcto y ya disponibles. Cambiar la carrocería es un cambio **estético**: no paga ingeniería. Una partida con una carrocería que ya no exista sigue siendo válida (se ve el modelo provisional). |
| Fabricación | `Simulation.designSnapshot` | Cada lote copia el diseño completo, así que el lote conserva su carrocería aunque después se edite el diseño. |
| Original y copia para el cliente | `Main.server.luau` | Lee el original de `ServerStorage.VehicleModels.Pioneer70_World` y **no lo modifica**. Publica una copia sin scripts en `ReplicatedStorage.CarEmpireAssets.VehicleModels`, para el editor y las miniaturas del cliente. Si falta el modelo, avisa en Output y se usa el provisional, sin errores. |
| Copias | `CarModel.template` / `CarModel.fromVehicleModel` | Prepara **una** plantilla por modelo: quita los scripts, ancla las piezas, saca la colisión y pone el pivote en el centro, a la altura de las ruedas (frente hacia −Z). Cada auto que se muestra es un clon de la plantilla, con las mismas piezas, mallas, materiales y posiciones relativas. |
| Pintura | `CarModel.fromVehicleModel` | Las piezas cuyo nombre termina en `_Paint` toman el color principal del diseño, con su intensidad (Body, Hood, Trunk y las 4 puertas). También sirve el atributo `Pintura = "primaria"/"secundaria"`. Neumáticos, llantas, cristales, asientos, faros, cromados, paragolpes e interior conservan su color y material. |
| Pivote | `CarModel.template` | Las piezas importadas de Blender traen un `PivotOffset` girado 90°. Como Roblox usa el pivote de la `PrimaryPart` e ignora `WorldPivot`, la plantilla fija el `PivotOffset` de su pieza principal en el centro, a ras del suelo y sin giro. Así el auto queda horizontal y apoyado. Se corrigió después de la primera prueba en Studio. |
| Garaje | `Garage:update` | Muestra el auto en la línea (semitransparente mientras se fabrica), en el almacén y en el concesionario. Se reconstruye solo cuando cambian los lotes y nunca hay más de 9 autos por parcela. Las filas del almacén pasaron de 16 a 18 studs y las plataformas del concesionario, de 15 a 20 de diámetro, para que entre el largo del Pioneer (17,5). |

## Qué hacer en Studio

1. **Tu place con el modelo ya configurado:** dejá el modelo donde está (`ServerStorage → VehicleModels →
   Pioneer70_World`) y sincronizá los scripts con `rojo serve` (usa `default.project.json`, que no toca
   `ServerStorage`). No hace falta moverlo ni importar el `.rbxm`.
2. **Recomendado:** borrar el `Script` de prueba que está dentro de `Pioneer70_World` (el que pinta de azul
   a los 3 segundos). El juego ya lo quita de cada copia, pero en el original no hace falta.
3. **Las mallas** son assets de tu cuenta (`rbxassetid://…`). Para que carguen en el juego publicado,
   el place tiene que pertenecer a la misma cuenta o grupo que subió las mallas, o las mallas tienen
   que tener permiso para esa experiencia.
4. **Si abrís el `CarEmpireTycoon.rbxl` de la entrega:** ya trae el Pioneer 70 en
   `ServerStorage.VehicleModels`, desde la copia de seguridad `assets/vehicles/Pioneer70_World.rbxm`.

## Pruebas automáticas

- `tests/run.luau` (bloque «Pioneer 70») comprueba:
  - predeterminada de 1970 a 1979 y no en 1980;
  - elegible en 1995;
  - solo sedanes;
  - el saneamiento rechaza carrocerías desconocidas;
  - el cambio de carrocería es estético (gratis, sin cambiar costos ni estadísticas);
  - el lote conserva la carrocería;
  - los diseños viejos sin el campo se resuelven;
  - la validación de la partida.
- `tests/ui.luau` (bloque «Pioneer 70», con el `.rbxm` real) comprueba:
  - la copia publicada no lleva scripts y el original queda intacto;
  - las 38 piezas se conservan, con la misma jerarquía, materiales y tamaños;
  - se pintan exactamente las 7 piezas `_Paint` y el resto conserva su color;
  - las ruedas apoyan en el suelo y las distancias entre piezas no cambian;
  - fantasma en fabricación;
  - se usa el provisional si falta el modelo;
  - el selector del editor;
  - el sedán fabricado aparece en el garaje con el Pioneer 70, sin superar 9 autos por parcela.

## Falta probar en Studio

- Que las mallas carguen (permisos de los assets) y que el auto se vea bien en el garaje: línea, almacén y concesionario.
- El editor: vista 3D y cámaras con el Pioneer 70, encuadre y miniaturas.
- La pintura con varios colores y acabados. El acabado (mate, metálico, perlado, cromado) no cambia el material del modelo 3D; solo el color.
- El rendimiento con 8 jugadores: hasta 9 autos de 38 piezas por parcela, unas 2.700 piezas ancladas y sin colisión.
