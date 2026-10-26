--!strict
--[[
	Investigación histórica 1970–2030: ramas (motores, carrocerías, transmisiones, seguridad, confort,
	producción, electrónica, materiales y marketing) con las tecnologías ordenadas por año. Cada una
	muestra su efecto real, el costo en dinero y en PI, el tiempo estimado con la generación actual de
	PI y por qué está bloqueada (época o requisitos). Los PI salen de la sede (PI por minuto): ampliar
	la sede acelera la investigación; el personal del laboratorio suma un extra.
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

local STATE_CHIP = { hecha = { "✓ Hecha", "cg" }, activa = { "En curso", "cv" }, disponible = { "Disponible", "cb" }, bloqueada = { "Bloqueada", "cn" } }

local function piText(g: any): string
	local p = g.derived.piPerMinute
	return Util.num(p, p < 10 and 1 or 0) .. " PI/min"
end

function Screen.head(g: any): { Instance }
	return { Ui.chip(math.floor(g.rp) .. " PI", "cv"), Ui.chip(piText(g), "cb") }
end

-- Minutos reales (a 1×) que tardaría una investigación con el banco y la generación actuales.
function Screen.etaMinutes(g: any, n: any): number
	local left = math.max(0, n.rp - g.rp)
	return left / math.max(0.01, g.derived.piPerMinute)
end

local function nodeCard(g: any, n: any): Frame
	local st = Rules.researchState(g, n)
	local miss = Rules.researchMissing(g, n)
	local why = nil
	if st == "hecha" then
		why = "Ya investigada"
	elseif st == "activa" then
		why = "En curso"
	elseif #miss > 0 then
		why = table.concat(miss, " · ")
	elseif g.research.active then
		why = "Ya hay una investigación en curso"
	elseif g.money < n.cost then
		why = "Fondos insuficientes (" .. Util.money(n.cost) .. ")"
	end
	local reqs: { Instance? } = {}
	if #n.req > 0 then
		local names = {}
		for _, r in n.req do
			table.insert(names, (Rules.has(g, r) and "✓ " or "✕ ") .. Catalog.researchNode(r).name)
		end
		table.insert(reqs, Ui.text("Requiere: " .. table.concat(names, ", "), { size = Ui.S.xs, color = T.mut }))
	end
	local action: Instance? = nil
	if st == "activa" then
		local bar, fill = Ui.bar(0, T.vi)
		App.live(function(gg: any)
			local a = gg.research.active
			if a and a.id == n.id then
				Ui.setBar(fill, a.progress / n.rp * 100)
			end
		end)
		action = bar
	elseif st ~= "hecha" then
		local b
		b = Ui.button("Investigar", "p", function()
			App.request("startResearch", { id = n.id }, { button = b })
		end, { small = true, fill = true, disabled = why ~= nil, why = why, name = "Investigar_" .. n.id })
		action = Ui.col({ b, why and Ui.why(why) or nil }, 6)
	end
	local chip = STATE_CHIP[st]
	local tier = Catalog.RESEARCH_TIERS[n.tier]
	local eta = st == "disponible" and (" · ≈ " .. Util.realTime(Screen.etaMinutes(g, n) * 60) .. " con " .. piText(g)) or ""
	return Ui.card({
		Ui.row({ Ui.chip(tostring(n.year), "cn"), Ui.grow(Ui.text(n.name, { size = Ui.S.sm, weight = W.bold })), Ui.chip(chip[1], chip[2]) }, 8),
		Ui.text(n.gain, { size = Ui.S.xs, color = T.tx2 }),
		Ui.text((tier and tier.label or "") .. " · " .. Util.money(n.cost) .. " · " .. Util.num(n.rp) .. " PI" .. eta, { size = Ui.S.xs, color = T.mut }),
		#reqs > 0 and Ui.col(reqs, 2) or nil,
		action,
	}, { gap = 6, stroke = st == "activa" and T.vi or (st == "hecha" and Color3.fromHex("#226043") or nil), name = "Nodo_" .. n.id })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local list = {}
	for _, key in Catalog.RESEARCH_ORDER do
		local done, avail = 0, 0
		for _, n in Catalog.RESEARCH[key].nodes do
			if Rules.has(g, n.id) then
				done += 1
			elseif Rules.researchState(g, n) == "disponible" then
				avail += 1
			end
		end
		table.insert(list, { key, Catalog.RESEARCH[key].label, avail > 0 and avail or nil })
	end
	local tabs, cat = Sheet.tabs("investigacion", list, Catalog.RESEARCH_ORDER[1])
	tabs.Parent = main
	-- Por década: lo histórico se lee de arriba hacia abajo.
	local nodes = table.clone(Catalog.RESEARCH[cat].nodes)
	table.sort(nodes, function(a: any, b: any): boolean
		if a.year ~= b.year then
			return a.year < b.year
		end
		return a.id < b.id
	end)
	local decade = nil
	local cards: { Instance } = {}
	local function flush()
		if #cards > 0 then
			Ui.grid(cards, App.isPhone() and 1 or 2, nil, 10).Parent = main
			cards = {}
		end
	end
	for _, n in nodes do
		local d = math.floor(n.year / 10) * 10
		if d ~= decade then
			flush()
			decade = d
			Ui.lbl("Años " .. d .. (d <= Rules.year(g) and "" or " · todavía no llegaron")).Parent = main
		end
		table.insert(cards, nodeCard(g, n))
	end
	flush()

	local a = g.research.active
	local current: { Instance? } = { Ui.lbl("En curso") }
	if a then
		local n = Catalog.researchNode(a.id)
		local bar, fill = Ui.bar(a.progress / n.rp * 100, T.vi)
		local lbl = Ui.text("", { size = Ui.S.xs })
		local function upd(gg: any, ra: any)
			Ui.setBar(fill, ra.progress / n.rp * 100)
			local eta = Rules.researchEta(gg) or 0
			lbl.Text = math.floor(ra.progress) .. "/" .. n.rp .. " PI · " .. math.floor(ra.progress / n.rp * 100) .. " % · faltan ≈ " .. Util.realTime(eta / math.max(1, gg.time.speed))
		end
		upd(g, a)
		App.live(function(gg: any)
			local ra = gg.research.active
			if ra and ra.id == n.id then
				upd(gg, ra)
			end
		end)
		table.insert(current, Ui.text(n.name, { size = 15, weight = W.bold }))
		table.insert(current, Ui.text(n.gain, { size = Ui.S.xs, color = T.mut }))
		table.insert(current, bar)
		table.insert(current, lbl)
		table.insert(current, Ui.button("Cancelar investigación", "d", function()
			App.openDialog("confirm", {
				title = "¿Cancelar la investigación?",
				body = "Se devuelven " .. Util.money(a.paid) .. " y los " .. math.floor(a.progress) .. " PI aplicados.",
				okLabel = "Cancelar investigación",
				danger = true,
				onOk = function()
					App.request("cancelResearch")
				end,
			})
		end, { small = true, name = "CancelarInvestigacion" }))
	else
		table.insert(current, Ui.text("No hay investigación en curso. Elegí una disponible: los PI ahorrados se aplican enseguida.", { size = Ui.S.sm, color = T.mut }))
	end
	Ui.card(current, { gap = 8, name = "EnCurso" }).Parent = side
	local sede = Rules.sede(g)
	local nx = Rules.nextSede(g)
	local rpLabel = Ui.inline(math.floor(g.rp) .. " / " .. math.floor(Rules.piCap(g)) .. " PI", { size = Ui.S.sm, weight = W.bold })
	App.live(function(gg: any)
		rpLabel.Text = math.floor(gg.rp) .. " / " .. math.floor(gg.derived.piCap) .. " PI"
	end)
	Ui.card({
		Ui.lbl("Puntos de investigación (PI)"),
		Ui.row({ Ui.grow(Ui.text("Ahorrados", { size = Ui.S.sm })), rpLabel }, 10),
		Ui.between("Generación total", piText(g), { color = T.vi2 }),
		Ui.between("· de la sede (" .. sede.name .. ")", sede.pi .. " PI/min"),
		Ui.between("· del personal del laboratorio", "+" .. Util.num(g.derived.piPerMinute - sede.pi, 1) .. " PI/min (máx. +30 %)"),
		nx and Ui.text("Con «" .. nx.name .. "» la sede genera " .. nx.pi .. " PI/min.", { size = Ui.S.xs, color = T.mut }) or nil,
		Ui.text("Sin investigación activa se ahorran hasta " .. Catalog.RULES.piBankMinutes .. " minutos de generación. También dan PI las ventas (1 cada " .. Catalog.ECON.salesPiPer .. " autos, con tope mensual), agotar un lote con ganancia y las misiones.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.4 }),
	}, { gap = 6, name = "PI" }).Parent = side
	Ui.card({
		Ui.lbl("Progreso"),
		Ui.between("Tecnologías completadas", #g.research.done .. "/" .. (function()
			local n = 0
			for _, key in Catalog.RESEARCH_ORDER do
				n += #Catalog.RESEARCH[key].nodes
			end
			return n
		end)()),
		Ui.between("Año actual", tostring(Rules.year(g))),
	}, { gap = 6 }).Parent = side
end

return Screen
