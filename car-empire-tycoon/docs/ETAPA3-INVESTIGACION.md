# Etapa 3 · sistema de investigación

Se reutilizó lo que ya existía:
- el reloj único (días, velocidades y pausa);
- la economía de servidor;
- el editor de diseño y el guardado.

No se probó en Roblox Studio.

## Qué cambió

| Parte | Ahora |
|---|---|
| **Categorías** | Chasis, Motores, Seguridad y Tecnología, cada una con su pestaña y tarjetas de a 3. Una quinta pestaña, «Empresa (provisorio)», conserva las mejoras de producción y marketing que ya existían. |
| **PI** | Recurso propio, sin tope. Lo generan dos fuentes: el centro de investigación (la sede; 3 PI/min en el garaje) y **+2 PI/min por cada línea que está fabricando**. Avanza con 2×/3×, se detiene en pausa, no hay generación sin conexión y conserva los decimales. Ya no hay bonificación de PI por lote; las misiones siguen dando PI. |
| **Proyectos** | Hasta 6 a la vez. PI y dinero se cobran una sola vez, al empezar. Duran días de juego, no se cancelan, se guardan con su progreso y al terminar desbloquean para siempre (con aviso). |
| **Costo** | Depende de la complejidad (1 a 5: 10–450 PI, $5.000–300.000 escalados por época, 30–300 días). Las tecnologías viejas se abaratan (difusión). |
| **Adelanto** | Se puede investigar hasta 5 años antes. Cada año suma +15 % de dinero, +15 % de PI y +10 % de días; la tarjeta lo muestra antes de pagar. Con más de 5 años queda bloqueada. |
| **Chasis** | Sedán y Coupé 1970 de entrada. Se investigan: Compacto 1972, Pickup 1973, Sedán 1978 / 1988 y Coupé 1978 (cada uno con sus estadísticas). Las generaciones anteriores siguen disponibles. |
| **Motores** | 6 familias (I4, I6, V6, V8, I3 turbo, eléctrico) con 10 niveles. Cada nivel da +6 % de potencia y −3 % de consumo, pero el motor cuesta +7 %. Variantes: Equilibrada de entrada; Económica y Deportiva se investigan y valen para todos los motores a combustión. Los diseños guardados conservan su nivel y su variante. El modo de motor avanzado queda preparado (`RESEARCH_RULES.advancedEngineTuning = false`), sin interfaz. |
| **Seguridad y Tecnología** | Diez equipamientos (zonas de deformación, radio, aire acondicionado, ventanillas, dirección asistida, computadora, navegador, sensores, cámara y pantalla táctil). Nada se instala solo: se eligen en el paso 3 del editor. Cada uno suma su atributo y su costo por unidad, y cambia el atractivo y las reseñas. |
| **Personal (futuro)** | `Rules.researchModifiers` es el punto de enganche para las habilidades: conocimiento (menos PI), creatividad (menos días) y precisión (menos dinero). Hoy devuelve 1 y el personal no suma PI por minuto. |

**Datos:** esquema 8, con migración 7 → 8:
- La investigación en curso pasa a ser un proyecto con los días que le faltaban.
- Los diseños y lotes quedan con motor nivel 1 y variante equilibrada.
- Lo que antes venía instalado solo (zonas de deformación, aire, dirección asistida y computadora) queda como equipamiento elegido, así no cambian sus estadísticas.

## Pruebas

Todas pasan:
- `lune run tests/run.luau`: 8.656 comprobaciones.
  - La nueva **[E3]** recorre los 15 casos pedidos con sesiones reales, incluido guardar y cargar en otro servidor.
  - Otra prueba cubre la migración 7 → 8.
- `lune run tests/ui.luau`: 911 comprobaciones. Recorrido por la interfaz:
  - pestañas y tarjetas de Investigación;
  - dos proyectos simultáneos;
  - sección «Completadas»;
  - nivel y variante del motor, y equipamiento en el editor.
- `selene src tests`: sin avisos.
- `.rbxl` armado y verificado (`tests/verify_place.luau`).

**Ritmo (bot, provisional):** el optimizador completa las 123 tecnologías antes de 2030. Duración media por complejidad: 1,3 · 2,8 · 5,9 · 9,9 · 15 minutos.

## Cómo probar en Studio

1. Empresa nueva:
   - En Diseño solo están el Sedán y el Coupé 1970.
   - En Motor, I4 e I6 nivel 1, solo con la variante Equilibrada.
2. Investigación:
   - Cuatro pestañas y tarjetas de a 3, con nivel, estado, beneficio, costo (dinero · PI · días) y requisitos.
   - El panel PI muestra lo disponible, el centro y las líneas.
3. Esperar un minuto: los PI suben unos 3. Lanzar un lote: mientras fabrica, el panel muestra +2 por la línea.
4. Empezar dos investigaciones:
   - El dinero y los PI bajan una sola vez.
   - Avanzan juntas: más rápido a 3× y detenidas con un menú abierto.
5. Probar algo adelantado (por ejemplo, la variante Económica en 1970): la tarjeta muestra el recargo antes de pagar. Lo de más de 5 años aparece bloqueado.
6. Al terminar llega el aviso. En el editor:
   - el nivel o la variante nuevos se pueden elegir;
   - el equipamiento aparece en el paso 3, sin marcar.
   El diseño viejo sigue igual.
7. Compañía › «Guardar y volver al menú», reabrir: los proyectos siguen donde estaban.
