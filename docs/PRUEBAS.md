# Pruebas de la fase 1 (en Studio)

La lógica de plata, compras y entrenamiento está cubierta por `tests/progression.test.luau`
(`luau tests/progression.test.luau`). Todo lo demás depende de la física y la interfaz,
así que hay que probarlo jugando. Anotá qué pasó en cada punto.

## 1. Sincronización
- [ ] Al darle Play aparecen: estadísticas arriba a la izquierda, Reiniciar y TIENDA arriba a la derecha, la explicación inicial y los botones abajo.
- [ ] La ventana Output no muestra errores en rojo.

## 2. Patada y controles
- [ ] Q/E (o ◀ ▶) mueven la flecha cómodamente; llega a ±30°.
- [ ] La pelota sale hacia donde apunta la flecha.
- [ ] Alejado de la pelota, PATEAR responde "Acercate a la pelota".
- [ ] Apretar F muchas veces seguidas da una sola patada.
- [ ] El personaje gira hacia la dirección y mueve la pierna al patear.
- [ ] En celular (Studio → Test → Device emulator) los botones se ven y no tapan la estructura.

## 3. Destrucción en cadena
- [ ] Antes de patear la estructura está quieta, y empujarla caminando no la mueve (hay una barrera invisible).
- [ ] Apuntando unos 15° a un lado se rompe un soporte y la plataforma cae hacia ese lado.
- [ ] Las cajas que caen se rompen (roturas en cadena).
- [ ] El mensaje explica la causa: "¡Derribada! Rompiste el soporte izquierdo y cayeron N piezas en cadena."
- [ ] Los fragmentos desaparecen a los ~2,5 s.
- [ ] El intento termina poco después de que todo queda quieto (no más de 8 s).

## 4. Plata
- [ ] Una directa + dos en cadena = $60 (el detalle muestra las cantidades).
- [ ] Una patada sin roturas da $0.
- [ ] Reiniciar (R) varias veces seguidas no cambia el saldo.
- [ ] Reiniciar en medio de una patada cobra solo lo roto hasta ese momento.

## 5. Pelota
- [ ] Con la pelota inicial, el panel central resiste y el mensaje muestra un porcentaje.
- [ ] Comprar el nivel 2 descuenta $60; sin plata dice cuánto falta.
- [ ] Con nivel 2, el panel se rompe. Si no, anotar el porcentaje y ajustar `Materials.Reforzado.Strength` en `Config.luau`.
- [ ] El nivel se conserva al reiniciar.

## 6. Entrenamiento
- [ ] En la zona azul aparece ENTRENAR (o T); cada repetición salta y suma 1 de fuerza.
- [ ] Apretar muy rápido no suma más de 2 por segundo.
- [ ] Después de entrenar, "Potencia de patada" sube y la pelota sale más rápido.

## 7. Zapatillas
- [ ] La tienda muestra las equipadas, el multiplicador y el precio de las demás.
- [ ] Sin plata no se compran; comprando descuenta el precio y las equipa.
- [ ] Se puede volver a equipar un modelo comprado sin pagar.
- [ ] La potencia sube según el multiplicador.

## 9. Ritmo (anotar)
- Patadas hasta la primera mejora:
- Patadas entre compras:
- Repeticiones de entrenamiento que se sienten razonables:
- ¿Alguna compra es siempre mejor que las otras?

## 10. Prueba final
- [ ] Ciclo completo desde cero.
- [ ] Morir (por ejemplo, caerse del piso) y reaparecer conserva el progreso.
- [ ] Dos jugadores (Studio → Test → Clients and Servers, 2 jugadores): cobra solo el que pateó; el otro ve "Patada de otro jugador" y no puede patear hasta que termine.
- [ ] Muchas roturas seguidas no traban el juego.
- [ ] Alguien que no conoce el juego lo entiende sin explicación.
