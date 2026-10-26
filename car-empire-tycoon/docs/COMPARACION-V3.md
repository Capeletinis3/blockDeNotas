# Comparación con la V3 · pantalla por pantalla

Referencia principal: `reference/Car-Empire-Tycoon-V3.html`. Este documento se usa para trabajar y para
comprobar el resultado: cada elemento tiene su estado **antes** de esta etapa y **después** de implementarla.

Estado al cierre de esta etapa: las 75 escenas de escritorio (1600×900) y 12 de celular (844×390 y 390×844)
se compararon contra la V3; la columna **Después** resume el resultado. Lo que todavía difiere está en la
sección «Diferencias que quedan», al final.

Estados: **C** completo (igual a la V3) · **D** diferente (existe pero no se ve o no funciona como la V3) ·
**F** falta · **A** adaptación de Roblox documentada (no se puede igual; se reemplaza por algo equivalente) ·
**X** no corresponde en Roblox (función del prototipo web, no del juego).

## Cómo se compara

- `node tools/preview/v3.js` captura la V3 con escenas con nombre (azar con semilla fija).
- `lune run tests/preview.luau` ejecuta el servidor y el cliente reales sobre el entorno Roblox simulado,
  lleva la partida al mismo estado y vuelca el árbol de interfaz; `node tools/preview/render.js` lo dibuja
  con una emulación del diseño de Roblox (UDim2, AutomaticSize, UIListLayout, UIFlexItem, UIGridLayout,
  UIPadding, UICorner, UIStroke, UIGradient, ScrollingFrame, RichText…).
- `node tools/preview/compare.js` arma la imagen V3 arriba / Roblox abajo de cada escena.

Límites de la vista previa (no reemplaza a Studio): usa la fuente Inter en lugar de Builder Sans, no
dibuja el mundo 3D ni los ViewportFrame (se ven como un recuadro «3D»), no mide como el motor de Roblox
en casos límite y no prueba toques, foco del teclado en pantalla ni rendimiento.

## Adaptaciones de Roblox (válidas para todas las pantallas)

| Tema | V3 | Roblox |
|---|---|---|
| Fuente | Inter (incrustada) | Builder Sans (familia incluida en Roblox con todos los pesos). Inter no es una familia incluida. |
| Sombras (`box-shadow`) y desenfoque de fondo | CSS | No existen en la interfaz nativa: se usan fondos un poco más opacos y bordes. |
| Bordes punteados (`dashed`) | CSS | `UIStroke` no tiene trazos punteados: borde liso más tenue. |
| Espaciado entre letras (`letter-spacing`) | CSS | No existe en `TextLabel`: «CAR EMPIRE / TYCOON» usa espacios finos; las etiquetas en mayúsculas quedan sin espaciado extra. |
| `<select>` | nativo del navegador | Botón con flecha que abre una lista desplegable propia (misma información y opciones). |
| `<input type=range>` | nativo | Deslizador propio (pista + perilla) con arrastre y toques. |
| Tooltips (`title`) | al pasar el mouse | El motivo de un botón deshabilitado se muestra al tocarlo (aviso) y con el texto «.why» donde la V3 lo muestra. |
| Guardado | `localStorage` + exportar/importar JSON | DataStore de Roblox con candado de sesión. No hay exportar/importar (pedido explícito): esos botones no se muestran. |
| «Índice del prototipo» y su opción en Configuración | herramienta del visor | X: no forma parte del juego. |
| Indicaciones de proximidad («E Escritorio de diseño») | HTML sobre el canvas | `ProximityPrompt` con estilo `Custom`: la píldora clara con la tecla y los puntos (.dot3d) se dibujan con `BillboardGui` (WorldPrompts.luau); tocar un punto hace caminar al personaje. |
| Vista 3D del editor | lienzo three.js de pantalla completa | `ViewportFrame` centrado en el hueco libre y más grande que la pantalla: el auto queda encuadrado entre los paneles como en la V3 y el piso sigue detrás. Antes/después recorta una segunda vista con el divisor. |
| «Captura» del editor | descarga un PNG | Roblox no deja guardar imágenes desde un script: «Captura» oculta la interfaz y los avisos 5 s (modo foto) para usar la captura de Roblox o del dispositivo. |
| Mundo 3D de la sede | three.js | Garaje construido con Parts en el mundo de Roblox. |
| Fecha de la recompensa diaria | fecha del dispositivo | fecha UTC del servidor (no se puede adelantar el reloj del dispositivo). |
| Textos de dificultad | prometen «crisis», «rivales», «materiales caros» que la simulación no tiene | Se describen solo los efectos reales (corrección pedida en la revisión anterior). |

## 1. Menú de empresas (`renderMenu`)

| Elemento de la V3 | Antes | Después |
|---|---|---|
| Fondo: escena 3D con degradado horizontal oscuro | D (degradado vertical, sin escena visible a la derecha) || A (degradado oscuro igual; detrás se ve el mundo de Roblox, sin cámara dedicada al garaje) |
| Marca «CAR EMPIRE / TYCOON» con logo de borde violeta | D (texto en una línea, logo relleno) || C |
| Título 3,4 rem «Construí tu imperio automotor» + subtítulo | D (otro subtítulo) || C |
| Tarjeta de novedades (versión, título, texto, «Ver novedades») | D (solo texto) || C |
| Franja «Próximo evento» con ícono de calendario | F || C |
| «Demostraciones (no modifican tus partidas)»: Tutorial / Empresa en funcionamiento / Fábrica avanzada | F || C |
| Encabezado «Tus empresas» + «N de 3 ranuras en uso» | D (sin contador) || C |
| Ranura vacía: ícono punteado 56 px, «Nueva empresa», texto centrado, botón «Crear» | D (otro texto y botón «Crear empresa») || C |
| Ranura ocupada: logo 56, nombre, «Sede · Ranura · Nivel», chip de tutorial | D (chips distintos) || C |
| Grilla de 4 datos: fecha, dinero, tiempo jugado, última sesión | D (3 datos; falta tiempo jugado y última sesión) || C |
| Acciones: Renombrar, Exportar, Eliminar (rojo) + «Continuar» con tecla Enter | D (Jugar/Continuar a la izquierda; sin Enter) || A (Renombrar y Eliminar; sin Exportar). Continuar con Enter |
| Renombrar en línea con error debajo | D || C |
| Eliminar: confirmación «¿Eliminar «X»?» con «Exportar antes» | D (pedía escribir el nombre) || A (sin «Exportar antes») |
| Ranuras 4 y 5 bloqueadas en dos columnas | D (una columna) || C |
| «Importar partida (.json)» | X || X |
| Botón «Configuración» abajo a la izquierda | D (junto al título) || C |
| Pie «Prototipo local · sin conexión ni pagos reales» | A || A (texto: se guarda en tu cuenta de Roblox) |
| Diálogo de novedades | F || C |

## 2. Nueva empresa (`renderNueva`)

| Elemento | Antes | Después |
|---|---|---|
| «‹ Volver a mis empresas» (botón sin borde) | D || C |
| Título 2,9 rem «Fundá tu empresa» + texto | C || C |
| Vista previa de la marca (logo 80, «VISTA PREVIA», nombre, dificultad y dinero) | D (proporciones) || C |
| Tarjeta derecha: «Nueva empresa» + «Ranura N de 3» | D (orden de los campos) || C |
| Nombre: etiqueta arriba, campo, validación debajo (✓/✕) | D (validación arriba del campo) || C |
| Logotipo: 8 opciones cuadradas en una fila | D (íconos chicos) || C |
| Color de marca: 9 muestras de 42 px + nombre | D (muestras sin color visible en la vista previa) || C |
| Dificultad: 3 tarjetas con puntos ●●○ y dinero | D (puntos llenos, sin vacíos) || A (textos honestos de dificultad: solo efectos reales) |
| Pie: «Podés renombrarla más adelante.» + Cancelar + «Comenzar mi empresa» con Enter | D (otro texto, sin Cancelar) || C |

## 3. Sede · HUD y vista del juego (`renderHud`, `renderGameView`)

| Elemento | Antes | Después |
|---|---|---|
| Fila 1: marca (logo 30, nombre, sede · nivel), fecha, dinero, investigación, personal, reputación | D (orden y textos: «FECHA · hh:mm» arriba en la V3) || C |
| Chip «DEMO · no se guarda · Salir» | F || C |
| Chip «❚❚ Simulación en pausa» | F || C |
| Velocidad ❚❚ 1× 2× 4× (pausa amarilla) | C || C |
| Notificaciones con insignia roja | C || C |
| Sonido (silenciar) | F (había «ayuda») || C |
| Configuración (ícono de ajustes) | D (ícono distinto) || C |
| Fila 2: Sede + 8 secciones con ícono de color, contador y tecla | D (contadores con otro estilo) || C |
| «Más ▾» con Misiones, Estadísticas, Noticias del sector, Recompensa diaria, Tienda, Ayuda, Volver al menú | D (diálogo en lugar de menú emergente) || C |
| Tarjeta Objetivo/Tutorial (primera, plegable, borde violeta en tutorial) | D (orden y botones) || C |
| Tarjeta «Últimos 7 días de juego» (cuota de mercado, flujo con ▲) | D (faltan cuota y «Ver estadísticas») || C |
| Alerta (detenida / listos / ofertas / laboratorio / agotado) | D || C |
| Tarjeta Sede (nivel, barra de progreso, próxima sede) | F || C |
| Panel derecho «En venta · N unidades» plegable con tarjetas (★, vendidos, ingresos, margen, stock, demanda) | D (otra tarjeta) || C |
| «Ocultar paneles / Mostrar paneles» (Tab) | F || C |
| Botón principal (CTA) con tecla | D || C |
| Botones Amigos / Evento / Diaria (punto verde) | D || C |
| Cinta de noticias con desplazamiento y botón para ocultar / «Mostrar noticias» | D (una sola noticia, sin ocultar) || C |
| Globo del tutorial («Entendido», «Saltar tutorial») | F || C |
| Indicaciones de proximidad y puntos para caminar | A || A (píldora «E …» y puntos con el aspecto de la V3 sobre ProximityPrompt; tocar un punto camina hasta el objeto. Sin verificar en Studio) |
| Celular: «Menú», píldoras Objetivo / En venta / Alerta, paneles desplegables | D || C |

## 4. Panel de gestión genérico (`renderSheet`)

| Elemento | Antes | Después |
|---|---|---|
| Encabezado: ícono, título, chips de la sección, ayuda (?) y «✕ Cerrar Esc» | D (chips junto al título; «Cerrar» sin texto) || C |
| Columna principal + lateral de 400 px | C || C |

## 5. Fábrica

| Elemento | Antes | Después |
|---|---|---|
| Chips: líneas, almacén, «Acelerada ×2» | C || C |
| «+ Nueva orden de producción» + «Velocidad de las líneas ×n» | D (botones de aceleración/automática arriba) || C |
| Líneas 1–4 (bloqueadas con «Se habilita con la sede…») | C || C |
| Orden: arrastre, color, nombre, chip vN, × cantidad, chips de estado/versión nueva/automática | D || C |
| Barra + texto en vivo «0/2 · unidad lista en … (≈ s reales)» | D || C (texto en vivo) |
| «Unidad en curso: cobrado … materiales …» | D || C |
| Nota roja con motivo y botón de solución | C || C |
| Subir/bajar, Pausar, Prioridad (lista), Línea (lista), costo fijado, Cancelar | D (botones en lugar de listas) || C (listas desplegables) |
| «Órdenes terminadas · repetir» | D || C |
| Estaciones de montaje en grilla de 3 (abajo) | D (en la columna lateral) || C |
| Lateral: Capacidad, Controles (automática, acelerar con interruptores), Materiales (+20), Tiempo | D || C |

## 6. Mis autos e inventario

| Elemento | Antes | Después |
|---|---|---|
| Pestañas Vehículos / Piezas / Materiales / Diseños y plantillas (en ese orden) | D (orden) || C |
| Búsqueda + filtros Estado / Tipo / Orden (listas) | D || C |
| Fila de unidad: muestra de color 44×28, nombre, serie, datos, chip, «Detalle», acciones | D (miniatura 3D, otra distribución) || C (muestra de color, sin miniatura 3D) |
| Piezas, materiales y diseños | D || C |
| Lateral: Capacidad (regla única) y Resumen | D (más datos) || C |
| Detalle de unidad (diálogo) | D || C (sin vista 3D, como la V3) |

## 7. Ventas y concesionario

| Elemento | Antes | Después |
|---|---|---|
| Pestañas Salón y clientes / Historial de ventas | D (pestaña extra «Movimientos») || C (sin «Movimientos») |
| Clientes: ícono, nombre, «Busca … valora … interés … mira …», estado, paciencia en vivo | D || C |
| Acciones de oferta: Negociar, Aceptar, Rechazar + precio de lista y margen | D || C |
| En exhibición: precio de lista (campo), descuento (deslizador), precio final y margen, demanda | D (descuento por botones) || C (deslizador) |
| En el almacén: enviar al salón y mayorista | F || C |
| Historial: líneas con margen ▲/▼ | D || C (cada línea abre el detalle: agregado) |
| Lateral: Promoción (interruptor), Últimos 7 días, Cómo deciden | D || C (la promoción requiere investigar «Promociones»: corrección) |
| Negociación (diálogo) | D || C (probabilidad calculada por el servidor, sin detalles de la tirada) |

## 8. Mercado global

| Elemento | Antes | Después |
|---|---|---|
| 7 pestañas, nota azul, búsqueda y filtros | C/D || C |
| Tarjeta: franja de color con ícono y corazón, datos, chips, precio, «Ver publicación» | D || C |
| Mis publicaciones / Ofertas recibidas | D || C |
| Publicación y Publicar (diálogos) | D || C |
| Sin columna lateral | D (había lateral) || C |

## 9. Investigación

| Elemento | Antes | Después |
|---|---|---|
| Pestañas por categoría con «hechas/total» | C || C |
| Columnas por nivel con tarjetas (estado, efecto, costo, requisitos, Investigar, motivo) | D || C |
| Lateral: En curso, PI, Completadas | C || C |

## 10. Personal

| Elemento | Antes | Después |
|---|---|---|
| Pestañas Equipo / Contratar | C || C |
| Empleado: datos, estado, energía en vivo, Puesto (lista con ★ y completo), descanso, despedir | D (asignación distinta) || C |
| Candidatos y «Buscar más candidatos · $1.000» | D || C |
| Lateral: Áreas y efecto actual | D || C |

## 11. Compañía

| Elemento | Antes | Después |
|---|---|---|
| Marca: logo 72, nombre editable, logotipo, color | D || C |
| Sede y capacidad, próxima sede con requisitos y «Ampliar sede» | D || C |
| Lateral: Resumen de la empresa, Datos (volver al menú) | D || A (Datos: sin exportar; «Volver al menú de empresas») |

## 12. Misiones

| Elemento | Antes | Después |
|---|---|---|
| Pestañas Tutorial / Historia / Diarias / Eventos con contador | C || C |
| Tarjetas con estado, barra, recompensa y Reclamar/Ir | D || C |
| Eventos: tarjeta «Semana de los eléctricos» con botón deshabilitado | D || C |
| Lateral: Recompensa diaria y Cómo funcionan | C || C (fecha UTC del servidor) |

## 13. Estadísticas y finanzas

| Elemento | Antes | Después |
|---|---|---|
| Selector 7/14/30 días | C || C |
| 8 indicadores (incluye cuota de mercado estimada) | D (flujo de caja/producidas en lugar de cuota) || C |
| Gráfico por día | C || C |
| Ventas por modelo con margen medio | D || C |
| Lateral: Gastos del período, Últimos movimientos | D || C (cifras desde agregados diarios: no se recortan con el historial) |

## 14. Editor

| Elemento | Antes | Después |
|---|---|---|
| Barra superior: «Diseñar un auto», subtítulo, dinero, Deshacer/Rehacer con teclas, «Modelos anteriores», «Volver a la empresa Esc» | D || C |
| Herramientas a la izquierda: Cámara (7 vistas con tecla), −/+/restablecer, costos, ayuda | D (botones arriba) || C |
| Tarjeta de estadísticas (pasos 2 y 3) con vista previa de la pieza | C || C |
| Pasos abajo al centro + barra de herramientas (deshacer, rehacer, restablecer, captura, antes/después, ocultar interfaz H) | D || C (Captura: ver adaptaciones) |
| Panel derecho 440 px: encabezado (paso, ayuda, cerrar, título, nombre, estado, progreso) | D (superposiciones) || C (380 px en tableta) |
| Paso 1: nombre, marca, generación, chasis, segmento (listas), objetivo, calidad (deslizador), filtro por tipo, tarjetas de base | D || C |
| Paso 2: categorías 4 columnas, lista de piezas, comparación, «Instalar en el prototipo» | D || C |
| Paso 3: Exterior/Interior, pintura (selector SV, tono, HEX, muestras, intensidad, brillo, acabado), ruedas, carrocería, matrícula | D || C (pestañas Exterior/Interior visibles: en la V3 no se ven) |
| Paso 4: resumen, economía, desarrollo, estadísticas, piezas, advertencias, acciones | D || C |
| Pie: desarrollo pendiente, fabricación, dinero, Volver/Siguiente con teclas [ ] | D || C |
| Antes/después con divisor y etiquetas | D || C |
| Ocultar interfaz (H) | F || C |
| Puntos sobre el auto | D || C (solo dentro del encuadre) |
| Diálogos: cambios sin guardar, modelos anteriores, prueba en pista | D || C |

## 15. Diálogos generales

| Diálogo | Antes | Después |
|---|---|---|
| Configuración (Accesibilidad / Juego / Datos con filas) | D || A (sin «Índice del prototipo» ni Exportar/Importar; agrega «Borrar todos los datos») |
| Notificaciones (chip por tipo, día y hora) | D || C |
| Ayuda por sección (confirmación con «Entendido») | D || C |
| Recompensa diaria (7 días, racha) | D || C |
| Nueva orden (modelo, cantidad, línea, prioridad, costos, materiales, notas) | D || C |
| Confirmaciones (mayorista, reciclar, cancelar orden, comprar materiales, ampliar, despedir, eliminar) | D || C |
| Tienda / Amigos / Evento | D || C |
| Saltar tutorial | D || C |

## 16. Celular

| Elemento | Antes | Después |
|---|---|---|
| HUD de una fila con «Menú» y menú en grilla de 2 columnas | D || C (844×390 y 390×844) |
| Paneles a pantalla completa, columnas apiladas | C || C |
| Editor: panel inferior (vertical) o lateral (horizontal), herramientas y estadísticas desplegables | D || C (sin verificar el 3D en un teléfono real) |


## Diferencias que quedan

Comparadas en la vista previa (no en Studio). Ninguna cambia mecánicas ni costos.

1. **Mundo 3D de la sede.** El garaje de Roblox (Parts) tiene la misma distribución funcional (escritorio,
   línea, almacén, salón y puntos de interacción), pero no está modelado pieza por pieza como la escena
   three.js de la V3 (luces, cartel «VORTEX MOTORS», personas de colores). No hay cámara fija del menú sobre
   el garaje: detrás del menú se ve el mundo con la cámara del jugador.
2. **Fuente.** Builder Sans en lugar de Inter: los textos ocupan casi lo mismo, pero algunas líneas largas
   cortan en otro lugar.
3. **Sombras, desenfoque, bordes punteados y espaciado entre letras** no existen en la interfaz nativa (ver
   adaptaciones).
4. **Modelo del auto en el editor.** Se dibuja con Parts en un `ViewportFrame`: misma silueta por tipo,
   pintura, llantas, alerón e interior, pero con menos detalle y sin reflejos ni la luz de estudio de la V3.
5. **Captura** (modo foto en lugar de descargar un PNG), **Exportar/Importar** (no existen) e **Índice del
   prototipo** (no corresponde).
6. **Pestañas Exterior/Interior del editor** visibles en Roblox; en la V3 están en el código pero no se ven.
7. **Datos de las demostraciones.** Los clientes, publicaciones del mercado y ventas generadas son
   aleatorios: los nombres y montos no coinciden con las capturas de la V3, la distribución sí.
8. **Sin verificar en Studio:** medidas exactas con Builder Sans, toques en celular, `BillboardGui` de las
   indicaciones, encuadre del `ViewportFrame`, rendimiento y DataStore real. Ver «Pruebas pendientes en
   Studio» en el README.
