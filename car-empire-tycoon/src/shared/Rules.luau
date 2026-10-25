--!strict
--[[
	Reglas derivadas de una partida (capacidades, velocidad de la línea, personal, misiones,
	investigación y finanzas). Son funciones puras: el servidor las usa para validar y el cliente
	para mostrar exactamente las mismas cifras. Ninguna modifica la partida.
]]

local Catalog = require(script.Parent.Catalog)
local Util = require(script.Parent.Util)

local Rules = {}

function Rules.has(g: any, researchId: string?): boolean
	if not researchId then
		return true
	end
	return g ~= nil and g.research ~= nil and Util.contains(g.research.done, researchId)
end

function Rules.sede(g: any): any
	return Catalog.SEDES[Util.clamp(g.sede or 1, 1, #Catalog.SEDES)]
end

function Rules.caps(g: any): any
	local s = Rules.sede(g)
	return {
		warehouse = s.warehouse + (Rules.has(g, "l1") and 4 or 0),
		showroom = s.showroom + (Rules.has(g, "mk3") and 2 or 0),
		mats = s.mats,
		lines = s.lines,
		staff = s.staff,
	}
end

-- Almacén (regla única): unidades terminadas que esperan (almacén, reservadas o publicadas en el
-- mercado) + lugares reservados por las unidades que se están fabricando.
function Rules.warehouseFinished(g: any): number
	local n = 0
	for _, u in g.units do
		if u.status == "almacen" or u.status == "reservado" or u.status == "mercado" then
			n += 1
		end
	end
	return n
end

function Rules.inProgress(g: any): number
	local n = 0
	for _, o in g.production.orders do
		if o.unitStarted then
			n += 1
		end
	end
	return n
end

function Rules.warehouseUsed(g: any): number
	return Rules.warehouseFinished(g) + Rules.inProgress(g)
end

function Rules.showroomUsed(g: any): number
	local n = 0
	for _, u in g.units do
		if u.status == "salon" then
			n += 1
		end
	end
	return n
end

-- Depósito de materiales (regla única): lo guardado + lo que tiene una unidad en fabricación
-- (si se cancela, vuelve al depósito sin exceder su capacidad).
function Rules.matsStored(g: any): number
	local n = 0
	for _, v in g.materials do
		n += v
	end
	return n
end

function Rules.matsInProcess(g: any): number
	local n = 0
	for _, o in g.production.orders do
		if o.unitStarted and o.cur and o.cur.mats then
			for _, v in o.cur.mats do
				n += v
			end
		end
	end
	return n
end

function Rules.matsUsed(g: any): number
	return Rules.matsStored(g) + Rules.matsInProcess(g)
end

function Rules.xpForLevel(l: number): number
	return Util.round(400 * math.pow(l, 1.35))
end

function Rules.absMinute(g: any): number
	return g.time.day * Catalog.RULES.dayMinutes + g.time.minute
end

-- Personal ---------------------------------------------------------------------

-- Aporte de un puesto: habilidad × afinidad (la mitad si no es el rol ideal o si está agotado).
function Rules.staffBonus(g: any, area: string): number
	local st = Catalog.station(area) or Catalog.department(area)
	local want = st and st[3] or nil
	local total = 0
	for _, e in g.employees or {} do
		if e.assign == area and e.status == "activo" then
			total += (e.skill / 100) * (e.role == want and 1 or 0.5) * (e.energy < 20 and 0.5 or 1)
		end
	end
	return total
end

function Rules.assignedCount(g: any, area: string, exceptId: string?): number
	local n = 0
	for _, e in g.employees or {} do
		if e.assign == area and e.id ~= exceptId then
			n += 1
		end
	end
	return n
end

function Rules.salaries(g: any): number
	local n = 0
	for _, e in g.employees or {} do
		n += e.salary
	end
	return n
end

-- Producción ---------------------------------------------------------------------

function Rules.stationStaff(g: any): number
	local staff = 0
	for _, st in Catalog.STATIONS do
		staff += Rules.staffBonus(g, st[1])
	end
	return staff
end

-- Velocidad de las líneas (V3: lineSpeed). La aceleración duplica la velocidad.
function Rules.lineSpeed(g: any, ignoreBoost: boolean?): number
	local lv = 0
	for _, st in Catalog.STATIONS do
		lv += g.stations[st[1]].level
	end
	lv /= #Catalog.STATIONS
	local staff = Rules.stationStaff(g)
	local s = (staff > 0 and 1 or Catalog.RULES.noStaffSpeed) * (1 + 0.15 * (lv - 1)) * (1 + math.min(1.2, staff * 0.25))
	if Rules.has(g, "p1") then
		s *= 1.1
	end
	if Rules.has(g, "p2") then
		s *= 1.2
	end
	if g.production.boost and not ignoreBoost then
		s *= 2
	end
	return s
end

function Rules.brokenStation(g: any): any
	for _, st in Catalog.STATIONS do
		if g.stations[st[1]].broken then
			return st
		end
	end
	return nil
end

function Rules.maxStationLevel(g: any): number
	return math.min(5, (g.sede or 1) + 1)
end

function Rules.upgradeCost(s: any): number
	return 6000 * s.level * s.level
end

function Rules.maintCost(s: any): number
	if s.broken then
		return Catalog.RULES.repairPerLevel * s.level
	end
	return Util.round(Catalog.RULES.repairPerLevel * s.level * (100 - s.condition) / 100 / 100) * 100
end

function Rules.unitCostFactor(g: any): number
	return g.production.boost and Catalog.RULES.boostCostFactor or 1
end

-- Precio del proveedor de materiales (con −10 % de «Compras al por mayor») + impuesto.
function Rules.supplierPrice(g: any, mat: string, qty: number): any
	local m = Catalog.material(mat)
	local base = Util.round(m[3] * qty * (Rules.has(g, "l2") and 0.9 or 1))
	local tax = Util.round(base * Catalog.RULES.taxRate)
	return { base = base, tax = tax, total = base + tax }
end

function Rules.wholesale(u: any): number
	return Util.round(u.cost * Catalog.RULES.wholesaleFactor / 100) * 100
end

function Rules.finalPrice(u: any): number
	return Util.round(u.price * (1 - Util.clamp(u.discount or 0, 0, Catalog.RULES.maxDiscount) / 100))
end

-- Interés (0–100) de un cliente por una unidad (V3: unitInterest). Sin cliente da la demanda general.
function Rules.interest(g: any, u: any, c: any?): number
	local st = u.stats
	local base = Catalog.base(u.spec.baseId)
	local i = 45 + (st.quality - 60) * 0.6 + base.pop * 10 + g.reputation * 3
	if c and c.wants == u.type then
		i += 15
	end
	if c and Catalog.OBJECTIVES[u.spec.objective] == c.pref then
		i += 8
	end
	i += ((Catalog.SEGMENTS[u.spec.segment] or Catalog.SEGMENTS.Masivo).pop - 1) * 20
	if c and c.pref == "potencia" then
		i += (st.hp - 250) / 15
	end
	if c and c.pref == "economia" then
		i += (8 - st.consumption) * 3
	end
	if c and c.pref == "comodidad" then
		i += (st.comfort - 65) / 2
	end
	if c and c.pref == "estilo" then
		i += (u.spec.paint.finish ~= "Mate" and 4 or 0) + (u.spec.spoiler and 3 or 0)
	end
	-- Precio: más caro que el recomendado baja el interés; un descuento lo sube.
	local ratio = Rules.finalPrice(u) / math.max(1, st.price)
	i -= (ratio - 1) * 60
	i += Rules.staffBonus(g, "ventas") * 6
	return Util.clamp(Util.round(i), 5, 98)
end

-- Investigación -------------------------------------------------------------------

function Rules.researchMissing(g: any, n: any): { string }
	local m = {}
	for _, r in n.req do
		if not Rules.has(g, r) then
			table.insert(m, "Investigar «" .. Catalog.researchNode(r).name .. "»")
		end
	end
	if (g.sede or 1) < n.lab then
		table.insert(m, "Laboratorio nivel " .. n.lab .. " (sede " .. Catalog.SEDES[n.lab].name .. ")")
	end
	return m
end

function Rules.researchState(g: any, n: any): string
	if Rules.has(g, n.id) then
		return "hecha"
	end
	if g.research.active and g.research.active.id == n.id then
		return "activa"
	end
	return #Rules.researchMissing(g, n) > 0 and "bloqueada" or "disponible"
end

function Rules.rpPerDay(g: any): number
	return 15 + Util.round(Rules.staffBonus(g, "laboratorio") * 25)
end

-- Estadísticas por día --------------------------------------------------------------

function Rules.dayKey(day: number): string
	return tostring(math.floor(day))
end

function Rules.dayStats(g: any, day: number): any
	return g.stats.days[Rules.dayKey(day)]
end

local EMPTY_DAY = { revenue = 0, cogs = 0, units = 0, fees = 0, margin = 0, produced = 0, flow = {} }

-- Agrupa los movimientos de caja como la V3 (finance): costo de lo vendido y margen salen de las ventas,
-- gastos operativos e inversiones salen del flujo por tipo. Los agregados diarios se guardan aparte
-- del historial recortado, así que un período nunca queda incompleto.
function Rules.finance(g: any, days: number): any
	local from = g.time.day - days + 1
	local f = { days = days, from = from, revenue = 0, cogs = 0, units = 0, fees = 0, margin = 0, cash = 0, inflow = 0, outflow = 0, produced = 0, byType = {}, series = {} }
	for d = from, g.time.day do
		local ds = (d >= 0 and g.stats.days[Rules.dayKey(d)]) or EMPTY_DAY
		f.revenue += ds.revenue
		f.cogs += ds.cogs
		f.units += ds.units
		f.fees += ds.fees
		f.margin += ds.margin
		f.produced += ds.produced or 0
		local dayCash = 0
		for kind, amount in ds.flow do
			f.byType[kind] = (f.byType[kind] or 0) + amount
			dayCash += amount
			if amount >= 0 then
				f.inflow += amount
			else
				f.outflow += amount
			end
		end
		f.cash += dayCash
		table.insert(f.series, { day = d, revenue = ds.revenue, cash = dayCash, units = ds.units })
	end
	local function spent(kinds: { string }): number
		local n = 0
		for _, k in kinds do
			n -= math.min(0, f.byType[k] or 0)
		end
		return n
	end
	f.opex = { salarios = spent({ "salarios" }), promocion = spent({ "promocion" }), mantenimiento = spent({ "mantenimiento" }), comisiones = spent({ "comision" }) }
	f.invest = { desarrollo = spent({ "desarrollo" }), investigacion = spent({ "investigacion" }), mejoras = spent({ "mejora", "sede" }), contratacion = spent({ "contratacion" }) }
	f.purchases = spent({ "compra", "materiales" })
	f.taxes = spent({ "impuesto" })
	f.manufacturing = spent({ "fabricacion" })
	f.opProfit = f.margin - f.opex.salarios - f.opex.promocion - f.opex.mantenimiento - f.opex.comisiones
	return f
end

-- Misiones ----------------------------------------------------------------------------

function Rules.missionValue(g: any, m: any): number
	local today = Rules.dayStats(g, g.time.day) or EMPTY_DAY
	if m.counter == "soldToday" then
		return today.units
	elseif m.counter == "producedToday" then
		return today.produced or 0
	elseif m.counter == "marginToday" then
		return math.max(0, today.margin)
	elseif m.counter == "sedeLevel" then
		return g.sede
	end
	return g.counters[m.counter] or 0
end

function Rules.missionKey(g: any, m: any): string
	return m.kind == "diaria" and (m.id .. "@" .. g.time.day) or m.id
end

function Rules.missionState(g: any, m: any): string
	if g.claimed[Rules.missionKey(g, m)] then
		return "reclamada"
	end
	return Rules.missionValue(g, m) >= m.goal and "lista" or "progreso"
end

function Rules.currentTutorial(g: any): any
	for _, m in Catalog.MISSIONS do
		if m.kind == "tutorial" and Rules.missionState(g, m) ~= "reclamada" then
			return m
		end
	end
	return nil
end

function Rules.readyMissions(g: any): number
	local n = 0
	for _, m in Catalog.MISSIONS do
		if Rules.missionState(g, m) == "lista" then
			n += 1
		end
	end
	return n
end

function Rules.rewardText(r: any): string
	local parts = {}
	if r.money then
		table.insert(parts, "+" .. Util.money(r.money))
	end
	if r.gems then
		table.insert(parts, "+" .. r.gems .. " gemas")
	end
	if r.xp then
		table.insert(parts, "+" .. r.xp .. " XP")
	end
	return table.concat(parts, " · ")
end

-- Ampliación de sede ---------------------------------------------------------------------

function Rules.nextSede(g: any): any
	return Catalog.SEDES[(g.sede or 1) + 1]
end

function Rules.expandChecks(g: any): { any }
	local next = Rules.nextSede(g)
	if not next then
		return {}
	end
	return {
		{ g.counters.unitsSold >= next.req.sold, "Autos vendidos: " .. g.counters.unitsSold .. "/" .. next.req.sold },
		{ g.reputation >= next.req.rep, "Reputación: " .. Util.num(g.reputation, 1) .. "/" .. Util.num(next.req.rep, 1) },
		{ g.money >= next.cost, "Dinero: " .. Util.money(g.money) .. " / " .. Util.money(next.cost) },
	}
end

return Rules
