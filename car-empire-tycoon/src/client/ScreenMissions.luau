--!strict
-- Misiones y recompensas (SCREENS.misiones de la V3): tutorial, historia, diarias y recompensa diaria.

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
	title = "Misiones y recompensas",
	icon = "flag",
	color = Color3.fromHex("#B3AAFF"),
	bg = Color3.fromHex("#211D45"),
}

function Screen.head(_g: any): { Instance }
	return {}
end

local STATE = { reclamada = { "✓ Reclamada", "cn" }, lista = { "Lista para reclamar", "cg" }, progreso = { "En progreso", "cb" } }

local function missionCard(g: any, m: any): Frame
	local v = Rules.missionValue(g, m)
	local st = Rules.missionState(g, m)
	local money = m.counter == "marginToday"
	local bar = Ui.bar(math.min(1, v / m.goal) * 100, st ~= "progreso" and T.gr or nil)
	local action: Instance? = nil
	if st == "lista" then
		local claim
		claim = Ui.button("Reclamar", "g", function()
			App.request("claimMission", { id = m.id }, { button = claim })
		end, { small = true, icon = "check", iconSize = 15, name = "Reclamar_" .. m.id })
		action = claim
	elseif st == "progreso" then
		action = Ui.button("Ir", "default", function()
			App.go(m.go)
		end, { small = true, name = "Ir_" .. m.id })
	end
	local amount = (money and Util.money(math.min(v, m.goal)) or tostring(math.min(v, m.goal))) .. "/" .. (money and Util.money(m.goal) or tostring(m.goal))
	return Ui.card({
		Ui.row({ Ui.grow(Ui.text(m.title, { size = Ui.S.base, weight = W.bold })), Ui.chip(STATE[st][1], STATE[st][2]) }, 10, { wrap = true }),
		Ui.text(m.desc, { size = Ui.S.xs, color = T.mut }),
		Ui.row({ Ui.grow(bar, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline(amount, { size = Ui.S.sm, weight = W.bold }) }, 10),
		Ui.row({
			Ui.grow(Ui.text("Recompensa: <b><font color=\"#42E58D\">" .. Rules.rewardText(m.reward) .. "</font></b>", { size = Ui.S.sm })),
			action,
		}, 10, { wrap = true }),
	}, { gap = 8, stroke = st == "lista" and Color3.fromHex("#2A7550") or nil, name = "Mision_" .. m.id })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local function ready(kind: string): number
		local n = 0
		for _, m in Catalog.MISSIONS do
			if m.kind == kind and Rules.missionState(g, m) == "lista" then
				n += 1
			end
		end
		return n
	end
	local tabs, tab = Sheet.tabs("misiones", { { "tutorial", "Tutorial", ready("tutorial") }, { "historia", "Historia", ready("historia") }, { "diaria", "Diarias", ready("diaria") }, { "evento", "Eventos" } }, "tutorial")
	tabs.Parent = main
	if tab == "tutorial" and g.tutorial.skipped then
		Ui.note("y", "Saltaste el tutorial: las guías están ocultas, pero las misiones siguen activas y solo se completan haciendo cada acción.", Ui.button("Reactivar guías", "default", function()
			App.request("setTutorial", { skipped = false })
		end, { small = true, name = "ReactivarGuias" })).Parent = main
	end
	if tab == "diaria" then
		Ui.note("b", "Las misiones diarias se reinician al empezar cada día de juego (día " .. (g.time.day + 1) .. " ahora).").Parent = main
	end
	if tab == "evento" then
		local news = App.screens.menu and App.screens.menu.NEWS
		Ui.card({
			Ui.row({ Ui.grow(Ui.text(news and news.event or "Evento de temporada", { size = Ui.S.base, weight = W.bold })), Ui.chip("Demostración", "cy") }, 10),
			Ui.text("Ejemplo de cómo se vería un evento de temporada: los eléctricos tendrían más demanda durante 7 días. Todavía no otorga recompensas.", { size = Ui.S.sm, color = T.mut }),
			Ui.button("Disponible en una versión futura", "default", function() end, { small = true, disabled = true, why = "Función futura", name = "EventoFuturo" }),
		}, { gap = 8, pad = 18, name = "Evento" }).Parent = main
	else
		for _, m in Catalog.MISSIONS do
			if m.kind == tab then
				missionCard(g, m).Parent = main
			end
		end
	end
	local canDaily = g.daily.last ~= App.payload.today
	local daily
	daily = Ui.button(canDaily and "Reclamar recompensa de hoy" or "Ya reclamada hoy", canDaily and "g" or "default", function()
		App.openDialog("daily", {})
	end, { small = true, fill = true, name = "RecompensaDiaria" })
	Ui.card({
		Ui.lbl("Recompensa diaria"),
		Ui.text("Usa la fecha real del servidor (UTC). Racha actual: " .. g.daily.streak .. " día(s).", { size = Ui.S.xs, color = T.mut }),
		daily,
	}, { gap = 8 }).Parent = side
	Ui.card({
		Ui.lbl("Cómo funcionan"),
		Ui.text("Las misiones avanzan solo con acciones reales de la partida (guardar diseños, contratar, fabricar, vender…). Una recompensa reclamada queda registrada y no se puede volver a cobrar.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.5 }),
	}, { gap = 4 }).Parent = side
end

return Screen
