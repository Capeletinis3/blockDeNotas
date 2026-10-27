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
	check(named("Nav_editor") and named("Nav_editor"):FindFirstChild("Resaltado") ~= nil, "el tutorial resalta Diseño")
	App.go("editor", { new = true })
	M.task.wait()
	eq(App.ui.route, "editor", "abre el editor")
	App.screens.editor.goStep(2)
	M.task.wait()
	check(find("Efectos:") ~= nil, "las piezas muestran sus efectos")
	App.screens.editor.goStep(1)
	M.task.wait()
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
	for _, n in { "Encargadas", "Fabricadas", "Pendientes", "Disponibles", "Vendidas", "Ritmo", "Ingresos", "Gastos", "Resultado", "ModificarPrecio", "CerrarVenta", "Campana_0", "Campana_1" } do
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

	-- Editor: en el paso 3 de un sedán se elige la carrocería 3D (Pioneer 70 o provisional).
	App.go("editor", { new = true })
	M.task.wait()
	DesignCalc.changeBase(App.g, App.ui.editor.draft, "brisa")
	App.screens.editor.goStep(3)
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
	local lot = App.request("createLot", { designId = id, qty = 40 })
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
	for _ = 1, 40 do
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
	App.screens.editor.sync3d()
	M.task.wait()
	local inEditor = find3d(gui)
	check(#inEditor == 1, "la vista 3D del editor muestra el Pioneer 70 (" .. #inEditor .. ")")
	local vp = inEditor[1] and inEditor[1]:FindFirstAncestorWhichIsA("ViewportFrame")
	print("    editor: modelo «" .. tostring(inEditor[1] and inEditor[1].Name) .. "» dentro de " .. tostring(vp and vp:GetFullName()))
	-- 2) Elige un color en el paso 3 y guarda.
	for _ = 1, 2 do
		clickN("Siguiente")
	end
	check(named("Carroceria3D_pioneer70") ~= nil, "paso 3: la carrocería 3D elegida es el Pioneer 70")
	clickN("Pintura_Rojo carrera")
	M.task.wait()
	eq(App.ui.editor.draft.paint.primary, "#D6333F", "eligió «Rojo carrera»")
	App.screens.editor.sync3d()
	M.task.wait()
	local red = find3d(gui)[1]
	check(red ~= nil and red:FindFirstChild("Body_Paint").Color == M.Color3.fromHex("#D6333F"), "la vista 3D se repinta con el color elegido")
	clickN("Siguiente")
	local before = #App.g.designs
	clickN("GuardarDiseno")
	check(waitFor(function()
		return #App.g.designs > before
	end), "diseño guardado")
	local saved = App.g.designs[#App.g.designs]
	print("    guardado: «" .. saved.name .. "» · base " .. saved.baseId .. " · carrocería " .. tostring(saved.vehicleModel) .. " · color " .. saved.paint.primary)
	eq(saved.vehicleModel, "pioneer70", "el diseño guardado lleva el Pioneer 70")
	-- 3) Lanza un lote desde el diálogo de producción.
	App.ui.editor = nil
	App.closeAllDialogs()
	App.go("fabrica")
	M.task.wait()
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
	-- 4) El garaje muestra el auto fabricado con el Pioneer 70, pintado y apoyado en el piso.
	-- Con una sola línea, el lote espera en cola a que termine el anterior (como en el juego real).
	local found = {}
	for _ = 1, 200 do
		if next(found) ~= nil and #App.g.lots > 0 and App.g.lots[#App.g.lots].produced >= 3 then
			break
		end
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
				check(named("Expansion") ~= nil and named("ExpansionGlobal") ~= nil, "tarjeta y botón de expansión global")
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
