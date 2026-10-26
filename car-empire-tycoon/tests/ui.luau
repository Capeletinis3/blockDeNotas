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

local shared = M.Instance.new("Folder")
shared.Name = "CarEmpireShared"
shared.Parent = M.services.ReplicatedStorage

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


local function unitsWith(status: string): { any }
	local out = {}
	for _, u in App.g.units do
		if u.status == status then
			table.insert(out, u)
		end
	end
	return out
end

test("Recorrido completo por la interfaz: diseñar → recompensa → fabricar → salón → vender", function()
	local g0 = App.g
	local money0 = g0.money
	App.go("editor", { new = true })
	M.task.wait()
	eq(App.ui.route, "editor", "abre el editor")
	for step = 1, 3 do
		local nb = named("Siguiente")
		check(nb ~= nil, "paso " .. step .. ": botón Siguiente")
		M.click(nb)
	end
	local save = named("GuardarDiseno")
	check(save ~= nil and save:GetAttribute("disabled") == false, "guardar habilitado con fondos iniciales")
	M.click(save)
	check(waitFor(function()
		return #App.g.designs >= 1 and App.ui.editor.sourceId ~= nil
	end), "el diseño queda guardado")
	check(App.g.money <= money0, "el desarrollo se cobra (o no cuesta) al guardar")
	App.go("juego")
	M.task.wait()
	local claim = named("Reclamar")
	check(claim ~= nil, "la tarjeta del tutorial ofrece reclamar")
	local before = App.g.money
	M.click(claim)
	check(waitFor(function()
		return App.g.money > before
	end), "la recompensa del tutorial se acredita")
	-- Un segundo clic (o reenvío) no vuelve a pagar.
	local afterClaim = App.g.money
	App.request("claimMission", { id = "t1" })
	M.task.wait()
	eq(App.g.money, afterClaim, "la recompensa no se cobra dos veces")

	App.go("fabrica")
	M.task.wait()
	click("Nueva orden de producción")
	eq(topKind(), "order", "abre el diálogo de orden")
	M.type(named("Cantidad"), "6")
	eq(App.ui.orderDraft and App.ui.orderDraft.qty, 6, "la cantidad escrita se conserva")
	clickN("CrearOrden")
	check(waitFor(function()
		return #App.g.production.orders >= 1
	end), "la orden se crea")
	eq(App.ui.route, "fabrica", "sigue en la fábrica")
	check(not dialogOpen(), "el diálogo se cierra")
	for _ = 1, 900 do
		if #unitsWith("almacen") >= 2 then
			break
		end
		advance(1)
	end
	check(#unitsWith("almacen") >= 2, "se fabrican unidades")
	noErrors("Fabricación")

	App.go("autos")
	M.task.wait()
	click("Enviar al salón")
	check(waitFor(function()
		return #unitsWith("salon") >= 1
	end), "la unidad pasa al salón")
	click("Enviar al salón")
	waitFor(function()
		return #unitsWith("salon") >= 2
	end)

	App.go("ventas")
	local offer = nil
	for _ = 1, 900 do
		for _, c in App.g.customers do
			if c.state == "oferta" then
				offer = c
			end
		end
		if offer then
			break
		end
		advance(1)
	end
	check(offer ~= nil, "llega un cliente con oferta")
	if offer then
		M.task.wait()
		local accept = named("Aceptar_" .. offer.id)
		check(accept ~= nil, "botón aceptar de ese cliente")
		local sales0 = #App.g.sales
		M.click(accept)
		check(waitFor(function()
			return #App.g.sales > sales0
		end), "la venta se registra")
		local s = App.g.sales[1]
		check(s and s.price == offer.offer, "ingreso = oferta aceptada")
		check(s and s.listPrice ~= nil and s.margin == s.price - s.cost - (s.fee or 0), "lista, ingreso y margen separados")
	end
	noErrors("Venta")
end)

test("Negociación: probabilidad del servidor, monto redondeado y diálogo que se invalida", function()
	local offer = nil
	for _ = 1, 900 do
		for _, c in App.g.customers do
			if c.state == "oferta" then
				offer = c
			end
		end
		if offer then
			break
		end
		advance(1)
	end
	check(offer ~= nil, "otro cliente con oferta")
	if not offer then
		return
	end
	App.go("ventas")
	M.task.wait()
	App.openDialog("counter", { customerId = offer.id, wide = true })
	check(waitFor(function()
		return App.ui.counterDraft and App.ui.counterDraft.quote ~= nil
	end), "el servidor devuelve la probabilidad")
	local q = App.ui.counterDraft.quote
	eq(q.amount % 100, 0, "el monto mostrado está redondeado a $100")
	check(find(tostring(q.chance) .. "%") ~= nil, "se muestra la probabilidad exacta")
	check(find("tirada") == nil, "no se muestran detalles de la tirada")
	-- El cliente se va: el diálogo deja de ofrecer contraofertar.
	App.request("rejectCustomer", { customerId = offer.id })
	M.task.wait()
	if dialogOpen() then
		check(named("Contraofertar") == nil, "sin cliente no se puede contraofertar")
		App.closeAllDialogs()
	else
		check(true, "el diálogo se cerró")
	end
	noErrors("Negociación")
end)

test("Editor: cambios sin guardar al salir y al abrir otro proyecto", function()
	App.go("editor", { new = true })
	M.task.wait()
	App.screens.editor.change(function(d)
		d.name = "Prueba sin guardar"
	end)
	check(App.ui.editor.dirty, "el borrador queda con cambios")
	App.go("autos")
	M.task.wait()
	eq(topKind(), "unsaved", "pregunta antes de salir")
	clickN("SeguirEditando")
	eq(App.ui.route, "editor", "seguir editando no sale")
	eq(App.ui.editor.draft.name, "Prueba sin guardar", "el borrador se conserva")
	-- Abrir un proyecto guardado reemplazaría el borrador: también pregunta.
	local d = App.g.designs[1]
	App.go("editor", { designId = d.id })
	M.task.wait()
	eq(topKind(), "unsaved", "pregunta antes de abrir otro proyecto")
	clickN("Descartar")
	eq(App.ui.route, "editor", "abre el otro proyecto")
	eq(App.ui.editor.sourceId, d.id, "es el proyecto elegido")
	-- Deshacer y rehacer.
	App.screens.editor.change(function(dd)
		dd.name = "Otro nombre"
	end)
	App.screens.editor.undo()
	eq(App.ui.editor.draft.name, d.name, "deshacer vuelve al nombre anterior")
	App.screens.editor.redo()
	eq(App.ui.editor.draft.name, "Otro nombre", "rehacer reaplica el cambio")
	App.screens.editor.undo()
	check(not App.ui.editor.dirty, "sin cambios reales ya no pide guardar")
	App.go("juego")
	M.task.wait()
	eq(App.ui.route, "juego", "sale sin preguntar si no hay cambios")
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
	check(named("Camara_frontal") ~= nil and named("Camara_libre") ~= nil, "siete cámaras con su tecla")
	clickN("Camara_frontal")
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
	eq(topKind(), "prevModels", "abre modelos anteriores")
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
	local u = App.g.units[1]
	local l = App.g.market.listings[1]
	local sale = App.g.sales[1]
	local kinds = {
		{ "order", {} }, { "confirm", { title = "x", body = "y" } }, { "unitDetail", { unitId = u and u.id, wide = true } },
		{ "saleDetail", { saleId = sale and sale.id } }, { "publish", {} },
		{ "listing", { listingId = l and l.id } }, { "notifications", {} }, { "daily", {} }, { "settings", {} },
		{ "help", { screen = "fabrica" } }, { "future", { what = "amigos" } }, { "future", { what = "eventos" } }, { "future", { what = "tienda" } },
		{ "news", {} }, { "prevModels", {} }, { "testDrive", {} },
		{ "deleteCompany", { slot = "1", expected = "Ruta Norte", name = "Ruta Norte" } },
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
	clickN("Crear_2")
	eq(App.ui.newCompany.slot ~= "1", true, "elige una ranura libre")
	clickN("Dificultad_dificil")
	for _, d in root:GetDescendants() do
		if d.ClassName == "TextBox" and d.PlaceholderText == "Por ejemplo: Ruta Norte Motors" then
			M.type(d, "Magnate SA")
		end
	end
	clickN("Comenzar")
	check(waitFor(function()
		return App.g ~= nil
	end), "se crea la segunda empresa")
	eq(App.g.company.name, "Magnate SA", "es la nueva")
	eq(App.g.company.difficulty, "dificil", "dificultad Magnate")
	-- Magnate: sin dinero manual, la recompensa del primer diseño alcanza para la primera orden.
	App.go("editor", { new = true })
	M.task.wait()
	for _ = 1, 3 do
		clickN("Siguiente")
	end
	clickN("GuardarDiseno")
	waitFor(function()
		return #App.g.designs >= 1
	end)
	App.go("juego")
	M.task.wait()
	clickN("Reclamar")
	waitFor(function()
		return App.g.claimed.t1 ~= nil
	end)
	App.go("fabrica")
	M.task.wait()
	click("Nueva orden de producción")
	clickN("CrearOrden")
	check(waitFor(function()
		return #App.g.production.orders >= 1
	end), "Magnate puede crear su primera orden")
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

test("Celular: todas las pantallas y diálogos se construyen con la distribución de celular", function()
	M.services.Workspace.CurrentCamera.ViewportSize = M.Vector2.new(844, 390)
	M.task.wait()
	eq(App.layout, "phone", "distribución de celular")
	for _, route in { "juego", "editor", "autos", "fabrica", "ventas", "mercado", "investigacion", "personal", "compania", "misiones", "estadisticas" } do
		App.renderError = nil
		App.go(route)
		M.task.wait()
		App.closeAllDialogs()
		check(App.renderError == nil, route .. " (celular)" .. (App.renderError and (": " .. tostring(App.renderError)) or ""))
	end
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
	noErrors("Celular")
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
