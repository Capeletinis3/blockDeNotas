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

function Screen.head(g: any): { Instance }
	return { Ui.chip(Rules.readyMissions(g) .. " para reclamar", "cg"), Ui.chip(g.gems .. " gemas", "cv") }
end

local STATE = { reclamada = { "Reclamada", "cn" }, lista = { "Lista", "cg" }, progreso = { "En progreso", "cb" } }

local function missionCard(g: any, m: any): Frame
	local v = Rules.missionValue(g, m)
	local st = Rules.missionState(g, m)
	local money = m.counter == "marginToday"
	local bar = Ui.bar(math.min(1, v / m.goal) * 100, st == "lista" and T.gr or nil)
	local claim
	claim = Ui.button("Reclamar " .. Rules.rewardText(m.reward), "g", function()
		App.request("claimMission", { id = m.id }, { button = claim })
	end, { small = true, name = "Reclamar_" .. m.id })
	return Ui.card({
		Ui.row({ Ui.grow(Ui.text(m.title, { size = 15, weight = W.bold })), Ui.chip(STATE[st][1], STATE[st][2]) }, 6),
		Ui.text(m.desc, { size = Ui.S.xs, color = T.mut }),
		Ui.row({ Ui.grow(bar, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline((money and Util.money(math.min(v, m.goal)) or tostring(math.min(v, m.goal))) .. "/" .. (money and Util.money(m.goal) or tostring(m.goal)), { size = Ui.S.xs, weight = W.bold }) }, 8),
		Ui.row({
			Ui.inline("Recompensa: " .. Rules.rewardText(m.reward), { size = Ui.S.xs, color = T.gr }),
			Ui.spacer(),
			st == "lista" and claim or (st == "progreso" and Ui.button("Ir", "default", function()
				App.go(m.go)
			end, { small = true }) or nil),
		}, 8),
	}, { gap = 6, stroke = st == "lista" and Color3.fromHex("#226043") or nil, name = "Mision_" .. m.id })
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
		Ui.note("y", "Saltaste el tutorial: las guías están ocultas, pero las misiones siguen activas y se completan haciendo cada acción.", Ui.button("Reactivar guías", "default", function()
			App.request("setTutorial", { skipped = false })
		end, { small = true })).Parent = main
	end
	if tab == "diaria" then
		Ui.note("b", "Las misiones diarias se reinician al empezar cada día de juego (hoy es el día " .. (g.time.day + 1) .. "). Cuentan lo vendido, producido y ganado en ese día.").Parent = main
	end
	if tab == "evento" then
		Ui.card({
			Ui.row({ Ui.grow(Ui.text("Eventos de temporada", { size = 15, weight = W.bold })), Ui.chip("Función futura", "cy") }, 8),
			Ui.text("Los eventos todavía no están implementados: no modifican la simulación ni entregan premios.", { size = Ui.S.sm, color = T.mut }),
		}).Parent = main
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
		App.request("claimDaily", nil, { button = daily })
	end, { small = true, disabled = not canDaily, why = "Ya la reclamaste hoy" })
	Ui.card({
		Ui.lbl("Recompensa diaria"),
		Ui.text("Usa la fecha real del servidor (UTC). Racha actual: " .. g.daily.streak .. " día(s). Entrar días seguidos mejora el premio (hasta el día 7).", { size = Ui.S.xs, color = T.mut }),
		daily,
	}, { gap = 8 }).Parent = side
	Ui.card({
		Ui.lbl("Cómo funcionan"),
		Ui.text("Las misiones avanzan solo con acciones reales de la partida. Una recompensa reclamada queda registrada en el servidor y no se puede volver a cobrar, aunque se repita la solicitud. Las gemas se usarán en funciones futuras.", { size = Ui.S.xs, color = T.mut }),
	}, { gap = 4 }).Parent = side
end

return Screen
