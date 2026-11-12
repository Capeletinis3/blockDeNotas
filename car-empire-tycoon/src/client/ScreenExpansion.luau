--!strict
--[[ Compañía › Expansión internacional: mapa mundial interactivo (WorldMap) con los diez países del catálogo,
	resumen de presencia arriba y panel del país elegido a la derecha (debajo en celular).

	Todos los números salen de las reglas reales (Rules): costo de la próxima apertura (depende de cuántos países
	abriste, no de cuál), requisitos con su progreso (oficinas de nivel 5, autos vendidos y dinero), demanda que
	aporta el país este año repartida por tipo según sus preferencias (Rules.countryDemand: el mismo +15 % de la
	demanda mundial base, repartido) y capacidad de las líneas con un país más. No hay ventas ni ingresos por país:
	la simulación vende por tipo a escala mundial.

	La apertura la valida y cobra el servidor (Actions.expandGlobal) después de confirmar. Elegir otro país solo
	reconstruye el panel (no la pantalla). La vista del mapa (zoom, centro) y el país elegido se guardan en
	App.ui (no en la partida). La pantalla es un menú de gestión: mientras está abierta, la empresa queda en pausa. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)
local DesignCalc = require(Shared.DesignCalc)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local WorldMap = require(script.Parent.WorldMap)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Expansión internacional",
	icon = "globe",
	color = Color3.fromHex("#8DB8FF"),
	bg = Color3.fromHex("#0D2A52"),
	custom = true,
}

local E = Catalog.EXPANSION
local STATE_CHIP = { disponible = { "Disponible", "cb" }, bloqueado = { "Bloqueado", "cn" }, abierto = { "Abierto", "cg" } }
Screen.ALL_OPEN = "Presencia en los diez mercados internacionales disponibles."

-- Estados de los diez marcadores (para el mapa y las pruebas).
function Screen.states(g: any): { [string]: string }
	local out = {}
	for _, c in E.countries do
		out[c.id] = Rules.countryState(g, c.id)
	end
	return out
end

-- Tipos de vehículo que la empresa ya puede fabricar (alguna base disponible).
local function buildable(g: any): { [string]: boolean }
	local out = {}
	for _, b in Catalog.BASES do
		if DesignCalc.baseAvailable(g, b) == nil then
			out[b.type] = true
		end
	end
	return out
end

-- Barra horizontal con etiqueta y valor.
local function hbar(label: string, frac: number, value: string, color: Color3, name: string?): Frame
	local bar = Ui.bar(math.clamp(frac, 0, 1) * 100, color, 6)
	return Ui.col({
		Ui.row({ Ui.grow(Ui.inline(label, { size = Ui.S.xs, color = T.tx2 })), Ui.inline(value, { size = Ui.S.xs, weight = W.semi }) }, 6),
		bar,
	}, 3, { Name = name or "Barra" })
end

-- Preferencias del país: importancia relativa de cada tipo (parámetros del juego) y demanda que aporta.
function Screen.preferenceRows(country: any, yf: number): { any }
	local contrib = Rules.countryDemand(country, yf)
	local maxP, maxC = 0, 0
	for _, t in Catalog.TYPE_ORDER do
		maxP = math.max(maxP, country.prefs and country.prefs[t] or 1)
		maxC = math.max(maxC, contrib[t] or 0)
	end
	local rows = {}
	for _, t in Catalog.TYPE_ORDER do
		local p = country.prefs and country.prefs[t] or 1
		table.insert(rows, { type = t, pref = p, rel = maxP > 0 and p / maxP or 0, demand = contrib[t] or 0, relDemand = maxC > 0 and (contrib[t] or 0) / maxC or 0 })
	end
	return rows
end

-- Panel del país elegido.
function Screen.panel(g: any, id: string): Frame
	local c = Rules.country(id)
	local st = Rules.countryState(g, id)
	local chip = STATE_CHIP[st]
	local yf = Rules.yearFrac(g)
	local q = Rules.expansionQuote(g)
	local rows: { Instance? } = {
		Ui.row({ Ui.grow(Ui.text(c.name, { size = Ui.S.h2, weight = W.bold, name = "NombrePais" })), Ui.chip(chip[1], chip[2], { name = "EstadoPais" }) }, 8, { v = "C" }),
	}
	local _, total = Rules.countryDemand(c, yf)
	local _, worldNow = Rules.worldDemand(g, yf)
	local n = Rules.expansion(g)
	local perLine = Rules.lineRate(g)
	if st == "abierto" then
		local order = table.find(Rules.openedCountries(g), id) or 0
		table.insert(rows, Ui.card({
			Ui.lbl("Presencia comercial", T.gr),
			Ui.between("Apertura", "país n.º " .. order .. " de " .. #E.countries),
			Ui.between("Demanda incorporada este año", Util.num(total, 1) .. " autos/min", { name = "DemandaAportada" }),
			Ui.between("Peso en la demanda mundial", Util.num(worldNow > 0 and total / worldNow * 100 or 0, 1) .. " %"),
			Ui.between("Capacidad que suma a cada línea", "+" .. Util.round(E.line * 100) .. " %"),
			Ui.text("Esa demanda se reparte con las mismas reglas entre tus modelos, los rivales y el resto del mercado; las ventas se cuentan por tipo a escala mundial (no hay ventas por país).", { size = Ui.S.xs, color = T.mut, lineHeight = 1.35 }),
		}, { gap = 6, bg = T.p1, name = "PresenciaComercial" }))
	else
		local reqs = Rules.expansionRequirements(g)
		local req: { Instance? } = { Ui.lbl("Requisitos") }
		for _, r in reqs do
			table.insert(req, Ui.row({
				Ui.inline(r.ok and "✓" or "✕", { size = Ui.S.sm, weight = W.bold, color = r.ok and T.gr or T.re2 }),
				Ui.grow(Ui.text(r.text, { size = Ui.S.sm, color = r.ok and T.tx2 or T.re2 })),
			}, 8, { Name = r.ok and "Requisito" or "RequisitoPendiente" }))
			if not r.ok and r.kind == "ventas" then
				table.insert(req, (Ui.bar(r.cur / math.max(1, r.need) * 100, T.ye, 6)))
			end
		end
		table.insert(rows, Ui.grid({
			(Ui.kv("Costo de apertura", q and Util.money(q.cost) or "—", { name = "CostoApertura", sub = q and ("apertura n.º " .. q.level .. ": el mismo para cualquier país") or nil })),
			(Ui.kv("Autos vendidos requeridos", q and Util.num(q.sold) or "—", { name = "VentasRequeridas" })),
		}, 2, nil, 8))
		table.insert(rows, Ui.card(req, { gap = 6, bg = T.p1, name = "Requisitos" }))
		local after = perLine * (1 + E.line * (n + 1)) / (1 + E.line * n)
		table.insert(rows, Ui.card({
			Ui.lbl("Al abrir", T.gr),
			Ui.between("Demanda mundial", "×" .. Util.num(Rules.marketFactor(g), 2) .. " → ×" .. Util.num(1 + E.demand * (n + 1), 2), { name = "ImpactoDemanda" }),
			Ui.between("Demanda potencial este año", "+" .. Util.num(total, 1) .. " autos/min", { name = "DemandaPotencial" }),
			Ui.between("Autos por minuto por línea", Util.num(perLine, 1) .. " → " .. Util.num(after, 1), { name = "ImpactoProduccion" }),
			Ui.text("Se reparte entre los tipos según las preferencias de " .. c.name .. " (abajo) y compite con los rivales como cualquier demanda. Las campañas corporativas cuestan más con cada país.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.35 }),
		}, { gap = 6, bg = T.p1, name = "BeneficiosApertura" }))
	end
	-- Preferencias y demanda por tipo (con lo que la empresa ya puede fabricar).
	local can = buildable(g)
	local kindText = st == "abierto" and "Cifras por tipo: demanda incorporada este año." or "Cifras por tipo: demanda potencial este año (todavía no abriste este país)."
	local prefs: { Instance? } = { Ui.lbl("Preferencias del mercado"), Ui.text("Parámetros del juego (ficticios): reparten la demanda que aporta el país entre los tipos, sin sumar volumen. " .. kindText, { size = Ui.S.xs, color = T.mut, name = "TipoDemandaPais" }) }
	for _, r in Screen.preferenceRows(c, yf) do
		local label = Catalog.TYPES[r.type] .. (can[r.type] and "" or " · todavía no lo fabricás")
		table.insert(prefs, hbar(label, r.rel, "×" .. Util.num(r.pref, 1) .. " · " .. Util.num(r.demand, 1) .. "/min", r.demand > 0 and T.bl or T.mut, "Pref_" .. r.type))
	end
	table.insert(rows, Ui.card(prefs, { gap = 6, bg = T.p1, name = "Preferencias" }))
	-- Acción.
	if st ~= "abierto" then
		local pending = 0
		for _, r in Rules.expansionRequirements(g) do
			if not r.ok then
				pending += 1
			end
		end
		table.insert(rows, Ui.button("Expandirme a " .. c.name .. (q and (" · " .. Util.money(q.cost)) or ""), "p", function()
			Screen.confirm(g, id)
		end, { fill = true, icon = "globe", name = "Expandirse_" .. id, disabled = st ~= "disponible" or g.demo ~= nil, why = g.demo and "No disponible en demostraciones" or (pending == 1 and "Falta 1 requisito" or ("Faltan " .. pending .. " requisitos")) }))
	end
	return Ui.card(rows, { gap = 10, pad = 16, name = "PanelPais" })
end

-- Confirmación explícita de la inversión (el servidor vuelve a validar y calcula el costo).
function Screen.confirm(g: any, id: string)
	local c = Rules.country(id)
	local q = Rules.expansionQuote(g)
	if not q then
		return
	end
	local _, total = Rules.countryDemand(c, Rules.yearFrac(g))
	App.openDialog("confirm", {
		title = "¿Expandirte a " .. c.name .. "?",
		body = "Cuesta " .. Util.money(q.cost) .. " (no se devuelve). La demanda mundial pasa a ×" .. Util.num(1 + E.demand * q.level, 2) .. " (+" .. Util.num(total, 1) .. " autos/min este año, repartidos según las preferencias de " .. c.name .. ") y cada línea fabrica " .. Util.round(E.line * 100) .. " % más. Las campañas corporativas cuestan más.",
		okLabel = "Expandirme",
		onOk = function()
			App.ui.expCelebrate = nil
			local r = App.request("expandGlobal", { country = id })
			if r and r.ok then
				-- Aviso de un solo uso: lo muestra el primero que pueda (esta respuesta, si el estado nuevo ya
				-- llegó y la pantalla ya muestra el país abierto, o la reconstrucción cuando llegue).
				App.ui.expCelebrate = { id = id, at = os.clock() }
				Screen.celebrate()
			end
			-- Rechazada o sin respuesta: no hay aviso.
		end,
	})
end

-- Resumen de presencia mundial (arriba).
function Screen.summary(g: any): { any }
	local n = Rules.expansion(g)
	local base, total = Rules.worldDemand(g)
	local q = Rules.expansionQuote(g)
	local out = {
		{ "Países abiertos", n .. " de " .. #E.countries },
		{ "Demanda mundial", Util.num(total, 1) .. " autos/min" },
		{ "Aporte de la expansión", "+" .. Util.num(total - base, 1) .. " autos/min (×" .. Util.num(Rules.marketFactor(g), 2) .. ")" },
		{ "Capacidad extra por línea", "+" .. Util.round(E.line * n * 100) .. " %" },
	}
	if q then
		table.insert(out, { "Próxima apertura", Util.money(q.cost) })
		table.insert(out, { "Ventas para la próxima", Util.num(g.counters.unitsSold) .. " / " .. Util.num(q.sold) })
	end
	return out
end

local function topStrip(g: any): Frame
	local items: { Instance? } = {}
	for _, r in Screen.summary(g) do
		table.insert(items, Ui.col({ Ui.inline(r[1], { size = Ui.S.xs, color = T.mut }), Ui.inline(r[2], { size = Ui.S.sm, weight = W.bold }) }, 2, { Name = "Dato" }))
	end
	if Rules.expansion(g) >= #E.countries then
		table.insert(items, Ui.chip(Screen.ALL_OPEN, "cg", { name = "TodosAbiertos" }))
	elseif Rules.nextSede(g) ~= nil then
		table.insert(items, Ui.chip("Se abre con las oficinas centrales de nivel " .. #Catalog.SEDES, "cy", { name = "FaltaOficinas" }))
	end
	return Ui.row(items, 18, { Name = "ResumenMundial", wrap = true })
end

--[[ Aviso breve al abrir un país (no bloquea: se cierra solo). Exactamente una vez por apertura:
	- el pedido aceptado deja un aviso pendiente (App.ui.expCelebrate) y llama a Screen.celebrate();
	- la pantalla, al armarse, también llama a Screen.celebrate();
	- se muestra solo cuando la partida ya tiene el país abierto (el estado del servidor llegó) y la pantalla
	  está a la vista, y en ese momento el aviso se consume. Si el estado llegó antes que la respuesta, lo
	  muestra la respuesta sobre la pantalla actual; si llega después, la reconstrucción. Nunca los dos.
	- un pedido rechazado no deja aviso. ]]
Screen.CELEBRATE_TTL = 20 -- segundos que el aviso pendiente espera el estado nuevo
Screen.celebrations = 0 -- avisos mostrados (para las pruebas)
function Screen.celebrate(): boolean
	local cel = App.ui.expCelebrate
	local cur = Screen.current
	if not cel then
		return false
	end
	if os.clock() - cel.at > Screen.CELEBRATE_TTL then
		App.ui.expCelebrate = nil
		return false
	end
	local g = App.g
	if not g or not Rules.countryOpen(g, cel.id) or not cur or not cur.box.Parent or not cur.map.frame.Parent then
		return false
	end
	App.ui.expCelebrate = nil
	Screen.celebrations += 1
	local c = Rules.country(cel.id)
	local _, total = Rules.countryDemand(c, Rules.yearFrac(g))
	local banner = Ui.card({
		Ui.text("¡Nueva expansión internacional!", { size = Ui.S.h2, weight = W.bold, color = T.gr }),
		Ui.text("Tu compañía llegó a " .. c.name .. ".", { size = Ui.S.base, weight = W.semi }),
		Ui.text("Nuevo mercado disponible · +" .. Util.num(total, 1) .. " autos/min de demanda incorporada este año · +" .. Util.round(E.line * 100) .. " % de producción por línea · " .. Rules.expansion(g) .. " de " .. #E.countries .. " países abiertos", { size = Ui.S.xs, color = T.tx2, lineHeight = 1.35 }),
	}, { gap = 4, pad = 14, name = "NuevaExpansion", bg = Color3.fromHex("#0B1220"), stroke = { T.gr, 2 } })
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, 14)
	banner.Size = UDim2.fromOffset(420, 0)
	banner.AutomaticSize = Enum.AutomaticSize.Y
	banner.ZIndex = 30
	banner.Parent = cur.box
	if not Ui.reduceMotion then
		Ui.fadeIn(banner)
	end
	cur.map.setStates(Screen.states(g))
	cur.map.flash(cel.id)
	task.delay(6, function()
		if banner.Parent then
			banner:Destroy()
		end
	end)
	return true
end

function Screen.build(holder: Instance)
	local g = App.g
	local phone = App.isPhone()
	App.ui.expMap = App.ui.expMap or WorldMap.defaultView()
	-- La selección es por empresa: al cambiar de empresa no se arrastra la del mapa anterior.
	if App.ui.expCompany ~= (App.profile and App.profile.active) then
		App.ui.expCompany = App.profile and App.profile.active
		App.ui.expSel = nil
		App.ui.expMap = WorldMap.defaultView()
		App.ui.expCelebrate = nil
	end
	if not Rules.country(App.ui.expSel) then
		local first = nil
		for _, c in E.countries do
			first = first or (Rules.countryState(g, c.id) ~= "abierto" and c.id or nil)
		end
		App.ui.expSel = first or E.countries[1].id
	end
	local panelHolder: Frame
	local function showPanel(id: string)
		App.ui.expSel = id
		panelHolder:ClearAllChildren()
		local pl = Ui.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder })
		pl.Parent = panelHolder
		Screen.panel(g, id).Parent = panelHolder
	end
	local brand = Color3.fromHex(g.company.color or "#3B8BFF")
	local mapBox, mapCtl
	if phone then
		local scroll = Ui.scroll({}, { name = "Principal", gap = 12, pad = 12 })
		scroll.Parent = holder
		App.keepScroll(scroll, "expansion")
		topStrip(g).Parent = scroll
		mapBox = Ui.new("Frame", { Name = "ZonaMapa", Size = UDim2.new(1, 0, 0, 230), BackgroundTransparency = 1, Parent = scroll })
		panelHolder = Ui.new("Frame", { Name = "ZonaPanel", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = scroll })
	else
		local top = topStrip(g)
		top.Position = UDim2.fromOffset(18, 12)
		top.Size = UDim2.new(1, -36, 0, 0)
		top.AutomaticSize = Enum.AutomaticSize.Y
		top.Parent = holder
		local topH = 76
		local sideW = App.layout == "tablet" and 320 or 380
		mapBox = Ui.new("Frame", { Name = "ZonaMapa", Position = UDim2.fromOffset(18, topH), Size = UDim2.new(1, -(sideW + 18 + 16 + 18), 1, -(topH + 16)), BackgroundTransparency = 1, Parent = holder })
		local side = Ui.scroll({}, { name = "Lateral", Position = UDim2.new(1, -(sideW + 18), 0, topH), Size = UDim2.new(0, sideW, 1, -(topH + 16)), gap = 12, pad = { 0, 4, 2, 0 } })
		side.AutomaticSize = Enum.AutomaticSize.None
		side.Parent = holder
		App.keepScroll(side, "expansion:side")
		panelHolder = Ui.new("Frame", { Name = "ZonaPanel", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = side })
	end
	mapCtl = WorldMap.build(mapBox, {
		countries = E.countries,
		states = Screen.states(g),
		brand = brand,
		selected = App.ui.expSel,
		view = App.ui.expMap,
		onSelect = function(id: string)
			showPanel(id)
		end,
	})
	Screen.map = mapCtl
	Screen.current = { map = mapCtl, box = mapBox }
	showPanel(App.ui.expSel)
	Screen.celebrate()
	if not Ui.reduceMotion then
		Ui.fadeIn(mapCtl.frame)
	end
end

return Screen
