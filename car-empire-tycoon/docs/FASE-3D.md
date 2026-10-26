# Fase 3D futura · qué reemplazar y cómo

En esta etapa no se crean ni mejoran modelos 3D. Las mecánicas ya guardan todo lo necesario
(configuración de cada diseño, nivel de sede, lotes en producción y en venta), así que los modelos
definitivos se pueden incorporar **sin tocar la lógica del juego**.

## Modelos provisionales a reemplazar

| Elemento | Hoy | Dónde se crea |
|---|---|---|
| Autos (editor, miniaturas, garaje) | Parts por tipo de vehículo | `src/shared/CarModel.luau` (`CarModel.build`) |
| Edificio de cada sede (5 niveles) | Una parcela provisional igual para todas | `src/server/Garage.luau` (`Garage:buildPlot`) |
| Fábrica, línea, depósito, concesionario | Bloques y carteles en la parcela | `Garage:buildPlot`, `Garage:update` |
| Vestíbulo | Bloques | `Garage:buildLobby` |

## Cómo incorporar los definitivos

- **Autos:** poner un `Model` por base en `ReplicatedStorage.CarEmpireAssets.Cars.<baseId>` (`pixel`,
  `brisa`, `toro`, `duna`, `aurora`, `titan`, `vento`, `rayo`), con el frente hacia −Z y el pivote a ras
  del suelo. Las piezas con el atributo `Pintura = "primaria"` o `"secundaria"` toman los colores del
  diseño. `CarModel.build` los usa automáticamente (`CarModel.assetResolver`, configurado en
  `Main.server.luau` y `Main.client.luau`). Para reflejar más opciones (llantas, faros, interior), leer
  `spec.wheels`, `spec.body`, `spec.interior` y `spec.parts` dentro de `CarModel.fromAssets`.
- **Sedes:** poner un `Model` por nivel en `ServerStorage.CarEmpireAssets.Sedes.Sede1` … `Sede5`
  (`Catalog.SEDES[n].asset`). `Garage:applySedeModel` lo ubica en la parcela al cargar y al ampliar.
- **Producción y concesionario:** `Garage:update` ya sabe qué lote se fabrica (`Rules.producingLots`) y
  qué modelos tienen stock: ahí se pueden animar líneas o mostrar autos en la exhibición.

## Recursos nuevos que hará falta crear

Carrocerías por tipo y época (al menos 8 bases, idealmente variantes por década), llantas por estilo y
rodado, faros halógenos/LED, interiores; cinco edificios de sede; maquinaria de línea de montaje; salón de
exhibición; ambientación del vestíbulo; animaciones de la línea.
