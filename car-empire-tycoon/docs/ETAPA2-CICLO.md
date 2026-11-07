# Etapa 2 · primer ciclo jugable

Diseñar → fabricar un lote → reseñas → precio → vender → ganancia. Se reutilizó lo que ya existía:
- el editor de diseño;
- los lotes, que avanzan con el reloj único, las velocidades y la pausa;
- las ventas automáticas por demanda, precio, atractivo y reputación;
- la economía de servidor y el guardado.

Se agregó lo que faltaba. No se probó en Roblox Studio.

## Qué cambió

| Parte | Antes | Ahora |
|---|---|---|
| **Tecnologías de 1970** | Cuatro chasis y tres motores | Chasis **Sedán básico 1970** y **Coupé básico 1970**; motores **I4 1.6 · nivel 1** e **I6 2.5 · nivel 1** (nuevo). El compacto llega en 1972, la pickup en 1973, el I4 1.3 en 1973 y el V6 en 1975. Chasis con familia y generación (`Catalog.CHASSIS_GEN`); motores con familia y nivel (`Catalog.ENGINE_LEVELS`). Los diseños guardan sus piezas originales. |
| **Lotes** | Varios por modelo; se pagaba cada unidad al fabricarla | **Un solo lote por modelo** (para volver a fabricar: Duplicar o nueva generación). El lote **se paga completo al ordenarlo**: nunca queda a medio fabricar por falta de dinero. Cerrar un lote a medio fabricar reintegra lo no fabricado. |
| **Venta** | Se vendía mientras se fabricaba | Se fabrica completo, llegan las **reseñas** y queda «Por lanzar». El jugador elige el precio («Poner a la venta») y desde ahí se vende solo; el precio se puede cambiar después. |
| **Críticos** | No existían | Cuatro críticos con nombre, medio y personalidad (`Catalog.CRITICS`). Cada uno pondera aspectos reales del auto, el nivel tecnológico y la relación costo/valor frente a lo esperado en la época. Notas de 1 a 10 con un decimal y un comentario según su punto más fuerte o más flojo; nota final = promedio. Se calculan una vez al terminar el lote, se guardan, no son al azar y multiplican la demanda por (nota / 6)^1,2. |
| **Ingeniería** | Costo fijo por época | Con poco dinero, la ingeniería de un modelo nuevo no supera el 25 % del dinero disponible (piso: 10 % del costo normal). Evita que una empresa quede trabada sin poder fabricar. |
| **Magnate** | $50.000 iniciales | $65.000, para que alcance un primer lote pagado por adelantado. |

**Interfaz:**
- Diálogo de lote: costo total, duración y estimación de ventas, más un aviso si no alcanza el dinero (con un botón para usar el máximo que alcanza). Solo lista los modelos sin lote.
- Reseñas: se abren solas al terminar el lote. Los críticos aparecen de a uno, con un segundo entre cada uno, y se puede «Saltar». Muestran la nota final y su efecto en la demanda, y debajo se fija el precio de lanzamiento.
- Ventas: estados «En fabricación» y «Por lanzar», nota de los críticos y botones «Ver reseñas y poner a la venta» y «Reseñas».
- HUD: la siguiente acción es «Poner a la venta».

**Datos:** esquema 7, con migración 6 → 7. Los modelos que ya habían fabricado quedan marcados; los lotes que estaban a la venta siguen igual, sin reseñas.

## Pruebas

Todas sin fallas.
- `lune run tests/run.luau`: 7.676 comprobaciones. La nueva [E2] recorre con sesiones reales los 10 puntos pedidos:
  1. empresa en 1970;
  2. sedán con motor I4;
  3. diseño confirmado;
  4. lote de 100, cobrado completo;
  5. producción que avanza, más rápida a 3× y detenida en pausa;
  6. cuatro reseñas coherentes, guardadas e iguales al recalcularlas, que cambian la demanda;
  7. precio fijado y modificado;
  8. las 100 unidades vendidas de a poco;
  9. ingresos sumados al dinero;
  10. guardar y recuperar en otro servidor sin duplicados.
- `lune run tests/ui.luau`: 876 comprobaciones. El recorrido por la interfaz ordena el lote, ve abrirse las reseñas solas (de a una), las salta, fija el precio, vende, modifica el precio y cierra la venta.
- `selene src tests`: sin avisos.

**Ritmo (bot de balance, provisional):** con un lote por modelo la progresión es más lenta. El optimizador llega al Imperio en 2006 (antes, 1996), y la estrategia mínima termina 2030 con dinero positivo. Los valores están en `Catalog.ECON`.

## Cómo probar en Studio

1. Crear una empresa. En Diseño hay solo dos chasis (Sedán y Coupé básicos) y en Motor, I4 e I6 nivel 1.
2. Guardar un sedán I4 y, en Producción › Lanzar lote, escribir 100. El diálogo muestra el costo total (se descuenta al ordenar) y la duración.
3. Volver a la sede: el lote avanza (a 3×, más rápido); al abrir un panel se detiene.
4. Al terminar se abren las reseñas: cuatro críticos de a uno (o «Saltar»), luego la nota final. Elegir el precio y «Poner a la venta».
5. Ventas: el stock baja de a poco, las vendidas y los ingresos suben y figura la nota de los críticos. «Modificar precio» cambia el ritmo.
6. Intentar ordenar otro lote del mismo modelo: no se puede (Duplicar crea un modelo nuevo).
7. Compañía › «Guardar y volver al menú», reabrir: todo igual, sin duplicados.
