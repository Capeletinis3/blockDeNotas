# Patada Demoledora (nombre provisional)

Juego de Roblox: desarrollás una patada cada vez más poderosa y la usás para lanzar objetos contra escenarios destructibles que provocan reacciones en cadena.

## Fase 1

Recorrido: entrar → entrenar → patear → provocar una cadena → cobrar → mejorar pelota o zapatillas → comprobar la diferencia → repetir.

- Escenario con una plataforma sobre dos soportes y cajas encima, un panel reforzado al centro y una pared de freno.
- Plata: $10 por rotura directa y $25 por rotura en cadena.
- Pelota mejorable (x1 → x1,5 → x2 de capacidad de rotura, y pierde menos velocidad al atravesar).
- Entrenamiento de piernas en la zona azul: suma fuerza.
- Zapatillas que multiplican la fuerza: potencia de patada = fuerza × zapatillas.
- El progreso dura la sesión (todavía no se guarda al salir).

### Controles

| Acción    | Computadora | Celular          |
|-----------|-------------|------------------|
| Apuntar   | Q / E       | Botones ◀ ▶      |
| Patear    | F           | Botón PATEAR     |
| Entrenar  | T (en la zona azul) | Botón ENTRENAR |
| Reiniciar | R           | Botón Reiniciar  |
| Tienda    | Botón TIENDA | Botón TIENDA    |

## Abrirlo directo (sin Rojo)

Si tenés `PatadaDemoledora.rbxl`, abrilo con doble clic o desde Studio (File → Open) y dale Play.

Para generarlo desde el repo: `rojo build default.project.json -o PatadaDemoledora.rbxl`

## Cómo abrirlo en Studio (Rojo)

1. Instalá [Rojo](https://rojo.space) 7.x (CLI) y el plugin de Rojo para Studio (`rojo plugin install`).
2. En la carpeta del repo: `rojo serve`
3. En Studio abrí una place (vale la plantilla Baseplate), conectá el plugin de Rojo y dale Play.

El escenario se genera por código al iniciar el servidor, así que no hace falta ningún `.rbxl`.

## Estructura

```
src/shared/Balance.luau         precios, multiplicadores, fuerza y plata
src/shared/Progression.luau     reglas de compras, entrenamiento y pagos (sin APIs de Roblox)
src/shared/Config.luau          física, escenario, sonidos y presentación
src/shared/Aim.luau             dirección de la patada según el ángulo
src/server/Main.server.luau     escenario, patada, roturas, cobro, tienda y entrenamiento
src/client/Patada.client.luau   interfaz, apuntado y controles
tests/progression.test.luau     tests de la lógica de progresión
docs/PRUEBAS.md                 lista de pruebas para hacer en Studio
```

## Tests

```
luau tests/progression.test.luau
```

Usa el intérprete de [Luau](https://github.com/luau-lang/luau/releases). Cubre plata, compras, zapatillas y el límite de entrenamiento. La física y la interfaz se prueban en Studio con `docs/PRUEBAS.md`.

## Qué ajustar al probar

- `Balance.luau`: precios, multiplicadores, fuerza inicial, ritmo de entrenamiento y cómo la potencia se convierte en velocidad.
- `Config.luau`: resistencias de los materiales (`Materials.*.Strength`), tiempos del intento y sonidos.
