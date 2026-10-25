--!strict
--[[
	Simulación de la partida. Solo corre en el servidor. Reglas portadas de la V3:
	stepProduction, finishUnit, clientes, investigación, personal, cambio de día y venta atómica.
	ctx = { rng: () -> number, notify: (kind, text) -> () }

	Orden de cada paso de 10 minutos: reloj → cambio de día (si corresponde) → fabricación →
	clientes → investigación → personal. Así cada resultado queda asociado al día en que ocurre.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local DesignCalc = require(Shared.DesignCalc)
local Rules = require(Shared.Rules)
local GameState = require(script.Parent.GameState)

local round = Util.round
local clamp = Util.clamp
local money = Util.money

local Simulation = {}

local function market(): any
	return require(script.Parent.Market) :: any
end

local function pick(ctx: any, list: { any }): any
	return list[math.floor(ctx.rng() * #list) + 1]
end
Simulation.pick = pick

-- Dinero ---------------------------------------------------------------------------

function Simulation.ledger(g: any, kind: string, amount: number, note: string)
	amount = round(amount)
	table.insert(g.ledger, { day = g.time.day, min = math.floor(g.time.minute), type = kind, amount = amount, note = note })
	local ds = GameState.day(g)
	ds.flow[kind] = (ds.flow[kind] or 0) + amount
	GameState.trim(g)
end

-- Cobra solo si alcanza; nunca deja el dinero en negativo.
function Simulation.spend(g: any, amount: number, kind: string, note: string): boolean
	amount = round(amount)
	if not (amount >= 0) or g.money < amount then
		return false
	end
	if amount == 0 then
		return true
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

function Simulation.notify(g: any, ctx: any, kind: string, text: string, go: string?)
	table.insert(g.notifications, 1, { id = GameState.uid(g, "n"), kind = kind, text = text, go = go, read = false, day = g.time.day, at = Util.clock(g.time.minute) })
	while #g.notifications > 40 do
		table.remove(g.notifications)
	end
	if ctx and ctx.notify then
		ctx.notify(kind, text)
	end
end

function Simulation.addXp(g: any, ctx: any, n: number)
	g.xp += n
	local up = false
	while g.xp >= Rules.xpForLevel(g.level) do
		g.xp -= Rules.xpForLevel(g.level)
		g.level += 1
		g.gems += 10
		up = true
	end
	if up then
		Simulation.notify(g, ctx, "nivel", "¡Subiste al nivel " .. g.level .. "! +10 gemas", "compania")
	end
end

-- Producción ------------------------------------------------------------------------

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
		at = Rules.absMinute(g),
	}
end

function Simulation.makeOrder(g: any, snap: any, qty: number, line: number, priority: string, auto: boolean?): any
	return {
		id = GameState.uid(g, "o"),
		designId = snap.id,
		design = Util.deepCopy(snap),
		qty = qty,
		done = 0,
		line = line,
		priority = priority,
		pos = Rules.absMinute(g) + #g.production.orders / 100,
		paused = false,
		status = "en cola",
		reason = "",
		missing = nil,
		progress = 0,
		unitStarted = false,
		cur = nil,
		auto = auto == true,
		created = Rules.absMinute(g),
		produced = {},
	}
end

-- Mantiene el orden manual dentro de la misma prioridad (orden estable).
function Simulation.sortOrders(g: any)
	local P = GameState.PRIORITIES
	table.sort(g.production.orders, function(a, b)
		if a.line ~= b.line then
			return a.line < b.line
		end
		if P[a.priority] ~= P[b.priority] then
			return P[a.priority] < P[b.priority]
		end
		if a.pos ~= b.pos then
			return a.pos < b.pos
		end
		return a.id < b.id
	end)
end

-- Cambia el motivo de detención y limpia los datos del problema anterior.
local function stop(order: any, reason: string, missing: { any }?)
	order.status = "detenida"
	order.reason = reason
	order.missing = missing
end

local function finishUnit(g: any, ctx: any, order: any)
	local snap = order.design
	local c = snap.calc
	local cur = order.cur
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
		-- Lo que realmente se cobró y consumió al empezar esta unidad.
		cost = cur.charged,
		charged = { money = cur.charged, mats = Util.deepCopy(cur.mats), boost = cur.boost, factor = cur.factor },
		quality = c.quality,
		status = "almacen",
		price = c.price,
		discount = 0,
		createdDay = g.time.day,
		orderId = order.id,
	}
	table.insert(g.units, unit)
	table.insert(order.produced, unit.id)
	order.done += 1
	order.unitStarted = false
	order.progress = 0
	order.cur = nil
	-- Desgaste de estaciones
	for _, st in Catalog.STATIONS do
		local s = g.stations[st[1]]
		local wear = (Catalog.RULES.wearPerUnit - (Rules.has(g, "p2") and 1 or 0)) * (0.6 + ctx.rng() * 0.8)
		s.condition = math.max(0, s.condition - wear)
		if s.condition < Catalog.RULES.breakdownAt and not s.broken then
			s.broken = true
			Simulation.notify(g, ctx, "aviso", "Avería en la estación de " .. string.lower(st[2]) .. ". Reparala para continuar.", "fabrica")
		end
	end
	g.counters.unitsProduced += 1
	local ds = GameState.day(g)
	ds.produced = (ds.produced or 0) + 1
	g.production.lastDesign = snap.id
	g.production.lastSnap = Util.deepCopy(snap)
	if order.done >= order.qty then
		table.insert(g.production.history, 1, {
			id = order.id,
			qty = order.qty,
			line = order.line,
			priority = order.priority,
			design = Util.deepCopy(snap), -- permite repetir esta misma versión aunque el proyecto cambie
			day = g.time.day,
		})
		while #g.production.history > 8 do
			table.remove(g.production.history)
		end
	end
	Simulation.addXp(g, ctx, 30)
	Simulation.notify(g, ctx, "ok", "Producción completada: " .. snap.name .. " v" .. snap.version .. " (" .. unit.serial .. ")", "autos")
end

function Simulation.stepProduction(g: any, ctx: any, minutes: number)
	local caps = Rules.caps(g)
	local speed = Rules.lineSpeed(g)
	local broken = Rules.brokenStation(g)
	Simulation.sortOrders(g)
	for line = 1, caps.lines do
		local order = nil
		for _, o in g.production.orders do
			if o.line == line and o.done < o.qty then
				if not o.paused and order == nil then
					order = o
				elseif not o.paused then
					o.status = "en cola"
					o.reason = ""
					o.missing = nil
				else
					o.status = "pausada"
				end
			end
		end
		if order then
			local proceed = true
			if broken then
				stop(order, "Avería en la estación de " .. string.lower(broken[2]))
				proceed = false
			elseif not order.unitStarted then
				-- Inicio de una unidad: lugar, materiales y dinero; recién entonces se cobra.
				local c = order.design.calc
				local factor = Rules.unitCostFactor(g)
				local cost = round(c.unitCost * factor)
				local miss = missingMats(g, c.mats)
				if Rules.warehouseUsed(g) >= caps.warehouse then
					stop(order, "Almacén lleno (" .. Rules.warehouseUsed(g) .. "/" .. caps.warehouse .. ")")
					proceed = false
				elseif #miss > 0 then
					stop(order, "Faltan materiales: " .. missingText(miss), miss)
					proceed = false
				elseif g.money < cost then
					stop(order, "Fondos insuficientes para fabricar (" .. money(cost) .. ")")
					proceed = false
				else
					local used = {}
					for k, n in c.mats do
						g.materials[k] -= n
						used[k] = n
					end
					Simulation.spend(g, cost, "fabricacion", "Fabricación de " .. order.design.name .. " v" .. order.design.version)
					order.cur = { mats = used, charged = cost, boost = factor > 1, factor = factor, startedAt = Rules.absMinute(g) }
					order.unitStarted = true
					order.unitCost = cost
					order.unitTotal = c.build
					order.progress = 0
				end
			end
			if proceed then
				order.status = "en producción"
				order.reason = ""
				order.missing = nil
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
	-- Producción automática (requiere «Producción automática»): repite la ÚLTIMA versión guardada
	-- del último diseño fabricado; si el proyecto se eliminó, repite la copia de la última orden terminada.
	if g.production.auto and Rules.has(g, "p3") then
		for line = 1, caps.lines do
			local busy = false
			for _, o in g.production.orders do
				if o.line == line then
					busy = true
				end
			end
			if not busy and Rules.warehouseUsed(g) < caps.warehouse then
				local snap = nil
				for _, d in g.designs do
					if d.id == g.production.lastDesign and not d.template then
						snap = Simulation.designSnapshot(g, d)
					end
				end
				snap = snap or g.production.lastSnap
				if snap and #g.production.orders < Catalog.RULES.maxOrders then
					table.insert(g.production.orders, Simulation.makeOrder(g, snap, 1, line, "media", true))
				end
			end
		end
	end
end

-- Concesionario --------------------------------------------------------------------

Simulation.finalPrice = Rules.finalPrice

-- Interés de un cliente por una unidad (regla compartida con el cliente para mostrar la demanda).
Simulation.interest = Rules.interest

local function showroomUnits(g: any): { any }
	local out = {}
	for _, u in g.units do
		if u.status == "salon" then
			table.insert(out, u)
		end
	end
	return out
end

function Simulation.customerRate(g: any, step: number): number
	local show = Rules.showroomUsed(g)
	if show == 0 then
		return 0
	end
	local dif = Catalog.DIFFICULTIES[g.company.difficulty] or Catalog.DIFFICULTIES.normal
	return 0.025 * step / 10 * (0.6 + g.reputation / 5) * dif.demand * (g.promo and Catalog.RULES.promoBoost or 1)
		* (Rules.has(g, "mk1") and 1.15 or 1) * (1 + Rules.staffBonus(g, "marketing") * 0.3) * math.min(2, 0.6 + show * 0.25)
end

function Simulation.spawnCustomer(g: any, ctx: any): any
	local show = showroomUnits(g)
	if #show == 0 then
		return nil
	end
	local dif = Catalog.DIFFICULTIES[g.company.difficulty] or Catalog.DIFFICULTIES.normal
	local target = pick(ctx, show)
	local wants = target.type
	if ctx.rng() >= 0.75 then
		wants = pick(ctx, Util.keys(Catalog.TYPES))
	end
	local fp = Rules.finalPrice(target)
	local budget = round(fp * (0.82 + ctx.rng() * 0.33) / 100) * 100
	local c = {
		id = GameState.uid(g, "k"),
		name = pick(ctx, Catalog.CUSTOMER_NAMES),
		budget = budget,
		wants = wants,
		pref = pick(ctx, Catalog.PREFS),
		unitId = target.id,
		patience = round((180 + ctx.rng() * 240) * dif.patience * (Rules.has(g, "l3") and 1.25 or 1)),
		waited = 0,
		state = "mirando",
		offer = nil,
		rounds = 0,
		interest = 0,
		rev = 0, -- cambia cada vez que cambia la negociación (invalida probabilidades mostradas)
	}
	c.interest = Simulation.interest(g, target, c)
	table.insert(g.customers, c)
	Simulation.notify(g, ctx, "info", c.name .. " entró al concesionario y mira el " .. target.name .. ".", "ventas")
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
	local now = Rules.absMinute(g)
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
					c.waited = 0
				else
					c.state = "se fue"
					c.leftAt = now
					active = false
				end
				c.rev += 1
			end
			if active then
				c.waited += minutes
				if c.state == "mirando" and c.waited > 40 then
					local uu = findUnit(g, c.unitId)
					local fp = Rules.finalPrice(uu)
					if c.interest >= 35 then
						c.state = "oferta"
						c.offer = math.min(c.budget, round(fp * (0.84 + c.interest / 1000) / 100) * 100)
						if c.offer >= fp then
							c.offer = fp
						end
						c.rev += 1
						Simulation.notify(g, ctx, "info", c.name .. " ofrece " .. money(c.offer) .. " por el " .. uu.name .. ".", "ventas")
					elseif c.waited > c.patience * 0.6 then
						c.state = "se fue"
						c.leftAt = now
						c.rev += 1
					end
				end
				if c.waited >= c.patience and c.state ~= "se fue" then
					c.state = "se fue"
					c.leftAt = now
					c.rev += 1
					Simulation.notify(g, ctx, "aviso", c.name .. " se fue del concesionario sin comprar.", "ventas")
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

-- Monto de contraoferta: siempre redondeado a $100 (el mismo redondeo que muestra el cliente).
function Simulation.roundAmount(amount: number): number
	return round(amount / 100) * 100
end

-- Probabilidad (0–100) de que el cliente acepte una contraoferta. Un monto mayor a su presupuesto
-- nunca se acepta. La misma función responde la consulta del cliente y resuelve la acción.
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
-- opts = { fee = número | nil, listPrice = precio de lista al momento, offer = oferta del cliente }
function Simulation.sellUnit(g: any, ctx: any, unitId: string, price: number, channel: string, buyer: string, opts: any?): any
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
	local fee = opts and opts.fee or 0
	u.status = "vendido"
	u.soldDay = g.time.day
	u.soldPrice = price
	Simulation.earn(g, price, "venta", "Venta de " .. u.name .. " (" .. u.serial .. ")")
	if fee > 0 then
		Simulation.spend(g, math.min(fee, g.money), "comision", "Comisión del mercado por " .. u.serial)
	end
	local margin = price - u.cost
	local sale = {
		id = GameState.uid(g, "s"),
		day = g.time.day,
		at = Util.clock(g.time.minute),
		unitId = u.id,
		serial = u.serial,
		designId = u.designId,
		designVersion = u.designVersion,
		name = u.name,
		type = u.type,
		listPrice = opts and opts.listPrice or u.price,
		finalListPrice = Rules.finalPrice(u),
		offer = opts and opts.offer or nil,
		price = price,
		cost = u.cost,
		fee = fee,
		margin = margin,
		channel = channel,
		buyer = buyer,
	}
	table.insert(g.sales, sale)
	local ds = GameState.day(g)
	ds.revenue += price
	ds.cogs += u.cost
	ds.units += 1
	ds.fees += fee
	ds.margin += margin
	g.counters.unitsSold += 1
	g.counters.revenueTotal = (g.counters.revenueTotal or 0) + price
	g.counters.marginTotal = (g.counters.marginTotal or 0) + margin
	g.reputation = clamp(g.reputation + (u.quality - 55) / 600 + (Rules.has(g, "q2") and 0.02 or 0.008) - (margin < 0 and 0.01 or 0), 1, 5)
	Simulation.addXp(g, ctx, 80)
	for _, c in g.customers do
		if c.unitId == u.id and c.state ~= "compró" then
			c.unitId = nil
			c.rev += 1
		end
	end
	for _, l in g.market.mine do
		if l.unitId == u.id and l.status == "activa" then
			l.status = "vendida"
		end
	end
	GameState.trim(g)
	return { ok = true, msg = "Venta realizada: " .. u.name .. " por " .. money(price), saleId = sale.id }
end

-- Personal --------------------------------------------------------------------------

function Simulation.makeCandidates(g: any, ctx: any, n: number): { any }
	local out = {}
	for _ = 1, n do
		local lvl = 1 + math.floor(ctx.rng() * math.min(6, 2 + g.level))
		table.insert(out, {
			id = GameState.uid(g, "c"),
			name = pick(ctx, Catalog.FIRST) .. " " .. pick(ctx, Catalog.LAST),
			role = pick(ctx, Catalog.ROLES),
			level = lvl,
			skill = clamp(40 + lvl * 7 + math.floor(ctx.rng() * 12), 30, 98),
			salary = 600 + lvl * 280,
			fee = 3000 + lvl * 2500,
		})
	end
	return out
end

-- Cambio de día ---------------------------------------------------------------------

function Simulation.dayRollover(g: any, ctx: any)
	-- Los movimientos de este bloque pertenecen al día que empieza.
	local sal = Rules.salaries(g)
	if sal > 0 then
		local pay = math.min(sal, g.money)
		if pay > 0 then
			g.money -= pay
			Simulation.ledger(g, "salarios", -pay, "Salarios del día")
		end
		if pay < sal then
			g.reputation = clamp(g.reputation - 0.05, 1, 5)
			Simulation.notify(g, ctx, "error", "No alcanzó el dinero para pagar todos los salarios. Bajó la reputación.", "personal")
		end
	end
	if g.promo then
		if not Simulation.spend(g, Catalog.RULES.promoCostPerDay, "promocion", "Promoción del concesionario") then
			g.promo = false
			Simulation.notify(g, ctx, "aviso", "La promoción se apagó por falta de fondos.", "ventas")
		end
	end
	g.rp += Rules.rpPerDay(g)
	if #g.candidates < 3 then
		for _, c in Simulation.makeCandidates(g, ctx, 2) do
			table.insert(g.candidates, c)
		end
	end
	market().refresh(g, ctx)
end

-- Reloj -------------------------------------------------------------------------------

function Simulation.simulate(g: any, ctx: any, minutes: number)
	local left = minutes
	while left > 0 do
		local step = math.min(left, 10)
		left -= step
		g.time.minute += step
		if g.time.minute >= Catalog.RULES.dayMinutes then
			g.time.minute -= Catalog.RULES.dayMinutes
			g.time.day += 1
			Simulation.dayRollover(g, ctx)
		end
		Simulation.stepProduction(g, ctx, step)
		local waiting = 0
		for _, c in g.customers do
			if c.state ~= "se fue" then
				waiting += 1
			end
		end
		if waiting < Catalog.RULES.maxCustomers and ctx.rng() < Simulation.customerRate(g, step) then
			Simulation.spawnCustomer(g, ctx)
		end
		Simulation.customerTick(g, ctx, step)
		local ra = g.research.active
		if ra then
			ra.progress += step
			local n = Catalog.researchNode(ra.id)
			if ra.progress >= n.minutes then
				table.insert(g.research.done, ra.id)
				g.research.active = nil
				g.counters.researchDone += 1
				Simulation.addXp(g, ctx, 150)
				Simulation.notify(g, ctx, "ok", "Investigación completada: " .. n.name .. ". " .. n.gain, "investigacion")
			end
		end
		for _, e in g.employees do
			if e.status == "descanso" then
				e.energy = math.min(100, e.energy + step * 0.25)
				if e.energy >= 100 then
					e.status = "activo"
					Simulation.notify(g, ctx, "info", e.name .. " volvió del descanso.", "personal")
				end
			elseif e.assign then
				e.energy = math.max(0, e.energy - step * 0.02)
			end
		end
	end
	market().tick(g, ctx)
end

return Simulation
