--!strict
-- Personal (SCREENS.personal de la V3): equipo (asignación y despido) y candidatos. El personal es un
-- extra opcional: suma velocidad a la fábrica (máx. +30 %), PI al laboratorio (máx. +30 %) y alcance
-- comercial (máx. +25 %). No hay cansancio ni descansos que atender.

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
	title = "Personal",
	icon = "users",
	color = Color3.fromHex("#FF9DC1"),
	bg = Color3.fromHex("#33182A"),
}

function Screen.head(g: any): { Instance }
	return { Ui.chip(#g.employees .. "/" .. g.derived.caps.staff .. " empleados", "cn"), Ui.chip("Salarios " .. Util.money(Rules.salaries(g)) .. "/mes", "cy") }
end

local function empRow(g: any, e: any): Frame
	-- <select> «Puesto»: ★ marca el rol ideal y «(completo)» los puestos sin lugar.
	local options = { { "", "Sin asignar" } }
	local function add(id: string, label: string, max: number)
		local n = Rules.assignedCount(g, id, e.id)
		local full = n >= max
		table.insert(options, { id, label .. (full and " (completo)" or ""), full })
	end
	for _, st in Catalog.STATIONS do
		add(st[1], "Estación: " .. st[2] .. (st[3] == e.role and " ★" or ""), Catalog.RULES.assignMax.station)
	end
	for _, d in Catalog.DEPARTMENTS do
		add(d[1], d[2] .. (d[3] == e.role and " ★" or ""), Catalog.RULES.assignMax.dept)
	end
	local assigned = e.assign ~= nil and e.assign ~= ""
	return Ui.card({
		Ui.row({
			Ui.ico("users", T.pink, Ui.hex("#FF78AA"), 32, { alpha = 0.14, iconSize = 16 }),
			Ui.grow(Ui.col({
				Ui.text(e.name, { size = Ui.S.base, weight = W.bold }),
				Ui.text(e.role .. " · nivel " .. e.level .. " · habilidad " .. e.skill .. " · " .. Util.money(e.salary) .. "/mes", { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			Ui.chip(assigned and "Asignado/a" or "Sin puesto", assigned and "cg" or "cy"),
		}, 10, { wrap = true }),
		Ui.row({
			Ui.selectF("Puesto", e.assign or "", options, function(v: any)
				App.request("assign", { employeeId = e.id, area = v })
			end, { height = 34, name = "Puesto_" .. e.id }),
			Ui.spacer(),
			Ui.button("Despedir", "q", function()
				App.openDialog("confirm", {
					title = "¿Despedir a " .. e.name .. "?",
					body = "Deja de cobrar salario y de aportar a su puesto. El costo de contratación no se recupera.",
					okLabel = "Despedir",
					danger = true,
					onOk = function()
						App.request("fire", { employeeId = e.id })
					end,
				})
			end, { small = true }),
		}, 10, { wrap = App.isNarrow() }),
	}, { gap = 8, name = "Empleado_" .. e.id })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local tabs, tab = Sheet.tabs("personal", { { "team", "Equipo", #g.employees }, { "hire", "Contratar", #g.candidates } }, #g.employees > 0 and "team" or "hire")
	tabs.Parent = main
	if tab == "team" then
		if #g.employees == 0 then
			Ui.empty("users", "Todavía no contrataste a nadie. El personal es opcional: suma velocidad, PI y alcance comercial.", Ui.button("Ver candidatos", "p", function()
				App.ui.tabs.personal = "hire"
				App.forceRender()
			end, { small = true })).Parent = main
		end
		for _, e in g.employees do
			empRow(g, e).Parent = main
		end
	else
		local full = #g.employees >= g.derived.caps.staff
		if full then
			Ui.note("y", "La sede está completa (" .. g.derived.caps.staff .. " empleados). Ampliá la sede en Compañía para contratar más.").Parent = main
		end
		for _, c in g.candidates do
			local b
			b = Ui.button("Contratar", "p", function()
				App.request("hire", { candidateId = c.id }, { button = b })
			end, { small = true, disabled = full or g.money < c.fee, why = full and "Sede completa" or "Fondos insuficientes", name = "Contratar_" .. c.id })
			Ui.card({
				Ui.ico("users", T.pink, Ui.hex("#FF78AA"), 32, { alpha = 0.14, iconSize = 16 }),
				Ui.grow(Ui.col({
					Ui.text(c.name, { size = Ui.S.base, weight = W.bold }),
					Ui.text(c.role .. " · nivel " .. c.level .. " · habilidad " .. c.skill .. " · salario " .. Util.money(c.salary) .. "/mes", { size = Ui.S.xs, color = T.mut }),
				}, 2)),
				Ui.inline("Costo de contratación", { size = Ui.S.xs, color = T.mut }),
				Ui.inline(Util.money(c.fee), { size = Ui.S.base, weight = W.bold }),
				b,
			}, { dir = "H", v = "C", gap = 10, wrap = true, name = "Candidato_" .. c.id }).Parent = main
		end
		local more
		more = Ui.button("Buscar más candidatos · " .. Util.money(Catalog.RULES.moreCandidatesCost), "default", function()
			App.request("moreCandidates", nil, { button = more })
		end, { small = true, disabled = g.money < Catalog.RULES.moreCandidatesCost, why = "Fondos insuficientes" })
		Ui.row({ more, Ui.text("Cada mes de juego aparecen candidatos nuevos si quedan menos de 3.", { size = Ui.S.xs, color = T.mut }) }, 10, { wrap = true }).Parent = main
	end

	local rows: { Instance? } = { Ui.lbl("Áreas y efecto actual") }
	local function areaRow(id: string, label: string, role: string)
		table.insert(rows, Ui.row({
			Ui.grow(Ui.text(label .. " <font color=\"#A3AAB8\" size=\"11\">· ideal " .. string.lower(role) .. "</font>", { size = Ui.S.sm })),
			Ui.inline(tostring(Rules.assignedCount(g, id)), { size = Ui.S.sm, weight = W.bold }),
			Ui.inline("+" .. Util.num(Rules.staffBonus(g, id), 1), { size = Ui.S.xs, color = T.mut, width = 44, align = "R" }),
		}, 10))
	end
	for _, st in Catalog.STATIONS do
		areaRow(st[1], st[2], st[3])
	end
	for _, d in Catalog.DEPARTMENTS do
		areaRow(d[1], d[2], d[3])
	end
	table.insert(rows, Ui.text("El número de la derecha es el aporte (habilidad × afinidad con el puesto; la mitad si no es el rol ideal). Estaciones: +5 % de velocidad por punto (máx. +30 %). Laboratorio: más PI (máx. +30 %). Ventas y marketing: más alcance (máx. +25 %). Cada estación admite " .. Catalog.RULES.assignMax.station .. " personas y cada departamento " .. Catalog.RULES.assignMax.dept .. ".", { size = Ui.S.xs, color = T.mut, lineHeight = 1.5 }))
	Ui.card(rows, { gap = 6 }).Parent = side
end

return Screen
