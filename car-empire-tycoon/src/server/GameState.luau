--!strict
--[[
	Estado de una empresa y del perfil del jugador: creación, validación estricta, migración por versiones
	y la vista que se envía al cliente. Módulo puro (sin servicios de Roblox), probado con Lune.

	Perfil guardado (un registro por jugador):
	  { slots = { ["1"] = partida, ["2"] = …, ["3"] = … }, active = "1" | nil, settings = {…}, processed = { ids } }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local GameState = {}

GameState.SCHEMA = 3

-- Estados de un lote. Producción: en cola / produciendo / sin fondos / pausado / completado / cancelado.
-- Comercialización: en venta / agotado / retirado.
GameState.PROD_STATES = { cola = true, produciendo = true, ["sin fondos"] = true, pausado = true, completado = true, cancelado = true }
GameState.SALE_STATES = { ["en venta"] = true, agotado = true, retirado = true }
GameState.DEFAULT_SETTINGS = { sound = true, reduceMotion = false, keyHints = true, textScale = 1, camSpeed = 1, tips = true, shadows = true }

local function freshStations(): any
	local out = {}
	for _, st in Catalog.STATIONS do
		out[st[1]] = { level = 1 }
	end
	return out
end

function GameState.newGame(opts: { name: string, color: string, logo: string?, difficulty: string?, now: number }): any
	local dif = Catalog.DIFFICULTIES[opts.difficulty or "normal"] or Catalog.DIFFICULTIES.normal
	return {
		schema = GameState.SCHEMA,
		createdAt = opts.now,
		lastPlayed = opts.now,
		playedSeconds = 0,
		nextId = 1,
		company = { name = opts.name, color = opts.color, logo = opts.logo or "pico", difficulty = dif.id },
		sede = 1,
		money = dif.money,
		gems = 0, -- sin uso por ahora: se conserva por compatibilidad y no se muestra
		rp = 0, -- banco de puntos de investigación
		xp = 0,
		level = 1,
		reputation = 3.0,
		-- day = meses desde enero de 1970; minute = minutos de juego dentro del mes.
		time = { day = 0, minute = 0, speed = 1 },
		designs = {},
		lots = {},
		lotHistory = {},
		employees = {},
		candidates = {},
		stations = freshStations(),
		ledger = {},
		research = { done = {}, active = nil },
		devPaid = {},
		claimed = {},
		counters = {
			companyCreated = 1, designsSaved = 0, hires = 0, lotsLaunched = 0, lotsSoldOut = 0, lotsRetired = 0, generations = 0,
			unitsProduced = 0, unitsSold = 0, unitsDiscarded = 0, researchDone = 0, sedeLevel = 1, stationUpgrades = 0,
			revenueTotal = 0, marginTotal = 0,
		},
		-- Agregados por mes y acumuladores del mes en curso (reputación y PI por ventas).
		stats = { days = {}, month = { sold = 0, rel = 0, salesPi = 0 } },
		tutorial = { skipped = false, tips = true },
		daily = { last = "", streak = 0 },
		promo = false, -- campaña publicitaria
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
	if not Util.isHexColor(co.color) or not Catalog.isLogo(co.logo) or not Catalog.DIFFICULTIES[co.difficulty] then
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
	if type(t) ~= "table" or not isInt(t.day, 0) or not isFinite(t.minute) or t.minute < 0 or t.minute >= Catalog.RULES.dayMinutes or not Util.contains(Catalog.RULES.speeds, t.speed) then
		return fail("El reloj de la partida está dañado.")
	end
	if g.time.day > (Catalog.CALENDAR.endYear - Catalog.CALENDAR.startYear + 40) * 12 then
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
	local ra = g.research.active
	if ra ~= nil and (type(ra) ~= "table" or not Catalog.researchNode(ra.id) or not nonNeg(ra.progress) or not nonNeg(ra.paid)) then
		return fail("La investigación en curso está dañada.")
	end
	-- Estaciones
	if type(g.stations) ~= "table" then
		return fail("Las estaciones están dañadas.")
	end
	for _, st in Catalog.STATIONS do
		local s = g.stations[st[1]]
		if type(s) ~= "table" or not isInt(s.level, 1, 6) then
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
		local e = checkSpec(sn.spec, "Lote " .. l.id) or checkCalc(sn.calc, "Lote " .. l.id)
		if e then
			return e
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
		if active ~= (l.saleState == "en venta") then
			return "El lote " .. l.id .. " está en la lista equivocada."
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
	for _, e in g.employees do
		if type(e) ~= "table" or type(e.id) ~= "string" or not Util.contains(Catalog.ROLES, e.role) or not isInt(e.skill, 0, 100) or not nonNeg(e.salary) then
			return fail("Hay un empleado dañado.")
		end
		if e.assign ~= nil and not Catalog.station(e.assign) and not Catalog.department(e.assign) then
			return fail("Puesto de empleado desconocido.")
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
	local fresh = GameState.newGame({ name = g.company.name, color = g.company.color, difficulty = g.company.difficulty, now = now })
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
	t.minute = math.floor((t.minute or 0) * Catalog.RULES.dayMinutes / 1440)
	if t.minute >= Catalog.RULES.dayMinutes then
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
	return { slots = {}, active = nil, settings = Util.deepCopy(GameState.DEFAULT_SETTINGS), processed = {} }
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
	if profile.active ~= nil and (profile.slots[profile.active] == nil or damaged[profile.active]) then
		profile.active = nil
	end
	return profile, damaged
end

-- Límites de tamaño para que el registro no crezca sin control (los lotes son agregados: producir 50.000
-- autos no agrega 50.000 registros).
function GameState.trim(g: any)
	local R = Catalog.RULES
	while #g.ledger > R.maxLedger do
		table.remove(g.ledger, 1)
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

-- Resumen de una ranura para el menú de inicio.
function GameState.summary(g: any): any
	return {
		name = g.company.name,
		color = g.company.color,
		logo = g.company.logo,
		difficulty = g.company.difficulty,
		level = g.level,
		money = g.money,
		day = g.time.day,
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
