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
	eq(Util.gameDate(g0.time.day), "Ene 1970", "la empresa empieza en enero de 1970")
	check(find("Ene 1970") ~= nil, "el HUD muestra la fecha")
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
	M.type(named("Cantidad"), "40")
	eq(App.ui.lotDraft and App.ui.lotDraft.qty, 40, "la cantidad escrita se conserva")
	check(find("Ventas estimadas") ~= nil, "muestra la estimación de ventas")
	clickN("ConfirmarLote")
	local designId = App.g.designs[1].id
	check(waitFor(function()
		return lotOf(designId) ~= nil
	end), "el lote se crea")
	eq(lotOf(designId).qty, 40, "con la cantidad elegida")
	check(not dialogOpen(), "el diálogo se cierra")
	-- Se fabrica y se vende solo, sin ninguna acción.
	for _ = 1, 600 do
		local l = lotOf(designId)
		if l and l.sold >= 5 then
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
	for _, n in { "Disponibles", "Fabricadas", "Vendidas", "Ritmo", "Ingresos", "Resultado", "ModificarPrecio", "CerrarVenta" } do
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
	noErrors("Ventas")
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
	M.task.wait()
	M.services.RunService.RenderStepped:Fire(1 / 60) -- un cuadro: la cámara se ubica
	local diag = App.screens.editor.diagnose()
	check(diag.ok, "vista 3D: el auto está en el ViewportFrame y delante de la cámara" .. (diag.ok and "" or (": " .. table.concat(diag.problems, "; "))))
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
	local h = App.g.lotHistory[1]
	local kinds = {
		{ "lot", {} }, { "price", { lotId = h and h.id } }, { "confirm", { title = "x", body = "y" } },
		{ "notifications", {} }, { "daily", {} }, { "settings", {} },
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
	-- Magnate: sin dinero manual, alcanza para el primer diseño y un primer lote.
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
		if (d.Name == "Hud1" or string.sub(d.Name, 1, 6) == "Panel_" or d.Name == "PanelEditor" or d.Name == "Principal") and M.visible(d) then
			local x = d.AbsolutePosition.X
			local w = d.AbsoluteSize.X
			if x < -1 or x + w > vw + 1 then
				table.insert(out, d.Name .. string.format(" (%d..%d de %d)", x, x + w, vw))
			end
			-- Los elementos del HUD tampoco pueden quedar cortados por el borde derecho.
			if d.Name == "Hud1" then
				for _, c in d:GetChildren() do
					if c:IsA("GuiObject") and c.Visible and c.AbsolutePosition.X + c.AbsoluteSize.X > vw + 1 then
						table.insert(out, "Hud1/" .. c.Name .. string.format(" (termina en %d de %d)", c.AbsolutePosition.X + c.AbsoluteSize.X, vw))
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
