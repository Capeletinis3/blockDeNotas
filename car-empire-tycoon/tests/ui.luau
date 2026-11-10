--[[
	Pruebas de la interfaz sin Roblox Studio: se ejecutan el servidor y el cliente reales sobre los
	dobles de tests/mock.luau, y se maneja la interfaz como un jugador (buscar botones por su texto,
	hacer clic, escribir). Detectan errores de ejecución y flujos rotos; NO verifican el aspecto
	visual, el diseño en pantalla, la física ni el rendimiento: eso se prueba en Studio.
	Uso (desde la carpeta car-empire-tycoon):  lune run tests/ui.luau
]]

local process = require("@lune/process")

local Build = require("./build")
Build.prepare({ mock = true })

local M = require("./mock")
local T = require("./harness")
local check, eq, test = T.check, T.eq, T.test
local Util = require("./.build-ui/shared/Util")

local shared = M.Instance.new("Folder")
shared.Name = "CarEmpireShared"
shared.Parent = M.services.ReplicatedStorage

-- El Pioneer 70 real (assets/vehicles/Pioneer70_World.rbxm) donde lo guarda el equipo en Studio.
local VehicleAsset = require("./vehicle_asset")
local pioneerOriginal = VehicleAsset.load(M, "assets/vehicles/Pioneer70_World.rbxm")
do
	local folder = M.Instance.new("Folder")
	folder.Name = "VehicleModels"
	folder.Parent = M.services.ServerStorage
	pioneerOriginal.Parent = folder
end

require("./.build-ui/server/Main")
-- El límite de acciones por segundo se prueba en un caso propio; para el resto se amplía porque las
-- pruebas hacen clics mucho más rápido que una persona.
local Sessions = require("./.build-ui/server/Sessions")
local player = M.newPlayer(1001, "Ana")
M.addPlayer(player, true)

local App = require("./.build-ui/client/App")
require("./.build-ui/client/Main")

local function waitFor(cond: () -> boolean, frames: number?): boolean
	for _ = 1, frames or 300 do
		if cond() then
			return true
		end
		M.task.wait()
	end
	return cond()
end

local root = App.gui

local function find(text: string): any
	return M.find(root, text)
end
local function button(text: string): any
	return M.button(root, text)
end
local function click(text: string)
	local b = button(text)
	assert(b, "No se encontró el botón «" .. text .. "»")
	M.click(b)
end
local function named(name: string): any
	for _, d in root:GetDescendants() do
		if d.Name == name and M.visible(d) and not rawget(d, "__destroyed") then
			return d
		end
	end
	return nil
end
local function clickN(name: string)
	local b = named(name)
	assert(b, "No se encontró el elemento «" .. name .. "»")
	M.click(b)
end
local function dialogOpen(): boolean
	return #App.ui.dialogs > 0
end
local function topKind(): string?
	local d = App.topDialog()
	return d and d.kind
end
-- Avanza la simulación del servidor (1 paso = 1 s real = 10 min de juego a velocidad ×1).
local function advance(seconds: number)
	M.step(seconds)
	M.task.wait()
end
local function noErrors(what: string)
	local bad = {}
	for _, l in M.log do
		if string.find(l, "Error", 1, true) then
			table.insert(bad, l)
		end
	end
	check(#bad == 0, what .. " sin errores en el registro" .. (#bad > 0 and (": " .. bad[1]) or ""))
	table.clear(M.log)
end

test("Carga: pantalla de inicio con ranuras vacías", function()
	check(waitFor(function()
		return App.payload ~= nil and App.payload.status == "ready"
	end), "el servidor entrega el estado listo")
	eq(App.ui.route, "menu", "arranca en el menú de empresas")
	check(named("Crear_1") ~= nil, "la ranura 1 libre ofrece crear una empresa")
	noErrors("Menú")
end)

test("Crear empresa escribiendo solo el nombre (el botón se habilita en vivo)", function()
	clickN("Crear_1")
	eq(App.ui.route, "nueva", "abre el formulario")
	local start = named("Comenzar")
	check(start ~= nil, "existe el botón Comenzar")
	eq(start:GetAttribute("disabled"), true, "sin nombre está deshabilitado")
	local box = M.find(root, "", "TextBox")
	for _, d in root:GetDescendants() do
		if d.ClassName == "TextBox" and d.PlaceholderText == "Por ejemplo: Ruta Norte Motors" then
			box = d
		end
	end
	box:CaptureFocus()
	box.Text = "Ruta Norte"
	-- Sin soltar el foco: el botón ya tiene que estar habilitado (era el bloqueo de la etapa anterior).
	eq(named("Comenzar"):GetAttribute("disabled"), false, "se habilita mientras se escribe")
	box:ReleaseFocus(false)
	M.task.wait()
	clickN("Comenzar")
	check(waitFor(function()
		return App.g ~= nil
	end), "la empresa se crea")
	eq(App.ui.route, "juego", "entra a la sede")
	-- Introducción cinematográfica: aparece, pausa la empresa y se puede saltar.
	check(named("Intro") ~= nil and named("SaltarIntro") ~= nil, "introducción con botón Saltar")
	for _ = 1, 60 do
		M.services.RunService.RenderStepped:Fire(1 / 60)
	end
	check(find("1 de enero de 1970") ~= nil, "muestra la fecha de inicio")
	check(App.menuPaused(), "la empresa queda en pausa mientras dura")
	local sess0 = Sessions.instance.list[player]
	check(waitFor(function()
		return sess0.uiPaused == true
	end), "el servidor pausa solo esa empresa")
	clickN("SaltarIntro")
	M.task.wait()
	check(named("Intro") == nil and not App.menuPaused(), "saltada: la empresa sigue")
	check(waitFor(function()
		return sess0.uiPaused == false
	end), "el servidor la reanuda")
	eq(App.g and App.g.company.name, "Ruta Norte", "nombre guardado")
	noErrors("Crear empresa")
end)

test("Límite de acciones seguidas: se rechazan con aviso y no rompen la sesión", function()
	local rejected = 0
	for _ = 1, 20 do
		local r = App.request("markRead", {})
		if not r.ok and r.msg and string.find(r.msg, "Demasiadas", 1, true) then
			rejected += 1
		end
	end
	check(rejected > 0, "las acciones de más se rechazan")
	Sessions.RATE_MAX = 100000
	local r = App.request("markRead", {})
	check(r.ok, "la sesión sigue funcionando")
end)

test("Todas las pantallas se construyen en escritorio", function()
	for _, route in { "editor", "autos", "fabrica", "ventas", "mercado", "investigacion", "personal", "compania", "misiones", "estadisticas", "juego" } do
		App.renderError = nil
		App.go(route)
		M.task.wait()
		if route == "editor" and dialogOpen() then
			App.closeAllDialogs()
		end
		check(App.renderError == nil, route .. " se construye" .. (App.renderError and (": " .. tostring(App.renderError)) or ""))
		eq(App.ui.route, route, "ruta " .. route)
	end
	noErrors("Pantallas")
end)


-- Recorre las etapas que falten y finaliza el diseño abierto (con la confirmación).
local function finishDesign(): boolean
	local before = #App.g.designs
	for _ = 1, 5 do
		if App.ui.editor.step < #App.screens.editor.STEPS then
			clickN("Siguiente")
		end
	end
	clickN("FinalizarDiseno")
	clickN("Confirmar")
	return waitFor(function()
		return #App.g.designs > before
	end)
end

local function lotOf(designId: string): any
	for _, l in App.g.lots do
		if l.designId == designId then
			return l
		end
	end
	return nil
end

test("Recorrido completo por la interfaz: diseñar → recompensa → lanzar lote → venta automática → precio → cerrar venta", function()
	local g0 = App.g
	local money0 = g0.money
	eq(Util.fullDate(g0.time.day, g0.time.minute), "01/01/1970", "la empresa empieza el 01/01/1970")
	check(find("01/01/1970") ~= nil, "el HUD muestra la fecha completa")
	check(named("Nav_editor") and named("Nav_editor"):FindFirstChild("Resaltado") ~= nil, "el tutorial resalta Diseño")
	App.go("editor", { new = true })
	M.task.wait()
	eq(App.ui.route, "editor", "abre el editor")
	-- Primer recorrido guiado por las cinco etapas.
	App.screens.editor.goStep(3)
	eq(App.ui.editor.step, 1, "la primera vez no se saltean etapas")
	for step = 1, 4 do
		local nb = named("Siguiente")
		check(nb ~= nil, "etapa " .. step .. ": botón Siguiente")
		if step == 2 then
			check(named("Impacto") ~= nil, "las tarjetas muestran el impacto real en estadísticas y costo")
		end
		M.click(nb)
	end
	eq(App.ui.editor.step, 5, "llega al resumen")
	local fin = named("FinalizarDiseno")
	check(fin ~= nil and fin:GetAttribute("disabled") == false, "finalizar habilitado con fondos iniciales")
	M.click(fin)
	eq(topKind(), "confirm", "pide confirmar que el diseño será definitivo")
	clickN("Confirmar")
	check(waitFor(function()
		return #App.g.designs >= 1
	end), "el diseño queda finalizado")
	eq(#(App.g.drafts or {}), 0, "el borrador se retira")
	eq(App.ui.route, "fabrica", "pasa a Producción")
	check(App.g.money <= money0, "el desarrollo se cobra (o no cuesta) al finalizar")
	eq(App.g.designs[1].modelYear, 1970, "año de modelo 1970")
	App.go("juego")
	M.task.wait()
	local claim = named("Reclamar")
	check(claim ~= nil, "la tarjeta del tutorial ofrece reclamar")
	local before = App.g.money
	M.click(claim)
	check(waitFor(function()
		return App.g.money > before
	end), "la recompensa del tutorial se acredita")
	local afterClaim = App.g.money
	App.request("claimMission", { id = "t1" })
	M.task.wait()
	eq(App.g.money, afterClaim, "la recompensa no se cobra dos veces")

	-- Lanzar lote con cantidad escrita a mano.
	App.go("fabrica")
	M.task.wait()
	clickN("LanzarLote")
	eq(topKind(), "lot", "abre el diálogo de lote")
	check(named("Cantidad_10000") ~= nil and named("Cantidad_50000") ~= nil, "atajos de 10.000 y 50.000")
	M.type(named("Cantidad"), "30")
	eq(App.ui.lotDraft and App.ui.lotDraft.qty, 30, "la cantidad escrita se conserva")
	check(find("Ventas estimadas") ~= nil, "muestra la estimación de ventas")
	check(find("Costo total (se paga al ordenar)") ~= nil and find("Tiempo de producción") ~= nil, "muestra el costo total y la duración")
	clickN("ConfirmarLote")
	local designId = App.g.designs[1].id
	check(waitFor(function()
		return lotOf(designId) ~= nil
	end), "el lote se crea")
	eq(lotOf(designId).qty, 30, "con la cantidad elegida")
	check(not dialogOpen(), "el diálogo se cierra")
	-- Con el panel de Producción abierto la empresa está en pausa: ni el calendario ni la fábrica avanzan.
	local t0, p0 = App.g.time.minute + App.g.time.day * 10000, lotOf(designId).produced
	advance(10)
	eq(App.g.time.minute + App.g.time.day * 10000, t0, "con un menú abierto el calendario no avanza")
	eq(lotOf(designId).produced, p0, "ni la fabricación")
	App.go("juego")
	M.task.wait()
	-- Se fabrica completo; al terminar se abren solas las reseñas de los cuatro críticos.
	check(waitFor(function()
		advance(1)
		return topKind() == "reviews"
	end, 400), "llegan las reseñas")
	local lr = lotOf(designId)
	eq(lr.saleState, "por lanzar", "terminado y sin vender todavía")
	eq(lr.sold, 0, "no se vendió nada antes de fijar el precio")
	check(named("Critico_familia") ~= nil and named("Critico_pista") == nil, "los críticos aparecen de a uno")
	clickN("SaltarResenas")
	for _, c in { "familia", "pista", "bolsillo", "tendencias" } do
		check(named("Critico_" .. c) ~= nil, "reseña de " .. c)
	end
	check(named("NotaFinal") ~= nil, "nota final")
	M.type(named("Precio"), tostring(lr.refPrice))
	clickN("PonerALaVenta")
	check(waitFor(function()
		local x = lotOf(designId)
		return x ~= nil and x.saleState == "en venta"
	end), "a la venta con el precio elegido")
	App.go("juego")
	M.task.wait()
	for _ = 1, 600 do
		local x = lotOf(designId)
		if x and x.sold >= 5 then
			break
		end
		advance(1)
	end
	local l = lotOf(designId)
	check(l ~= nil and l.sold >= 5, "se venden solos")
	check(l.sold <= l.produced, "nunca más de lo fabricado")
	noErrors("Fabricación y venta")

	-- Centro de ventas: tarjeta del modelo con sus datos y acciones.
	App.go("ventas")
	M.task.wait()
	check(named("Modelo_" .. l.id) ~= nil, "tarjeta del modelo en venta")
	for _, n in { "Encargadas", "Fabricadas", "Pendientes", "Disponibles", "Vendidas", "Ritmo", "Ingresos", "Gastos", "Resultado", "ModificarPrecio", "CerrarVenta", "Campana", "NuevaCampana" } do
		check(named(n) ~= nil, "la tarjeta muestra " .. n)
	end
	check(find("En venta") ~= nil, "estado comercial En venta")
	clickN("ModificarPrecio")
	eq(topKind(), "price", "abre el diálogo de precio")
	M.type(named("Precio"), tostring(l.price + 500))
	clickN("AplicarPrecio")
	check(waitFor(function()
		local x = lotOf(designId)
		return x ~= nil and x.price ~= l.price
	end), "el precio cambia en el servidor")
	-- Cerrar venta: la confirmación dice cuántas unidades se pierden.
	M.task.wait()
	clickN("CerrarVenta")
	eq(topKind(), "confirm", "pide confirmación")
	local x = lotOf(designId)
	local avail = x.produced - x.sold - x.discarded
	check(find("unidades sin vender") ~= nil or avail == 0, "advierte las unidades sin vender (" .. avail .. ")")
	clickN("Confirmar")
	check(waitFor(function()
		return lotOf(designId) == nil
	end), "el modelo deja de estar en venta")
	local h = App.g.lotHistory[1]
	eq(h.saleState, "retirado", "queda Retirado en el historial")
	App.ui.tabs.ventas = "historial"
	App.forceRender()
	M.task.wait()
	check(named("Historial_" .. h.id) ~= nil, "aparece en Agotados y retirados")
	App.ui.tabs.ventas = nil
	-- Historia permanente del modelo en el Catálogo, con récords.
	App.go("autos")
	App.ui.tabs.autos = "historia"
	App.forceRender()
	M.task.wait()
	check(named("Records") ~= nil, "récords de la empresa")
	check(named("Generacion_" .. tostring(h.design.lineage) .. "#1") ~= nil, "la generación del modelo retirado está en la historia")
	App.ui.tabs.autos = nil
	-- Competidores: clasificación con la posición de la empresa.
	App.go("mercado")
	App.ui.tabs.mercado = "rivales"
	App.forceRender()
	M.task.wait()
	check(named("Clasificacion") ~= nil and named("PosicionPropia") ~= nil, "clasificación con tu posición")
	App.ui.tabs.mercado = nil
	App.go("juego")
	M.task.wait()
	noErrors("Ventas")
end)

test("Editor: el borrador se guarda solo al salir y un modelo terminado no se edita", function()
	App.go("editor", { new = true })
	M.task.wait()
	App.screens.editor.change(function(d)
		d.name = "Prueba sin guardar"
	end)
	check(App.ui.editor.pendingSync, "queda pendiente de guardar (sin escribir en cada clic)")
	local id = App.ui.editor.draftId
	App.go("autos")
	M.task.wait()
	check(not dialogOpen(), "salir no pregunta nada")
	local dr = App.screens.editor.findDraft(id)
	check(dr ~= nil and dr.spec.name == "Prueba sin guardar", "al salir el borrador queda guardado en la partida")
	-- Un modelo terminado abre un borrador NUEVO basado en él (el modelo no cambia).
	local d = App.g.designs[1]
	App.go("editor", { designId = d.id })
	M.task.wait()
	eq(App.ui.route, "editor", "abre el editor")
	check(App.ui.editor.draftId ~= id and App.ui.editor.draft.id == nil, "con un borrador nuevo, no el modelo")
	-- Deshacer y rehacer.
	local name0 = App.ui.editor.draft.name
	App.screens.editor.change(function(dd)
		dd.name = "Otro nombre"
	end)
	App.screens.editor.undo()
	eq(App.ui.editor.draft.name, name0, "deshacer vuelve al nombre anterior")
	App.screens.editor.redo()
	eq(App.ui.editor.draft.name, "Otro nombre", "rehacer reaplica el cambio")
	-- El borrador anterior sigue y se puede retomar.
	App.go("editor", { draftId = id })
	M.task.wait()
	eq(App.ui.editor.draftId, id, "se retoma el borrador anterior")
	eq(App.ui.editor.draft.name, "Prueba sin guardar", "con su contenido")
	App.go("juego")
	M.task.wait()
	eq(App.ui.route, "juego", "sale sin preguntar")
	noErrors("Editor")
end)

test("Editor V3: cámaras, pasos, ocultar interfaz, antes/después y modelos anteriores", function()
	App.go("editor", { new = true, force = true })
	M.task.wait()
	if dialogOpen() then
		clickN("Descartar")
		M.task.wait()
	end
	eq(App.ui.route, "editor", "abre el editor")
	M.task.wait()
	M.services.RunService.RenderStepped:Fire(1 / 60) -- un cuadro: la cámara se ubica
	local diag = App.screens.editor.diagnose()
	check(diag.ok, "vista 3D: el auto está en el ViewportFrame y delante de la cámara" .. (diag.ok and "" or (": " .. table.concat(diag.problems, "; "))))
	clickN("Camaras")
	check(M.find(App.dropLayer, "Frontal") ~= nil and M.find(App.dropLayer, "Vista libre") ~= nil, "siete cámaras en la lista")
	M.click(App.dropLayer:FindFirstChild("Opcion_frontal", true))
	eq(App.screens.editor.CAMS[2][1], "frontal", "cámara frontal")
	App.screens.editor.goStep(2)
	M.task.wait()
	eq(App.ui.editor.step, 2, "paso 2")
	check(named("Estadisticas") ~= nil, "las estadísticas aparecen en el paso 2")
	clickN("AntesDespues")
	M.task.wait()
	check(App.ui.editor.compare == true and named("RotuloAntes") ~= nil and named("Divisor") ~= nil, "antes/después con rótulos y divisor")
	clickN("AntesDespues")
	clickN("OcultarInterfaz")
	M.task.wait()
	check(named("PanelEditor") == nil and named("MostrarInterfaz") ~= nil, "ocultar interfaz deja solo la vista y la barra")
	clickN("MostrarInterfaz")
	M.task.wait()
	check(named("PanelEditor") ~= nil, "la interfaz vuelve")
	clickN("ModelosAnteriores")
	M.task.wait()
	eq(topKind(), "prevModels", "abre borradores y modelos")
	click("Empezar un proyecto nuevo")
	M.task.wait()
	check(not dialogOpen() and App.ui.editor.step == 1, "empieza un proyecto nuevo en el paso 1")
	App.go("juego")
	M.task.wait()
	if dialogOpen() then
		clickN("Descartar")
	end
	noErrors("Editor V3")
end)

test("Todos los diálogos se construyen", function()
	local h = App.g.lotHistory[1]
	local kinds = {
		{ "lot", {} }, { "price", { lotId = h and h.id } }, { "confirm", { title = "x", body = "y" } },
		{ "notifications", {} }, { "daily", {} }, { "settings", {} },
		{ "help", { screen = "fabrica" } }, { "future", { what = "amigos" } }, { "future", { what = "eventos" } }, { "future", { what = "tienda" } },
		{ "news", {} }, { "prevModels", {} }, { "testDrive", {} },
		{ "deleteCompany", { slot = "1", expected = "Ruta Norte", name = "Ruta Norte" } },
		{ "campaign", {} }, { "training", { scope = "general" } }, { "training", { scope = "departamento", dept = "investigacion" } },
	}
	for _, k in kinds do
		table.clear(M.log)
		App.openDialog(k[1], k[2])
		M.task.wait()
		check(named("Dialogo") ~= nil, k[1] .. " se muestra")
		noErrors("Diálogo " .. k[1])
		App.closeAllDialogs()
	end
end)

test("Configuración: se guarda en el servidor y se aplica", function()
	App.openDialog("settings", {})
	M.task.wait()
	for _, t in { "audio", "graficos", "accesibilidad", "datos" } do
		clickN("Ajustes_" .. t)
		M.task.wait()
		check(named("PestanasAjustes") ~= nil and #M.log == 0, "pestaña " .. t)
	end
	check(named("BorrarTodo") ~= nil, "datos: borrar todo")
	clickN("Ajustes_graficos")
	check(named("SensibilidadCamara") ~= nil, "gráficos: sensibilidad de la cámara")
	clickN("Ajustes_accesibilidad")
	M.task.wait()
	click("Grande")
	check(waitFor(function()
		return App.settings.textScale == 1.12
	end), "el tamaño del texto se guarda")
	App.request("setSetting", { key = "textScale", value = 1 })
	App.request("setSetting", { key = "textScale", value = 99 })
	M.task.wait()
	eq(App.settings.textScale, 1, "un valor fuera de rango se rechaza")
	App.closeAllDialogs()
	noErrors("Configuración")
end)

test("Segunda empresa en otra ranura (Magnate) e independencia entre ranuras", function()
	local money1 = App.g.money
	local name1 = App.g.company.name
	App.go("compania")
	M.task.wait()
	clickN("VolverMenu")
	check(waitFor(function()
		return App.g == nil and App.ui.route == "menu"
	end), "vuelve al menú de empresas")
	-- La tarjeta del espacio 2 se elige primero; la acción principal pasa a ser «Crear empresa».
	clickN("Elegir_2")
	clickN("Crear_2")
	eq(App.ui.newCompany.slot ~= "1", true, "elige una ranura libre")
	for _, d in root:GetDescendants() do
		if d.ClassName == "TextBox" and d.PlaceholderText == "Por ejemplo: Ruta Norte Motors" then
			M.type(d, "Magnate SA")
		end
	end
	clickN("Comenzar")
	check(waitFor(function()
		return App.g ~= nil
	end), "se crea la segunda empresa")
	-- La introducción también termina sola: se simula su duración completa.
	check(named("Intro") ~= nil, "introducción de la segunda empresa")
	for _ = 1, math.ceil(App.screens.intro.DURATION * 60) + 5 do
		M.services.RunService.RenderStepped:Fire(1 / 60)
	end
	M.task.wait()
	check(named("Intro") == nil and not App.menuPaused(), "termina sola y la empresa sigue")
	eq(App.g.company.name, "Magnate SA", "es la nueva")
	eq(App.g.company.difficulty, nil, "sin dificultad: misma condición inicial")
	eq(App.g.money, 90000, "capital inicial igual para todas")
	-- Sin dinero manual, el capital inicial alcanza para el primer diseño y un primer lote.
	App.go("editor", { new = true })
	M.task.wait()
	finishDesign()
	App.go("juego")
	M.task.wait()
	clickN("Reclamar")
	waitFor(function()
		return App.g.claimed.t1 ~= nil
	end)
	App.go("fabrica")
	M.task.wait()
	clickN("LanzarLote")
	clickN("ConfirmarLote")
	check(waitFor(function()
		return #App.g.lots >= 1
	end), "Magnate puede lanzar su primer lote")
	-- Volver a la primera empresa: sus datos siguen intactos.
	App.request("leaveCompany")
	waitFor(function()
		return App.g == nil
	end)
	App.request("selectSlot", { slot = "1" })
	check(waitFor(function()
		return App.g ~= nil
	end), "se abre la primera empresa")
	eq(App.g.company.name, name1, "es la primera")
	check(App.g.money ~= nil and math.abs(App.g.money - money1) < 50000, "su dinero no se mezcló con la otra")
	noErrors("Ranuras")
end)

-- [P15] La interfaz se adapta a PC y celular: se construyen todas las pantallas en las cuatro resoluciones
-- pedidas y se verifica que ningún panel ni el HUD se salgan del ancho de la pantalla.
local function overflow(): { string }
	local out = {}
	local vw = App.vw
	for _, d in App.content:GetDescendants() do
		if (d.Name == "Hud1" or d.Name == "Hud2" or string.sub(d.Name, 1, 6) == "Panel_" or d.Name == "PanelEditor" or d.Name == "Principal") and M.visible(d) then
			local x = d.AbsolutePosition.X
			local w = d.AbsoluteSize.X
			if x < -1 or x + w > vw + 1 then
				table.insert(out, d.Name .. string.format(" (%d..%d de %d)", x, x + w, vw))
			end
			-- Los elementos del HUD tampoco pueden quedar cortados por el borde derecho.
			if d.Name == "Hud1" or d.Name == "Hud2" then
				for _, c in d:GetChildren() do
					if c:IsA("GuiObject") and c.Visible and c.AbsolutePosition.X + c.AbsoluteSize.X > vw + 1 then
						table.insert(out, d.Name .. "/" .. c.Name .. string.format(" (termina en %d de %d)", c.AbsolutePosition.X + c.AbsoluteSize.X, vw))
					end
				end
			end
		end
	end
	return out
end

test("[P15] PC y celular: todas las pantallas en 1600×900, 1280×720, 844×390 y 390×844", function()
	local routes = { "juego", "editor", "autos", "fabrica", "ventas", "mercado", "investigacion", "personal", "compania", "misiones", "estadisticas" }
	for _, res in { { 1600, 900, "desktop" }, { 1280, 720, "compact" }, { 844, 390, "phone" }, { 390, 844, "phone" } } do
		M.services.Workspace.CurrentCamera.ViewportSize = M.Vector2.new(res[1], res[2])
		M.task.wait()
		eq(App.layout, res[3], res[1] .. "×" .. res[2] .. ": distribución " .. res[3])
		for _, route in routes do
			App.renderError = nil
			App.go(route)
			M.task.wait()
			App.closeAllDialogs()
			check(App.renderError == nil, route .. " en " .. res[1] .. "×" .. res[2] .. (App.renderError and (": " .. tostring(App.renderError)) or ""))
			local bad = overflow()
			check(#bad == 0, route .. " en " .. res[1] .. "×" .. res[2] .. " no se sale de la pantalla" .. (#bad > 0 and (": " .. bad[1]) or ""))
		end
		for _, k in { { "lot", {} }, { "settings", {} } } do
			App.openDialog(k[1], k[2])
			M.task.wait()
			check(named("Dialogo") ~= nil, "diálogo " .. k[1] .. " en " .. res[1] .. "×" .. res[2])
			App.closeAllDialogs()
		end
	end
	M.services.Workspace.CurrentCamera.ViewportSize = M.Vector2.new(844, 390)
	M.task.wait()
	App.go("juego")
	M.task.wait()
	App.ui.pop = "mob"
	App.screens.hud.renderPop()
	local menu = named("MenuCelular")
	check(menu ~= nil and M.find(App.popLayer, "Estad") ~= nil, "el menú de celular llega a todas las secciones")
	App.ui.pop = nil
	App.forceRender()
	M.services.Workspace.CurrentCamera.ViewportSize = M.Vector2.new(1600, 900)
	M.task.wait()
	noErrors("Resoluciones")
end)

test("Pioneer 70: carrocería 3D del sedán, pintura, ubicación y copias en el garaje", function()
	local Catalog = require("./.build-ui/shared/Catalog")
	local DesignCalc = require("./.build-ui/shared/DesignCalc")
	local CarModel = require("./.build-ui/shared/CarModel")
	local function parts(m: any): { any }
		local out = {}
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				out[d.Name] = d
			end
		end
		return out
	end
	local function count(t: any): number
		local n = 0
		for _ in t do
			n += 1
		end
		return n
	end
	local function minY(m: any): number
		local y = math.huge
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				y = math.min(y, d.CFrame.Y - d.Size.Y / 2)
			end
		end
		return y
	end
	local orig = parts(pioneerOriginal)
	eq(count(orig), 38, "el modelo real tiene 38 piezas")
	-- El servidor publicó una copia sin scripts para el cliente; el original queda igual (con su script).
	local public = M.services.ReplicatedStorage:FindFirstChild("CarEmpireAssets"):FindFirstChild("VehicleModels"):FindFirstChild("Pioneer70_World")
	check(public ~= nil, "copia publicada en ReplicatedStorage.CarEmpireAssets.VehicleModels")
	check(public:FindFirstChildWhichIsA("LuaSourceContainer", true) == nil, "la copia publicada no lleva scripts")
	check(pioneerOriginal:FindFirstChild("Script") ~= nil and pioneerOriginal.Parent ~= nil, "el original sigue en ServerStorage con su script")

	-- Diseño de sedán de los 70: carrocería predeterminada Pioneer 70.
	local g70 = { time = { day = 2 * 12 }, research = { done = {} }, company = { name = "Prueba" }, devPaid = {} }
	local d = DesignCalc.newDraft(g70, "brisa")
	eq(d.vehicleModel, "pioneer70", "el sedán de 1972 usa el Pioneer 70")
	d.paint.primary = "#1E88E5"
	local car = CarModel.build(d)
	eq(car:GetAttribute("vehicleModel"), "pioneer70", "se arma con el modelo 3D")
	local cp = parts(car)
	eq(count(cp), 38, "conserva las 38 piezas")
	check(car:FindFirstChildWhichIsA("LuaSourceContainer", true) == nil, "la copia no lleva el script de prueba de pintura")
	local blue = M.Color3.fromHex("#1E88E5")
	local painted, kept = 0, 0
	for name, p in cp do
		local o = orig[name]
		check(o ~= nil, name .. " existe en el original")
		check(p.Material == o.Material and math.abs(p.Size.X - o.Size.X) < 1e-6 and math.abs(p.Size.Z - o.Size.Z) < 1e-6, name .. ": mismo material y tamaño")
		if string.sub(name, -6) == "_Paint" then
			check(p.Color == blue, name .. " toma el color elegido")
			painted += 1
		else
			check(p.Color == o.Color and p.Transparency == o.Transparency, name .. " conserva su color y transparencia")
			kept += 1
		end
	end
	eq(painted, 7, "carrocería, capó, baúl y 4 puertas pintados")
	check(cp.Wheel_FL_Tire.Color == orig.Wheel_FL_Tire.Color and cp.Windows_Glass.Material == orig.Windows_Glass.Material and cp.Interior_Seats_Seat.Color == orig.Interior_Seats_Seat.Color, "neumáticos, cristales y asientos sin pintar")
	check(cp.FrontBumper_Chrome.Material == orig.FrontBumper_Chrome.Material and cp.Headlights_Lens.Material == orig.Headlights_Lens.Material, "paragolpes y faros sin cambios")
	check(cp.Headlights_Lens.Parent == cp.Interior_Controls_Rubber, "la jerarquía de piezas se conserva")
	local oc = orig.Body_Paint.Color
	check(math.floor(oc.R * 255 + 0.5) == 196 and math.floor(oc.G * 255 + 0.5) == 40 and math.floor(oc.B * 255 + 0.5) == 28, "el original no se pinta (sigue rojo)")
	-- Ubicación: el pivote queda a ras del suelo en el centro; las piezas mantienen sus distancias.
	car:PivotTo(M.CFrame.new(100, 0.5, 50) * M.CFrame.Angles(0, math.pi / 2, 0))
	check(math.abs(minY(car) - 0.5) < 1e-3, "las ruedas apoyan en el suelo (ni debajo ni flotando): " .. minY(car))
	local function dist(a: any, b: any): number
		return (a.CFrame.Position - b.CFrame.Position).Magnitude
	end
	check(math.abs(dist(cp.Wheel_FL_Tire, cp.Body_Paint) - dist(orig.Wheel_FL_Tire, orig.Body_Paint)) < 1e-4, "las piezas no cambian de posición entre sí")
	check(math.abs(dist(cp.Headlights_Lens, cp.Taillights_TailRed) - dist(orig.Headlights_Lens, orig.Taillights_TailRed)) < 1e-4, "faros y luces traseras en su lugar")
	check(math.abs(car:GetPivot().X - 100) < 1e-6 and math.abs(car:GetPivot().Z - 50) < 1e-6, "centrado donde se lo pide")
	-- Horizontal: el techo sigue arriba y el largo queda acostado (girado solo en Y, como se pidió).
	check(cp.Body_Paint.CFrame.UpVector.Y > 0.999, "el auto queda horizontal, no parado")
	check(math.abs(cp.Body_Paint.CFrame.LookVector.X) > 0.999, "girado 90° en Y como se pidió (largo a lo ancho)")
	check(cp.Interior_Headliner_TrimLight.CFrame.Y > cp.Wheel_FL_Tire.CFrame.Y + 2, "el techo queda arriba de las ruedas")
	check(cp.Body_Paint.Anchored == true and cp.Body_Paint.CanCollide == false, "anclado y sin colisión (es de exhibición)")
	local dims = CarModel.dims(d)
	check(dims.Z > 17 and dims.Z < 18 and dims.Y > 5 and dims.Y < 6, "medidas reales para encuadrar la cámara")
	-- Otra copia con otro color no hereda el anterior; fantasma = semitransparente.
	d.paint.primary = "#2E7D32"
	local ghost = CarModel.build(d, { ghost = true })
	local gp = parts(ghost)
	check(gp.Body_Paint.Color == M.Color3.fromHex("#2E7D32") and gp.Body_Paint.Transparency > 0.5, "cada copia con su pintura; en fabricación, semitransparente")
	-- Décadas: en 1985 el sedán nuevo no lo usa por defecto, pero se puede elegir (queda desbloqueado).
	local g85 = { time = { day = 15 * 12 }, research = { done = {} }, company = { name = "Prueba" }, devPaid = {} }
	local d85 = DesignCalc.newDraft(g85, "brisa")
	eq(d85.vehicleModel, nil, "en 1985 no es la predeterminada")
	eq(CarModel.build(d85):GetAttribute("vehicleModel"), nil, "un sedán de 1985 sin elección usa el provisional")
	check(DesignCalc.vehicleModelBlock(g85, d85, Catalog.vehicleModel("pioneer70")) == nil, "pero sigue disponible para elegir")
	d85.vehicleModel = "pioneer70"
	eq(CarModel.build(d85):GetAttribute("vehicleModel"), "pioneer70", "y se usa si se elige")
	-- Otro tipo no puede usarlo; "provisional" fuerza el genérico.
	local compact = DesignCalc.newDraft(g70, "pixel")
	compact.vehicleModel = "pioneer70"
	eq(CarModel.build(compact):GetAttribute("vehicleModel"), nil, "un compacto no usa la carrocería del sedán")
	d.vehicleModel = "provisional"
	eq(CarModel.build(d):GetAttribute("vehicleModel"), nil, "«Provisional» usa el modelo genérico")
	-- Sin el modelo en Studio no hay error: se usa el provisional.
	local saved = CarModel.vehicleResolver
	CarModel.vehicleResolver = function()
		return nil
	end
	d.vehicleModel = "pioneer70"
	local okBuild, fallback = pcall(CarModel.build, d)
	check(okBuild and fallback:GetAttribute("vehicleModel") == nil and fallback.PrimaryPart ~= nil, "si falta el modelo, provisional y sin errores")
	CarModel.vehicleResolver = saved

	-- Editor: en Chasis › Carrocería y pintura de un sedán se elige la carrocería 3D (Pioneer 70 o provisional).
	App.go("editor", { new = true })
	M.task.wait()
	DesignCalc.changeBase(App.g, App.ui.editor.draft, "brisa")
	App.screens.editor.openStage(1, "carroceria")
	M.task.wait()
	check(named("Carroceria3D_pioneer70") ~= nil and named("Carroceria3D_provisional") ~= nil, "el editor ofrece la carrocería 3D del sedán")
	clickN("Carroceria3D_provisional")
	eq(App.ui.editor.draft.vehicleModel, "provisional", "elegir «Provisional»")
	clickN("Carroceria3D_pioneer70")
	eq(App.ui.editor.draft.vehicleModel, "pioneer70", "volver al Pioneer 70")
	-- Salir del editor descartando el borrador de prueba.
	App.ui.editor = nil
	App.closeAllDialogs()
	App.go("juego")
	M.task.wait()

	-- Juego real: un sedán fabricado aparece en el garaje con el Pioneer 70, sin acumular copias.
	local draft = DesignCalc.newDraft(App.g, "brisa")
	draft.name = "Pioneer Prueba"
	draft.paint.primary = "#F7C95C"
	local r = App.request("saveDesign", { draft = draft })
	check(r.ok, "guardar: " .. tostring(r.msg))
	local id = r.designId
	local saved3d = nil
	for _, x in App.g.designs do
		if x.id == id then
			saved3d = x
		end
	end
	check(saved3d ~= nil and Catalog.resolveVehicleModel(saved3d) ~= nil and Catalog.resolveVehicleModel(saved3d).id == "pioneer70", "el diseño guardado usa el Pioneer 70")
	-- El lote se paga al ordenarlo: tantas unidades como alcance (hasta 40).
	local unit = DesignCalc.computeDesign(App.g, saved3d).unitCost
	local lot = App.request("createLot", { designId = id, qty = math.min(40, math.floor(App.g.money / unit)) })
	check(lot.ok, "lanzar lote: " .. tostring(lot.msg))
	local function garageCars(): { any }
		local out = {}
		for _, f in M.services.Workspace:GetDescendants() do
			if f.Name == "Dinamico" then
				for _, c in f:GetChildren() do
					if c:IsA("Model") then
						table.insert(out, c)
					end
				end
			end
		end
		return out
	end
	local maxCars, seen3d = 0, false
	App.go("juego")
	for _ = 1, 40 do
		App.closeAllDialogs() -- las reseñas se abren solas al terminar un lote (y pausan la empresa)
		advance(1)
		local cars = garageCars()
		maxCars = math.max(maxCars, #cars)
		for _, c in cars do
			if c:GetAttribute("vehicleModel") == "pioneer70" then
				seen3d = true
				check(math.abs(minY(c) - c:GetPivot().Y) < 1e-3 and c:GetPivot().Y >= 0, "apoyado en su lugar del garaje")
				check(c:FindFirstChild("Body_Paint").CFrame.UpVector.Y > 0.999, "horizontal en el garaje")
				-- En el concesionario (pivote a 1,4: arriba de la plataforma) el auto entra en el círculo.
				if math.abs(c:GetPivot().Y - 1.4) < 1e-3 then
					local center = c:GetPivot().Position
					local far = 0
					for _, d in c:GetDescendants() do
						if d:IsA("BasePart") then
							local h = d.Size / 2
							for _, sx in { -1, 1 } do
								for _, sz in { -1, 1 } do
									local w = d.CFrame:PointToWorldSpace(M.Vector3.new(h.X * sx, 0, h.Z * sz))
									far = math.max(far, math.sqrt((w.X - center.X) ^ 2 + (w.Z - center.Z) ^ 2))
								end
							end
						end
					end
					check(far <= 10, "en el concesionario el auto entra en la plataforma (radio usado " .. string.format("%.2f", far) .. " de 10)")
				end
				check(c:FindFirstChildWhichIsA("LuaSourceContainer", true) == nil, "sin scripts en el garaje")
			end
		end
	end
	check(seen3d, "el sedán fabricado se ve con el Pioneer 70 en el garaje")
	check(maxCars <= 9, "nunca más de 9 autos por parcela (" .. maxCars .. ")")
	noErrors("Pioneer 70")
end)

test("Recorrido de jugador: elegir el sedán en el editor muestra el Pioneer 70 y se fabrica con él", function()
	local function find3d(root: any): { any }
		local out = {}
		for _, d in root:GetDescendants() do
			if d:IsA("Model") and d:GetAttribute("vehicleModel") == "pioneer70" then
				table.insert(out, d)
			end
		end
		return out
	end
	local function minY(m: any): number
		local y = math.huge
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				y = math.min(y, d.CFrame.Y - d.Size.Y / 2)
			end
		end
		return y
	end
	local gui = M.localPlayer:FindFirstChild("PlayerGui")
	-- 1) Editor nuevo: el jugador hace clic en la tarjeta «Brisa Sedán».
	App.go("editor", { new = true })
	M.task.wait()
	clickN("Base_brisa")
	M.task.wait()
	eq(App.ui.editor.draft.baseId, "brisa", "eligió el sedán")
	App.screens.editor.change(function(d)
		d.name = "Rojo Recorrido"
	end)
	App.screens.editor.sync3d()
	M.task.wait()
	-- La vista principal (la de comparación «antes/después» también muestra el sedán de partida).
	local inEditor = {}
	for _, m in find3d(gui) do
		local v = m:FindFirstAncestorWhichIsA("ViewportFrame")
		if v and v.Name == "Vista" then
			table.insert(inEditor, m)
		end
	end
	check(#inEditor == 1, "la vista 3D del editor muestra el Pioneer 70 (" .. #inEditor .. ")")
	local vp = inEditor[1] and inEditor[1]:FindFirstAncestorWhichIsA("ViewportFrame")
	print("    editor: modelo «" .. tostring(inEditor[1] and inEditor[1].Name) .. "» dentro de " .. tostring(vp and vp:GetFullName()))
	-- 2) Elige un color en Chasis › Carrocería y pintura y finaliza.
	clickN("Pestana_carroceria")
	check(named("Carroceria3D_pioneer70") ~= nil, "carrocería y pintura: la carrocería 3D elegida es el Pioneer 70")
	clickN("Pintura_Rojo carrera")
	M.task.wait()
	eq(App.ui.editor.draft.paint.primary, "#D6333F", "eligió «Rojo carrera»")
	App.screens.editor.sync3d()
	M.task.wait()
	local red = find3d(gui)[1]
	check(red ~= nil and red:FindFirstChild("Body_Paint").Color == M.Color3.fromHex("#D6333F"), "la vista 3D se repinta con el color elegido")
	check(finishDesign(), "diseño finalizado")
	local saved = App.g.designs[#App.g.designs]
	print("    guardado: «" .. saved.name .. "» · base " .. saved.baseId .. " · carrocería " .. tostring(saved.vehicleModel) .. " · color " .. saved.paint.primary)
	eq(saved.vehicleModel, "pioneer70", "el diseño guardado lleva el Pioneer 70")
	-- 3) Lanza un lote desde el diálogo de producción.
	App.ui.editor = nil
	App.closeAllDialogs()
	App.go("fabrica")
	M.task.wait()
	-- Capital de prueba en el servidor (las pruebas anteriores gastaron el de esta empresa).
	local inst = Sessions.instance
	local sess = inst and inst.list[player]
	sess.game.money = 2000000
	inst:push(sess)
	waitFor(function()
		return App.g.money == 2000000
	end)
	App.ui.lotDraft = nil
	App.openDialog("lot", { designId = saved.id })
	M.task.wait()
	clickN("ConfirmarLote")
	check(waitFor(function()
		for _, l in App.g.lots do
			if l.designId == saved.id then
				return true
			end
		end
		return false
	end), "lote lanzado")
	-- Volver a la vista de la sede: con el panel abierto la empresa estaría en pausa.
	App.go("juego")
	M.task.wait()
	-- 4) El garaje muestra el auto fabricado con el Pioneer 70, pintado y apoyado en el piso.
	-- Con una sola línea, el lote espera en cola a que termine el anterior (como en el juego real).
	local found = {}
	for _ = 1, 200 do
		if next(found) ~= nil and #App.g.lots > 0 and App.g.lots[#App.g.lots].produced >= 3 then
			break
		end
		App.closeAllDialogs() -- las reseñas se abren solas al terminar un lote (y pausan la empresa)
		advance(1)
		for _, c in find3d(M.services.Workspace) do
			local body = c:FindFirstChild("Body_Paint")
			if body and body.Color == M.Color3.fromHex("#D6333F") then
				local p = c:GetPivot()
				found[c] = string.format("%s · pivote (%.1f, %.2f, %.1f) · piso de las ruedas %.2f · %s", c.Parent and c.Parent.Parent and c.Parent.Parent.Name or "?", p.X, p.Y, p.Z, minY(c), body.Transparency > 0.3 and "en fabricación (semitransparente)" or "terminado")
			end
		end
	end
	for _, l in App.g.lots do
		print(string.format("    lote %s · %s · %s · fabricadas %d/%d · vendidas %d", l.id, l.design.name, l.prodState, l.produced, l.qty, l.sold))
	end
	for _, c in M.services.Workspace:GetDescendants() do
		if c:IsA("Model") and c.Name == "Auto" then
			local b = c:FindFirstChild("Body_Paint") or c:FindFirstChild("Carroceria")
			print("    auto en el mundo: " .. tostring(c:GetAttribute("vehicleModel")) .. " · color " .. (b and b.Color:ToHex() or "?"))
		end
	end
	local n = 0
	for _, line in found do
		n += 1
		print("    garaje: " .. line)
	end
	check(n >= 1, "el sedán rojo aparece en el garaje con el Pioneer 70")
	noErrors("Recorrido Pioneer 70")
end)

test("Fin de partida: expansión global, récords y años extra en las cuatro resoluciones", function()
	local function lateGame()
		local g = App.g
		g.sede = 5
		g.expansion = 2
		g.money = 900000000
		g.counters.unitsSold = 250000
		g.time.day = (2033 - 1970) * 12 + 4
		g.records = {
			firstModel = { name = "Primero de todos", key = "x#1", gen = 1, value = 0, day = 0 },
			bestLot = { name = "Récord con un nombre bastante largo", key = "y#2", gen = 2, value = 123456, day = 300 },
			bestLotProfit = { name = "Rentable", key = "y#2", gen = 2, value = 987654321, day = 300 },
			others = { models = 312, lots = 900, produced = 80000, sold = 70000, discarded = 10000, revenue = 5e8, cost = 3e8 },
		}
		for i = 1, 30 do
			table.insert(g.modelHistory, { key = "m" .. i .. "#1", lineage = "m" .. i, gen = 1, name = "Modelo histórico " .. i, modelYear = 1990, type = "sedan", compact = i % 2 == 0, spec = { baseId = "brisa", paint = { primary = "#AA3344" } }, stats = {}, lots = 3, produced = 1000 + i, sold = 900 + i, discarded = 0, revenue = 1e7, cost = 5e6, bestLotSold = 400, bestLotProfit = 1e6, bestMonth = 120, firstDay = 0, lastDay = 10 })
		end
	end
	for _, res in { { 1600, 900 }, { 1280, 720 }, { 844, 390 }, { 390, 844 } } do
		M.services.Workspace.CurrentCamera.ViewportSize = M.Vector2.new(res[1], res[2])
		M.task.wait()
		for _, route in { "compania", "autos", "juego", "mercado" } do
			lateGame()
			App.ui.tabs.autos = "historia"
			App.renderError = nil
			App.go(route)
			check(App.renderError == nil, route .. " (fin de partida) en " .. res[1] .. "×" .. res[2] .. (App.renderError and (": " .. tostring(App.renderError)) or ""))
			local bad = overflow()
			check(#bad == 0, route .. " (fin de partida) en " .. res[1] .. "×" .. res[2] .. " no se sale" .. (#bad > 0 and (": " .. bad[1]) or ""))
			if route == "compania" then
				check(named("Expansion") ~= nil and named("Pais_JP") ~= nil, "tarjeta y países para elegir")
			elseif route == "autos" then
				check(named("Records") ~= nil and M.find(App.content, "Otros 312 modelos") ~= nil, "récords permanentes y «Otros modelos»")
				check(named("MostrarMas") ~= nil, "la historia se muestra de a 20 modelos")
			elseif route == "juego" and App.layout ~= "phone" then
				check(M.find(root, "AÑO EXTRA") ~= nil, "el HUD indica el año comercial extra")
			end
		end
	end
	App.ui.tabs.autos = nil
	M.services.Workspace.CurrentCamera.ViewportSize = M.Vector2.new(1600, 900)
	M.task.wait()
	noErrors("Fin de partida")
end)

test("Etapa 1 en la interfaz: pausa con diálogos, guardar ahora, guardar y volver, ranuras bloqueadas", function()
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	App.go("juego")
	M.task.wait()
	App.request("setSpeed", { speed = 1 })
	local function stamp(): number
		return App.g.time.day * 100000 + App.g.time.minute
	end
	local t0 = stamp()
	advance(4)
	check(stamp() > t0, "en la sede el tiempo avanza")
	App.openDialog("settings", {})
	M.task.wait()
	check(App.menuPaused(), "un diálogo abierto pausa la empresa")
	t0 = stamp()
	advance(6)
	eq(stamp(), t0, "con el diálogo abierto no avanza")
	App.closeAllDialogs()
	M.task.wait()
	advance(4)
	check(stamp() > t0, "al cerrarlo continúa")
	check(find("PAUSA") == nil, "sin menú no figura en pausa")
	-- Compañía: guardar ahora y guardar y volver.
	App.go("compania")
	M.task.wait()
	check(named("GuardarAhora") ~= nil and find("Guardar y volver al menú") ~= nil, "botones de guardado")
	check(find("Deudas") ~= nil, "las deudas figuran en el resumen")
	clickN("GuardarAhora")
	M.task.wait()
	local date = Util.fullDate(App.g.time.day, App.g.time.minute)
	clickN("VolverMenu")
	check(waitFor(function()
		return App.g == nil and App.ui.route == "menu"
	end), "vuelve al menú sin salir del servidor")
	check(named("Bloqueada_3") ~= nil and named("Bloqueada_4") ~= nil, "las ranuras 3 y 4 se ven bloqueadas")
	check(named("Crear_3") == nil and named("Crear_4") == nil, "y no se pueden usar")
	-- La ranura 3 se desbloquea con Robux; sin producto configurado, el botón queda deshabilitado.
	App.ui.menuSel = "3"
	App.forceRender()
	M.task.wait()
	local buy = named("Comprar_3")
	check(buy ~= nil and buy:GetAttribute("disabled") == true, "compra de la ranura 3 deshabilitada mientras no esté configurada")
	App.ui.menuSel = nil
	App.request("selectSlot", { slot = "1" })
	check(waitFor(function()
		return App.g ~= nil
	end), "vuelve a abrir la empresa")
	eq(Util.fullDate(App.g.time.day, App.g.time.minute), date, "con la misma fecha")
	noErrors("Etapa 1")
end)

test("Etapa 3 en la interfaz: investigación por categorías, proyectos simultáneos, nivel de motor y equipamiento", function()
	local Catalog = require("./.build-ui/shared/Catalog")
	local Rules = require("./.build-ui/shared/Rules")
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	App.closeAllDialogs()
	App.ui.editor = nil
	-- PI y capital de prueba en el servidor.
	local inst = Sessions.instance
	local sess = inst.list[player]
	sess.game.money = 5000000
	sess.game.rp = 5000
	inst:push(sess)
	check(waitFor(function()
		return App.g.rp == 5000
	end), "PI de prueba")
	App.go("investigacion")
	M.task.wait()
	for _, key in { "chasis", "motores", "seguridad", "tecnologia" } do
		check(named("Pestana_" .. key) ~= nil, "pestaña " .. Catalog.RESEARCH[key].label)
	end
	check(named("PI") ~= nil and named("EnCurso") ~= nil, "panel de PI y de proyectos en curso")
	-- Una investigación disponible por categoría: se empiezan dos a la vez desde sus tarjetas.
	local started = {}
	for _, key in { "tecnologia", "seguridad" } do
		clickN("Pestana_" .. key)
		M.task.wait()
		local pick
		for _, n in Catalog.RESEARCH[key].nodes do
			if not pick and Rules.researchState(App.g, n) == "disponible" and Rules.researchAhead(App.g, n) == 0 then
				pick = n
			end
		end
		check(pick ~= nil, key .. ": hay una disponible")
		if pick then
			local card = named("Nodo_" .. pick.id)
			check(card ~= nil, key .. ": tarjeta de " .. pick.name)
			check(card and card:FindFirstChild("Costo", true) ~= nil, key .. ": muestra dinero, PI y días")
			clickN("Investigar_" .. pick.id)
			check(waitFor(function()
				return Rules.researchProject(App.g, pick.id) ~= nil
			end), key .. ": empieza " .. pick.name)
			table.insert(started, pick)
		end
	end
	eq(#App.g.research.projects, #started, "dos proyectos simultáneos")
	for _, n in started do
		check(named("Proyecto_" .. n.id) ~= nil, "en curso: " .. n.name)
	end
	-- Avanzan con el calendario y se completan.
	App.go("juego")
	M.task.wait()
	App.request("setSpeed", { speed = 3 })
	for _ = 1, 400 do
		advance(1)
		if #App.g.research.projects == 0 then
			break
		end
	end
	for _, n in started do
		check(Rules.has(App.g, n.id), "completada: " .. n.name)
	end
	App.request("setSpeed", { speed = 1 })
	App.go("investigacion")
	M.task.wait()
	check(find("COMPLETADAS") ~= nil, "sección de completadas")
	-- Editor: nivel de motor, variante y equipamiento (solo lo investigado).
	App.go("editor", { new = true, force = true })
	M.task.wait()
	if dialogOpen() then
		clickN("Descartar")
		M.task.wait()
	end
	App.screens.editor.goStep(2)
	M.task.wait()
	check(named("NivelMotor_1") ~= nil and named("VarianteMotor_balanced") ~= nil, "nivel y variante del motor")
	local anyEquip = false
	for _, stage in { 3, 4 } do
		App.screens.editor.goStep(stage)
		M.task.wait()
		for _, e in Catalog.EQUIPMENT do
			if (e.group == "seguridad") == (stage == 3) then
				check(named("Equipo_" .. e.id) ~= nil, "equipamiento: " .. e.name .. " en la etapa " .. stage)
				if Rules.equipmentUnlocked(App.g, e) and not anyEquip then
					anyEquip = true
					eq(#App.ui.editor.draft.equipment, 0, "no viene instalado")
					clickN("Equipo_" .. e.id)
					M.task.wait()
					eq(App.ui.editor.draft.equipment[1], e.id, "se elige " .. e.name)
				end
			end
		end
	end
	check(anyEquip, "hay equipamiento investigado para elegir")
	App.ui.editor = nil
	App.go("juego")
	M.task.wait()
	if dialogOpen() then
		clickN("Descartar")
	end
	noErrors("Etapa 3")
end)

test("Personal en la interfaz: departamentos, mercado laboral, contratar, detalle y capacitación", function()
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	App.closeAllDialogs()
	App.ui.editor = nil
	local inst = Sessions.instance
	local sess = inst.list[player]
	sess.game.money = 5000000
	inst:push(sess)
	waitFor(function()
		return App.g.money == 5000000
	end)
	App.ui.staff = nil
	App.go("personal")
	M.task.wait()
	for _, id in { "produccion", "investigacion", "marketing", "administracion" } do
		check(named("Tarjeta_" .. id) ~= nil, "tarjeta " .. id)
	end
	clickN("AbrirMercado")
	M.task.wait()
	local c = App.g.candidates[1]
	check(c ~= nil and named("Candidato_" .. c.id) ~= nil, "candidatos del mes")
	local before = #App.g.employees
	clickN("Contratar_" .. c.id)
	check(waitFor(function()
		return #App.g.employees == before + 1
	end), "contrata desde el mercado")
	local e = App.g.employees[#App.g.employees]
	eq(e.dept, c.spec, "en su especialidad por defecto")
	-- Búsqueda: pide confirmación antes de reemplazar.
	clickN("BusquedaGeneral")
	M.task.wait()
	eq(topKind(), "confirm", "confirma antes de reemplazar a los candidatos")
	clickN("Confirmar")
	check(waitFor(function()
		return App.g.market.searches >= 1
	end), "búsqueda hecha")
	-- Departamento: lista y detalle; capacitación con vista previa.
	App.ui.staff.view = "depto"
	App.ui.staff.dept = e.dept
	App.ui.staff.sel = e.id
	App.forceRender()
	M.task.wait()
	check(named("ListaEmpleados") ~= nil and named("Detalle_" .. e.id) ~= nil, "lista a la izquierda y detalle a la derecha")
	clickN("Capacitar_" .. e.id)
	M.task.wait()
	eq(topKind(), "training", "abre la capacitación")
	check(named("Participantes") ~= nil or find("potencial") ~= nil, "muestra participantes y resultado (o el motivo)")
	if named("Participantes") then
		clickN("EmpezarCapacitacion")
		check(waitFor(function()
			return #(App.g.trainings or {}) >= 1
		end), "capacitación en curso")
	end
	App.closeAllDialogs()
	clickN("Capacitaciones")
	M.task.wait()
	check(App.ui.staff.view == "capacitaciones", "vista de capacitaciones")
	App.go("juego")
	M.task.wait()
	noErrors("Personal")
end)

test("Marketing en la interfaz: nueva campaña con presupuesto y duración, cancelar sin reembolso", function()
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	App.closeAllDialogs()
	local inst = Sessions.instance
	local sess = inst.list[player]
	sess.game.money = 50000000
	sess.game.campaign = nil
	inst:push(sess)
	waitFor(function()
		return App.g.money == 50000000
	end)
	App.go("ventas")
	M.task.wait()
	clickN("NuevaCampana")
	M.task.wait()
	eq(topKind(), "campaign", "abre el diálogo")
	clickN("Tipo_corporativa")
	clickN("Presupuesto_2")
	clickN("Dias_60")
	M.task.wait()
	check(named("Precios") ~= nil, "muestra costo y efecto antes de pagar")
	local m0 = App.g.money
	clickN("LanzarCampana")
	check(waitFor(function()
		return App.g.campaign ~= nil
	end), "campaña activa")
	eq(App.g.campaign.days, 60, "60 días")
	check(App.g.money < m0, "pagada al empezar")
	check(named("CancelarCampana") ~= nil, "se puede cancelar")
	clickN("CancelarCampana")
	M.task.wait()
	clickN("Confirmar")
	check(waitFor(function()
		return App.g.campaign == nil
	end), "cancelada")
	check(named("NuevaCampana") ~= nil, "y se puede empezar otra")
	App.go("juego")
	M.task.wait()
	noErrors("Marketing")
end)

test("Instalaciones en la interfaz: obra de la línea 2 con confirmación, avance y línea 3 sin compra configurada", function()
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	App.closeAllDialogs()
	local inst = Sessions.instance
	local sess = inst.list[player]
	sess.game.money = 5000000
	sess.game.facilities.lines["2"] = nil
	sess.game.facilities.builds = {}
	inst:push(sess)
	waitFor(function()
		return App.g.money == 5000000
	end)
	App.go("compania")
	M.task.wait()
	for _, k in { "offices", "factory", "research", "line2", "line3" } do
		check(named("Instalacion_" .. k) ~= nil, "tarjeta " .. k)
	end
	local b3 = named("ComprarLinea3")
	check(b3 ~= nil, "la línea 3 ofrece la compra con Robux")
	clickN("Mejorar_line2")
	M.task.wait()
	eq(topKind(), "confirm", "confirma antes de pagar")
	clickN("Confirmar")
	check(waitFor(function()
		return #App.g.facilities.builds == 1
	end), "obra en curso")
	App.go("juego")
	App.request("setSpeed", { speed = 3 })
	for _ = 1, 60 do
		advance(1)
		if App.g.facilities.lines["2"] then
			break
		end
	end
	check(App.g.facilities.lines["2"] == true, "la línea 2 quedó construida")
	eq(App.g.derived.caps.lines, 2, "dos líneas")
	App.request("setSpeed", { speed = 1 })
	noErrors("Instalaciones")
end)

test("Escenario sin personaje: la cámara orbita sobre el garaje con zoom y rotación", function()
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	App.closeAllDialogs()
	App.go("juego")
	M.task.wait()
	local center = player:GetAttribute("PlotCenter")
	check(M.typeof(center) == "Vector3", "el servidor publica el centro del garaje")
	check(M.services.Players.CharacterAutoLoads == false, "no se crea un personaje para caminar")
	local SceneCamera = require("./.build-ui/client/SceneCamera")
	local cam = M.services.Workspace.CurrentCamera
	M.services.RunService.RenderStepped:Fire(1 / 60)
	local d0 = (cam.CFrame.Position - center).Magnitude
	check(d0 > 10, "cámara del escenario a distancia del garaje (" .. math.floor(d0) .. ")")
	SceneCamera.zoom(0.5)
	M.services.RunService.RenderStepped:Fire(1 / 60)
	check((cam.CFrame.Position - center).Magnitude < d0, "zoom: se acerca")
	local p0 = cam.CFrame.Position
	SceneCamera.rotate(120, 0)
	M.services.RunService.RenderStepped:Fire(1 / 60)
	check((cam.CFrame.Position - p0).Magnitude > 1, "rotación: gira alrededor del garaje")
	SceneCamera.zoom(2)
	noErrors("Cámara del escenario")
end)

test("Showroom 3D del menú: escenario persistente, transición entre empresas, cámara con arrastre y zoom, y limpieza", function()
	local Showroom = App.screens.showroom
	local st = Showroom._state
	local C = Showroom.CONFIG
	local UIS = M.services.UserInputService
	-- Dos empresas con colores distintos.
	App.closeAllDialogs()
	if App.g then
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
	end
	local slots = App.profile.slots
	if not slots["2"] then
		App.request("createCompany", { slot = "2", name = "Showroom Dos", color = "#FF8A3D", logo = "rayo" })
		waitFor(function()
			return App.g ~= nil
		end)
		if App.screens.intro.active() then
			App.screens.intro.finish()
		end
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
	end
	App.go("menu")
	M.task.wait()
	slots = App.profile.slots
	check(slots["1"] ~= nil and slots["2"] ~= nil, "dos empresas en el menú")
	local function stage(): any
		return st.stage
	end
	local function cars(): number
		local n = 0
		for _, c in stage():GetChildren() do
			if c.ClassName == "Model" then
				n += 1
			end
		end
		return n
	end
	local maxCars = 0
	local function step(seconds: number)
		for _ = 1, math.ceil(seconds * 30) do
			Showroom.update(1 / 30)
			maxCars = math.max(maxCars, cars())
		end
	end
	local function near(a: any, hex: string): boolean
		local b = M.Color3.fromHex(hex)
		return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B) < 0.02
	end
	check(Showroom.isVisible(), "el showroom se ve en el menú")
	local ambient0 = st.savedLighting and st.savedLighting.Ambient
	check(st.savedLighting ~= nil, "ambiente global oscurecido mientras se ve el showroom")
	check(stage() ~= nil and stage().Parent == M.services.Workspace, "escenario en el Workspace del cliente")
	check(stage():FindFirstChild("Piso") and stage():FindFirstChild("Plataforma") and stage():FindFirstChild("Techo"), "piso, plataforma y sala cerrada")
	local spots = 0
	for _, d in stage():GetDescendants() do
		if d.ClassName == "SpotLight" then
			spots += 1
		end
	end
	eq(spots, 3, "luz principal, de relleno y de contorno")
	-- Empresa 1.
	App.ui.menuSel = "1"
	App.forceRender()
	step(1.3)
	eq(cars(), 1, "un solo auto en la plataforma")
	check(near(st.accent, slots["1"].color), "luces de acento con el color de la empresa 1")
	local m1 = st.current and st.current.model
	check(m1 ~= nil, "auto de la empresa 1")
	local p = m1 and (m1:FindFirstChildWhichIsA("BasePart", true) :: any)
	check(p ~= nil and p.Anchored == true and p.CanCollide == false, "el auto queda quieto (anclado y sin colisiones)")
	-- El Pioneer 70 viene con el frente hacia +Z: la plantilla lo gira y la vista inicial muestra el frente.
	local fb, rb = m1 and m1:FindFirstChild("FrontBumper_Chrome", true), m1 and m1:FindFirstChild("RearBumper_Chrome", true)
	if fb and rb then
		check(fb.CFrame.Position.Z < rb.CFrame.Position.Z, "frente del auto hacia −Z (como el resto de los modelos)")
		local camPos = M.services.Workspace.CurrentCamera.CFrame.Position
		check((fb.CFrame.Position - camPos).Magnitude < (rb.CFrame.Position - camPos).Magnitude, "la vista inicial de tres cuartos muestra el frente")
		local tire = m1:FindFirstChild("Wheel_FL_Tire", true)
		local plat = stage():FindFirstChild("Plataforma")
		check(tire and plat and math.abs((tire.CFrame.Position.Y - tire.Size.Y / 2) - (plat.CFrame.Position.Y + plat.Size.X / 2)) < 0.15, "las ruedas apoyan sobre la plataforma")
	else
		check(false, "el auto exhibido es el Pioneer 70")
	end
	local wrap = named("MenuWrap")
	check(wrap ~= nil and wrap.ScrollBarThickness == 0, "en PC no hay barra de desplazamiento en medio de la escena")
	-- Luces según el tamaño real del auto: fuera de la carrocería; las de acento no llegan al auto.
	for _, name in { "LuzPrincipal", "LuzRelleno", "LuzContorno" } do
		local h = stage():FindFirstChild(name)
		check(h ~= nil and (h.CFrame.Position - st.target).Magnitude > st.radius * 1.5, name .. " fuera del auto")
	end
	for _, h in stage():GetChildren() do
		if h.Name == "Acento" then
			local l = h:FindFirstChildWhichIsA("PointLight")
			check(l ~= nil and (h.CFrame.Position - st.target).Magnitude - st.radius > l.Range, "la luz de acento no alcanza la pintura del auto")
		end
	end
	-- Redibujar la misma empresa no rearma nada.
	App.forceRender()
	step(0.5)
	check(st.current and st.current.model == m1, "mismo auto al redibujar")
	-- Cambio de empresa: transición de 0,8–1,2 s.
	maxCars = 0
	App.ui.menuSel = "2"
	App.forceRender()
	step(0.3)
	check(st.phase ~= nil, "transición en curso")
	step(1.0)
	eq(st.phase, nil, "transición terminada en menos de 1,3 s")
	eq(cars(), 1, "un solo auto al final")
	check(maxCars <= 2, "nunca más de dos autos durante la transición (" .. maxCars .. ")")
	check(near(st.accent, slots["2"].color), "el color de acento cambió al de la empresa 2")
	check(st.current and st.current.model ~= m1, "auto de la empresa 2")
	-- Cambios rápidos: se cancela la transición anterior sin acumular autos.
	maxCars = 0
	for i = 1, 8 do
		App.ui.menuSel = i % 2 == 0 and "1" or "2"
		App.forceRender()
		step(0.1)
	end
	step(1.5)
	check(maxCars <= 2, "cambios rápidos: como máximo dos autos (" .. maxCars .. ")")
	eq(cars(), 1, "queda uno")
	check(near(st.accent, slots["1"].color), "y es el de la última empresa elegida")
	-- La interfaz tiene prioridad: un clic que usó una tarjeta no mueve la cámara.
	local function input(kind: string, pos: any): any
		return { UserInputType = M.Enum.UserInputType[kind], Position = pos }
	end
	UIS.InputBegan:Fire(input("MouseButton1", M.Vector3.new(100, 100, 0)), true)
	check(not st.dragging, "clic sobre la interfaz: sin arrastre")
	-- Arrastre sobre el área libre.
	local yaw0 = st.tYaw
	UIS.InputBegan:Fire(input("MouseButton1", M.Vector3.new(900, 400, 0)), false)
	check(st.dragging, "arrastre sobre el área libre")
	for i = 1, 30 do
		UIS.InputChanged:Fire(input("MouseMovement", M.Vector3.new(900 + i * 40, 400 + i * 40, 0)), false)
		step(1 / 30)
	end
	check(st.tYaw ~= yaw0, "rota alrededor del auto")
	check(st.tPitch <= C.pitchMax + 1e-6 and st.tPitch >= C.pitchMin - 1e-6, "límites verticales")
	UIS.InputEnded:Fire(input("MouseButton1", M.Vector3.new(0, 0, 0)), false)
	check(not st.dragging, "suelta")
	-- Zoom con la rueda, con límites según el tamaño del auto.
	for _ = 1, 40 do
		UIS.InputChanged:Fire(input("MouseWheel", M.Vector3.new(0, 0, 1)), false)
	end
	step(1)
	check(st.tDist >= st.distMin - 1e-6, "no se acerca más que la distancia mínima")
	check(st.distMin >= st.radius * 1.29, "la distancia mínima deja la cámara fuera de la carrocería")
	local cam = M.services.Workspace.CurrentCamera
	check((cam.CFrame.Position - st.target).Magnitude >= st.distMin * 0.9, "la cámara no atraviesa el auto")
	check(cam.CFrame.Position.Y >= C.origin.Y + 0.5 - 1e-6, "ni el piso")
	for _ = 1, 60 do
		UIS.InputChanged:Fire(input("MouseWheel", M.Vector3.new(0, 0, -1)), false)
	end
	check(st.tDist <= st.distMax + 1e-6 and st.distMax <= C.room - 6 + 1e-6, "ni se aleja más que la máxima (dentro de la sala)")
	-- Sin interacción vuelve de a poco a la órbita cinematográfica.
	step(C.idleDelay + C.returnTime + 6)
	eq(st.blend, 1, "órbita recuperada")
	check(math.abs(st.pitch - C.pitchDefault) < 1, "altura predeterminada")
	check(math.abs(st.dist - st.distDefault) < 0.5, "encuadre predeterminado (" .. Util.num(st.dist, 2) .. " / " .. Util.num(st.distDefault, 2) .. " · " .. Util.num(st.distMin, 2) .. "–" .. Util.num(st.distMax, 2) .. ")")
	local yawA = st.yaw
	step(1)
	check(st.yaw > yawA, "órbita lenta en marcha")
	-- Sin información flotante sobre el auto.
	local floating = 0
	for _, d in stage():GetDescendants() do
		if d.ClassName == "BillboardGui" or d.ClassName == "SurfaceGui" or d.ClassName == "TextLabel" then
			floating += 1
		end
	end
	eq(floating, 0, "sin carteles ni textos en el escenario")
	-- Fuera del menú no trabaja.
	App.request("selectSlot", { slot = "1" })
	check(waitFor(function()
		return App.g ~= nil
	end), "entra a una empresa")
	M.task.wait()
	check(not Showroom.isVisible() and stage().Parent == nil, "fuera del menú el escenario sale del Workspace")
	check(M.services.Lighting.Ambient == ambient0, "y la iluminación global vuelve a la del lugar")
	check(M.services.Workspace.CurrentCamera.FieldOfView ~= C.fov, "y la cámara recupera su campo de visión")
	local clock = st.clock
	Showroom.update(1)
	eq(st.clock, clock, "y no se actualiza")
	-- Conexiones: una por evento, sin duplicarse; se liberan todas.
	eq(Showroom.connectionCount(), 5, "cinco conexiones (cuadro, entrada ×3 y pérdida de foco)")
	Showroom.start()
	eq(Showroom.connectionCount(), 5, "iniciar dos veces no duplica")
	Showroom.destroy()
	eq(Showroom.connectionCount(), 0, "destroy libera las conexiones")
	check(st.stage == nil and st.current == nil, "y el escenario y los autos")
	Showroom.start()
	App.go("juego")
	M.task.wait()
	noErrors("Showroom")
end)

test("Showroom: una sola cámara activa, luz del lugar restaurada, prioridad de la interfaz, plataforma y transiciones", function()
	local Showroom = App.screens.showroom
	local SceneCamera = require("./.build-ui/client/SceneCamera")
	local DesignCalc = require("./.build-ui/shared/DesignCalc")
	local st = Showroom._state
	local C = Showroom.CONFIG
	local UIS = M.services.UserInputService
	local cam = M.services.Workspace.CurrentCamera
	local Lighting = M.services.Lighting
	App.closeAllDialogs()
	-- Iluminación del lugar conocida (para comprobar que se restaura exacta).
	Lighting.Ambient = M.Color3.fromRGB(120, 120, 130)
	Lighting.OutdoorAmbient = M.Color3.fromRGB(128, 128, 128)
	Lighting.Brightness = 2
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 1
	Lighting.FogEnd = 500
	local atm = M.Instance.new("Atmosphere")
	atm.Density = 0.3
	atm.Haze = 1
	atm.Glare = 0.2
	atm.Parent = Lighting
	-- 1. Con una empresa abierta, la cámara es de la gestión.
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	App.go("juego")
	M.task.wait()
	eq(App.cameraOwner, "scene", "en el juego la cámara es de la gestión")
	check(not Showroom.isVisible(), "el showroom no se ve")
	SceneCamera.update(1 / 60)
	local center = player:GetAttribute("PlotCenter")
	local before = cam.CFrame.Position
	Showroom.update(1 / 60)
	check(cam.CFrame.Position == before, "el showroom no toca la cámara durante el juego")
	-- 2. Volver al menú con la empresa todavía cargada (el instante de «Guardar y volver al menú»).
	App.ui.enteringGame = false
	App.ui.route = "menu"
	App.forceRender()
	M.task.wait()
	check(App.g ~= nil, "la empresa sigue cargada en este instante")
	eq(App.cameraOwner, "showroom", "pero la cámara ya es del showroom")
	check(Showroom.isVisible(), "el showroom recupera el control")
	Showroom.update(1 / 30)
	local p0 = cam.CFrame.Position
	SceneCamera.update(1 / 60)
	check(cam.CFrame.Position == p0, "la cámara de gestión no la mueve mientras se ve el showroom")
	check((p0 - st.target).Magnitude < 200 and (p0 - center).Magnitude > 200, "la cámara mira al showroom, no al garaje")
	-- Iluminación durante el showroom: sol, cielo y niebla apagados; color y luces propias intactas.
	eq(Lighting.Brightness, 0, "sin sol")
	eq(Lighting.EnvironmentDiffuseScale, 0, "sin luz difusa del cielo")
	check(Lighting.FogEnd >= 100000 and atm.Density == 0, "sin niebla ni atmósfera")
	local spots = 0
	for _, d in st.stage:GetDescendants() do
		if d.ClassName == "SpotLight" then
			spots += 1
		end
	end
	eq(spots, 3, "luz principal, relleno y contorno siguen")
	-- La sala bloquea el sol: techo, paredes, junturas y muro exterior proyectan sombra.
	local blocking = 0
	for _, d in st.stage:GetChildren() do
		if d.Name == "Techo" or d.Name == "Panel" or d.Name == "Juntura" or d.Name == "Muro" or d.Name == "Piso" then
			check(d.CastShadow ~= false, d.Name .. " proyecta sombra")
			blocking += 1
		end
	end
	check(blocking >= 1 + 1 + 40 + 40 + 4, "sala cerrada completa (" .. blocking .. " piezas)")
	-- 3. Volver al juego: la luz del lugar vuelve exacta y la cámara es de la gestión otra vez.
	App.go("juego")
	M.task.wait()
	eq(App.cameraOwner, "scene", "al continuar la partida la cámara vuelve a la gestión")
	check(Lighting.Ambient == M.Color3.fromRGB(120, 120, 130) or (Lighting.Ambient.R > 0.46 and Lighting.Ambient.R < 0.48), "ambiente restaurado")
	eq(Lighting.Brightness, 2, "sol restaurado")
	eq(Lighting.EnvironmentDiffuseScale, 1, "cielo restaurado")
	eq(Lighting.EnvironmentSpecularScale, 1, "reflejos restaurados")
	eq(Lighting.FogEnd, 500, "niebla restaurada")
	check(atm.Density == 0.3 and atm.Haze == 1 and atm.Glare == 0.2, "atmósfera restaurada")
	SceneCamera.update(1 / 60)
	check((cam.CFrame.Position - center).Magnitude < 400, "la cámara vuelve al garaje")
	-- 4. Menú de nuevo para las pruebas de entrada y plataforma.
	App.request("leaveCompany", {})
	waitFor(function()
		return App.g == nil
	end)
	App.ui.route = "menu"
	App.forceRender()
	M.task.wait()
	check(Showroom.isVisible() and App.cameraOwner == "showroom", "menú: showroom")
	local function input(kind: string, pos: any): any
		return { UserInputType = M.Enum.UserInputType[kind], Position = pos }
	end
	local card = named("Ranura_1") or named("Elegir_2")
	local scroller = named("MenuWrap")
	local original = Showroom.hitTest
	-- Clic sobre una tarjeta (un Frame sin Active: `processed` llega en false) no rota.
	Showroom.hitTest = function()
		return { card }
	end
	UIS.InputBegan:Fire(input("MouseButton1", M.Vector3.new(200, 200, 0)), false)
	check(card ~= nil and not st.dragging, "arrastrar sobre una tarjeta no rota la cámara")
	-- Rueda sobre la lista desplazable: no hay zoom.
	Showroom.hitTest = function()
		return { scroller }
	end
	local d0 = st.tDist
	UIS.InputChanged:Fire(input("MouseWheel", M.Vector3.new(200, 200, 1)), false)
	eq(st.tDist, d0, "la rueda sobre la lista no hace zoom")
	-- Área libre: arrastre y zoom; perder el foco cancela el arrastre.
	Showroom.hitTest = function()
		return {}
	end
	UIS.InputBegan:Fire(input("MouseButton1", M.Vector3.new(1200, 400, 0)), false)
	check(st.dragging, "arrastre sobre el área libre")
	UIS.WindowFocusReleased:Fire()
	check(not st.dragging, "al perder el foco se cancela el arrastre")
	UIS.InputChanged:Fire(input("MouseWheel", M.Vector3.new(1200, 400, 1)), false)
	check(st.tDist < d0 and st.tDist >= st.distMin, "zoom sobre el área libre, dentro del límite")
	Showroom.hitTest = original
	-- 5. Plataforma y anillo con otro auto (el modelo provisional por piezas).
	local fake = { time = { day = 300, minute = 0 }, research = { done = {}, projects = {} }, company = { name = "x" }, devPaid = {}, facilities = { factory = 1, research = 1, lines = {}, builds = {} } }
	local spec = DesignCalc.newDraft(fake, "pixel")
	spec.vehicleModel = "provisional"
	Showroom.show(spec, "#42E58D", "prueba")
	for _ = 1, 45 do
		Showroom.update(1 / 30)
	end
	local plat, ring = st.stage:FindFirstChild("Plataforma"), st.stage:FindFirstChild("Anillo")
	local floorTop = C.origin.Y
	local platTop = plat.CFrame.Position.Y + plat.Size.X / 2
	check(math.abs(plat.CFrame.Position.Y - plat.Size.X / 2 - floorTop) < 1e-6, "la plataforma apoya en el piso")
	check(ring.CFrame.Position.Y - ring.Size.X / 2 > floorTop, "el anillo queda sobre el piso (no enterrado)")
	check(ring.Size.Y > plat.Size.Y + 1, "el anillo sobresale de la plataforma")
	check(math.abs(ring.CFrame.Position.X - plat.CFrame.Position.X) < 1e-6 and math.abs(ring.CFrame.Position.Z - plat.CFrame.Position.Z) < 1e-6, "plataforma y anillo alineados")
	local lowest = math.huge
	for p in st.current.parts do
		lowest = math.min(lowest, p.CFrame.Position.Y - p.Size.Y / 2)
	end
	check(math.abs(lowest - platTop) < 0.4, "el auto provisional apoya sobre la plataforma (" .. string.format("%.2f", lowest - platTop) .. ")")
	-- 6. Ocultar a mitad de una transición no deja autos invisibles ni animaciones colgadas.
	App.ui.menuSel = "1"
	App.forceRender()
	Showroom.update(0.2)
	check(st.outgoing ~= nil, "transición a medias")
	App.ui.route = "nueva" -- sale del menú principal (sin empresa abierta: pantalla de creación)
	App.forceRender()
	M.task.wait()
	check(not Showroom.isVisible() and App.cameraOwner == nil, "fuera del menú nadie controla la cámara")
	check(st.outgoing == nil, "al ocultarse se libera el auto que salía")
	local models = 0
	for _, c in st.stage:GetChildren() do
		if c.ClassName == "Model" then
			models += 1
		end
	end
	check(models <= 1, "como mucho un auto guardado")
	App.ui.route = "menu"
	App.forceRender()
	M.task.wait()
	for _ = 1, 45 do
		Showroom.update(1 / 30)
	end
	check(st.phase == nil and st.current ~= nil and string.find(st.current.sig, "^1|") ~= nil, "al volver se ve el auto de la última empresa elegida")
	-- 7. «Reducir movimiento»: sin órbita automática ni transiciones; la interfaz sigue igual.
	local prof = App.payload.profile.settings or {}
	App.payload.profile.settings = prof
	prof.reduceMotion = true
	App.forceRender()
	M.task.wait()
	check(st.reduce, "modo reducido activo")
	local yaw0 = st.tYaw
	for _ = 1, 90 do
		Showroom.update(1 / 30)
	end
	eq(st.tYaw, yaw0, "sin órbita automática")
	App.ui.menuSel = "2"
	App.forceRender()
	check(st.phase == nil and string.find(st.current.sig, "^2|") ~= nil, "cambio de empresa sin animación")
	local accent = st.accent
	check(math.abs(accent.R - M.Color3.fromHex(App.profile.slots["2"].color).R) < 0.01, "color sin transición")
	check(named("Elegir_1") ~= nil, "las tarjetas siguen funcionando")
	prof.reduceMotion = false
	App.forceRender()
	atm:Destroy()
	noErrors("Correcciones del showroom")
end)

test("Menú: cuatro tarjetas de empresas, la elegida expandida, acciones según el espacio y una sola animación", function()
	local Menu = App.screens.menu
	local Showroom = App.screens.showroom
	local st = Showroom._state
	local Catalog = require("./.build-ui/shared/Catalog")
	local Util = require("./.build-ui/shared/Util")
	-- Empresa pedida al showroom (la que muestra o la que está por mostrar) y su color de acento.
	local function shownKey(): string?
		local sig = st.pending and st.pending.sig or (st.current and st.current.sig)
		return sig and string.match(sig, "^([^|]*)|") or nil
	end
	local function accentIs(hex: string): boolean
		local a, b = st.accentTo or st.accent, M.Color3.fromHex(hex)
		return a ~= nil and math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B) < 0.02
	end
	App.closeAllDialogs()
	if App.g then
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
	end
	App.ui.enteringGame = false
	App.ui.menuSel = "1"
	App.ui.route = "menu"
	App.forceRender()
	M.task.wait()
	local slots = App.profile.slots
	-- 1–3. Cuatro espacios: dos gratuitos y dos que se desbloquean por separado.
	eq(Catalog.RULES.slots, 4, "cuatro espacios")
	eq(Catalog.RULES.slotsFree, 2, "dos gratuitos")
	for i = 1, 4 do
		check(named("Espacio_" .. i) ~= nil, "existe el espacio " .. i)
	end
	check(slots["1"] ~= nil and slots["2"] ~= nil, "los espacios 1 y 2 tienen empresa")
	eq(Menu.slotState("3"), "locked", "el 3 está bloqueado")
	eq(Menu.slotState("4"), "locked", "el 4 está bloqueado")
	check(named("Bloqueada_3") ~= nil and named("Bloqueada_4") ~= nil, "con candado")
	check(find("Espacio adicional · bloqueado") ~= nil, "texto «Espacio adicional» y estado bloqueado")
	-- 4–8. Empresa elegida: datos, tamaño y acciones.
	local compactH, expandedH = Menu.heights()
	local function height(i: number): number
		return named("Espacio_" .. i).Size.Y.Offset
	end
	local s1 = slots["1"]
	local card = named("Ranura_1")
	check(card ~= nil, "la tarjeta 1 está expandida")
	check(M.find(card, s1.name) ~= nil, "muestra el nombre")
	check(M.find(card, "Año " .. tostring(s1.year)) ~= nil, "muestra el año de la partida")
	check(M.find(card, Util.money(s1.money)) ~= nil, "muestra el dinero")
	check(s1.lastModel ~= nil and M.find(card, s1.lastModel) ~= nil, "muestra el último vehículo creado (" .. tostring(s1.lastModel) .. ")")
	check(M.find(card, "Reputación") == nil and M.find(card, "Empleados") == nil and M.find(card, "Tiempo jugado") == nil, "sin datos de más")
	local stroke = card:FindFirstChildOfClass("UIStroke")
	check(stroke ~= nil and stroke.Color == M.Color3.fromHex(s1.color), "borde con el color corporativo")
	check(card.BackgroundColor3 ~= M.Color3.fromHex(s1.color) and card.BackgroundTransparency > 0, "sin pintar la tarjeta entera")
	eq(height(1), expandedH, "la elegida mide lo expandido")
	for i = 2, 4 do
		eq(height(i), compactH, "la " .. i .. " queda compacta")
	end
	local c2 = named("Elegir_2")
	check(c2 ~= nil and M.find(c2, slots["2"].name) ~= nil and M.find(c2, "Año " .. tostring(slots["2"].year)) ~= nil, "la compacta muestra logo, nombre y año")
	check(M.find(c2, Util.money(slots["2"].money)) == nil, "la compacta no muestra el dinero")
	check(named("Continuar_1") ~= nil and named("Renombrar_1") ~= nil and named("Eliminar_1") ~= nil, "empresa: Continuar, renombrar y eliminar")
	check(named("Crear_1") == nil and named("Comprar_1") == nil, "sin acciones de otro tipo")
	check(shownKey() == "1" and accentIs(s1.color), "el showroom recibió la empresa 1 y su color")
	-- El último vehículo es el diseño más reciente (las plantillas no cuentan) y sin diseños no hay ninguno.
	local GameState = require("./.build-ui/server/GameState")
	local g1 = Util.deepCopy(Sessions.instance.list[player].profile.slots["1"])
	table.insert(g1.designs, { id = "plantilla", name = "Plantilla X", template = true, createdDay = g1.time.day + 1 })
	eq(GameState.summary(g1).lastModel, s1.lastModel, "una plantilla no cuenta como vehículo creado")
	g1.designs = {}
	eq(GameState.summary(g1).lastModel, nil, "sin diseños: sin último vehículo")
	-- Eliminar pide confirmación.
	clickN("Eliminar_1")
	M.task.wait()
	check(#App.ui.dialogs == 1 and App.profile.slots["1"] ~= nil, "eliminar pide confirmación antes de borrar")
	App.closeAllDialogs()
	-- 9. Cambiar de empresa: una sola animación por tarjeta que cambia de tamaño (la nueva y la anterior).
	local TS = M.services.TweenService
	local orig = TS.Create
	local tweens = {}
	TS.Create = function(self, inst, info, props)
		if string.sub(inst.Name, 1, 8) == "Espacio_" then
			table.insert(tweens, { name = inst.Name, time = info and info.Time, to = props.Size })
		end
		return orig(self, inst, info, props)
	end
	clickN("Elegir_2")
	M.task.wait()
	eq(App.ui.menuSel, "2", "el clic elige la empresa 2")
	eq(#tweens, 2, "dos animaciones: la que se expande y la que se compacta")
	local names = {}
	for _, t in tweens do
		names[t.name] = t.to.Y.Offset
		check(t.time == nil or (t.time >= 0.2 and t.time <= 0.35), "duración entre 0,2 y 0,35 s")
	end
	check(names.Espacio_2 == expandedH and names.Espacio_1 == compactH, "la nueva se expande y la anterior se compacta")
	check(M.find(named("Ranura_2"), slots["2"].lastModel or "Sin vehículos creados") ~= nil, "empresa 2: último vehículo o «Sin vehículos creados»")
	check(shownKey() == "2" and accentIs(slots["2"].color), "el showroom recibió la empresa 2 y su color (su transición es la única del auto)")
	-- Redibujar sin cambiar la selección no anima nada.
	table.clear(tweens)
	App.forceRender()
	M.task.wait()
	eq(#tweens, 0, "redibujar la misma selección no anima")
	-- Elegir la misma tarjeta otra vez no redibuja.
	table.clear(tweens)
	Menu.select("2")
	eq(#tweens, 0, "elegir la ya elegida no hace nada")
	-- 10. Cambios rápidos: sin errores ni animaciones acumuladas; queda la última.
	for i = 1, 12 do
		table.clear(tweens)
		Menu.select(tostring((i % 4) + 1))
		check(#Menu._running <= 2, "nunca más de dos animaciones a la vez")
	end
	M.task.wait()
	eq(App.ui.menuSel, "1", "queda la última elegida")
	eq(shownKey(), "1", "y el showroom muestra esa")
	eq(height(1), expandedH, "expandida")
	TS.Create = orig
	-- Espacio bloqueado elegido: «Desbloquear» (deshabilitado mientras el producto no tenga id).
	Menu.select("3")
	M.task.wait()
	local buy = named("Comprar_3")
	check(buy ~= nil and buy:GetAttribute("label") == "Desbloquear", "bloqueado: acción «Desbloquear»")
	eq(buy:GetAttribute("disabled"), Catalog.PRODUCTS.slot3.id == 0, "sin producto configurado queda deshabilitado")
	check(named("NotaCompra") ~= nil or Catalog.PRODUCTS.slot3.id ~= 0, "y lo dice")
	check(named("Continuar_3") == nil and named("Crear_3") == nil, "sin continuar ni crear")
	-- Desbloqueo individual (como lo deja la compra): el 3 pasa a ser un espacio libre, el 4 sigue bloqueado.
	local sess = Sessions.instance.list[player]
	sess.profile.unlocked = sess.profile.unlocked or {}
	sess.profile.unlocked["3"] = true
	Sessions.instance:push(sess)
	M.task.wait()
	eq(Menu.slotState("3"), "empty", "desbloqueado, el 3 es un espacio libre")
	eq(Menu.slotState("4"), "locked", "el 4 sigue bloqueado")
	local create = named("Crear_3")
	check(create ~= nil and create:GetAttribute("label") == "Crear empresa", "libre: acción «Crear empresa»")
	check(find("Espacio 3 · disponible") ~= nil, "con la indicación de disponible")
	clickN("Crear_3")
	eq(App.ui.route, "nueva", "abre el formulario de nombre, símbolo y color existente")
	eq(App.ui.newCompany.slot, "3", "para el espacio 3")
	App.go("menu")
	M.task.wait()
	sess.profile.unlocked["3"] = nil
	Sessions.instance:push(sess)
	M.task.wait()
	eq(Menu.slotState("3"), "locked", "vuelve a quedar bloqueado")
	-- Enter continúa la empresa elegida (no la primera de la lista) y no abre compras.
	Menu.select("4")
	Menu.enterKey()
	M.task.wait()
	check(App.g == nil and App.ui.route == "menu", "Enter sobre un espacio bloqueado no hace nada")
	-- «Reducir movimiento»: el cambio de tarjeta es instantáneo.
	local prof = App.payload.profile.settings or {}
	App.payload.profile.settings = prof
	prof.reduceMotion = true
	App.forceRender()
	tweens = {}
	TS.Create = function(self, inst, info, props)
		if string.sub(inst.Name, 1, 8) == "Espacio_" then
			table.insert(tweens, inst.Name)
		end
		return orig(self, inst, info, props)
	end
	Menu.select("2")
	eq(#tweens, 0, "sin animación con «Reducir movimiento»")
	eq(height(2), expandedH, "y la tarjeta ya está expandida")
	TS.Create = orig
	prof.reduceMotion = false
	App.forceRender()
	-- 12. El resto del menú sigue: configuración, novedades y demostraciones.
	check(named("Configuracion") ~= nil and named("Novedades") ~= nil and named("Demostraciones") ~= nil, "configuración, novedades y demostraciones")
	clickN("Novedades")
	M.task.wait()
	eq(#App.ui.dialogs, 1, "novedades abre su diálogo")
	App.closeAllDialogs()
	clickN("Demostraciones")
	check(M.find(App.dropLayer, "Demo: garaje") ~= nil, "la lista de demostraciones se abre")
	for _, c in App.dropLayer:GetChildren() do
		c:Destroy()
	end
	-- Renombrar en la tarjeta expandida.
	clickN("Renombrar_2")
	check(named("NombreRanura") ~= nil and Menu.isRenaming(), "renombrar edita el nombre en la tarjeta")
	Menu.cancelRename()
	check(named("NombreEmpresa") ~= nil, "cancelar vuelve al nombre")
	-- Continuar abre la empresa elegida.
	Menu.select("2")
	clickN("Continuar_2")
	check(waitFor(function()
		return App.g ~= nil
	end), "Continuar abre la empresa")
	eq(App.g.company.name, slots["2"].name, "la empresa elegida")
	App.request("leaveCompany", {})
	waitFor(function()
		return App.g == nil
	end)
	App.ui.route = "menu"
	App.forceRender()
	noErrors("Tarjetas del menú")
end)

test("Editor definitivo: cinco etapas guiadas, selección inmediata, comparación real, borradores persistentes y finalización", function()
	local Catalog = require("./.build-ui/shared/Catalog")
	local DesignCalc = require("./.build-ui/shared/DesignCalc")
	local Rules = require("./.build-ui/shared/Rules")
	local Actions = require("./.build-ui/server/Actions")
	local Ed = App.screens.editor
	App.closeAllDialogs()
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	local sess = Sessions.instance.list[player]
	sess.game.money = math.max(sess.game.money, 400000)
	App.go("juego")
	M.task.wait()
	-- Abrir el editor pausa la empresa y no usa la cámara del Workspace.
	App.go("editor", { new = true })
	M.task.wait()
	check(App.menuPaused(), "abrir el editor pausa la empresa")
	M.services.RunService.RenderStepped:Fire(1 / 60)
	check(Ed.diagnose().ok, "vista 3D propia con el auto encuadrado")
	check(not App.screens.showroom.isVisible(), "sin el showroom de fondo")
	local e = App.ui.editor
	eq(e.step, 1, "empieza en Chasis")
	check(named("Paso_5") ~= nil and named("TituloEtapa") ~= nil, "indicador de cinco etapas")
	-- 1. Chasis: las tarjetas reflejan lo disponible; el Sedán y el Coupé de 1970 siempre están.
	for _, b in Catalog.BASES do
		local card = named("Base_" .. b.id)
		check(card ~= nil and card:GetAttribute("bloqueado") == (DesignCalc.baseAvailable(App.g, b) ~= nil), "chasis " .. b.name .. ": disponible/bloqueado según la investigación")
	end
	check(named("Base_brisa"):GetAttribute("bloqueado") == false and named("Base_duna"):GetAttribute("bloqueado") == false, "Sedán y Coupé 1970 disponibles")
	-- 4. Selección inmediata, sin confirmación, con el auto y las estadísticas actualizados.
	clickN("Base_duna")
	check(not dialogOpen(), "sin confirmación por componente")
	eq(App.ui.editor.draft.baseId, "duna", "el chasis se aplica al borrador")
	check(named("UltimoCambio") ~= nil, "se muestra qué cambió")
	-- 3. Navegación guiada: no se saltea, se puede volver y las elecciones se conservan.
	Ed.goStep(4)
	eq(App.ui.editor.step, 1, "la primera vez no se saltea a una etapa no visitada")
	clickN("Siguiente")
	eq(App.ui.editor.step, 2, "Siguiente pasa a Motor")
	-- 2. Motores I4 e I6 (nivel 1 de su familia investigada como mínimo).
	check(named("Pieza_i4") ~= nil and named("Pieza_i6") ~= nil, "motores I4 e I6")
	check(named("Pieza_i6"):GetAttribute("bloqueado") == false and named("Pieza_i4"):GetAttribute("bloqueado") == false, "ambos disponibles")
	check(named("NivelMotor_1") ~= nil and named("NivelMotor_10") ~= nil, "niveles 1 a 10")
	-- 5 y 6. Recalculo y comparación con los valores reales de DesignCalc.
	local d0 = Util.deepCopy(App.ui.editor.draft)
	local target = d0.parts.motor == "i4" and "i6" or "i4"
	clickN("Pieza_" .. target)
	local d1 = App.ui.editor.draft
	eq(d1.parts.motor, target, "el motor se aplica al instante")
	local a, b = DesignCalc.computeDesign(App.g, d0), DesignCalc.computeDesign(App.g, d1)
	local hp = named("Stat_hp")
	check(hp ~= nil and hp:GetAttribute("antes") == a.hp and hp:GetAttribute("ahora") == b.hp, "potencia: antes " .. a.hp .. " → ahora " .. b.hp .. " (cálculo real)")
	eq(hp:GetAttribute("favorable"), b.hp > a.hp, "más potencia es favorable")
	local cons = named("Stat_consumption")
	if b.consumption ~= a.consumption then
		eq(cons:GetAttribute("favorable"), b.consumption < a.consumption, "menos consumo es favorable (no todo aumento es bueno)")
	end
	local uc = named("Stat_unitCost")
	if b.unitCost ~= a.unitCost then
		eq(uc:GetAttribute("favorable"), b.unitCost < a.unitCost, "menor costo de fabricación es favorable")
	end
	-- 7. Lo no investigado está bloqueado y no se aplica.
	for _, v in Catalog.ENGINE_VARIANTS do
		local card = named("VarianteMotor_" .. v.id)
		eq(card:GetAttribute("bloqueado"), DesignCalc.variantBlock(App.g, d1, v) ~= nil, "variante " .. v.name .. " según la investigación")
		if card:GetAttribute("bloqueado") then
			clickN("VarianteMotor_" .. v.id)
			check(App.ui.editor.draft.motorVariant ~= v.id, "una variante bloqueada no se aplica")
		end
	end
	-- Volver a Chasis conserva el motor elegido.
	clickN("Paso_1")
	eq(App.ui.editor.step, 1, "se vuelve a una etapa visitada")
	eq(App.ui.editor.draft.parts.motor, target, "el motor se conserva")
	clickN("Paso_2")
	eq(App.ui.editor.step, 2, "y se vuelve directo a Motor")
	clickN("Siguiente")
	clickN("Siguiente")
	eq(App.ui.editor.step, 4, "Tecnología y confort")
	-- Equipamiento: instalar y quitar sin duplicar; lo no investigado queda bloqueado.
	local free, locked = nil, nil
	for _, x in Catalog.EQUIPMENT do
		if x.group == "tecnologia" then
			if Rules.equipmentUnlocked(App.g, x) then
				free = free or x
			else
				locked = locked or x
			end
		end
	end
	if free then
		clickN("Equipo_" .. free.id)
		clickN("Equipo_" .. free.id)
		eq(#App.ui.editor.draft.equipment, 0, "instalar y quitar deja el borrador como estaba")
		clickN("Equipo_" .. free.id)
		clickN("Paso_1")
		clickN("Paso_4")
		eq(#App.ui.editor.draft.equipment, 1, "ir y volver entre etapas no duplica componentes")
	end
	if locked then
		check(named("Equipo_" .. locked.id):GetAttribute("bloqueado") == true, locked.name .. " sin investigar: bloqueado")
		clickN("Equipo_" .. locked.id)
		check(table.find(App.ui.editor.draft.equipment, locked.id) == nil, "no se instala")
	end
	-- 8. Guardado automático del borrador: unos segundos después del último cambio, en la partida.
	local id = App.ui.editor.draftId
	check(App.ui.editor.pendingSync, "cambio pendiente de guardar")
	check(Actions.important.saveDraft == nil and Actions.economic.saveDraft == nil, "guardar un borrador no fuerza una escritura en DataStore")
	M.task.wait(Ed.SYNC_DELAY + 0.3)
	M.task.wait()
	local dr = nil
	for _, x in sess.game.drafts do
		if x.id == id then
			dr = x
		end
	end
	check(dr ~= nil, "el borrador está en la partida del servidor")
	eq(dr and dr.spec.parts.motor, target, "con el motor elegido")
	eq(dr and dr.step, 4, "y la etapa")
	eq(#sess.game.designs, #App.g.designs, "un borrador no es un modelo")
	-- 9. Salir, volver al menú y cargar la empresa: el borrador vuelve igual.
	App.ui.editor.draft.name = "Sin terminar"
	App.screens.editor.change(function(dd)
		dd.name = "Prototipo Uno"
	end)
	App.leaveToMenu()
	check(waitFor(function()
		return App.g == nil
	end), "vuelve al menú (guarda la empresa)")
	App.request("selectSlot", { slot = "1" })
	check(waitFor(function()
		return App.g ~= nil
	end), "carga la empresa")
	App.go("juego")
	M.task.wait()
	sess = Sessions.instance.list[player]
	local back = nil
	for _, x in App.g.drafts do
		if x.id == id then
			back = x
		end
	end
	check(back ~= nil and back.spec.name == "Prototipo Uno", "el borrador se recupera tras cargar la empresa (el cambio de último momento incluido)")
	App.go("editor")
	M.task.wait()
	eq(App.ui.editor.draftId, id, "el editor continúa ese borrador")
	eq(App.ui.editor.step, 4, "en su etapa")
	eq(App.ui.editor.draft.parts.motor, target, "con sus componentes")
	-- 10. Investigar algo después e incorporarlo al mismo borrador.
	if locked then
		App.go("juego")
		table.insert(sess.game.research.done, locked.research)
		Sessions.instance:push(sess)
		M.task.wait()
		App.go("editor", { draftId = id })
		M.task.wait()
		check(named("Equipo_" .. locked.id):GetAttribute("bloqueado") == false, locked.name .. " ya investigado se puede elegir")
		clickN("Equipo_" .. locked.id)
		check(table.find(App.ui.editor.draft.equipment, locked.id) ~= nil, "se incorpora al borrador")
	end
	-- 11. Resumen: el nombre se valida y la finalización pide confirmación.
	clickN("Siguiente")
	eq(App.ui.editor.step, 5, "Resumen")
	check(named("TituloPresentacion") ~= nil and named("NombreModelo") ~= nil and named("Ficha_Motor") ~= nil, "presentación con nombre editable y ficha técnica")
	App.screens.editor.change(function(dd)
		dd.name = "x"
	end)
	local fin = named("FinalizarDiseno")
	check(fin:GetAttribute("disabled") == true and Ed.finalizeCheck() ~= nil, "un nombre inválido no se puede finalizar")
	App.screens.editor.change(function(dd)
		dd.name = "Halcón Definitivo"
	end)
	local spec = Util.deepCopy(App.ui.editor.draft)
	local before = #App.g.designs
	clickN("FinalizarDiseno")
	eq(topKind(), "confirm", "confirmación de diseño definitivo")
	check(find("definitivo") ~= nil, "avisa que no se podrá cambiar")
	clickN("Confirmar")
	check(waitFor(function()
		return #App.g.designs == before + 1
	end), "se crea el modelo finalizado")
	eq(App.ui.route, "fabrica", "pasa a Producción")
	check(named("LoteRecienFinalizado") ~= nil, "con acceso directo a su lote")
	-- 12. Sin duplicados por una segunda confirmación.
	Ed.doFinalize()
	local again = App.request("finalizeDesign", { draftId = id, draft = spec })
	check(not again.ok, "una segunda confirmación se rechaza")
	M.task.wait()
	eq(#App.g.designs, before + 1, "sigue habiendo un solo modelo nuevo")
	local inDrafts = false
	for _, x in App.g.drafts do
		inDrafts = inDrafts or x.id == id
	end
	check(not inDrafts, "el borrador se retiró")
	-- 13. Especificaciones conservadas e inmutables.
	local model = App.g.designs[#App.g.designs]
	eq(model.name, "Halcón Definitivo", "nombre del modelo")
	eq(model.parts.motor, target, "motor original")
	eq(table.concat(model.equipment, ","), table.concat(spec.equipment, ","), "equipamiento original")
	local edit = Util.deepCopy(model)
	edit.paint.primary = "#D6333F"
	check(not App.request("saveDesign", { draft = edit, sourceId = model.id }).ok, "el modelo terminado no se modifica")
	App.go("editor", { designId = model.id })
	M.task.wait()
	check(App.ui.editor.draftId ~= id and App.ui.editor.draft.id == nil, "«editar» un modelo abre un borrador nuevo basado en él")
	App.go("juego")
	M.task.wait()
	-- 14. Disponible en Producción: un solo lote.
	local lot = App.request("createLot", { designId = model.id, qty = 5 })
	check(lot.ok, "se fabrica: " .. tostring(lot.msg))
	check(not App.request("createLot", { designId = model.id, qty = 5 }).ok, "un solo lote por modelo")
	check(not App.request("createLot", { designId = id, qty = 5 }).ok, "un borrador no se fabrica")
	-- 15. La partida (con borradores) sigue siendo válida.
	local GameState = require("./.build-ui/server/GameState")
	check(GameState.validate(sess.game), "la partida es válida")
	noErrors("Editor definitivo")
end)

test("Eliminar empresa exige escribir el nombre", function()
	App.request("leaveCompany")
	waitFor(function()
		return App.g == nil
	end)
	local slots = App.profile.slots
	local key = nil
	for k, s in slots do
		if s.name == "Magnate SA" then
			key = k
		end
	end
	check(key ~= nil, "existe la ranura de Magnate")
	local r = App.request("deleteCompany", { slot = key, confirm = "otra cosa" })
	check(not r.ok, "sin el nombre exacto no se borra")
	r = App.request("deleteCompany", { slot = key, confirm = "Magnate SA" })
	check(r.ok, "con el nombre exacto se borra")
	M.task.wait()
	check(App.profile.slots[key] == nil, "la ranura queda libre")
	local other = false
	for _, s in App.profile.slots do
		if s.name == "Ruta Norte" then
			other = true
		end
	end
	check(other, "la otra empresa no se toca")
	noErrors("Eliminar")
end)

T.finish()
Build.clean()
process.exit(T.failed == 0 and 0 or 1)
