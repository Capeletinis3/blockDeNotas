--!strict
--[[
	Investigación y desarrollo (I+D): una pestaña por categoría (Chasis, Motores, Seguridad, Tecnología y
	confort; «Empresa» guarda provisoriamente las mejoras de producción y marketing). Tarjetas en filas de tres
	con nombre, nivel o generación, descripción, beneficios, costo en dinero, PI y días (con el recargo si se
	adelanta), requisitos y estado. Se pueden llevar varias investigaciones a la vez; avanzan por días
	simulados y no se cancelan. Todos los números salen de Rules.researchCost: los mismos que cobra el servidor.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Sheet = require(script.Parent.ScreenSheet)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Investigación",
	icon = "flask",
	color = Color3.fromHex("#6FE3F0"),
	bg = Color3.fromHex("#12303A"),
}

local STATE_CHIP = { hecha = { "✓ Completada", "cg" }, activa = { "Investigándose", "cv" }, disponible = { "Disponible", "cb" }, bloqueada = { "Bloqueada", "cn" } }
local CATEGORY_DESC = {
	chasis = "Plataformas y generaciones de chasis, estructura y materiales.",
	motores = "Familias de motores con 10 niveles, variantes económica y deportiva, transmisiones y tecnología del motor.",
	seguridad = "Cada tecnología se investiga sola y después se elige al diseñar: no se instala sola.",
	tecnologia = "Equipamiento y confort: se investiga una vez y se elige en cada diseño.",
	empresa = "Mejoras de la empresa de versiones anteriores (fabricación y marketing). Pasarán a Instalaciones y Marketing.",
}

local function piText(g: any): string
	local p = g.derived.piPerMinute
	return Util.num(p, p < 10 and 1 or 0) .. " PI/min"
end

function Screen.head(g: any): { Instance }
	return { Ui.chip(Util.num(math.floor(g.rp)) .. " PI", "cv"), Ui.chip(piText(g), "cb"), Ui.chip(#(g.research.projects or {}) .. " en curso", "cn") }
end

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

-- Por qué no se puede empezar (o nil si se puede).
function Screen.blockReason(g: any, n: any): string?
	local st = Rules.researchState(g, n)
	if st == "hecha" then
		return "Ya investigada"
	elseif st == "activa" then
		return "En curso"
	end
	local miss = Rules.researchMissing(g, n)
	if #miss > 0 then
		return table.concat(miss, " · ")
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

function Screen.card(g: any, n: any): Frame
	local st = Rules.researchState(g, n)
	local chip = STATE_CHIP[st]
	local pi, cost, days, info = Rules.researchCost(g, n)
	local why = Screen.blockReason(g, n)
	local reqs: { Instance? } = {}
	if #n.req > 0 then
		local names = {}
		for _, r in n.req do
			table.insert(names, (Rules.has(g, r) and "✓ " or "✕ ") .. Catalog.researchNode(r).name)
		end
		table.insert(reqs, Ui.text("Requisitos: " .. table.concat(names, ", "), { size = Ui.S.xs, color = T.mut }))
	end
	local costLine = Util.money(cost) .. " · " .. Util.num(pi) .. " PI · " .. days .. (days == 1 and " día" or " días")
	local aheadNote = nil
	if st ~= "hecha" and info.ahead > 0 then
		local R = Catalog.RESEARCH_RULES
		aheadNote = Ui.text("Adelantada " .. info.ahead .. (info.ahead == 1 and " año" or " años") .. " (aparece en " .. n.year .. "): +" .. Util.round(R.aheadMoney * info.ahead * 100) .. " % de dinero, +" .. Util.round(R.aheadPi * info.ahead * 100) .. " % de PI y +" .. Util.round(R.aheadDays * info.ahead * 100) .. " % de días (incluido arriba).", { size = Ui.S.xs, color = T.ye, name = "Adelanto" })
	elseif st ~= "hecha" and info.diffusion < 1 then
		aheadNote = Ui.text("Tecnología conocida: −" .. Util.round((1 - info.diffusion) * 100) .. " % de dinero y PI.", { size = Ui.S.xs, color = T.gr })
	end
	local action: Instance? = nil
	if st == "activa" then
		local p = Rules.researchProject(g, n.id)
		local bar, fill = Ui.bar(p and p.progress / p.days * 100 or 0, T.vi)
		local lbl = Ui.inline("", { size = Ui.S.xs, color = T.mut })
		local function upd(gg: any)
			local x = Rules.researchProject(gg, n.id)
			if x then
				Ui.setBar(fill, x.progress / x.days * 100)
				lbl.Text = math.floor(x.progress) .. "/" .. x.days .. " días"
			end
		end
		upd(g)
		App.live(upd)
		action = Ui.col({ bar, lbl }, 4)
	elseif st ~= "hecha" then
		local b
		b = Ui.button("Investigar", "p", function()
			App.request("startResearch", { id = n.id }, { button = b })
		end, { small = true, fill = true, disabled = why ~= nil, why = why, name = "Investigar_" .. n.id })
		action = Ui.col({ b, why and Ui.why(why) or nil }, 6)
	end
	return Ui.card({
		Ui.row({ Ui.chip(Screen.levelLabel(n), "cn"), Ui.spacer(), Ui.chip(chip[1], chip[2]) }, 6),
		Ui.text(n.name, { size = Ui.S.sm, weight = W.bold }),
		Ui.text((n.desc or (Catalog.RESEARCH[n.category].label .. " · aparece en " .. n.year)), { size = Ui.S.xs, color = T.mut }),
		Ui.text("Beneficio: " .. n.gain, { size = Ui.S.xs, color = T.tx2, lineHeight = 1.35 }),
		st ~= "hecha" and Ui.text(costLine, { size = Ui.S.xs, weight = W.semi, color = T.or_, name = "Costo" }) or nil,
		aheadNote,
		#reqs > 0 and Ui.col(reqs, 2) or nil,
		action,
	}, { gap = 6, stroke = st == "activa" and T.vi or (st == "hecha" and Color3.fromHex("#226043") or nil), name = "Nodo_" .. n.id })
end

-- Tarjetas de una categoría. En Motores, los niveles se muestran de a uno por familia (el próximo a investigar
-- o el que está en curso) para no llenar la pantalla con 54 tarjetas.
function Screen.visibleNodes(g: any, cat: string): { any }
	local out = {}
	local shownFamily = {}
	local nodes = table.clone(Catalog.RESEARCH[cat].nodes)
	table.sort(nodes, function(a: any, b: any): boolean
		if a.year ~= b.year then
			return a.year < b.year
		end
		return a.id < b.id
	end)
	for _, n in nodes do
		if n.family then
			local st = Rules.researchState(g, n)
			if st == "activa" then
				table.insert(out, n)
			elseif st ~= "hecha" and not shownFamily[n.family] then
				shownFamily[n.family] = true
				table.insert(out, n)
			end
		else
			table.insert(out, n)
		end
	end
	return out
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local list = {}
	for _, key in Catalog.RESEARCH_ORDER do
		local avail = 0
		for _, n in Catalog.RESEARCH[key].nodes do
			if Screen.blockReason(g, n) == nil then
				avail += 1
			end
		end
		table.insert(list, { key, Catalog.RESEARCH[key].label, avail > 0 and avail or nil })
	end
	local tabs, cat = Sheet.tabs("investigacion", list, Catalog.RESEARCH_ORDER[1])
	tabs.Parent = main
	Ui.text(CATEGORY_DESC[cat] or "", { size = Ui.S.xs, color = T.mut }).Parent = main
	if cat == "motores" then
		local fams = {}
		for _, f in Catalog.ENGINE_FAMILIES do
			table.insert(fams, Ui.chip(f.name .. " · nivel " .. Rules.engineLevelMax(g, f.id) .. "/" .. Catalog.RESEARCH_RULES.engineMaxLevel, "cv"))
		end
		Ui.row(fams, 6, { wrap = true, Name = "NivelesMotor" }).Parent = main
	end
	local cards: { Instance } = {}
	local pending: { Instance } = {}
	for _, n in Screen.visibleNodes(g, cat) do
		if Rules.has(g, n.id) then
			table.insert(pending, Screen.card(g, n))
		else
			table.insert(cards, Screen.card(g, n))
		end
	end
	local cols = App.isPhone() and 1 or 3
	if #cards > 0 then
		Ui.grid(cards, cols, nil, 10).Parent = main
	end
	if #pending > 0 then
		Ui.lbl("Completadas").Parent = main
		Ui.grid(pending, cols, nil, 10).Parent = main
	end

	-- Columna lateral: proyectos en curso y PI.
	local current: { Instance? } = { Ui.lbl("En curso (" .. #g.research.projects .. "/" .. Catalog.RESEARCH_RULES.maxParallel .. ")") }
	for _, p in g.research.projects do
		local n = Catalog.researchNode(p.id)
		local bar, fill = Ui.bar(p.progress / p.days * 100, T.vi)
		local lbl = Ui.text("", { size = Ui.S.xs, color = T.mut })
		local function upd(gg: any)
			local x = Rules.researchProject(gg, p.id)
			if x then
				Ui.setBar(fill, x.progress / x.days * 100)
				lbl.Text = math.floor(x.progress) .. "/" .. x.days .. " días · faltan ≈ " .. Util.realTime(Rules.projectSecondsLeft(x, gg.time.speed, gg)) .. (gg.time.speed == 0 and " (en pausa)" or "")
			end
		end
		upd(g)
		App.live(upd)
		table.insert(current, Ui.col({ Ui.text(n and n.name or p.id, { size = Ui.S.sm, weight = W.bold }), bar, lbl }, 4, { Name = "Proyecto_" .. p.id }))
	end
	if #g.research.projects == 0 then
		table.insert(current, Ui.text("No hay investigaciones en curso. Podés llevar varias a la vez: cada una avanza por días del juego.", { size = Ui.S.sm, color = T.mut }))
	end
	table.insert(current, Ui.text("Se pagan al empezar y no se pueden cancelar. Con la empresa en pausa (o un menú abierto) no avanzan.", { size = Ui.S.xs, color = T.mut }))
	Ui.card(current, { gap = 8, name = "EnCurso" }).Parent = side

	local rpLabel = Ui.inline(Util.num(math.floor(g.rp)) .. " PI", { size = Ui.S.sm, weight = W.bold })
	local center = Ui.inline("", { size = Ui.S.sm })
	local lines = Ui.inline("", { size = Ui.S.sm })
	local total = Ui.inline("", { size = Ui.S.sm, color = T.vi2 })
	local function upd(gg: any)
		rpLabel.Text = Util.num(math.floor(gg.rp)) .. " PI"
		local c = Rules.piCenter(gg)
		local l = Rules.piLines(gg)
		center.Text = Util.num(c, 1) .. " PI/min"
		lines.Text = Util.num(l, 1) .. " PI/min (" .. Rules.activeLines(gg) .. (Rules.activeLines(gg) == 1 and " línea" or " líneas") .. ")"
		total.Text = Util.num(c + l, 1) .. " PI/min"
	end
	upd(g)
	App.live(upd)
	Ui.card({
		Ui.lbl("Puntos de investigación (PI)"),
		Ui.row({ Ui.grow(Ui.text("Disponibles", { size = Ui.S.sm })), rpLabel }, 10),
		Ui.row({ Ui.grow(Ui.text("Centro de investigación (" .. Rules.sede(g).name .. ")", { size = Ui.S.sm })), center }, 10),
		Ui.row({ Ui.grow(Ui.text("Líneas fabricando (" .. Catalog.RESEARCH_RULES.linePi .. " PI/min cada una)", { size = Ui.S.sm })), lines }, 10),
		Ui.row({ Ui.grow(Ui.text("Generación total a 1×", { size = Ui.S.sm, weight = W.bold })), total }, 10),
		Ui.text("Los PI se generan mientras la simulación corre (a 2× y 3×, más rápido) y se acumulan sin tope. Ampliar la sede mejora el centro de investigación.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.4 }),
	}, { gap = 6, name = "PI" }).Parent = side
	local totalNodes = 0
	for _, key in Catalog.RESEARCH_ORDER do
		totalNodes += #Catalog.RESEARCH[key].nodes
	end
	Ui.card({
		Ui.lbl("Progreso"),
		Ui.between("Tecnologías completadas", #g.research.done .. "/" .. totalNodes),
		Ui.between("Año actual", tostring(Rules.year(g)) .. " (se puede adelantar hasta " .. (Rules.year(g) + Catalog.RESEARCH_RULES.aheadMaxYears) .. ")"),
	}, { gap = 6 }).Parent = side
end

return Screen
