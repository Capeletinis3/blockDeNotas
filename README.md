# Patada Demoledora (nombre provisional)

Juego de Roblox: desarrollás una patada cada vez más poderosa y la usás para lanzar objetos contra escenarios destructibles que provocan reacciones en cadena.

## Prototipo actual

Objetivo: **patear una pelota, golpear un soporte y provocar que caiga una estructura.**

- Piso con zona de patada y una pelota con potencia fija.
- Plataforma sobre dos soportes de madera, con cajas encima. Detrás hay una pared que frena la pelota.
- Si el impacto supera la resistencia del soporte, este se rompe y la plataforma cae.
- Al terminar se muestra el resultado y el escenario se reinicia solo.

### Controles

| Acción    | Computadora | Celular        |
|-----------|-------------|----------------|
| Apuntar   | Q / E       | Botones ◀ ▶    |
| Patear    | F           | Botón PATEAR   |
| Reiniciar | R           | Botón Reiniciar |

## Abrirlo directo (sin Rojo)

Si tenés `PatadaDemoledora.rbxl`, abrilo con doble clic o desde Studio (File → Open) y dale Play.

Para generarlo desde el repo: `rojo build default.project.json -o PatadaDemoledora.rbxl`

## Cómo abrirlo en Studio (Rojo)

1. Instalá [Rojo](https://rojo.space) 7.x (CLI) y el plugin de Rojo para Studio.
2. En la carpeta del repo: `rojo serve`
3. En Studio abrí una place (vale la plantilla Baseplate), conectá el plugin de Rojo y dale Play.

El escenario se genera por código al iniciar el servidor, así que no hace falta ningún `.rbxl`.

## Estructura

```
src/shared/Config.luau          valores ajustables (potencia, resistencias, tiempos)
src/shared/Aim.luau             dirección de la patada según el ángulo
src/server/Main.server.luau     escenario, patada, roturas, resultado y reinicio
src/client/Patada.client.luau   interfaz, apuntado y controles
```

## Qué ajustar al probar

Todo está en `src/shared/Config.luau`:

- `KickSpeed`: potencia de la patada.
- `Materials.Madera.Strength`: resistencia de los soportes. Si la pelota los golpea y no se rompen, el mensaje indica qué porcentaje de la fuerza necesaria llegó.
- `Materials.Caja.Strength`: resistencia de las cajas al caer.
