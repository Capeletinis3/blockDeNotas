# Actualización integral · progreso

Respaldo: tag git `respaldo-pre-integral` (commit b518f2d, Etapa 3) y copia del `.rbxl` anterior.
El proyecto se edita como código (Rojo); el `.rbxl` se arma con `rojo build place.project.json`.

## Auditoría (fase 1)

| Sistema | Estado encontrado | Acción |
|---|---|---|
| Empresas / ranuras | 4 ranuras (2 gratis, 3-4 bloqueadas sin compra). Nombre obligatorio; color y logo con valores por defecto. **Dificultad** cambia dinero (150k/90k/65k) y demanda (±15 %). | Quitar dificultad (todas iguales), identidad obligatoria, compra de ranuras con Developer Product. |
| Calendario | 2 s/día a 1×, 2×, 3×, pausa por empresa al abrir menús, sin progreso offline, reloj único `Simulation.simulate`. | Cumple. Conectar capacitaciones, campañas y obras al mismo reloj. |
| Personal | Roles (Mecánico, Ingeniero…), una sola «skill», costo de contratación, asignación a estaciones y 4 departamentos viejos (Laboratorio, Ventas, Marketing, Diseño). Despido sin indemnización. Salarios impagos bajan reputación. | Rehacer: 4 departamentos, 3 habilidades c/u, potencial, límites por beneficio, adaptación, deuda salarial con 30 % de las ventas, indemnización. |
| Mercado laboral | Candidatos que se acumulan (hasta 12), 2 por mes, búsqueda fija de $1.000. | 8 por mes que reemplazan, búsqueda general/especializada con precio creciente. |
| Capacitaciones | No existen. | Implementar. |
| Marketing | 3 niveles fijos con cobro mensual, atados a investigaciones. | Campaña de modelo/corporativa con presupuesto, duración, pago al inicio, cancelable. |
| Instalaciones | «Sede» de 5 niveles que da todo junto (líneas 1-5, capacidad, alcance, PI, personal). Estaciones de fábrica. Mejoras instantáneas. Expansión por regiones. | Separar oficinas / fábrica / centro de I+D, líneas 1 gratis · 2 dinero · 3 Robux, obras con duración, expansión por países. |
| Investigación | 4 categorías + «Empresa (provisorio)». | Pasar producción a la fábrica y marketing a campañas; quitar la pestaña. |
| Diseño, lotes, reseñas, ventas | Cumplen (Etapa 2-3). | Conectar bonificaciones de personal, campañas y deuda salarial. |
| Guardado | Esquema 8 con migraciones versionadas, validación completa y perfil con `processed`/`unlocked`. | Esquema 9 con migración de empleados, campañas, instalaciones y dificultad. |
| Interfaz | Menú de ranuras, HUD con barra de navegación, pantallas por sección. Avisos de proximidad en el mundo (`WorldPrompts`). | Ajustar Personal, Marketing, Instalaciones y Ajustes; revisar lo demás. |

## Fases

- [x] 1. Auditoría y respaldo
- [x] 2. Sistemas fundamentales
  - Sin dificultades: todas las empresas empiezan con $90.000 y la misma demanda (`Catalog.START`). Migración 8 → 9 (se quita el campo; el dinero se conserva).
  - Nombre, símbolo y color obligatorios en el servidor (la pantalla propone valores editables).
  - Ranuras 3 y 4: compra individual con Developer Product (`Catalog.PRODUCTS`, id 0 = sin configurar, botón deshabilitado). `Sessions.processReceipt` acredita solo después de guardar y no duplica recibos (`profile.receipts`).
  - Calendario, velocidades y pausa por empresa: ya cumplían (pruebas [E1]).
- [x] 3. Personal (`src/shared/Staff.luau`, valores en `Catalog.STAFF`)
  - 4 departamentos × 3 habilidades, cada beneficio con su tope; potencial individual; aportes y vista previa de contratación con topes.
  - Efectos: velocidad (líneas, en vivo), calidad (puntos al terminar el lote), eficiencia (costo de lotes nuevos), conocimiento/precisión (PI y dinero al empezar), creatividad (avance en vivo), marketing y administración se conectan en fases 5-6.
  - Transferencias con adaptación (50 % → 100 % en 180 días), habilidades conservadas.
  - Sueldos al empezar el mes, deuda salarial, productividad que baja, 30 % de las ventas a la deuda; indemnización salario × años.
  - 8 candidatos por mes, búsqueda general/especializada (+50 % por búsqueda, contador compartido); sin costo de contratación.
  - Esquema 10: migración de empleados viejos (rol → departamento, habilidad y salario conservados).
- [x] 4. Capacitaciones (`Catalog.TRAINING`, `Staff.trainingPlan`)
  - Individual, por departamento y general; básico desde el inicio, intermedio y avanzado con oficinas nivel 2 y 3.
  - Costo, días y resultado de cada participante visibles antes de pagar (mismo cálculo en servidor); sin azar; tope = potencial.
  - Varias a la vez, una por empleado; productividad 80 % mientras dura; avanza con el reloj único. Esquema 11.
- [x] 5. Marketing (`Catalog.MARKETING`, `Rules.campaignPlan`)
  - Campaña de modelo (un auto) o corporativa (todos los modelos en venta + reputación; más cara según tamaño y modelos en venta).
  - Presupuesto mensual y duración elegibles; efecto con rendimientos decrecientes; costo y efecto calculados en el servidor.
  - Una activa, pago al inicio, avanza con el calendario, cancelable sin reembolso. Personal: creatividad (efecto), análisis (costo), comunicación (duración).
  - Esquema 12: la campaña por niveles activa sigue como corporativa por el resto del mes ya pagado.
- [x] 6. Instalaciones (`Catalog.SEDES`, `Catalog.FACILITIES`, Compañía › Instalaciones)
  - Oficinas centrales (g.sede): límite global de empleados, alcance, niveles de capacitación, expansión internacional.
  - Fábrica (autos/min por línea, edificio del garaje) y centro de investigación (PI/min) separados; no superan a las oficinas.
  - Mejoras = obras pagadas al inicio con duración (organización las acelera, gestión las abarata); mantenimiento mensual sobre lo invertido (finanzas lo baja).
  - Líneas: 1 gratis, 2 con dinero (obra), 3 con Robux (Developer Product, independiente de la 2). Ninguna mejora da líneas.
  - Expansión internacional por países reales (sin mapa definitivo todavía).
  - Esquema 13: la sede vieja se reparte en oficinas/fábrica/centro del mismo nivel; quien tenía 2 o 3+ líneas las conserva.
- [x] 7. Investigación: exactamente 4 categorías. Producción (velocidad, calidad, costo, acabados premium) pasó a los niveles de la fábrica; marketing a campañas y oficinas. Esquema 14: esos ids salen de lo investigado y un proyecto en curso se reintegra (dinero y PI).
- [x] 8. Ciclo automotriz: diseño con especificaciones fijas, un lote por modelo, reseñas guardadas, ventas con campaña, stock y deuda salarial (prueba [I8]).
  - Ajuste: el mantenimiento tiene tope en el 10 % de las ventas del mes anterior (la estrategia simple del bot se trababa sin dinero).
- [x] 9. Interfaz
  - Menú principal: showroom 3D de fondo (`Showroom.luau`) con el auto exhibido y el color de la empresa elegida; 4 tarjetas a la izquierda (2 gratis, 2 con Robux), la elegida expandida. El auto exhibido se elige en Compañía › Marca.
  - Barra superior: ya tenía dos filas (datos y botones); Producción pasó a Ventas › Producción.
  - Personal (4 tarjetas, lista y detalle, mercado, capacitaciones), Marketing (diálogo de campaña) e Instalaciones (Compañía).
  - Sin personaje caminando: `SceneCamera.luau` orbita sobre el garaje (arrastrar = rotar, rueda/pellizco = zoom).
  - Ajustes con pestañas Audio, Gráficos, Accesibilidad y Datos.
- [x] 10. Pruebas generales (simuladas; **no se probó en Roblox Studio**)
  - `lune run tests/run.luau`: 6.272 comprobaciones; [I10] recorre los 20 pasos con sesiones reales (dos jugadores, pausa individual, duplicados, cambio de mes, carga en otro servidor).
  - `lune run tests/ui.luau`: 965 comprobaciones (menú, Personal, capacitación, marketing, instalaciones, cámara, ajustes).
  - `selene src tests` sin avisos; `.rbxl` armado y verificado con `tests/verify_place.luau`.

## Pendiente

- Probar en Studio: verificar el aspecto del showroom 3D, de la cámara del escenario y de las pantallas nuevas.
- Configurar los Developer Products (ranura 3, ranura 4, línea 3) en Roblox y poner sus ids en `Catalog.PRODUCTS`; hasta entonces las compras quedan deshabilitadas.
- Mapa mundial de la expansión internacional (los países y su lógica ya están).
- Modelos de edificios por nivel de fábrica (el garaje ya busca `ServerStorage.CarEmpireAssets.Sedes.Sede1..5`).
- Las mejoras de estaciones siguen siendo instantáneas (las obras con duración son las de instalaciones).
- Partidas viejas: los bonos de demanda de las investigaciones de marketing desaparecen (las campañas los reemplazan) y la antigüedad de los empleados empieza en la migración.
- Equilibrio: todos los valores nuevos son provisionales (`Catalog.STAFF`, `TRAINING`, `MARKETING`, `FACILITIES`).

## Revisión sin pruebas manuales (sin Studio)

Hecho con revisión estática y pruebas automáticas (`luau-analyze`, selene, chequeo de referencias entre módulos, acciones cliente ↔ servidor, pruebas con datos inválidos). **No se ejecutó en Roblox Studio.**

- Línea 3: ahora es de la **cuenta** (`profile.owned.line3`); se refleja en todas las empresas, también las nuevas (`GameState.applyAccount`).
- Expansión internacional: el jugador **elige el país** (`expandGlobal { country }`); esquema 15 conserva las aperturas previas.
- Capacitaciones: sin tope fijo de 12; el límite es una por empleado (protección del guardado = 50). Despedir al único participante elimina la capacitación vacía.
- Introducción cinematográfica (`Intro.luau`) al fundar una empresa: pausa esa empresa, termina sola en 9 s o con «Saltar» / Esc / Espacio / Enter.
- Despidos: además de la indemnización se paga el sueldo de los días trabajados desde el último pago (antes se podía usar personal casi gratis).
- El diálogo de lote muestra el mismo costo que cobra el servidor (con la eficiencia de Producción).
- Textos de ayuda que mandaban a caminar con el personaje, actualizados.

## Showroom 3D definitivo (sin probar en Studio)

Respaldo: tag `respaldo-pre-showroom`. Archivos: `src/client/Showroom.luau` (reescrito), `ScreenMenu.luau`, `App.luau`, `Main.client.luau`, `tests/ui.luau`.
- El escenario pasó de un ViewportFrame (una sola luz direccional, reconstruido en cada redibujo) al Workspace **local** del cliente, en `CONFIG.origin`, persistente entre redibujos. Solo está en el Workspace mientras se ve el menú.
- Sala cerrada (piso grafito semibrillante, paneles oscuros, techo), plataforma baja y líneas de luz del color corporativo. Luces: principal, relleno y contorno blancas (ubicadas según el tamaño del auto) y acentos de color con alcance que no llega a la pintura.
- Mientras se ve, el ambiente global se oscurece solo en ese cliente; al salir se restauran la iluminación y la cámara (FOV y tipo).
- Cámara: tres cuartos frontal y baja, órbita lenta, arrastre con el botón izquierdo en el área libre, rueda para zoom, límites según el tamaño real del modelo, vuelta suave a la órbita, auto corrido a la derecha.
- Cambio de empresa ≈ 0,9 s (sale 0,4, entra 0,5, color 0,8); un cambio nuevo cancela el anterior; nunca hay más de 2 autos.
- Parámetros en `Showroom.CONFIG`. Para celular quedan `Showroom.rotate` y `Showroom.zoom` (sin controles táctiles todavía).
- Recomendación para Studio: con `Lighting.Technology = Future` las luces puntuales se ven mejor (es una opción del lugar; no se cambió).

## Correcciones puntuales del showroom (sin probar en Studio)

Respaldo: tag `respaldo-pre-correcciones-showroom` y copia del `.rbxl` anterior.
- **Cámara:** `App.cameraOwner` define un único dueño: `"showroom"` en el menú principal, `"scene"` con empresa abierta fuera del menú, nadie en la creación. `SceneCamera.update` no escribe la cámara si no es su dueña (antes la movía en el menú mientras la empresa seguía cargada). La intro sigue igual; una sola conexión a RenderStepped.
- **Luz:** techo, paredes y junturas proyectan sombra y se agregó un muro exterior por lado, así el sol no entra. Mientras se ve: sol (`Brightness`), luz del cielo, niebla y `Atmosphere` apagados; cada propiedad se guarda y restaura por separado, aunque falle otra.
- **Mouse:** además de `processed`, se consulta `GetGuiObjectsAtPosition`. No rota sobre tarjetas, paneles, textos ni botones, y la rueda no hace zoom sobre listas desplazables. Al perder el foco de la ventana se cancela el arrastre.
- **Plataforma y anillo:** el anillo queda apoyado sobre el piso (antes casi enterrado), centrado con la plataforma y con un diámetro según el auto.
- **Transiciones:** al ocultarse a mitad de un cambio se libera el auto que salía y, al volver, se muestra el de la última empresa. «Reducir movimiento» también aplica el color al instante.
- Pruebas: `tests/ui.luau` (1.158) cubre cámara, luz, sombras, entrada, anillo, transición y modo reducido.
