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

GameState.SCHEMA = 2

GameState.UNIT_STATUSES = { almacen = true, salon = true, reservado = true, mercado = true, vendido = true }
GameState.CUSTOMER_STATES = { mirando = true, oferta = true, ["se fue"] = true, ["compró"] = true }
GameState.PRIORITIES = { alta = 0, media = 1, baja = 2 }
GameState.DEFAULT_SETTINGS = { sound = true, reduceMotion = false, keyHints = true, textScale = 1, camSpeed = 1, tips = true }

local function freshStations(): any
	local out = {}
	for _, st in Catalog.STATIONS do
		out[st[1]] = { level = 1, condition = 100, broken = false }
	end
	return out
end

function GameState.newGame(opts: { name: string, color: string, logo: string?, difficulty: string?, now: number }): any
	local dif = Catalog.DIFFICULTIES[opts.difficulty or "normal"] or Catalog.DIFFICULTIES.normal
	return {
		schema = GameState.SCHEMA,
		createdAt = opts.now,
		lastPlayed = opts.now,
		nextId = 1,
		company = { name = opts.name, color = opts.color, logo = opts.logo or "pico", difficulty = dif.id },
		sede = 1,
		money = dif.money,
		gems = 20,
		rp = 0,
		xp = 0,
		level = 1,
		reputation = 3.0,
		time = { day = 0, minute = 8 * 60, speed = 1 },
		designs = {},
		units = {},
		parts = {},
		materials = { acero = 120, aluminio = 40, pintura = 30, electronica = 20, baterias = 0, cuero = 10 },
		employees = {},
		candidates = {},
		stations = freshStations(),
		production = { orders = {}, auto = false, boost = false, lastDesign = nil, lastSnap = nil, history = {} },
		customers = {},
		sales = {},
		ledger = {},
		research = { done = {}, active = nil },
		devPaid = {},
		claimed = {},
		counters = {
			companyCreated = 1, designsSaved = 0, hires = 0, ordersCreated = 0, unitsProduced = 0, sentToShowroom = 0,
			unitsSold = 0, researchDone = 0, sedeLevel = 1, serial = 0, revenueTotal = 0, marginTotal = 0,
		},
		stats = { days = {} },
		tutorial = { skipped = false },
		daily = { last = "", streak = 0 },
		promo = false,
		market = { seedDay = -1, listings = {}, favorites = {}, mine = {}, offers = {} },
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
		ds = { revenue = 0, cogs = 0, units = 0, fees = 0, margin = 0, produced = 0, flow = {} }
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
	if type(spec.wheels) ~= "table" or not isInt(spec.wheels.size, 16, 22) then
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

local function checkMats(m: any, what: string): string?
	if type(m) ~= "table" then
		return what .. " dañados."
	end
	for k, v in m do
		if not Catalog.material(k) or not isInt(v, 0) then
			return what .. ": cantidad inválida de «" .. tostring(k) .. "»."
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
	if type(g.counters) ~= "table" then
		return fail("Los contadores están dañados.")
	end
	for k, v in g.counters do
		if type(k) ~= "string" or not isFinite(v) then
			return fail("Contador inválido: " .. tostring(k) .. ".")
		end
	end
	for _, k in { "designs", "units", "sales", "ledger", "devPaid", "customers", "parts", "employees", "candidates", "notifications" } do
		if not isList(g[k]) then
			return fail("La lista «" .. k .. "» está dañada.")
		end
	end
	local mErr = checkMats(g.materials, "Los materiales")
	if mErr then
		return fail(mErr)
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
	if ra ~= nil and (type(ra) ~= "table" or not Catalog.researchNode(ra.id) or not nonNeg(ra.progress) or not nonNeg(ra.paid) or not nonNeg(ra.rp)) then
		return fail("La investigación en curso está dañada.")
	end
	-- Estaciones
	if type(g.stations) ~= "table" then
		return fail("Las estaciones están dañadas.")
	end
	for _, st in Catalog.STATIONS do
		local s = g.stations[st[1]]
		if type(s) ~= "table" or not isInt(s.level, 1, 5) or not isFinite(s.condition) or s.condition < 0 or s.condition > 100 or type(s.broken) ~= "boolean" then
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
		local e = checkSpec(d, "Diseño «" .. d.name .. "»")
		if e then
			return fail(e)
		end
	end
	-- Unidades
	local unitIds = {}
	for _, u in g.units do
		if type(u) ~= "table" or type(u.id) ~= "string" or unitIds[u.id] then
			return fail("Hay una unidad sin identificador válido.")
		end
		unitIds[u.id] = u
		if not GameState.UNIT_STATUSES[u.status] then
			return fail("Estado de unidad desconocido: " .. tostring(u.status) .. ".")
		end
		local e = checkSpec(u.spec, "Unidad " .. tostring(u.serial)) or checkCalc(u.stats, "Unidad " .. tostring(u.serial))
		if e then
			return fail(e)
		end
		if not nonNeg(u.cost) or not isFinite(u.price) or u.price <= 0 or not isInt(u.discount, 0, Catalog.RULES.maxDiscount) then
			return fail("Unidad " .. tostring(u.serial) .. ": costo o precio inválidos.")
		end
	end
	-- Órdenes
	if type(g.production) ~= "table" or not isList(g.production.orders) or not isList(g.production.history) then
		return fail("La producción está dañada.")
	end
	local caps = Rules.caps(g)
	for _, o in g.production.orders do
		if type(o) ~= "table" or type(o.id) ~= "string" then
			return fail("Hay una orden sin identificador.")
		end
		local sn = o.design
		if type(sn) ~= "table" or not isInt(sn.version, 1) or type(sn.name) ~= "string" then
			return fail("La orden " .. o.id .. " no tiene la versión confirmada del diseño.")
		end
		local e = checkSpec(sn.spec, "Orden " .. o.id) or checkCalc(sn.calc, "Orden " .. o.id)
		if e then
			return fail(e)
		end
		if not isInt(o.qty, 1, Catalog.RULES.maxQty) or not isInt(o.done, 0, o.qty - 1) then
			return fail("La orden " .. o.id .. " tiene cantidades inválidas.")
		end
		if not isInt(o.line, 1, caps.lines) or GameState.PRIORITIES[o.priority] == nil or not nonNeg(o.progress) or not isFinite(o.pos) then
			return fail("La orden " .. o.id .. " tiene línea, prioridad o progreso inválidos.")
		end
		if type(o.unitStarted) ~= "boolean" then
			return fail("La orden " .. o.id .. " tiene un estado de unidad inválido.")
		end
		if o.unitStarted then
			local cur = o.cur
			if type(cur) ~= "table" or not nonNeg(cur.charged) or checkMats(cur.mats, "Materiales de la unidad en curso") or not nonNeg(o.unitTotal) then
				return fail("La orden " .. o.id .. " no registra lo cobrado a la unidad en curso.")
			end
		end
	end
	-- Personal
	for _, e in g.employees do
		if type(e) ~= "table" or type(e.id) ~= "string" or not Util.contains(Catalog.ROLES, e.role) or not isInt(e.skill, 0, 100) or not nonNeg(e.salary) or not isFinite(e.energy) or e.energy < 0 or e.energy > 100 then
			return fail("Hay un empleado dañado.")
		end
		if e.status ~= "activo" and e.status ~= "descanso" then
			return fail("Estado de empleado desconocido.")
		end
		if e.assign ~= nil and not Catalog.station(e.assign) and not Catalog.department(e.assign) then
			return fail("Puesto de empleado desconocido.")
		end
	end
	for _, p in g.parts do
		if type(p) ~= "table" or not Catalog.part(p.cat, p.id) or not isInt(p.qty, 1) then
			return fail("Hay una pieza de inventario dañada.")
		end
	end
	-- Clientes y referencias
	for _, c in g.customers do
		if type(c) ~= "table" or type(c.id) ~= "string" or not GameState.CUSTOMER_STATES[c.state] or not nonNeg(c.patience) or not nonNeg(c.waited) or not isFinite(c.budget) then
			return fail("Hay un cliente dañado.")
		end
		if c.unitId ~= nil and not unitIds[c.unitId] and c.state ~= "se fue" then
			return fail("Un cliente mira una unidad inexistente.")
		end
	end
	for _, s in g.sales do
		-- Las demostraciones de la V3 traen 30 días de historial previos al día 0 (días negativos).
		if type(s) ~= "table" or not isFinite(s.price) or not isFinite(s.cost) or not isInt(s.day, g.demo and -60 or 0) then
			return fail("El historial de ventas está dañado.")
		end
	end
	for _, l in g.ledger do
		if type(l) ~= "table" or not isFinite(l.amount) or type(l.type) ~= "string" then
			return fail("El libro de movimientos está dañado.")
		end
	end
	-- Mercado
	local m = g.market
	if type(m) ~= "table" or not isList(m.listings) or not isList(m.mine) or not isList(m.offers) or not isList(m.favorites) then
		return fail("El mercado está dañado.")
	end
	for _, l in m.mine do
		if l.status == "activa" then
			local u = unitIds[l.unitId]
			if not u or u.status ~= "mercado" then
				return fail("Una publicación activa no corresponde a una unidad en el mercado.")
			end
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
	for k, v in fresh.materials do
		if g.materials[k] == nil then
			g.materials[k] = v
		end
	end
	for k, v in fresh.stations do
		if g.stations[k] == nil then
			g.stations[k] = v
		end
	end
	if type(g.production) == "table" then
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

-- Límites de tamaño para que el registro no crezca sin control.
function GameState.trim(g: any)
	local R = Catalog.RULES
	while #g.ledger > R.maxLedger do
		table.remove(g.ledger, 1)
	end
	while #g.sales > R.maxSales do
		table.remove(g.sales, 1)
	end
	local sold = {}
	for i, u in g.units do
		if u.status == "vendido" then
			table.insert(sold, i)
		end
	end
	for i = #sold - R.maxSoldUnitsKept, 1, -1 do
		table.remove(g.units, sold[i])
	end
	while #g.notifications > 40 do
		table.remove(g.notifications)
	end
end

-- Vista para el cliente -----------------------------------------------------------------------
-- Solo datos de la propia empresa. Los presupuestos de los clientes son información oculta.
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
	v.sales = lastN(g.sales, 120)
	for _, c in v.customers do
		c.budget = nil
	end
	v.derived = {
		caps = Rules.caps(g),
		warehouseFinished = Rules.warehouseFinished(g),
		inProgress = Rules.inProgress(g),
		warehouseUsed = Rules.warehouseUsed(g),
		showroomUsed = Rules.showroomUsed(g),
		matsStored = Rules.matsStored(g),
		matsInProcess = Rules.matsInProcess(g),
		matsUsed = Rules.matsUsed(g),
		lineSpeed = Rules.lineSpeed(g),
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
		sede = Rules.sede(g).name,
		sold = g.counters.unitsSold,
		lastPlayed = g.lastPlayed,
	}
end

return GameState
