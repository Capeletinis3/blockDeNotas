--!strict
--[[
	Personal: reglas puras (sin servicios de Roblox) para departamentos, habilidades, productividad,
	bonificaciones con límite propio, salarios e indemnizaciones. Los valores están en Catalog.STAFF.

	Empleado = {
	  id, name, spec (departamento de especialidad), dept (departamento actual),
	  salary (mensual), skills = { [habilidad] = 0..100 }, potential = { [habilidad] = máximo individual },
	  months (meses trabajados: experiencia), hiredDay (día absoluto de ingreso: antigüedad),
	  adapt = { [departamento] = 0..1 } (adaptación fuera de su especialidad), status = "activo",
	  training = id de la capacitación activa o nil
	}
	No depende de Rules (Rules lo usa): las funciones que necesitan la fecha la reciben como parámetro.
]]

local Catalog = require(script.Parent.Catalog)
local Util = require(script.Parent.Util)

local Staff = {}

local S = Catalog.STAFF
Staff.DEPT_ORDER = {}
Staff.SKILL_ORDER = {}
for _, d in S.departments do
	table.insert(Staff.DEPT_ORDER, d.id)
	for _, k in d.skills do
		table.insert(Staff.SKILL_ORDER, k)
	end
end

function Staff.dept(id: any): any
	return Catalog.department(id)
end

function Staff.skill(id: any): any
	return type(id) == "string" and S.skills[id] or nil
end

-- Multiplicador de salarios y búsquedas por época (la economía crece con los años).
function Staff.eraMult(year: number): number
	return Catalog.interp(S.salaryEra, year)
end

-- Promedio de las habilidades de un departamento para un empleado.
function Staff.deptAverage(e: any, deptId: string): number
	local d = Staff.dept(deptId)
	if not d then
		return 0
	end
	local n = 0
	for _, k in d.skills do
		n += e.skills[k] or 0
	end
	return n / #d.skills
end

-- Salario mensual que corresponde a las habilidades del empleado en la época indicada.
function Staff.salaryFor(e: any, year: number): number
	local best = 0
	for _, id in Staff.DEPT_ORDER do
		best = math.max(best, Staff.deptAverage(e, id))
	end
	return Util.round((S.salaryBase + S.salaryPerPoint * best) * Staff.eraMult(year) / 10) * 10
end

-- Adaptación al departamento actual (1 en su especialidad).
function Staff.adaptation(e: any): number
	if e.dept == e.spec then
		return 1
	end
	return Util.clamp((e.adapt and e.adapt[e.dept]) or S.adaptStart, S.adaptStart, 1)
end

-- Productividad 0..1: adaptación × capacitación en curso × deuda salarial de la empresa.
function Staff.productivity(g: any, e: any): number
	local p = Staff.adaptation(e)
	if e.training ~= nil then
		p *= S.trainingProductivity
	end
	local months = (g.payroll and g.payroll.debtMonths) or 0
	if months > 0 then
		p *= math.max(S.debtProductivityFloor, 1 - S.debtProductivityPerMonth * months)
	end
	return p
end

-- Aporte de un empleado a una habilidad: solo cuenta en su departamento actual.
function Staff.contribution(g: any, e: any, skillId: string): number
	local sk = S.skills[skillId]
	if not sk or e.dept ~= sk.dept then
		return 0
	end
	return (e.skills[skillId] or 0) / 100 * sk.per * Staff.productivity(g, e)
end

-- Bonificación de la empresa para una habilidad: (valor con tope, suma sin tope, tope).
function Staff.bonusDetail(g: any, skillId: string, list: { any }?): (number, number, number)
	local sk = S.skills[skillId]
	if not sk then
		return 0, 0, 0
	end
	local raw = 0
	for _, e in list or g.employees or {} do
		raw += Staff.contribution(g, e, skillId)
	end
	return math.min(sk.cap, raw), raw, sk.cap
end

function Staff.bonus(g: any, skillId: string): number
	return (Staff.bonusDetail(g, skillId))
end

-- Cuánto mejoraría cada habilidad del departamento si se suma `cand` a ese departamento (respeta los topes).
function Staff.previewHire(g: any, cand: any, deptId: string): { any }
	local d = Staff.dept(deptId)
	local out = {}
	if not d then
		return out
	end
	local probe = Util.deepCopy(cand)
	probe.dept = deptId
	probe.spec = probe.spec or deptId
	probe.training = nil
	local list = table.clone(g.employees or {})
	table.insert(list, probe)
	for _, k in d.skills do
		local before = Staff.bonusDetail(g, k)
		local after, raw, cap = Staff.bonusDetail(g, k, list)
		table.insert(out, { skill = k, before = before, after = after, gain = after - before, raw = raw, cap = cap, capped = raw > cap + 1e-9 })
	end
	return out
end

-- Resumen de un departamento para la interfaz.
function Staff.deptSummary(g: any, deptId: string): any
	local d = Staff.dept(deptId)
	local members, salaries, perf = {}, 0, 0
	for _, e in g.employees or {} do
		if e.dept == deptId then
			table.insert(members, e)
			salaries += e.salary
			perf += Staff.productivity(g, e)
		end
	end
	local bonuses = {}
	for _, k in d.skills do
		local v, raw, cap = Staff.bonusDetail(g, k)
		table.insert(bonuses, { skill = k, value = v, raw = raw, cap = cap, full = raw >= cap - 1e-9 })
	end
	return { dept = d, members = members, count = #members, salaries = salaries, performance = #members > 0 and perf / #members or 0, bonuses = bonuses }
end

function Staff.salaries(g: any): number
	local n = 0
	for _, e in g.employees or {} do
		n += e.salary
	end
	return n
end

-- Indemnización = salario mensual × años trabajados (proporcional: 6 meses = medio salario).
function Staff.severance(e: any, today: number): number
	local days = math.max(0, today - (e.hiredDay or today))
	return Util.round(e.salary * days / 365)
end

-- Texto de un beneficio («+12 %» o «+4 pts»).
function Staff.format(skillId: string, v: number): string
	local sk = S.skills[skillId]
	if sk and sk.unit == "pts" then
		return "+" .. Util.num(v, 1) .. " pts"
	end
	return (v >= 0 and "+" or "") .. Util.num(v * 100, 1) .. " %"
end

-- Costo de la próxima búsqueda de candidatos del mes (el contador es compartido entre ambos tipos).
function Staff.searchCost(g: any, special: boolean, year: number): number
	local n = (g.market and g.market.searches) or 0
	local base = S.searchBase * Staff.eraMult(year) * (special and S.searchSpecialMult or 1)
	return Util.round(base * math.pow(S.searchGrowth, n))
end

-- Capacitaciones ---------------------------------------------------------------------------

function Staff.trainingLevel(id: any): any
	for _, l in Catalog.TRAINING.levels do
		if l.id == id then
			return l
		end
	end
	return nil
end

--[[ Plan de una capacitación (lo muestra la interfaz y lo cobra el servidor: mismo cálculo).
	req = { scope = "individual" | "departamento" | "general", level, skill, employeeId?, dept? }
	officeLevel = nivel de las oficinas centrales; year = año (escala el costo).
	Devuelve { members = { { id, name, from, to } }, cost, days, gain, level } o (nil, motivo).
	Solo participan quienes no están en otra capacitación y todavía pueden mejorar esa habilidad. ]]
function Staff.trainingPlan(g: any, req: any, officeLevel: number, year: number): (any?, string?)
	if type(req) ~= "table" then
		return nil, "Datos de la capacitación inválidos."
	end
	local lvl = Staff.trainingLevel(req.level)
	if not lvl then
		return nil, "Nivel de capacitación desconocido."
	end
	if officeLevel < lvl.office then
		return nil, "El nivel " .. lvl.name .. " requiere oficinas centrales de nivel " .. lvl.office .. " (Compañía › Instalaciones)."
	end
	local sk = Staff.skill(req.skill)
	if not sk then
		return nil, "Elegí la habilidad a mejorar."
	end
	local pool = {}
	if req.scope == "individual" then
		for _, e in g.employees do
			if e.id == req.employeeId then
				table.insert(pool, e)
			end
		end
		if #pool == 0 then
			return nil, "Ese empleado ya no está."
		end
		if pool[1].training ~= nil then
			return nil, pool[1].name .. " ya está en una capacitación."
		end
	elseif req.scope == "departamento" then
		if not Staff.dept(req.dept) then
			return nil, "Departamento desconocido."
		end
		for _, e in g.employees do
			if e.dept == req.dept then
				table.insert(pool, e)
			end
		end
	elseif req.scope == "general" then
		pool = table.clone(g.employees)
	else
		return nil, "Tipo de capacitación desconocido."
	end
	local members = {}
	for _, e in pool do
		local from, pot = e.skills[req.skill] or 0, e.potential[req.skill] or 0
		if e.training == nil and from < pot then
			table.insert(members, { id = e.id, name = e.name, from = from, to = math.min(pot, from + lvl.gain) })
		end
	end
	if #members == 0 then
		return nil, "Nadie puede hacer esta capacitación: ya están en otra o llegaron a su potencial en " .. sk.name .. "."
	end
	local cost = Util.round(lvl.cost * #members * Staff.eraMult(year) / 10) * 10
	return { members = members, cost = cost, days = lvl.days, gain = lvl.gain, level = lvl }, nil
end

return Staff
