--[[
	Pruebas de la interfaz sin Roblox Studio: se ejecutan el servidor y el cliente reales sobre los
	dobles de tests/mock.luau, y se maneja la interfaz como un jugador (buscar botones por su texto,
	hacer clic, escribir). Detectan errores de ejecución y flujos rotos; NO verifican el aspecto
	visual, el diseño en pantalla, la física ni el rendimiento: eso se prueba en Studio.
	Uso (desde la carpeta car-empire-tycoon):  lune run tests/ui.luau
]]

local process = require("@lune/process")
local serde = require("@lune/serde")

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

-- Ordena un lote por la interfaz: configuración (cantidad) → confirmación obligatoria. Si todas las líneas
-- están ocupadas, la empresa de prueba recibe otra línea (como si la hubiera comprado).
local function lotViaUi(designId: string, qty: number): boolean
	local Rules = require("./.build-ui/shared/Rules")
	if not Rules.freeLine(App.g) then
		local sess = Sessions.instance.list[player]
		sess.game.facilities.lines["2"] = true
		sess.game.facilities.accountLine3 = true
		Sessions.instance:push(sess)
		M.task.wait()
	end
	local before = #App.g.lots
	App.ui.lotDraft = nil
	App.openDialog("lot", { designId = designId, wide = true })
	M.task.wait()
	M.type(named("Cantidad"), tostring(qty))
	clickN("ContinuarLote")
	clickN("Confirmar")
	return waitFor(function()
		return #App.g.lots > before
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

	-- Producción: lista de líneas a la izquierda y detalle a la derecha.
	local Rules = require("./.build-ui/shared/Rules")
	local DesignCalc = require("./.build-ui/shared/DesignCalc")
	App.go("fabrica")
	M.task.wait()
	check(named("Linea_1") ~= nil and named("Linea_2") ~= nil and named("Linea_3") ~= nil, "tres líneas en la lista")
	eq(named("Linea_1"):GetAttribute("estado"), "libre", "la línea 1 está libre desde la fundación")
	eq(named("Linea_2"):GetAttribute("estado"), "bloqueada", "la 2 está bloqueada (dinero del juego)")
	eq(named("Linea_3"):GetAttribute("estado"), "bloqueada", "la 3 está bloqueada (Robux de la cuenta)")
	clickN("Linea_2")
	check(named("DesbloquearLinea_2") ~= nil, "la línea 2 muestra cómo desbloquearla")
	clickN("Linea_3")
	check(named("DesbloquearLinea_3") ~= nil, "la línea 3 también")
	clickN("Linea_1")
	-- Catálogo visual → cantidad libre → confirmación obligatoria.
	clickN("IniciarProduccion")
	eq(topKind(), "lot", "abre el catálogo de modelos")
	local designId = App.g.designs[1].id
	local vcard = named("Vehiculo_" .. designId)
	check(vcard ~= nil and vcard:GetAttribute("disponible") == true and vcard:FindFirstChild("Miniatura", true) ~= nil, "el modelo finalizado está disponible, con su vista 3D")
	clickN("Vehiculo_" .. designId)
	check(named("Cantidad") ~= nil and named("Cantidad_100") ~= nil and named("CantidadMaxima") ~= nil, "cantidad libre con atajos")
	eq(named("Cantidad").Text, "", "sin cantidad predeterminada")
	eq(named("ContinuarLote"):GetAttribute("disabled"), true, "sin cantidad no se continúa")
	M.type(named("Cantidad"), "2.5")
	check(named("CantidadInvalida") ~= nil and named("ContinuarLote"):GetAttribute("disabled") == true, "una cantidad no entera se rechaza")
	M.type(named("Cantidad"), "30")
	eq(App.ui.lotDraft and App.ui.lotDraft.qty, 30, "la cantidad escrita se conserva")
	local unit = Rules.lotUnitCost(App.g, DesignCalc.computeDesign(App.g, App.g.designs[1]).unitCost)
	check(find(Util.money(30 * unit)) ~= nil, "costo total con el costo real por unidad")
	check(named("Duracion") ~= nil and named("Bonificaciones") ~= nil, "duración estimada y bonificaciones")
	clickN("ContinuarLote")
	eq(topKind(), "confirm", "confirmación obligatoria")
	check(find("no podrá cancelarse") ~= nil and find("Cada modelo solo puede producir un lote") ~= nil, "advierte que no se cancela")
	check(find("Confirmar producción") ~= nil and find("Volver") ~= nil, "botones Volver y Confirmar producción")
	clickN("Cancelar")
	eq(topKind(), "lot", "Volver regresa a la configuración")
	clickN("ContinuarLote")
	clickN("Confirmar")
	check(waitFor(function()
		return lotOf(designId) ~= nil
	end), "el lote se crea")
	eq(lotOf(designId).qty, 30, "con la cantidad elegida")
	eq(lotOf(designId).line, 1, "en la línea 1")
	check(not dialogOpen(), "el diálogo se cierra")
	App.forceRender()
	M.task.wait()
	eq(named("Linea_1"):GetAttribute("estado"), "ocupada", "la línea 1 queda ocupada")
	for _, n in { "ModeloLinea", "Porcentaje", "DiasRestantes", "CostoPagado", "Bonificaciones" } do
		check(named(n) ~= nil, "el detalle de la línea muestra " .. n)
	end
	check(named("IniciarProduccion") == nil, "una línea ocupada no ofrece otro lote")
	check(named("Pausa") == nil and named("Subir") == nil, "sin pausa, cola ni cancelación")
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
	check(App.menuPaused(), "la empresa está en pausa mientras se muestran las reseñas")
	check(named("Critico_familia") ~= nil and named("Critico_pista") == nil, "los críticos aparecen de a uno")
	local review0 = Util.deepCopy(lr.review)
	clickN("SaltarResenas")
	check(not dialogOpen(), "saltar cierra la presentación")
	eq(App.ui.route, "ventas", "y lleva a Ventas")
	eq(App.ui.salesSel, lr.id, "con el modelo elegido")
	App.openDialog("reviews", { lotId = lr.id })
	M.task.wait()
	for _, c in { "familia", "pista", "bolsillo", "tendencias" } do
		check(named("Critico_" .. c) ~= nil, "reseña de " .. c)
	end
	check(named("NotaFinal") ~= nil, "nota final")
	App.closeAllDialogs()
	eq(serde.encode("json", lotOf(designId).review), serde.encode("json", review0), "las reseñas no se recalculan al volver a verlas")
	-- Precio de lanzamiento en el panel de Ventas: libre, validado y con la demanda prevista en vivo.
	App.forceRender()
	M.task.wait()
	check(named("Modelo_" .. lr.id) ~= nil, "detalle del modelo")
	for _, n in { "PrecioModelo", "Vendidas", "Disponibles", "Ingresos", "NotaCriticos", "Demanda", "Margen", "PrecioReferencia" } do
		check(named(n) ~= nil, "el panel muestra " .. n)
	end
	local box = named("Precio")
	box.Text = "0"
	check(named("PonerALaVenta"):GetAttribute("disabled") == true, "un precio inválido no se envía")
	box.Text = tostring(lr.refPrice * 6)
	local dearLevel = named("DemandaPrevista"):GetAttribute("nivel")
	box.Text = tostring(math.floor(lr.refPrice * 0.7))
	local cheapLevel = named("DemandaPrevista"):GetAttribute("nivel")
	check(cheapLevel > dearLevel, "la demanda prevista cambia con el precio (" .. tostring(dearLevel) .. " → " .. tostring(cheapLevel) .. ")")
	box.Text = tostring(lr.refPrice)
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

	-- Centro de ventas: lista de modelos a la izquierda y detalle a la derecha.
	App.go("ventas")
	App.ui.salesSel = l.id
	App.forceRender()
	M.task.wait()
	check(named("Fila_" .. l.id) ~= nil and named("Modelo_" .. l.id) ~= nil, "fila en la lista y detalle del modelo")
	for _, n in { "PrecioModelo", "Vendidas", "Disponibles", "Ingresos", "NotaCriticos", "Demanda", "AplicarPrecio", "CerrarVenta", "Campana", "NuevaCampana" } do
		check(named(n) ~= nil, "el panel muestra " .. n)
	end
	check(find("En venta") ~= nil, "estado comercial En venta")
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
	local Rules = require("./.build-ui/shared/Rules")
	local DesignCalc = require("./.build-ui/shared/DesignCalc")
	local unit = Rules.lotUnitCost(App.g, DesignCalc.computeDesign(App.g, App.g.designs[1]).unitCost)
	check(lotViaUi(App.g.designs[1].id, math.min(100, math.floor(App.g.money / unit))), "Magnate puede lanzar su primer lote")
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
-- Tramos de pared construidos, contados de forma independiente de Office: cada casilla del borde aporta un tramo
-- por cada lado exterior que toca, salvo que sea un acceso (puerta abierta en ese lado).
local function builtWalls(r: any): number
	local access = {}
	for _, a in r.access do
		access[a[1] .. ":" .. a[2]] = true
	end
	local n = 0
	for x = 0, r.w - 1 do
		for _, y in { 0, r.d - 1 } do
			if not access[x .. ":" .. y] then
				n += 1
			end
		end
	end
	for y = 0, r.d - 1 do
		for _, x in { 0, r.w - 1 } do
			if not access[x .. ":" .. y] then
				n += 1
			end
		end
	end
	return n
end

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
	check(lotViaUi(saved.id, 50), "lote lanzado")
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
	check(named("PIDisponibles") ~= nil and named("FranjaEnCurso") ~= nil, "PI disponibles y franja de investigaciones en curso")
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
			eq(topKind(), "research", key .. ": abre la confirmación")
			clickN("ConfirmarInvestigacion")
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
	App.ui.researchFilter = "completadas"
	App.ui.tabs.investigacion = started[1] and started[1].category or "tecnologia"
	App.forceRender()
	M.task.wait()
	check(started[1] and named("Nodo_" .. started[1].id) ~= nil and named("Nodo_" .. started[1].id):GetAttribute("estado") == "completada", "filtro de completadas")
	App.ui.researchFilter = nil
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
	-- Tarjeta del candidato: salario, potencial, tres habilidades y aporte real; el resto, a pedido.
	check(named("Salario_" .. c.id) ~= nil and named("Potencial_" .. c.id) ~= nil and named("Aporte_" .. c.id) ~= nil, "salario, potencial y aporte a la vista")
	check(named("MasDatos_" .. c.id) == nil, "los datos extra no cargan la tarjeta")
	clickN("VerMas_" .. c.id)
	M.task.wait()
	check(named("MasDatos_" .. c.id) ~= nil, "más datos a pedido")
	clickN("VerMas_" .. c.id)
	M.task.wait()
	check(named("MasDatos_" .. c.id) == nil, "y se vuelven a ocultar")
	local occ = named("OcupacionPersonal")
	check(occ ~= nil and string.find(occ.Text, #App.g.employees .. " ", 1, true) == 1 and string.find(occ.Text, "/ " .. App.g.derived.caps.staff, 1, true) ~= nil, "límite global con datos reales")
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
	for _, l in require("./.build-ui/shared/Catalog").TRAINING.levels do
		check(named("NivelCap_" .. l.id) ~= nil, "nivel de capacitación " .. l.id)
	end
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
	-- Lista + detalle: el detalle muestra la comparación con valores reales de las reglas.
	local FV = require("./.build-ui/client/FacilitiesView")
	local Rules = require("./.build-ui/shared/Rules")
	App.ui.facSel = nil
	App.forceRender()
	M.task.wait()
	check(named("DetalleInstalacion") ~= nil and named("NivelActual") ~= nil, "detalle de las oficinas por defecto")
	check(named("ComparacionMejora") ~= nil and M.find(App.content, tostring(Rules.sede(App.g).staff)) ~= nil, "límite actual de empleados")
	local fi = FV.info(App.g, "factory")
	if fi.next then
		local exp = App.g.derived.caps.perLine * fi.next.def.perLine / Rules.factory(App.g).perLine
		eq(fi.compare[1][3], require("./.build-ui/shared/Util").num(exp, 1), "fábrica: autos/min después = base del próximo nivel con las mismas mejoras")
	end
	local ri = FV.info(App.g, "research")
	if ri.next then
		eq(ri.compare[1][3], tostring(ri.next.def.pi), "centro: PI del próximo nivel")
	end
	clickN("Instalacion_line3")
	M.task.wait()
	check(named("ComprarLinea3") ~= nil, "la línea 3 ofrece la compra con Robux")
	clickN("Instalacion_line2")
	M.task.wait()
	check(named("ComparacionMejora") ~= nil and named("CostoMejora") ~= nil and named("Requisitos") ~= nil, "línea 2: antes → después, costo y requisitos")
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

test("Avatar autónomo del dueño: uno por parcela, camina por la oficina, no es el personaje y se limpia", function()
	local OwnerAvatar = require("./.build-ui/server/OwnerAvatar")
	local original = { makeRig = OwnerAvatar.makeRig, PAUSE = OwnerAvatar.PAUSE, WORK = OwnerAvatar.WORK, MOVE_TIMEOUT = OwnerAvatar.MOVE_TIMEOUT, START_DELAY = OwnerAvatar.START_DELAY }
	-- La simulación no tiene los servicios de avatares de Roblox: un rig mínimo con Humanoid reemplaza
	-- a CreateHumanoidModelFromDescription; MoveTo lo lleva directo al destino.
	local made, moves = 0, 0
	OwnerAvatar.PAUSE = { 0.02, 0.05 }
	OwnerAvatar.WORK = { 0.02, 0.05 }
	OwnerAvatar.MOVE_TIMEOUT = 0.5
	OwnerAvatar.START_DELAY = { 0.01, 0.02 }
	OwnerAvatar.makeRig = function(_userId: number)
		made += 1
		local rig = M.Instance.new("Model")
		local rootPart = M.Instance.new("Part")
		rootPart.Name = "HumanoidRootPart"
		rootPart.Size = M.Vector3.new(2, 2, 1)
		rootPart.Parent = rig
		rig.PrimaryPart = rootPart
		local hum = M.Instance.new("Humanoid")
		hum.HipHeight = 2
		hum.MoveTo = function(_, pos)
			moves += 1
			rig:PivotTo(M.CFrame.new(pos + M.Vector3.new(0, 3, 0)))
		end
		hum.Parent = rig
		return rig
	end
	local function avatars(): { any }
		local out = {}
		for _, d in M.services.Workspace:GetDescendants() do
			if d.Name == OwnerAvatar.NAME then
				table.insert(out, d)
			end
		end
		return out
	end
	local function reopen()
		App.closeAllDialogs()
		if App.g then
			App.request("leaveCompany", {})
			waitFor(function()
				return App.g == nil
			end)
		end
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
		if App.screens.intro.active() then
			App.screens.intro.finish()
		end
	end
	reopen()
	check(waitFor(function()
		return #avatars() == 1
	end), "aparece un avatar en la parcela del dueño")
	local av = avatars()[1]
	eq(av:GetAttribute("OwnerId"), player.UserId, "es el avatar del dueño")
	check(av ~= player.Character and M.services.Players.CharacterAutoLoads == false, "no es el personaje del jugador (no se controla)")
	local cam = M.services.Workspace.CurrentCamera
	check(cam.CameraSubject == nil or not cam.CameraSubject:IsDescendantOf(av), "la cámara de gestión no sigue al avatar")
	-- Camina entre puntos de la oficina (sin pathfinding continuo: MoveTo en línea recta).
	local center = player:GetAttribute("PlotCenter")
	local inside = true
	-- La rutina usa segundos reales: se espera con tiempo real (máximo 8 s).
	for _ = 1, 160 do
		local p = av:GetPivot().Position
		-- La parcela está girada 180°: la oficina (x −44…−15, z −32…−5 de la parcela) queda en +x / +z del centro.
		local dx, dz = p.X - center.X, p.Z - center.Z
		if dx < 14 or dx > 45 or dz < 4 or dz > 33 then
			inside = false
		end
		if moves >= 4 then
			break
		end
		M.task.wait(0.05)
	end
	check(moves >= 4, "camina solo entre varios puntos (" .. moves .. ")")
	check(inside, "siempre dentro de la oficina")
	-- Abrir y cerrar menús no crea otro avatar.
	for _, route in { "personal", "compania", "fabrica", "juego" } do
		App.go(route)
		M.task.wait()
	end
	check(#avatars() == 1 and avatars()[1] == av and made == 1, "abrir menús no duplica el avatar")
	-- Puntos de un edificio de sede: carpeta PuntosAvatar con marcadores invisibles y silla.
	local m = M.Instance.new("Model")
	local folder = M.Instance.new("Folder")
	folder.Name = "PuntosAvatar"
	folder.Parent = m
	for k = 1, 2 do
		local pt = M.Instance.new("Part")
		pt.CFrame = M.CFrame.new(k * 5, 0.4, 3)
		pt.Parent = folder
	end
	local seat = M.Instance.new("Seat")
	seat.Parent = folder
	local spots = OwnerAvatar.spotsFrom(m)
	check(spots ~= nil and #spots.points == 2 and spots.seat == seat, "usa los puntos y la silla del edificio")
	check(folder:GetChildren()[1].Transparency == 1 and folder:GetChildren()[1].CanCollide == false, "marcadores invisibles y sin colisión")
	check(OwnerAvatar.spotsFrom(M.Instance.new("Model")) == nil, "sin puntos en el edificio: usa la oficina provisional")
	-- Al salir de la empresa se destruye y su rutina termina; al volver hay uno solo otra vez.
	App.request("leaveCompany", {})
	check(waitFor(function()
		return App.g == nil and #avatars() == 0
	end), "se elimina al liberar la parcela")
	local frozen = moves
	M.task.wait(0.6)
	eq(moves, frozen, "la rutina se detiene (sin hilos ni conexiones colgadas)")
	reopen()
	check(waitFor(function()
		return #avatars() == 1
	end), "un solo avatar al volver a entrar")
	-- Restaurar: sin rig falso la simulación no crea avatares (como sin servicios de Roblox).
	OwnerAvatar.makeRig = original.makeRig
	OwnerAvatar.PAUSE, OwnerAvatar.WORK, OwnerAvatar.MOVE_TIMEOUT, OwnerAvatar.START_DELAY = original.PAUSE, original.WORK, original.MOVE_TIMEOUT, original.START_DELAY
	reopen()
	check(waitFor(function()
		return #avatars() == 0
	end), "sin servicios de avatares no queda ninguno a medias")
	noErrors("Avatar del dueño")
end)

test("Avatar del dueño: rutas que rodean obstáculos, bloqueos sin teletransporte, destinos inaccesibles y cambio de oficina", function()
	local OwnerAvatar = require("./.build-ui/server/OwnerAvatar")
	local saved = {}
	for _, k in { "makeRig", "findPath", "PAUSE", "WORK", "START_DELAY", "STUCK_TIME", "MOVE_TIMEOUT", "DESK_CHANCE", "LOOK_CHANCE" } do
		saved[k] = OwnerAvatar[k]
	end
	local blocked: { [string]: boolean } = {}
	local visits: { any } = {}
	local function key(v: any): string
		return math.floor(v.X + 0.5) .. "," .. math.floor(v.Z + 0.5)
	end
	OwnerAvatar.makeRig = function()
		local rig = M.Instance.new("Model")
		local rootPart = M.Instance.new("Part")
		rootPart.Name = "HumanoidRootPart"
		rootPart.Size = M.Vector3.new(2, 2, 1)
		rootPart.Parent = rig
		rig.PrimaryPart = rootPart
		local hum = M.Instance.new("Humanoid")
		hum.HipHeight = 2
		-- MoveTo: llega al destino salvo que esté bloqueado (ahí no avanza nada, como contra un mueble).
		hum.MoveTo = function(_, pos)
			table.insert(visits, pos)
			if not blocked[key(pos)] then
				rig:PivotTo(M.CFrame.new(M.Vector3.new(pos.X, 3.4, pos.Z)))
			end
		end
		hum.Parent = rig
		return rig
	end
	OwnerAvatar.PAUSE, OwnerAvatar.WORK, OwnerAvatar.START_DELAY = { 0.01, 0.02 }, { 0.01, 0.02 }, { 0.01, 0.02 }
	OwnerAvatar.STUCK_TIME, OwnerAvatar.MOVE_TIMEOUT = 0.5, 2
	OwnerAvatar.DESK_CHANCE, OwnerAvatar.LOOK_CHANCE = 0, 0 -- solo caminar: se miden los trayectos
	local V = M.Vector3.new
	local A, B, C = V(0, 0.4, 0), V(20, 0.4, 0), V(0, 0.4, 20)
	-- Ruta con desvío para ir a B (rodea un «escritorio» en (10, 0)); C es inaccesible.
	OwnerAvatar.findPath = function(_av, _from, to)
		if key(to) == key(C) then
			return nil
		end
		if key(to) == key(B) then
			return { V(10, 0.4, 6), B }
		end
		return { to }
	end
	local folder = M.Instance.new("Model")
	folder.Parent = M.services.Workspace
	local owner = { UserId = 77 }
	local av = OwnerAvatar.new(owner :: any, folder, { points = { A, B, C }, source = "prueba" })
	check(av ~= nil and folder:FindFirstChild(OwnerAvatar.NAME) ~= nil, "se arma dentro de la oficina")
	local function realWait(cond: () -> boolean, seconds: number): boolean
		for _ = 1, math.ceil(seconds / 0.05) do
			if cond() then
				return true
			end
			M.task.wait(0.05)
		end
		return cond()
	end
	-- 1) Ruta con desvío: pasa por el punto intermedio antes de llegar.
	table.clear(visits)
	check(av:walkTo(B), "llega a B por la ruta")
	check(#visits >= 2 and key(visits[1]) == "10,6" and key(visits[#visits]) == "20,0", "sigue los puntos de la ruta (rodea el obstáculo)")
	-- 2) Destino inaccesible: no camina hacia él ni se mueve de lugar.
	local before = av:pos()
	table.clear(visits)
	check(av:walkTo(C) == false and #visits == 0, "sin ruta no camina eternamente hacia un punto inaccesible")
	check((av:pos() - before).Magnitude < 0.01, "y se queda donde estaba")
	-- 3) Bloqueo en el camino: deja de intentar a los STUCK_TIME, se detiene donde está (sin aparecer en el destino).
	blocked[key(A)] = true
	local t0 = os.clock()
	check(av:walkTo(A) == false, "detecta que no avanza")
	check(os.clock() - t0 < 1.5, "y no se queda caminando hasta el tiempo máximo")
	check((av:pos() - before).Magnitude < 0.01, "no se teletransporta al destino")
	eq(av.current, "idle", "vuelve a la animación de reposo (sin caminar en el lugar)")
	blocked[key(A)] = nil
	-- 4) La rutina no repite el destino que acaba de fallar y se recupera caminando.
	local fails0 = av.fails
	check(fails0 >= 1, "cuenta los fallos")
	check(av:pickPoint(3) ~= 3 or #av.spots.points == 1, "evita el punto que falló")
	-- 5) Cambio de oficina: corta el trayecto, no aparece de golpe si hay ruta desde donde está.
	local e0 = av.epoch
	local D = V(40, 0.4, 40)
	av:setSpots({ points = { D, A }, source = "nueva" })
	check(av.epoch == e0 + 1, "el cambio de oficina corta el trayecto en curso")
	M.task.wait(0.05)
	eq(av.recovered, 0, "con ruta disponible no se teletransporta")
	-- 6) Rutina en marcha: camina sola y el hilo se cancela al destruirlo.
	check(realWait(function()
		return #visits >= 6
	end, 6), "la rutina camina sola")
	av:destroy()
	check(folder:FindFirstChild(OwnerAvatar.NAME) == nil and av.thread == nil and av.alive == false, "destroy elimina el modelo y cancela el hilo")
	local n = #visits
	M.task.wait(0.3)
	eq(#visits, n, "sin movimiento después de destruirlo")
	for k, v in saved do
		OwnerAvatar[k] = v
	end
	folder:Destroy()
	noErrors("Avatar: rutas y recuperación")
end)

test("Cámaras: un solo dueño por pantalla, sin conexiones acumuladas, y pantallas que se abren y cierran rápido", function()
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	if App.screens.intro.active() then
		App.screens.intro.finish()
	end
	App.closeAllDialogs()
	local function live(sigName: string, inst: any): number
		local sig = rawget(inst, "__signals")[sigName]
		local n = 0
		for _, h in (sig and sig.handlers) or {} do
			if h.connected then
				n += 1
			end
		end
		return n
	end
	local RS, UIS = M.services.RunService, M.services.UserInputService
	local Showroom = App.screens.showroom
	local SceneCamera = require("./.build-ui/client/SceneCamera")
	local function cycle()
		for _, route in { "juego", "personal", "compania", "investigacion", "editor", "juego" } do
			App.go(route)
			M.task.wait()
			eq(App.cameraOwner, "scene", "con la empresa abierta la cámara es la de gestión (" .. route .. ")")
			check(not Showroom.isVisible(), "el showroom no se mueve fuera del menú (" .. route .. ")")
		end
		App.go("juego")
		M.task.wait()
		-- Volver al menú principal (mismo camino que «Guardar y volver al menú») y entrar otra vez.
		App.request("leaveCompany", {})
		App.ui.route = "menu"
		waitFor(function()
			return App.g == nil
		end)
		App.forceRender()
		M.task.wait()
		eq(App.cameraOwner, "showroom", "en el menú principal la cámara es del showroom")
		check(Showroom.isVisible() and not SceneCamera.owns(), "el showroom vuelve y la cámara de gestión se suelta")
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
		App.go("juego")
		M.task.wait()
		eq(App.cameraOwner, "scene", "al entrar a la empresa se activa la cámara de gestión")
	end
	cycle()
	local rs0, ib0, ic0 = live("RenderStepped", RS), live("InputBegan", UIS), live("InputChanged", UIS)
	for _ = 1, 3 do
		cycle()
	end
	eq(M.services.Workspace.CurrentCamera.CameraType, M.Enum.CameraType.Scriptable, "la cámara queda siempre en manos de un script (sin cuadros de la cámara de Roblox)")
	eq(live("RenderStepped", RS), rs0, "RenderStepped: no se acumulan conexiones al cambiar de pantalla")
	eq(live("InputBegan", UIS), ib0, "InputBegan: sin conexiones nuevas")
	eq(live("InputChanged", UIS), ic0, "InputChanged: sin conexiones nuevas")
	-- La cámara de gestión: zoom y rotación siguen funcionando después de los cambios.
	App.go("juego")
	M.task.wait()
	local cam = M.services.Workspace.CurrentCamera
	RS.RenderStepped:Fire(1 / 60)
	local p0 = cam.CFrame.Position
	SceneCamera.rotate(90, 0)
	RS.RenderStepped:Fire(1 / 60)
	check((cam.CFrame.Position - p0).Magnitude > 1, "la rotación sigue respondiendo")
	SceneCamera.rotate(-90, 0)
	-- Abrir y cerrar pantallas y diálogos muy rápido no deja errores ni diálogos colgados.
	App.renderError = nil
	for _ = 1, 4 do
		for _, route in { "personal", "compania", "investigacion", "fabrica", "ventas", "autos", "mercado", "juego" } do
			App.go(route)
		end
		App.ui.staff = { view = "mercado", dept = "produccion", hireDept = {} }
		App.go("personal")
		App.ui.staff.view = "capacitaciones"
		App.forceRender()
		App.openDialog("training", { scope = "general" })
		App.closeAllDialogs()
		App.go("juego")
	end
	M.task.wait()
	check(App.renderError == nil, "sin errores al abrir y cerrar rápido" .. (App.renderError and (": " .. tostring(App.renderError)) or ""))
	eq(#App.ui.dialogs, 0, "sin diálogos colgados")
	noErrors("Cámaras y pantallas")
end)

test("Showroom: la exposición se adapta a la pintura y la iluminación del lugar vuelve al salir", function()
	local Showroom = App.screens.showroom
	local light, dark, mid = Showroom.exposureFor("#F2F2F2"), Showroom.exposureFor("#111111"), Showroom.exposureFor("#7A7A7A")
	check(light < mid and mid < dark, "clara < media < oscura (" .. light .. ", " .. mid .. ", " .. dark .. ")")
	check(light <= -0.3 and dark >= 0, "las claras bajan la exposición y las negras no se oscurecen de más")
	local Lighting = M.services.Lighting
	Lighting.ExposureCompensation = 0.2
	Lighting.Brightness = 2
	App.closeAllDialogs()
	if App.g then
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
	end
	App.ui.route = "menu"
	App.forceRender()
	M.task.wait()
	check(Showroom.isVisible(), "showroom visible en el menú")
	check(Lighting.ExposureCompensation ~= 0.2 and Lighting.Brightness == 0, "en el showroom usa su propia iluminación")
	App.request("selectSlot", { slot = "1" })
	waitFor(function()
		return App.g ~= nil
	end)
	App.go("juego")
	M.task.wait()
	check(not Showroom.isVisible(), "fuera del menú se oculta")
	eq(Lighting.ExposureCompensation, 0.2, "exposición del lugar restaurada al salir")
	eq(Lighting.Brightness, 2, "brillo del lugar restaurado al salir")
	noErrors("Exposición del showroom")
end)

test("Instalaciones: relaciones reales (oficinas, capacitaciones, fábrica, centro, línea 2 con dinero, línea 3 sin la 2)", function()
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	local FV = require("./.build-ui/client/FacilitiesView")
	local Rules = require("./.build-ui/shared/Rules")
	local Catalog = require("./.build-ui/shared/Catalog")
	local Staff = require("./.build-ui/shared/Staff")
	local g = App.g
	local oi = FV.info(g, "offices")
	eq(oi.current[1][2], tostring(g.derived.caps.staff), "oficinas: límite de empleados = el de la simulación")
	if oi.next then
		local nx = Catalog.SEDES[Rules.officeLevel(g) + 1]
		eq(oi.compare[1][3], tostring(nx.staff), "oficinas: el próximo nivel sube el límite global")
		-- La capacitación que habilita el próximo nivel es la que acepta Staff.trainingPlan con ese nivel.
		for _, l in Catalog.TRAINING.levels do
			if l.office == nx.level then
				eq(oi.compare[3][3], l.name, "oficinas: desbloquean la capacitación " .. l.name)
				local e = g.employees[1]
				if e then
					local _, why = Staff.trainingPlan(g, { scope = "general", level = l.id, skill = Staff.dept(e.dept).skills[1] }, nx.level - 1, Rules.year(g))
					check(why ~= nil and string.find(why, "oficinas", 1, true) ~= nil, "con el nivel actual de oficinas no se puede")
				end
			end
		end
	end
	local ri = FV.info(g, "research")
	eq(ri.current[1][2], tostring(g.derived.caps.pi), "centro: PI por minuto = el de la simulación")
	local li2 = FV.info(g, "line2")
	if not Rules.ownsLine(g, 2) and li2.next then
		eq(li2.next.cost, Rules.expansionCost(g, Catalog.FACILITIES.line2.cost), "línea 2: se paga con dinero del juego")
	end
	-- Línea 3: independiente de la 2 (por cuenta, con Robux) y sin compra real configurada.
	local fake = table.clone(g)
	fake.facilities = table.clone(g.facilities)
	fake.facilities.lines = {}
	fake.facilities.accountLine3 = true
	check(Rules.ownsLine(fake, 3) and not Rules.ownsLine(fake, 2), "la línea 3 no exige la línea 2")
	local l3 = FV.info(g, "line3")
	check(l3.next == nil and #l3.checks == 0, "la línea 3 no tiene requisitos de dinero del juego")
	eq(Catalog.PRODUCTS.line3.id, 0, "sin compra real de Robux configurada")
	-- Gestión por menús: los ProximityPrompt del garaje existen pero están desactivados.
	local prompts, on = 0, 0
	for _, d in M.services.Workspace:GetDescendants() do
		if d.ClassName == "ProximityPrompt" then
			prompts += 1
			if d.Enabled ~= false then
				on += 1
			end
		end
	end
	check(prompts > 0 and on == 0, "prompts del garaje desactivados (" .. prompts .. ")")
	noErrors("Relaciones de Instalaciones")
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

test("Borrador: si el guardado falla no se sale del editor, se avisa, se reintenta y nada viejo pisa lo nuevo", function()
	local Actions = require("./.build-ui/server/Actions")
	local Ed = App.screens.editor
	App.closeAllDialogs()
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	App.go("juego")
	M.task.wait()
	App.go("editor", { new = true })
	M.task.wait()
	local real = Actions.handlers.saveDraft
	local calls = 0
	local failing: string? = nil
	Actions.handlers.saveDraft = function(g: any, ctx: any, p: any): any
		calls += 1
		if failing then
			return { ok = false, msg = failing, quiet = true }
		end
		return real(g, ctx, p)
	end
	local function serverDraft(id: string): any
		for _, x in Sessions.instance.list[player].game.drafts do
			if x.id == id then
				return x
			end
		end
		return nil
	end
	-- 6. Autoguardado diferido: varios clics, un solo envío.
	for i = 1, 6 do
		Ed.change(function(d)
			d.quality = i % 2
		end)
	end
	eq(calls, 0, "ningún envío por clic")
	M.task.wait(Ed.SYNC_DELAY + 0.3)
	M.task.wait()
	eq(calls, 1, "un solo envío después de la pausa")
	local e = App.ui.editor
	local id = e.draftId
	eq(e.ackRev, e.rev, "el servidor confirmó la última revisión")
	check(not e.pendingSync, "nada pendiente")
	-- 5. Una revisión vieja (respuesta o reintento atrasado) no pisa lo guardado.
	local stale = Util.deepCopy(e.draft)
	stale.name = "Versión vieja"
	check(App.request("saveDraft", { draftId = id, draft = stale, step = 1, visited = 1, rev = e.rev - 1 }).ok, "el servidor responde sin error")
	check(serverDraft(id).spec.name ~= "Versión vieja", "pero no aplica la revisión vieja")
	-- Sin cambios nuevos, salir no envía nada más.
	calls = 0
	check(Ed.ensureSaved(), "sin cambios pendientes ya está guardado")
	eq(calls, 0, "y no hace falta reenviar")
	-- 1–4. Falla el guardado: no se sale, se avisa y el borrador sigue en memoria.
	failing = "Servidor ocupado (prueba)."
	Ed.change(function(d)
		d.name = "Cambio Importante"
	end)
	App.go("juego")
	M.task.wait()
	eq(App.ui.route, "editor", "con cambios sin confirmar no sale del editor")
	eq(topKind(), "unsaved", "muestra el aviso")
	check(find("Servidor ocupado") ~= nil, "con el motivo")
	eq(App.ui.editor, e, "el mismo editor")
	eq(App.ui.editor.draft.name, "Cambio Importante", "con las selecciones intactas")
	check(e.syncError ~= nil and e.pendingSync, "el cambio queda pendiente")
	check(serverDraft(id).spec.name ~= "Cambio Importante", "el servidor no lo tiene")
	clickN("ReintentarGuardado")
	M.task.wait()
	eq(App.ui.route, "editor", "reintentar con el servidor fallando tampoco sale")
	eq(topKind(), "unsaved", "y el aviso sigue")
	clickN("SeguirEditando")
	check(not dialogOpen() and App.ui.route == "editor", "seguir editando")
	App.forceRender()
	M.task.wait()
	check(string.find(named("EstadoBorrador").Text, "No se pudo guardar", 1, true) ~= nil, "la barra muestra que no se guardó")
	-- Volver al menú o abrir otro borrador tampoco descarta lo pendiente.
	App.leaveToMenu()
	M.task.wait()
	check(App.g ~= nil and App.ui.route == "editor" and topKind() == "unsaved", "volver al menú se detiene")
	App.closeAllDialogs()
	App.go("editor", { new = true })
	M.task.wait()
	eq(App.ui.editor.draftId, id, "otro borrador no reemplaza al pendiente")
	App.closeAllDialogs()
	Ed.newProject()
	M.task.wait()
	eq(App.ui.editor.draftId, id, "un proyecto nuevo tampoco")
	App.closeAllDialogs()
	Ed.goStep(App.ui.editor.visited)
	Ed.doFinalize()
	M.task.wait()
	eq(App.ui.editor.draftId, id, "finalizar no avanza sin el borrador guardado")
	App.closeAllDialogs()
	-- 3. Con el servidor sano, reintentar guarda la última versión y recién ahí sale.
	App.go("juego")
	M.task.wait()
	eq(topKind(), "unsaved", "sigue avisando mientras falla")
	failing = nil
	clickN("ReintentarGuardado")
	M.task.wait()
	eq(App.ui.route, "juego", "guardado confirmado: sale")
	eq(serverDraft(id).spec.name, "Cambio Importante", "el servidor tiene el último cambio")
	check(not e.pendingSync and e.syncError == nil and e.ackRev == e.rev, "sin pendientes ni errores")
	-- «Salir igual» es una elección explícita: el borrador queda en memoria y se sigue protegiendo.
	App.go("editor", { draftId = id })
	M.task.wait()
	failing = "Sin conexión (prueba)."
	Ed.change(function(d)
		d.name = "Cambio Dos"
	end)
	App.go("juego")
	M.task.wait()
	clickN("SalirIgual")
	M.task.wait()
	eq(App.ui.route, "juego", "salir igual sale")
	eq(App.ui.editor and App.ui.editor.draft.name, "Cambio Dos", "el borrador sigue en memoria")
	App.leaveToMenu()
	M.task.wait()
	check(App.g ~= nil and topKind() == "unsaved", "volver al menú vuelve a avisar")
	failing = nil
	clickN("ReintentarGuardado")
	check(waitFor(function()
		return App.g == nil
	end), "guardado: vuelve al menú")
	Actions.handlers.saveDraft = real
	App.request("selectSlot", { slot = "1" })
	check(waitFor(function()
		return App.g ~= nil
	end), "carga la empresa")
	local back = nil
	for _, x in App.g.drafts do
		if x.id == id then
			back = x
		end
	end
	check(back ~= nil and back.spec.name == "Cambio Dos", "el último cambio sobrevivió a la falla")
	App.go("juego")
	M.task.wait()
	noErrors("Protección del borrador")
end)

test("Producción y Ventas: modelos usados no disponibles en el catálogo y reseñas que se cierran solas", function()
	local Rules = require("./.build-ui/shared/Rules")
	local DesignCalc = require("./.build-ui/shared/DesignCalc")
	App.closeAllDialogs()
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	local sess = Sessions.instance.list[player]
	sess.game.money = math.max(sess.game.money, 3000000)
	sess.game.facilities.lines["2"] = true
	sess.game.facilities.accountLine3 = true
	Sessions.instance:push(sess)
	App.go("fabrica")
	M.task.wait()
	-- Un modelo que ya usó su único lote figura como no disponible, con la explicación.
	local used = nil
	for _, d in App.g.designs do
		if d.lotLaunched and not d.template then
			used = d
		end
	end
	check(used ~= nil, "hay un modelo que ya tuvo su lote")
	local free = Rules.freeLine(App.g)
	check(free ~= nil, "hay una línea libre")
	App.ui.lotDraft = nil
	App.openDialog("lot", { line = free, wide = true })
	M.task.wait()
	local card = named("Vehiculo_" .. used.id)
	check(card ~= nil and card:GetAttribute("disponible") == false, "figura como no disponible")
	check(find("único lote") ~= nil, "con la explicación")
	M.click(card)
	M.task.wait()
	check(named("Cantidad") == nil, "no se puede elegir para fabricar")
	App.closeAllDialogs()
	-- Un modelo nuevo: se fabrica y al terminar las reseñas aparecen de a una y se cierran solas. (Las reseñas
	-- de lotes anteriores ya se dan por vistas: la prueba mira solo el nuevo.)
	for _, l in App.g.lots do
		App.ui.reviewsSeen[l.id] = true
	end
	local draft = DesignCalc.newDraft(App.g, "brisa")
	draft.name = "Reseña Corta"
	local r = App.request("saveDesign", { draft = draft })
	check(r.ok, tostring(r.msg))
	check(lotViaUi(r.designId, 5), "lote de 5")
	local lot = nil
	for _, l in App.g.lots do
		if l.designId == r.designId then
			lot = l
		end
	end
	App.go("juego")
	M.task.wait()
	check(waitFor(function()
		advance(1)
		return topKind() == "reviews"
	end, 400), "llegan las reseñas")
	check(named("Critico_pista") == nil, "empiezan de a una")
	M.task.wait(1.2)
	M.task.wait()
	check(named("Critico_pista") ~= nil, "un segundo después aparece la siguiente")
	M.task.wait(4)
	M.task.wait()
	check(not dialogOpen(), "al terminar la secuencia la pantalla se cierra sola")
	eq(App.ui.route, "ventas", "y lleva a Ventas")
	eq(App.ui.salesSel, lot.id, "con el modelo elegido para fijar el precio")
	check(named("PonerALaVenta") ~= nil, "listo para poner a la venta")
	App.go("juego")
	M.task.wait()
	noErrors("Producción y Ventas")
end)

test("Centro de investigación: categorías, filtros, estados, franja de activas y confirmación antes de cobrar", function()
	local Catalog = require("./.build-ui/shared/Catalog")
	local Rules = require("./.build-ui/shared/Rules")
	local R = App.screens.investigacion
	App.closeAllDialogs()
	if not App.g then
		App.request("selectSlot", { slot = "1" })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	local sess = Sessions.instance.list[player]
	sess.game.money = 50000000
	sess.game.rp = 100000
	Sessions.instance:push(sess)
	waitFor(function()
		return App.g.rp == 100000
	end)
	App.go("investigacion")
	App.ui.researchFilter = nil
	App.ui.tabs.investigacion = "chasis"
	App.forceRender()
	M.task.wait()
	check(find("Centro de investigación") ~= nil, "título")
	check(named("PIDisponibles") ~= nil and named("FranjaEnCurso") ~= nil and named("Panel_investigacion"):FindFirstChild("Lateral", true) == nil, "PI y franja arriba, sin panel derecho")
	check(App.menuPaused(), "la pantalla pausa la empresa")
	-- 1–2. Cuatro categorías en el menú lateral.
	for _, c in R.CATEGORIES do
		check(named("Pestana_" .. c[1]) ~= nil, "categoría " .. c[2])
	end
	eq(#R.CATEGORIES, 4, "exactamente cuatro")
	-- 3–4. Todas las tecnologías (también futuras) y estados coherentes en cada filtro.
	for _, c in R.CATEGORIES do
		clickN("Pestana_" .. c[1])
		M.task.wait()
		eq(named("Pestana_" .. c[1]):GetAttribute("activa"), true, c[2] .. " queda activa")
		local main, families = R.nodes(c[1])
		local total = #main
		for _, list in families do
			total += #list
		end
		for _, f in R.FILTERS do
			App.ui.researchFilter = f[1]
			App.forceRender()
			M.task.wait()
			local seen = 0
			for _, d in root:GetDescendants() do
				if string.sub(d.Name, 1, 5) == "Nodo_" and M.visible(d) then
					seen += 1
					local id = string.sub(d.Name, 6)
					local n = Catalog.researchNode(id)
					local st = d:GetAttribute("estado")
					check(R.matches(f[1], st), c[2] .. " / " .. f[2] .. ": " .. id .. " (" .. tostring(st) .. ")")
					if n then
						eq(st, (R.status(App.g, n)), "estado coherente de " .. id)
					end
				end
			end
			if f[1] == "todas" then
				eq(seen, total, c[2] .. ": «Todas» muestra el catálogo completo (" .. total .. ")")
			end
		end
	end
	App.ui.researchFilter = nil
	-- Lo que la empresa tiene desde la fundación figura como completado.
	App.ui.tabs.investigacion = "chasis"
	App.forceRender()
	M.task.wait()
	check(named("Nodo_inicio_brisa") ~= nil and named("Nodo_inicio_brisa"):GetAttribute("estado") == "incluida", "Sedán 1970 desde el inicio")
	check(named("Nodo_inicio_duna") ~= nil, "Coupé 1970 desde el inicio")
	App.ui.tabs.investigacion = "motores"
	App.forceRender()
	M.task.wait()
	check(named("Nodo_inicio_motor_I4") ~= nil and named("Nodo_inicio_motor_I6") ~= nil and named("Nodo_inicio_variante_balanced") ~= nil, "I4 e I6 nivel 1 y variante Equilibrada desde el inicio")
	-- Una tecnología demasiado adelantada se consulta pero no se inicia.
	local far = nil
	for _, n in Catalog.RESEARCH.motores.nodes do
		if not far and n.year > Rules.year(App.g) + Catalog.RESEARCH_RULES.aheadMaxYears then
			far = n
		end
	end
	check(far ~= nil and named("Nodo_" .. far.id) ~= nil, "una tecnología futura se muestra: " .. tostring(far and far.name))
	eq(named("Nodo_" .. far.id):GetAttribute("estado"), "bloqueada", "bloqueada")
	check(named("Investigar_" .. far.id) == nil, "sin botón de investigar")
	check(not App.request("startResearch", { id = far.id }).ok, "el servidor tampoco la inicia")
	-- 9–12. Confirmación: abrirla no cobra; confirmar cobra una sola vez; adelanto con su recargo.
	local pick = nil
	for _, key in { "motores", "chasis", "seguridad", "tecnologia" } do
		for _, n in Catalog.RESEARCH[key].nodes do
			local st, _, ahead = R.status(App.g, n)
			if not pick and st == "disponible" and ahead > 0 then
				pick = n
			end
		end
	end
	check(pick ~= nil, "hay una tecnología adelantada disponible")
	App.ui.tabs.investigacion = pick.category
	App.forceRender()
	M.task.wait()
	local card = named("Nodo_" .. pick.id)
	check(card:GetAttribute("adelanto") > 0 and find("Adelantada") ~= nil, "la tarjeta marca el adelanto sin dejar de estar disponible")
	local pi, cost, days, detail = Rules.researchCost(App.g, pick)
	local a = detail.ahead
	check(math.abs(detail.penalty.money - 0.15 * a) < 1e-9 and math.abs(detail.penalty.pi - 0.15 * a) < 1e-9 and math.abs(detail.penalty.days - 0.10 * a) < 1e-9, "recargo de " .. a .. " años: +" .. 15 * a .. " % dinero y PI, +" .. 10 * a .. " % días")
	check(cost >= detail.base.money and pi >= detail.base.pi and days >= detail.base.days, "sobre los valores base")
	local m0, rp0, n0 = App.g.money, App.g.rp, #App.g.research.projects
	clickN("Investigar_" .. pick.id)
	eq(topKind(), "research", "abre la confirmación")
	for _, n in { "CostoInvestigacion", "PIInvestigacion", "DuracionInvestigacion", "Beneficios", "ConfirmarInvestigacion", "VolverInvestigacion" } do
		check(named(n) ~= nil, "la confirmación muestra " .. n)
	end
	check(find("no podrá cancelarse") ~= nil and find("Los recursos se descontarán al confirmar") ~= nil, "advertencia")
	check(find(Util.money(cost)) ~= nil, "costo definitivo")
	M.task.wait()
	check(App.g.money == m0 and App.g.rp == rp0 and #App.g.research.projects == n0, "abrir la confirmación no cobra")
	clickN("VolverInvestigacion")
	check(not dialogOpen() and App.g.money == m0, "Volver no cobra")
	clickN("Investigar_" .. pick.id)
	clickN("ConfirmarInvestigacion")
	check(waitFor(function()
		return Rules.researchProject(App.g, pick.id) ~= nil
	end), "confirmar la inicia")
	eq(App.g.money, m0 - cost, "descuenta el dinero una vez")
	eq(App.g.rp, rp0 - pi, "y los PI una vez")
	-- 10. Duplicada: el botón ya no aparece y el servidor la rechaza sin cobrar.
	check(named("Investigar_" .. pick.id) == nil, "en curso: sin botón")
	local again = App.request("startResearch", { id = pick.id })
	check(not again.ok, "una segunda solicitud se rechaza")
	eq(App.g.money, m0 - cost, "sin doble cobro")
	-- 5 y 13. Otra en curso de otra categoría: la franja muestra las dos.
	local other = nil
	for _, key in { "tecnologia", "seguridad", "chasis", "motores" } do
		if key ~= pick.category then
			for _, n in Catalog.RESEARCH[key].nodes do
				if not other and R.status(App.g, n) == "disponible" then
					other = n
				end
			end
		end
	end
	check(App.request("startResearch", { id = other.id }).ok, "segunda investigación simultánea")
	App.ui.tabs.investigacion = "chasis"
	App.forceRender()
	M.task.wait()
	check(named("Proyecto_" .. pick.id) ~= nil and named("Proyecto_" .. other.id) ~= nil, "la franja muestra las de todas las categorías")
	-- 14. Con la pantalla abierta (empresa en pausa) no avanzan; cambiar de categoría no las reinicia.
	local p0 = Rules.researchProject(App.g, pick.id).progress
	advance(5)
	eq(Rules.researchProject(App.g, pick.id).progress, p0, "en pausa no avanzan")
	clickN("Pestana_tecnologia")
	eq(Rules.researchProject(App.g, pick.id).progress, p0, "navegar no reinicia el progreso")
	App.go("juego")
	M.task.wait()
	noErrors("Centro de investigación")
end)

test("Cambiar de empresa: no se arrastran borradores ni ids de la anterior", function()
	App.closeAllDialogs()
	local slots = {}
	for k, v in App.profile.slots do
		if v then
			table.insert(slots, k)
		end
	end
	table.sort(slots)
	if #slots < 2 then
		check(true, "sin dos empresas no aplica")
		return
	end
	local function open(slot: string)
		if App.g then
			App.request("leaveCompany", {})
			waitFor(function()
				return App.g == nil
			end)
		end
		App.request("selectSlot", { slot = slot })
		waitFor(function()
			return App.g ~= nil
		end)
		if App.screens.intro.active() then
			App.screens.intro.finish()
		end
	end
	open(slots[1])
	App.ui.coName = "Nombre a medio escribir"
	App.ui.campaignDraft = { kind = "modelo", designId = "d-de-la-otra" }
	App.ui.reviewsSeen["l3"] = true
	open(slots[2])
	check(App.ui.coName == nil and App.ui.campaignDraft == nil, "el nombre y la campaña a medio armar no pasan a la otra empresa")
	check(App.ui.reviewsSeen["l3"] == nil, "las reseñas vistas se cuentan por empresa (ids de lote repetidos)")
	noErrors("Cambio de empresa")
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


test("Editor de oficinas: entrar desde Instalaciones, colocar, comprar una vez, mover, rechazos, reenvíos, ampliación, cambio de empresa y limpieza", function()
	local Office = require("./.build-ui/shared/Office")
	local OfficeCatalog = require("./.build-ui/shared/OfficeCatalog")
	local Editor = require("./.build-ui/client/OfficeEditor")
	local Scene = require("./.build-ui/client/OfficeScene")
	local OfficeCamera = require("./.build-ui/client/OfficeCamera")
	App.closeAllDialogs()
	if App.g then
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
	end
	-- 1. Empresa nueva en una ranura libre.
	local slot
	for _, k in { "1", "2", "3", "4" } do
		if App.profile.slots[k] == nil and (tonumber(k) <= 2 or (App.profile.unlocked or {})[k]) then
			slot = k
			break
		end
	end
	check(slot ~= nil, "hay una ranura libre")
	local cr = App.request("createCompany", { slot = slot, name = "Oficinas SA", color = "#FF8A3D", logo = "pico" })
	check(cr.ok, "empresa creada: " .. tostring(cr.msg))
	waitFor(function()
		return App.g ~= nil
	end)
	if App.screens.intro.active() then
		App.screens.intro.finish()
	end
	local sess = Sessions.instance.list[player]
	sess.game.money = 100000
	Sessions.instance:push(sess)
	waitFor(function()
		return App.g.money == 100000
	end)
	App.ui.facSel = "offices"
	App.go("compania")
	M.task.wait()
	clickN("PersonalizarOficina")
	M.task.wait()
	eq(App.ui.route, "oficina", "Instalaciones › Oficinas centrales › Personalizar oficina abre el editor")
	eq(App.cameraOwner, "office", "la cámara es del editor")
	check(App.menuPaused(), "la empresa queda en pausa (setUiPause)")
	local folder = M.services.Workspace:FindFirstChild("EditorOficina")
	check(folder ~= nil and folder:FindFirstChild("Habitaciones") ~= nil, "escena de la oficina en el Workspace (solo en este cliente)")
	check(named("LateralOficina") ~= nil and named("BarraOficina") ~= nil and named("AccionesOficina") ~= nil and named("DineroOficina") ~= nil, "barra superior, panel lateral y acciones")
	OfficeCamera.update(1 / 60)
	local cam = M.services.Workspace.CurrentCamera
	check((cam.CFrame.Position - Scene.ORIGIN).Magnitude < 400, "la cámara encuadra la oficina")
	-- Las paredes que miran a la cámara se vuelven casi transparentes.
	local faded, solid = 0, 0
	for _, w in Scene.wallParts() do
		if w.part.Transparency >= Scene.WALL_FADED - 1e-6 then
			faded += 1
		else
			solid += 1
		end
	end
	check(faded > 0 and solid > 0, "paredes semitransparentes según la cámara (" .. faded .. "/" .. solid .. ")")
	-- 2. Escritorio y silla iniciales en el inventario.
	local o = App.g.office
	eq(#o.placed, 0, "nada colocado")
	check(named("Inventario_escritorio_metal_1970") ~= nil and named("Inventario_silla_oficina_1970") ~= nil, "el catálogo los muestra en el inventario (gratis)")
	local R = "oficina_principal"
	local function place(itemId: string, x: number, y: number, rot: number?): any
		Editor.startPlace(itemId)
		local st = Editor.state()
		while st.rot ~= (rot or 0) do
			Editor.rotate(1)
		end
		Editor.hover(R, x, y)
		return Editor.confirm()
	end
	-- 3. Colocarlos sin pagar (la posición del cursor se ajusta a la cuadrícula).
	local m0 = App.g.money
	local r = place("escritorio_metal_1970", 5.1, 2.6)
	check(r and r.ok and r.paid == 0, "escritorio colocado gratis")
	r = place("silla_oficina_1970", 5.4, 3.4)
	check(r and r.ok and r.paid == 0, "silla colocada gratis")
	eq(App.g.money, m0, "sin pagar")
	eq(#App.g.office.placed, 2, "dos muebles en la oficina")
	check(Scene.furnitureModel(App.g.office.placed[1].id) ~= nil, "el modelo aparece en la escena")
	-- 4. Comprar uno nuevo: se cobra exactamente una vez; se pueden poner varios seguidos sin cerrar el catálogo.
	local lamp = OfficeCatalog.item("lampara_pie_1970")
	r = place(lamp.id, 8.5, 6.5)
	check(r and r.ok and r.paid == lamp.price, "lámpara comprada")
	eq(App.g.money, m0 - lamp.price, "cobrada una vez")
	eq(Editor.state().mode, "place", "sigue en modo colocar para poner otra")
	Editor.hover(R, 7.5, 6.5)
	r = Editor.confirm()
	check(r and r.ok and r.paid == lamp.price, "segunda lámpara")
	eq(App.g.money, m0 - 2 * lamp.price, "dos lámparas, dos cobros")
	-- 13. Reenviar la misma operación (mismo requestId): no cobra de nuevo.
	Editor.hover(R, 6.5, 6.5)
	local fixed = "reenvio-oficina-0001"
	r = Editor.confirm(fixed)
	check(r and r.ok, "tercera lámpara")
	local money3 = App.g.money
	-- Reenvío de la misma solicitud (por ejemplo, si se perdió la respuesta): mismo requestId.
	local dup = App.request("officePlace", { item = lamp.id, room = R, x = 6.5, y = 6.5, rot = 0 }, { requestId = fixed })
	check(dup and dup.duplicate and dup.ok, "el reenvío se reconoce y devuelve la respuesta original")
	eq(App.g.money, money3, "sin segundo cobro")
	eq(Office.owned(App.g.office, lamp.id), 3, "sin unidades de más")
	-- 6-7. Rechazos: fuera del plano (también en diagonal), superposición y accesos. La vista previa queda roja,
	-- no se envía nada y no cambia el dinero.
	local beforeOffice = serde.encode("json", App.g.office)
	local mb = App.g.money
	Editor.startPlace("planta_interior_1970")
	Editor.rotate(1) -- 45°
	Editor.hover(R, 0.6, 7.4)
	check(Editor.state().hover.valid == false and string.find(Editor.state().hover.reason, "sale", 1, true) ~= nil, "diagonal contra la pared: roja")
	local rr = Editor.confirm()
	check(rr and not rr.ok, "no se confirma")
	Editor.rotate(-1)
	Editor.hover(R, 0.5, 3.5)
	check(not Editor.state().hover.valid and string.find(Editor.state().hover.reason, "acceso", 1, true) ~= nil, "sobre el acceso: roja")
	check(not Editor.confirm().ok, "no se coloca sobre un acceso")
	Editor.hover(R, 8.5, 6.5)
	check(not Editor.state().hover.valid and string.find(Editor.state().hover.reason, "ocupado", 1, true) ~= nil, "sobre otra lámpara: roja")
	check(named("EstadoColocacion") ~= nil and named("ConfirmarColocacion") ~= nil, "la barra muestra el motivo y la confirmación")
	-- El servidor rechaza lo mismo aunque el cliente lo envíe directo.
	check(not App.request("officePlace", { item = "planta_interior_1970", room = R, x = 0.5, y = 3.5, rot = 0 }).ok, "el servidor también rechaza el acceso")
	eq(App.g.money, mb, "los rechazos no cobran")
	eq(serde.encode("json", App.g.office), beforeOffice, "ni cambian la oficina")
	Editor.cancel()
	eq(Editor.state().mode, "idle", "cancelar la vista previa (gratis)")
	-- 5. Elegir un mueble colocado, moverlo y girarlo sin pagar.
	local desk = App.g.office.placed[1]
	eq(Editor.selectAt(R, desk.x, desk.y), desk.id, "clic sobre el escritorio lo elige")
	check(named("MoverMueble") ~= nil and named("GuardarMueble") ~= nil, "acciones del mueble elegido")
	Editor.startMove()
	Editor.hover(R, 3.1, 6.4)
	r = Editor.confirm()
	check(r and r.ok, "escritorio movido")
	local moved = Office.find(App.g.office, desk.id)
	check(moved.x == 3 and moved.y == 6.5, "nueva posición ajustada a la cuadrícula")
	Editor.selectAt(R, moved.x, moved.y)
	r = Editor.rotateSelected(1)
	check(r and r.ok and Office.find(App.g.office, desk.id).rot == 45, "girado 45° en su lugar")
	eq(App.g.money, mb, "mover y girar es gratis")
	-- 8-9. Guardarlo en el inventario y volver a colocarlo gratis.
	Editor.selectAt(R, 8.5, 6.5)
	local lampId = Editor.state().instance
	check(lampId ~= nil, "lámpara elegida")
	r = Editor.removeSelected()
	check(r and r.ok, "lámpara guardada")
	eq(Office.count(App.g.office, lamp.id), 1, "vuelve al inventario")
	eq(App.g.money, mb, "sin reembolso")
	r = place(lamp.id, 8.5, 1.5)
	check(r and r.ok and r.paid == 0, "reutilizada sin pagar")
	-- 10. Guardar, salir al menú y volver a entrar: se conserva todo.
	local layout = serde.encode("json", App.g.office.placed)
	App.request("saveNow", {})
	App.go("juego")
	M.task.wait()
	check(not Editor.isActive() and M.services.Workspace:FindFirstChild("EditorOficina") == nil, "al salir del editor se libera la escena")
	eq(App.cameraOwner, "scene", "y la cámara vuelve a la de gestión")
	App.request("leaveCompany", {})
	waitFor(function()
		return App.g == nil
	end)
	App.request("selectSlot", { slot = slot })
	waitFor(function()
		return App.g ~= nil
	end)
	eq(serde.encode("json", App.g.office.placed), layout, "distribución conservada al volver a entrar")
	-- 11. Otra empresa: oficina propia y estado del editor limpio.
	App.go("oficina")
	M.task.wait()
	Editor.selectAt(R, 8.5, 1.5)
	check(Editor.state().instance ~= nil, "algo elegido en esta empresa")
	App.go("juego")
	App.request("leaveCompany", {})
	waitFor(function()
		return App.g == nil
	end)
	local other
	for k, v in App.profile.slots do
		if v and k ~= slot then
			other = k
		end
	end
	if other then
		App.request("selectSlot", { slot = other })
		waitFor(function()
			return App.g ~= nil
		end)
		if App.screens.intro.active() then
			App.screens.intro.finish()
		end
		App.go("oficina")
		M.task.wait()
		check(Editor.state().instance == nil and Editor.state().mode == "idle", "el estado del editor no pasa a otra empresa")
		check(serde.encode("json", App.g.office.placed) ~= layout, "la otra empresa tiene su propia distribución")
		App.go("juego")
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
		App.request("selectSlot", { slot = slot })
		waitFor(function()
			return App.g ~= nil
		end)
	end
	-- 12. Ampliación de oficinas terminada: el editor muestra el plano nuevo sin perder ni duplicar muebles.
	local owned = {}
	for id in OfficeCatalog.FURNITURE do
		owned[id] = Office.owned(App.g.office, id)
	end
	sess = Sessions.instance.list[player]
	sess.game.money = 1e9
	sess.game.counters.unitsSold = 1e6
	sess.game.reputation = 5
	Sessions.instance:push(sess)
	App.go("oficina")
	M.task.wait()
	check(App.request("upgradeFacility", { kind = "offices" }).ok, "obra de oficinas iniciada")
	App.request("setSpeed", { speed = 3 })
	App.go("juego") -- la empresa avanza fuera del editor
	for _ = 1, 400 do
		advance(1)
		if App.g.sede >= 2 then
			break
		end
	end
	App.request("setSpeed", { speed = 1 })
	eq(App.g.sede, 2, "oficinas nivel 2")
	App.go("oficina")
	M.task.wait()
	eq(App.g.office.level, 2, "plano del nivel 2")
	local rooms = M.services.Workspace.EditorOficina.Habitaciones
	check(rooms:FindFirstChild("Habitacion_sala_reuniones") ~= nil, "la sala nueva aparece en el editor")
	for id, n in owned do
		eq(Office.owned(App.g.office, id), n, "sin pérdidas ni copias: " .. id)
	end
	-- 14. Entrar y salir varias veces: sin conexiones nuevas ni escenas duplicadas.
	local function live(sigName: string, inst: any): number
		local sig = rawget(inst, "__signals")[sigName]
		local n = 0
		for _, h in (sig and sig.handlers) or {} do
			if h.connected then
				n += 1
			end
		end
		return n
	end
	local UIS, RS = M.services.UserInputService, M.services.RunService
	App.go("juego")
	M.task.wait()
	local a0, b0, c0 = live("InputBegan", UIS), live("InputChanged", UIS), live("RenderStepped", RS)
	App.renderError = nil
	for _ = 1, 4 do
		App.go("oficina")
		M.task.wait()
		Editor.startPlace("planta_interior_1970")
		Editor.hover(R, 2.5, 1.5)
		App.go("juego")
		M.task.wait()
	end
	eq(live("InputBegan", UIS), a0, "InputBegan sin conexiones nuevas")
	eq(live("InputChanged", UIS), b0, "InputChanged sin conexiones nuevas")
	eq(live("RenderStepped", RS), c0, "RenderStepped sin conexiones nuevas")
	local scenes = 0
	for _, d in M.services.Workspace:GetChildren() do
		if d.Name == "EditorOficina" then
			scenes += 1
		end
	end
	eq(scenes, 0, "ninguna escena del editor queda en el Workspace")
	check(App.renderError == nil, "sin errores al entrar y salir")
	noErrors("Editor de oficinas")
end)


test("Editor de oficinas (estabilización): inventario inicial, cursor fuera de las habitaciones, reintentos sin cobro doble y medidas de los modelos", function()
	local Office = require("./.build-ui/shared/Office")
	local OfficeCatalog = require("./.build-ui/shared/OfficeCatalog")
	local Editor = require("./.build-ui/client/OfficeEditor")
	local Scene = require("./.build-ui/client/OfficeScene")
	local OfficeModels = require("./.build-ui/client/OfficeModels")
	-- Medidas: cada modelo provisional entra en las casillas que ocupa (y en su tamaño declarado).
	local CELL = OfficeCatalog.CELL
	for id, item in OfficeCatalog.FURNITURE do
		check(item.size[1] <= item.cells[1] * CELL + 1e-6 and item.size[3] <= item.cells[2] * CELL + 1e-6, id .. ": tamaño declarado dentro de sus casillas")
		local m = OfficeModels.build(item)
		local hx, hz = item.cells[1] * CELL / 2, item.cells[2] * CELL / 2
		local worst = 0
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") and d.Transparency < 1 then
				local p, sz = d.CFrame.Position, d.Size
				worst = math.max(worst, math.abs(p.X) + sz.X / 2 - hx, math.abs(p.Z) + sz.Z / 2 - hz)
				check(p.Y - sz.Y / 2 >= -1e-6 and p.Y + sz.Y / 2 <= item.size[2] + 1e-6, id .. "/" .. d.Name .. ": entre el piso y su alto")
			end
		end
		check(worst <= 1e-6, id .. ": ninguna pieza sobresale de sus casillas (" .. string.format("%.2f", worst) .. ")")
		m:Destroy()
	end
	-- Empresa nueva para empezar con el inventario inicial.
	App.closeAllDialogs()
	if App.g then
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
	end
	local slot
	for _, k in { "1", "2", "3", "4" } do
		if App.profile.slots[k] == nil and (tonumber(k) <= 2 or (App.profile.unlocked or {})[k]) then
			slot = k
			break
		end
	end
	if not slot then
		-- Sin ranura libre: se libera la última de esta prueba anterior.
		for k, v in App.profile.slots do
			if v and v.name == "Oficinas SA" then
				App.request("deleteCompany", { slot = k, confirm = "Oficinas SA" })
				slot = k
			end
		end
	end
	check(slot ~= nil, "ranura libre")
	local cr = App.request("createCompany", { slot = slot, name = "Muebles Uno", color = "#FF8A3D", logo = "pico" })
	check(cr.ok, "empresa creada: " .. tostring(cr.msg))
	waitFor(function()
		return App.g ~= nil
	end)
	if App.screens.intro.active() then
		App.screens.intro.finish()
	end
	local sess = Sessions.instance.list[player]
	sess.game.money = 100000
	Sessions.instance:push(sess)
	waitFor(function()
		return App.g.money == 100000
	end)
	App.go("oficina")
	M.task.wait()
	-- 1. Pestaña Inventario: escritorio y silla iniciales, para colocar gratis.
	clickN("TabInventario")
	M.task.wait()
	check(named("Mueble_escritorio_metal_1970") ~= nil and named("Mueble_silla_oficina_1970") ~= nil, "el inventario muestra el escritorio y la silla")
	check(named("Inventario_escritorio_metal_1970") ~= nil and named("Inventario_silla_oficina_1970") ~= nil, "con su cantidad y «gratis»")
	check(named("Mueble_lampara_pie_1970") == nil, "solo lo propio (no el catálogo)")
	local btn = named("Colocar_escritorio_metal_1970")
	check(btn ~= nil and string.find(btn:GetAttribute("label"), "gratis", 1, true) ~= nil, "botón «Colocar gratis»")
	clickN("Colocar_escritorio_metal_1970")
	M.task.wait()
	eq(Editor.state().mode, "place", "elegir desde el inventario empieza la colocación")
	local R = "oficina_principal"
	-- 2. Cursor fuera de las habitaciones: la vista previa desaparece y confirmar no usa la posición anterior.
	Editor.hover(R, 5, 2.5)
	check(Editor.state().hover and Editor.state().hover.valid, "dentro: posición válida")
	check(Scene._state.preview ~= nil, "con vista previa")
	Editor.hover(nil, nil, nil)
	check(Editor.state().hover == nil, "fuera: se olvida la posición anterior")
	check(Scene._state.preview == nil, "y la vista previa desaparece")
	check(named("EstadoColocacion") ~= nil and string.find(named("EstadoColocacion").Text, "Fuera", 1, true) ~= nil, "la barra lo indica")
	local placed0 = #App.g.office.placed
	check(Editor.confirm() == nil, "confirmar fuera de las habitaciones no envía nada")
	eq(#App.g.office.placed, placed0, "ni coloca en la posición anterior")
	Editor.hover(R, 5, 2.5)
	local r = Editor.confirm()
	check(r and r.ok and r.paid == 0, "de vuelta adentro se coloca gratis")
	clickN("TabInventario")
	M.task.wait()
	check(named("Mueble_escritorio_metal_1970") == nil and named("Mueble_silla_oficina_1970") ~= nil, "el escritorio deja el inventario y la silla sigue")
	-- 3. Reintentos: la respuesta de una compra se pierde (el servidor la aplicó). El editor conserva el id.
	local rf = M.services.ReplicatedStorage.CarEmpireRemotes.Request
	local orig = rawget(rf, "__props").OnServerInvoke
	local lamp = OfficeCatalog.item("lampara_pie_1970")
	local m0 = App.g.money
	rawget(rf, "__props").OnServerInvoke = function(pl, action, body)
		local res = orig(pl, action, body)
		rawget(rf, "__props").OnServerInvoke = orig -- solo esta vez
		error("respuesta perdida")
		return res
	end
	Editor.startPlace(lamp.id)
	Editor.hover(R, 8.5, 6.5)
	r = Editor.confirm()
	check(r and r.noResponse, "sin respuesta")
	check(Editor.state().pending ~= nil and Editor.state().pending.requestId == r.requestId, "la operación queda pendiente con su id")
	check(named("ReintentarOperacion") ~= nil, "la barra ofrece reintentar")
	waitFor(function()
		return App.g.money == m0 - lamp.price
	end)
	eq(App.g.money, m0 - lamp.price, "el estado del servidor se reconcilia (se aplicó una vez)")
	-- Confirmar otra cosa primero reintenta la pendiente (mismo id): no hay cobro doble.
	Editor.hover(R, 7.5, 6.5)
	r = Editor.confirm()
	check(r and r.duplicate, "el reintento se reconoce como ya aplicado")
	check(Editor.state().pending == nil, "la operación queda resuelta")
	eq(App.g.money, m0 - lamp.price, "un solo cobro")
	eq(Office.owned(App.g.office, lamp.id), 1, "una sola lámpara")
	-- Pérdida ANTES de llegar al servidor: el reintento la aplica una vez.
	local m1 = App.g.money
	rawget(rf, "__props").OnServerInvoke = function()
		rawget(rf, "__props").OnServerInvoke = orig
		error("sin conexión")
	end
	Editor.hover(R, 7.5, 6.5)
	r = Editor.confirm()
	check(r and r.noResponse and Editor.state().pending ~= nil, "pendiente sin aplicar")
	eq(App.g.money, m1, "todavía sin cobro")
	r = Editor.retry()
	check(r and r.ok and not r.duplicate and r.paid == lamp.price, "el reintento la aplica")
	eq(App.g.money, m1 - lamp.price, "cobrada una vez")
	r = App.request("officePlace", { item = lamp.id, room = R, x = 7.5, y = 6.5, rot = 0 }, { requestId = Editor.state().pending and Editor.state().pending.requestId or "x-ya-resuelto-0001" })
	eq(App.g.money, m1 - lamp.price, "sin cobros extra")
	eq(Office.owned(App.g.office, lamp.id), 2, "dos lámparas en total")
	Editor.cancel()
	App.go("juego")
	M.task.wait()
	noErrors("Estabilización del editor de oficinas")
end)


test("Remodelación de interiores: vista previa gratis, presupuesto, confirmación, rechazos, reintentos, persistencia, empresas, ampliación y escena", function()
	local Office = require("./.build-ui/shared/Office")
	local OfficeCatalog = require("./.build-ui/shared/OfficeCatalog")
	local Editor = require("./.build-ui/client/OfficeEditor")
	local Scene = require("./.build-ui/client/OfficeScene")
	local F = OfficeCatalog.FINISHES
	App.closeAllDialogs()
	if App.g then
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
	end
	-- Empresa nueva (se libera una ranura de pruebas anteriores si hace falta).
	local slot
	for _, k in { "1", "2", "3", "4" } do
		if App.profile.slots[k] == nil and (tonumber(k) <= 2 or (App.profile.unlocked or {})[k]) then
			slot = k
			break
		end
	end
	if not slot then
		for k, v in App.profile.slots do
			if v and (v.name == "Muebles Uno" or v.name == "Oficinas SA") then
				App.request("deleteCompany", { slot = k, confirm = v.name })
				slot = k
				break
			end
		end
	end
	check(slot ~= nil, "ranura libre")
	check(App.request("createCompany", { slot = slot, name = "Remodela Uno", color = "#FF8A3D", logo = "pico" }).ok, "empresa creada")
	waitFor(function()
		return App.g ~= nil
	end)
	if App.screens.intro.active() then
		App.screens.intro.finish()
	end
	local sess = Sessions.instance.list[player]
	sess.game.money = 5000
	Sessions.instance:push(sess)
	waitFor(function()
		return App.g.money == 5000
	end)
	App.go("oficina")
	M.task.wait()
	local R = "oficina_principal"
	local room = OfficeCatalog.room(App.g.office.level, R)
	-- Un mueble colocado antes de remodelar.
	Editor.startPlace("escritorio_metal_1970")
	Editor.hover(R, 5, 2.5)
	check(Editor.confirm().ok, "escritorio colocado")
	Editor.cancel()
	local furniture = serde.encode("json", App.g.office.placed)
	local deskModel = Scene.furnitureModel(App.g.office.placed[1].id)
	local deskCf = deskModel:GetPivot()
	-- Sección Remodelación.
	clickN("SeccionRemodelacion")
	M.task.wait()
	eq(Editor.state().section, "remodelacion", "sección Remodelación")
	check(named("Tipo_floor") and named("Tipo_wall") and named("Tipo_covering") and named("Tipo_lighting"), "cuatro categorías")
	check(named("RemodelacionTitulo") ~= nil and named("RemodelacionMedidas") ~= nil, "habitación y medidas en el presupuesto")
	eq(Scene._state.highlighted, R, "la habitación elegida se resalta")
	-- 2. Vista previa: cambia la escena, no el dinero, ni g.office.finishes, ni se envía nada.
	local money0, finishes0 = App.g.money, serde.encode("json", App.g.office.finishes)
	local inv0 = M.stats.invokes
	clickN("Probar_piso_parquet_1970")
	M.task.wait()
	eq(Scene.roomParts(R).floor.Material, M.Enum.Material.WoodPlanks, "el piso de la escena pasa a parquet")
	eq(App.g.money, money0, "sin cobro")
	eq(serde.encode("json", App.g.office.finishes), finishes0, "sin tocar los acabados guardados")
	eq(M.stats.invokes, inv0, "sin solicitudes al servidor")
	check(named("Previsto_piso_parquet_1970") ~= nil, "la tarjeta marca la vista previa")
	-- Reemplazar la elección cuantas veces se quiera.
	Editor.choose("floor", "piso_alfombra_1970")
	eq(Scene.roomParts(R).floor.Material, M.Enum.Material.Fabric, "alfombra")
	Editor.choose("floor", "piso_parquet_1970")
	-- 16. Los cuatro tipos se ven en la escena.
	Editor.choose("wall", "pared_beige_1970")
	Editor.choose("covering", "madera_1970")
	Editor.choose("lighting", "luz_calida_1970")
	local rp = Scene.roomParts(R)
	eq(rp.walls[1].part.Color, M.Color3.fromHex(F.wall.pared_beige_1970.color), "pintura beige en las paredes")
	local covers, wood = 0, 0
	for _, w in rp.walls do
		if w.cover then
			covers += 1
			if w.cover.Material == M.Enum.Material.Wood then
				wood += 1
			end
		end
	end
	check(covers == #rp.walls and wood == covers, "revestimiento de madera en cada tramo de pared (" .. covers .. ")")
	local fixtures, lights = 0, 0
	for _, d in rp.lights:GetDescendants() do
		if d.Name == "Plafon" then
			fixtures += 1
		elseif d.ClassName == "PointLight" then
			lights += 1
			check(d.Color == M.Color3.fromHex(F.lighting.luz_calida_1970.light.color), "luz cálida")
		end
	end
	eq(fixtures, Office.finishQuantity(room, F.lighting.luz_calida_1970), "una luminaria por cada una presupuestada")
	check(lights >= 1 and lights <= Scene.MAX_LIGHTS, "pocas luces locales (" .. lights .. ")")
	eq(M.services.Lighting.Brightness, M.services.Lighting.Brightness, "sin tocar Lighting")
	-- 14. Los muebles no se mueven al cambiar materiales.
	check(deskModel.Parent ~= nil and (deskModel:GetPivot().Position - deskCf.Position).Magnitude < 1e-6, "el escritorio sigue en su lugar")
	eq(serde.encode("json", App.g.office.placed), furniture, "la distribución no cambia")
	-- 4. Presupuesto: suma de los cambios efectivos con las medidas reales del plano.
	local expected = room.w * room.d * F.floor.piso_parquet_1970.price + builtWalls(room) * (F.wall.pared_beige_1970.price + F.covering.madera_1970.price) + math.ceil(room.w * room.d / OfficeCatalog.LIGHT_AREA) * F.lighting.luz_calida_1970.price
	local cost = Editor.quote()
	eq(cost, expected, "total del presupuesto")
	check(named("Presupuesto_floor") ~= nil and named("RemodelacionTotal") ~= nil, "líneas y total en el panel")
	-- 7. Fondos insuficientes: no se puede confirmar.
	check(expected > App.g.money, "la remodelación completa supera el dinero (" .. expected .. ")")
	local btn = named("ConfirmarRemodelacion")
	check(btn ~= nil and btn:GetAttribute("disabled") == true, "botón deshabilitado")
	inv0 = M.stats.invokes
	local r = Editor.confirmRemodel()
	check(r and not r.ok and string.find(r.msg, "Fondos", 1, true) ~= nil, "explica los fondos insuficientes")
	eq(M.stats.invokes, inv0, "ni siquiera se envía")
	-- 3. Restaurar selección y cancelar: vuelve lo instalado, sin cobrar.
	clickN("RestaurarSeleccion")
	M.task.wait()
	eq(Scene.roomParts(R).floor.Material, M.Enum.Material.Concrete, "restaurar: vuelve el cemento")
	check(not Editor.hasDraft(R), "sin vista previa")
	Editor.choose("floor", "piso_parquet_1970")
	Editor.setRoom("oficina_principal")
	clickN("CancelarRemodelacion")
	M.task.wait()
	eq(Scene.roomParts(R).floor.Material, M.Enum.Material.Concrete, "cancelar: vuelve el aspecto instalado")
	eq(App.g.money, money0, "sin cobro")
	-- 1/4. Remodelar con varios materiales y pagar el total exacto.
	sess.game.money = 100000
	Sessions.instance:push(sess)
	waitFor(function()
		return App.g.money == 100000
	end)
	Editor.choose("floor", "piso_parquet_1970")
	Editor.choose("wall", "pared_beige_1970")
	Editor.choose("covering", "madera_1970")
	Editor.choose("lighting", "luz_calida_1970")
	r = Editor.confirmRemodel()
	check(r and r.ok and r.paid == expected, "remodelación confirmada: " .. tostring(r and r.msg))
	eq(App.g.money, 100000 - expected, "pagó el total exacto una vez")
	eq(App.g.office.finishes[R].floor, "piso_parquet_1970", "acabados instalados")
	check(not Editor.hasDraft(R), "la vista previa queda instalada")
	eq(serde.encode("json", App.g.office.placed), furniture, "los muebles siguen igual")
	-- 5. Lo instalado no se cobra de nuevo.
	App.forceRender()
	M.task.wait()
	Editor.setKind("floor")
	App.forceRender()
	M.task.wait()
	check(named("Instalado_piso_parquet_1970") ~= nil, "el parquet figura instalado")
	check(not Editor.choose("floor", "piso_parquet_1970") or not Editor.hasDraft(R), "elegir lo instalado no genera cambios")
	r = Editor.confirmRemodel()
	check(r and not r.ok, "sin cambios no hay nada que cobrar")
	eq(App.g.money, 100000 - expected, "sin cobro")
	-- 6. Material futuro: bloqueado en el catálogo y rechazado.
	F.floor.prueba_2001 = { id = "prueba_2001", name = "Porcelanato", year = 2001, price = 10, unit = "casilla", material = "Marble", materialName = "Cerámica" }
	App.forceRender()
	M.task.wait()
	local fb = named("Probar_prueba_2001")
	check(fb ~= nil and fb:GetAttribute("disabled") == true, "material futuro bloqueado (y el editor lo muestra sin cambios en el código)")
	check(not Editor.choose("floor", "prueba_2001"), "no se puede probar")
	check(not App.request("officeRemodel", { room = R, changes = { floor = "prueba_2001" }, rev = App.g.office.rev, quote = room.w * room.d * 10, companyId = App.g.company.id }).ok, "el servidor lo rechaza")
	F.floor.prueba_2001 = nil
	-- 8. Identificadores falsos.
	local m1 = App.g.money
	check(not App.request("officeRemodel", { room = R, changes = { floor = "piso_falso" }, rev = App.g.office.rev, quote = 0 }).ok, "id falso")
	check(not App.request("officeRemodel", { room = "falsa", changes = { floor = "piso_alfombra_1970" }, rev = App.g.office.rev, quote = 0 }).ok, "habitación falsa")
	check(not App.request("officeRemodel", { room = R, changes = { floor = "piso_alfombra_1970" }, rev = App.g.office.rev, quote = 1 }).ok, "precio inventado por el cliente")
	eq(App.g.money, m1, "ningún rechazo cobra")
	-- 9. Reintento sin cobro doble: se pierde la respuesta de una remodelación que el servidor aplicó.
	local rf = M.services.ReplicatedStorage.CarEmpireRemotes.Request
	local orig = rawget(rf, "__props").OnServerInvoke
	rawget(rf, "__props").OnServerInvoke = function(pl, action, body)
		local res = orig(pl, action, body)
		rawget(rf, "__props").OnServerInvoke = orig
		error("respuesta perdida")
		return res
	end
	local alfombra = room.w * room.d * F.floor.piso_alfombra_1970.price
	Editor.choose("floor", "piso_alfombra_1970")
	r = Editor.confirmRemodel()
	check(r and r.noResponse and Editor.state().pending ~= nil, "operación incierta guardada con su id")
	waitFor(function()
		return App.g.money == m1 - alfombra
	end)
	eq(App.g.money, m1 - alfombra, "el servidor la aplicó una vez")
	-- 11. Pendiente por empresa: cambiar de empresa no la pierde ni la mezcla.
	local pendingId = Editor.state().pending.requestId
	App.go("juego")
	App.request("leaveCompany", {})
	waitFor(function()
		return App.g == nil
	end)
	local other
	for k, v in App.profile.slots do
		if v and k ~= slot then
			other = k
			break
		end
	end
	if other then
		App.request("selectSlot", { slot = other })
		waitFor(function()
			return App.g ~= nil
		end)
		if App.screens.intro.active() then
			App.screens.intro.finish()
		end
		App.go("oficina")
		M.task.wait()
		check(Editor.state().pending == nil, "la otra empresa no hereda la operación incierta")
		check(not Editor.hasDraft(R), "ni vistas previas")
		-- 12. Independencia entre empresas: sus acabados son los propios.
		eq(App.g.office.finishes[R].floor, "piso_cemento", "la otra empresa conserva sus propios acabados (no la alfombra)")
		eq(Scene.lookOf(R), table.concat({ App.g.office.finishes[R].floor, App.g.office.finishes[R].wall, App.g.office.finishes[R].covering, App.g.office.finishes[R].lighting }, "|"), "la escena muestra los de esta empresa")
		-- Un reintento de la otra empresa llegando acá se rechaza (companyId).
		local wrong = App.request("officeRemodel", { room = R, changes = { floor = "piso_alfombra_1970" }, rev = App.g.office.rev, quote = alfombra, companyId = "c-otra-empresa" })
		check(not wrong.ok, "una operación de otra empresa no se aplica")
		App.go("juego")
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
	end
	App.request("selectSlot", { slot = slot })
	waitFor(function()
		return App.g ~= nil
	end)
	App.go("oficina")
	M.task.wait()
	check(Editor.state().pending ~= nil and Editor.state().pending.requestId == pendingId, "al volver, la operación incierta sigue con su id")
	-- Actualizar la vista no la descarta.
	Editor.refreshState()
	check(Editor.state().pending ~= nil, "actualizar la vista no la descarta")
	r = Editor.retry()
	check(r and r.duplicate, "el reintento se reconoce como ya aplicado")
	check(Editor.state().pending == nil, "y queda resuelta")
	eq(App.g.money, m1 - alfombra, "un solo cobro")
	eq(App.g.office.finishes[R].floor, "piso_alfombra_1970", "acabado aplicado una vez")
	-- 11. Independencia entre habitaciones (nivel 2) y 13. ampliación sin perder acabados.
	sess = Sessions.instance.list[player]
	sess.game.money = 1e9
	sess.game.counters.unitsSold = 1e6
	sess.game.reputation = 5
	Sessions.instance:push(sess)
	check(App.request("upgradeFacility", { kind = "offices" }).ok, "obra de oficinas")
	App.go("juego")
	App.request("setSpeed", { speed = 3 })
	for _ = 1, 400 do
		advance(1)
		if App.g.sede >= 2 then
			break
		end
	end
	App.request("setSpeed", { speed = 1 })
	eq(App.g.sede, 2, "oficinas nivel 2")
	App.go("oficina")
	M.task.wait()
	Editor.setSection("remodelacion")
	eq(App.g.office.finishes[R].floor, "piso_alfombra_1970", "la principal conserva sus acabados")
	eq(App.g.office.finishes.sala_reuniones.floor, "piso_cemento", "la sala nueva empieza con los básicos")
	Editor.setRoom("sala_reuniones")
	Editor.choose("wall", "pared_beige_1970")
	r = Editor.confirmRemodel()
	check(r and r.ok, "remodelar la sala nueva")
	eq(App.g.office.finishes[R].wall, "pared_beige_1970", "la principal no cambia por la sala")
	eq(App.g.office.finishes.sala_reuniones.wall, "pared_beige_1970", "la sala tiene su pintura")
	eq(App.g.office.finishes.sala_reuniones.floor, "piso_cemento", "y solo lo pedido")
	-- 10. Guardar, salir y volver: los acabados confirmados siguen; la vista previa no se guarda.
	Editor.setRoom(R)
	Editor.choose("floor", "piso_cemento")
	local saved = serde.encode("json", App.g.office.finishes)
	App.request("saveNow", {})
	App.go("juego")
	M.task.wait()
	check(not Editor.isActive() and M.services.Workspace:FindFirstChild("EditorOficina") == nil, "al salir se libera la escena (luces incluidas)")
	App.request("leaveCompany", {})
	waitFor(function()
		return App.g == nil
	end)
	App.request("selectSlot", { slot = slot })
	waitFor(function()
		return App.g ~= nil
	end)
	eq(serde.encode("json", App.g.office.finishes), saved, "acabados confirmados conservados; la vista previa no se guardó")
	-- 15. Abrir y cerrar el editor muchas veces sin fugas.
	local function live(sigName: string, inst: any): number
		local sig = rawget(inst, "__signals")[sigName]
		local n = 0
		for _, h in (sig and sig.handlers) or {} do
			if h.connected then
				n += 1
			end
		end
		return n
	end
	local UIS, RS = M.services.UserInputService, M.services.RunService
	local a0, b0, c0 = live("InputBegan", UIS), live("InputChanged", UIS), live("RenderStepped", RS)
	App.renderError = nil
	for _ = 1, 4 do
		App.go("oficina")
		M.task.wait()
		Editor.setSection("remodelacion")
		Editor.choose("lighting", "luz_fluorescente")
		Editor.choose("covering", "sin_revestimiento")
		App.go("juego")
		M.task.wait()
	end
	eq(live("InputBegan", UIS), a0, "InputBegan sin conexiones nuevas")
	eq(live("InputChanged", UIS), b0, "InputChanged sin conexiones nuevas")
	eq(live("RenderStepped", RS), c0, "RenderStepped sin conexiones nuevas")
	check(M.services.Workspace:FindFirstChild("EditorOficina") == nil, "ninguna escena ni luz queda en el Workspace")
	check(App.renderError == nil, "sin errores")
	noErrors("Remodelación")
end)


test("Remodelación en oficinas de nivel 1 a 5: todas las habitaciones con todos los acabados, pocas luces y sin restos", function()
	local Office = require("./.build-ui/shared/Office")
	local OfficeCatalog = require("./.build-ui/shared/OfficeCatalog")
	local Scene = require("./.build-ui/client/OfficeScene")
	for level = 1, 5 do
		local o = Office.new(level)
		Scene.buildRooms(o)
		local rooms = OfficeCatalog.plan(level).rooms
		for _, r in rooms do
			for _, fl in OfficeCatalog.finishList("floor") do
				for _, lt in OfficeCatalog.finishList("lighting") do
					local look = { floor = fl.id, wall = "pared_beige_1970", covering = "madera_1970", lighting = lt.id }
					Scene.applyLook(r.id, look)
					eq(Scene.lookOf(r.id), table.concat({ fl.id, "pared_beige_1970", "madera_1970", lt.id }, "|"), "nivel " .. level .. " · " .. r.id .. ": acabado aplicado")
				end
			end
			Scene.applyLook(r.id, OfficeCatalog.DEFAULT_FINISH)
		end
		local lights, covers = 0, 0
		for _, d in Scene._state.folder:GetDescendants() do
			if d.ClassName == "PointLight" then
				lights += 1
			elseif d.Name == "Revestimiento" then
				covers += 1
			end
		end
		check(lights <= #rooms * Scene.MAX_LIGHTS + 1, "nivel " .. level .. ": luces acotadas (" .. lights .. ")")
		eq(covers, 0, "nivel " .. level .. ": sin revestimientos huérfanos al volver a «sin revestimiento»")
		Scene.destroy()
	end
	check(Scene._state.folder == nil, "la escena se libera")
	noErrors("Remodelación por niveles")
end)


test("Remodelación en el editor, niveles 1 a 5: presupuesto igual a las paredes de la escena, cancelar, confirmar y MaterialVariant", function()
	local Office = require("./.build-ui/shared/Office")
	local OfficeCatalog = require("./.build-ui/shared/OfficeCatalog")
	local Editor = require("./.build-ui/client/OfficeEditor")
	local Scene = require("./.build-ui/client/OfficeScene")
	local F = OfficeCatalog.FINISHES
	local CELL = OfficeCatalog.CELL
	-- MaterialVariant: al pasar a un acabado sin variante se quita la anterior; con variante cargada se aplica.
	local probe = M.Instance.new("Part")
	probe.MaterialVariant = "ParquetViejo"
	Scene._applySurface(probe, F.floor.piso_alfombra_1970, "#000000")
	eq(probe.MaterialVariant, "", "sin variante en el acabado nuevo: se quita la anterior")
	local ms = M.Instance.new("Folder")
	ms.Name = "MaterialService"
	M.services.MaterialService = ms
	local mv = M.Instance.new("Folder")
	mv.Name = "ParquetDefinitivo"
	mv.Parent = ms
	F.floor.piso_parquet_1970.variant = "ParquetDefinitivo"
	Scene._applySurface(probe, F.floor.piso_parquet_1970, "#000000")
	eq(probe.MaterialVariant, "ParquetDefinitivo", "variante cargada: se aplica")
	F.floor.piso_alfombra_1970.variant = "AlfombraQueNoExiste"
	Scene._applySurface(probe, F.floor.piso_alfombra_1970, "#000000")
	eq(probe.MaterialVariant, "", "variante no cargada: se quita la anterior y queda el material provisional")
	eq(probe.Material, M.Enum.Material.Fabric, "con el material del acabado")
	F.floor.piso_parquet_1970.variant = nil
	F.floor.piso_alfombra_1970.variant = nil
	M.services.MaterialService = nil
	-- Empresa en curso (de la prueba anterior) con dinero para remodelar.
	if not App.g then
		for k, v in App.profile.slots do
			if v then
				App.request("selectSlot", { slot = k })
				break
			end
		end
		waitFor(function()
			return App.g ~= nil
		end)
	end
	if App.screens.intro.active() then
		App.screens.intro.finish()
	end
	local full = { floor = "piso_parquet_1970", wall = "pared_beige_1970", covering = "madera_1970", lighting = "luz_calida_1970" }
	for level = 1, 5 do
		local sess = Sessions.instance.list[player]
		sess.game.sede = level
		Office.remap(sess.game.office, level)
		-- Habitaciones con acabados básicos, para presupuestar el cambio completo.
		for _, r in OfficeCatalog.plan(level).rooms do
			sess.game.office.finishes[r.id] = table.clone(OfficeCatalog.DEFAULT_FINISH)
		end
		sess.game.office.rev += 1
		sess.game.money = 1e7
		Sessions.instance:push(sess)
		waitFor(function()
			return App.g.office.level == level and App.g.money == 1e7
		end)
		App.go("oficina")
		M.task.wait()
		Editor.setSection("remodelacion")
		for _, r in OfficeCatalog.plan(level).rooms do
			-- Las paredes que arma la escena miden exactamente los tramos que se cobran.
			local len = 0
			for _, w in Scene.roomParts(r.id).walls do
				len += w.len
			end
			eq(len, Office.wallLength(r) * CELL, "nivel " .. level .. " · " .. r.id .. ": paredes de la escena = tramos cobrados")
			Editor.setRoom(r.id)
			for k, v in full do
				Editor.choose(k, v)
			end
			local expected = r.w * r.d * F.floor.piso_parquet_1970.price + builtWalls(r) * (F.wall.pared_beige_1970.price + F.covering.madera_1970.price) + math.ceil(r.w * r.d / OfficeCatalog.LIGHT_AREA) * F.lighting.luz_calida_1970.price
			eq(Editor.quote(), expected, "nivel " .. level .. " · " .. r.id .. ": presupuesto")
		end
		-- Cancelar: todas vuelven a lo instalado, sin cobrar.
		local m0 = App.g.money
		Editor.cancelRemodel()
		for _, r in OfficeCatalog.plan(level).rooms do
			check(not Editor.hasDraft(r.id), "nivel " .. level .. " · " .. r.id .. ": sin vista previa tras cancelar")
			eq(Scene.lookOf(r.id), "piso_cemento|pared_blanca|sin_revestimiento|luz_fluorescente", "nivel " .. level .. " · " .. r.id .. ": aspecto instalado")
		end
		eq(App.g.money, m0, "nivel " .. level .. ": cancelar no cobra")
		-- Confirmar la última habitación del plano: cobro exacto y acabados instalados.
		local rooms = OfficeCatalog.plan(level).rooms
		local last = rooms[#rooms]
		Editor.setRoom(last.id)
		for k, v in full do
			Editor.choose(k, v)
		end
		local cost = Editor.quote()
		local res = Editor.confirmRemodel()
		check(res and res.ok and res.paid == cost, "nivel " .. level .. ": confirmación de " .. last.id)
		eq(App.g.money, m0 - cost, "nivel " .. level .. ": cobro exacto")
		eq(App.g.office.finishes[last.id].covering, "madera_1970", "nivel " .. level .. ": instalado")
		App.go("juego")
		M.task.wait()
	end
	noErrors("Remodelación por niveles en el editor")
end)


test("Bonificaciones del mobiliario en la interfaz: tarjetas con aporte real, Beneficios de la oficina y Personal con el tope compartido", function()
	local Office = require("./.build-ui/shared/Office")
	local Editor = require("./.build-ui/client/OfficeEditor")
	App.closeAllDialogs()
	if App.g then
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
	end
	local slot
	for _, k in { "1", "2", "3", "4" } do
		if App.profile.slots[k] == nil and (tonumber(k) <= 2 or (App.profile.unlocked or {})[k]) then
			slot = k
			break
		end
	end
	if not slot then
		for k, v in App.profile.slots do
			if v and (v.name == "Remodela Uno" or v.name == "Muebles Uno" or v.name == "Oficinas SA") then
				App.request("deleteCompany", { slot = k, confirm = v.name })
				slot = k
				break
			end
		end
	end
	check(App.request("createCompany", { slot = slot, name = "Bonos Interfaz", color = "#FF8A3D", logo = "pico" }).ok, "empresa creada")
	waitFor(function()
		return App.g ~= nil
	end)
	if App.screens.intro.active() then
		App.screens.intro.finish()
	end
	local sess = Sessions.instance.list[player]
	sess.game.money = 1e6
	Sessions.instance:push(sess)
	waitFor(function()
		return App.g.money == 1e6
	end)
	App.go("oficina")
	M.task.wait()
	local R = "oficina_principal"
	for _, pos in { { 5, 2.5 }, { 5, 5.5 } } do
		Editor.startPlace("escritorio_metal_1970")
		Editor.hover(R, pos[1], pos[2])
		check(Editor.confirm().ok, "escritorio colocado")
	end
	Editor.cancel()
	if not named("TabCatalogo") then
		local d = App.topDialog()
		print("DIAG TabCatalogo ausente: ruta=" .. tostring(App.ui.route) .. " diálogo=" .. tostring(d and d.kind) .. " seccion=" .. tostring(Editor.state().section) .. " lateral=" .. tostring(named("LateralOficina") ~= nil) .. " intro=" .. tostring(App.ui.intro ~= nil))
	end
	clickN("TabCatalogo")
	M.task.wait()
	clickN("Cat_todas")
	M.task.wait()
	-- Tarjeta del escritorio con los datos reales.
	local card = named("Bono_escritorio_metal_1970")
	check(card ~= nil, "la tarjeta muestra la bonificación")
	check(M.find(card, "Organización") ~= nil and M.find(card, "obras y mejoras más rápidas") ~= nil, "habilidad y efecto")
	check(M.find(card, "+1 %") ~= nil, "beneficio base +1 %")
	check(M.find(card, "+1,5 %") ~= nil, "aporte actual de dos escritorios +1,5 %")
	check(M.find(card, "+0,25 %") ~= nil, "próximo escritorio +0,25 %")
	check(M.find(card, "+40 %") ~= nil, "límite compartido 40 %")
	check(M.find(App.content, "Beneficio futuro") == nil, "ya no dice «Beneficio futuro»")
	-- Beneficios de la oficina.
	clickN("TabBeneficios")
	M.task.wait()
	local row = named("Resumen_organizacion")
	check(row ~= nil and M.find(row, "Mobiliario +1,5 %") ~= nil and M.find(row, "Personal +0 %") ~= nil, "Beneficios de la oficina: personal y mobiliario")
	check(M.find(row, "/ +40 %") ~= nil, "con el límite")
	check(named("Beneficios_administracion") ~= nil and named("Beneficios_produccion") ~= nil, "separado por departamento")
	-- Al tope: el personal (inyectado) más los muebles superan el 40 %.
	sess = Sessions.instance.list[player]
	local cap = 0.40
	for i = 1, 5 do
		table.insert(sess.game.employees, { id = "eb" .. i, name = "Admin " .. i, spec = "administracion", dept = "administracion", salary = 1000, skills = { organizacion = 100 }, potential = { organizacion = 100 }, months = 1, hiredDay = 0, adapt = {}, status = "activo" })
	end
	Sessions.instance:push(sess)
	waitFor(function()
		return #App.g.employees >= 5
	end)
	App.forceRender()
	M.task.wait()
	row = named("Resumen_organizacion")
	check(row ~= nil and M.find(row, "se desperdicia") ~= nil, "muestra lo que se desperdicia por el tope")
	check(M.find(row, "+40 % / +40 %") ~= nil, "total efectivo en el tope")
	clickN("TabCatalogo")
	M.task.wait()
	card = named("Bono_escritorio_metal_1970")
	check(named("Tope_escritorio_metal_1970") ~= nil, "aviso de límite alcanzado en la tarjeta")
	check(M.find(card, "Próxima unidad") ~= nil and M.find(card, "+0 %") ~= nil, "otro escritorio no suma")
	local buy = named("Colocar_escritorio_metal_1970")
	check(buy ~= nil and buy:GetAttribute("disabled") ~= true, "la compra sigue habilitada (decoración)")
	-- Personal: desglose y mensaje del tope compartido; la vista previa de contratación no inventa mejoras.
	App.ui.staff = nil
	App.go("personal")
	M.task.wait()
	local d = named("Desglose_organizacion")
	check(d ~= nil and string.find(d.Text, "Mobiliario +1,5 %", 1, true) ~= nil, "Personal: desglose personal / mobiliario")
	check(M.find(App.content, "entre personal y mobiliario") ~= nil, "Personal: el tope se explica con personal y mobiliario")
	App.ui.staff = { view = "mercado", dept = "produccion", hireDept = {} }
	local c = App.g.candidates[1]
	App.ui.staff.hireDept[c.id] = "administracion"
	App.forceRender()
	M.task.wait()
	local Staff = require("./.build-ui/shared/Staff")
	local gainOrg
	for _, p in Staff.previewHire(App.g, c, "administracion") do
		if p.skill == "organizacion" then
			gainOrg = p
		end
	end
	check(gainOrg and gainOrg.gain == 0 and gainOrg.capped, "vista previa de contratación: +0 en Organización (al tope)")
	local aporte = named("Aporte_" .. c.id)
	check(aporte ~= nil and M.find(aporte, "tope") ~= nil, "la tarjeta del candidato lo marca")
	-- Retirar escritorios baja el beneficio y la interfaz se actualiza.
	sess = Sessions.instance.list[player]
	for i = #sess.game.employees, 1, -1 do
		if string.sub(sess.game.employees[i].id, 1, 2) == "eb" then
			table.remove(sess.game.employees, i)
		end
	end
	Sessions.instance:push(sess)
	waitFor(function()
		return #App.g.employees == 0
	end)
	App.go("oficina")
	M.task.wait()
	Editor.selectAt(R, 5, 5.5)
	check(Editor.removeSelected().ok, "retirar un escritorio")
	App.forceRender()
	M.task.wait()
	card = named("Bono_escritorio_metal_1970")
	check(M.find(card, "+1 %") ~= nil and M.find(card, "+0,5 %") ~= nil, "con uno: aporte +1 % y el próximo +0,5 %")
	check(math.abs(require("./.build-ui/shared/Rules").staff(App.g, "organizacion") - 0.01) < 1e-9, "el cliente calcula lo mismo que el servidor")
	App.go("juego")
	noErrors("Bonificaciones del mobiliario")
end)


-- Etapa 5: empleados visibles en el editor de oficinas -------------------------------------------------------
do
	local Office = require("./.build-ui/shared/Office")
	local OfficeCatalog = require("./.build-ui/shared/OfficeCatalog")
	local Nav = require("./.build-ui/shared/OfficeNavigation")
	local Rules = require("./.build-ui/shared/Rules")
	local Act = require("./.build-ui/client/OfficeActivities")
	local Mgr = require("./.build-ui/client/OfficeNPCManager")
	local Anim = require("./.build-ui/client/OfficeAnimations")
	local Scene = require("./.build-ui/client/OfficeScene")
	local DEPTS = { "administracion", "investigacion", "marketing", "produccion" }

	-- Empleados de prueba: cada uno es un amigo de Roblox (como los asigna el servidor al contratar).
	local function staff(n: number, prefix: string, dept: string?): { any }
		local out = {}
		local base = 0
		for i = 1, #prefix do
			base = base * 31 + string.byte(prefix, i)
		end
		base = 100000 + (base % 5000) * 100
		for i = 1, n do
			local d = dept or DEPTS[(i - 1) % #DEPTS + 1]
			local uid = base + i
			table.insert(out, { id = prefix .. i, name = "Amigo " .. prefix .. i, spec = d, dept = d, salary = 1000, skills = { organizacion = 40 }, potential = { organizacion = 80 }, months = 1, hiredDay = 0, adapt = {}, status = "activo", friend = { userId = uid, username = "amigo_" .. prefix .. i, displayName = "Amigo " .. prefix .. i, since = 0 } })
		end
		return out
	end

	-- Plantillas de avatar en PlayerGui.AvataresEmpleados (lo que deja el servidor) para estos empleados.
	local function provideAvatars(list: { any }, builtAt: number?)
		local gui = M.services.Players.LocalPlayer:FindFirstChild("PlayerGui")
		local folder = gui:FindFirstChild("AvataresEmpleados")
		if not folder then
			folder = M.Instance.new("Folder")
			folder.Name = "AvataresEmpleados"
			folder.Parent = gui
		end
		for _, e in list do
			if e.friend then
				local old = folder:FindFirstChild("Avatar_" .. e.friend.userId)
				if old then
					old:Destroy()
				end
				local m = M.fakeR15(e.friend.userId)
				m.Name = "Avatar_" .. e.friend.userId
				m:SetAttribute("userId", e.friend.userId)
				m:SetAttribute("builtAt", builtAt or os.time())
				m.Parent = folder
			end
		end
	end

	-- ¿El personaje es el avatar real (rig R15 con articulaciones), sin piezas de un personaje genérico?
	local function isAvatar(rig: any): boolean
		local m = rig and rig.model
		return m ~= nil and m:FindFirstChild("HumanoidRootPart") ~= nil and m:FindFirstChild("UpperTorso") ~= nil and m:FindFirstChild("Camisa") == nil and m:FindFirstChild("Corbata") == nil and #rig.chain >= 15
	end

	local function put(o: any, item: string, room: string, x: number, y: number, rot: number?): string
		local req = { room = room, x = x, y = y, rot = rot or 0 }
		local ok, why = Office.validatePlacement(o, OfficeCatalog.item(item), req)
		assert(ok, item .. " en (" .. x .. ", " .. y .. "): " .. tostring(why))
		local id = Office.newInstanceId(o)
		table.insert(o.placed, { id = id, item = item, room = room, x = x, y = y, rot = req.rot })
		o.rev = (o.rev or 0) + 1
		return id
	end

	-- Copia de la oficina (como la que llega con cada partida nueva del servidor).
	local function copy(o: any): any
		local c = table.clone(o)
		c.placed = {}
		for _, p in o.placed do
			table.insert(c.placed, table.clone(p))
		end
		return c
	end

	local function npcModels(): number
		local f = Scene.folder()
		local holder = f and f:FindFirstChild("Empleados")
		local n = 0
		for _, d in holder and holder:GetChildren() or {} do
			if d:IsA("Model") and d:GetAttribute("employeeId") then
				n += 1
			end
		end
		return n
	end

	local function heartbeatHandlers(): number
		local sigs = rawget(M.services.RunService, "__signals")
		local hb = sigs and sigs.Heartbeat
		local n = 0
		for _, c in hb and hb.handlers or {} do
			if c.connected then
				n += 1
			end
		end
		return n
	end

	-- Invariantes de un paso: dentro de su habitación, nunca dentro de un mueble (salvo sentado en el suyo),
	-- reservas sin repetir y nadie parado en el lugar de otro.
	local function invariants(world: any): (boolean, string?)
		local owner = {}
		local list = Act.list(world)
		for _, npc in list do
			local rd = world.rooms[npc.room]
			if not rd then
				return false, npc.id .. " sin habitación"
			end
			local r = rd.room
			if npc.x < 0 or npc.y < 0 or npc.x > r.w or npc.y > r.d then
				return false, string.format("%s fuera de %s (%.2f, %.2f)", npc.id, npc.room, npc.x, npc.y)
			end
			if not Act.isSeated(npc) and not Nav.clearAt(rd.grid, npc.x, npc.y) then
				return false, string.format("%s dentro de un mueble o pegado a la pared (%.2f, %.2f) en %s", npc.id, npc.x, npc.y, npc.state)
			end
			for _, k in npc.activity and npc.activity.keys or {} do
				if owner[k] and owner[k] ~= npc.id then
					return false, "dos empleados con el mismo punto " .. k
				end
				owner[k] = npc.id
			end
		end
		for i = 1, #list do
			for k = i + 1, #list do
				local a, b = list[i], list[k]
				if a.room == b.room and a.activity and b.activity and a.state ~= "Walking" and b.state ~= "Walking" and not a.phase and not b.phase then
					if math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) < 2 * Nav.RADIUS - 1e-6 then
						return false, a.id .. " y " .. b.id .. " superpuestos"
					end
				end
			end
		end
		return true, nil
	end

	test("Empleados visibles (1–7): solo empleados reales, límite configurable, sin duplicados, despidos y cambio de empresa", function()
		local o = Office.new(1)
		Scene.buildRooms(o)
		Scene.syncFurniture(o)
		local company = { id = "npc-A" }
		local g = { company = company, office = o, employees = {} }
		local hb0 = heartbeatHandlers()
		Mgr.open(g)
		eq(#Mgr.world().order, 0, "1. sin empleados contratados no aparece nadie")
		eq(npcModels(), 0, "1. ningún personaje en la escena")
		local v, h = Mgr.counts(g)
		check(v == 0 and h == 0, "1. 0 visibles de 0 contratados")
		eq(heartbeatHandlers(), hb0 + 1, "una sola conexión a Heartbeat")
		-- 2 y 4. Tres contratados: tres personajes, cada uno de un empleado real con su nombre.
		local three = staff(3, "a")
		local before = serde.encode("json", three)
		-- Un puesto sin amigo asignado no tiene personaje (nunca uno genérico).
		local vacant = { id = "vac1", name = "Puesto sin amigo asignado", spec = "produccion", dept = "produccion", salary = 1000, skills = {}, potential = {}, months = 0, hiredDay = 0, adapt = {} }
		local withVacant = table.clone(three)
		table.insert(withVacant, vacant)
		g = { company = company, office = o, employees = withVacant }
		Mgr.sync(g)
		eq(#Mgr.world().order, 3, "13. el puesto sin amigo no se representa")
		check(Mgr.npc("vac1") == nil, "13. sin NPC genérico para el puesto vacante")
		eq(npcModels(), 0, "6. sin avatar todavía: no se dibuja nadie (ni genéricos)")
		local _, _, loading, vacN = Mgr.counts(g)
		check(loading == 3 and vacN == 1, "contador: 3 avatares cargando y 1 puesto sin amigo")
		check(Mgr._state.requests >= 1 and #Mgr._state.queue == 0, "16. los avatares se piden al servidor en un lote")
		local req0 = Mgr._state.requests
		Mgr.step(0.5)
		eq(Mgr._state.requests, req0, "16. sin pedidos repetidos antes del reintento")
		provideAvatars(three)
		g = { company = company, office = o, employees = three }
		Mgr.sync(g)
		eq(#Mgr.world().order, 3, "2. con tres contratados se ven tres")
		eq(npcModels(), 3, "2. tres personajes")
		local ids = {}
		for _, npc in Act.list(Mgr.world()) do
			local e
			for _, x in three do
				if x.id == npc.id then
					e = x
				end
			end
			local rig = Mgr.rig(npc.id)
			check(e ~= nil, "4. " .. npc.id .. " es un empleado real")
			check(e and npc.name == e.name and rig.label.Text == e.name and rig.model:GetAttribute("employeeId") == e.id, "4. nombre igual al de Personal (DisplayName del amigo)")
			check(isAvatar(rig) and rig.userId == e.friend.userId, "4. el personaje es el avatar real de su amigo")
			check(not ids[npc.id], "5. sin ids repetidos")
			ids[npc.id] = true
		end
		eq(serde.encode("json", three), before, "crear los personajes no cambia ningún dato de los empleados")
		-- Cambio de departamento: se actualiza sin rearmar el personaje.
		local rigA1 = Mgr.rig("a1")
		local model = rigA1.model
		local moved = table.clone(three)
		moved[1] = table.clone(three[1])
		moved[1].dept = "marketing"
		Mgr.sync({ company = company, office = o, employees = moved })
		check(Mgr.rig("a1").model == model and Mgr.npc("a1").dept == "marketing", "cambio de departamento sin rearmar el personaje")
		eq(Mgr.info("a1").dept, "Marketing", "el panel muestra el departamento nuevo")
		-- 5. Datos con el mismo empleado dos veces: un solo personaje.
		local dup = table.clone(moved)
		table.insert(dup, moved[2])
		Mgr.sync({ company = company, office = o, employees = dup })
		eq(#Mgr.world().order, 3, "5. el mismo empleado repetido no duplica su personaje")
		eq(npcModels(), 3, "5. tres modelos")
		-- 7. Despedir: su personaje desaparece y libera lo que tenía reservado.
		local fired = { moved[1], moved[3] }
		Mgr.step(5)
		Mgr.sync({ company = company, office = o, employees = fired })
		check(Mgr.npc("a2") == nil and Mgr.rig("a2") == nil, "7. el despedido ya no se ve")
		eq(npcModels(), 2, "7. quedan dos personajes")
		for _, who in Mgr.world().res do
			check(who ~= "a2", "7. sin reservas del despedido")
		end
		-- Contratar uno nuevo: entra por la puerta.
		local hired = table.clone(fired)
		table.insert(hired, staff(1, "n")[1])
		provideAvatars(hired)
		Mgr.sync({ company = company, office = o, employees = hired })
		local newbie = Mgr.npc("n1")
		check(newbie ~= nil, "el contratado nuevo se incorpora")
		local entry = false
		local grid = Mgr.world().rooms[newbie.room].grid
		for _, idx in grid.entries do
			local x, y = Nav.nodePos(grid, idx)
			if math.abs(x - newbie.x) < 1e-6 and math.abs(y - newbie.y) < 1e-6 then
				entry = true
			end
		end
		check(entry, "el nuevo aparece en un acceso de la habitación")
		-- 6. Otra empresa: los personajes anteriores desaparecen por completo.
		local oldModels = {}
		for _, rig in Mgr._state.rigs do
			table.insert(oldModels, rig.model)
		end
		-- Avatar actualizado (el servidor lo rearmó): se rearma solo el personaje.
		local before1 = Mgr.rig("n1") and Mgr.rig("n1").model
		provideAvatars({ hired[#hired] }, os.time() + 5)
		Mgr.step(0.1)
		check(Mgr.rig("n1") and Mgr.rig("n1").model ~= before1 and before1.Parent == nil, "16. avatar actualizado: se reemplaza el personaje")
		local bList = staff(2, "b")
		provideAvatars(bList)
		Mgr.sync({ company = { id = "npc-B" }, office = Office.new(1), employees = bList })
		for _, m in oldModels do
			check(m.Parent == nil, "6. personaje de la empresa anterior destruido")
		end
		for _, npc in Act.list(Mgr.world()) do
			check(string.sub(npc.id, 1, 1) == "b", "6. solo empleados de la empresa nueva")
		end
		eq(npcModels(), 2, "6. dos personajes nuevos")
		eq(heartbeatHandlers(), hb0 + 1, "6. sigue habiendo una sola conexión")
		Mgr.close()
		eq(heartbeatHandlers(), hb0, "al cerrar se desconecta")
		Scene.destroy()
		-- 3. Cincuenta contratados en el nivel 5: se respeta el límite configurable, repartidos por habitación.
		local o5 = Office.new(5)
		Scene.buildRooms(o5)
		local fifty = staff(50, "c")
		provideAvatars(fifty)
		Mgr.open({ company = { id = "npc-C" }, office = o5, employees = fifty })
		local w = Mgr.world()
		eq(#w.order, Act.MAX_VISIBLE_NPCS, "3. con 50 contratados se ven MAX_VISIBLE_NPCS (" .. Act.MAX_VISIBLE_NPCS .. ")")
		eq(npcModels(), Act.MAX_VISIBLE_NPCS, "3. igual cantidad de personajes")
		local per, used = {}, 0
		for _, npc in Act.list(w) do
			per[npc.room] = (per[npc.room] or 0) + 1
		end
		for id, n in per do
			used += 1
			check(n <= w.rooms[id].cap, "3. " .. id .. ": no se amontonan (" .. n .. " de " .. w.rooms[id].cap .. ")")
		end
		check(used >= 2, "3. repartidos entre varias habitaciones (" .. used .. ")")
		local v5, h5 = Mgr.counts({ employees = fifty })
		check(v5 == 10 and h5 == 50, "3. 10 visibles de 50 contratados")
		local firstSet = table.concat(w.order, ",")
		Mgr.close()
		Mgr.open({ company = { id = "npc-C" }, office = o5, employees = fifty })
		eq(table.concat(Mgr.world().order, ","), firstSet, "3. elección estable: los mismos al volver a abrir")
		Mgr.close()
		Act.MAX_VISIBLE_NPCS = 4
		Mgr.open({ company = { id = "npc-C" }, office = o5, employees = fifty })
		eq(#Mgr.world().order, 4, "3. el límite se cambia con una constante")
		Mgr.close()
		Act.MAX_VISIBLE_NPCS = 10
		Scene.destroy()
		-- Nivel 1 con muchos contratados: no más de lo que entra en la habitación.
		local o1 = Office.new(1)
		local w1 = Act.new(o1, { seed = "chica" })
		Act.setEmployees(w1, fifty, true)
		eq(#w1.order, Act.totalCapacity(w1), "habitación chica: solo los que entran (" .. Act.totalCapacity(w1) .. ")")
		check(#w1.order < 10, "no se fuerzan diez empleados en una oficina de 10 × 8")
		-- Rotación ocasional: de a uno, sin superar nunca el máximo, y todos siguen contratados.
		local wr = Act.new(Office.new(3), { seed = "rotar", max = 5, rotateEvery = 20 })
		local list = staff(12, "r")
		Act.setEmployees(wr, list, true)
		local seen, maxVis, prev = {}, 0, table.concat(wr.order, ",")
		local changes = 0
		for _ = 1, 3000 do
			Act.step(wr, 0.1)
			maxVis = math.max(maxVis, #wr.order)
			for _, id in wr.order do
				seen[id] = true
			end
			local now = table.concat(wr.order, ",")
			if now ~= prev then
				changes += 1
				prev = now
			end
		end
		local nSeen = 0
		for _ in seen do
			nSeen += 1
		end
		check(maxVis <= 5, "rotación: nunca más de 5 visibles (" .. maxVis .. ")")
		check(wr.rotations >= 5 and nSeen > 5, "rotación: con el tiempo se ven otros empleados (" .. nSeen .. " distintos, " .. wr.rotations .. " rotaciones)")
		check(changes <= wr.rotations * 2 + 2, "rotación sin cambios constantes (" .. changes .. " cambios)")
		eq(#list, 12, "los 12 siguen contratados")
		noErrors("Empleados visibles: generación")
	end)

	test("Actividades (16–24): caminar, sentarse, trabajar, consultar, descansar, reuniones, reservas, retiros e interrupciones", function()
		local o = Office.new(2)
		local MAIN, SALA = "oficina_principal", "sala_reuniones"
		local desk1 = put(o, "escritorio_metal_1970", MAIN, 4, 2.5)
		local chair1 = put(o, "silla_oficina_1970", MAIN, 4.5, 3.5)
		local desk2 = put(o, "escritorio_metal_1970", MAIN, 9, 2.5)
		local chairSolo = put(o, "silla_oficina_1970", MAIN, 10.5, 6.5, 270)
		local shelf = put(o, "estanteria_madera_1970", MAIN, 6, 0.5)
		local sofa = put(o, "sofa_cuero_1970", MAIN, 6.5, 8.5)
		local mesa = put(o, "mesa_reuniones_1970", SALA, 4.5, 3)
		local emps = staff(8, "x")
		local world = Act.new(o, { seed = "actividades" })
		Act.setEmployees(world, emps, true)
		eq(#world.order, 8, "ocho visibles")
		local stats = { walkThenStop = false, sit = false, work = false, workSeated = false, workStand = false, browse = false, rest = false, sofaTogether = 0, meeting = 0, offSpot = 0, badFacing = 0 }
		local okAll, firstBad = true, nil
		local jump = 0
		local last = {}
		local wasWalking = {}
		for step = 1, 12000 do
			Act.step(world, 0.1)
			local ok, why = invariants(world)
			if not ok and okAll then
				okAll, firstBad = false, "paso " .. step .. ": " .. tostring(why)
			end
			local sofaN, meetN = 0, 0
			for _, npc in Act.list(world) do
				local p = last[npc.id]
				if p and not npc.phase then
					local d = math.sqrt((npc.x - p[1]) ^ 2 + (npc.y - p[2]) ^ 2)
					jump = math.max(jump, d)
				end
				last[npc.id] = { npc.x, npc.y }
				if wasWalking[npc.id] and npc.state ~= "Walking" then
					stats.walkThenStop = true
				end
				wasWalking[npc.id] = npc.state == "Walking"
				local a = npc.activity
				if a and npc.state ~= "Walking" and not npc.phase then
					local sp = a.spot
					if not (math.abs(npc.x - sp.x) < 1e-6 and math.abs(npc.y - sp.y) < 1e-6) then
						stats.offSpot += 1
					end
					if npc.state == "Sitting" and sp.instance == chairSolo then
						stats.sit = true
						if math.abs((npc.heading - sp.facing + 540) % 360 - 180) > 1 and npc.timer < 30 then
							stats.badFacing += 1
						end
					elseif npc.state == "Working" then
						stats.work = true
						if sp.instance == desk1 and sp.chair then
							stats.workSeated = true
						elseif sp.instance == desk2 then
							stats.workStand = true
						end
					elseif npc.state == "Browsing" and sp.instance == shelf then
						stats.browse = true
					elseif npc.state == "Resting" and sp.instance == sofa then
						stats.rest = true
						sofaN += 1
					elseif npc.state == "Meeting" and sp.instance == mesa then
						meetN += 1
					end
				end
			end
			stats.sofaTogether = math.max(stats.sofaTogether, sofaN)
			stats.meeting = math.max(stats.meeting, meetN)
		end
		eq(stats.offSpot, 0, "en su actividad, cada uno está en el lugar exacto de su punto de uso")
		eq(stats.badFacing, 0, "sentado mirando hacia donde mira la silla")
		check(okAll, "8, 11, 12 y 22: nadie atraviesa muebles ni paredes, sale de su habitación ni comparte un punto (" .. tostring(firstBad) .. ")")
		check(jump <= Act.WALK_SPEED * 1.1 * 0.1 + 1e-3, string.format("sin teletransportes: máximo %.3f casillas por paso de 0,1 s", jump))
		check(stats.walkThenStop, "16. caminan y se detienen")
		check(stats.sit, "17. usan una silla (sentados en el asiento)")
		check(stats.work and stats.workSeated and stats.workStand, "18. trabajan en escritorios: sentados en la silla de al lado y de pie")
		check(stats.browse, "19. consultan la estantería")
		check(stats.rest, "20. descansan en el sofá")
		check(stats.meeting >= 2, "21. reunión de " .. stats.meeting .. " personas en la mesa")
		check(world.plans < 12000 / 5, "las rutas no se calculan por cuadro (" .. world.plans .. " en 1200 s)")
		-- 22. Reservas: un asiento, un empleado.
		local a, b = Act.list(world)[1], Act.list(world)[2]
		Act.interrupt(world, a, "prueba")
		Act.interrupt(world, b, "prueba")
		check(Act._reserve(world, a, { "silla-prueba#1" }), "22. el primero reserva")
		check(not Act._reserve(world, b, { "silla-prueba#1" }), "22. el segundo no puede reservar el mismo asiento")
		world.res["silla-prueba#1"] = nil
		-- 23. Retirar un mueble con reserva: se libera y el empleado se interrumpe.
		local victim
		for _ = 1, 3000 do
			Act.step(world, 0.1)
			for _, npc in Act.list(world) do
				if npc.activity and npc.state ~= "Walking" and not npc.phase and npc.activity.spot.instance ~= mesa then
					victim = npc
				end
			end
			if victim then
				break
			end
		end
		check(victim ~= nil, "alguien usa un mueble")
		local inst = victim.activity.spot.instance
		local count0 = victim.interrupts
		local o2 = copy(o)
		Office.removePlaced(o2, inst)
		o2.rev += 1
		Act.setOffice(world, o2)
		check(victim.activity == nil and victim.interrupts == count0 + 1, "23. retirar el mueble interrumpe la actividad")
		for k in world.res do
			check(string.find(k, "/" .. inst .. "#", 1, true) == nil, "23. sin reservas del mueble retirado")
		end
		check(string.find(victim.nav, "Interrumpido", 1, true) ~= nil, "23. el panel lo informa (" .. victim.nav .. ")")
		check(Nav.clearAt(world.rooms[victim.room].grid, victim.x, victim.y), "23. no queda dentro de otro mueble")
		-- 24. Se recupera: vuelve a elegir actividades.
		local busy = false
		for _ = 1, 1500 do
			Act.step(world, 0.1)
			if victim.state ~= "Idle" then
				busy = true
			end
		end
		check(busy and victim.interrupts == count0 + 1, "24. retoma sus actividades después de la interrupción")
		-- 14 y 12. Un mueble nuevo sobre alguien en reposo o sobre una ruta en curso.
		local idle, walker
		for _ = 1, 2000 do
			Act.step(world, 0.1)
			for _, npc in Act.list(world) do
				if npc.room == MAIN and npc.state == "Idle" and not idle then
					idle = npc
				end
			end
			if idle then
				break
			end
		end
		check(idle ~= nil, "alguien en reposo")
		local o3 = copy(o2)
		local px, py = math.floor(idle.x) + 0.5, math.floor(idle.y) + 0.5
		local okPut = Office.validatePlacement(o3, OfficeCatalog.item("planta_interior_1970"), { room = idle.room, x = px, y = py, rot = 0 })
		if okPut then
			put(o3, "planta_interior_1970", idle.room, px, py)
			Act.setOffice(world, o3)
			check(Nav.clearAt(world.rooms[idle.room].grid, idle.x, idle.y), "un mueble puesto encima de alguien lo corre a un lugar libre")
		end
		for _ = 1, 3000 do
			Act.step(world, 0.1)
			for _, npc in Act.list(world) do
				if npc.state == "Walking" and npc.path and npc.pi < #npc.path and npc.room == MAIN then
					walker = npc
				end
			end
			if walker then
				break
			end
		end
		check(walker ~= nil, "alguien camina")
		local wp = walker.path[walker.pi]
		local mx, my = (walker.x + wp[1]) / 2, (walker.y + wp[2]) / 2
		local o4 = copy(world.office)
		local placedBlock = false
		for _, c in { { math.floor(mx) + 0.5, math.floor(my) + 0.5 }, { math.floor(mx) + 1.5, math.floor(my) + 0.5 }, { math.floor(mx) - 0.5, math.floor(my) + 0.5 } } do
			if not placedBlock and Office.validatePlacement(o4, OfficeCatalog.item("planta_interior_1970"), { room = MAIN, x = c[1], y = c[2], rot = 0 }) then
				put(o4, "planta_interior_1970", MAIN, c[1], c[2])
				placedBlock = true
			end
		end
		if placedBlock then
			local re0, it0 = world.replans, walker.interrupts
			Act.setOffice(world, o4)
			local rd = world.rooms[MAIN]
			local clear = true
			local qx, qy = walker.x, walker.y
			for i = walker.pi, walker.path and #walker.path or 0 do
				local q = walker.path[i]
				if not Nav.segmentClear(rd.grid, qx, qy, q[1], q[2]) then
					clear = false
				end
				qx, qy = q[1], q[2]
			end
			check(clear, "14. después del cambio la ruta restante no cruza el mueble nuevo")
			check(world.replans > re0 or walker.interrupts > it0 or walker.state ~= "Walking" or clear, "14. la ruta afectada se recalculó o se interrumpió")
		end
		for _ = 1, 600 do
			Act.step(world, 0.1)
			local ok, why = invariants(world)
			if not ok then
				check(false, "invariantes después de los cambios: " .. tostring(why))
				break
			end
		end
		-- Destino imposible: se evita sin bloquear (punto al que no se llega).
		local o5 = Office.new(1)
		for _, y in { 1, 3, 5, 7 } do
			put(o5, "estanteria_madera_1970", "oficina_principal", 6.5, y, 90)
		end
		put(o5, "escritorio_metal_1970", "oficina_principal", 8.5, 4, 90)
		local w5 = Act.new(o5, { seed = "muro" })
		Act.setEmployees(w5, staff(2, "m", "administracion"), true)
		for _ = 1, 3000 do
			Act.step(w5, 0.1)
		end
		for _, npc in Act.list(w5) do
			check(npc.x < 6, "13. nadie cruza al lado sin acceso")
			check(not (npc.activity and npc.activity.spot.item == "escritorio_metal_1970"), "13. el escritorio inalcanzable no se usa")
		end
		-- Animaciones: cada estado tiene su pose y al salir de una pose no quedan restos.
		local NPCm = require("./.build-ui/client/OfficeNPC")
		local tpl = M.fakeR15(4242)
		tpl:SetAttribute("userId", 4242)
		local rig = NPCm.build("anim1", "Ana", "administracion", tpl)
		check(isAvatar(rig), "el rig es el avatar R15 (con sus articulaciones)")
		local fake = { state = "Idle", pose = "idle", seed = 3 }
		local cf = M.CFrame.new(0, 100, 0)
		for _, pose in { "idle", "walk", "sit", "sitwork", "work", "browse", "rest", "meet", "sitmeet" } do
			check(Anim.POSES[pose] ~= nil, "pose " .. pose)
			fake.pose = pose
			fake.state = pose == "walk" and "Walking" or "Working"
			fake.activity = { spot = { seatH = 1.5 } }
			for _ = 1, 20 do
				Anim.update(rig, fake, cf, 1, 0.05)
			end
			eq(Anim.baseName(rig), pose, "pose actual " .. pose)
			check(rig.from == nil, "la mezcla con la pose anterior terminó (" .. pose .. ")")
		end
		fake.pose, fake.state, fake.phase, fake.phaseT = "sit", "Sitting", "down", 0.4
		Anim.update(rig, fake, cf, 1, 0.05)
		local midHip = rig.current.hipH
		check(midHip < NPCm.DIM.hipH and midHip > 1.5, "sentarse: transición entre de pie y sentado")
		-- Sentado del todo: la cadera del avatar queda a la altura del asiento y los muslos horizontales.
		fake.phase = nil
		for _ = 1, 20 do
			Anim.update(rig, fake, cf, 1, 0.05)
		end
		local lower = rig.model:FindFirstChild("LowerTorso")
		local hipJ = rig.joints.LeftHip
		local hipY = (lower.CFrame * hipJ.c0).Position.Y - 100
		check(math.abs(hipY - 1.5) < 0.05, string.format("sentado: cadera a la altura del asiento (%.2f studs)", hipY))
		local thigh = rig.model:FindFirstChild("LeftUpperLeg")
		local knee = (thigh.CFrame * rig.joints.LeftKnee.c0).Position
		check(math.abs(knee.Y - 100 - hipY) < 0.1, "sentado: muslo horizontal (rodilla a la altura de la cadera)")
		check((cf:Inverse() * M.CFrame.new(knee)).Position.Z < -0.5, "sentado: la rodilla hacia adelante")
		local pelo = rig.model:FindFirstChild("Pelo")
		local handle = pelo and pelo:FindFirstChild("Handle")
		local head = rig.model:FindFirstChild("Head")
		local hrec
		for _, rec in rig.chain do
			if rec.part == handle then
				hrec = rec
			end
		end
		check(handle and hrec and (handle.CFrame.Position - (head.CFrame * hrec.c0 * hrec.c1:Inverse()).Position).Magnitude < 1e-3, "los accesorios siguen a la cabeza")
		fake.phase, fake.phaseT = "up", Act.SIT_TIME
		Anim.update(rig, fake, cf, 1, 0.05)
		fake.phase, fake.pose, fake.state = nil, "idle", "Idle"
		for _ = 1, 20 do
			Anim.update(rig, fake, cf, 1, 0.05)
		end
		check(math.abs(rig.current.hipH - NPCm.DIM.hipH) < 1e-6 and math.abs(rig.current.thighL) < 0.05, "levantarse: vuelve a la postura de pie sin restos")
		local headY = rig.model:FindFirstChild("Head").CFrame.Position.Y - 100
		check(headY > 4.5 and headY < 6, string.format("altura de la cabeza acorde a los muebles (%.2f studs)", headY))
		for _, d in rig.model:GetDescendants() do
			if d:IsA("BasePart") and not d.Anchored then
				check(false, "todas las piezas ancladas (" .. d.Name .. ")")
			end
			if d:IsA("LocalScript") or d:IsA("Script") then
				check(false, "sin scripts del avatar (" .. d.Name .. ")")
			end
		end
		NPCm.destroy(rig)
		noErrors("Actividades de los empleados")
	end)

	test("Niveles 1 a 5: oficinas amuebladas al azar, cambios de muebles en plena actividad y costo por paso", function()
		local items = { "escritorio_metal_1970", "silla_oficina_1970", "sofa_cuero_1970", "estanteria_madera_1970", "mesa_reuniones_1970", "planta_interior_1970", "lampara_pie_1970", "maquina_escribir_1970" }
		local seed = 777
		local function rnd(): number
			seed = (seed * 16807) % 2147483647
			return seed / 2147483647
		end
		local function randomPlace(o: any, r: any): boolean
			for _ = 1, 25 do
				local it = OfficeCatalog.item(items[math.floor(rnd() * #items) + 1])
				local req = { room = r.id, x = math.floor(rnd() * r.w * 2) / 2, y = math.floor(rnd() * r.d * 2) / 2, rot = math.floor(rnd() * 8) * 45 }
				if Office.validatePlacement(o, it, req) then
					table.insert(o.placed, { id = Office.newInstanceId(o), item = it.id, room = r.id, x = req.x, y = req.y, rot = req.rot })
					return true
				end
			end
			return false
		end
		local violations, steps, worst = 0, 0, 0
		local firstBad = nil
		for level = 1, 5 do
			for k = 1, 3 do
				local o = Office.new(level)
				for _, r in OfficeCatalog.plan(level).rooms do
					for _ = 1, math.floor(r.w * r.d / 8) do
						randomPlace(o, r)
					end
				end
				local w = Act.new(o, { seed = "nivel" .. level .. "-" .. k })
				Act.setEmployees(w, staff(30, "z"), true)
				check(#w.order == math.min(10, Act.totalCapacity(w)), "nivel " .. level .. ": visibles según el lugar (" .. #w.order .. ")")
				for step = 1, 1500 do
					if step % 250 == 0 then
						local c = copy(o)
						if rnd() < 0.5 and #c.placed > 0 then
							table.remove(c.placed, math.floor(rnd() * #c.placed) + 1)
						else
							local rooms = OfficeCatalog.plan(level).rooms
							randomPlace(c, rooms[math.floor(rnd() * #rooms) + 1])
						end
						o = c
						Act.setOffice(w, o)
					end
					local t0 = os.clock()
					Act.step(w, 0.1)
					worst = math.max(worst, os.clock() - t0)
					steps += 1
					local ok, why = invariants(w)
					if not ok then
						violations += 1
						firstBad = firstBad or ("nivel " .. level .. ": " .. tostring(why))
					end
				end
			end
		end
		eq(violations, 0, "en " .. steps .. " pasos nadie atraviesa muebles ni paredes ni comparte un punto (" .. tostring(firstBad) .. ")")
		check(worst < 0.05, string.format("paso más caro de la simulación visual: %.2f ms (10 empleados)", worst * 1000))
		noErrors("Niveles 1 a 5")
	end)

	test("Empleados visibles en el editor (25–30): herramientas intactas, abrir y cerrar sin duplicar, ocultar sin tocar la economía, pausa y partidas guardadas", function()
		local Editor = require("./.build-ui/client/OfficeEditor")
		local OfficeCamera = require("./.build-ui/client/OfficeCamera")
		local GameState = require("./.build-ui/server/GameState")
		App.closeAllDialogs()
		if App.g then
			App.request("leaveCompany", {})
			waitFor(function()
				return App.g == nil
			end)
		end
		local slot
		for _, k in { "1", "2", "3", "4" } do
			if App.profile.slots[k] == nil and (tonumber(k) <= 2 or (App.profile.unlocked or {})[k]) then
				slot = k
				break
			end
		end
		if not slot then
			for k, v in App.profile.slots do
				if v and v.name ~= nil then
					App.request("deleteCompany", { slot = k, confirm = v.name })
					slot = k
					break
				end
			end
		end
		check(App.request("createCompany", { slot = slot, name = "Empleados Editor", color = "#FF8A3D", logo = "pico" }).ok, "empresa creada")
		waitFor(function()
			return App.g ~= nil
		end)
		if App.screens.intro.active() then
			App.screens.intro.finish()
		end
		local sess = Sessions.instance.list[player]
		sess.game.money = 1e6
		sess.game.sede = 3 -- lugar para contratar varios
		-- 1. La lista de amigos real del servidor (Players:GetFriendsAsync, aquí con dobles): 8 amigos.
		local FI = require("./.build-ui/server/FriendIdentity")
		local list = {}
		for i = 1, 8 do
			table.insert(list, { userId = 700000 + i, username = "amiga_" .. i, displayName = "Amiga " .. i })
		end
		M.friendsOf[player.UserId] = list
		M.avatarsEnabled = true
		local calls0 = M.friendsCalls
		Sessions.instance:fetchFriends(sess)
		eq(M.friendsCalls, calls0 + 1, "1. la lista se pide con la API oficial")
		check(waitFor(function()
			return App.payload.friends ~= nil and App.payload.friends.status == "ok" and App.payload.friends.total == 8
		end), "la interfaz conoce la lista (8 amigos)")
		-- 2–5. Contratar desde Personal: cada uno es automáticamente un amigo, sin elegirlo.
		App.go("personal")
		M.task.wait()
		local staffSt = App.ui.staff
		check(staffSt ~= nil, "estado de Personal")
		staffSt.view = "mercado"
		App.forceRender()
		M.task.wait()
		local nextName = App.payload.friends.next and App.payload.friends.next.displayName
		check(nextName ~= nil and find("La próxima contratación se incorpora como " .. nextName) ~= nil, "Personal anuncia qué amigo se incorpora (sin elegirlo)")
		check(named("PerfilCandidato") ~= nil, "los candidatos son perfiles laborales (sin un nombre propio inventado)")
		check(find("Elegir amigo") == nil and find("Elegí un amigo") == nil, "5. no hay selección manual de amigos")
		local first
		for k = 1, 6 do
			local c = App.g.candidates[1]
			local r = App.request("hire", { candidateId = c.id })
			check(r.ok, "contratar " .. k .. ": " .. tostring(r.msg))
			if k == 1 then
				first = r
			end
			waitFor(function()
				return #App.g.employees == k
			end)
		end
		check(string.find(first.msg, nextName, 1, true) ~= nil, "3. el primero es el amigo anunciado")
		local ids = {}
		for _, e in App.g.employees do
			check(e.friend ~= nil and e.name == e.friend.displayName, "4. identidad del amigo: " .. tostring(e.name))
			check(not ids[e.friend.userId], "7. sin repetir amigos")
			ids[e.friend.userId] = true
		end
		eq(App.payload.friends.available, 2, "quedan 2 amigos libres")
		-- Personal muestra la foto y el usuario del amigo.
		staffSt.view = "inicio"
		staffSt.dept = App.g.employees[1].dept
		staffSt.sel = App.g.employees[1].id
		App.go("personal")
		App.forceRender()
		M.task.wait()
		staffSt.view = "depto"
		App.forceRender()
		M.task.wait()
		local photo = named("FotoAmigo")
		check(photo ~= nil and string.find(photo.Image, "id=" .. App.g.employees[1].friend.userId, 1, true) ~= nil, "Personal muestra la foto del avatar del amigo")
		check(find("@" .. App.g.employees[1].friend.username) ~= nil, "y su nombre de usuario")
		App.go("oficina")
		M.task.wait()
		-- 16. Los avatares llegan del servidor (a lo sumo 2 a la vez) y se dibujan; nunca genéricos.
		check(waitFor(function()
			Mgr.step(0.5)
			return npcModels() == 6
		end, 400), "16. llegan los seis avatares reales")
		for _, npc in Act.list(Mgr.world()) do
			local rig = Mgr.rig(npc.id)
			local e
			for _, x in App.g.employees do
				if x.id == npc.id then
					e = x
				end
			end
			check(isAvatar(rig) and rig.userId == e.friend.userId and rig.label.Text == e.friend.displayName, "4. " .. e.name .. ": su avatar y su nombre")
		end
		local gui = player:FindFirstChild("PlayerGui")
		check(gui:FindFirstChild("AvataresEmpleados") ~= nil, "las plantillas viven en el PlayerGui de este jugador (solo él las recibe)")
		-- Seguridad: pedir el avatar de alguien que no es empleado no hace nada.
		local built = M.avatarCalls.model
		M.services.ReplicatedStorage.CarEmpireRemotes.Avatares:FireServer({ "no-existe", "e999" })
		M.task.wait()
		eq(M.avatarCalls.model, built, "el cliente no puede pedir avatares de cualquiera")
		-- Caché: volver a pedir los mismos no los rearma.
		M.services.ReplicatedStorage.CarEmpireRemotes.Avatares:FireServer({ App.g.employees[1].id })
		M.task.wait()
		eq(M.avatarCalls.model, built, "16. un avatar vigente no se vuelve a armar")
		local hb0 = heartbeatHandlers() - 1
		check(Mgr.isOpen(), "los empleados aparecen al abrir el editor")
		eq(#Mgr.world().order, 6, "seis visibles")
		eq(npcModels(), 6, "seis personajes")
		check(named("ZonaEmpleados") ~= nil and named("MostrarEmpleados") ~= nil, "interruptor «Mostrar empleados»")
		App.forceRender()
		M.task.wait()
		check(find("Empleados visibles: 6 / 6 contratados") ~= nil, "«Empleados visibles: 6 / 6 contratados»")
		local _ = FI
		-- 28. La empresa sigue en pausa: los empleados se mueven pero el tiempo y el dinero no.
		check(App.menuPaused(), "28. el editor pausa la empresa (setUiPause)")
		local day0, min0, money0 = sess.game.time.day, sess.game.time.minute, sess.game.money
		local t0 = Mgr.world().t
		local inv0 = M.stats.invokes
		advance(20)
		check(Mgr.world().t > t0 + 10, "28. los empleados siguen con sus actividades visuales")
		check(sess.game.time.day == day0 and sess.game.time.minute == min0, "28. el tiempo de la empresa no avanza")
		eq(sess.game.money, money0, "28. el dinero no cambia")
		eq(M.stats.invokes, inv0, "los empleados no envían solicitudes al servidor")
		-- 25. Herramientas del editor intactas, aunque haya un empleado en el lugar.
		local npc = Act.list(Mgr.world())[1]
		local R = npc.room
		local px, py = math.floor(npc.x) + 0.5, math.floor(npc.y) + 0.5
		Editor.startPlace("planta_interior_1970")
		Editor.hover(R, px, py)
		local hv = Editor.state().hover
		if hv and hv.valid then
			local r = Editor.confirm()
			check(r and r.ok, "25. se coloca un mueble donde estaba parado un empleado")
			Mgr.step(0.2)
			check(Nav.clearAt(Mgr.world().rooms[R].grid, npc.x, npc.y), "25. el empleado se corre: no queda dentro del mueble")
		end
		Editor.cancel()
		-- Ubicaciones libres (las valida igual que el editor) para colocar y después mover el escritorio.
		local desk = OfficeCatalog.item("escritorio_metal_1970")
		local spots = {}
		for _, c in { { 5, 2.5 }, { 7, 2.5 }, { 5, 5.5 }, { 7, 5.5 }, { 3, 6.5 }, { 8, 6.5 }, { 4, 1.5 } } do
			local gx, gy = Editor.snap(desk, c[1], c[2], 45)
			if Office.validatePlacement(App.g.office, desk, { room = "oficina_principal", x = c[1], y = c[2], rot = 0 }) and Office.validatePlacement(App.g.office, desk, { room = "oficina_principal", x = gx, y = gy, rot = 45 }) then
				table.insert(spots, c)
			end
		end
		check(#spots >= 2, "hay lugar para el escritorio")
		local a1, a2 = spots[1], spots[#spots]
		Editor.startPlace("escritorio_metal_1970")
		Editor.hover("oficina_principal", a1[1], a1[2])
		local pr = Editor.confirm()
		check(pr and pr.ok, "25. colocar: " .. tostring(pr and pr.msg))
		Editor.cancel()
		check(Editor.selectAt("oficina_principal", a1[1], a1[2]) ~= nil, "25. elegir un mueble")
		local rr = Editor.rotateSelected(1)
		check(rr and rr.ok, "25. girar: " .. tostring(rr and rr.msg))
		Editor.startMove()
		Editor.hover("oficina_principal", a2[1], a2[2])
		while Editor.state().rot ~= 0 do
			Editor.rotate(1)
		end
		Editor.hover("oficina_principal", a2[1], a2[2])
		local mv = Editor.confirm()
		check(mv and mv.ok, "25. mover: " .. tostring(mv and mv.msg))
		check(Editor.selectAt("oficina_principal", a2[1], a2[2]) ~= nil and Editor.removeSelected().ok, "25. guardar en el inventario")
		check(named("SeccionMobiliario") ~= nil and named("SeccionRemodelacion") ~= nil and named("TabCatalogo") ~= nil, "25. secciones y catálogo")
		Mgr.step(0.2)
		-- Panel del empleado elegido (clic sobre el personaje).
		local target = Act.list(Mgr.world())[2]
		local pos = Mgr.position(target.id)
		eq(Mgr.pickRay(pos + M.Vector3.new(0, 60, 0), M.Vector3.new(0, -1, 0)), target.id, "un clic sobre el personaje lo elige")
		Editor.selectEmployee(target.id)
		M.task.wait()
		local panel = named("PanelEmpleado")
		check(panel ~= nil and M.find(panel, target.name) ~= nil, "panel con el nombre")
		check(named("EmpleadoDepartamento") ~= nil and named("EmpleadoActividad") ~= nil and named("EmpleadoNavegacion") ~= nil, "departamento, actividad y navegación")
		check(M.button(panel, "Contratar") == nil and M.button(panel, "Despedir") == nil, "sin contratar ni despedir en el panel")
		clickN("EnfocarEmpleado")
		local fp = OfficeCamera.state().tFocus
		check(math.abs(fp.X - pos.X) < 4 and math.abs(fp.Z - pos.Z) < 4, "«Enfocar» centra la cámara en el empleado")
		clickN("CerrarEmpleado")
		M.task.wait()
		check(named("PanelEmpleado") == nil, "cerrar el panel")
		-- 27 y 29. Ocultar: no cambia la cantidad real, los beneficios, la oficina ni la economía.
		local org0, rev0, emp0 = Rules.staff(App.g, "organizacion"), App.g.office.rev, #App.g.employees
		local serverOrg = Rules.staff(sess.game, "organizacion")
		inv0 = M.stats.invokes
		clickN("MostrarEmpleados")
		M.task.wait()
		check(not Mgr.shown(), "27. ocultos")
		local f = Scene.folder()
		check(f:FindFirstChild("Empleados") == nil, "27. sin personajes en la escena")
		check(find("(ocultos)") ~= nil, "27. el contador lo indica")
		local tHidden = Mgr.world().t
		advance(5)
		eq(Mgr.world().t, tHidden, "27. actividades suspendidas")
		eq(M.stats.invokes, inv0, "27. ocultar no envía nada al servidor")
		eq(#App.g.employees, emp0, "27. mismo número de empleados")
		eq(App.g.office.rev, rev0, "27. la oficina guardada no cambia")
		eq(Rules.staff(App.g, "organizacion"), org0, "29. los beneficios del mobiliario siguen igual")
		eq(Rules.staff(sess.game, "organizacion"), serverOrg, "29. también en el servidor")
		clickN("MostrarEmpleados")
		M.task.wait()
		check(Mgr.shown() and f:FindFirstChild("Empleados") ~= nil and npcModels() == 6, "27. al mostrarlos vuelven los seis")
		-- 26. Abrir y cerrar varias veces: sin personajes ni conexiones de más.
		for i = 1, 5 do
			App.ui.facSel = "offices"
			App.go("compania")
			M.task.wait()
			check(not Mgr.isOpen() and Mgr.connections() == 0, "26. cerrar #" .. i .. ": sin conexión")
			eq(heartbeatHandlers(), hb0, "26. cerrar #" .. i .. ": Heartbeat como al principio")
			check(M.services.Workspace:FindFirstChild("EditorOficina") == nil, "26. cerrar #" .. i .. ": nada en el Workspace")
			App.go("oficina")
			M.task.wait()
			eq(npcModels(), 6, "26. abrir #" .. i .. ": seis personajes, sin duplicados")
			eq(heartbeatHandlers(), hb0 + 1, "26. abrir #" .. i .. ": una sola conexión")
			eq(Mgr.world().res and #Mgr.world().gone or 0, 0, "26. sin restos de la vez anterior")
		end
		-- 30. Partidas: ningún dato de los empleados visibles en el guardado y el esquema sigue igual.
		eq(GameState.SCHEMA, 19, "30. esquema de guardado sin cambios (sin migraciones)")
		local saved = serde.encode("json", sess.game)
		for _, word in { "heading", "Walking", "reserv", "npc", "OfficeNPC", "pose" } do
			check(string.find(saved, word, 1, true) == nil, "30. el guardado no lleva «" .. word .. "»")
		end
		local probe = sess.game.office
		for k in probe do
			check(table.find({ "version", "level", "seq", "rev", "inventory", "placed", "finishes", "storedFinishes", "starter", "ops" }, k) ~= nil, "30. g.office solo con sus campos de siempre (" .. k .. ")")
		end
		-- 12. Despedir libera al amigo y su personaje desaparece.
		local victim = App.g.employees[1]
		local freedId = victim.friend.userId
		App.ui.dialogs = {}
		local fr = App.request("fire", { employeeId = victim.id })
		check(fr.ok, "despedir: " .. tostring(fr.msg))
		check(waitFor(function()
			return #App.g.employees == 5
		end), "quedan cinco")
		Mgr.step(0.2)
		check(Mgr.npc(victim.id) == nil and Mgr.rig(victim.id) == nil, "12. su representación desaparece")
		eq(App.payload.friends.available, 3, "12. su amigo vuelve a estar libre")
		-- 13. Más contrataciones que amigos: puestos sin identidad y sin clones.
		if #App.g.candidates < 4 then
			check(App.request("searchCandidates", { kind = "general" }).ok, "búsqueda de candidatos")
			waitFor(function()
				return #App.g.candidates >= 4
			end)
		end
		for _ = 1, 4 do
			local c = App.g.candidates[1]
			if not c then
				break
			end
			App.request("hire", { candidateId = c.id })
		end
		local withF, without, seenU = 0, 0, {}
		for _, e in App.g.employees do
			if e.friend then
				withF += 1
				check(not seenU[e.friend.userId], "13. ningún amigo repetido")
				seenU[e.friend.userId] = true
			else
				without += 1
			end
		end
		check(withF == 8 and without >= 1, "13. ocho con amigo y el resto como puestos sin identidad (" .. without .. ")")
		check(seenU[freedId] == true, "el amigo liberado se volvió a asignar")
		Mgr.step(0.5)
		for _, npc in Act.list(Mgr.world()) do
			local e
			for _, x in App.g.employees do
				if x.id == npc.id then
					e = x
				end
			end
			check(e and e.friend ~= nil, "13. solo hay personajes de empleados con amigo")
		end
		App.forceRender()
		M.task.wait()
		check(find("sin amigo") ~= nil, "el contador muestra los puestos sin amigo")
		M.avatarsEnabled = false
		-- Cambiar de empresa: el editor se cierra y no queda ningún empleado de esta.
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
		M.task.wait()
		check(not Mgr.isOpen() and Mgr.connections() == 0, "al salir de la empresa no quedan empleados ni conexiones")
		noErrors("Empleados visibles en el editor")
	end)

	-- Correcciones de la etapa 5 ------------------------------------------------------------------------------

	-- Empresa nueva y limpia para las pruebas con el servidor real (borra otra de prueba si no hay ranura).
	local function freshCompany(name: string): any
		App.closeAllDialogs()
		if App.g then
			App.request("leaveCompany", {})
			waitFor(function()
				return App.g == nil
			end)
		end
		local slot
		for _, k in { "1", "2", "3", "4" } do
			if App.profile.slots[k] == nil and (tonumber(k) <= 2 or (App.profile.unlocked or {})[k]) then
				slot = k
				break
			end
		end
		if not slot then
			for k, v in App.profile.slots do
				if v and v.name ~= nil then
					App.request("deleteCompany", { slot = k, confirm = v.name })
					slot = k
					break
				end
			end
		end
		local r = App.request("createCompany", { slot = slot, name = name, color = "#FF8A3D", logo = "pico" })
		assert(r.ok, r.msg)
		waitFor(function()
			return App.g ~= nil
		end)
		if App.screens.intro.active() then
			App.screens.intro.finish()
		end
		local sess = Sessions.instance.list[player]
		sess.game.money = 1e6
		sess.game.sede = 3
		Sessions.instance:push(sess)
		waitFor(function()
			return App.g.money == 1e6
		end)
		return sess
	end

	local function setFriends(sess: any, list: { any })
		M.friendsOf[player.UserId] = list
		Sessions.instance:fetchFriends(sess)
		waitFor(function()
			return App.payload.friends ~= nil and App.payload.friends.status == "ok" and App.payload.friends.total == #list
		end)
	end

	local function hireUi(n: number)
		for _ = 1, n do
			if #App.g.candidates == 0 then
				App.request("searchCandidates", { kind = "general" })
				waitFor(function()
					return #App.g.candidates > 0
				end)
			end
			local before = #App.g.employees
			local r = App.request("hire", { candidateId = App.g.candidates[1].id })
			assert(r.ok, r.msg)
			waitFor(function()
				return #App.g.employees == before + 1
			end)
		end
	end

	-- Espera en tiempo real (los límites del servidor son por segundo real) avanzando la oficina.
	local function waitReal(cond: () -> boolean, seconds: number): boolean
		local t0 = os.clock()
		while os.clock() - t0 < seconds do
			Mgr.step(0.5)
			if cond() then
				return true
			end
			M.task.wait(0.05)
		end
		return cond()
	end

	local function friendList(n: number, base: number, online: boolean?): { any }
		local out = {}
		for i = 1, n do
			table.insert(out, { userId = base + i, username = "amigo" .. (base + i), displayName = "Amigo " .. (base + i), isOnline = online == true and i % 2 == 0 })
		end
		return out
	end

	test("Correcciones etapa 5: habitaciones distintas con coordenadas iguales no se estorban", function()
		local o = Office.new(2)
		local cMain = put(o, "silla_oficina_1970", "oficina_principal", 2.5, 2.5)
		local cSala = put(o, "silla_oficina_1970", "sala_reuniones", 2.5, 2.5)
		local world = Act.new(o, { seed = "salas" })
		Act.setEmployees(world, staff(2, "h"), true)
		local a, b = Act.list(world)[1], Act.list(world)[2]
		local spMain = world.rooms.oficina_principal.byKey[Act.spotKey("oficina_principal", cMain, 1)]
		local spSala = world.rooms.sala_reuniones.byKey[Act.spotKey("sala_reuniones", cSala, 1)]
		check(spMain and spSala and spMain.x == spSala.x and spMain.y == spSala.y, "dos sillas en el mismo x, y local de habitaciones distintas")
		check(spMain.key ~= spSala.key and string.find(spMain.key, "oficina_principal/", 1, true) == 1 and string.find(spSala.key, "sala_reuniones/", 1, true) == 1, "las reservas llevan la habitación")
		-- A sentado en la silla de la oficina principal; B, en la sala de reuniones.
		a.room, b.room = "oficina_principal", "sala_reuniones"
		Act.interrupt(world, a, "prueba")
		Act.interrupt(world, b, "prueba")
		check(Act._reserve(world, a, spMain.keys), "A reserva su silla")
		a.activity = { kind = "sit", spot = spMain, key = spMain.key, keys = spMain.keys }
		a.state, a.x, a.y = "Sitting", spMain.x, spMain.y
		check(Act._spotFree(world, spSala, b.id), "1. la silla de la sala sigue libre para B (otra habitación)")
		check(not Act._spotFree(world, spMain, b.id), "la de la oficina principal está ocupada")
		-- Alguien parado en el mismo x, y de otra habitación tampoco estorba.
		Act.interrupt(world, a, "prueba")
		a.x, a.y = spSala.x, spSala.y
		check(Act._spotFree(world, spSala, b.id), "1. alguien parado en otra habitación no ocupa el punto")
		a.room = "sala_reuniones"
		check(not Act._spotFree(world, spSala, b.id), "en la misma habitación sí lo ocupa")
		-- Con la simulación: cada uno usa su silla al mismo tiempo, sin bloquearse.
		local o2 = Office.new(2)
		put(o2, "silla_oficina_1970", "oficina_principal", 2.5, 2.5)
		put(o2, "silla_oficina_1970", "sala_reuniones", 2.5, 2.5)
		local w2 = Act.new(o2, { seed = "salas2" })
		Act.setEmployees(w2, staff(2, "hh"), true)
		local l2 = Act.list(w2)
		l2[1].room, l2[2].room = "oficina_principal", "sala_reuniones"
		local both = false
		for _ = 1, 6000 do
			Act.step(w2, 0.1)
			if l2[1].state == "Sitting" and l2[2].state == "Sitting" and not l2[1].phase and not l2[2].phase then
				both = true
				break
			end
		end
		check(both, "los dos se sientan a la vez, cada uno en su habitación")
		noErrors("Habitaciones distintas")
	end)

	test("Correcciones etapa 5: un empleado que cambia de amigo nunca muestra el avatar anterior", function()
		local o = Office.new(1)
		Scene.buildRooms(o)
		local list = staff(2, "ra")
		provideAvatars(list)
		local company = { id = "reasig" }
		Mgr.open({ company = company, office = o, employees = list })
		Mgr.step(0.1)
		local rig = Mgr.rig("ra1")
		check(rig and rig.userId == list[1].friend.userId, "avatar del primer amigo")
		local oldModel = rig.model
		local oldUser = rig.userId
		-- Reasignación: el puesto pasa a otro amigo (su avatar todavía no llegó).
		local moved = { table.clone(list[1]), list[2] }
		moved[1].friend = { userId = 987654, username = "nuevo_amigo", displayName = "Nuevo Amigo", since = 1 }
		moved[1].name = "Nuevo Amigo"
		Mgr._state.lastRequest = -math.huge
		local req0 = Mgr._state.requests
		Mgr.sync({ company = company, office = o, employees = moved })
		check(oldModel.Parent == nil, "2. el avatar anterior se destruye en el acto")
		check(Mgr.rig("ra1") == nil, "2. sin referencias al personaje anterior")
		check(Mgr.npc("ra1") ~= nil and Mgr.npc("ra1").name == "Nuevo Amigo", "el empleado sigue (misma actividad), con el nombre nuevo")
		local shown = false
		for _, d in (Scene.folder():FindFirstChild("Empleados") or M.Instance.new("Folder")):GetDescendants() do
			if d.Name == "Nombre" and d.Text == "Nuevo Amigo" then
				shown = true
			end
		end
		check(not shown, "2. el nombre nuevo no aparece sobre ningún avatar mientras carga")
		check(Mgr._state.requests > req0, "2. se pide la apariencia nueva")
		eq(npcModels(), 1, "2. ningún personaje genérico mientras tanto")
		-- Una plantilla que dice ser de otro amigo no se usa.
		local fake = M.fakeR15(111)
		fake.Name = "Avatar_987654"
		fake:SetAttribute("userId", 111)
		fake:SetAttribute("builtAt", os.time())
		fake.Parent = M.services.Players.LocalPlayer.PlayerGui.AvataresEmpleados
		Mgr.step(0.1)
		check(Mgr.rig("ra1") == nil, "una plantilla de otro UserId no se muestra")
		fake:Destroy()
		-- Llega la apariencia correcta.
		provideAvatars({ moved[1] })
		Mgr.step(0.1)
		local nr = Mgr.rig("ra1")
		check(nr and nr.userId == 987654 and nr.userId ~= oldUser and nr.label.Text == "Nuevo Amigo", "2. el avatar nuevo con su nombre")
		-- Pierde el amigo (amistad terminada sin reemplazo): su personaje desaparece.
		local released = { table.clone(moved[1]), list[2] }
		released[1].friend = nil
		released[1].name = "Puesto sin amigo asignado"
		local nm = nr.model
		Mgr.sync({ company = company, office = o, employees = released })
		check(nm.Parent == nil and Mgr.npc("ra1") == nil, "sin amigo: sin personaje")
		Mgr.close()
		Scene.destroy()
		noErrors("Reasignación de avatar")
	end)

	test("Correcciones etapa 5: avatares R15 con accesorios, ropa en capas, uniones raras y distintas escalas", function()
		local NPCm = require("./.build-ui/client/OfficeNPC")
		local extras = { "weldconstraint", "rigid", "unknown", "broken", "orphan", "layered" }
		for _, scale in { 0.6, 1, 1.6 } do
			local tpl = M.fakeR15(5150, { extras = extras })
			tpl:SetAttribute("userId", 5150)
			tpl:ScaleTo(scale)
			local tlo, thi = math.huge, -math.huge
			for _, d in tpl:GetDescendants() do
				if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
					tlo = math.min(tlo, d.CFrame.Position.Y - d.Size.Y / 2)
					thi = math.max(thi, d.CFrame.Position.Y + d.Size.Y / 2)
				end
			end
			local h0 = thi - tlo
			local okB, rig = pcall(NPCm.build, "var" .. scale, "Variante", "produccion", tpl)
			check(okB and rig ~= nil, "escala " .. scale .. ": se arma aunque haya uniones desconocidas o rotas (" .. tostring(rig) .. ")")
			if okB and rig then
				local m = rig.model
				-- Relaciones de la plantilla (antes de animar) para comparar después.
				local head = m:FindFirstChild("Head")
				local hat = m:FindFirstChild("Sombrero")
				local glasses = m:FindFirstChild("Anteojos") and m.Anteojos:FindFirstChild("Handle")
				local broken = m:FindFirstChild("AccesorioRoto") and m.AccesorioRoto:FindFirstChild("Handle")
				local tail, loose = m:FindFirstChild("Cola"), m:FindFirstChild("Suelta")
				local jacket = m:FindFirstChild("Campera") and m.Campera:FindFirstChild("Handle")
				local upper = m:FindFirstChild("UpperTorso")
				local relHat = head.CFrame:Inverse() * hat.CFrame
				local relGl = head.CFrame:Inverse() * glasses.CFrame
				local relJk = upper.CFrame:Inverse() * jacket.CFrame
				local lo, hi = math.huge, -math.huge
				for _, d in m:GetDescendants() do
					if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
						lo = math.min(lo, d.CFrame.Position.Y - d.Size.Y / 2)
						hi = math.max(hi, d.CFrame.Position.Y + d.Size.Y / 2)
					end
				end
				local h = hi - lo
				local expect = h0 * math.clamp(NPCm.DIM.height / h0, NPCm.MIN_SCALE, NPCm.MAX_SCALE)
				check(math.abs(h - expect) < 0.05, string.format("escala %.1f: altura normalizada %.2f (esperada ≈ %.2f)", scale, h, expect))
				-- Animar sentado y de pie: cada accesorio sigue a su pieza.
				local npc = { state = "Sitting", pose = "sitwork", seed = 1, activity = { spot = { seatH = 1.5 } } }
				local cf = M.CFrame.new(10, 50, 10) * M.CFrame.Angles(0, 1, 0)
				local okA = pcall(function()
					for _ = 1, 20 do
						Anim.update(rig, npc, cf, 2, 0.05)
					end
				end)
				check(okA, "escala " .. scale .. ": se anima sin errores")
				local function near(a: any, b: any): boolean
					return (a.Position - b.Position).Magnitude < 1e-3
				end
				check(near(head.CFrame * relHat, hat.CFrame), "WeldConstraint: el sombrero sigue a la cabeza")
				check(near(head.CFrame * relGl, glasses.CFrame), "RigidConstraint (por Attachment): los anteojos siguen a la cabeza")
				check(near(upper.CFrame * relJk, jacket.CFrame), "ropa en capas soldada al revés: sigue al torso")
				check(broken and broken.CFrame.Position.Y > 50 and tail and tail.CFrame.Position.Y > 50 and loose and loose.CFrame.Position.Y > 50, "unión rota, desconocida o pieza suelta: acompañan al personaje (no quedan atrás)")
				local hipY = (m.LowerTorso.CFrame * rig.joints.LeftHip.c0).Position.Y - 50
				check(math.abs(hipY - 1.5) < 0.08, string.format("escala %.1f: sentado a la altura del asiento (%.2f)", scale, hipY))
				NPCm.destroy(rig)
			end
		end
		-- Lectura de uniones: tipos sin Part0/Part1 (RigidConstraint) y desconocidos nunca dan error.
		local m = M.fakeR15(1, { extras = extras })
		local n, okAll = 0, true
		for _, d in m:GetDescendants() do
			local ok, e = pcall(NPCm._readJoint, d, m)
			okAll = okAll and ok
			if ok and e then
				n += 1
			end
		end
		check(okAll and n >= 18, "3. todas las uniones se leen sin error (" .. n .. " válidas)")
		check(NPCm.build("x", "x", "produccion", M.Instance.new("Model")) == nil, "plantilla sin HumanoidRootPart: no se arma (sin error)")
		noErrors("Avatares R15")
	end)

	test("Correcciones etapa 5: con el servidor real — sin conexión, sin amigos, más empleados que amigos, pedidos inválidos, cambio de empresa durante la carga y reapertura", function()
		local EA = require("./.build-ui/server/EmployeeAvatars")
		local remote = M.services.ReplicatedStorage.CarEmpireRemotes.Avatares
		M.avatarsEnabled = true
		-- Amigos sin conexión: cuentan igual (la mitad desconectados).
		local sess = freshCompany("Amigos Lejos")
		setFriends(sess, friendList(4, 810000, true))
		hireUi(4)
		local offline = 0
		for _, e in App.g.employees do
			check(e.friend ~= nil, "amigo asignado aunque esté desconectado")
			local f = M.friendsOf[player.UserId]
			for _, x in f do
				if x.userId == e.friend.userId and not x.isOnline then
					offline += 1
				end
			end
		end
		check(offline >= 2, "amigos desconectados también son empleados (" .. offline .. ")")
		-- Más empleados que amigos.
		hireUi(2)
		local vac = 0
		for _, e in App.g.employees do
			if not e.friend then
				vac += 1
			end
		end
		eq(vac, 2, "13. dos puestos sin amigo")
		App.go("oficina")
		M.task.wait()
		check(waitReal(function()
			return npcModels() == 4 and EA.pending() == 0
		end, 10), "solo los 4 con amigo tienen personaje")
		-- Pedidos inválidos o duplicados al servidor: no arman nada ni rompen nada.
		local built = M.avatarCalls.model
		M.task.wait(2.1) -- ventana del límite de eventos
		for _, payload in { nil, 5, "e1", {}, { x = "e1" }, { { "e1" } }, { 1, 2, 3 }, (function()
			local t = {}
			for i = 1, 40 do
				t[i] = "e1"
			end
			return t
		end)() } do
			remote:FireServer(payload)
		end
		M.task.wait()
		eq(M.avatarCalls.model, built, "4. pedidos con formato inválido: nada")
		M.task.wait(2.1)
		local vacId
		for _, e in App.g.employees do
			if not e.friend then
				vacId = e.id
			end
		end
		remote:FireServer({ vacId })
		remote:FireServer({ "e-inexistente" })
		local one = App.g.employees[1].id
		remote:FireServer({ one, one, one })
		M.task.wait()
		eq(M.avatarCalls.model, built, "4. sin amigo, inexistentes o repetidos de uno vigente: nada nuevo")
		-- Límite de eventos: muchos seguidos, solo los primeros se procesan.
		M.task.wait(2.1)
		local gui = player:FindFirstChild("PlayerGui")
		local folder = gui:FindFirstChild("AvataresEmpleados")
		local tplOne = folder:FindFirstChild("Avatar_" .. App.g.employees[1].friend.userId)
		if tplOne then
			tplOne:Destroy() -- obliga a rearmar ese
		end
		local b0 = M.avatarCalls.model
		for _ = 1, 10 do
			remote:FireServer({ one })
		end
		M.task.wait(0.2)
		check(M.avatarCalls.model - b0 <= 1, "4. pedidos duplicados en ráfaga: un solo armado (" .. (M.avatarCalls.model - b0) .. ")")
		check(waitFor(function()
			return folder:FindFirstChild("Avatar_" .. App.g.employees[1].friend.userId) ~= nil
		end), "el avatar pedido llega")
		M.task.wait(2.1)
		-- Cerrar y reabrir el editor: sin personajes duplicados.
		for i = 1, 3 do
			App.go("compania")
			M.task.wait()
			App.go("oficina")
			M.task.wait()
			waitReal(function()
				return npcModels() == 4
			end, 10)
			local seen, dup = {}, false
			for _, mdl in Scene.folder():FindFirstChild("Empleados"):GetChildren() do
				local id = mdl:GetAttribute("employeeId")
				dup = dup or seen[id] == true
				seen[id] = true
			end
			check(npcModels() == 4 and not dup, "reabrir #" .. i .. ": 4 personajes, ninguno repetido")
		end
		-- Cambio de empresa mientras los avatares se arman: los resultados viejos se descartan.
		local sessA = freshCompany("Carga A")
		setFriends(sessA, friendList(3, 820000))
		hireUi(3)
		local aIds = {}
		for _, e in App.g.employees do
			aIds[e.friend.userId] = true
		end
		M.avatarDelay = 0.4
		local disc0, skip0 = EA._stats.discarded, EA._stats.skipped
		App.go("oficina")
		M.task.wait()
		Mgr.step(0.1) -- pide los avatares (quedan en curso)
		local sessB = freshCompany("Carga B") -- se cambia de empresa antes de que terminen
		setFriends(sessB, friendList(2, 830000))
		M.task.wait(1.5)
		M.avatarDelay = nil
		check(EA._stats.discarded + EA._stats.skipped > disc0 + skip0, "4. los avatares que llegaron tarde se descartan (" .. (EA._stats.discarded - disc0) .. " + " .. (EA._stats.skipped - skip0) .. ")")
		local leaked = 0
		for _, mdl in folder:GetChildren() do
			local uid = mdl:GetAttribute("userId")
			if uid and aIds[uid] then
				leaked += 1
			end
		end
		eq(leaked, 0, "4. ningún avatar de la empresa anterior se entrega")
		check(not Mgr.isOpen() or #Mgr.world().order == 0, "la empresa nueva no muestra empleados de la anterior")
		-- Jugador sin amigos.
		setFriends(sessB, {})
		hireUi(2)
		for _, e in App.g.employees do
			check(e.friend == nil and e.name == "Puesto sin amigo asignado", "sin amigos: puesto sin identidad")
		end
		App.go("personal")
		M.task.wait()
		App.ui.staff.view = "mercado"
		App.forceRender()
		M.task.wait()
		check(find("Tu lista de amigos de Roblox está vacía") ~= nil, "Personal lo explica")
		App.go("oficina")
		M.task.wait()
		Mgr.step(0.5)
		eq(npcModels(), 0, "sin amigos: oficina sin personajes (ni genéricos)")
		check(find("2 puestos sin amigo") ~= nil, "el contador muestra los puestos sin amigo")
		App.go("juego")
		M.avatarsEnabled = false
		noErrors("Servidor real")
	end)

	test("Recuperación de avatares (cliente): falla temporal, plantilla inválida, regeneración y sin reintentos infinitos", function()
		local o = Office.new(1)
		Scene.buildRooms(o)
		local list = staff(4, "rc")
		local folder = M.services.Players.LocalPlayer.PlayerGui:FindFirstChild("AvataresEmpleados")
		local function put(e: any, tpl: any)
			local old = folder:FindFirstChild("Avatar_" .. e.friend.userId)
			if old then
				old:Destroy()
			end
			tpl.Name = "Avatar_" .. e.friend.userId
			if tpl:GetAttribute("userId") == nil then
				tpl:SetAttribute("userId", e.friend.userId)
			end
			tpl:SetAttribute("builtAt", os.time())
			tpl.Parent = folder
			return tpl
		end
		-- 1) Falla temporal: la plantilla llega sin la raíz todavía (se está replicando) y se completa después.
		local t1 = M.fakeR15(list[1].friend.userId)
		local root1 = t1.HumanoidRootPart
		root1.Parent = nil
		put(list[1], t1)
		-- 2) Plantilla inválida: sin raíz para siempre (hasta que el servidor la regenere).
		local t2 = M.fakeR15(list[2].friend.userId)
		t2.HumanoidRootPart:Destroy()
		put(list[2], t2)
		-- 3) Inválida que nunca se arregla (para el tope de reintentos).
		local t3 = M.fakeR15(list[3].friend.userId)
		t3.HumanoidRootPart:Destroy()
		put(list[3], t3)
		-- 4) Plantilla que dice ser de otro UserId: inválida enseguida.
		local t4 = M.fakeR15(999)
		t4:SetAttribute("userId", 999)
		put(list[4], t4)
		local u1, u2, u3, u4 = list[1].friend.userId, list[2].friend.userId, list[3].friend.userId, list[4].friend.userId
		Mgr.open({ company = { id = "recupera" }, office = o, employees = list })
		local S = Mgr._state
		check(S.buildFail[u1] and S.buildFail[u1].n == 1 and not S.buildFail[u1].invalid, "falla temporal: primer intento fallido, sin darla por inválida")
		check(S.buildFail[u4] and S.buildFail[u4].invalid and (S.rebuildAsked[u4] or 0) == 1, "otro UserId: inválida enseguida y se pide regenerar")
		eq(npcModels(), 0, "ningún personaje genérico mientras tanto")
		root1.Parent = t1 -- terminó de llegar
		Mgr.step(Mgr.LOCAL_DELAY + 0.1)
		check(Mgr.rig("rc1") ~= nil and S.buildFail[u1] == nil, "falla temporal: se recupera reintentando acá")
		eq(S.rebuildAsked[u1], nil, "falla temporal: no se pidió regenerar al servidor")
		-- La inválida agota los reintentos locales y pide regenerar.
		for _ = 1, 8 do
			Mgr.step(1)
		end
		check(S.buildFail[u2] and S.buildFail[u2].invalid and S.rebuildAsked[u2] == 1, "inválida: tras " .. Mgr.LOCAL_RETRIES .. " intentos se pide regenerar")
		eq(#S.rebuildQueue, 0, "el pedido de regeneración se envió")
		-- El servidor manda una plantilla nueva: se arma sola.
		put(list[2], M.fakeR15(u2))
		Mgr.step(0.1)
		check(Mgr.rig("rc2") ~= nil and Mgr.rig("rc2").userId == u2 and S.buildFail[u2] == nil, "regenerada: el avatar aparece")
		-- La que nunca se arregla: regeneraciones con espera y tope, después «no disponible».
		local req0 = S.requests
		for _ = 1, 120 do
			Mgr.step(1)
		end
		check((S.rebuildAsked[u3] or 0) <= Mgr.MAX_REBUILDS and S.unavailable[u3] ~= nil, "sin arreglo: tope de " .. Mgr.MAX_REBUILDS .. " regeneraciones y queda no disponible (" .. tostring(S.unavailable[u3]) .. ")")
		check(S.requests - req0 <= Mgr.MAX_REBUILDS * 2 + 2, "sin pedidos infinitos (" .. (S.requests - req0) .. " en 120 s)")
		local req1 = S.requests
		for _ = 1, 60 do
			Mgr.step(1)
		end
		check(S.requests - req1 <= 1, "agotado: ya no se pide más")
		local _, _, _, _, unav = Mgr.counts({ employees = list })
		check(unav >= 1, "el contador cuenta los avatares no disponibles (" .. unav .. ")")
		eq(Mgr.info("rc3").avatarProblem, S.unavailable[u3].reason, "el panel del empleado lo explica")
		-- Ninguna duplicación: un modelo por empleado.
		local seen, dup = {}, false
		for _, mdl in Scene.folder():FindFirstChild("Empleados"):GetChildren() do
			local id = mdl:GetAttribute("employeeId")
			dup = dup or seen[id] == true
			seen[id] = true
		end
		check(not dup, "sin modelos duplicados")
		-- Al cerrar y reabrir se puede intentar de nuevo (con los límites del servidor).
		Mgr.close()
		check(next(S.unavailable) == nil and next(S.buildFail) == nil and next(S.rebuildAsked) == nil, "cerrar limpia el estado de recuperación")
		Scene.destroy()
		for _, e in list do
			local m = folder:FindFirstChild("Avatar_" .. e.friend.userId)
			if m then
				m:Destroy()
			end
		end
		noErrors("Recuperación (cliente)")
	end)

	test("Recuperación de avatares (servidor real): regenerar sin esperar 30 min, límites, autorización, fallas del servidor y cancelación", function()
		local EA = require("./.build-ui/server/EmployeeAvatars")
		local saved = { EA.REBUILD_GAP, EA.REBUILD_MAX, EA.RETRY_AFTER, EA.FAIL_MAX, EA.PER_MINUTE }
		EA.PER_MINUTE = 1000 -- el límite por minuto se prueba aparte: acá se encadenan muchas pruebas seguidas
		local remote = M.services.ReplicatedStorage.CarEmpireRemotes.Avatares
		M.avatarsEnabled = true
		local sess = freshCompany("Recupera SA")
		setFriends(sess, friendList(4, 840000))
		hireUi(4)
		App.go("oficina")
		M.task.wait()
		check(waitReal(function()
			return npcModels() == 4 and EA.pending() == 0
		end, 10), "los cuatro avatares llegan")
		local folder = player.PlayerGui.AvataresEmpleados
		local e1, e2 = App.g.employees[1], App.g.employees[2]
		local u1 = e1.friend.userId
		-- Antes: un pedido común de una plantilla vigente no la rearma (MODEL_TTL).
		M.task.wait(2.1)
		local c0 = M.avatarCalls.model
		remote:FireServer({ e1.id })
		M.task.wait(0.1)
		eq(M.avatarCalls.model, c0, "pedido común de una vigente: no se rearma")
		-- Regenerar: se rearma aunque esté vigente (pasado el intervalo mínimo).
		EA.REBUILD_GAP = 0
		local before = folder:FindFirstChild("Avatar_" .. u1)
		remote:FireServer({ e1.id }, { e1.id })
		check(waitReal(function()
			local now = folder:FindFirstChild("Avatar_" .. u1)
			return now ~= nil and now ~= before
		end, 5), "regenerada sin esperar MODEL_TTL")
		eq(M.avatarCalls.model, c0 + 1, "un solo armado")
		local count = 0
		for _, mdl in folder:GetChildren() do
			if mdl.Name == "Avatar_" .. u1 then
				count += 1
			end
		end
		eq(count, 1, "sin plantillas duplicadas")
		check(before.Parent == nil, "la anterior se reemplazó")
		-- Intervalo mínimo: justo después de armarla, otra regeneración se rechaza.
		EA.REBUILD_GAP = 10
		M.task.wait(2.1)
		local r0, c1 = EA._stats.refused, M.avatarCalls.model
		remote:FireServer({ e1.id }, { e1.id })
		M.task.wait(0.1)
		check(EA._stats.refused == r0 + 1 and M.avatarCalls.model == c1, "dentro del intervalo mínimo: rechazada")
		-- Tope por amigo: como mucho REBUILD_MAX regeneraciones en la ventana.
		EA.REBUILD_GAP, EA.REBUILD_MAX = 0, 2
		local c2 = M.avatarCalls.model
		for _ = 1, 4 do
			M.task.wait(2.1)
			remote:FireServer({ e2.id }, { e2.id })
			waitReal(function()
				return EA.pending() == 0
			end, 3)
			M.task.wait(0.2)
		end
		check(M.avatarCalls.model - c2 <= 2, "tope de regeneraciones por amigo (" .. (M.avatarCalls.model - c2) .. ")")
		-- Autorización: regenerar solo amigos de empleados de la empresa activa y pedidos en el mismo evento.
		M.task.wait(2.1)
		local c3 = M.avatarCalls.model
		remote:FireServer({ e1.id }, { "e-ajeno" })
		remote:FireServer({ e1.id }, { e2.id }) -- regenerar uno que no se pide
		remote:FireServer({ e1.id }, 5)
		remote:FireServer({ e1.id }, { { e1.id } })
		M.task.wait(0.2)
		eq(M.avatarCalls.model, c3, "regeneraciones no autorizadas o mal formadas: nada")
		-- El servidor entrega algo roto: no se entrega, cuenta como falla y se corta tras FAIL_MAX.
		EA.RETRY_AFTER, EA.FAIL_MAX = 0, 2
		local e3 = App.g.employees[3]
		local u3 = e3.friend.userId
		M.avatarVariant = function(uid: number): any
			return uid == u3 and { noRoot = true } or nil
		end
		local inv0, c4 = EA._stats.invalid, M.avatarCalls.model
		for _ = 1, 4 do
			M.task.wait(2.1)
			remote:FireServer({ e3.id }, { e3.id })
			waitReal(function()
				return EA.pending() == 0
			end, 3)
			M.task.wait(0.2)
		end
		M.avatarVariant = nil
		check(EA._stats.invalid > inv0, "modelo roto: no se entrega")
		check(M.avatarCalls.model - c4 <= 2, "fallas seguidas: se corta tras FAIL_MAX (" .. (M.avatarCalls.model - c4) .. " armados)")
		check(type(folder:GetAttribute("Agotado_" .. u3)) == "number", "el servidor avisa que dejó de intentarlo")
		local tpl3 = folder:FindFirstChild("Avatar_" .. u3)
		check(tpl3 == nil or tpl3:FindFirstChild("HumanoidRootPart") ~= nil, "nunca queda una plantilla rota entregada")
		-- Cancelación: una regeneración en curso cuando se despide al empleado se descarta.
		EA.REBUILD_GAP, EA.REBUILD_MAX = 0, 5
		local e4 = App.g.employees[4]
		local u4 = e4.friend.userId
		local old4 = folder:FindFirstChild("Avatar_" .. u4)
		M.avatarDelay = 0.5
		M.task.wait(2.1)
		local d0 = EA._stats.discarded + EA._stats.skipped
		remote:FireServer({ e4.id }, { e4.id })
		M.task.wait(0.05)
		check(App.request("fire", { employeeId = e4.id }).ok, "despedir mientras se regenera")
		M.task.wait(1)
		M.avatarDelay = nil
		check(EA._stats.discarded + EA._stats.skipped > d0, "la regeneración obsoleta se descarta")
		local now4 = folder:FindFirstChild("Avatar_" .. u4)
		check(now4 == nil or now4 == old4, "no se entrega un avatar del empleado despedido")
		Mgr.step(0.5)
		check(Mgr.npc(e4.id) == nil and Mgr.rig(e4.id) == nil, "su personaje ya no está")
		-- Límite por minuto: con el tope en 1, una segunda regeneración en el mismo minuto se ignora.
		EA.PER_MINUTE, EA.REBUILD_GAP, EA.REBUILD_MAX = 1, 0, 5
		local st = EA._perPlayer and EA._perPlayer(player)
		if st then
			st.count, st.windowStart = 0, os.clock()
		end
		local c5 = M.avatarCalls.model
		for _ = 1, 2 do
			M.task.wait(2.1)
			remote:FireServer({ e1.id }, { e1.id })
			waitReal(function()
				return EA.pending() == 0
			end, 3)
			M.task.wait(0.2)
		end
		check(st ~= nil and M.avatarCalls.model - c5 == 1, "límite por minuto respetado también al regenerar (" .. (M.avatarCalls.model - c5) .. ")")
		EA.REBUILD_GAP, EA.REBUILD_MAX, EA.RETRY_AFTER, EA.FAIL_MAX, EA.PER_MINUTE = saved[1], saved[2], saved[3], saved[4], saved[5]
		App.go("juego")
		M.avatarsEnabled = false
		noErrors("Recuperación (servidor)")
	end)

	test("Bloqueos de avatares: tres fallas, bloqueo temporal, vencimiento a los 600 s sin reabrir, rechazos que no consumen, regeneración, cancelación y sin duplicados", function()
		local EA = require("./.build-ui/server/EmployeeAvatars")
		local remote = M.services.ReplicatedStorage.CarEmpireRemotes.Avatares
		local saved = { EA.now, Mgr.now, EA.RETRY_AFTER, EA.FAIL_MAX, EA.FAIL_WINDOW, EA.REBUILD_GAP, EA.REBUILD_MAX, EA.PER_MINUTE }
		local T = os.time()
		local function clock(): number
			return T
		end
		EA.now, Mgr.now = clock, clock -- reloj simulado (mismo para servidor y cliente)
		EA.RETRY_AFTER, EA.FAIL_MAX, EA.FAIL_WINDOW, EA.REBUILD_GAP, EA.REBUILD_MAX, EA.PER_MINUTE = 60, 3, 600, 10, 3, 1000
		M.avatarsEnabled = true
		local sess = freshCompany("Bloqueos SA")
		setFriends(sess, friendList(2, 850000))
		hireUi(2)
		local e1, e2 = App.g.employees[1], App.g.employees[2]
		local u1, u2 = e1.friend.userId, e2.friend.userId
		M.avatarVariant = function(uid: number): any
			return uid == u1 and { noRoot = true } or nil -- el avatar de u1 sale roto hasta que se arregle
		end
		local S = Mgr._state
		local folder = player.PlayerGui.AvataresEmpleados
		local pst = EA._perPlayer(player)
		local function fails(): number
			local f = pst.fails[u1]
			return f and f.n or 0
		end
		local calls0 = M.avatarCalls.model
		App.go("oficina")
		M.task.wait()
		local opens = S.opens
		check(waitReal(function()
			return EA.pending() == 0 and Mgr.rig(e2.id) ~= nil and fails() == 1
		end, 10), "u2 aparece y u1 falla una vez")
		-- Tres fallas seguidas: el cliente vuelve a pedir tras RETRY y el servidor, pasada la espera por falla.
		for k = 2, 3 do
			T += EA.RETRY_AFTER + 1
			M.task.wait(2.1)
			Mgr.step(Mgr.RETRY + 1)
			check(waitReal(function()
				return EA.pending() == 0 and fails() == k
			end, 5), "falla " .. k .. " de u1")
		end
		eq(M.avatarCalls.model - calls0, 4, "tres intentos de u1 (más el de u2)")
		local untilT = folder:GetAttribute("Agotado_" .. u1)
		eq(untilT, T + EA.FAIL_WINDOW, "bloqueo: el atributo guarda el vencimiento (600 s)")
		Mgr.step(0.1)
		check(S.unavailable[u1] and S.unavailable[u1].untilT == untilT, "el cliente lo marca no disponible hasta el vencimiento")
		check(Mgr.rig(e1.id) == nil and npcModels() == 1, "sin personaje (ni genérico) mientras tanto")
		-- Bloqueo temporal: ni el cliente insiste ni el servidor arma, aunque se le pida directo.
		local c1, r1 = M.avatarCalls.model, S.requests
		T += 300
		M.task.wait(2.1)
		for _ = 1, 30 do
			Mgr.step(Mgr.RETRY + 1)
		end
		remote:FireServer({ e1.id })
		M.task.wait(0.2)
		eq(M.avatarCalls.model, c1, "bloqueado: el servidor no lo arma")
		check(S.requests - r1 <= 0, "bloqueado: el cliente no lo pide (" .. (S.requests - r1) .. ")")
		eq(fails(), 3, "el bloqueo no suma fallas")
		-- Vencimiento a los 600 s: se recupera solo, sin reabrir el editor.
		M.avatarVariant = nil -- el avatar de u1 ya se puede armar
		T = untilT + 1
		M.task.wait(2.1)
		check(waitReal(function()
			return Mgr.rig(e1.id) ~= nil
		end, 10), "vencido el bloqueo, el avatar aparece sin reabrir el editor")
		eq(S.opens, opens, "el editor no se reabrió")
		check(folder:GetAttribute("Agotado_" .. u1) == nil and pst.fails[u1] == nil, "el bloqueo vencido se limpió")
		eq(S.cycles[u1], 1, "un ciclo de reintento usado")
		-- Rechazos que NO consumen regeneraciones de u2.
		local function used(): number
			local rb = pst.rebuilds[u2]
			return rb and rb.n or 0
		end
		local tpl2 = folder:FindFirstChild("Avatar_" .. u2)
		local function ask()
			M.task.wait(2.1)
			remote:FireServer({ e2.id }, { e2.id })
			M.task.wait(0.1)
		end
		-- Regeneración aceptada: consume una y se entrega (la plantilla queda recién armada).
		local rb0 = EA._stats.rebuilt
		ask()
		local function regenerated(prev: any): boolean
			return waitReal(function()
				local now2 = folder:FindFirstChild("Avatar_" .. u2)
				return now2 ~= nil and now2 ~= prev and Mgr.rig(e2.id) ~= nil and Mgr.rig(e2.id).builtAt == now2:GetAttribute("builtAt")
			end, 5)
		end
		check(regenerated(tpl2), "regeneración exitosa: plantilla nueva y personaje rearmado")
		check(used() == 1 and EA._stats.rebuilt == rb0 + 1, "una regeneración consumida")
		tpl2 = folder:FindFirstChild("Avatar_" .. u2)
		-- Rechazos: ninguno consume una regeneración ni rearma nada.
		local ref0 = EA._stats.refused
		ask() -- recién armado: dentro de REBUILD_GAP
		check(used() == 1 and EA._stats.refused == ref0 + 1, "rechazo por frecuencia: no consume")
		T += EA.REBUILD_GAP + 1
		folder:SetAttribute("Fallo_" .. u2, T)
		ask()
		check(used() == 1, "rechazo por falla reciente: no consume")
		folder:SetAttribute("Fallo_" .. u2, nil)
		pst.count = EA.PER_MINUTE
		ask()
		check(used() == 1, "rechazo por límite por minuto: no consume")
		pst.count = 0
		pst.fails[u2] = { n = EA.FAIL_MAX, blockedUntil = T + 100 }
		ask()
		check(used() == 1, "rechazo por bloqueo: no consume")
		pst.fails[u2] = nil
		folder:SetAttribute("Agotado_" .. u2, nil)
		pst.building[u2] = true
		ask()
		check(used() == 1, "rechazo por armado en curso: no consume")
		pst.building[u2] = nil
		check(folder:FindFirstChild("Avatar_" .. u2) == tpl2 and EA._stats.refused == ref0 + 5, "cinco rechazos y nada rearmado")
		-- Después de los rechazos, la siguiente válida se acepta: los intentos siguen disponibles.
		ask()
		check(regenerated(tpl2), "regeneración aceptada después de los rechazos")
		eq(used(), 2, "solo las aceptadas consumen (2 de " .. EA.REBUILD_MAX .. ")")
		-- Sin duplicados (plantillas ni personajes).
		local tcount, seen, dup = {}, {}, false
		for _, mdl in folder:GetChildren() do
			tcount[mdl.Name] = (tcount[mdl.Name] or 0) + 1
			dup = dup or tcount[mdl.Name] > 1
		end
		for _, mdl in Scene.folder():FindFirstChild("Empleados"):GetChildren() do
			local id = mdl:GetAttribute("employeeId")
			dup = dup or seen[id] == true
			seen[id] = true
		end
		check(not dup and npcModels() == 2, "sin NPCs ni plantillas duplicados")
		-- Cancelación por cambio de empresa: la regeneración en curso se descarta.
		local tplNow = folder:FindFirstChild("Avatar_" .. u2)
		T += EA.REBUILD_GAP + 1
		M.avatarDelay = 0.5
		local d0 = EA._stats.discarded + EA._stats.skipped
		M.task.wait(2.1)
		remote:FireServer({ e2.id }, { e2.id })
		M.task.wait(0.05)
		local sessB = freshCompany("Bloqueos B")
		M.task.wait(1)
		M.avatarDelay = nil
		check(EA._stats.discarded + EA._stats.skipped > d0, "cambio de empresa: el resultado obsoleto se descarta")
		check(folder:FindFirstChild("Avatar_" .. u2) == tplNow, "no se entrega la plantilla de la empresa anterior")
		check(not Mgr.isOpen() or #Mgr.world().order == 0, "la empresa nueva no muestra empleados de la anterior")
		-- Tope de ciclos: un amigo que vuelve a bloquearse una y otra vez queda no disponible hasta reabrir.
		local _ = sessB
		local o = Office.new(1)
		Scene.buildRooms(o)
		local one = staff(1, "bq")
		local uq = one[1].friend.userId
		Mgr.open({ company = { id = "ciclos" }, office = o, employees = one })
		for k = 1, Mgr.MAX_CYCLES + 1 do
			folder:SetAttribute("Agotado_" .. uq, T + 10)
			Mgr._state.lastRequest = -math.huge
			Mgr.step(Mgr.RETRY + 1)
			check(S.unavailable[uq] ~= nil, "ciclo " .. k .. ": bloqueado")
			T += 11
			Mgr.step(0.1)
		end
		check(S.unavailable[uq] and S.unavailable[uq].untilT == math.huge and S.cycles[uq] == Mgr.MAX_CYCLES, "tras " .. Mgr.MAX_CYCLES .. " ciclos queda no disponible hasta reabrir (sin reintentos infinitos)")
		folder:SetAttribute("Agotado_" .. uq, nil)
		Mgr.close()
		Scene.destroy()
		EA.now, Mgr.now, EA.RETRY_AFTER, EA.FAIL_MAX, EA.FAIL_WINDOW, EA.REBUILD_GAP, EA.REBUILD_MAX, EA.PER_MINUTE = saved[1], saved[2], saved[3], saved[4], saved[5], saved[6], saved[7], saved[8]
		App.go("juego")
		M.avatarsEnabled = false
		noErrors("Bloqueos de avatares")
	end)
end


test("Etapa 6: ciclo jugable guiado por el botón principal con el capital inicial (sin callejones sin salida)", function()
	local Rules = require("./.build-ui/shared/Rules")
	local DesignCalc = require("./.build-ui/shared/DesignCalc")
	local Catalog = require("./.build-ui/shared/Catalog")
	App.closeAllDialogs()
	if App.g then
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
	end
	local slot
	for _, k in { "1", "2", "3", "4" } do
		if App.profile.slots[k] == nil and (tonumber(k) <= 2 or (App.profile.unlocked or {})[k]) then
			slot = k
			break
		end
	end
	if not slot then
		for k, v in App.profile.slots do
			if v and v.name ~= nil then
				App.request("deleteCompany", { slot = k, confirm = v.name })
				slot = k
				break
			end
		end
	end
	check(App.request("createCompany", { slot = slot, name = "Ciclo Guiado", color = "#3B82F6", logo = "pico" }).ok, "empresa nueva")
	waitFor(function()
		return App.g ~= nil
	end)
	if App.screens.intro.active() then
		App.screens.intro.finish()
	end
	-- Sin tutorial: así el dinero es solo el capital inicial (sin recompensas) y se prueba la guía general.
	App.request("setTutorial", { skipped = true })
	App.go("juego")
	M.task.wait()
	eq(App.g.money, Catalog.START.money, "capital inicial intacto")
	local function principal(): (string?, any)
		local b = named("Principal")
		return b and (M.find(b, "Diseñar otro modelo") and "otro" or M.find(b, "Diseñar") and "diseñar" or M.find(b, "Lanzar un lote") and "lote" or M.find(b, "Poner a la venta") and "vender" or "otro paso"), b
	end
	-- 1. Diseñar mi primer auto → editor.
	local kind, btn = principal()
	check(kind == "diseñar", "el botón principal propone diseñar el primer auto")
	M.click(btn)
	M.task.wait()
	eq(App.ui.route, "editor", "abre el editor")
	for _ = 1, 4 do
		clickN("Siguiente")
	end
	local fin = named("FinalizarDiseno")
	check(fin and fin:GetAttribute("disabled") == false, "finalizar habilitado con el capital inicial")
	M.click(fin)
	clickN("Confirmar")
	check(waitFor(function()
		return #App.g.designs == 1
	end), "diseño finalizado")
	eq(App.ui.route, "fabrica", "pasa a Producción")
	local d = App.g.designs[1]
	-- 2. Lote: los atajos que no alcanza el dinero aparecen apagados; el máximo pagable es razonable.
	App.go("juego")
	M.task.wait()
	kind, btn = principal()
	eq(kind, "lote", "el botón principal propone lanzar un lote")
	M.click(btn)
	M.task.wait()
	clickN("Vehiculo_" .. d.id)
	local unit = Rules.lotUnitCost(App.g, DesignCalc.computeDesign(App.g, d).unitCost)
	local afford = math.floor(App.g.money / unit)
	check(afford >= 20, "con el capital inicial alcanza para un primer lote razonable (" .. afford .. " unidades)")
	for _, q in { 10, 50, 100, 500, 1000 } do
		local b = named("Cantidad_" .. q)
		eq(b and b:GetAttribute("disabled") == true, q > afford, "atajo " .. q .. (q > afford and " apagado (no alcanza)" or " disponible"))
	end
	M.type(named("Cantidad"), "30")
	clickN("ContinuarLote")
	clickN("Confirmar")
	check(waitFor(function()
		return #App.g.lots == 1
	end), "lote creado")
	local lotId = App.g.lots[1].id
	-- 3. Al terminar: las reseñas se abren solas y llevan a Ventas.
	App.go("juego")
	check(waitFor(function()
		advance(1)
		local top = App.topDialog()
		return top ~= nil and top.kind == "reviews"
	end, 600), "al terminar la fabricación se abren las reseñas")
	local cards = 0
	clickN("SaltarResenas")
	M.task.wait()
	eq(App.ui.route, "ventas", "las reseñas llevan a Ventas")
	for _, x in App.g.lots do
		if x.id == lotId then
			cards = x.review and #x.review.scores or 0
		end
	end
	eq(cards, 4, "cuatro reseñas guardadas")
	-- 4. Precio recomendado y a la venta.
	check(named("PrecioReferencia") ~= nil and named("PonerALaVenta") ~= nil, "Ventas ofrece el precio recomendado y Poner a la venta")
	clickN("PrecioReferencia")
	clickN("PonerALaVenta")
	check(waitFor(function()
		for _, x in App.g.lots do
			if x.id == lotId then
				return x.saleState == "en venta"
			end
		end
		return false
	end), "a la venta")
	App.forceRender()
	M.task.wait()
	check(named("AvisoVentasArrancan") ~= nil, "Ventas explica que las ventas corren al volver al juego (menú en pausa)")
	-- 5. Primeras ventas y agotado: avisos breves, sin diálogos. (Con el menú de Ventas abierto la empresa queda en
	-- pausa, según la regla de los menús: se vuelve al juego para que corra el tiempo.)
	App.go("juego")
	M.task.wait()
	local sawFirst, sawSold = false, false
	for _ = 1, 600 do
		advance(1)
		for _, t in M.texts(App.toastLayer) do
			if string.find(t, "Primeras ventas", 1, true) then
				sawFirst = true
			end
			if string.find(t, "Agotado", 1, true) then
				sawSold = true
			end
		end
		if #App.g.lots == 0 then
			break
		end
	end
	check(sawFirst, "aviso de primeras ventas")
	check(sawSold or #App.g.lots == 0, "aviso de lote agotado")
	check(not dialogOpen(), "sin ventanas emergentes en el medio")
	check(App.g.money > Catalog.START.money, "terminó con ganancia sobre el capital inicial (" .. Util.money(App.g.money - Catalog.START.money) .. ")")
	-- 6. Todos los modelos ya fabricaron: el botón principal lleva a diseñar otro (no a un catálogo vacío).
	App.go("juego")
	M.task.wait()
	kind, btn = principal()
	eq(kind, "otro", "sin modelos por fabricar, el botón principal propone diseñar otro modelo")
	M.click(btn)
	M.task.wait()
	eq(App.ui.route, "editor", "y abre el editor")
	App.go("juego")
	noErrors("Ciclo guiado")
end)


test("HUD coherente: botón principal y alerta superior en los nueve estados del ciclo", function()
	local DesignCalc = require("./.build-ui/shared/DesignCalc")
	local Hud = App.screens.hud
	App.closeAllDialogs()
	if App.g then
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
	end
	local slot
	for _, k in { "1", "2", "3", "4" } do
		if App.profile.slots[k] == nil and (tonumber(k) <= 2 or (App.profile.unlocked or {})[k]) then
			slot = k
			break
		end
	end
	if not slot then
		for k, v in App.profile.slots do
			if v and v.name ~= nil then
				App.request("deleteCompany", { slot = k, confirm = v.name })
				slot = k
				break
			end
		end
	end
	check(App.request("createCompany", { slot = slot, name = "Alertas HUD", color = "#3B82F6", logo = "pico" }).ok, "empresa nueva")
	waitFor(function()
		return App.g ~= nil
	end)
	if App.screens.intro.active() then
		App.screens.intro.finish()
	end
	App.request("setTutorial", { skipped = true })
	App.go("juego")
	M.task.wait()
	local PARADA, OTRO, PRIMERO = "Iniciá la producción de uno de tus modelos.", "Tu último modelo completó su ciclo. Diseñá un nuevo automóvil para continuar.", "Diseñá tu primer automóvil para comenzar."
	-- Comprueba un estado: qué dice el botón principal, qué dice la alerta, y que el HUD dibujado coincida.
	local function state(label: string, wantMain: string?, wantAlert: string?, notMain: { string }?)
		App.closeAllDialogs()
		App.go("juego")
		App.forceRender()
		M.task.wait()
		local main = Hud.nextAction(App.g)
		local alert = Hud.topAlert(App.g)
		local alertText = alert and alert.text or nil
		if wantMain then
			eq(main and main.label, wantMain, label .. ": botón principal")
		end
		for _, bad in notMain or {} do
			check(not (main and main.label == bad), label .. ": el botón principal no propone «" .. bad .. "»")
		end
		if wantAlert then
			eq(alertText, wantAlert, label .. ": alerta superior")
		else
			check(alertText ~= PARADA and alertText ~= OTRO and alertText ~= PRIMERO, label .. ": sin alerta de fábrica parada (" .. tostring(alertText) .. ")")
		end
		-- Coherencia: cada alerta del ciclo va con el botón principal que corresponde.
		if alertText == PARADA then
			eq(main.label, "Lanzar un lote", label .. ": «fábrica parada» va con «Lanzar un lote»")
			eq(Hud.fabricable(App.g) > 0, true, label .. ": hay modelos fabricables")
		elseif alertText == OTRO then
			eq(main.label, "Diseñar otro modelo", label .. ": «diseñá un nuevo automóvil» va con «Diseñar otro modelo»")
			eq(Hud.fabricable(App.g), 0, label .. ": ningún modelo fabricable")
			eq(alert.go, "editor", label .. ": la alerta abre el editor")
		elseif alertText == PRIMERO then
			eq(main.label, "Diseñar mi primer auto", label .. ": va con «Diseñar mi primer auto»")
		end
		-- El HUD dibujado muestra esa misma alerta.
		local shown = named("Alerta")
		if alertText then
			check(shown ~= nil and M.find(shown, alertText) ~= nil, label .. ": el HUD muestra la alerta")
		else
			check(shown == nil, label .. ": el HUD no muestra alerta")
		end
	end
	local function newModel(name: string): any
		local dr = DesignCalc.newDraft(App.g, "brisa")
		dr.name = name
		local r = App.request("saveDesign", { draft = dr })
		check(r.ok, "diseño «" .. name .. "»: " .. tostring(r.msg))
		waitFor(function()
			for _, d in App.g.designs do
				if d.name == name then
					return true
				end
			end
			return false
		end)
		for _, d in App.g.designs do
			if d.name == name then
				return d
			end
		end
		return nil
	end
	local function lotFor(d: any): any
		for _, l in App.g.lots do
			if l.designId == d.id then
				return l
			end
		end
		return nil
	end
	local function runUntil(cond: () -> boolean): boolean
		for _ = 1, 900 do
			App.closeAllDialogs()
			if App.ui.route ~= "juego" then
				App.go("juego")
			end
			advance(1)
			if cond() then
				return true
			end
		end
		return false
	end
	-- 1. Empresa nueva sin diseños.
	state("1. sin diseños", "Diseñar mi primer auto", PRIMERO)
	-- 2. Primer diseño finalizado, sin fabricar.
	local d1 = newModel("Alerta Uno")
	state("2. diseño sin fabricar", "Lanzar un lote", PARADA)
	-- 3. Lote en producción.
	check(App.request("createLot", { designId = d1.id, qty = 10 }).ok, "lote")
	waitFor(function()
		return lotFor(d1) ~= nil
	end)
	state("3. fabricando", nil, nil, { "Lanzar un lote", "Diseñar otro modelo" })
	-- 4. Lote terminado, pendiente de venta.
	check(runUntil(function()
		local l = lotFor(d1)
		return l ~= nil and l.saleState == "por lanzar"
	end), "termina la fabricación")
	state("4. por lanzar", "Poner a la venta", nil)
	-- 5. A la venta.
	check(App.request("launchSale", { lotId = lotFor(d1).id, price = lotFor(d1).refPrice }).ok, "a la venta")
	waitFor(function()
		local l = lotFor(d1)
		return l ~= nil and l.saleState == "en venta"
	end)
	state("5. a la venta", nil, nil, { "Lanzar un lote", "Diseñar otro modelo" })
	-- 6 y 7. Vendido y archivado: todos los diseños usaron su lote.
	check(runUntil(function()
		return lotFor(d1) == nil
	end), "se agota y pasa al historial")
	eq(Hud.fabricable(App.g), 0, "ningún modelo fabricable")
	state("6. agotado y archivado", "Diseñar otro modelo", OTRO)
	state("7. todos los diseños usados", "Diseñar otro modelo", OTRO)
	-- 8. Nuevo modelo diseñado después del anterior.
	local d2 = newModel("Alerta Dos")
	state("8. modelo nuevo sin fabricar", "Lanzar un lote", PARADA)
	-- 9. Varios diseños, solo algunos usados.
	local d3 = newModel("Alerta Tres")
	eq(Hud.fabricable(App.g), 2, "dos fabricables y uno usado")
	state("9. varios, algunos usados (sin lotes)", "Lanzar un lote", PARADA)
	check(App.request("createLot", { designId = d2.id, qty = 5 }).ok, "lote del segundo")
	waitFor(function()
		return lotFor(d2) ~= nil
	end)
	state("9. varios, uno fabricándose y otro disponible", nil, nil, { "Diseñar otro modelo" })
	-- El botón principal y el catálogo del lote usan la misma regla.
	local Dialogs = require("./.build-ui/client/Dialogs")
	local n = 0
	for _, d in App.g.designs do
		if Dialogs.lotBlock(App.g, d) == nil then
			n += 1
		end
	end
	eq(Hud.fabricable(App.g), n, "misma regla que el catálogo del lote")
	local function current(d: any): any
		for _, x in App.g.designs do
			if x.id == d.id then
				return x
			end
		end
		return nil
	end
	check(Dialogs.lotBlock(App.g, current(d3)) == nil and Dialogs.lotBlock(App.g, current(d1)) ~= nil, "el usado no se puede fabricar; el nuevo sí")
	App.go("juego")
	noErrors("HUD coherente")
end)


test("HUD y tutorial: la alerta superior respeta el paso del tutorial (t1–t6) con y sin lotes, archivados y sin fondos", function()
	local DesignCalc = require("./.build-ui/shared/DesignCalc")
	local Catalog = require("./.build-ui/shared/Catalog")
	local Rules = require("./.build-ui/shared/Rules")
	local Hud = App.screens.hud
	App.closeAllDialogs()
	if App.g then
		App.request("leaveCompany", {})
		waitFor(function()
			return App.g == nil
		end)
	end
	local slot
	for _, k in { "1", "2", "3", "4" } do
		if App.profile.slots[k] == nil and (tonumber(k) <= 2 or (App.profile.unlocked or {})[k]) then
			slot = k
			break
		end
	end
	if not slot then
		for k, v in App.profile.slots do
			if v and v.name ~= nil then
				App.request("deleteCompany", { slot = k, confirm = v.name })
				slot = k
				break
			end
		end
	end
	check(App.request("createCompany", { slot = slot, name = "Tutorial HUD", color = "#3B82F6", logo = "pico" }).ok, "empresa nueva")
	waitFor(function()
		return App.g ~= nil
	end)
	if App.screens.intro.active() then
		App.screens.intro.finish()
	end
	App.go("juego")
	M.task.wait()
	App.ui.editor = nil
	-- Estados reales de un lote (del servidor): fabricando, por lanzar, a la venta y archivado.
	local dr = DesignCalc.newDraft(App.g, "brisa")
	dr.name = "Tutorial Uno"
	check(App.request("saveDesign", { draft = dr }).ok, "diseño")
	waitFor(function()
		return #App.g.designs == 1
	end)
	local base = Util.deepCopy(App.g)
	local d1 = App.g.designs[1]
	check(App.request("createLot", { designId = d1.id, qty = 10 }).ok, "lote")
	waitFor(function()
		return #App.g.lots == 1
	end)
	local producing = Util.deepCopy(App.g)
	local function runUntil(cond: () -> boolean): boolean
		for _ = 1, 900 do
			App.closeAllDialogs()
			if App.ui.route ~= "juego" then
				App.go("juego")
			end
			advance(1)
			if cond() then
				return true
			end
		end
		return false
	end
	check(runUntil(function()
		return App.g.lots[1] ~= nil and App.g.lots[1].saleState == "por lanzar"
	end), "por lanzar")
	local ready = Util.deepCopy(App.g)
	check(App.request("launchSale", { lotId = App.g.lots[1].id, price = App.g.lots[1].refPrice }).ok, "a la venta")
	waitFor(function()
		return App.g.lots[1] ~= nil and App.g.lots[1].saleState == "en venta"
	end)
	local selling = Util.deepCopy(App.g)
	check(runUntil(function()
		return #App.g.lots == 0
	end), "agotado y archivado")
	local archived = Util.deepCopy(App.g)
	check(#archived.lotHistory >= 1 and Hud.fabricable(archived) == 0, "archivado: ningún modelo fabricable")
	-- Escenarios de lotes (copias de estados reales).
	local function noFunds(): any
		local g = Util.deepCopy(producing)
		g.lots[1].prodState = "sin fondos"
		return g
	end
	local function archivedPlusNew(): any
		local g = Util.deepCopy(archived)
		local nd = Util.deepCopy(g.designs[1])
		nd.id, nd.name, nd.lotLaunched = "d-nuevo", "Tutorial Dos", nil
		table.insert(g.designs, nd)
		return g
	end
	local LOTS = {
		{ "sin diseños", function(): any
			local g = Util.deepCopy(base)
			g.designs = {}
			return g
		end },
		{ "diseño sin fabricar", function(): any
			return Util.deepCopy(base)
		end },
		{ "fabricando", function(): any
			return Util.deepCopy(producing)
		end },
		{ "por lanzar", function(): any
			return Util.deepCopy(ready)
		end },
		{ "a la venta", function(): any
			return Util.deepCopy(selling)
		end },
		{ "archivado (todos usados)", function(): any
			return Util.deepCopy(archived)
		end },
		{ "archivado + modelo nuevo", archivedPlusNew },
		{ "sin fondos", noFunds },
	}
	-- Paso del tutorial: los anteriores reclamados; el actual en progreso o con la recompensa lista.
	local tutorials = {}
	for _, m in Catalog.MISSIONS do
		if m.kind == "tutorial" then
			table.insert(tutorials, m)
		end
	end
	local function setTutorial(g: any, k: number?, ready: boolean, skipped: boolean)
		g.claimed = {}
		g.tutorial = { skipped = skipped, tips = true }
		for i, m in tutorials do
			if k == nil or i < k then
				g.claimed[Rules.missionKey(g, m)] = true
			end
		end
		if k then
			local m = tutorials[k]
			g.counters[m.counter] = ready and Rules.missionGoal(g, m) or 0
		end
	end
	local checked, coherent, critical = 0, 0, 0
	local failures = {}
	local function verify(label: string, g: any, tutorialOn: boolean)
		local cta = Hud.nextAction(g)
		local alert = Hud.topAlert(g)
		checked += 1
		local ok = true
		if alert and alert.critical then
			critical += 1
		elseif cta and cta.tutorial and tutorialOn then
			ok = alert == nil or alert.intent == cta.intent
		end
		if ok then
			coherent += 1
		else
			table.insert(failures, label .. ": botón «" .. tostring(cta and cta.label) .. "» y alerta «" .. tostring(alert and alert.text) .. "»")
		end
		return cta, alert
	end
	for k = 1, #tutorials do
		for _, ready2 in { false, true } do
			for _, sc in LOTS do
				local g = sc[2]()
				setTutorial(g, k, ready2, false)
				verify(tutorials[k].id .. (ready2 and " (lista)" or "") .. " · " .. sc[1], g, true)
			end
		end
	end
	eq(#failures, 0, "t1–t6 × lotes: botón y alerta coherentes en " .. checked .. " combinaciones (" .. tostring(failures[1]) .. ")")
	-- Casos concretos.
	local function at(k: number?, scName: string, opts: any?): (any, any)
		for _, sc in LOTS do
			if sc[1] == scName then
				local g = sc[2]()
				setTutorial(g, k, opts and opts.ready or false, opts and opts.skipped or false)
				if opts and opts.rp then
					g.rp = opts.rp
					g.research.projects = {}
				end
				return Hud.nextAction(g), Hud.topAlert(g)
			end
		end
		return nil, nil
	end
	local cta, alert = at(4, "archivado (todos usados)")
	eq(cta.label, "Mejorar la fábrica", "t4 con el lote archivado: el botón dice mejorar la fábrica")
	check(alert == nil, "t4 con el lote archivado: la alerta no recomienda diseñar otro auto (" .. tostring(alert and alert.text) .. ")")
	cta, alert = at(6, "archivado (todos usados)")
	check(cta.label == "Diseñar otro modelo" and alert and alert.intent == "otro", "t6 con todo usado: botón y alerta piden diseñar otro modelo")
	cta, alert = at(2, "diseño sin fabricar")
	check(cta.label == "Ordenar un lote" and alert and alert.intent == "lote", "t2 sin lotes: botón y alerta piden fabricar")
	cta, alert = at(1, "sin diseños")
	check(cta.label == "Diseñar mi primer auto" and alert and alert.intent == "disenar", "t1 sin diseños: botón y alerta piden el primer auto")
	cta, alert = at(5, "diseño sin fabricar", { rp = 40 })
	check(cta.label == "Investigar" and alert and alert.intent == "investigar", "t5 con PI: la alerta de investigación acompaña al botón (no la de la fábrica)")
	cta, alert = at(3, "archivado (todos usados)", { ready = true })
	check(cta.label == "Reclamar recompensa" and alert == nil, "recompensa lista: sin alertas que la contradigan")
	for k = 1, #tutorials do
		cta, alert = at(k, "sin fondos")
		check(alert and alert.critical and alert.title == "Producción en pausa", tutorials[k].id .. ": la producción sin fondos se avisa siempre")
	end
	-- Tutorial terminado o salteado: el comportamiento corregido antes, sin cambios.
	for _, mode in { { nil, false, "terminado" }, { 3, true, "salteado" } } do
		local _, a1 = at(mode[1], "archivado (todos usados)", { skipped = mode[2] })
		local _, a2 = at(mode[1], "archivado + modelo nuevo", { skipped = mode[2] })
		local _, a3 = at(mode[1], "sin diseños", { skipped = mode[2] })
		local _, a4 = at(mode[1], "a la venta", { skipped = mode[2] })
		check(a1 and a1.intent == "otro", mode[3] .. ": todo usado → diseñá un nuevo automóvil")
		check(a2 and a2.intent == "lote", mode[3] .. ": con un modelo nuevo → la fábrica está parada")
		check(a3 and a3.intent == "disenar", mode[3] .. ": sin diseños → diseñá tu primer automóvil")
		check(a4 == nil or (a4.intent ~= "otro" and a4.intent ~= "lote" and a4.intent ~= "disenar"), mode[3] .. ": a la venta → sin alerta de fábrica parada")
	end
	-- El caso del informe, dibujado: t4 en curso con el lote vendido y archivado.
	setTutorial(App.g, 4, false, false)
	App.forceRender()
	M.task.wait()
	local b = named("Principal")
	check(b and M.find(b, "Mejorar la fábrica") ~= nil, "HUD: el botón principal dice «Mejorar la fábrica»")
	local shown = named("Alerta")
	check(shown == nil or M.find(shown, "Diseñá un nuevo automóvil") == nil, "HUD: la alerta no pide diseñar otro auto")
	App.request("sync")
	M.task.wait()
	App.go("juego")
	noErrors("HUD y tutorial")
end)

T.finish()
Build.clean()
process.exit(T.failed == 0 and 0 or 1)
