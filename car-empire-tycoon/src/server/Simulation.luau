--!strict
--[[
	Simulación de la partida (reloj, fabricación y clientes). Solo corre en el servidor.
	Reglas portadas de la V3: stepProduction, finishUnit, spawnCustomer, customerTick, sellUnit.
	ctx = { rng: () -> number, notify: (kind: string, text: string) -> () }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local DesignCalc = require(Shared.DesignCalc)
local GameState = require(script.Parent.GameState)

local round = Util.round
local clamp = Util.clamp
local money = Util.money

local Simulation = {}

local function pick(ctx: any, list: { any }): any
	return list[math.floor(ctx.rng() * #list) + 1]
end

function Simulation.ledger(g: any, kind: string, amount: number, note: string)
	table.insert(g.ledger, { day = g.time.day, min = math.floor(g.time.minute), type = kind, amount = round(amount), note = note })
	GameState.trim(g)
end

-- Cobra solo si alcanza; nunca deja el dinero en negativo.
function Simulation.spend(g: any, amount: number, kind: string, note: string): boolean
	amount = round(amount)
	if not (amount >= 0) or g.money < amount then
		return false
	end
	g.money -= amount
	Simulation.ledger(g, kind, -amount, note)
	return true
end

function Simulation.earn(g: any, amount: number, kind: string, note: string)
	amount = round(amount)
	if amount <= 0 then
		return
	end
	g.money += amount
	Simulation.ledger(g, kind, amount, note)
end

function Simulation.notify(g: any, ctx: any, kind: string, text: string)
	table.insert(g.notifications, 1, { kind = kind, text = text, day = g.time.day, at = Util.clock(g.time.minute) })
	while #g.notifications > 30 do
		table.remove(g.notifications)
	end
	if ctx and ctx.notify then
		ctx.notify(kind, text)
	end
end

function Simulation.addXp(g: any, ctx: any, n: number)
	g.xp += n
	local up = false
	while g.xp >= GameState.xpForLevel(g.level) do
		g.xp -= GameState.xpForLevel(g.level)
		g.level += 1
		up = true
	end
	if up then
		Simulation.notify(g, ctx, "nivel", "¡Subiste al nivel " .. g.level .. "!")
	end
end

-- Producción -------------------------------------------------------------------

local function missingMats(g: any, need: { [string]: number }): { any }
	local out = {}
	for _, k in Util.keys(need) do
		local have = g.materials[k] or 0
		if have < need[k] then
			table.insert(out, { k, need[k] - have })
		end
	end
	return out
end
Simulation.missingMats = missingMats

local function missingText(miss: { any }): string
	local parts = {}
	for _, m in miss do
		table.insert(parts, m[2] .. " de " .. string.lower(Catalog.matLabel(m[1])))
	end
	return table.concat(parts, ", ")
end
Simulation.missingText = missingText

-- Copia independiente de la versión confirmada del diseño: configuración + valores calculados.
function Simulation.designSnapshot(g: any, d: any): any
	local c = DesignCalc.computeDesign(g, d)
	return {
		id = d.id,
		version = d.version or 1,
		name = d.name,
		brand = d.brand,
		baseId = d.baseId,
		spec = Util.deepCopy(d),
		calc = Util.deepCopy(c),
		at = GameState.absMinute(g),
	}
end

local function finishUnit(g: any, ctx: any, order: any)
	local snap = order.design
	local c = snap.calc
	local cur = order.cur or { charged = order.unitCost or c.unitCost, mats = c.mats }
	g.counters.serial = (g.counters.serial or 0) + 1
	local letters = string.upper(string.sub(string.gsub(g.company.name, "[^%a]", ""), 1, 2))
	if #letters < 2 then
		letters = "CE"
	end
	local base = Catalog.base(snap.baseId)
	local unit = {
		id = GameState.uid(g, "u"),
		serial = letters .. "-" .. string.format("%04d", g.counters.serial),
		designId = snap.id,
		designVersion = snap.version,
		name = snap.name,
		type = base.type,
		spec = Util.deepCopy(snap.spec),
		stats = Util.deepCopy(c),
		cost = cur.charged,
		quality = c.quality,
		status = "almacen",
		price = c.price,
		discount = 0,
		createdDay = g.time.day,
		orderId = order.id,
	}
	table.insert(g.units, unit)
	order.done += 1
	order.unitStarted = false
	order.progress = 0
	order.cur = nil
	g.counters.unitsProduced += 1
	g.today.produced += 1
	if order.done >= order.qty then
		table.insert(g.production.history, 1, { id = order.id, qty = order.qty, designId = snap.id, version = snap.version, name = snap.name, day = g.time.day })
		while #g.production.history > 6 do
			table.remove(g.production.history)
		end
	end
	Simulation.addXp(g, ctx, 30)
	Simulation.notify(g, ctx, "ok", "Producción completada: " .. snap.name .. " v" .. snap.version .. " (" .. unit.serial .. ")")
end

function Simulation.stepProduction(g: any, ctx: any, minutes: number)
	local caps = GameState.caps(g)
	local speed = GameState.lineSpeed(g)
	for line = 1, caps.lines do
		local order = nil
		for _, o in g.production.orders do
			if o.line == line and o.done < o.qty then
				if not o.paused and order == nil then
					order = o
				elseif o ~= order and not o.paused then
					o.status = "en cola"
				end
			end
		end
		if order then
			local snap = order.design
			local proceed = true
			if not order.unitStarted then
				-- Inicio de una unidad: verificar lugar, materiales y dinero; recién entonces cobrar.
				local c = snap.calc
				if GameState.warehouseUsed(g) + GameState.inProgress(g) >= caps.warehouse then
					order.status = "detenida"
					order.reason = "Almacén lleno (" .. GameState.warehouseUsed(g) .. "/" .. caps.warehouse .. ")"
					proceed = false
				else
					local miss = missingMats(g, c.mats)
					if #miss > 0 then
						order.status = "detenida"
						order.reason = "Faltan materiales: " .. missingText(miss)
						order.missing = miss
						proceed = false
					elseif g.money < c.unitCost then
						order.status = "detenida"
						order.reason = "Fondos insuficientes para fabricar (" .. money(c.unitCost) .. ")"
						proceed = false
					else
						local used = {}
						for k, n in c.mats do
							g.materials[k] -= n
							used[k] = n
						end
						Simulation.spend(g, c.unitCost, "fabricacion", "Fabricación de " .. snap.name .. " v" .. snap.version)
						order.cur = { mats = used, charged = c.unitCost, startedAt = GameState.absMinute(g) }
						order.unitStarted = true
						order.unitCost = c.unitCost
						order.unitTotal = c.build
						order.progress = 0
						order.reason = ""
						order.missing = nil
					end
				end
			end
			if proceed then
				order.status = "en producción"
				order.progress += minutes * speed
				if order.progress >= order.unitTotal then
					finishUnit(g, ctx, order)
				end
			end
		end
	end
	-- Las órdenes terminadas salen de la cola (quedan en el historial).
	local keep = {}
	for _, o in g.production.orders do
		if o.done < o.qty then
			table.insert(keep, o)
		end
	end
	g.production.orders = keep
end

-- Concesionario ----------------------------------------------------------------

function Simulation.finalPrice(u: any): number
	return round(u.price * (1 - clamp(u.discount or 0, 0, Catalog.RULES.maxDiscount) / 100))
end

function Simulation.interest(g: any, u: any, c: any?): number
	local s = u.stats
	local base = Catalog.base(u.spec.baseId)
	local i = 45 + (s.quality - 60) * 0.6 + base.pop * 10 + g.reputation * 3
	if c and c.wants == u.type then
		i += 15
	end
	if c and Catalog.OBJECTIVES[u.spec.objective] == c.pref then
		i += 8
	end
	i += ((Catalog.SEGMENTS[u.spec.segment] or Catalog.SEGMENTS.Masivo).pop - 1) * 20
	if c and c.pref == "potencia" then
		i += (s.hp - 250) / 15
	end
	if c and c.pref == "economia" then
		i += (8 - s.consumption) * 3
	end
	if c and c.pref == "comodidad" then
		i += (s.comfort - 65) / 2
	end
	if c and c.pref == "estilo" then
		i += (u.spec.paint.finish ~= "Mate" and 4 or 0) + (u.spec.spoiler and 3 or 0)
	end
	local ratio = Simulation.finalPrice(u) / math.max(1, s.price)
	i -= (ratio - 1) * 60
	return clamp(round(i), 5, 98)
end

local function showroomUnits(g: any): { any }
	local out = {}
	for _, u in g.units do
		if u.status == "salon" then
			table.insert(out, u)
		end
	end
	return out
end

function Simulation.spawnCustomer(g: any, ctx: any)
	local show = showroomUnits(g)
	if #show == 0 then
		return
	end
	local dif = Catalog.DIFFICULTIES[g.company.difficulty] or Catalog.DIFFICULTIES.normal
	local target = pick(ctx, show)
	local wants = target.type
	if ctx.rng() >= 0.75 then
		wants = pick(ctx, Util.keys(Catalog.TYPES))
	end
	local fp = Simulation.finalPrice(target)
	local budget = round(fp * (0.82 + ctx.rng() * 0.33) / 100) * 100
	local c = {
		id = GameState.uid(g, "k"),
		name = pick(ctx, Catalog.CUSTOMER_NAMES),
		budget = budget,
		wants = wants,
		pref = pick(ctx, Catalog.PREFS),
		unitId = target.id,
		patience = round((180 + ctx.rng() * 240) * dif.patience),
		waited = 0,
		state = "mirando",
		offer = nil,
		rounds = 0,
		interest = 0,
	}
	c.interest = Simulation.interest(g, target, c)
	table.insert(g.customers, c)
	Simulation.notify(g, ctx, "info", c.name .. " entró al concesionario y mira el " .. target.name .. ".")
	return c
end

local function findUnit(g: any, id: any): any
	for _, u in g.units do
		if u.id == id then
			return u
		end
	end
	return nil
end
Simulation.findUnit = findUnit

function Simulation.customerTick(g: any, ctx: any, minutes: number)
	local now = GameState.absMinute(g)
	for _, c in g.customers do
		if c.state ~= "se fue" and c.state ~= "compró" then
			local u = findUnit(g, c.unitId)
			local active = true
			if not u or u.status ~= "salon" then
				-- Si su auto ya no está, mira otro del salón o se va.
				local alt = showroomUnits(g)[1]
				if alt then
					c.unitId = alt.id
					c.interest = Simulation.interest(g, alt, c)
					c.offer = nil
					c.state = "mirando"
				else
					c.state = "se fue"
					c.leftAt = now
					active = false
				end
			end
			if active then
				c.waited += minutes
				if c.state == "mirando" and c.waited > 40 then
					local uu = findUnit(g, c.unitId)
					local fp = Simulation.finalPrice(uu)
					if c.interest >= 35 then
						c.state = "oferta"
						c.offer = math.min(c.budget, round(fp * (0.84 + c.interest / 1000) / 100) * 100)
						if c.offer >= fp then
							c.offer = fp
						end
						Simulation.notify(g, ctx, "info", c.name .. " ofrece " .. money(c.offer) .. " por el " .. uu.name .. ".")
					elseif c.waited > c.patience * 0.6 then
						c.state = "se fue"
						c.leftAt = now
					end
				end
				if c.waited >= c.patience and c.state ~= "se fue" then
					c.state = "se fue"
					c.leftAt = now
					Simulation.notify(g, ctx, "aviso", c.name .. " se fue del concesionario sin comprar.")
				end
			end
		end
	end
	local keep = {}
	for _, c in g.customers do
		local old = c.state == "se fue" and now - (c.leftAt or 0) > 600
		if not old and c.state ~= "compró" then
			table.insert(keep, c)
		end
	end
	g.customers = keep
end

-- Probabilidad (0–100) de que el cliente acepte una contraoferta. Regla visible en pantalla.
function Simulation.counterChance(c: any, amount: number): number
	if amount > c.budget then
		return 0
	end
	local offer = c.offer or c.budget * 0.85
	local span = math.max(1, c.budget - offer)
	local over = clamp((amount - offer) / span, 0, 1)
	return clamp(round((c.interest / 100) * (95 - over * 70) - c.rounds * 8), 3, 95)
end

-- Venta única y atómica: la unidad pasa a «vendido» y el dinero entra una sola vez.
function Simulation.sellUnit(g: any, ctx: any, unitId: string, price: number, channel: string, buyer: string): any
	local u = findUnit(g, unitId)
	if not u then
		return { ok = false, msg = "La unidad no existe." }
	end
	if u.status == "vendido" then
		return { ok = false, msg = "Esta unidad ya fue vendida." }
	end
	price = round(price)
	if not (price > 0) then
		return { ok = false, msg = "Precio inválido." }
	end
	u.status = "vendido"
	u.soldDay = g.time.day
	u.soldPrice = price
	Simulation.earn(g, price, "venta", "Venta de " .. u.name .. " (" .. u.serial .. ")")
	local margin = price - u.cost
	table.insert(g.sales, {
		id = GameState.uid(g, "s"),
		day = g.time.day,
		at = Util.clock(g.time.minute),
		unitId = u.id,
		serial = u.serial,
		designId = u.designId,
		designVersion = u.designVersion,
		name = u.name,
		price = price,
		cost = u.cost,
		margin = margin,
		channel = channel,
		buyer = buyer,
	})
	g.counters.unitsSold += 1
	g.today.sold += 1
	g.today.margin += margin
	g.reputation = clamp(g.reputation + (u.quality - 55) / 600 + 0.008 - (margin < 0 and 0.01 or 0), 1, 5)
	Simulation.addXp(g, ctx, 80)
	for _, c in g.customers do
		if c.unitId == u.id and c.state ~= "compró" then
			c.unitId = nil
		end
	end
	GameState.trim(g)
	return { ok = true, msg = "Venta realizada: " .. u.name .. " por " .. money(price) }
end

-- Reloj ------------------------------------------------------------------------

function Simulation.simulate(g: any, ctx: any, minutes: number)
	local left = minutes
	while left > 0 do
		local step = math.min(left, 10)
		left -= step
		local before = g.time.day
		g.time.minute += step
		if g.time.minute >= Catalog.RULES.dayMinutes then
			g.time.minute -= Catalog.RULES.dayMinutes
			g.time.day += 1
		end
		Simulation.stepProduction(g, ctx, step)
		local show = GameState.showroomUsed(g)
		if show > 0 then
			local dif = Catalog.DIFFICULTIES[g.company.difficulty] or Catalog.DIFFICULTIES.normal
			local rate = 0.025 * step / 10 * (0.6 + g.reputation / 5) * dif.demand * math.min(2, 0.6 + show * 0.25)
			local waiting = 0
			for _, c in g.customers do
				if c.state ~= "se fue" then
					waiting += 1
				end
			end
			if ctx.rng() < rate and waiting < Catalog.RULES.maxCustomers then
				Simulation.spawnCustomer(g, ctx)
			end
		end
		Simulation.customerTick(g, ctx, step)
		if g.time.day ~= before then
			g.today = { day = g.time.day, sold = 0, produced = 0, margin = 0 }
		end
	end
end

return Simulation
