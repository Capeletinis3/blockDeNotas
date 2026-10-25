--!strict
-- Investigación (SCREENS.investigacion de la V3): árbol por categorías, costo, PI, requisitos,
-- laboratorio, duración, progreso y desbloqueos reales.

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

function Screen.head(g: any): { Instance }
	return { Ui.chip(math.floor(g.rp) .. " PI", "cv") }
end

local function depth(n: any): number
	if #n.req == 0 then
		return 0
	end
	local d = 0
	for _, r in n.req do
		d = math.max(d, depth(Catalog.researchNode(r)))
	end
	return 1 + d
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
		why = "El laboratorio está ocupado"
	elseif g.money < n.cost then
		why = "Fondos insuficientes"
	elseif g.rp < n.rp then
		why = "Faltan puntos de investigación (" .. math.floor(g.rp) .. "/" .. n.rp .. ")"
	end
	local reqs: { Instance? } = {}
	if #n.req > 0 then
		local names = {}
		for _, r in n.req do
			table.insert(names, (Rules.has(g, r) and "✓ " or "✕ ") .. Catalog.researchNode(r).name)
		end
		table.insert(reqs, Ui.text("Requiere: " .. table.concat(names, ", "), { size = Ui.S.xs, color = T.mut }))
	end
	if n.lab > 1 then
		table.insert(reqs, Ui.text(((g.sede >= n.lab) and "✓ " or "✕ ") .. "Laboratorio de la sede " .. Catalog.SEDES[n.lab].name, { size = Ui.S.xs, color = T.mut }))
	end
	local action: Instance? = nil
	if st == "activa" then
		local bar, fill = Ui.bar(0, T.vi)
		App.live(function(gg: any)
			local a = gg.research.active
			if a and a.id == n.id then
				Ui.setBar(fill, a.progress / n.minutes * 100)
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
	return Ui.card({
		Ui.row({ Ui.grow(Ui.text(n.name, { size = Ui.S.sm, weight = W.bold })), Ui.chip(chip[1], chip[2]) }, 10),
		Ui.text(n.gain, { size = Ui.S.xs, color = T.mut }),
		Ui.text(Util.money(n.cost) .. " · " .. n.rp .. " PI · " .. Util.gameDuration(n.minutes) .. " de juego", { size = Ui.S.xs }),
		#reqs > 0 and Ui.col(reqs, 2) or nil,
		action,
	}, { gap = 6, stroke = st == "activa" and T.vi or (st == "hecha" and Color3.fromHex("#226043") or nil), name = "Nodo_" .. n.id })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local list = {}
	for _, key in Catalog.RESEARCH_ORDER do
		local done = 0
		for _, n in Catalog.RESEARCH[key].nodes do
			if Rules.has(g, n.id) then
				done += 1
			end
		end
		table.insert(list, { key, Catalog.RESEARCH[key].label, done .. "/" .. #Catalog.RESEARCH[key].nodes })
	end
	local tabs, cat = Sheet.tabs("investigacion", list, Catalog.RESEARCH_ORDER[1])
	tabs.Parent = main
	local cols = {}
	for _, n in Catalog.RESEARCH[cat].nodes do
		local d = depth(n) + 1
		cols[d] = cols[d] or {}
		table.insert(cols[d], n)
	end
	local narrow = App.isNarrow()
	local holder = narrow and Ui.col({}, 12) or Ui.row({}, 14, { v = "T" })
	for i, col in cols do
		local items: { Instance? } = { Ui.lbl("Nivel " .. i) }
		for _, n in col do
			table.insert(items, nodeCard(g, n))
		end
		local c = Ui.col(items, 10)
		if narrow then
			c.Parent = holder
		else
			Ui.grow(c, { Size = UDim2.new(1 / #cols, -10, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }).Parent = holder
		end
	end
	holder.Parent = main

	local a = g.research.active
	local current: { Instance? } = { Ui.lbl("En curso") }
	if a then
		local n = Catalog.researchNode(a.id)
		local bar, fill = Ui.bar(a.progress / n.minutes * 100, T.vi)
		local lbl = Ui.text("", { size = Ui.S.xs })
		App.live(function(gg: any)
			local ra = gg.research.active
			if ra and ra.id == n.id then
				Ui.setBar(fill, ra.progress / n.minutes * 100)
				-- V3 (data-live="research"): porcentaje y tiempo de juego restante.
				lbl.Text = math.floor(ra.progress / n.minutes * 100) .. "% · faltan " .. Util.gameDuration(n.minutes - ra.progress) .. " de juego"
			end
		end)
		table.insert(current, Ui.text(n.name, { size = 15, weight = W.bold }))
		table.insert(current, bar)
		table.insert(current, lbl)
		table.insert(current, Ui.button("Cancelar investigación", "d", function()
			App.openDialog("confirm", {
				title = "¿Cancelar la investigación?",
				body = "Se devuelven " .. Util.money(a.paid) .. " y " .. a.rp .. " PI. Se pierde el avance.",
				okLabel = "Cancelar investigación",
				danger = true,
				onOk = function()
					App.request("cancelResearch")
				end,
			})
		end, { small = true }))
		table.insert(current, Ui.text("Cancelar devuelve el dinero y los PI; se pierde el avance.", { size = Ui.S.xs, color = T.mut }))
	else
		table.insert(current, Ui.text("El laboratorio está libre. Elegí una investigación disponible.", { size = Ui.S.sm, color = T.mut }))
	end
	Ui.card(current, { gap = 8 }).Parent = side
	Ui.card({
		Ui.lbl("Puntos de investigación (PI)"),
		Ui.between("Disponibles", math.floor(g.rp) .. " PI"),
		Ui.between("Se generan por día de juego", Rules.rpPerDay(g) .. " PI"),
		Ui.text("Asigná ingenieros al Laboratorio en Personal para generar más PI.", { size = Ui.S.xs, color = T.mut }),
	}, { gap = 6 }).Parent = side
	local done = {}
	for _, id in g.research.done do
		table.insert(done, Catalog.researchNode(id).name)
	end
	Ui.card({ Ui.lbl("Completadas"), Ui.text(#done > 0 and table.concat(done, ", ") or "Ninguna todavía.", { size = Ui.S.sm }) }, { gap = 4 }).Parent = side
end

return Screen
