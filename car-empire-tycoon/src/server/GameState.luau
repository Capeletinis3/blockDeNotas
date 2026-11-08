--!strict
--[[
	Estado de una empresa y del perfil del jugador: creación, validación estricta, migración por versiones
	y la vista que se envía al cliente. Módulo puro (sin servicios de Roblox), probado con Lune.

	Perfil guardado (un registro por jugador):
	  { slots = { ["1"] = partida, … ["4"] = … }, active = "1" | nil, settings = {…}, processed = { ids },
	    unlocked = { ["3"] = true }, receipts = { PurchaseId } }   -- ranuras 3 y 4: compra por separado (Robux)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)
local Staff = require(Shared.Staff)

local GameState = {}

GameState.SCHEMA = 12

-- Estados de un lote. Producción: en cola / produciendo / sin fondos / pausado / completado / cancelado.
-- Comercialización: en producción (todavía no se vende) / por lanzar (fabricado y con reseñas, espera el precio)
-- / en venta / agotado / retirado. Los tres primeros son lotes activos (g.lots); los otros, historial.
GameState.PROD_STATES = { cola = true, produciendo = true, ["sin fondos"] = true, pausado = true, completado = true, cancelado = true }
GameState.SALE_STATES = { produccion = true, ["por lanzar"] = true, ["en venta"] = true, agotado = true, retirado = true }
GameState.ACTIVE_SALE = { produccion = true, ["por lanzar"] = true, ["en venta"] = true }
GameState.DEFAULT_SETTINGS = { sound = true, reduceMotion = false, keyHints = true, textScale = 1, camSpeed = 1, tips = true, shadows = true }

local function freshStations(): any
	local out = {}
	for _, st in Catalog.STATIONS do
		out[st[1]] = { level = 1 }
	end
	return out
end

-- Récords permanentes de la empresa: se actualizan al cerrar cada lote y no se recortan nunca.
-- others = modelos con pocas ventas que se resumieron en un total para que la partida no crezca sin límite.
function GameState.newRecords(): any
	return { others = { models = 0, lots = 0, produced = 0, sold = 0, discarded = 0, revenue = 0, cost = 0 } }
end

function GameState.newGame(opts: { name: string, color: string, logo: string?, now: number }): any
	return {
		schema = GameState.SCHEMA,
		createdAt = opts.now,
		lastPlayed = opts.now,
		playedSeconds = 0,
		nextId = 1,
		-- id: identificador estable de la empresa (no cambia al renombrarla ni al moverla de ranura).
		company = { id = opts.id or ("c" .. tostring(opts.now)), name = opts.name, color = opts.color, logo = opts.logo or "pico" },
		sede = 1,
		expansion = 0, -- regiones abiertas de la expansión global (después del Imperio automotriz)
		money = Catalog.START.money, -- todas las empresas empiezan igual
		gems = 0, -- sin uso por ahora: se conserva por compatibilidad y no se muestra
		rp = 0, -- banco de puntos de investigación
		xp = 0,
		level = 1,
		reputation = Catalog.START.reputation,
		-- day = meses desde enero de 1970; minute = minutos de juego dentro del mes.
		time = { day = 0, minute = 0, speed = 1 },
		designs = {},
		lots = {},
		lotHistory = {}, -- historial reciente (lotes livianos)
		modelHistory = {}, -- historial permanente: un resumen por modelo y generación
		records = GameState.newRecords(), -- récords de la empresa (no dependen del historial)
		launched = {}, -- diseños que ya cobraron la bonificación de lanzamiento exitoso
		marketShare = {}, -- cuota de mercado por tipo (promedio móvil mensual)
		employees = {}, -- ver Staff.luau (departamento, habilidades, potencial, antigüedad…)
		candidates = {}, -- 8 por mes (Simulation.ensureMarket); se reemplazan, no se acumulan
		market = { month = -1, searches = 0 }, -- mes de los candidatos actuales y búsquedas pagas del mes
		payroll = { debt = 0, debtMonths = 0 }, -- sueldos atrasados y meses seguidos con deuda
		-- capacitaciones en curso { id, level, skill, scope, members = { empleados }, results = { [id] = valor final }, progress, days, cost }
		trainings = {},
		stations = freshStations(),
		ledger = {},
		-- projects = investigaciones en curso { id, progress (días), days, paidMoney, paidPi, ahead, startDay }
		research = { done = {}, projects = {} },
		devPaid = {},
		claimed = {},
		counters = {
			companyCreated = 1, designsSaved = 0, hires = 0, lotsLaunched = 0, lotsSoldOut = 0, lotsRetired = 0, generations = 0,
			unitsProduced = 0, unitsSold = 0, unitsDiscarded = 0, researchDone = 0, sedeLevel = 1, stationUpgrades = 0,
			revenueTotal = 0, marginTotal = 0,
		},
		-- Agregados por mes y acumuladores del mes en curso (reputación y PI por ventas).
		stats = { days = {}, month = { sold = 0, rel = 0, salesPi = 0, bonusPi = 0 } },
		tutorial = { skipped = false, tips = true },
		daily = { last = "", streak = 0 },
		-- campaña publicitaria activa (una por empresa) o nil:
		-- { id, kind = "modelo" | "corporativa", designId?, name, budget, boost, days, progress, cost, startDay }
		campaign = nil,
		-- Deudas: préstamos { id, principal, balance, monthlyRate, takenDay }. Base para un sistema de
		-- préstamos futuro; hoy ninguna acción los crea (Rules.debt los suma).
		loans = {},
		notifications = {},
	}
end

function GameState.uid(g: any, prefix: string): string
	g.nextId = (g.nextId or 1) + 1
	return prefix .. tostring(g.nextId)
end

-- Agregados del día (fuente común de HUD, Ventas, Misiones y Estadísticas).
function GameState.day(g: any, day: number?): any
	local d = day or g.time.day
	local key = Rules.dayKey(d)
	local ds = g.stats.days[key]
	if not ds then
		ds = { revenue = 0, cogs = 0, units = 0, margin = 0, produced = 0, flow = {} }
		g.stats.days[key] = ds
		-- Conservar solo los últimos N días de agregados.
		local limit = d - Catalog.RULES.statsDaysKept
		for k in g.stats.days do
			local n = tonumber(k)
			if n and n < limit then
				g.stats.days[k] = nil
			end
		end
	end
	return ds
end

-- Validación --------------------------------------------------------------------------

local isFinite = Util.isFiniteNumber

local function isList(t: any): boolean
	if type(t) ~= "table" then
		return false
	end
	local n = 0
	for k in t do
		if type(k) ~= "number" then
			return false
		end
		n += 1
	end
	return n == #t
end

local function isInt(v: any, lo: number?, hi: number?): boolean
	return isFinite(v) and v == math.floor(v) and (lo == nil or v >= lo) and (hi == nil or v <= hi)
end

local function nonNeg(v: any): boolean
	return isFinite(v) and v >= 0
end

local function checkSpec(spec: any, what: string): string?
	if type(spec) ~= "table" then
		return what .. ": falta la configuración."
	end
	if not Catalog.base(spec.baseId) then
		return what .. ": modelo base desconocido."
	end
	if type(spec.parts) ~= "table" then
		return what .. ": piezas dañadas."
	end
	for _, c in Catalog.CATS do
		if not Catalog.part(c[1], spec.parts[c[1]]) then
			return what .. ": pieza inválida en " .. c[2] .. "."
		end
	end
	if type(spec.paint) ~= "table" or not Util.isHexColor(spec.paint.primary) or not Util.isHexColor(spec.paint.secondary) or not Catalog.FINISHES[spec.paint.finish] then
		return what .. ": pintura dañada."
	end
	if type(spec.wheels) ~= "table" or not isInt(spec.wheels.size, Catalog.WHEEL_SIZE.min, Catalog.WHEEL_SIZE.max) then
		return what .. ": ruedas dañadas."
	end
	if type(spec.body) ~= "table" or type(spec.interior) ~= "table" then
		return what .. ": carrocería o interior dañados."
	end
	if not isInt(spec.quality, 0, 5) then
		return what .. ": calidad de terminación inválida."
	end
	if spec.motorLevel ~= nil and not isInt(spec.motorLevel, 1, Catalog.RESEARCH_RULES.engineMaxLevel) then
		return what .. ": nivel de motor inválido."
	end
	if spec.motorVariant ~= nil and not Catalog.engineVariant(spec.motorVariant) then
		return what .. ": variante de motor inválida."
	end
	if spec.equipment ~= nil then
		if not isList(spec.equipment) then
			return what .. ": equipamiento dañado."
		end
		for _, id in spec.equipment do
			if not Catalog.equipment(id) then
				return what .. ": equipamiento desconocido."
			end
		end
	end
	-- Carrocería 3D: una que ya no esté en el catálogo no daña la partida (se ve el modelo provisional).
	if spec.vehicleModel ~= nil and type(spec.vehicleModel) ~= "string" then
		return what .. ": carrocería 3D inválida."
	end
	return nil
end

local function checkCalc(c: any, what: string): string?
	if type(c) ~= "table" then
		return what .. ": faltan las estadísticas."
	end
	for _, k in { "unitCost", "price", "quality", "hp", "build" } do
		if not nonNeg(c[k]) then
			return what .. ": estadística «" .. k .. "» inválida."
		end
	end
	if type(c.mats) ~= "table" then
		return what .. ": materiales por unidad dañados."
	end
	for k, v in c.mats do
		if not Catalog.material(k) or not isInt(v, 0) then
			return what .. ": material por unidad inválido."
		end
	end
	return nil
end

--[[
	Revisa una partida completa antes de usarla o de escribirla.
	Devuelve (true) o (false, motivo). Quien llama nunca debe sobrescribir datos si falla.
]]
function GameState.validate(g: any): (boolean, string?)
	local function fail(msg: string): (boolean, string?)
		return false, msg
	end
	if type(g) ~= "table" then
		return fail("La partida no es una tabla.")
	end
	if g.schema ~= GameState.SCHEMA then
		return fail("Versión de partida no reconocida (" .. tostring(g.schema) .. ").")
	end
	local co = g.company
	if type(co) ~= "table" or type(co.name) ~= "string" or Util.charCount(co.name) < 3 or Util.charCount(co.name) > 24 then
		return fail("El nombre de la empresa no es válido.")
	end
	if type(co.id) ~= "string" or #co.id < 1 or #co.id > 64 or not Util.isHexColor(co.color) or not Catalog.isLogo(co.logo) or co.difficulty ~= nil then
		return fail("La identidad de la empresa está dañada.")
	end
	if not nonNeg(g.money) or not isInt(g.gems, 0) or not nonNeg(g.rp) or not nonNeg(g.xp) then
		return fail("Dinero, gemas, PI o experiencia inválidos.")
	end
	if not isInt(g.level, 1, 500) or not isFinite(g.reputation) or g.reputation < 1 or g.reputation > 5 then
		return fail("Nivel o reputación inválidos.")
	end
	if not isInt(g.sede, 1, #Catalog.SEDES) or not isInt(g.nextId, 1) then
		return fail("Sede o contador de identificadores inválidos.")
	end
	local t = g.time
	if type(t) ~= "table" or not isInt(t.day, 0) or not isFinite(t.minute) or t.minute < 0 or t.minute >= Rules.monthMinutes(t.day) or not Util.contains(Catalog.RULES.speeds, t.speed) then
		return fail("El reloj de la partida está dañado.")
	end
	-- Sin tope por el año final: después de endYear el juego sigue en años comerciales extra. Solo se
	-- descarta un valor absurdo (más de 5.000 años de juego).
	if g.time.day > 12 * 5000 then
		return fail("El reloj de la partida está dañado.")
	end
	if type(g.counters) ~= "table" then
		return fail("Los contadores están dañados.")
	end
	for k, v in g.counters do
		if type(k) ~= "string" or not isFinite(v) then
			return fail("Contador inválido: " .. tostring(k) .. ".")
		end
	end
	for _, k in { "designs", "lots", "lotHistory", "ledger", "devPaid", "employees", "candidates", "notifications" } do
		if not isList(g[k]) then
			return fail("La lista «" .. k .. "» está dañada.")
		end
	end
	-- Investigación
	if type(g.research) ~= "table" or not isList(g.research.done) then
		return fail("La investigación está dañada.")
	end
	for _, id in g.research.done do
		if not Catalog.researchNode(id) then
			return fail("Investigación desconocida: " .. tostring(id) .. ".")
		end
	end
	if not isList(g.research.projects) or #g.research.projects > Catalog.RESEARCH_RULES.maxParallel then
		return fail("Las investigaciones en curso están dañadas.")
	end
	local running = {}
	for _, p in g.research.projects do
		if type(p) ~= "table" or not Catalog.researchNode(p.id) or not nonNeg(p.progress) or not isFinite(p.days) or p.days <= 0 or running[p.id] or Util.contains(g.research.done, p.id) then
			return fail("Una investigación en curso está dañada.")
		end
		running[p.id] = true
	end
	-- Estaciones
	if type(g.stations) ~= "table" then
		return fail("Las estaciones están dañadas.")
	end
	for _, st in Catalog.STATIONS do
		local s = g.stations[st[1]]
		if type(s) ~= "table" or not isInt(s.level, 1, 10) then
			return fail("La estación «" .. st[2] .. "» está dañada.")
		end
	end
	-- Diseños
	local designIds = {}
	for _, d in g.designs do
		if type(d) ~= "table" or type(d.id) ~= "string" or designIds[d.id] then
			return fail("Hay un diseño sin identificador válido.")
		end
		designIds[d.id] = true
		if type(d.name) ~= "string" or not isInt(d.version, 1) then
			return fail("El diseño «" .. tostring(d.name) .. "» tiene nombre o versión inválidos.")
		end
		if not isInt(d.gen, 1, 99) or not isInt(d.modelYear, 1900, 2200) then
			return fail("El diseño «" .. d.name .. "» tiene año o generación inválidos.")
		end
		local e = checkSpec(d, "Diseño «" .. d.name .. "»")
		if e then
			return fail(e)
		end
	end
	-- Lotes (activos e historial): contadores enteros y coherentes; nunca más vendidas que fabricadas.
	local lotIds = {}
	local function checkLot(l: any, active: boolean): string?
		if type(l) ~= "table" or type(l.id) ~= "string" or lotIds[l.id] then
			return "Hay un lote sin identificador válido."
		end
		lotIds[l.id] = true
		local sn = l.design
		if type(sn) ~= "table" or type(sn.name) ~= "string" or not isInt(sn.version, 1) or not Catalog.TYPES[sn.type] then
			return "El lote " .. l.id .. " no tiene la copia del diseño."
		end
		-- Los lotes activos llevan la copia completa; los del historial reciente, una versión liviana.
		if active then
			local e = checkSpec(sn.spec, "Lote " .. l.id) or checkCalc(sn.calc, "Lote " .. l.id)
			if e then
				return e
			end
		elseif type(sn.spec) ~= "table" or type(sn.spec.paint) ~= "table" then
			return "El lote " .. l.id .. " del historial está dañado."
		end
		if not isInt(l.qty, 0, Catalog.RULES.maxLotQty) or not isInt(l.produced, 0, l.qty) or not isInt(l.sold, 0) or not isInt(l.discarded, 0) then
			return "El lote " .. l.id .. " tiene cantidades inválidas."
		end
		if l.sold + l.discarded > l.produced then
			return "El lote " .. l.id .. " vendió o descartó más de lo fabricado."
		end
		if not GameState.PROD_STATES[l.prodState] or not GameState.SALE_STATES[l.saleState] then
			return "El lote " .. l.id .. " tiene un estado desconocido."
		end
		if active ~= (GameState.ACTIVE_SALE[l.saleState] == true) then
			return "El lote " .. l.id .. " está en la lista equivocada."
		end
		if (l.saleState == "produccion" or l.saleState == "por lanzar") and l.sold > 0 then
			return "El lote " .. l.id .. " vendió antes de salir a la venta."
		end
		local rv = l.review
		if rv ~= nil and (type(rv) ~= "table" or not isFinite(rv.avg) or rv.avg < 1 or rv.avg > 10 or not isList(rv.scores)) then
			return "Las reseñas del lote " .. l.id .. " están dañadas."
		end
		if not nonNeg(l.price) or l.price <= 0 or not nonNeg(l.unitCost) or not nonNeg(l.refPrice) or not isFinite(l.appeal) then
			return "El lote " .. l.id .. " tiene precio o costo inválidos."
		end
		if not nonNeg(l.revenue) or not nonNeg(l.costSpent) or not nonNeg(l.prodProgress) or not nonNeg(l.saleAcc) then
			return "El lote " .. l.id .. " tiene acumulados inválidos."
		end
		return nil
	end
	if not isList(g.lots) or not isList(g.lotHistory) then
		return fail("La lista de lotes está dañada.")
	end
	for _, l in g.lots do
		local e = checkLot(l, true)
		if e then
			return fail(e)
		end
	end
	for _, l in g.lotHistory do
		local e = checkLot(l, false)
		if e then
			return fail(e)
		end
	end
	-- Personal
	local function checkSkills(t: any, pot: any): boolean
		if type(t) ~= "table" or type(pot) ~= "table" then
			return false
		end
		for _, k in Staff.SKILL_ORDER do
			if not isInt(t[k], 0, 100) or not isInt(pot[k], 0, 100) or t[k] > pot[k] then
				return false
			end
		end
		return true
	end
	if #g.employees > 500 or #g.candidates > 40 then
		return fail("Demasiados empleados o candidatos.")
	end
	for _, e in g.employees do
		if type(e) ~= "table" or type(e.id) ~= "string" or type(e.name) ~= "string" or not Staff.dept(e.spec) or not Staff.dept(e.dept) or not nonNeg(e.salary) then
			return fail("Hay un empleado dañado.")
		end
		if not checkSkills(e.skills, e.potential) or not isInt(e.months, 0) or not isFinite(e.hiredDay) or type(e.adapt) ~= "table" then
			return fail("Las habilidades de " .. e.name .. " están dañadas (nunca superan su potencial).")
		end
		if e.training ~= nil and type(e.training) ~= "string" then
			return fail("La capacitación de " .. e.name .. " está dañada.")
		end
	end
	for _, c in g.candidates do
		if type(c) ~= "table" or type(c.id) ~= "string" or not Staff.dept(c.spec) or not nonNeg(c.salary) or not checkSkills(c.skills, c.potential) then
			return fail("Hay un candidato dañado.")
		end
	end
	if type(g.market) ~= "table" or not isInt(g.market.month, -1) or not isInt(g.market.searches, 0) then
		return fail("El mercado laboral está dañado.")
	end
	if type(g.payroll) ~= "table" or not nonNeg(g.payroll.debt) or not isInt(g.payroll.debtMonths, 0) then
		return fail("La deuda salarial está dañada.")
	end
	if not isList(g.trainings) or #g.trainings > Catalog.TRAINING.maxActive then
		return fail("Las capacitaciones están dañadas.")
	end
	local inTraining = {}
	for _, t in g.trainings do
		if type(t) ~= "table" or type(t.id) ~= "string" or not Staff.trainingLevel(t.level) or not Staff.skill(t.skill) or not isList(t.members) or type(t.results) ~= "table" then
			return fail("Hay una capacitación dañada.")
		end
		if not isFinite(t.progress) or not isFinite(t.days) or t.days <= 0 or t.progress < 0 or t.progress > t.days then
			return fail("El avance de una capacitación es inválido.")
		end
		for _, id in t.members do
			if inTraining[id] or not isInt(t.results[id], 0, 100) then
				return fail("Un empleado figura en dos capacitaciones.")
			end
			inTraining[id] = t.id
		end
	end
	for _, e in g.employees do
		if e.training ~= nil and inTraining[e.id] ~= e.training then
			return fail("La capacitación de " .. e.name .. " no existe.")
		end
	end
	for _, l in g.ledger do
		if type(l) ~= "table" or not isFinite(l.amount) or type(l.type) ~= "string" then
			return fail("El libro de movimientos está dañado.")
		end
	end
	if type(g.stats) ~= "table" or type(g.stats.days) ~= "table" then
		return fail("Las estadísticas están dañadas.")
	end
	for k, ds in g.stats.days do
		if not tonumber(k) or type(ds) ~= "table" or not isFinite(ds.revenue) or type(ds.flow) ~= "table" then
			return fail("Las estadísticas diarias están dañadas.")
		end
	end
	if type(g.stats.month) ~= "table" or not isFinite(g.stats.month.sold) or not isFinite(g.stats.month.rel) or not isFinite(g.stats.month.salesPi) then
		return fail("Los acumulados del mes están dañados.")
	end
	if type(g.claimed) ~= "table" or type(g.daily) ~= "table" or type(g.tutorial) ~= "table" then
		return fail("Las misiones están dañadas.")
	end
	if not isList(g.modelHistory) or type(g.launched) ~= "table" or type(g.marketShare) ~= "table" then
		return fail("El historial de modelos está dañado.")
	end
	for _, e in g.modelHistory do
		if type(e) ~= "table" or type(e.key) ~= "string" or type(e.name) ~= "string" or type(e.spec) ~= "table" then
			return fail("Hay un modelo dañado en el historial.")
		end
		for _, k in { "lots", "produced", "sold", "discarded" } do
			if not isInt(e[k], 0) then
				return fail("El historial de «" .. e.name .. "» tiene cantidades inválidas.")
			end
		end
		if e.sold + e.discarded > e.produced or not nonNeg(e.revenue) or not nonNeg(e.cost) then
			return fail("El historial de «" .. e.name .. "» no es coherente.")
		end
	end
	if g.campaign ~= nil then
		local c = g.campaign
		if type(c) ~= "table" or not Catalog.MARKETING.kinds[c.kind] or not isFinite(c.boost) or c.boost < 0 or c.boost > 1
			or not isFinite(c.days) or c.days <= 0 or not isFinite(c.progress) or c.progress < 0 or c.progress > c.days or type(c.name) ~= "string" then
			return fail("La campaña publicitaria está dañada.")
		end
	end
	if not isList(g.loans) then
		return fail("Las deudas están dañadas.")
	end
	for _, l in g.loans do
		if type(l) ~= "table" or not nonNeg(l.balance) or not nonNeg(l.principal) or not nonNeg(l.monthlyRate) then
			return fail("Hay un préstamo dañado.")
		end
	end
	if not isInt(g.expansion, 0, #Catalog.EXPANSION.regions) or (g.expansion > 0 and g.sede < #Catalog.SEDES) then
		return fail("La expansión global está dañada.")
	end
	local rec = g.records
	if type(rec) ~= "table" or type(rec.others) ~= "table" then
		return fail("Los récords de la empresa están dañados.")
	end
	for _, k in { "models", "lots", "produced", "sold", "discarded", "revenue", "cost" } do
		if not nonNeg(rec.others[k]) then
			return fail("Los récords de la empresa están dañados.")
		end
	end
	for _, k in { "firstModel", "bestLot", "bestLotProfit", "bestMonth" } do
		if rec[k] ~= nil and (type(rec[k]) ~= "table" or type(rec[k].name) ~= "string" or not isFinite(rec[k].value)) then
			return fail("Los récords de la empresa están dañados.")
		end
	end
	return true, nil
end

-- Migración -----------------------------------------------------------------------------
--[[
	Recupera campos de versiones anteriores sin tocar los existentes. Solo completa lo que falta
	o tiene una forma antigua conocida; si un campo existe con un tipo incorrecto, NO lo «arregla»:
	la validación posterior lo marca como dato dañado.
]]
local MIGRATIONS: { [number]: (any, number) -> () } = {}

-- 1 → 2: sistemas completos de la V3 (personal, estaciones, investigación activa, mercado, misiones…).
MIGRATIONS[1] = function(g: any, now: number)
	local fresh = GameState.newGame({ name = g.company.name, color = g.company.color, now = now })
	for k, v in fresh do
		if g[k] == nil then
			g[k] = v
		end
	end
	if g.company.logo == nil then
		g.company.logo = "pico"
	end
	for k, v in fresh.counters do
		if g.counters[k] == nil then
			g.counters[k] = v
		end
	end
	if type(g.materials) ~= "table" then
		g.materials = {}
	end
	for k, v in fresh.stations do
		if g.stations[k] == nil then
			g.stations[k] = { level = v.level, condition = 100, broken = false }
		end
	end
	if type(g.production) == "table" then
		g.production.orders = g.production.orders or {}
		g.production.history = g.production.history or {}
		if g.production.boost == nil then
			g.production.boost = false
		end
		if g.production.auto == nil then
			g.production.auto = false
		end
		for i, o in g.production.orders or {} do
			if type(o) == "table" then
				o.priority = o.priority or "media"
				o.pos = o.pos or ((o.created or 0) + i / 1000)
				o.line = o.line or 1
				o.progress = o.progress or 0
				if o.unitStarted == nil then
					o.unitStarted = false
				end
			end
		end
		-- El historial antiguo no guardaba la copia del diseño: se conserva solo como registro.
		for _, h in g.production.history do
			if type(h) == "table" and h.design == nil then
				h.legacy = true
			end
		end
	end
	if type(g.research) == "table" and g.research.done == nil then
		g.research.done = {}
	end
	for _, c in g.customers or {} do
		if type(c) == "table" and c.budget == nil then
			c.budget = c.offer or 0
		end
	end
	-- Reconstruir agregados diarios a partir del historial existente (antes no había agregados).
	if type(g.stats) == "table" and next(g.stats.days) == nil then
		for _, s in g.sales or {} do
			local ds = GameState.day(g, s.day)
			ds.revenue += s.price
			ds.cogs += s.cost
			ds.units += 1
			ds.margin += s.margin or (s.price - s.cost)
			g.counters.revenueTotal = (g.counters.revenueTotal or 0) + s.price
			g.counters.marginTotal = (g.counters.marginTotal or 0) + (s.margin or (s.price - s.cost))
		end
		for _, l in g.ledger or {} do
			local ds = GameState.day(g, l.day or 0)
			ds.flow[l.type] = (ds.flow[l.type] or 0) + l.amount
		end
	end
	g.schema = 2
end

-- Costos de las investigaciones de la versión 2 (árbol anterior): se devuelven al migrar.
local OLD_RESEARCH_COST = {
	m1 = 15000, m2 = 25000, m3 = 60000, m4 = 90000, e1 = 30000, e4 = 25000, e2 = 70000, e3 = 140000,
	a1 = 20000, a2 = 45000, a3 = 80000, mt1 = 18000, mt2 = 55000, mt3 = 65000, p1 = 20000, p3 = 30000, p2 = 90000,
	mk1 = 15000, mk2 = 20000, mk3 = 70000, q1 = 18000, q3 = 35000, q2 = 60000, l1 = 20000, l2 = 30000, l3 = 50000,
}
local OLD_MAT_PRICE = { acero = 40, aluminio = 95, pintura = 120, electronica = 260, baterias = 420, cuero = 180 }

--[[ 2 → 3: producción por lotes, ventas automáticas, calendario desde 1970 e investigación nueva.
	Nada se pierde ni aparece de la nada: lo que ya estaba pagado y deja de existir se reintegra al costo.
	· unidades sin vender (almacén, salón, reservadas, en el mercado) → su costo de fabricación
	· la unidad en curso de cada orden → lo cobrado al empezarla (el resto de la orden no se había cobrado)
	· materiales y piezas sueltas → su precio de proveedor
	· investigaciones del árbol anterior → su costo (y su PI vuelve al banco)
	Se conservan: dinero, diseños (con año de modelo y 1.ª generación), sede, personal, mejoras de estaciones,
	estadísticas por período, contadores, reputación, nivel, gemas (sin uso) y misiones de recompensa diaria. ]]
MIGRATIONS[2] = function(g: any, _now: number)
	local refund = 0
	local notes = {}
	local unitsBack = 0
	for _, u in g.units or {} do
		if type(u) == "table" and u.status ~= "vendido" and isFinite(u.cost) then
			refund += u.cost
			unitsBack += 1
		end
	end
	if unitsBack > 0 then
		table.insert(notes, unitsBack .. " autos sin vender")
	end
	local prod = type(g.production) == "table" and g.production or {}
	for _, o in prod.orders or {} do
		if type(o) == "table" and o.unitStarted and type(o.cur) == "table" and isFinite(o.cur.charged) then
			refund += o.cur.charged
		end
	end
	if #(prod.orders or {}) > 0 then
		table.insert(notes, #prod.orders .. " órdenes en curso (lo no fabricado no se había cobrado)")
	end
	local mats = 0
	for k, n in type(g.materials) == "table" and g.materials or {} do
		if OLD_MAT_PRICE[k] and isFinite(n) and n > 0 then
			mats += OLD_MAT_PRICE[k] * n
		end
	end
	for _, p in g.parts or {} do
		local part = type(p) == "table" and Catalog.part(p.cat, p.id)
		if part and isFinite(p.qty) then
			mats += part.unit * p.qty
		end
	end
	if mats > 0 then
		refund += mats
		table.insert(notes, "materiales y piezas sueltas")
	end
	local research = 0
	if type(g.research) == "table" then
		for _, id in g.research.done or {} do
			research += OLD_RESEARCH_COST[id] or 0
		end
		local ra = g.research.active
		if type(ra) == "table" then
			research += isFinite(ra.paid) and ra.paid or 0
			if isFinite(ra.rp) then
				g.rp = (isFinite(g.rp) and g.rp or 0) + ra.rp
			end
		end
	end
	if research > 0 then
		refund += research
		table.insert(notes, "investigaciones del árbol anterior")
	end
	refund = Util.round(refund)
	g.money = (isFinite(g.money) and g.money or 0) + refund

	-- Calendario: cada día anterior pasa a ser un mes desde enero de 1970.
	local t = g.time
	t.minute = math.floor((t.minute or 0) * Catalog.RULES.legacyMonthMinutes / 1440)
	if t.minute >= Catalog.RULES.legacyMonthMinutes then
		t.minute = 0
	end
	local year = Catalog.CALENDAR.startYear + math.floor((t.day or 0) / 12)
	for _, d in g.designs or {} do
		if type(d) == "table" then
			d.gen = d.gen or 1
			d.modelYear = d.modelYear or year
			d.generation = d.modelYear .. " · " .. d.gen .. ".ª gen."
		end
	end
	-- Estaciones: solo queda el nivel (sin averías ni desgaste).
	for k, st in g.stations or {} do
		if type(st) == "table" then
			g.stations[k] = { level = math.clamp(isFinite(st.level) and st.level or 1, 1, 6) }
		end
	end
	local upgrades = 0
	for _, st in g.stations or {} do
		upgrades += st.level - 1
	end
	-- Personal sin cansancio ni descansos.
	for _, e in g.employees or {} do
		if type(e) == "table" then
			e.energy = nil
			e.status = nil
		end
	end
	g.units, g.customers, g.sales, g.materials, g.parts, g.market, g.production = nil, nil, nil, nil, nil, nil, nil
	g.research = { done = {}, active = nil }
	g.lots = {}
	g.lotHistory = {}
	if type(g.stats) == "table" then
		g.stats.month = { sold = 0, rel = 0, salesPi = 0 }
	end
	local c = g.counters
	for k, v in { lotsLaunched = 0, lotsSoldOut = 0, lotsRetired = 0, generations = 0, unitsDiscarded = 0, stationUpgrades = upgrades } do
		if c[k] == nil then
			c[k] = v
		end
	end
	-- Las misiones cambiaron: las reclamadas antes quedan como registro aparte.
	g.claimedV2 = g.claimed
	g.claimed = {}
	g.promo = false
	g.notifications = g.notifications or {}
	table.insert(g.notifications, 1, {
		id = "mig3", kind = "info", read = false, day = t.day, at = "00:00", go = "fabrica",
		text = "Tu empresa se actualizó al sistema de lotes y al calendario desde " .. Catalog.CALENDAR.startYear .. ". "
			.. (refund > 0 and ("Se reintegraron " .. Util.money(refund) .. " por " .. table.concat(notes, ", ") .. ".") or "No había nada que reintegrar."),
	})
	if refund > 0 then
		table.insert(g.ledger, { day = t.day, min = 0, type = "reintegro", amount = refund, note = "Actualización al sistema de lotes" })
	end
	g.schema = 3
end

--[[ 3 → 4: historial permanente por modelo y generación, historial reciente liviano, categoría de piezas
	«Seguridad», campañas por nivel y cuota de mercado. No se borra nada: cada lote del historial suma sus
	números al resumen de su modelo antes de quedar en versión liviana. ]]
MIGRATIONS[3] = function(g: any, _now: number)
	local function addSafety(spec: any)
		if type(spec) == "table" and type(spec.parts) == "table" and spec.parts.seguridad == nil then
			spec.parts.seguridad = "basica"
		end
	end
	for _, d in g.designs or {} do
		addSafety(d)
	end
	for _, l in g.lots or {} do
		if type(l) == "table" and type(l.design) == "table" then
			addSafety(l.design.spec)
		end
	end
	g.modelHistory = type(g.modelHistory) == "table" and g.modelHistory or {}
	g.launched = type(g.launched) == "table" and g.launched or {}
	g.marketShare = type(g.marketShare) == "table" and g.marketShare or {}
	-- Del más viejo al más nuevo, para que el resumen quede con el último nombre del modelo.
	local hist = type(g.lotHistory) == "table" and g.lotHistory or {}
	local slim = {}
	for i = #hist, 1, -1 do
		local l = hist[i]
		if type(l) == "table" and type(l.design) == "table" and type(l.design.spec) == "table" then
			addSafety(l.design.spec)
			local e = GameState.modelEntry(g, l)
			e.lots += 1
			e.produced += l.produced or 0
			e.sold += l.sold or 0
			e.discarded += l.discarded or 0
			e.revenue += l.revenue or 0
			e.cost += l.costSpent or 0
			e.bestLotSold = math.max(e.bestLotSold, l.sold or 0)
			e.bestLotProfit = math.max(e.bestLotProfit, (l.revenue or 0) - (l.costSpent or 0))
			e.bestMonth = math.max(e.bestMonth, l.lastMonthSold or 0)
			e.lastDay = math.max(e.lastDay, l.endDay or 0)
			table.insert(slim, 1, GameState.slimLot(l))
		end
	end
	g.lotHistory = slim
	for _, l in g.lots or {} do
		if type(l) == "table" and type(l.design) == "table" and type(l.design.spec) == "table" then
			GameState.modelEntry(g, l)
			if (l.sold or 0) >= Catalog.ECON.launchSold then
				g.launched[l.designId] = true
			end
		end
	end
	-- Campaña: antes era sí/no; ahora es un nivel (el «sí» pasa a radio y prensa).
	g.promo = (g.promo == true) and 1 or (tonumber(g.promo) or 0)
	if type(g.stats) == "table" and type(g.stats.month) == "table" then
		g.stats.month.bonusPi = g.stats.month.bonusPi or 0
	end
	g.schema = 4
end

-- 4 → 5: expansión global, récords permanentes (desde el historial existente) e historial compactable.
MIGRATIONS[4] = function(g: any, _now: number)
	g.expansion = tonumber(g.expansion) or 0
	if type(g.records) ~= "table" then
		g.records = GameState.newRecords()
		local first = nil
		for _, e in type(g.modelHistory) == "table" and g.modelHistory or {} do
			if type(e) == "table" and type(e.name) == "string" then
				if not first or (e.firstDay or 0) < (first.firstDay or 0) then
					first = e
				end
				GameState.noteRecords(g, e, { name = e.name, gen = e.gen, sold = e.bestLotSold or 0, profit = e.bestLotProfit or 0, bestMonth = e.bestMonth or 0, day = e.lastDay or 0 })
			end
		end
		if first then
			g.records.firstModel = { name = first.name, key = first.key, gen = first.gen or 1, value = first.firstDay or 0, day = first.firstDay or 0 }
		end
	end
	g.schema = 5
end

-- 5 → 6: calendario diario (1 día = 2 s reales, meses de 28 a 31 días), velocidades 1×/2×/3×,
-- identificador de empresa y deudas. La fecha se conserva: se mantiene la misma fracción del mes.
MIGRATIONS[5] = function(g: any, _now: number)
	local t = g.time
	if type(t) == "table" and isFinite(t.minute) and isInt(t.day, 0) then
		local frac = math.clamp(t.minute / Catalog.RULES.legacyMonthMinutes, 0, 0.999)
		local len = Rules.monthMinutes(t.day)
		t.minute = math.min(len - Catalog.RULES.gameDayMinutes, math.floor(frac * len / 10) * 10)
		if t.speed == 4 then
			t.speed = 3
		end
	end
	if type(g.company) == "table" and type(g.company.id) ~= "string" then
		g.company.id = "c" .. tostring(g.createdAt or 0) .. "-" .. tostring(g.nextId or 0)
	end
	if type(g.loans) ~= "table" then
		g.loans = {}
	end
	g.schema = 6
end

-- 6 → 7: un lote por modelo. Los diseños que ya fabricaron quedan marcados; los lotes que estaban a la
-- venta siguen igual (sin reseñas: su demanda no cambia).
MIGRATIONS[6] = function(g: any, _now: number)
	local used = {}
	for _, list in { g.lots or {}, g.lotHistory or {} } do
		for _, l in list do
			if type(l) == "table" and l.designId ~= nil then
				used[l.designId] = true
			end
		end
	end
	for _, d in g.designs or {} do
		if type(d) == "table" and used[d.id] then
			d.lotLaunched = true
		end
	end
	g.schema = 7
end

-- 7 → 8: I+D por días con varias investigaciones a la vez; motores por nivel y variante; equipamiento.
-- La investigación activa pasa a la lista con los días que le faltaban (proporcional a su avance). Los efectos
-- que antes se aplicaban solos (aire acondicionado, dirección asistida, zonas de deformación, computadora
-- de a bordo) pasan a ser equipamiento: los diseños existentes lo reciben para conservar sus estadísticas.
MIGRATIONS[7] = function(g: any, _now: number)
	local r = type(g.research) == "table" and g.research or { done = {} }
	r.done = type(r.done) == "table" and r.done or {}
	r.projects = type(r.projects) == "table" and r.projects or {}
	local a = r.active
	if type(a) == "table" then
		local n = Catalog.researchNode(a.id)
		if n and not Util.contains(r.done, a.id) then
			local need = (isFinite(a.rp) and a.rp > 0) and a.rp or n.rp
			local left = math.clamp(1 - (isFinite(a.progress) and a.progress or 0) / need, 0.05, 1)
			table.insert(r.projects, { id = n.id, progress = 0, days = math.max(1, math.floor(n.days * left + 0.5)), paidMoney = isFinite(a.paid) and a.paid or 0, paidPi = 0, ahead = 0, startDay = 0 })
		end
	end
	r.active = nil
	g.research = r
	-- Antes, estas tecnologías se aplicaban solas a todos los autos: los diseños existentes las conservan
	-- como equipamiento elegido (en el orden del catálogo) para no cambiar sus estadísticas.
	local AUTO = { se2 = true, co1 = true, co3 = true, el2 = true }
	local equip = {}
	for _, e in Catalog.EQUIPMENT do
		if AUTO[e.research] and Util.contains(r.done, e.research) then
			table.insert(equip, e.id)
		end
	end
	local function upgrade(spec: any)
		if type(spec) == "table" then
			spec.motorLevel = spec.motorLevel or 1
			spec.motorVariant = spec.motorVariant or "balanced"
			if spec.equipment == nil then
				spec.equipment = table.clone(equip)
			end
		end
	end
	for _, d in g.designs or {} do
		upgrade(d)
	end
	for _, l in g.lots or {} do
		if type(l) == "table" and type(l.design) == "table" then
			upgrade(l.design.spec)
		end
	end
	g.schema = 8
end

-- 8 → 9: sin dificultades (todas las empresas juegan con las mismas reglas). El dinero que ya tenían se
-- conserva; solo deja de aplicarse el ajuste de demanda.
MIGRATIONS[8] = function(g: any, _now: number)
	g.company.difficulty = nil
	g.schema = 9
end

-- 9 → 10: personal por departamentos. Cada empleado viejo (rol + una habilidad) pasa al departamento que
-- corresponde a su rol, con esa habilidad en las tres de su especialidad y un potencial algo mayor; conserva
-- su salario. Su antigüedad empieza ahora (las versiones anteriores no la registraban). Los candidatos viejos
-- se reemplazan por los 8 del mes al abrir la empresa.
local OLD_ASSIGN = { chasis = "produccion", pintura = "produccion", motor = "produccion", interior = "produccion", calidad = "produccion", entrega = "produccion", laboratorio = "investigacion", ventas = "marketing", marketing = "marketing", diseno = "produccion" }
MIGRATIONS[9] = function(g: any, _now: number)
	local today = Rules.absDay(g)
	local list = {}
	for _, e in (type(g.employees) == "table" and g.employees or {}) do
		if type(e) == "table" and type(e.id) == "string" then
			local spec = Catalog.LEGACY_ROLES[e.role] or "produccion"
			local skill = math.clamp(math.floor(isFinite(e.skill) and e.skill or 40), 0, 100)
			local skills, potential = {}, {}
			for _, d in Catalog.STAFF.departments do
				for _, k in d.skills do
					local v = d.id == spec and skill or 10
					skills[k] = v
					potential[k] = math.min(100, d.id == spec and v + 10 or 40)
				end
			end
			table.insert(list, {
				id = e.id, name = type(e.name) == "string" and e.name or "Empleado", spec = spec,
				dept = (e.assign and OLD_ASSIGN[e.assign]) or spec,
				salary = isFinite(e.salary) and math.max(0, e.salary) or 1000,
				skills = skills, potential = potential, months = 0, hiredDay = today, adapt = {}, status = "activo",
			})
		end
	end
	g.employees = list
	g.candidates = {}
	g.market = { month = -1, searches = 0 }
	g.payroll = { debt = 0, debtMonths = 0 }
	g.schema = 10
end

-- 10 → 11: capacitaciones (nadie estaba capacitándose).
MIGRATIONS[10] = function(g: any, _now: number)
	g.trainings = {}
	for _, e in g.employees or {} do
		if type(e) == "table" then
			e.training = nil
		end
	end
	g.schema = 11
end

-- 11 → 12: marketing nuevo. La campaña por niveles (cobro mensual) que estaba activa ya tenía pagado el mes:
-- sigue como campaña corporativa con el mismo efecto por los días que le quedaban a ese mes.
local OLD_CAMPAIGN_BOOST = { 0.15, 0.3, 0.45 }
MIGRATIONS[11] = function(g: any, _now: number)
	local lvl = tonumber(g.promo) or 0
	g.promo = nil
	g.campaign = nil
	local boost = OLD_CAMPAIGN_BOOST[lvl]
	if boost then
		local left = math.max(1, math.floor((Rules.monthMinutes(g.time.day) - (g.time.minute or 0)) / Catalog.RULES.gameDayMinutes))
		g.campaign = { id = "m-mig", kind = "corporativa", name = g.company.name, budget = 0, boost = math.min(boost, 1), days = left, progress = 0, cost = 0, startDay = Rules.absDay(g) }
	end
	g.schema = 12
end

function GameState.migrate(g: any, now: number): (any?, string?)
	if type(g) ~= "table" or type(g.company) ~= "table" then
		return nil, "La partida no tiene empresa."
	end
	local schema = g.schema
	if schema == nil then
		schema = 1
		g.schema = 1
	end
	if type(schema) ~= "number" or schema > GameState.SCHEMA then
		return nil, "La partida es de una versión más nueva o desconocida (" .. tostring(schema) .. ")."
	end
	while g.schema < GameState.SCHEMA do
		local step = MIGRATIONS[g.schema]
		if not step then
			return nil, "No hay migración desde la versión " .. tostring(g.schema) .. "."
		end
		local ok, err = pcall(step, g, now)
		if not ok then
			return nil, "La migración falló: " .. tostring(err)
		end
	end
	return g, nil
end

-- Perfil (varias empresas por jugador) ---------------------------------------------------

function GameState.newProfile(): any
	return { slots = {}, active = nil, settings = Util.deepCopy(GameState.DEFAULT_SETTINGS), processed = {}, unlocked = {}, receipts = {} }
end

-- ¿Se puede usar la ranura? Las dos primeras son gratuitas; la 3 y la 4 solo si se habilitaron
-- (profile.unlocked) o si ya tienen una empresa (partidas de versiones con 3 ranuras: no se pierde nada).
function GameState.slotUsable(profile: any, key: string): boolean
	local n = tonumber(key)
	if not n or n < 1 or n > Catalog.RULES.slots or n ~= math.floor(n) then
		return false
	end
	return n <= Catalog.RULES.slotsFree or (profile.unlocked and profile.unlocked[key] == true) or profile.slots[key] ~= nil
end

function GameState.slotKeys(): { string }
	local out = {}
	for i = 1, Catalog.RULES.slots do
		table.insert(out, tostring(i))
	end
	return out
end

--[[
	Prepara el perfil leído del registro. Devuelve (perfil, dañadas) donde dañadas[ranura] = motivo.
	Una ranura dañada se conserva tal cual (se vuelve a escribir sin cambios) y no se puede jugar.
	Devuelve (nil, motivo) si el perfil entero no tiene una forma reconocible.
]]
function GameState.loadProfile(record: any, now: number): (any?, any)
	local profile
	if record == nil then
		return GameState.newProfile(), {}
	end
	if type(record) ~= "table" then
		return nil, "El registro no tiene el formato esperado."
	end
	if record.profile == nil and record.game ~= nil then
		-- Registro de la etapa 1: una sola empresa.
		profile = GameState.newProfile()
		profile.slots["1"] = record.game
		profile.active = "1"
	elseif record.profile == nil then
		profile = GameState.newProfile()
	elseif type(record.profile) == "table" and type(record.profile.slots) == "table" then
		profile = record.profile
	else
		return nil, "El perfil guardado está dañado."
	end
	if type(profile.settings) ~= "table" then
		profile.settings = Util.deepCopy(GameState.DEFAULT_SETTINGS)
	end
	for k, v in GameState.DEFAULT_SETTINGS do
		if type(profile.settings[k]) ~= type(v) then
			profile.settings[k] = v
		end
	end
	-- Tamaños de texto de versiones anteriores → los de la V3 (Normal, Grande, Muy grande).
	local ts = profile.settings.textScale
	if ts ~= 1 and ts ~= 1.12 and ts ~= 1.25 then
		profile.settings.textScale = (ts >= 1.27 and 1.25) or (ts >= 1.1 and 1.12) or 1
	end
	if not isList(profile.processed) then
		profile.processed = {}
	end
	if type(profile.unlocked) ~= "table" then
		profile.unlocked = {}
	end
	if not isList(profile.receipts) then
		profile.receipts = {} -- recibos de Robux ya acreditados (PurchaseId)
	end
	local damaged = {}
	for key, raw in profile.slots do
		if not tonumber(key) or tonumber(key) > Catalog.RULES.slots then
			damaged[key] = "Ranura desconocida."
		else
			local copy = Util.deepCopy(raw)
			local migrated, err = GameState.migrate(copy, now)
			local ok, why = false, err
			if migrated then
				ok, why = GameState.validate(migrated)
			end
			if ok then
				profile.slots[key] = migrated
			else
				damaged[key] = why or "Partida dañada."
			end
		end
	end
	-- Una ranura de pago que ya tenía empresa queda habilitada para siempre (aunque después se borre).
	for key in profile.slots do
		local n = tonumber(key)
		if n and n > Catalog.RULES.slotsFree and n <= Catalog.RULES.slots then
			profile.unlocked[key] = true
		end
	end
	if profile.active ~= nil and (profile.slots[profile.active] == nil or damaged[profile.active]) then
		profile.active = nil
	end
	return profile, damaged
end

-- Historial permanente ------------------------------------------------------------------------

function GameState.modelKey(design: any): string
	return tostring(design.lineage or design.id) .. "#" .. tostring(design.gen or 1)
end

-- Configuración compacta de un diseño (lo que se eligió en el editor), para el historial permanente.
function GameState.compactSpec(spec: any): any
	return {
		baseId = spec.baseId, objective = spec.objective, segment = spec.segment, chassis = spec.chassis, quality = spec.quality,
		parts = Util.deepCopy(spec.parts), paint = { primary = spec.paint.primary, secondary = spec.paint.secondary, finish = spec.paint.finish },
		wheels = { size = spec.wheels and spec.wheels.size }, generation = spec.generation, vehicleModel = spec.vehicleModel,
	}
end

-- Entrada del historial permanente del modelo y la generación del lote (la crea si no existe).
function GameState.modelEntry(g: any, lot: any): any
	local d = lot.design
	local key = GameState.modelKey(d)
	for _, e in g.modelHistory do
		if e.key == key then
			return e
		end
	end
	local c = d.calc or {}
	local e = {
		key = key, lineage = d.lineage or d.id, gen = d.gen or 1, name = d.name, modelYear = d.modelYear, type = d.type,
		spec = GameState.compactSpec(d.spec),
		stats = { hp = c.hp, top = c.top, accel = c.accel, consumption = c.consumption, consUnit = c.consUnit, comfort = c.comfort, safety = c.safety, durability = c.durability, quality = c.quality, unitCost = c.unitCost, price = c.price },
		lots = 0, produced = 0, sold = 0, discarded = 0, revenue = 0, cost = 0, bestLotSold = 0, bestLotProfit = 0, bestMonth = 0,
		firstDay = lot.createdDay or g.time.day, lastDay = lot.createdDay or g.time.day,
	}
	table.insert(g.modelHistory, e)
	if g.records and not g.records.firstModel then
		g.records.firstModel = { name = e.name, key = key, gen = e.gen, value = e.firstDay, day = e.firstDay }
	end
	return e
end

-- Actualiza los récords de la empresa con un lote cerrado (o un resumen equivalente):
-- x = { name, gen, sold, profit, bestMonth, day }.
function GameState.noteRecords(g: any, e: any, x: any)
	local rec = g.records
	if not rec then
		return
	end
	local function better(k: string, value: number)
		if value > 0 and (not rec[k] or value > rec[k].value) then
			rec[k] = { name = x.name, key = e.key, gen = x.gen or 1, value = value, day = x.day }
		end
	end
	better("bestLot", x.sold or 0)
	better("bestLotProfit", x.profit or 0)
	better("bestMonth", x.bestMonth or 0)
end

-- Deja una entrada del historial solo con números y nombre (sin configuración ni estadísticas).
local function compactEntry(e: any)
	local sp = e.spec or {}
	local paint = sp.paint or {}
	e.spec = { baseId = sp.baseId, paint = { primary = paint.primary, secondary = paint.secondary } }
	e.stats = { unitCost = e.stats and e.stats.unitCost, price = e.stats and e.stats.price }
	e.compact = true
end

-- Versión liviana de un lote terminado para el historial reciente (sin la copia completa del diseño:
-- la configuración queda una sola vez en el historial permanente).
function GameState.slimLot(l: any): any
	local d = l.design
	local spec = d.spec or {}
	local paint = spec.paint or {}
	local out = table.clone(l)
	out.design = {
		id = d.id, version = d.version or 1, name = d.name, brand = d.brand, baseId = d.baseId, type = d.type,
		gen = d.gen or 1, modelYear = d.modelYear, lineage = d.lineage or d.id,
		spec = { baseId = spec.baseId, generation = spec.generation, paint = { primary = paint.primary or "#888888", secondary = paint.secondary or "#222222" } },
	}
	return out
end

-- Límites de tamaño para que el registro no crezca sin control (los lotes son agregados: producir 50.000
-- autos no agrega 50.000 registros).
function GameState.trim(g: any, protect: string?)
	local R = Catalog.RULES
	while #g.ledger > R.maxLedger do
		table.remove(g.ledger, 1)
	end
	if #g.modelHistory > R.maxModelDetail then
		-- Protegidos: modelos con lotes activos, el primer modelo, el más vendido, el más rentable y los que
		-- tienen un récord de la empresa. Nunca se compactan ni se resumen.
		local keep = {}
		if protect then
			keep[protect] = true
		end
		for _, l in g.lots do
			keep[GameState.modelKey(l.design)] = true
		end
		local rec = g.records or {}
		for _, k in { "firstModel", "bestLot", "bestLotProfit", "bestMonth" } do
			if rec[k] and rec[k].key then
				keep[rec[k].key] = true
			end
		end
		local best, profit = nil, nil
		for _, e in g.modelHistory do
			if not best or e.sold > best.sold then
				best = e
			end
			if not profit or e.revenue - e.cost > profit.revenue - profit.cost then
				profit = e
			end
		end
		keep[best.key] = true
		keep[profit.key] = true
		-- Orden de importancia: menos ventas primero (a igualdad, el más antiguo).
		local order = {}
		local detailed = 0
		for _, e in g.modelHistory do
			if not e.compact then
				detailed += 1
			end
			if not keep[e.key] then
				table.insert(order, e)
			end
		end
		table.sort(order, function(a: any, b: any): boolean
			if a.sold ~= b.sold then
				return a.sold < b.sold
			end
			return (a.lastDay or 0) < (b.lastDay or 0)
		end)
		for _, e in order do
			if detailed <= R.maxModelDetail then
				break
			end
			if not e.compact then
				compactEntry(e)
				detailed -= 1
			end
		end
		-- Sobre el tope total, los menos vendidos pasan a «Otros modelos» (se suman sus números).
		local extra = #g.modelHistory - R.maxModelHistory
		if extra > 0 then
			local drop = {}
			for i = 1, math.min(extra, #order) do
				drop[order[i]] = true
				local o = rec.others
				local e = order[i]
				o.models += 1
				o.lots += e.lots
				o.produced += e.produced
				o.sold += e.sold
				o.discarded += e.discarded
				o.revenue += e.revenue
				o.cost += e.cost
			end
			for i = #g.modelHistory, 1, -1 do
				if drop[g.modelHistory[i]] then
					table.remove(g.modelHistory, i)
				end
			end
		end
	end
	while #g.lotHistory > R.maxLotHistory do
		table.remove(g.lotHistory)
	end
	while #g.notifications > 40 do
		table.remove(g.notifications)
	end
end

-- Vista para el cliente -----------------------------------------------------------------------
function GameState.view(g: any): any
	local v = Util.deepCopy(g)
	local function lastN(list: { any }, n: number): { any }
		local out = {}
		for i = math.max(1, #list - n + 1), #list do
			table.insert(out, list[i])
		end
		return out
	end
	v.ledger = lastN(g.ledger, 120)
	v.claimedV2 = nil
	local caps = Rules.caps(g)
	v.derived = {
		caps = caps,
		lineRate = caps.perLine,
		piPerMinute = Rules.piPerMinute(g),
		piCap = Rules.piCap(g),
		year = Rules.year(g),
		xpNext = Rules.xpForLevel(g.level),
		sedeName = Rules.sede(g).name,
	}
	return v
end

-- Datos que cambian cada segundo (dinero, reloj, contadores de lotes, PI…). Se envían solos mientras la
-- estructura de la partida no cambie (GameState.structKey), en lugar de la partida completa.
local LOT_LIVE = { "produced", "sold", "discarded", "prodState", "saleState", "prodProgress", "revenue", "costSpent", "monthSold", "lastMonthSold", "bestMonth", "price" }
function GameState.live(g: any): any
	local lots = {}
	for _, l in g.lots do
		local x = { id = l.id }
		for _, k in LOT_LIVE do
			x[k] = l[k]
		end
		table.insert(lots, x)
	end
	local key = Rules.dayKey(g.time.day)
	local caps = Rules.caps(g)
	return {
		money = g.money, rp = g.rp, xp = g.xp, level = g.level, reputation = g.reputation, bankFull = g.bankFull,
		payroll = table.clone(g.payroll),
		trainings = Util.deepCopy(g.trainings),
		campaign = g.campaign and table.clone(g.campaign) or false,
		time = table.clone(g.time),
		counters = table.clone(g.counters),
		month = table.clone(g.stats.month),
		dayKey = key,
		day = g.stats.days[key] and Util.deepCopy(g.stats.days[key]) or nil,
		research = Util.deepCopy(g.research.projects),
		lots = lots,
		derived = { caps = caps, lineRate = caps.perLine, piPerMinute = Rules.piPerMinute(g), piCap = Rules.piCap(g), year = Rules.year(g), xpNext = Rules.xpForLevel(g.level), sedeName = Rules.sede(g).name },
	}
end

-- Firma de la estructura: si cambia, el cliente recibe la partida completa.
function GameState.structKey(g: any): string
	local parts = { tostring(g.time.day), tostring(g.sede), tostring(#g.designs), tostring(#g.notifications), g.notifications[1] and g.notifications[1].id or "",
		tostring(#g.lotHistory), g.lotHistory[1] and g.lotHistory[1].id or "", tostring(#g.research.done), tostring(#g.research.projects),
		tostring(#g.candidates), g.candidates[1] and g.candidates[1].id or "", tostring(g.market.searches), tostring(#g.employees), tostring(#g.trainings), g.campaign and g.campaign.id or "-", tostring(#g.modelHistory), tostring(g.expansion) }
	for _, l in g.lots do
		table.insert(parts, l.id .. ":" .. l.prodState .. ":" .. l.saleState)
	end
	return table.concat(parts, "|")
end

-- Resumen de una ranura para el menú de inicio.
function GameState.summary(g: any): any
	return {
		name = g.company.name,
		color = g.company.color,
		logo = g.company.logo,
		level = g.level,
		money = g.money,
		day = g.time.day,
		date = Rules.date(g),
		year = Rules.year(g),
		sede = Rules.sede(g).name,
		sold = g.counters.unitsSold,
		lastPlayed = g.lastPlayed,
		playedSeconds = g.playedSeconds or 0,
		tutorialDone = (function()
			local n = 0
			for _, m in Catalog.MISSIONS do
				if m.kind == "tutorial" and g.claimed[m.id] then
					n += 1
				end
			end
			return n
		end)(),
		tutorialSkipped = g.tutorial.skipped == true,
	}
end

return GameState
