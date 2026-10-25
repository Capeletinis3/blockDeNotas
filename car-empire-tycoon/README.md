# Car Empire Tycoon · Roblox (etapa 1)

Primera etapa jugable en Roblox basada en el prototipo `reference/Car-Empire-Tycoon-V3.html`.
La V3 sirve de referencia visual y de reglas: los catálogos, fórmulas de precio y estadísticas,
la fabricación y el comportamiento de los clientes se portaron con los mismos números.

## Estructura

```
car-empire-tycoon/
├─ default.project.json      Proyecto Rojo (qué carpeta va a qué servicio)
├─ src/shared/  → ReplicatedStorage.CarEmpireShared
│   ├─ Catalog.luau          Bases, piezas, pinturas, materiales, reglas (V3)
│   ├─ DesignCalc.luau       computeDesign, bloqueos, costo de desarrollo, saneamiento del borrador
│   ├─ CarModel.luau         Auto provisional hecho con Parts (editor y garaje)
│   └─ Util.luau             Redondeo como JS, dinero "$28.700", fechas
├─ src/server/  → ServerScriptService.CarEmpireServer
│   ├─ Main.server.luau      Sesiones por jugador, remotos, bucle de simulación, autoguardado
│   ├─ Actions.luau          Acciones validadas (diseño, órdenes, compras, salón, ventas)
│   ├─ Simulation.luau       Reloj, fabricación, clientes, venta atómica
│   ├─ GameState.luau        Partida nueva, validación, migración, vista para el cliente
│   ├─ DataService.luau      DataStore con candado de sesión, reintentos y protección de datos
│   └─ Garage.luau           Vestíbulo + 8 garajes básicos con ProximityPrompts
├─ src/client/  → StarterPlayerScripts.CarEmpireClient
│   ├─ Main.client.luau      Arranque, eventos del servidor, atajos 0–4 / Esc
│   ├─ App.luau              Estado, navegación, reconstrucción por firma y valores en vivo
│   ├─ Ui.luau               Componentes con los tokens de color de la V3
│   └─ Screen*.luau, Dialogs.luau   Empresa, HUD, Editor, Fábrica, Mis autos, Ventas, diálogos
├─ tests/run.luau            Pruebas de la lógica del servidor con Lune
└─ reference/                Prototipo V3 original
```

## Cómo abrir el proyecto

Opción A — sincronizar con Rojo (recomendado para seguir desarrollando):

1. Instalar [Rojo](https://rojo.space) 7 (CLI) y el plugin de Rojo en Roblox Studio.
2. En esta carpeta: `rojo serve`
3. En Studio, abrir tu place (o uno nuevo «Baseplate») → plugin Rojo → **Connect**.
   Rojo solo crea/gestiona `CarEmpireShared`, `CarEmpireServer` y `CarEmpireClient`; el resto del place no se toca.

Opción B — generar un archivo de place: `rojo build -o CarEmpire.rbxl` y abrirlo en Studio.

### Ajustes necesarios en Studio (acción manual)

- **Guardado real**: publicar el place (File › Publish to Roblox) y activar
  *Game Settings › Security › Enable Studio Access to API Services*.
  Sin esto el juego funciona igual, pero usa un guardado temporal en memoria y lo avisa con una banda amarilla.
- Recomendado: *Game Settings › Places › Max Players = 8* (hay 8 garajes por servidor).

## Cómo probar el recorrido (Play en Studio)

1. Aparecés en el vestíbulo con la pantalla **Fundá tu empresa**: nombre (3–24 caracteres), color y dificultad → *Comenzar mi empresa*.
2. Te lleva a tu **garaje** (cartel con tu nombre y color). Puntos con la tecla **E**: Escritorio de diseño, Línea de producción, Almacén, Concesionario. También el HUD (Diseño, Mis autos, Fábrica, Ventas) o las teclas 1–4.
3. **Diseño**: paso 1 elegí *Pixel C1* o *Brisa Sedán*; paso 2 instalá piezas (p. ej. frenos deportivos); paso 3 pintura principal/secundaria, acabado, llantas y alerón; paso 4 *Guardar diseño*.
4. Se cobra la licencia del modelo y los prototipos **una sola vez** (volver a guardar sin cambios no cobra; una v2 solo cobra piezas nuevas).
5. *Enviar a producción* (o Fábrica › Nueva orden). La orden muestra «v1» y queda fijada aunque edites el diseño después.
6. Con velocidad 2×/4× (arriba a la derecha) la unidad avanza: al empezar descuenta dinero y materiales; al terminar aparece en Mis autos y en el almacén del garaje.
7. Mis autos › *Enviar al salón*. En Ventas aparecen clientes; cuando uno ofrece: *Aceptar*, *Contraofertar* o *Rechazar*.
8. Revisar dinero (HUD), Mis autos (unidad vendida), Ventas › Historial y Movimientos.
9. Detener y volver a dar Play (con API activada): la empresa, el dinero, los diseños y el inventario se recuperan.

**Dos jugadores**: pestaña *Test › Clients and Servers*, 2 jugadores → Start. Cada uno crea su empresa y recibe su propio garaje; dinero, diseños e inventario son independientes. Las acciones de cada cliente solo tocan la partida de ese jugador (el servidor la elige por el `Player` del remoto, nunca por un id enviado por el cliente).

## Pruebas automáticas (fuera de Studio)

Requiere [Lune](https://lune-org.github.io/docs) ≥ 0.10:

```
lune run tests/run.luau
```

Cubren: fórmulas iguales a la V3, saneamiento del borrador (piezas/bases bloqueadas, precios inventados),
cobro único del desarrollo, copia independiente de la versión en la orden, consumo de dinero y materiales,
detención por falta de materiales o fondos y reintegro al cancelar, cliente → oferta → venta, rechazo de dobles ventas,
contraoferta, independencia de dos jugadores y guardado (ida y vuelta por JSON, candado de sesión,
fallo de carga sin escritura, datos dañados intactos, partida inválida no se guarda, sesión perdida).

## Reglas de seguridad y guardado

- El cliente envía solo intenciones e identificadores. El servidor recalcula costos y precios, valida pertenencia, capacidad, dinero y materiales; si algo falla, no cambia nada.
- Nombres de empresa y de diseños pasan por `TextService` (se ven en el garaje para todos).
- Una acción por jugador a la vez y límite de 12 solicitudes cada 2 s.
- Clave por jugador `player_<UserId>`; `UpdateAsync` con candado de sesión (vence a los 300 s sin renovarse).
- Si la carga falla o los datos están dañados: se muestra el error con *Reintentar* y esa sesión **no guarda** nada.
- Antes de cada escritura se valida la partida; si otro servidor tomó el candado, se deja de guardar.
- Autoguardado cada 45 s con cambios, guardado poco después de acciones importantes, al salir y al cerrar el servidor.
