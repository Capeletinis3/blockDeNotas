--!strict
--[[
	Centro de investigación (I+D).
	- Arriba: PI disponibles, generación por minuto y una franja compacta (con desplazamiento horizontal) con
	  TODAS las investigaciones en curso de la empresa, de cualquier categoría.
	- Izquierda: menú fijo con las cuatro categorías (Chasis, Motores, Seguridad, Tecnología).
	- Centro: filtros (Todas, Disponibles, En curso, Bloqueadas, Completadas) y tarjetas en filas de tres con
	  ilustración, nombre, nivel o generación, descripción, beneficios, costos (dinero, PI y días), año,
	  requisitos, estado y acción. Se ve el catálogo completo, también lo futuro y bloqueado.
	«Investigar» abre una confirmación (Dialogs.research) y recién al confirmar el servidor valida y cobra
	(Actions.startResearch). Todos los números salen de Rules.researchCost, los mismos que cobra el servidor.
	La pantalla es un menú de gestión: mientras está abierta, la empresa del jugador queda en pausa.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Centro de investigación",
	icon = "flask",
	color = Color3.fromHex("#6FE3F0"),
	bg = Color3.fromHex("#12303A"),
	custom = true, -- menú lateral fijo y catálogo desplazable (ScreenSheet)
}

local STYLE = {
	panel = Ui.hex("#0B1220"),
	card = Ui.hex("#111A2B"),
	line = Ui.hex("#22304A"),
	accent = Ui.hex("#3B8BFF"),
	accent2 = Ui.hex("#8DB8FF"),
}

-- Categorías del menú lateral: { clave del catálogo, nombre, ícono }.
Screen.CATEGORIES = {
	{ "chasis", "Chasis", "car" },
	{ "motores", "Motores", "gear" },
	{ "seguridad", "Seguridad", "check" },
	{ "tecnologia", "Tecnología", "gem" },
}
local CATEGORY_DESC = {
	chasis = "Plataformas y generaciones de chasis, estructura y materiales. Las generaciones nuevas se suman: las anteriores siguen en el editor.",
	motores = "Familias de motores con 10 niveles, variantes económica y deportiva, transmisiones y tecnología del motor. Los niveles anteriores siguen disponibles.",
	seguridad = "Cada tecnología se investiga una vez y después se elige al diseñar: no se instala sola en los autos.",
	tecnologia = "Equipamiento y confort: se investiga una vez y se agrega a mano en cada diseño nuevo.",
}

--[[ Ilustraciones: por ahora un ícono de la categoría. Para usar imágenes definitivas, cargar el id de la
	imagen por tecnología (IMAGES[id]) o por categoría (IMAGES[categoría]): la tarjeta la muestra sola. ]]
Screen.IMAGES = {} :: { [string]: string }

Screen.FILTERS = {
	{ "todas", "Todas" },
	{ "disponibles", "Disponibles" },
	{ "curso", "En curso" },
	{ "bloqueadas", "Bloqueadas" },
	{ "completadas", "Completadas" },
}

-- Estado de cada tarjeta: { texto, chip }
local STATE_CHIP = {
	disponible = { "Disponible", "cb" },
	curso = { "En curso", "cv" },
	bloqueada = { "Bloqueada", "cn" },
	completada = { "✓ Completada", "cg" },
	incluida = { "✓ Incluida desde el inicio", "cg" },
}

local function piRate(g: any): number
	return g.derived and g.derived.piPerMinute or Rules.piPerMinute(g)
end

-- Sin chips en el encabezado: los PI y las investigaciones en curso están en la zona superior de la pantalla.

-- Nivel o generación que se muestra en la tarjeta.
function Screen.levelLabel(n: any): string
	if n.level then
		return "Nivel " .. n.level
	end
	for _, b in Catalog.BASES do
		if b.research == n.id and b.gen then
			return "Generación " .. b.gen
		end
	end
	return Catalog.RESEARCH_RULES.complexityLabel[n.complexity] or "Mejora"
end

-- Categoría de la tarjeta (Chasis, Motores, Seguridad o Tecnología).
function Screen.categoryLabel(n: any, cat: string): string
	for _, c in Screen.CATEGORIES do
		if c[1] == (n.category or cat) then
			return c[2]
		end
	end
	return tostring(cat)
end

--[[ Qué hace la tecnología al completarse: un efecto automático (se aplica solo a lo que se fabrique), opciones
	que se eligen en el editor en cada diseño, o las dos cosas. Lo de serie ya está en el editor. ]]
local EFFECT_LABEL = {
	auto = "Efecto automático",
	editor = "Se elige en el editor",
	ambos = "Efecto automático + opción del editor",
}
function Screen.effectLabel(n: any): string
	if n.builtin then
		return "De serie en el editor"
	end
	return EFFECT_LABEL[Catalog.researchEffectKind(n)]
end

--[[ Lo que la empresa tiene desde la fundación (no se investiga): Sedán y Coupé de 1970, motores I4 e I6 de
	nivel 1 y la variante Equilibrada. Se muestran como tarjetas completadas para que el catálogo esté entero. ]]
function Screen.builtins(cat: string): { any }
	local out = {}
	if cat == "chasis" then
		for _, b in Catalog.BASES do
			if b.research == nil and (b.year or 1970) <= Catalog.CALENDAR.startYear then
				table.insert(out, { id = "inicio_" .. b.id, builtin = true, name = b.name, year = b.year or 1970, gen = b.gen or 1, gain = "Chasis disponible desde la fundación: " .. (Catalog.TYPES[b.type] or b.type) .. ", " .. b.weight .. " kg, seguridad " .. (b.safety or 40) .. ".", desc = "Generación " .. (b.gen or 1) .. " de la familia " .. tostring(b.family or b.type) .. "." })
			end
		end
	elseif cat == "motores" then
		for _, f in Catalog.ENGINE_FAMILIES do
			if not f.req and f.first <= Catalog.CALENDAR.startYear then
				table.insert(out, { id = "inicio_motor_" .. f.id, builtin = true, name = f.name .. " · nivel 1", year = f.first, level = 1, family = f.id, gain = "Motor disponible desde la fundación. Los niveles 2 a " .. Catalog.RESEARCH_RULES.engineMaxLevel .. " se investigan.", desc = "Familia " .. f.name .. "." })
			end
		end
		local v = Catalog.ENGINE_VARIANTS[1]
		table.insert(out, { id = "inicio_variante_" .. v.id, builtin = true, name = "Variante " .. v.name, year = Catalog.CALENDAR.startYear, gain = "Disponible desde la fundación para todos los motores.", desc = "La variante de serie de cada motor." })
	end
	return out
end

--[[ Estado de una tecnología para la interfaz: "disponible", "curso", "bloqueada", "completada" o "incluida",
	más el adelanto (años antes de su año normal). «Adelantada» es una marca aparte: una tecnología puede estar
	disponible y adelantada, o bloqueada y adelantada (por ejemplo, si le faltan requisitos), sin contradecirse.
	Devuelve (estado, motivo de bloqueo o nil, años de adelanto). ]]
function Screen.status(g: any, n: any): (string, string?, number)
	if n.builtin then
		return "incluida", nil, 0
	end
	local st = Rules.researchState(g, n)
	if st == "hecha" then
		return "completada", nil, 0
	elseif st == "activa" then
		return "curso", nil, 0
	end
	local ahead = Rules.researchAhead(g, n)
	local miss = Rules.researchMissing(g, n)
	if #miss > 0 then
		return "bloqueada", table.concat(miss, " · "), ahead
	end
	return "disponible", nil, ahead
end

-- Por qué no se puede empezar ahora (recursos o cupo), o nil. Los requisitos van en Screen.status.
function Screen.blockReason(g: any, n: any): string?
	local st, why = Screen.status(g, n)
	if st == "completada" or st == "incluida" then
		return "Ya investigada"
	elseif st == "curso" then
		return "En curso"
	elseif st == "bloqueada" then
		return why
	end
	if #(g.research.projects or {}) >= Catalog.RESEARCH_RULES.maxParallel then
		return "Máximo de " .. Catalog.RESEARCH_RULES.maxParallel .. " investigaciones en curso"
	end
	local pi, cost = Rules.researchCost(g, n)
	if g.rp < pi then
		return "Faltan " .. Util.num(math.ceil(pi - g.rp)) .. " PI"
	end
	if g.money < cost then
		return "Fondos insuficientes (" .. Util.money(cost) .. ")"
	end
	return nil
end

local function matches(filter: string, st: string): boolean
	return filter == "todas"
		or (filter == "disponibles" and st == "disponible")
		or (filter == "curso" and st == "curso")
		or (filter == "bloqueadas" and st == "bloqueada")
		or (filter == "completadas" and (st == "completada" or st == "incluida"))
end
Screen.matches = matches

-- Días que faltan a un proyecto (con la velocidad del personal de Investigación).
function Screen.daysLeft(g: any, p: any): number
	return math.max(0, p.days - p.progress) / Rules.researchSpeed(g)
end

local function daysText(d: number): string
	local n = math.max(0, math.ceil(d))
	return Util.num(n) .. (n == 1 and " día" or " días")
end

-- Ilustración de la tarjeta: imagen definitiva si existe; si no, el ícono de la categoría.
local function illustration(n: any, cat: string, st: string): GuiObject
	local img = Screen.IMAGES[n.id] or Screen.IMAGES[cat]
	if img then
		return Ui.new("ImageLabel", { Name = "Ilustracion", Image = img, ScaleType = Enum.ScaleType.Fit, BackgroundColor3 = Ui.hex("#16223A"), BackgroundTransparency = 0, Size = UDim2.new(1, 0, 0, 48), Corner = 8 })
	end
	local icon = "flask"
	for _, c in Screen.CATEGORIES do
		if c[1] == cat then
			icon = c[3]
		end
	end
	local done = st == "completada" or st == "incluida"
	local color = (st == "bloqueada" and T.mut2) or (done and T.gr) or STYLE.accent2
	local box = Ui.new("Frame", { Name = "Ilustracion", BackgroundColor3 = Ui.hex("#16223A"), BackgroundTransparency = 0, Size = UDim2.new(1, 0, 0, 48), Corner = 8 })
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(150, 160, 185))
	g.Rotation = 90
	g.Parent = box
	local ic = Ui.icon(st == "bloqueada" and "lock" or icon, 22, color)
	ic.AnchorPoint = Vector2.new(0.5, 0.5)
	ic.Position = UDim2.fromScale(0.5, 0.5)
	ic.Parent = box
	return box
end

function Screen.card(g: any, n: any, cat: string): Frame
	local st, why, ahead = Screen.status(g, n)
	local chip = STATE_CHIP[st]
	local items: { Instance? } = {
		illustration(n, cat, st),
		Ui.row({
			Ui.chip(n.builtin and (n.level and ("Nivel " .. n.level) or (n.gen and ("Generación " .. n.gen)) or "De serie") or Screen.levelLabel(n), "cn"),
			Ui.chip(chip[1], chip[2]),
			(ahead > 0 and st ~= "completada") and Ui.chip(ahead > Catalog.RESEARCH_RULES.aheadMaxYears and "Futura" or ("Adelantada " .. ahead .. (ahead == 1 and " año" or " años")), "cy") or nil,
		}, 4, { wrap = true }),
		Ui.text(n.name, { size = 16, weight = W.bold, name = "Nombre" }),
		Ui.text(Screen.categoryLabel(n, cat) .. " · " .. Screen.effectLabel(n), { size = Ui.S.xs, color = STYLE.accent2, weight = W.semi, name = "Tipo" }),
		Ui.text(n.desc or ((Catalog.RESEARCH[cat] and Catalog.RESEARCH[cat].label or "") .. " · aparece en " .. tostring(n.year)), { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }),
		-- Beneficio destacado (es lo que se compra): etiqueta verde y texto claro.
		Ui.col({
			Ui.lbl("Beneficio", T.gr, 11),
			Ui.text(tostring(n.gain), { size = Ui.S.sm, color = T.tx, weight = W.semi, lineHeight = 1.3 }),
		}, 2, { Name = "Beneficio" }),
	}
	if not n.builtin then
		local RR = Catalog.RESEARCH_RULES
		local pi, cost, days, info = Rules.researchCost(g, n)
		local future = ahead > RR.aheadMaxYears
		local costNote = nil
		local project = st == "curso" and Rules.researchProject(g, n.id) or nil
		if project then
			-- En curso: lo que se pagó al empezar (no cambia con el calendario ni con la difusión).
			pi, cost, days = project.paidPi or pi, project.paidMoney or cost, project.days or days
			costNote = "Pagado al empezar"
		elseif future then
			-- Todavía no se puede adelantar: costo base (el recargo se calcula el año en que se empiece).
			pi, cost, days = info.base.pi, info.base.money, info.base.days
			costNote = "Costo base, sin recargo"
		end
		if st ~= "completada" then
			-- Costos en píldoras: dinero, PI y días, cada uno con su color.
			table.insert(items, Ui.row({
				Ui.chip(Util.money(cost), "co", { height = 22 }),
				Ui.chip(Util.num(pi) .. " PI", "cb", { height = 22 }),
				Ui.chip(daysText(days), "cn", { height = 22 }),
				costNote and Ui.inline(costNote, { size = Ui.S.xs, color = T.mut, name = "NotaCosto" }) or nil,
			}, 4, { wrap = true, Name = "Costo" }))
		end
		local late = ahead > 0 and st ~= "completada" and not project
		local yearText = "Año " .. n.year
		if late and future then
			yearText ..= " · se puede adelantar desde " .. (n.year - RR.aheadMaxYears) .. " (recargo de hasta +" .. Util.round(RR.aheadMoney * RR.aheadMaxYears * 100) .. " % dinero, +" .. Util.round(RR.aheadPi * RR.aheadMaxYears * 100) .. " % PI, +" .. Util.round(RR.aheadDays * RR.aheadMaxYears * 100) .. " % días)"
		elseif late then
			yearText ..= " · recargo +" .. Util.round(info.penalty.money * 100) .. " % dinero, +" .. Util.round(info.penalty.pi * 100) .. " % PI, +" .. Util.round(info.penalty.days * 100) .. " % días"
		elseif project and (project.ahead or 0) > 0 then
			yearText ..= " · adelantada " .. project.ahead .. (project.ahead == 1 and " año" or " años") .. " (recargo ya pagado)"
		end
		table.insert(items, Ui.text(yearText, { size = Ui.S.xs, color = late and T.ye or T.mut, name = "Anio" }))
		if #n.req > 0 then
			local reqs: { Instance? } = {}
			for _, r in n.req do
				local rn = Catalog.researchNode(r)
				local ok = Rules.has(g, r)
				table.insert(reqs, Ui.text((ok and "✓ " or "✕ ") .. (rn and rn.name or r), { size = Ui.S.xs, color = ok and T.gr or T.re2, weight = ok and W.med or W.semi }))
			end
			table.insert(items, Ui.col({ Ui.lbl("Requisitos", T.mut, 11), Ui.col(reqs, 2) }, 3, { Name = "Requisitos" }))
		else
			table.insert(items, Ui.text("Sin tecnologías previas", { size = Ui.S.xs, color = T.mut, name = "Requisitos" }))
		end
	end
	if st == "curso" then
		local p = Rules.researchProject(g, n.id)
		local bar, fill = Ui.bar(p and p.progress / p.days * 100 or 0, STYLE.accent)
		local lbl = Ui.inline("", { size = Ui.S.xs, color = T.mut, name = "AvanceTarjeta" })
		local function upd(gg: any)
			local x = Rules.researchProject(gg, n.id)
			if x then
				Ui.setBar(fill, x.progress / x.days * 100)
				lbl.Text = Util.round(x.progress / x.days * 100) .. " % · faltan " .. daysText(Screen.daysLeft(gg, x))
			end
		end
		upd(g)
		App.live(upd)
		table.insert(items, Ui.col({ bar, lbl }, 4))
	elseif st == "disponible" then
		local block = Screen.blockReason(g, n)
		table.insert(items, Ui.button("Investigar", "p", function()
			App.openDialog("research", { id = n.id })
		end, { small = true, fill = true, icon = "flask", name = "Investigar_" .. n.id }))
		if block then
			table.insert(items, Ui.why(block))
		end
	elseif st == "bloqueada" then
		table.insert(items, Ui.why(why or "Bloqueada"))
	end
	local card = Ui.card(items, {
		gap = 6, pad = 10, radius = 12, bg = STYLE.card, transparency = st == "bloqueada" and 0.4 or 0.12,
		stroke = st == "curso" and { STYLE.accent, 2 } or ((st == "completada" or st == "incluida") and { Ui.hex("#226043"), 1 } or { STYLE.line, 1 }),
		name = "Nodo_" .. n.id,
	})
	card:SetAttribute("estado", st)
	card:SetAttribute("adelanto", ahead)
	return card
end

-- Tecnologías de una categoría (todas, en orden de año), más las incluidas desde la fundación. En Motores, los
-- niveles se agrupan por familia (sección propia, del nivel 2 al 10) para que el catálogo se lea ordenado.
function Screen.nodes(cat: string): ({ any }, { [string]: { any } }, { string })
	local main = Screen.builtins(cat)
	local families: { [string]: { any } } = {}
	local order: { string } = {}
	local nodes = table.clone(Catalog.RESEARCH[cat].nodes)
	table.sort(nodes, function(a: any, b: any): boolean
		if a.year ~= b.year then
			return a.year < b.year
		end
		return a.id < b.id
	end)
	for _, n in nodes do
		if n.family then
			if not families[n.family] then
				families[n.family] = {}
				table.insert(order, n.family)
			end
			table.insert(families[n.family], n)
		else
			table.insert(main, n)
		end
	end
	for _, list in families do
		table.sort(list, function(a: any, b: any): boolean
			return a.level < b.level
		end)
	end
	return main, families, order
end

local function counts(g: any, cat: string): any
	local c = { todas = 0, disponibles = 0, curso = 0, bloqueadas = 0, completadas = 0 }
	local main, families = Screen.nodes(cat)
	local function add(n: any)
		local st = Screen.status(g, n)
		for _, f in Screen.FILTERS do
			if matches(f[1], st) then
				c[f[1]] += 1
			end
		end
	end
	for _, n in main do
		add(n)
	end
	for _, list in families do
		for _, n in list do
			add(n)
		end
	end
	return c
end
Screen.counts = counts

local function category(): string
	local cat = App.ui.tabs.investigacion
	for _, c in Screen.CATEGORIES do
		if c[1] == cat then
			return cat
		end
	end
	return Screen.CATEGORIES[1][1]
end

local function filter(): string
	local f = App.ui.researchFilter
	for _, x in Screen.FILTERS do
		if x[1] == f then
			return f
		end
	end
	return "todas"
end

-- Franja de investigaciones en curso (todas las categorías), con desplazamiento horizontal.
local function activeStrip(g: any): Frame
	local items: { Instance? } = {}
	for _, p in g.research.projects do
		local n = Catalog.researchNode(p.id)
		local catLabel = ""
		for _, c in Screen.CATEGORIES do
			if n and c[1] == n.category then
				catLabel = c[2]
			end
		end
		local bar, fill = Ui.bar(p.progress / p.days * 100, STYLE.accent, 5)
		local pct = Ui.inline("", { size = Ui.S.xs, weight = W.bold, name = "Porcentaje" })
		local left = Ui.inline("", { size = Ui.S.xs, color = T.mut, name = "Restante" })
		local function upd(gg: any)
			local x = Rules.researchProject(gg, p.id)
			if x then
				Ui.setBar(fill, x.progress / x.days * 100)
				pct.Text = Util.round(x.progress / x.days * 100) .. " %"
				left.Text = "faltan " .. daysText(Screen.daysLeft(gg, x))
			end
		end
		upd(g)
		App.live(upd)
		table.insert(items, Ui.new("Frame", {
			Name = "Proyecto_" .. p.id, Size = UDim2.fromOffset(230, 70), BackgroundColor3 = STYLE.card, BackgroundTransparency = 0.1, Corner = 10,
			Stroke = { STYLE.line, 1 }, Pad = { 8, 10 }, List = { dir = "V", gap = 4 },
		}, {
			Ui.inline(Util.truncateChars(n and n.name or p.id, 28), { size = Ui.S.sm, weight = W.bold }),
			Ui.row({ Ui.grow(Ui.inline(catLabel, { size = Ui.S.xs, color = STYLE.accent2 })), pct }, 6),
			bar,
			left,
		}))
	end
	if #items == 0 then
		table.insert(items, Ui.inline("No hay investigaciones en curso. Podés llevar hasta " .. Catalog.RESEARCH_RULES.maxParallel .. " a la vez: cada una avanza por días del juego.", { size = Ui.S.sm, color = T.mut }))
	end
	local scroll = Ui.new("ScrollingFrame", {
		Name = "FranjaEnCurso", Size = UDim2.new(1, 0, 0, 84), BackgroundTransparency = 1, ScrollingDirection = Enum.ScrollingDirection.X,
		AutomaticCanvasSize = Enum.AutomaticSize.X, CanvasSize = UDim2.new(), ScrollBarThickness = 4,
	}, {
		Ui.row(items, 8, { Size = UDim2.new(0, 0, 0, 74), AutomaticSize = Enum.AutomaticSize.X }),
	})
	return scroll
end

-- Zona superior: PI, generación y la franja de investigaciones activas.
local function topZone(g: any): Frame
	local rp = Ui.inline(Util.num(math.floor(g.rp)), { size = 22, weight = W.heavy, name = "PIDisponibles" })
	local rate = Ui.inline("", { size = Ui.S.xs, color = T.mut, name = "GeneracionPI" })
	local function upd(gg: any)
		rp.Text = Util.num(math.floor(gg.rp))
		rate.Text = "+" .. Util.num(piRate(gg), 1) .. " PI por minuto real a 1× · centro " .. Util.num(Rules.piCenter(gg), 1) .. " + líneas " .. Util.num(Rules.piLines(gg), 1)
	end
	upd(g)
	App.live(upd)
	local n = #g.research.projects
	return Ui.col({
		Ui.row({
			Ui.ico("flask", STYLE.accent2, STYLE.accent, 40, { alpha = 0.2, radius = 10, iconSize = 20 }),
			Ui.col({ Ui.inline("PI disponibles", { size = Ui.S.xs, color = T.mut }), rp }, 0, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY }),
			Ui.grow(rate),
			Ui.chip(n .. " de " .. Catalog.RESEARCH_RULES.maxParallel .. " en curso", n > 0 and "cv" or "cn"),
			Ui.chip("Año " .. Rules.year(g) .. " · adelanto hasta " .. (Rules.year(g) + Catalog.RESEARCH_RULES.aheadMaxYears), "cn"),
		}, 12, { wrap = App.isPhone() }),
		activeStrip(g),
	}, 8, { Name = "ZonaSuperior" })
end

-- Menú lateral de categorías (fijo).
local function sideMenu(g: any, cat: string, vertical: boolean): Frame
	local items: { Instance? } = {}
	for _, c in Screen.CATEGORIES do
		local on = c[1] == cat
		local cnt = counts(g, c[1])
		local b = Ui.new("TextButton", {
			Name = "Pestana_" .. c[1], Text = "", AutoButtonColor = false,
			BackgroundColor3 = on and STYLE.accent or STYLE.card, BackgroundTransparency = on and 0.78 or 0.2,
			Size = vertical and UDim2.new(1, 0, 0, 52) or UDim2.fromOffset(0, 44), AutomaticSize = vertical and Enum.AutomaticSize.None or Enum.AutomaticSize.X,
			Corner = 10, Stroke = on and { STYLE.accent, 2 } or { STYLE.line, 1 }, Pad = { 0, 10 }, List = { dir = "H", gap = 10, v = "C" },
		}, {
			Ui.ico(c[3], on and T.tx or STYLE.accent2, on and STYLE.accent or Ui.hex("#16223A"), 32, { alpha = on and 0.6 or 1, radius = 8, iconSize = 16 }),
			Ui.grow(Ui.col({
				Ui.inline(c[2], { size = 15, weight = on and W.bold or W.semi, color = on and T.tx or T.tx2 }),
				Ui.inline(cnt.disponibles .. " disponibles" .. (cnt.curso > 0 and (" · " .. cnt.curso .. " en curso") or ""), { size = Ui.S.xs, color = T.mut }),
			}, 0)),
		})
		b:SetAttribute("activa", on)
		b.Activated:Connect(function()
			-- Cambiar de categoría solo cambia lo que se ve: las investigaciones en curso siguen igual.
			App.ui.tabs.investigacion = c[1]
			App.forceRender()
		end)
		table.insert(items, b)
	end
	if vertical then
		table.insert(items, Ui.text("Las investigaciones se pagan al empezar, no se cancelan y avanzan por días del juego (con la empresa en pausa, o con este menú abierto, no avanzan).", { size = Ui.S.xs, color = T.mut, lineHeight = 1.35 }))
		return Ui.col(items, 8, { Name = "MenuCategorias" })
	end
	return Ui.row(items, 6, { Name = "MenuCategorias", wrap = true })
end

local function filtersRow(g: any, cat: string, current: string): Frame
	local cnt = counts(g, cat)
	local items = {}
	for _, f in Screen.FILTERS do
		table.insert(items, Ui.opt(f[2] .. " (" .. cnt[f[1]] .. ")", current == f[1], function()
			App.ui.researchFilter = f[1]
			App.forceRender()
		end, { height = 34, name = "Filtro_" .. f[1] }))
	end
	return Ui.row(items, 6, { Name = "Filtros", wrap = true })
end

-- Catálogo de la categoría con el filtro elegido.
local function catalogBody(g: any, cat: string, f: string, parent: Instance)
	local cols = App.isPhone() and 1 or 3
	local main, families, order = Screen.nodes(cat)
	-- Primero lo que está en curso y lo que se puede investigar; después lo bloqueado y lo completado.
	local RANK = { curso = 1, disponible = 2, bloqueada = 3, completada = 4, incluida = 5 }
	local rank = {}
	for i, n in main do
		rank[n] = RANK[(Screen.status(g, n))] * 10000 + i
	end
	table.sort(main, function(a: any, b: any): boolean
		return rank[a] < rank[b]
	end)
	local cards: { Instance } = {}
	for _, n in main do
		if matches(f, (Screen.status(g, n))) then
			table.insert(cards, Screen.card(g, n, cat))
		end
	end
	local shown = #cards
	if #cards > 0 then
		Ui.grid(cards, cols, nil, 10).Parent = parent
	end
	-- Motores: una sección por familia con sus niveles.
	for _, fam in order do
		local famCards: { Instance } = {}
		for _, n in families[fam] do
			if matches(f, (Screen.status(g, n))) then
				table.insert(famCards, Screen.card(g, n, cat))
			end
		end
		if #famCards > 0 then
			local name = fam
			for _, x in Catalog.ENGINE_FAMILIES do
				if x.id == fam then
					name = x.name
				end
			end
			Ui.lbl("Familia " .. name .. " · nivel " .. Rules.engineLevelMax(g, fam) .. " de " .. Catalog.RESEARCH_RULES.engineMaxLevel).Parent = parent
			Ui.grid(famCards, cols, nil, 10).Parent = parent
			shown += #famCards
		end
	end
	if shown == 0 then
		local msg = {
			disponibles = "No hay tecnologías disponibles para investigar ahora en esta categoría. Mirá las bloqueadas para ver qué falta.",
			curso = "No hay investigaciones en curso en esta categoría.",
			bloqueadas = "No hay tecnologías bloqueadas en esta categoría.",
			completadas = "Todavía no completaste tecnologías en esta categoría.",
			todas = "Esta categoría no tiene tecnologías.",
		}
		Ui.empty("flask", msg[f] or "").Parent = parent
	end
end

function Screen.build(holder: Instance)
	local g = App.g
	local phone = App.isPhone()
	local cat = category()
	local f = filter()
	if phone then
		local scroll = Ui.scroll({}, { name = "Principal", gap = 12, pad = 12 })
		scroll.Parent = holder
		App.keepScroll(scroll, "investigacion:" .. cat .. ":" .. f)
		topZone(g).Parent = scroll
		sideMenu(g, cat, false).Parent = scroll
		filtersRow(g, cat, f).Parent = scroll
		Ui.text(CATEGORY_DESC[cat] or "", { size = Ui.S.xs, color = T.mut }).Parent = scroll
		catalogBody(g, cat, f, scroll)
		return
	end
	local top = topZone(g)
	top.Position = UDim2.fromOffset(18, 14)
	top.Size = UDim2.new(1, -36, 0, 0)
	top.Parent = holder
	local topH = 14 + 48 + 8 + 84 + 12
	local menu = sideMenu(g, cat, true)
	menu.Position = UDim2.fromOffset(18, topH)
	menu.Size = UDim2.fromOffset(220, 0)
	menu.Parent = holder
	local body = Ui.scroll({}, { name = "Principal", gap = 12, pad = { 0, 6, 12, 0 } })
	body.Position = UDim2.fromOffset(18 + 220 + 16, topH)
	body.Size = UDim2.new(1, -(18 + 220 + 16 + 18), 1, -(topH + 10))
	body.AutomaticSize = Enum.AutomaticSize.None
	body.Parent = holder
	App.keepScroll(body, "investigacion:" .. cat .. ":" .. f)
	Ui.row({
		Ui.grow(Ui.text(CATEGORY_DESC[cat] or "", { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 })),
	}, 8).Parent = body
	filtersRow(g, cat, f).Parent = body
	catalogBody(g, cat, f, body)
	if not Ui.reduceMotion then
		Ui.fadeIn(body)
	end
end

return Screen
