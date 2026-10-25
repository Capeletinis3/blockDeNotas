--!strict
--[[
	Partidas de demostración (makeDemo de la V3): «tutorial», «operacion» (empresa en funcionamiento)
	y «avanzada» (fábrica avanzada). Se juegan en memoria: nunca se guardan ni tocan las ranuras.
	Módulo puro (sin servicios de Roblox).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)
local DesignCalc = require(Shared.DesignCalc)

local GameState = require(script.Parent.GameState)
local Simulation = require(script.Parent.Simulation)
local Market = require(script.Parent.Market)

local Demo = {}

Demo.KINDS = { tutorial = "Tutorial", operacion = "Empresa en funcionamiento", avanzada = "Fábrica avanzada" }

local round = Util.round

function Demo.make(kind: string, ctx: any, now: number): any?
	if not Demo.KINDS[kind] then
		return nil
	end
	local g = GameState.newGame({ name = kind == "tutorial" and "Demo Garaje" or "Vortex Motors", color = "#7667FF", logo = "pico", difficulty = "normal", now = now })
	g.demo = kind
	if kind == "tutorial" then
		g.money = 50000
		g.candidates = Simulation.makeCandidates(g, ctx, 5)
		Market.refresh(g, ctx)
		return g
	end
	local avanz = kind == "avanzada"
	g.sede = avanz and 3 or 2
	g.counters.sedeLevel = g.sede
	g.level = avanz and 9 or 4
	g.reputation = avanz and 4.6 or 3.9
	g.money = avanz and 2400000 or 185000
	g.gems = avanz and 260 or 80
	g.rp = avanz and 900 or 120
	g.research.done = avanz and { "m1", "m2", "m3", "e1", "e2", "mt1", "mt2", "p1", "p3", "p2", "mk1", "mk2", "q1", "q3", "l1", "a1" } or { "m1", "e1", "p1", "mk1" }
	g.counters.researchDone = #g.research.done
	g.materials = avanz and { acero = 900, aluminio = 500, pintura = 260, electronica = 300, baterias = 220, cuero = 120 }
		or { acero = 240, aluminio = 120, pintura = 60, electronica = 60, baterias = 40, cuero = 20 }
	g.time.day = avanz and 64 or 21
	for _, t in { "t1", "t2", "t3", "t4", "t5" } do
		g.claimed[t] = true
	end
	local function mk(baseId: string, name: string, paint: string, extra: any?): any
		local d = DesignCalc.newDraft(g, baseId)
		d.id = GameState.uid(g, "d")
		d.name = name
		d.version = 1
		d.paint.primary = paint
		if extra then
			for k, v in extra do
				d[k] = v
			end
		end
		for _, it in DesignCalc.devItems(g, d) do
			if not Util.contains(g.devPaid, it.key) then
				table.insert(g.devPaid, it.key)
			end
		end
		return d
	end
	local ds = { mk("aurora", "Aurora GT", "#4F5BD5", { spoiler = true }), mk("brisa", "Brisa Sedán", "#E8ECF2"), mk("titan", "Titán SUV", "#2E7D5B") }
	if avanz then
		table.insert(ds, mk("rayo", "Rayo E", "#42B8E5"))
		table.insert(ds, mk("vento", "Halcón Vento SS", "#F7C95C", { spoiler = true }))
		ds[5].parts.motor = "v8"
	end
	g.designs = ds
	local staff = avanz and 14 or 4
	local roles = { "Mecánico", "Ingeniero", "Vendedor", "Diseñador", "Inspector", "Marketing" }
	local assigns = { "chasis", "motor", "ventas", "interior", "calidad", "marketing", "pintura", "laboratorio", "entrega" }
	for i = 0, staff - 1 do
		table.insert(g.employees, {
			id = GameState.uid(g, "e"),
			name = Catalog.FIRST[i % #Catalog.FIRST + 1] .. " " .. Catalog.LAST[i % #Catalog.LAST + 1],
			role = roles[i % #roles + 1],
			level = 3 + i % 4,
			skill = 60 + (i * 7) % 35,
			salary = 1200 + (i % 4) * 300,
			energy = 70 + (i * 13) % 30,
			status = "activo",
			assign = assigns[i % #assigns + 1],
		})
	end
	g.counters.hires = staff
	local letters = "VM"
	-- Historial de ventas de los últimos 30 días (marcadas como demostración).
	local dayNow = g.time.day
	local serial = 0
	local salaries = Rules.salaries(g)
	for d = dayNow - 30, dayNow - 1 do
		local n = avanz and (6 + math.floor(ctx.rng() * 6)) or (1 + math.floor(ctx.rng() * 3))
		local agg = GameState.day(g, d)
		for _ = 1, n do
			local des = Simulation.pick(ctx, ds)
			local c = DesignCalc.computeDesign(g, des)
			local price = round(c.price * (0.92 + ctx.rng() * 0.12) / 100) * 100
			serial += 1
			local id = GameState.uid(g, "u")
			local serialText = letters .. "-" .. string.format("%04d", serial)
			table.insert(g.units, {
				id = id, serial = serialText, designId = des.id, designVersion = 1, name = des.name, type = Catalog.base(des.baseId).type,
				spec = Util.deepCopy(des), stats = Util.deepCopy(c), cost = c.unitCost, charged = { money = c.unitCost, mats = Util.deepCopy(c.mats), boost = false, factor = 1 },
				quality = c.quality, status = "vendido", price = price, discount = 0, createdDay = d - 1, soldDay = d, soldPrice = price,
			})
			table.insert(g.sales, {
				id = GameState.uid(g, "s"), day = d, at = "11:40", unitId = id, serial = serialText, designId = des.id, designVersion = 1, name = des.name,
				type = Catalog.base(des.baseId).type, listPrice = c.price, finalListPrice = c.price, price = price, cost = c.unitCost, fee = 0,
				margin = price - c.unitCost, channel = "concesionario", buyer = Simulation.pick(ctx, Catalog.CUSTOMER_NAMES), demo = true,
			})
			table.insert(g.ledger, { day = d, min = 600, type = "fabricacion", amount = -c.unitCost, note = "Fabricación (demostración)" })
			table.insert(g.ledger, { day = d, min = 700, type = "venta", amount = price, note = "Venta (demostración)" })
			agg.revenue += price
			agg.cogs += c.unitCost
			agg.units += 1
			agg.margin += price - c.unitCost
			agg.produced += 1
			agg.flow.fabricacion = (agg.flow.fabricacion or 0) - c.unitCost
			agg.flow.venta = (agg.flow.venta or 0) + price
		end
		table.insert(g.ledger, { day = d, min = 0, type = "salarios", amount = -salaries, note = "Salarios (demostración)" })
		agg.flow.salarios = (agg.flow.salarios or 0) - salaries
	end
	g.counters.unitsSold = #g.sales
	g.counters.unitsProduced = #g.sales
	g.counters.designsSaved = #ds
	g.counters.serial = serial
	-- Unidades actuales: las primeras van al salón, el resto al almacén.
	local caps = Rules.caps(g)
	for i = 0, (avanz and 10 or 4) - 1 do
		local des = ds[i % #ds + 1]
		local c = DesignCalc.computeDesign(g, des)
		serial += 1
		g.counters.serial = serial
		table.insert(g.units, {
			id = GameState.uid(g, "u"), serial = letters .. "-" .. string.format("%04d", serial), designId = des.id, designVersion = 1, name = des.name,
			type = Catalog.base(des.baseId).type, spec = Util.deepCopy(des), stats = Util.deepCopy(c), cost = c.unitCost,
			charged = { money = c.unitCost, mats = Util.deepCopy(c.mats), boost = false, factor = 1 }, quality = c.quality,
			status = i < caps.showroom and "salon" or "almacen", price = c.price, discount = 0, createdDay = dayNow - 1,
		})
	end
	local function order(d: any, qty: number, line: number, prio: string)
		local o = Simulation.makeOrder(g, Simulation.designSnapshot(g, d), qty, line, prio)
		table.insert(g.production.orders, o)
	end
	order(ds[1], avanz and 6 or 2, 1, "alta")
	order(ds[2], 3, 1, "media")
	if avanz then
		order(ds[4], 4, 2, "alta")
		g.production.auto = true
	end
	Simulation.sortOrders(g)
	g.production.lastDesign = ds[1].id
	g.candidates = Simulation.makeCandidates(g, ctx, 5)
	GameState.trim(g)
	Market.refresh(g, ctx)
	for _ = 1, avanz and 4 or 2 do
		Simulation.spawnCustomer(g, ctx)
	end
	return g
end

return Demo
