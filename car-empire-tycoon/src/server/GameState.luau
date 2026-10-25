--!strict
--[[
	Estado de una partida (una empresa por jugador en la etapa 1): creación, validación,
	migración y la vista que se envía al cliente. Módulo puro, probado con Lune.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)

local GameState = {}

GameState.SCHEMA = 1

function GameState.newGame(opts: { name: string, color: string, difficulty: string?, now: number }): any
	local dif = Catalog.DIFFICULTIES[opts.difficulty or "normal"] or Catalog.DIFFICULTIES.normal
	local g = {
		schema = GameState.SCHEMA,
		createdAt = opts.now,
		nextId = 1,
		company = { name = opts.name, color = opts.color, logo = "pico", difficulty = dif.id },
		sede = 1,
		money = dif.money,
		xp = 0,
		level = 1,
		reputation = 3.0,
		time = { day = 0, minute = 8 * 60, speed = 1 },
		designs = {},
		units = {},
		parts = {},
		materials = { acero = 120, aluminio = 40, pintura = 30, electronica = 20, baterias = 0, cuero = 10 },
		production = { orders = {}, history = {} },
		customers = {},
		sales = {},
		ledger = {},
		research = { done = {} },
		devPaid = {},
		counters = { companyCreated = 1, designsSaved = 0, ordersCreated = 0, unitsProduced = 0, sentToShowroom = 0, unitsSold = 0, serial = 0 },
		today = { day = 0, sold = 0, produced = 0, margin = 0 },
		notifications = {},
	}
	return g
end

function GameState.uid(g: any, prefix: string): string
	g.nextId = (g.nextId or 1) + 1
	return prefix .. tostring(g.nextId)
end

function GameState.sede(g: any): any
	return Catalog.SEDES[Util.clamp(g.sede or 1, 1, #Catalog.SEDES)]
end

function GameState.caps(g: any): any
	local s = GameState.sede(g)
	return { warehouse = s.warehouse, showroom = s.showroom, mats = s.mats, lines = s.lines }
end

-- Regla única de capacidad (V3): el almacén cuenta unidades en el almacén o reservadas;
-- el salón cuenta solo las exhibidas; las vendidas no ocupan lugar.
function GameState.warehouseUsed(g: any): number
	local n = 0
	for _, u in g.units do
		if u.status == "almacen" or u.status == "reservado" then
			n += 1
		end
	end
	return n
end

function GameState.inProgress(g: any): number
	local n = 0
	for _, o in g.production.orders do
		if o.unitStarted then
			n += 1
		end
	end
	return n
end

function GameState.showroomUsed(g: any): number
	local n = 0
	for _, u in g.units do
		if u.status == "salon" then
			n += 1
		end
	end
	return n
end

function GameState.matsUsed(g: any): number
	local n = 0
	for _, v in g.materials do
		n += v
	end
	return n
end

function GameState.xpForLevel(l: number): number
	return Util.round(400 * math.pow(l, 1.35))
end

function GameState.lineSpeed(_g: any): number
	-- Sin personal ni mejoras en la etapa 1: velocidad base de la V3 sin personal asignado.
	return Catalog.RULES.noStaffSpeed
end

function GameState.absMinute(g: any): number
	return g.time.day * Catalog.RULES.dayMinutes + g.time.minute
end

-- Validación -----------------------------------------------------------------

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

local function isFinite(v: any): boolean
	return Util.isFiniteNumber(v)
end

--[[
	Revisa que una partida tenga la forma esperada antes de usarla o de escribirla en el DataStore.
	Si algo no cuadra, devuelve (false, motivo) y quien llama NO debe sobrescribir datos.
]]
function GameState.validate(g: any): (boolean, string?)
	if type(g) ~= "table" then
		return false, "La partida no es una tabla."
	end
	if type(g.schema) ~= "number" or g.schema > GameState.SCHEMA then
		return false, "Versión de partida desconocida (" .. tostring(g.schema) .. ")."
	end
	if type(g.company) ~= "table" or type(g.company.name) ~= "string" or Util.charCount(g.company.name) < 3 then
		return false, "El nombre de la empresa no es válido."
	end
	if not Util.isHexColor(g.company.color) then
		return false, "El color de la empresa no es válido."
	end
	if not isFinite(g.money) or g.money < 0 then
		return false, "El dinero no es un número válido."
	end
	if type(g.time) ~= "table" or not isFinite(g.time.day) or not isFinite(g.time.minute) then
		return false, "El reloj de la partida está dañado."
	end
	for _, k in { "designs", "units", "sales", "ledger", "devPaid", "customers" } do
		if not isList(g[k]) then
			return false, "La lista «" .. k .. "» está dañada."
		end
	end
	if type(g.production) ~= "table" or not isList(g.production.orders) then
		return false, "La cola de producción está dañada."
	end
	if type(g.materials) ~= "table" then
		return false, "Los materiales están dañados."
	end
	for k, v in g.materials do
		if type(k) ~= "string" or not isFinite(v) or v < 0 then
			return false, "Cantidad de material inválida."
		end
	end
	for _, d in g.designs do
		if type(d) ~= "table" or type(d.id) ~= "string" or not Catalog.base(d.baseId) then
			return false, "Hay un diseño con un modelo base desconocido."
		end
	end
	for _, u in g.units do
		if type(u) ~= "table" or type(u.id) ~= "string" or type(u.spec) ~= "table" or type(u.status) ~= "string" then
			return false, "Hay una unidad dañada."
		end
	end
	for _, o in g.production.orders do
		if type(o) ~= "table" or type(o.id) ~= "string" or type(o.design) ~= "table" or not isFinite(o.qty) then
			return false, "Hay una orden de producción dañada."
		end
	end
	return true, nil
end

-- Completa campos que falten (partidas de versiones anteriores) sin tocar los existentes.
function GameState.migrate(g: any, now: number): any
	local fresh = GameState.newGame({ name = g.company.name, color = g.company.color, difficulty = g.company.difficulty, now = now })
	for k, v in fresh do
		if g[k] == nil then
			g[k] = v
		end
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
	if g.production.history == nil then
		g.production.history = {}
	end
	g.money = math.max(0, Util.round(g.money))
	return g
end

-- Límites de tamaño para que el registro del DataStore no crezca sin control.
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
	local extra = #sold - R.maxSoldUnitsKept
	for i = extra, 1, -1 do
		table.remove(g.units, sold[i])
	end
	while #g.notifications > 30 do
		table.remove(g.notifications)
	end
end

-- Vista para el cliente -----------------------------------------------------------
-- Solo datos de la propia empresa; listas largas recortadas.
function GameState.view(g: any): any
	local v = Util.deepCopy(g)
	local function lastN(list: { any }, n: number): { any }
		local out = {}
		for i = math.max(1, #list - n + 1), #list do
			table.insert(out, list[i])
		end
		return out
	end
	v.ledger = lastN(g.ledger, 60)
	v.sales = lastN(g.sales, 60)
	local units = {}
	local soldShown = 0
	for i = #g.units, 1, -1 do
		local u = g.units[i]
		if u.status ~= "vendido" then
			table.insert(units, 1, Util.deepCopy(u))
		elseif soldShown < 20 then
			soldShown += 1
			table.insert(units, 1, Util.deepCopy(u))
		end
	end
	v.units = units
	v.derived = {
		caps = GameState.caps(g),
		warehouseUsed = GameState.warehouseUsed(g),
		inProgress = GameState.inProgress(g),
		showroomUsed = GameState.showroomUsed(g),
		matsUsed = GameState.matsUsed(g),
		lineSpeed = GameState.lineSpeed(g),
		xpNext = GameState.xpForLevel(g.level),
		sedeName = GameState.sede(g).name,
	}
	return v
end

return GameState
