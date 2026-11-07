# Etapa 1 · base del juego (calendario, pausa, economía, empresas y guardado)

Se trabajó sobre el proyecto existente: se reutilizaron las sesiones, el guardado, la simulación, la
economía y la interfaz; solo se cambió lo necesario.

## Auditoría (resumen)

| Estado | Qué |
|---|---|
| **Funcional y reutilizado** | **Sesiones** (`Sessions`). **Guardado** (`DataService`): DataStore con candado entre servidores, reintentos, autoguardado, guardado al salir y al cerrar el servidor, ranuras dañadas que no se pisan, esquema versionado con migraciones. **Validación estricta** de la partida (`GameState`). **Reloj único** (`Simulation.simulate`, desde `Sessions:tick`). **Economía de servidor** (`Simulation.spend/earn` con registro; el cliente solo pide acciones validadas). **Producción, ventas, investigación, personal y sedes**. **Interfaz completa**. **Pruebas** con Lune y un Roblox simulado. |
| **Necesitaba correcciones** | El calendario avanzaba por meses fijos de 55 s, sin días. Las velocidades eran 1×/2×/4×. No había pausa por menú. Había 3 ranuras libres, sin identificador de empresa y sin deudas. No había guardado manual, y volver al menú no guardaba en el momento. |
| **No implementado (para etapas siguientes)** | Investigación en cuatro categorías con varios proyectos a la vez (hoy hay 7 ramas y uno activo). Cuatro departamentos de personal con capacitaciones (hoy hay estaciones y departamentos). Préstamos (la estructura existe, pero ninguna acción los crea). Críticos especializados. Instalaciones como edificios mejorables (hoy: sede y estaciones). Desbloqueo de las ranuras 3 y 4. |
| **Riesgos** | Pasar a días hace que el año dure 12,2 min en vez de 11; el equilibrio se movió poco (el bot llega a las mismas sedes). La pausa por menú hace que el juego solo avance con la vista de la sede abierta: es lo pedido, pero cambia el ritmo percibido. Nada de esto se probó en Roblox Studio. |

## Qué quedó implementado

- **Calendario:**
  - un día cada 2 s reales a 1×, con meses reales (28 a 31 días) y años bisiestos;
  - fecha visible `dd/mm/aaaa` en el HUD y en Compañía; empieza el 01/01/1970;
  - velocidades 1×, 2× y 3× (y pausa manual); no hay avance instantáneo.
- **Pausa individual:**
  - con un panel de gestión o un diálogo abiertos, el cliente avisa (`setUiPause`) y el servidor deja de simular esa sesión: calendario, fábrica, ventas, investigación, campañas y salarios;
  - las demás empresas del servidor siguen;
  - el HUD dice «EN PAUSA (MENÚ)»;
  - al volver al menú de empresas, la pausa se quita.
- **Empresas:**
  - 4 ranuras: 1 y 2 libres; 3 y 4 bloqueadas, sin botón de compra ni precio;
  - una cuenta que ya tenía empresa en la ranura 3 la conserva habilitada;
  - cada empresa tiene un identificador estable (`company.id`) y deudas (`loans`, `Rules.debt`).
- **Economía:** `Simulation.canAfford`, además de `spend`, que rechaza gastos sin fondos, y `earn`; todo queda registrado. El cliente no puede cambiar el dinero; está probado con acciones y campos falsos.
- **Guardado:**
  - «Guardar ahora» y «Guardar y volver al menú» en Compañía › Datos, sin salir del servidor;
  - respeta el intervalo mínimo del DataStore: si se acaba de guardar, el guardado queda programado para unos segundos después;
  - esquema 6, con migración 5 → 6: conserva la fecha (misma fracción del mes), pasa 4× a 3×, crea el identificador y las deudas.

## Pruebas automáticas

Todas sin fallas; no son pruebas en Studio.
- `lune run tests/run.luau`: 1.342 comprobaciones, con los bloques nuevos [E1]: calendario, pausa con dos jugadores, economía, guardado/volver/recargar sin progreso desconectado, ranuras y migración.
- `lune run tests/ui.luau`: 718 comprobaciones. El recorrido por la interfaz ahora verifica la pausa con el panel de Producción y con un diálogo, «Guardar ahora», «Guardar y volver», las ranuras bloqueadas y la fecha 01/01/1970.
- `selene src tests`: sin avisos. `tests/verify_place.luau`: el `.rbxl` coincide con las fuentes.

## Cómo probarlo en Studio

1. Abrir `CarEmpireTycoon.rbxl`. Para guardar de verdad: *Enable Studio Access to API Services*.
2. Crear una empresa:
   - el HUD muestra `01/01/1970`;
   - con un cronómetro, a 1× la fecha cambia cada 2 s; a 2× y 3×, el doble y el triple.
3. Abrir Producción (o cualquier panel, o Configuración): la fecha se congela y el HUD dice «EN PAUSA (MENÚ)». Cerrar: sigue.
4. Con *Test › Clients and Servers* (2 jugadores): abrir un panel en uno; la fecha del otro sigue avanzando.
5. Compañía › Datos:
   - «Guardar ahora» muestra «Partida guardada»;
   - «Guardar y volver al menú» vuelve a la lista de empresas sin salir del servidor;
   - al reabrir la empresa, la fecha es la misma.
6. En el menú: ranuras 3 y 4 «bloqueadas», sin compra.
7. Salir, esperar unos minutos y volver a entrar: la fecha y el dinero son los mismos.
