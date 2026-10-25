--[[
	Escenas de la vista previa: cada una lleva la interfaz a un estado concreto. Tienen los mismos nombres
	que las capturas de la V3 (tools/preview/v3.js) para compararlas lado a lado.
	Las escenas corren en orden sobre la misma sesión; las que modifican la partida van al final.
]]
local Scenes = {}

local function named(App: any, M: any, name: string): any
	for _, d in App.gui:GetDescendants() do
		if d.Name == name and M.visible(d) and not rawget(d, "__destroyed") then
			return d
		end
	end
	return nil
end
Scenes.named = named

function Scenes.list(_ctx: any): { any }
	local list = {}
	local function add(name: string, title: string, run: (any) -> ())
		table.insert(list, { name = name, title = title, run = run })
	end
	local function reset(c: any)
		local App = c.App
		App.closeAllDialogs()
		App.ui.sidePanel = nil
		App.ui.pop = nil
		App.ui.panelsHidden = false
	end
	-- Empresa «Vortex Motors» recién creada en la ranura 1 (se crea la primera vez).
	local function fresh(c: any)
		local App = c.App
		reset(c)
		local slots = App.profile and App.profile.slots or {}
		if not slots["1"] then
			App.request("createCompany", { slot = "1", name = "Vortex Motors", color = "#7667FF", logo = "pico", difficulty = "normal" })
		elseif not (App.g and App.payload.profile.active == "1") then
			App.request("selectSlot", { slot = "1" })
		end
		c.waitFor(function()
			return App.g ~= nil and not App.g.demo
		end)
	end
	local function demo(c: any, kind: string)
		local App = c.App
		reset(c)
		App.request("playDemo", { kind = kind })
		c.waitFor(function()
			return App.g ~= nil and App.g.demo == kind
		end)
	end
	local function go(c: any, route: string, params: any?)
		c.App.go(route, params)
		c.M.task.wait()
	end
	local function tab(c: any, key: string, value: string)
		c.App.ui.tabs[key] = value
		c.App.forceRender()
	end

	add("menu", "Menú de empresas (sin empresas)", function(c)
		reset(c)
		go(c, "menu")
	end)
	add("nueva", "Nueva empresa", function(c)
		reset(c)
		local nc = c.App.ui.newCompany
		nc.name, nc.color, nc.logo, nc.difficulty, nc.slot = "", "#7667FF", "pico", "normal", "1"
		go(c, "nueva")
	end)
	add("nueva-escrita", "Nueva empresa con datos", function(c)
		local nc = c.App.ui.newCompany
		nc.name, nc.color, nc.logo, nc.difficulty = "Vortex Motors", "#F7C95C", "rayo", "dificil"
		go(c, "nueva")
	end)
	add("juego-nuevo", "Sede de una empresa recién creada", function(c)
		fresh(c)
		go(c, "juego")
	end)
	for _, r in { "editor", "autos", "fabrica", "ventas", "mercado", "investigacion", "personal", "compania", "misiones", "estadisticas" } do
		add(r .. "-nuevo", r .. " (empresa nueva)", function(c)
			fresh(c)
			go(c, r)
		end)
	end
	add("menu-empresas", "Menú con empresas", function(c)
		fresh(c)
		if not c.App.profile.slots["2"] then
			c.App.request("leaveCompany")
			c.App.request("createCompany", { slot = "2", name = "Ruta Norte", color = "#F7C95C", logo = "rayo", difficulty = "dificil" })
		end
		c.App.request("leaveCompany")
		c.waitFor(function()
			return c.App.g == nil
		end)
		reset(c)
		go(c, "menu")
	end)
	add("menu-renombrar", "Menú: renombrar", function(c)
		local Menu = c.App.screens.menu
		if Menu.startRename then
			Menu.startRename("1")
		end
		c.App.forceRender()
	end)
	add("menu-eliminar", "Menú: confirmar eliminación", function(c)
		local Menu = c.App.screens.menu
		if Menu.cancelRename then
			Menu.cancelRename()
		end
		local s = c.App.profile.slots["2"]
		c.App.openDialog("deleteCompany", { slot = "2", expected = s and s.name or "", name = s and s.name or "", level = s and s.level, money = s and s.money })
	end)

	add("juego-op", "Sede (demostración en funcionamiento)", function(c)
		demo(c, "operacion")
		go(c, "juego")
	end)
	add("juego-op-ocultos", "Sede con paneles ocultos", function(c)
		demo(c, "operacion")
		c.App.ui.panelsHidden = true
		go(c, "juego")
	end)
	add("juego-op-mas", "Sede con el menú «Más»", function(c)
		demo(c, "operacion")
		go(c, "juego")
		local Hud = c.App.screens.hud
		if Hud.openMore then
			Hud.openMore()
		else
			Hud.openMenu(false)
		end
	end)
	add("juego-avanzada", "Sede (demostración avanzada)", function(c)
		demo(c, "avanzada")
		go(c, "juego")
	end)
	for _, r in { "autos", "fabrica", "ventas", "mercado", "investigacion", "personal", "compania", "misiones", "estadisticas" } do
		add(r .. "-op", r .. " (demostración)", function(c)
			demo(c, "operacion")
			go(c, r)
		end)
	end
	add("fabrica-avanzada", "Fábrica (demostración avanzada)", function(c)
		demo(c, "avanzada")
		go(c, "fabrica")
	end)
	local tabsList = {
		{ "autos-op-piezas", "autos", "autos", "parts" }, { "autos-op-materiales", "autos", "autos", "mats" }, { "autos-op-disenos", "autos", "autos", "designs" },
		{ "ventas-op-historial", "ventas", "ventas", "hist" },
		{ "mercado-op-pieza", "mercado", "mercado", "pieza" }, { "mercado-op-diseno", "mercado", "mercado", "diseno" }, { "mercado-op-material", "mercado", "mercado", "material" },
		{ "mercado-op-fav", "mercado", "mercado", "fav" }, { "mercado-op-mine", "mercado", "mercado", "mine" }, { "mercado-op-offers", "mercado", "mercado", "offers" },
		{ "personal-op-contratar", "personal", "personal", "hire" },
		{ "misiones-op-historia", "misiones", "misiones", "historia" }, { "misiones-op-diarias", "misiones", "misiones", "diaria" }, { "misiones-op-eventos", "misiones", "misiones", "evento" },
	}
	for _, t in tabsList do
		add(t[1], t[1], function(c)
			demo(c, "operacion")
			go(c, t[2])
			tab(c, t[3], t[4])
		end)
	end
	add("estadisticas-op-30", "Estadísticas a 30 días", function(c)
		demo(c, "operacion")
		go(c, "estadisticas")
		c.App.ui.statRange = 30
		c.App.forceRender()
	end)

	-- Editor
	local function editorStep(c: any, step: number)
		fresh(c)
		go(c, "editor", { new = true, force = true })
		local e = c.App.ui.editor
		if e then
			e.step = step
			e.sel = nil
		end
		c.App.forceRender()
		return e
	end
	add("editor-paso1", "Editor paso 1", function(c)
		editorStep(c, 1)
	end)
	add("editor-paso2", "Editor paso 2", function(c)
		editorStep(c, 2)
	end)
	add("editor-paso2-pieza", "Editor paso 2 con pieza elegida", function(c)
		local e = editorStep(c, 2)
		if e then
			e.cat = "frenos"
			e.sel = "deportivos"
		end
		c.App.forceRender()
	end)
	add("editor-paso3", "Editor paso 3", function(c)
		editorStep(c, 3)
	end)
	add("editor-paso3-interior", "Editor paso 3 interior", function(c)
		local e = editorStep(c, 3)
		if e then
			e.tab = "int"
		end
		c.App.forceRender()
	end)
	add("editor-paso4", "Editor paso 4", function(c)
		editorStep(c, 4)
	end)
	add("editor-comparar", "Editor: antes y después", function(c)
		editorStep(c, 3)
		c.App.screens.editor.change(function(d)
			d.paint.primary = "#D6333F"
		end)
		c.App.ui.editor.compare = true
		c.App.forceRender()
	end)
	add("editor-oculto", "Editor con la interfaz oculta", function(c)
		editorStep(c, 1)
		c.App.ui.editor.hideUI = true
		c.App.forceRender()
	end)
	add("editor-modelos", "Editor: modelos anteriores", function(c)
		demo(c, "operacion")
		go(c, "editor", { new = true, force = true })
		c.App.openDialog("prevModels", { wide = true })
	end)
	add("editor-salir", "Editor: salir con cambios", function(c)
		editorStep(c, 1)
		c.App.screens.editor.change(function(d)
			d.name = "Prueba sin guardar"
		end)
		c.App.go("juego")
	end)

	-- Diálogos
	local function dlg(name: string, title: string, setup: (any) -> ())
		add(name, title, setup)
	end
	dlg("dlg-configuracion", "Configuración", function(c)
		demo(c, "operacion")
		go(c, "juego")
		c.App.openDialog("settings", { wide = true })
	end)
	dlg("dlg-notificaciones", "Notificaciones", function(c)
		demo(c, "operacion")
		go(c, "juego")
		c.App.openDialog("notifications", {})
	end)
	dlg("dlg-ayuda", "Ayuda de Fábrica", function(c)
		demo(c, "operacion")
		go(c, "fabrica")
		c.App.openDialog("help", { screen = "fabrica" })
	end)
	dlg("dlg-diaria", "Recompensa diaria", function(c)
		demo(c, "operacion")
		go(c, "juego")
		c.App.openDialog("daily", {})
	end)
	dlg("dlg-orden", "Nueva orden", function(c)
		demo(c, "operacion")
		go(c, "fabrica")
		c.App.ui.orderDraft = nil
		c.App.openDialog("order", { wide = true })
	end)
	dlg("dlg-negociar", "Negociación", function(c)
		demo(c, "operacion")
		go(c, "ventas")
		local g = c.App.g
		local cust = nil
		for _ = 1, 200 do
			for _, x in c.App.g.customers do
				if x.state == "oferta" then
					cust = x
				end
			end
			if cust then
				break
			end
			c.M.step(1)
			c.M.task.wait()
		end
		g = c.App.g
		if cust then
			c.App.openDialog("counter", { customerId = cust.id, wide = true })
			c.waitFor(function()
				return c.App.ui.counterDraft and c.App.ui.counterDraft.quote ~= nil
			end)
		end
		local _ = g
	end)
	dlg("dlg-unidad", "Detalle de unidad", function(c)
		demo(c, "operacion")
		go(c, "autos")
		for _, u in c.App.g.units do
			if u.status ~= "vendido" then
				c.App.openDialog("unitDetail", { unitId = u.id, wide = true })
				break
			end
		end
	end)
	dlg("dlg-mayorista", "Vender al mayorista", function(c)
		demo(c, "operacion")
		go(c, "autos")
		for _, u in c.App.g.units do
			if u.status == "almacen" or u.status == "salon" then
				c.App.openDialog("wholesale", { unitId = u.id })
				break
			end
		end
	end)
	dlg("dlg-publicacion", "Publicación del mercado", function(c)
		demo(c, "operacion")
		go(c, "mercado")
		for _, l in c.App.g.market.listings do
			if l.kind == "vehiculo" then
				c.App.openDialog("listing", { listingId = l.id, wide = true })
				break
			end
		end
	end)
	dlg("dlg-publicar", "Publicar en el mercado", function(c)
		demo(c, "operacion")
		go(c, "mercado")
		c.App.openDialog("publish", {})
	end)
	dlg("dlg-prueba", "Prueba en pista", function(c)
		editorStep(c, 4)
		c.App.openDialog("testDrive", {})
	end)
	dlg("dlg-novedades", "Novedades", function(c)
		reset(c)
		c.App.request("leaveCompany")
		c.waitFor(function()
			return c.App.g == nil
		end)
		go(c, "menu")
		c.App.openDialog("news", {})
	end)
	dlg("dlg-tienda", "Tienda", function(c)
		demo(c, "operacion")
		go(c, "juego")
		c.App.openDialog("future", { what = "tienda" })
	end)
	dlg("dlg-amigos", "Amigos", function(c)
		demo(c, "operacion")
		go(c, "juego")
		c.App.openDialog("future", { what = "amigos" })
	end)
	dlg("dlg-evento", "Evento", function(c)
		demo(c, "operacion")
		go(c, "juego")
		c.App.openDialog("future", { what = "eventos" })
	end)
	dlg("dlg-saltar-tutorial", "Saltar tutorial", function(c)
		fresh(c)
		go(c, "juego")
		local b = named(c.App, c.M, "SaltarTutorial")
		if b then
			c.M.click(b)
		end
	end)
	dlg("dlg-cancelar-orden", "Cancelar orden", function(c)
		demo(c, "operacion")
		go(c, "fabrica")
		local b = nil
		for _, d in c.App.gui:GetDescendants() do
			if d.Name == "CancelarOrden" or (d:GetAttribute("label") == "Cancelar" and string.find(d:GetFullName(), "Contenido", 1, true)) then
				b = d
				break
			end
		end
		if b then
			c.M.click(b)
		end
	end)
	dlg("dlg-comprar-material", "Comprar material", function(c)
		demo(c, "operacion")
		go(c, "fabrica")
		local b = named(c.App, c.M, "Comprar_acero")
		if b then
			c.M.click(b)
		end
	end)
	dlg("dlg-ampliar", "Ampliar sede", function(c)
		demo(c, "operacion")
		go(c, "compania")
		local b = named(c.App, c.M, "AmpliarSede")
		if b then
			c.M.click(b)
		end
	end)
	return list
end

return Scenes
