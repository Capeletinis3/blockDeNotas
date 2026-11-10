--!strict
--[[ Personal: cuatro departamentos (Producción, Investigación, Marketing y Administración).
	- Inicio: una tarjeta por departamento con empleados, salarios, rendimiento y bonificaciones.
	- Departamento: lista de empleados a la izquierda y detalle del elegido a la derecha (habilidades con su
	  potencial, productividad, cambio de departamento, capacitación e indemnización).
	- Mercado laboral: los 8 candidatos del mes con la mejora real que aportarían (con los topes) y las
	  búsquedas pagas. Todo lo valida el servidor (Actions.hire / setDept / fire / searchCandidates). ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)
local Staff = require(Shared.Staff)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Personal",
	icon = "users",
	color = Color3.fromHex("#FF9DC1"),
	bg = Color3.fromHex("#33182A"),
}

local function st(): any
	App.ui.staff = App.ui.staff or { view = "inicio", dept = "produccion", sel = nil, hireDept = {} }
	return App.ui.staff
end

local function go(view: string, dept: string?)
	local s = st()
	s.view = view
	if dept then
		s.dept = dept
		s.sel = nil
	end
	App.forceRender()
end

function Screen.head(g: any): { Instance }
	local out = { Ui.chip(#g.employees .. "/" .. g.derived.caps.staff .. " empleados", "cn"), Ui.chip("Salarios " .. Util.money(Rules.salaries(g)) .. "/mes", "cy") }
	if g.payroll and g.payroll.debt > 0 then
		table.insert(out, Ui.chip("Deuda salarial " .. Util.money(g.payroll.debt), "cr"))
	end
	return out
end

-- Barra de una bonificación: actual / máxima, con aviso al llegar al tope.
local function bonusRow(b: any): Frame
	local sk = Staff.skill(b.skill)
	local pct = b.cap > 0 and b.value / b.cap * 100 or 0
	local bar = Ui.bar(pct, b.full and T.gr or T.vi)
	return Ui.col({
		Ui.row({
			Ui.grow(Ui.text(sk.name .. " <font color=\"#A3AAB8\" size=\"11\">· " .. sk.effect .. "</font>", { size = Ui.S.sm })),
			Ui.inline(Staff.format(b.skill, b.value) .. " / " .. Staff.format(b.skill, b.cap), { size = Ui.S.xs, weight = W.bold }),
		}, 8),
		bar,
		b.full and Ui.text("Límite alcanzado: más personal en esta habilidad no suma.", { size = Ui.S.xs, color = T.gr }) or nil,
	}, 4, { Name = "Bono_" .. b.skill })
end

local function deptCard(g: any, deptId: string): Frame
	local sum = Staff.deptSummary(g, deptId)
	local d = sum.dept
	local rows: { Instance? } = {
		Ui.row({
			Ui.ico(d.icon, Color3.fromHex(d.color), Color3.fromHex(d.color), 34, { alpha = 0.15, iconSize = 17 }),
			Ui.grow(Ui.col({
				Ui.text(d.name, { size = 17, weight = W.bold }),
				Ui.text(sum.count .. (sum.count == 1 and " empleado" or " empleados") .. " · " .. Util.money(sum.salaries) .. "/mes · rendimiento " .. (sum.count > 0 and (Util.round(sum.performance * 100) .. " %") or "—"), { size = Ui.S.xs, color = T.mut }),
			}, 2)),
		}, 10),
	}
	for _, b in sum.bonuses do
		table.insert(rows, bonusRow(b))
	end
	table.insert(rows, Ui.button("Ver departamento", "default", function()
		go("depto", deptId)
	end, { small = true, fill = true, name = "Depto_" .. deptId }))
	return Ui.card(rows, { gap = 8, name = "Tarjeta_" .. deptId })
end

local function skillLines(e: any, deptId: string): { Instance }
	local out = {}
	for _, k in Staff.dept(deptId).skills do
		local v, pot = e.skills[k] or 0, e.potential[k] or 0
		table.insert(out, Ui.row({
			Ui.grow(Ui.text(Staff.skill(k).name, { size = Ui.S.sm })),
			Ui.inline(v .. " / " .. pot, { size = Ui.S.xs, weight = W.bold, color = v >= pot and T.ye or T.tx }),
		}, 8, { Name = "Hab_" .. k }))
	end
	return out
end

local function employeeDetail(g: any, e: any): Frame
	local today = Rules.absDay(g)
	local prod = Staff.productivity(g, e)
	local rows: { Instance? } = {
		Ui.text(e.name, { size = 18, weight = W.bold }),
		Ui.text("Especialidad: " .. Staff.dept(e.spec).name .. " · trabaja en " .. Staff.dept(e.dept).name, { size = Ui.S.xs, color = T.mut }),
		Ui.text(Util.money(e.salary) .. "/mes · " .. e.months .. " meses de experiencia · productividad " .. Util.round(prod * 100) .. " %" .. (e.dept ~= e.spec and (" (adaptación " .. Util.round(Staff.adaptation(e) * 100) .. " %)") or "") .. (e.training and " · capacitándose" or ""), { size = Ui.S.xs, color = T.mut }),
	}
	-- Aporte individual a cada beneficio de su departamento actual.
	table.insert(rows, Ui.lbl("Aporte a " .. Staff.dept(e.dept).name))
	for _, k in Staff.dept(e.dept).skills do
		table.insert(rows, Ui.row({ Ui.grow(Ui.text(Staff.skill(k).name, { size = Ui.S.sm })), Ui.inline(Staff.format(k, Staff.contribution(g, e, k)), { size = Ui.S.xs, weight = W.bold }) }, 8))
	end
	table.insert(rows, Ui.lbl("Habilidades (actual / potencial)"))
	for _, id in Staff.DEPT_ORDER do
		table.insert(rows, Ui.text(Staff.dept(id).name, { size = Ui.S.xs, weight = W.bold, color = T.mut }))
		for _, line in skillLines(e, id) do
			table.insert(rows, line)
		end
	end
	local options = {}
	for _, id in Staff.DEPT_ORDER do
		table.insert(options, { id, Staff.dept(id).name .. (id == e.spec and " ★" or "") })
	end
	local total, sev, unpaid = Staff.dismissalCost(g, e, today)
	table.insert(rows, Ui.selectF("Departamento", e.dept, options, function(v: any)
		App.request("setDept", { employeeId = e.id, dept = v })
	end, { height = 34, name = "Departamento_" .. e.id }))
	table.insert(rows, Ui.button("Capacitar", "default", function()
		App.openDialog("training", { scope = "individual", employeeId = e.id, dept = e.dept })
	end, { small = true, fill = true, disabled = e.training ~= nil, why = "Ya está en una capacitación", name = "Capacitar_" .. e.id }))
	table.insert(rows, Ui.button("Despedir · " .. Util.money(total), "q", function()
		App.openDialog("confirm", {
			title = "¿Despedir a " .. e.name .. "?",
			body = "Se paga la indemnización: " .. Util.money(e.salary) .. " por año trabajado (proporcional) = " .. Util.money(sev) .. "." .. (unpaid > 0 and (" Además, el sueldo de los días trabajados desde que entró: " .. Util.money(unpaid) .. ".") or "") .. " No se puede deshacer.",
			okLabel = "Despedir",
			danger = true,
			onOk = function()
				App.request("fire", { employeeId = e.id })
			end,
		})
	end, { small = true, fill = true, disabled = g.money < total, why = "No alcanza para la indemnización", name = "Despedir_" .. e.id }))
	return Ui.card(rows, { gap = 6, name = "Detalle_" .. e.id })
end

local function candidateCard(g: any, c: any, full: boolean): Frame
	local s = st()
	local dept = s.hireDept[c.id] or c.spec
	local options = {}
	for _, id in Staff.DEPT_ORDER do
		table.insert(options, { id, Staff.dept(id).name .. (id == c.spec and " ★" or "") })
	end
	local gains: { Instance? } = {}
	for _, p in Staff.previewHire(g, c, dept) do
		table.insert(gains, Ui.row({
			Ui.grow(Ui.text(Staff.skill(p.skill).name, { size = Ui.S.xs })),
			Ui.inline(Staff.format(p.skill, p.gain) .. (p.capped and " (tope)" or ""), { size = Ui.S.xs, weight = W.bold, color = p.gain > 0 and T.gr or T.mut }),
		}, 6))
	end
	local b
	b = Ui.button("Contratar", "p", function()
		App.request("hire", { candidateId = c.id, dept = dept }, { button = b })
	end, { small = true, fill = true, disabled = full, why = "Límite de empleados", name = "Contratar_" .. c.id })
	local rows: { Instance? } = {
		Ui.row({ Ui.grow(Ui.text(c.name, { size = Ui.S.base, weight = W.bold })), c.exceptional and Ui.chip("Extraordinario", "cg") or nil }, 6),
		Ui.text(Staff.dept(c.spec).name .. " · " .. Util.money(c.salary) .. "/mes · sin costo de contratación", { size = Ui.S.xs, color = T.mut }),
	}
	for _, line in skillLines(c, c.spec) do
		table.insert(rows, line)
	end
	table.insert(rows, Ui.selectF("Asignar a", dept, options, function(v: any)
		s.hireDept[c.id] = v
		App.forceRender()
	end, { height = 32, name = "AsignarA_" .. c.id }))
	table.insert(rows, Ui.lbl("Mejora real del departamento"))
	for _, x in gains do
		table.insert(rows, x)
	end
	if dept ~= c.spec then
		table.insert(rows, Ui.text("Fuera de su especialidad empieza al " .. Util.round(Catalog.STAFF.adaptStart * 100) .. " % y se adapta con el tiempo.", { size = Ui.S.xs, color = T.ye }))
	end
	table.insert(rows, b)
	return Ui.card(rows, { gap = 6, name = "Candidato_" .. c.id })
end

local function searchButton(g: any, special: boolean): Frame
	local s = st()
	local cost = Staff.searchCost(g, special, Rules.year(g))
	return Ui.button((special and ("Búsqueda especializada · " .. Staff.dept(s.dept).name) or "Búsqueda general") .. " · " .. Util.money(cost), special and "default" or "p", function()
		App.openDialog("confirm", {
			title = special and "¿Búsqueda especializada?" or "¿Búsqueda general?",
			body = "Los " .. #g.candidates .. " candidatos actuales que no contrataste se reemplazan por 8 nuevos" .. (special and (" (cada uno con 50 % de chance de ser de " .. Staff.dept(s.dept).name .. ", sin mínimo garantizado)") or " de cualquier departamento") .. ". Cuesta " .. Util.money(cost) .. "; la siguiente del mes costará 50 % más.",
			okLabel = "Buscar",
			onOk = function()
				App.request("searchCandidates", { kind = special and "especializada" or "general", dept = s.dept })
			end,
		})
	end, { small = true, disabled = g.money < cost, why = "Fondos insuficientes", name = special and "BusquedaEspecial" or "BusquedaGeneral" })
end

-- Capacitaciones en curso y acceso a una capacitación general.
function Screen.trainings(g: any, main: Frame, side: Frame)
	local list = g.trainings or {}
	if #list == 0 then
		Ui.empty("flask", "No hay capacitaciones en curso. Podés capacitar a una persona (desde su detalle), a un departamento o a toda la empresa.").Parent = main
	end
	for _, t in list do
		local lvl = Staff.trainingLevel(t.level)
		local names = {}
		for _, id in t.members do
			for _, e in g.employees do
				if e.id == id then
					table.insert(names, e.name .. " (" .. (e.skills[t.skill] or 0) .. " → " .. (t.results[id] or 0) .. ")")
				end
			end
		end
		local bar = Ui.bar(t.progress / t.days * 100, T.vi)
		Ui.card({
			Ui.row({ Ui.grow(Ui.text(lvl.name .. " · " .. Staff.skill(t.skill).name, { size = Ui.S.base, weight = W.bold })), Ui.chip(math.floor(t.progress) .. "/" .. t.days .. " días", "cv") }, 8),
			bar,
			Ui.text(table.concat(names, " · "), { size = Ui.S.xs, color = T.mut, lineHeight = 1.4 }),
		}, { gap = 6, name = "Capacitacion_" .. t.id }).Parent = main
	end
	local office = Rules.officeLevel(g)
	local rows: { Instance? } = { Ui.lbl("Niveles") }
	for _, l in Catalog.TRAINING.levels do
		local open = office >= l.office
		table.insert(rows, Ui.row({
			Ui.grow(Ui.text(l.name .. " · +" .. l.gain .. " · " .. l.days .. " días · " .. Util.money(Util.round(l.cost * Staff.eraMult(Rules.year(g)) / 10) * 10) .. " por persona", { size = Ui.S.xs })),
			Ui.chip(open and "Disponible" or ("Oficinas nivel " .. l.office), open and "cg" or "cy"),
		}, 6))
	end
	table.insert(rows, Ui.button("Capacitación general", "p", function()
		App.openDialog("training", { scope = "general" })
	end, { small = true, fill = true, disabled = #g.employees == 0, why = "Sin empleados", name = "CapacitacionGeneral" }))
	Ui.card(rows, { gap = 6 }).Parent = side
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local s = st()
	local full = #g.employees >= g.derived.caps.staff
	local nav = Ui.row({
		Ui.opt("Departamentos", s.view ~= "mercado", function()
			go(s.view == "mercado" and "inicio" or s.view)
		end, { name = "VerDepartamentos", height = 34 }),
		Ui.opt("Mercado laboral · " .. #g.candidates, s.view == "mercado", function()
			go("mercado")
		end, { name = "MercadoLaboral", height = 34 }),
		Ui.opt("Capacitaciones · " .. #(g.trainings or {}), s.view == "capacitaciones", function()
			go("capacitaciones")
		end, { name = "Capacitaciones", height = 34 }),
	}, 8, { wrap = true })
	nav.Parent = main
	if g.payroll and g.payroll.debt > 0 then
		Ui.note("r", "Deuda salarial: " .. Util.money(g.payroll.debt) .. ". El " .. Util.round(Catalog.STAFF.debtRecoveryShare * 100) .. " % de cada venta se destina a pagarla. Con deuda, la productividad baja " .. Util.round(Catalog.STAFF.debtProductivityPerMonth * 100) .. " % por mes (los empleados no renuncian).").Parent = main
	end
	if full then
		Ui.note("y", "Llegaste al límite de " .. g.derived.caps.staff .. " empleados. Mejorá las oficinas centrales (Compañía › Instalaciones) para contratar más.").Parent = main
	end

	if s.view == "mercado" then
		Ui.text("Cada mes llegan " .. Catalog.STAFF.candidatesPerMonth .. " candidatos nuevos y los que no contrataste se van. Contratar no tiene costo: se paga el salario mensual.", { size = Ui.S.xs, color = T.mut }).Parent = main
		local cards = {}
		for _, c in g.candidates do
			table.insert(cards, candidateCard(g, c, full))
		end
		if #cards > 0 then
			Ui.grid(cards, App.isPhone() and 1 or 2, nil, 10).Parent = main
		else
			Ui.empty("users", "No quedan candidatos este mes. Llegan 8 nuevos al empezar el próximo, o hacé una búsqueda.").Parent = main
		end
		local options = {}
		for _, id in Staff.DEPT_ORDER do
			table.insert(options, { id, Staff.dept(id).name })
		end
		Ui.card({
			Ui.lbl("Búsquedas pagas"),
			searchButton(g, false),
			Ui.selectF("Departamento de la búsqueda especializada", s.dept, options, function(v: any)
				s.dept = v
				App.forceRender()
			end, { height = 32, name = "DeptoBusqueda" }),
			searchButton(g, true),
			Ui.text("Búsquedas este mes: " .. ((g.market and g.market.searches) or 0) .. ". Cada una cuesta 50 % más que la anterior; el contador vuelve a cero cada mes.", { size = Ui.S.xs, color = T.mut }),
		}, { gap = 8, name = "Busquedas" }).Parent = side
		return
	end
	if s.view == "capacitaciones" and Screen.trainings then
		Screen.trainings(g, main, side)
		return
	end
	if s.view == "depto" then
		local sum = Staff.deptSummary(g, s.dept)
		Ui.row({
			Ui.button("‹ Departamentos", "default", function()
				go("inicio")
			end, { small = true, name = "VolverDeptos" }),
			Ui.grow(Ui.text(sum.dept.name, { size = 19, weight = W.bold })),
			Ui.button("Capacitar al departamento", "default", function()
				App.openDialog("training", { scope = "departamento", dept = s.dept })
			end, { small = true, disabled = sum.count == 0, why = "Sin empleados", name = "CapacitarDepto" }),
		}, 10, { wrap = true }).Parent = main
		local list = {}
		for _, e in sum.members do
			local on = s.sel == e.id
			table.insert(list, Ui.opt(e.name .. " · " .. Util.round(Staff.productivity(g, e) * 100) .. " %" .. (e.dept ~= e.spec and " · adaptándose" or "") .. (e.training and " · en capacitación" or ""), on, function()
				s.sel = e.id
				App.forceRender()
			end, { name = "Empleado_" .. e.id, fill = true, height = 36 }))
		end
		if #list == 0 then
			Ui.empty("users", "No hay nadie en " .. sum.dept.name .. ". El juego funciona sin personal; contratar mejora las operaciones.", Ui.button("Abrir el mercado laboral", "p", function()
				go("mercado")
			end, { small = true })).Parent = main
		else
			local sel
			for _, e in sum.members do
				if e.id == s.sel then
					sel = e
				end
			end
			sel = sel or sum.members[1]
			s.sel = sel.id
			local cols = App.isPhone() and 1 or 2
			Ui.grid({ Ui.col(list, 6, { Name = "ListaEmpleados" }), employeeDetail(g, sel) }, cols, nil, 12).Parent = main
		end
		local rows: { Instance? } = { Ui.lbl("Bonificaciones de " .. sum.dept.name) }
		for _, b in sum.bonuses do
			table.insert(rows, bonusRow(b))
		end
		Ui.card(rows, { gap = 8, name = "BonosDepto" }).Parent = side
		return
	end
	-- Inicio: las cuatro tarjetas.
	local cards = {}
	for _, id in Staff.DEPT_ORDER do
		table.insert(cards, deptCard(g, id))
	end
	Ui.grid(cards, App.isPhone() and 1 or 2, nil, 12).Parent = main
	Ui.card({
		Ui.lbl("Mercado laboral"),
		Ui.text(#g.candidates .. " candidatos este mes.", { size = Ui.S.sm }),
		Ui.button("Abrir el mercado laboral", "p", function()
			go("mercado")
		end, { small = true, fill = true, name = "AbrirMercado" }),
		Ui.text("Las bonificaciones se suman, pero cada beneficio tiene su propio límite. Se aplican enseguida también a lo que ya está en curso, sin devolver gastos ya pagados.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.4 }),
	}, { gap = 8 }).Parent = side
end

return Screen
