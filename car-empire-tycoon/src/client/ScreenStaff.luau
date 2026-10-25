--!strict
-- Personal (SCREENS.personal de la V3): equipo (asignación, energía, descanso, despido) y candidatos.

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
	return { Ui.chip(#g.employees .. "/" .. g.derived.caps.staff .. " empleados", "cn"), Ui.chip("Salarios " .. Util.money(Rules.salaries(g)) .. "/día", "cy") }
end

local function areaLabel(id: string?): string
	if not id then
		return "Sin asignar"
	end
	local s = Catalog.station(id)
	if s then
		return "Estación: " .. s[2]
	end
	local d = Catalog.department(id)
	return d and d[2] or id
end

local function empRow(g: any, e: any): Frame
	local energyBar, fill = Ui.bar(e.energy, e.energy < 20 and T.re or (e.energy < 50 and T.ye or T.gr))
	local energyLabel = Ui.inline(math.floor(e.energy) .. "%", { size = Ui.S.xs, weight = W.bold })
	App.live(function(gg: any)
		for _, x in gg.employees do
			if x.id == e.id then
				Ui.setBar(fill, x.energy)
				energyLabel.Text = math.floor(x.energy) .. "%"
			end
		end
	end)
	local open = App.ui.assigning == e.id
	local options: { Instance? } = {}
	if open then
		local areas = { { "", "Sin asignar", 0 } }
		for _, s in Catalog.STATIONS do
			table.insert(areas, { s[1], s[2] .. (s[3] == e.role and " ★" or ""), Catalog.RULES.assignMax.station })
		end
		for _, d in Catalog.DEPARTMENTS do
			table.insert(areas, { d[1], d[2] .. (d[3] == e.role and " ★" or ""), Catalog.RULES.assignMax.dept })
		end
		for _, a in areas do
			local n = a[1] ~= "" and Rules.assignedCount(g, a[1], e.id) or 0
			local full = a[1] ~= "" and n >= a[3]
			table.insert(options, Ui.opt(a[2] .. (a[1] ~= "" and (" " .. n .. "/" .. a[3]) or ""), (e.assign or "") == a[1], function()
				App.ui.assigning = nil
				App.request("assign", { employeeId = e.id, area = a[1] })
			end, { height = 34, disabled = full, why = "Ese puesto está completo" }))
		end
	end
	return Ui.card({
		Ui.row({
			Ui.ico("user", T.pink, Color3.fromHex("#33182A"), 32),
			Ui.grow(Ui.col({
				Ui.text(e.name, { size = 15, weight = W.bold }),
				Ui.text(e.role .. " · nivel " .. e.level .. " · habilidad " .. e.skill .. " · " .. Util.money(e.salary) .. "/día", { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			Ui.chip(e.status == "descanso" and "Descansando" or areaLabel(e.assign), e.status == "descanso" and "cy" or (e.assign and "cg" or "cn")),
		}, 10),
		Ui.row({ Ui.inline("Energía", { size = Ui.S.xs, color = T.mut }), Ui.grow(energyBar, { Size = UDim2.new(0, 0, 0, 7) }), energyLabel }, 8),
		Ui.row({
			Ui.button(open and "Cerrar puestos" or "Asignar puesto", "default", function()
				App.ui.assigning = open and nil or e.id
				App.forceRender()
			end, { small = true, disabled = e.status == "descanso", why = "Está descansando" }),
			Ui.button(e.status == "descanso" and "Volver al trabajo" or "Dar descanso", "default", function()
				App.request("toggleRest", { employeeId = e.id })
			end, { small = true, disabled = e.status ~= "descanso" and e.energy >= 100, why = "Tiene la energía completa" }),
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
		}, 6, { wrap = true }),
		open and Ui.row(options, 6, { wrap = true }) or nil,
	}, { gap = 8, name = "Empleado_" .. e.id })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local tabs, tab = Sheet.tabs("personal", { { "team", "Equipo", #g.employees }, { "hire", "Contratar", #g.candidates } }, #g.employees > 0 and "team" or "hire")
	tabs.Parent = main
	if tab == "team" then
		if #g.employees == 0 then
			Ui.note("b", "Todavía no contrataste a nadie. Sin personal, las líneas trabajan al 50 %.", Ui.button("Ver candidatos", "p", function()
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
			b = Ui.button("Contratar · " .. Util.money(c.fee), "p", function()
				App.request("hire", { candidateId = c.id }, { button = b })
			end, { small = true, disabled = full or g.money < c.fee, why = full and "La sede está completa" or "Fondos insuficientes", name = "Contratar_" .. c.id })
			Ui.card({
				Ui.row({
					Ui.ico("user", T.pink, Color3.fromHex("#33182A"), 32),
					Ui.grow(Ui.col({
						Ui.text(c.name, { size = 15, weight = W.bold }),
						Ui.text(c.role .. " · nivel " .. c.level .. " · habilidad " .. c.skill .. " · salario " .. Util.money(c.salary) .. "/día", { size = Ui.S.xs, color = T.mut }),
					}, 2)),
					b,
				}, 10, { wrap = true }),
			}).Parent = main
		end
		local more
		more = Ui.button("Buscar más candidatos · " .. Util.money(Catalog.RULES.moreCandidatesCost), "default", function()
			App.request("moreCandidates", nil, { button = more })
		end, { small = true, disabled = g.money < Catalog.RULES.moreCandidatesCost, why = "Fondos insuficientes" })
		Ui.row({ more, Ui.text("Cada día de juego aparecen candidatos nuevos si quedan menos de 3.", { size = Ui.S.xs, color = T.mut }) }, 10, { wrap = true }).Parent = main
	end

	local rows: { Instance? } = { Ui.lbl("Áreas y efecto actual") }
	local function areaRow(id: string, label: string, role: string, effect: string, max: number)
		local n = Rules.assignedCount(g, id)
		table.insert(rows, Ui.line(label .. "  <font color=\"#7D8493\">· ideal " .. string.lower(role) .. " · " .. effect .. "</font>", n .. "/" .. max .. " · +" .. Util.num(Rules.staffBonus(g, id), 2), { size = Ui.S.xs }))
	end
	for _, s in Catalog.STATIONS do
		areaRow(s[1], s[2], s[3], "velocidad", Catalog.RULES.assignMax.station)
	end
	for _, d in Catalog.DEPARTMENTS do
		areaRow(d[1], d[2], d[3], string.lower(d[4]), Catalog.RULES.assignMax.dept)
	end
	table.insert(rows, Ui.text("El aporte es habilidad × afinidad (la mitad si no es el rol ideal o si está agotado). Estaciones: velocidad de la línea. Laboratorio: PI por día. Concesionario: interés de los clientes. Marketing: visitas. Estudio de diseño: −10 % de desarrollo por persona (hasta 30 %).", { size = Ui.S.xs, color = T.mut }))
	Ui.card(rows, { gap = 2 }).Parent = side
	Ui.card({
		Ui.lbl("Efecto en la producción"),
		Ui.line("Velocidad de las líneas", "×" .. Util.num(g.derived.lineSpeed, 2), { leftColor = T.mut }),
		Ui.line("PI por día", tostring(Rules.rpPerDay(g)), { leftColor = T.mut }),
		Ui.line("Salarios por día", Util.money(Rules.salaries(g)), { leftColor = T.mut, color = T.or_ }),
	}, { gap = 2 }).Parent = side
end

return Screen
