# Comparación con la V3 · pantalla por pantalla

Referencia principal: `reference/Car-Empire-Tycoon-V3.html`. Este documento se usa para trabajar y para
comprobar el resultado: cada elemento tiene su estado **antes** de esta etapa y **después** de implementarla.

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
| Indicaciones de proximidad («E Escritorio de diseño») | HTML sobre el canvas | `ProximityPrompt` con estilo propio dibujado igual (píldora clara con la tecla). |
| Mundo 3D de la sede | three.js | Garaje construido con Parts en el mundo de Roblox. |
| Fecha de la recompensa diaria | fecha del dispositivo | fecha UTC del servidor (no se puede adelantar el reloj del dispositivo). |
| Textos de dificultad | prometen «crisis», «rivales», «materiales caros» que la simulación no tiene | Se describen solo los efectos reales (corrección pedida en la revisión anterior). |

## 1. Menú de empresas (`renderMenu`)

| Elemento de la V3 | Antes | Después |
|---|---|---|
| Fondo: escena 3D con degradado horizontal oscuro | D (degradado vertical, sin escena visible a la derecha) | |
| Marca «CAR EMPIRE / TYCOON» con logo de borde violeta | D (texto en una línea, logo relleno) | |
| Título 3,4 rem «Construí tu imperio automotor» + subtítulo | D (otro subtítulo) | |
| Tarjeta de novedades (versión, título, texto, «Ver novedades») | D (solo texto) | |
| Franja «Próximo evento» con ícono de calendario | F | |
| «Demostraciones (no modifican tus partidas)»: Tutorial / Empresa en funcionamiento / Fábrica avanzada | F | |
| Encabezado «Tus empresas» + «N de 3 ranuras en uso» | D (sin contador) | |
| Ranura vacía: ícono punteado 56 px, «Nueva empresa», texto centrado, botón «Crear» | D (otro texto y botón «Crear empresa») | |
| Ranura ocupada: logo 56, nombre, «Sede · Ranura · Nivel», chip de tutorial | D (chips distintos) | |
| Grilla de 4 datos: fecha, dinero, tiempo jugado, última sesión | D (3 datos; falta tiempo jugado y última sesión) | |
| Acciones: Renombrar, Exportar, Eliminar (rojo) + «Continuar» con tecla Enter | D (Jugar/Continuar a la izquierda; sin Enter) | |
| Renombrar en línea con error debajo | D | |
| Eliminar: confirmación «¿Eliminar «X»?» con «Exportar antes» | D (pedía escribir el nombre) | |
| Ranuras 4 y 5 bloqueadas en dos columnas | D (una columna) | |
| «Importar partida (.json)» | X | |
| Botón «Configuración» abajo a la izquierda | D (junto al título) | |
| Pie «Prototipo local · sin conexión ni pagos reales» | A | |
| Diálogo de novedades | F | |

## 2. Nueva empresa (`renderNueva`)

| Elemento | Antes | Después |
|---|---|---|
| «‹ Volver a mis empresas» (botón sin borde) | D | |
| Título 2,9 rem «Fundá tu empresa» + texto | C | |
| Vista previa de la marca (logo 80, «VISTA PREVIA», nombre, dificultad y dinero) | D (proporciones) | |
| Tarjeta derecha: «Nueva empresa» + «Ranura N de 3» | D (orden de los campos) | |
| Nombre: etiqueta arriba, campo, validación debajo (✓/✕) | D (validación arriba del campo) | |
| Logotipo: 8 opciones cuadradas en una fila | D (íconos chicos) | |
| Color de marca: 9 muestras de 42 px + nombre | D (muestras sin color visible en la vista previa) | |
| Dificultad: 3 tarjetas con puntos ●●○ y dinero | D (puntos llenos, sin vacíos) | |
| Pie: «Podés renombrarla más adelante.» + Cancelar + «Comenzar mi empresa» con Enter | D (otro texto, sin Cancelar) | |

## 3. Sede · HUD y vista del juego (`renderHud`, `renderGameView`)

| Elemento | Antes | Después |
|---|---|---|
| Fila 1: marca (logo 30, nombre, sede · nivel), fecha, dinero, investigación, personal, reputación | D (orden y textos: «FECHA · hh:mm» arriba en la V3) | |
| Chip «DEMO · no se guarda · Salir» | F | |
| Chip «❚❚ Simulación en pausa» | F | |
| Velocidad ❚❚ 1× 2× 4× (pausa amarilla) | C | |
| Notificaciones con insignia roja | C | |
| Sonido (silenciar) | F (había «ayuda») | |
| Configuración (ícono de ajustes) | D (ícono distinto) | |
| Fila 2: Sede + 8 secciones con ícono de color, contador y tecla | D (contadores con otro estilo) | |
| «Más ▾» con Misiones, Estadísticas, Noticias del sector, Recompensa diaria, Tienda, Ayuda, Volver al menú | D (diálogo en lugar de menú emergente) | |
| Tarjeta Objetivo/Tutorial (primera, plegable, borde violeta en tutorial) | D (orden y botones) | |
| Tarjeta «Últimos 7 días de juego» (cuota de mercado, flujo con ▲) | D (faltan cuota y «Ver estadísticas») | |
| Alerta (detenida / listos / ofertas / laboratorio / agotado) | D | |
| Tarjeta Sede (nivel, barra de progreso, próxima sede) | F | |
| Panel derecho «En venta · N unidades» plegable con tarjetas (★, vendidos, ingresos, margen, stock, demanda) | D (otra tarjeta) | |
| «Ocultar paneles / Mostrar paneles» (Tab) | F | |
| Botón principal (CTA) con tecla | D | |
| Botones Amigos / Evento / Diaria (punto verde) | D | |
| Cinta de noticias con desplazamiento y botón para ocultar / «Mostrar noticias» | D (una sola noticia, sin ocultar) | |
| Globo del tutorial («Entendido», «Saltar tutorial») | F | |
| Indicaciones de proximidad y puntos para caminar | A | |
| Celular: «Menú», píldoras Objetivo / En venta / Alerta, paneles desplegables | D | |

## 4. Panel de gestión genérico (`renderSheet`)

| Elemento | Antes | Después |
|---|---|---|
| Encabezado: ícono, título, chips de la sección, ayuda (?) y «✕ Cerrar Esc» | D (chips junto al título; «Cerrar» sin texto) | |
| Columna principal + lateral de 400 px | C | |

## 5. Fábrica

| Elemento | Antes | Después |
|---|---|---|
| Chips: líneas, almacén, «Acelerada ×2» | C | |
| «+ Nueva orden de producción» + «Velocidad de las líneas ×n» | D (botones de aceleración/automática arriba) | |
| Líneas 1–4 (bloqueadas con «Se habilita con la sede…») | C | |
| Orden: arrastre, color, nombre, chip vN, × cantidad, chips de estado/versión nueva/automática | D | |
| Barra + texto en vivo «0/2 · unidad lista en … (≈ s reales)» | D | |
| «Unidad en curso: cobrado … materiales …» | D | |
| Nota roja con motivo y botón de solución | C | |
| Subir/bajar, Pausar, Prioridad (lista), Línea (lista), costo fijado, Cancelar | D (botones en lugar de listas) | |
| «Órdenes terminadas · repetir» | D | |
| Estaciones de montaje en grilla de 3 (abajo) | D (en la columna lateral) | |
| Lateral: Capacidad, Controles (automática, acelerar con interruptores), Materiales (+20), Tiempo | D | |

## 6. Mis autos e inventario

| Elemento | Antes | Después |
|---|---|---|
| Pestañas Vehículos / Piezas / Materiales / Diseños y plantillas (en ese orden) | D (orden) | |
| Búsqueda + filtros Estado / Tipo / Orden (listas) | D | |
| Fila de unidad: muestra de color 44×28, nombre, serie, datos, chip, «Detalle», acciones | D (miniatura 3D, otra distribución) | |
| Piezas, materiales y diseños | D | |
| Lateral: Capacidad (regla única) y Resumen | D (más datos) | |
| Detalle de unidad (diálogo) | D | |

## 7. Ventas y concesionario

| Elemento | Antes | Después |
|---|---|---|
| Pestañas Salón y clientes / Historial de ventas | D (pestaña extra «Movimientos») | |
| Clientes: ícono, nombre, «Busca … valora … interés … mira …», estado, paciencia en vivo | D | |
| Acciones de oferta: Negociar, Aceptar, Rechazar + precio de lista y margen | D | |
| En exhibición: precio de lista (campo), descuento (deslizador), precio final y margen, demanda | D (descuento por botones) | |
| En el almacén: enviar al salón y mayorista | F | |
| Historial: líneas con margen ▲/▼ | D | |
| Lateral: Promoción (interruptor), Últimos 7 días, Cómo deciden | D | |
| Negociación (diálogo) | D | |

## 8. Mercado global

| Elemento | Antes | Después |
|---|---|---|
| 7 pestañas, nota azul, búsqueda y filtros | C/D | |
| Tarjeta: franja de color con ícono y corazón, datos, chips, precio, «Ver publicación» | D | |
| Mis publicaciones / Ofertas recibidas | D | |
| Publicación y Publicar (diálogos) | D | |
| Sin columna lateral | D (había lateral) | |

## 9. Investigación

| Elemento | Antes | Después |
|---|---|---|
| Pestañas por categoría con «hechas/total» | C | |
| Columnas por nivel con tarjetas (estado, efecto, costo, requisitos, Investigar, motivo) | D | |
| Lateral: En curso, PI, Completadas | C | |

## 10. Personal

| Elemento | Antes | Después |
|---|---|---|
| Pestañas Equipo / Contratar | C | |
| Empleado: datos, estado, energía en vivo, Puesto (lista con ★ y completo), descanso, despedir | D (asignación distinta) | |
| Candidatos y «Buscar más candidatos · $1.000» | D | |
| Lateral: Áreas y efecto actual | D | |

## 11. Compañía

| Elemento | Antes | Después |
|---|---|---|
| Marca: logo 72, nombre editable, logotipo, color | D | |
| Sede y capacidad, próxima sede con requisitos y «Ampliar sede» | D | |
| Lateral: Resumen de la empresa, Datos (volver al menú) | D | |

## 12. Misiones

| Elemento | Antes | Después |
|---|---|---|
| Pestañas Tutorial / Historia / Diarias / Eventos con contador | C | |
| Tarjetas con estado, barra, recompensa y Reclamar/Ir | D | |
| Eventos: tarjeta «Semana de los eléctricos» con botón deshabilitado | D | |
| Lateral: Recompensa diaria y Cómo funcionan | C | |

## 13. Estadísticas y finanzas

| Elemento | Antes | Después |
|---|---|---|
| Selector 7/14/30 días | C | |
| 8 indicadores (incluye cuota de mercado estimada) | D (flujo de caja/producidas en lugar de cuota) | |
| Gráfico por día | C | |
| Ventas por modelo con margen medio | D | |
| Lateral: Gastos del período, Últimos movimientos | D | |

## 14. Editor

| Elemento | Antes | Después |
|---|---|---|
| Barra superior: «Diseñar un auto», subtítulo, dinero, Deshacer/Rehacer con teclas, «Modelos anteriores», «Volver a la empresa Esc» | D | |
| Herramientas a la izquierda: Cámara (7 vistas con tecla), −/+/restablecer, costos, ayuda | D (botones arriba) | |
| Tarjeta de estadísticas (pasos 2 y 3) con vista previa de la pieza | C | |
| Pasos abajo al centro + barra de herramientas (deshacer, rehacer, restablecer, captura, antes/después, ocultar interfaz H) | D | |
| Panel derecho 440 px: encabezado (paso, ayuda, cerrar, título, nombre, estado, progreso) | D (superposiciones) | |
| Paso 1: nombre, marca, generación, chasis, segmento (listas), objetivo, calidad (deslizador), filtro por tipo, tarjetas de base | D | |
| Paso 2: categorías 4 columnas, lista de piezas, comparación, «Instalar en el prototipo» | D | |
| Paso 3: Exterior/Interior, pintura (selector SV, tono, HEX, muestras, intensidad, brillo, acabado), ruedas, carrocería, matrícula | D | |
| Paso 4: resumen, economía, desarrollo, estadísticas, piezas, advertencias, acciones | D | |
| Pie: desarrollo pendiente, fabricación, dinero, Volver/Siguiente con teclas [ ] | D | |
| Antes/después con divisor y etiquetas | D | |
| Ocultar interfaz (H) | F | |
| Puntos sobre el auto | D | |
| Diálogos: cambios sin guardar, modelos anteriores, prueba en pista | D | |

## 15. Diálogos generales

| Diálogo | Antes | Después |
|---|---|---|
| Configuración (Accesibilidad / Juego / Datos con filas) | D | |
| Notificaciones (chip por tipo, día y hora) | D | |
| Ayuda por sección (confirmación con «Entendido») | D | |
| Recompensa diaria (7 días, racha) | D | |
| Nueva orden (modelo, cantidad, línea, prioridad, costos, materiales, notas) | D | |
| Confirmaciones (mayorista, reciclar, cancelar orden, comprar materiales, ampliar, despedir, eliminar) | D | |
| Tienda / Amigos / Evento | D | |
| Saltar tutorial | D | |

## 16. Celular

| Elemento | Antes | Después |
|---|---|---|
| HUD de una fila con «Menú» y menú en grilla de 2 columnas | D | |
| Paneles a pantalla completa, columnas apiladas | C | |
| Editor: panel inferior (vertical) o lateral (horizontal), herramientas y estadísticas desplegables | D | |
