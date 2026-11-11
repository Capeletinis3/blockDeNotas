# Primer ciclo jugable (etapa 6)

Crear empresa → diseñar → finalizar → fabricar un lote → reseñas → precio → vender → beneficio → otro modelo.
Esta etapa fue de auditoría, integración y pruebas: el ciclo ya estaba implementado y no se reescribió.

## Auditoría

Se recorrió el ciclo completo por las solicitudes reales del servidor (Sessions) con el capital inicial, sin
tocar el dinero, y por la interfaz (entorno simulado) como un jugador nuevo.

| Parte | Estado |
| --- | --- |
| Empresa nueva 1970, sedán y coupé, motores I4/I6 nivel 1 | Funciona |
| Borradores (guardar, salir, volver), finalización única, id único, desarrollo cobrado una vez | Funciona |
| Validación del servidor (nombre, piezas desconocidas o bloqueadas, fondos) con motivo | Funciona |
| Lote pagado al ordenar, una línea al inicio, un lote por modelo, sin cancelación | Funciona |
| Producción con 1×/2×/3×, pausa de menús, sin progreso sin conexión | Funciona |
| Cuatro reseñas una sola vez, guardadas, iguales al recargar | Funciona |
| Precio recomendado, precio validado, ventas automáticas, nunca más que lo fabricado, agotado, cerrar venta | Funciona |
| Contabilidad (dinero = inicial + movimientos), historial, PI, experiencia, reputación | Funciona |
| Empresas independientes, guardado en cada fase | Funciona |

### Errores encontrados y corregidos (interfaz y continuidad)

1. **Callejón sin salida del botón principal** (`ScreenHud.nextAction`): terminado el tutorial, sin lotes activos y
   con todos los modelos ya fabricados, el botón decía «Lanzar un lote» y abría un catálogo donde nada se podía
   fabricar. Ahora propone «Diseñar otro modelo» y abre el editor.
2. **Sin aviso de primeras ventas en lotes chicos**: el único aviso intermedio era «Lanzamiento exitoso» a las 100
   ventas, que un primer lote (≤ 32 unidades con el capital inicial) nunca alcanza. Ahora hay un aviso breve
   «Primeras ventas de …» una vez por lote (`Simulation.stepSales`, solo en pantalla: no se guarda en la partida).
3. **Atajos de cantidad engañosos** (diálogo del lote): 50, 100, 500 y 1.000 se veían elegibles con el capital
   inicial aunque no alcanzaba. Ahora se ven apagados y, al tocarlos, dicen cuánto cuestan. «Máximo que alcanza» y
   la cantidad escrita siguen igual. (`Ui.opt` publica su atributo `disabled`, como `Ui.button`.)
4. **Ventas que «no arrancan»**: con el menú de Ventas abierto la empresa está en pausa (regla existente), así que
   lo recién lanzado no se vende hasta volver al juego. Ventas ahora lo explica en el modelo recién lanzado.

5. **Alerta superior contradictoria** (`ScreenHud.topAlert`): con todos los modelos ya fabricados decía «La fábrica
   está parada. Lanzá un lote…» mientras el botón principal proponía «Diseñar otro modelo». Ahora, sin lotes activos:
   sin diseños → «Diseñá tu primer automóvil para comenzar»; con modelos fabricables → «La fábrica está parada.
   Iniciá la producción de uno de tus modelos»; con todos usados → «Tu último modelo completó su ciclo. Diseñá un
   nuevo automóvil para continuar» (abre el editor). Con lotes activos no aparece ninguna de esas tres. El botón y la
   alerta usan la misma regla (`ScreenHud.fabricable`, basada en `Dialogs.lotBlock`, la del catálogo del lote).

### Comportamientos revisados que se conservan (no son errores)

- Un componente omitido en la solicitud se completa con el predeterminado de la carrocería (compatibilidad); uno
  desconocido o bloqueado se rechaza con su motivo. El editor siempre envía todos: no hay autos incompletos.
- Un precio con decimales se redondea al dólar entero (1,5 → $2); cero, negativos, NaN e infinito se rechazan.
- Las reseñas dependen del auto y de la fecha en que termina el lote; se calculan una vez y quedan guardadas.

## Equilibrio inicial (medido, sin cambios)

Capital $90.000 · desarrollo del primer sedán $18.500 · costo por unidad $2.226 → el primer lote puede tener hasta
**32 unidades**. Lote de 30 vendido al recomendado ($3.560): ingresos $106.800, beneficio del lote $40.020, la
empresa termina con $111.520. Fabricación ≈ 2 min reales a 1×, ventas ≈ 1½ min. Un segundo sedán cuesta solo $2.500
de ingeniería (licencia ya pagada) y alcanza para ~48 unidades; un coupé nuevo cuesta $24.500. La partida normal es
posible sin cambiar costos. Nota: un primer lote de 50 o más no es posible sin la recompensa del tutorial.

## Cómo completar el primer ciclo

1. Crear la empresa (nombre, color y símbolo) en el menú.
2. Botón principal **Diseñar mi primer auto** → editor: carrocería, componentes, apariencia, ajustes y resumen
   (Siguiente en cada etapa). El borrador se guarda solo.
3. **Finalizar diseño** → confirmar. Se cobra el desarrollo y se pasa a Producción.
4. **Iniciar producción** (o el botón principal) → elegir el modelo → escribir la cantidad (o «Máximo que
   alcanza») → Continuar → **Confirmar producción**. Se paga completo.
5. Volver al juego y dejar correr el tiempo (1×, 2× o 3×). Al terminar se abren las **reseñas** de los cuatro
   críticos; al cerrarlas se va a Ventas.
6. **Usar el recomendado** (o escribir otro precio) → **Poner a la venta**. Volver al juego: se vende solo.
7. Avisos «Primeras ventas» y «¡Agotado!» con el beneficio. El lote pasa al historial.
8. Botón principal **Diseñar otro modelo** (cada modelo fabrica un solo lote).

## Pruebas

- **Unitarias** (tests/run.luau): reglas puras ya existentes (DesignCalc, Rules, Staff, reseñas, precios).
- **Integración del servidor** (tests/run.luau, `[CJ1]`–`[CJ3]`): los 22 casos con sesiones reales y guardado en
  memoria, más un verificador de estados imposibles después de cada paso (unidades, estados, reseñas, cobros, líneas,
  un lote por modelo, contador de ventas y dinero = inicial + movimientos) y un recorrido al azar de 900 pasos con
  velocidades, pausas, lotes, ventas, cierres y recargas.
- **Integración de la interfaz** (tests/ui.luau, «Etapa 6: ciclo jugable guiado…»): jugador nuevo con el capital
  inicial, solo con el botón principal y los controles visibles, hasta la ganancia y el segundo modelo.
- **Manual en Roblox Studio** (pendiente): aspecto de los avisos y de los atajos apagados, lectura del aviso de
  Ventas, ritmo real del primer ciclo a 1×, 2× y 3×, y el guardado real en DataStore (las pruebas usan memoria).
