--!strict
-- Misiones y recompensas (SCREENS.misiones de la V3): tutorial, historia, del año y recompensa diaria.

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
	local money = m.counter == "marginYear"
	local goal = Rules.missionGoal(g, m)
	local bar = Ui.bar(math.min(1, v / goal) * 100, st ~= "progreso" and T.gr or nil)
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
	local amount = (money and Util.money(math.min(v, goal)) or Util.num(math.min(v, goal))) .. "/" .. (money and Util.money(goal) or Util.num(goal))
	return Ui.card({
		Ui.row({ Ui.grow(Ui.text(m.title, { size = Ui.S.base, weight = W.bold })), Ui.chip(STATE[st][1], STATE[st][2]) }, 10, { wrap = true }),
		Ui.text(m.desc, { size = Ui.S.xs, color = T.mut }),
		Ui.row({ Ui.grow(bar, { Size = UDim2.new(0, 0, 0, 7) }), Ui.inline(amount, { size = Ui.S.sm, weight = W.bold }) }, 10),
		Ui.row({
			Ui.grow(Ui.text("Recompensa: <b><font color=\"#42E58D\">" .. Rules.rewardText(Rules.missionReward(g, m)) .. "</font></b>", { size = Ui.S.sm })),
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
	local tabs, tab = Sheet.tabs("misiones", { { "tutorial", "Tutorial", ready("tutorial") }, { "historia", "Historia", ready("historia") }, { "anual", "Del año", ready("anual") } }, "tutorial")
	tabs.Parent = main
	if tab == "tutorial" and g.tutorial.skipped then
		Ui.note("y", "Saltaste el tutorial: las guías están ocultas, pero las misiones siguen activas y solo se completan haciendo cada acción.", Ui.button("Reactivar guías", "default", function()
			App.request("setTutorial", { skipped = false })
		end, { small = true, name = "ReactivarGuias" })).Parent = main
	end
	if tab == "anual" then
		Ui.note("b", "Las misiones del año se reinician cada enero (ahora " .. Rules.year(g) .. "). La meta crece con el alcance de tu sede.").Parent = main
	end
	for _, m in Catalog.MISSIONS do
		if m.kind == tab then
			missionCard(g, m).Parent = main
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
		Ui.text("Las misiones avanzan solo con acciones reales de la partida (guardar diseños, lanzar lotes, vender, investigar…). Las recompensas dan dinero y puntos de investigación (PI). Una recompensa reclamada queda registrada y no se puede volver a cobrar.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.5 }),
	}, { gap = 4 }).Parent = side
end

return Screen
