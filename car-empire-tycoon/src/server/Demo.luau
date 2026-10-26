--!strict
--[[
	Partidas de demostración: «tutorial» (empresa recién fundada en 1970), «operacion» (empresa en
	funcionamiento en 1974) y «avanzada» (corporación en 1992). Se juegan en memoria: nunca se guardan ni
	tocan las ranuras. Los lotes y las estadísticas de los meses anteriores son coherentes entre sí.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)
local DesignCalc = require(Shared.DesignCalc)

local GameState = require(script.Parent.GameState)
local Simulation = require(script.Parent.Simulation)

local Demo = {}

Demo.KINDS = { tutorial = "Tutorial", operacion = "Empresa en funcionamiento", avanzada = "Fábrica avanzada" }

local round = Util.round

function Demo.make(kind: string, ctx: any, now: number): any?
	if not Demo.KINDS[kind] then
		return nil
	end
	local g = GameState.newGame({ name = kind == "tutorial" and "Demo Garaje" or "Vortex Motors", color = "#7667FF", logo = "pico", difficulty = "normal", now = now })
	g.demo = kind
	g.candidates = Simulation.makeCandidates(g, ctx, 5)
	if kind == "tutorial" then
		return g
	end
	local avanz = kind == "avanzada"
	g.time.day = avanz and (22 * 12 + 3) or (4 * 12 + 2)
	g.sede = avanz and 4 or 2
	g.counters.sedeLevel = g.sede
	g.level = avanz and 12 or 4
	g.reputation = avanz and 4.2 or 3.4
	g.money = avanz and 12500000 or 240000
	g.research.done = avanz
			and { "mo1", "mo2", "mo3", "mo4", "mo5", "ca1", "ca2", "ca3", "ca4", "tr1", "tr2", "tr3", "se1", "se2", "se3", "se4", "co1", "co2", "co3", "co4", "pr1", "pr2", "pr3", "pr4", "el1", "el2", "ma1", "ma2", "ma3", "mk1", "mk2", "mk3" }
		or { "mo1", "ca1", "se1", "pr1", "pr2", "mk1", "co1" }
	g.counters.researchDone = #g.research.done
	g.rp = avanz and 300 or 12
	for _, s in g.stations do
		s.level = avanz and 4 or 2
	end
	g.counters.stationUpgrades = avanz and 18 or 6
	for _, t in { "t1", "t2", "t3", "t4", "t5", "t6", "s1", "s2" } do
		g.claimed[t] = true
	end
	if avanz then
		for _, t in { "s2", "s3", "s4", "s5", "s6" } do
			g.claimed[t] = true
		end
	end

	local function mk(baseId: string, name: string, paint: string, extra: any?): any
		local d = DesignCalc.newDraft(g, baseId)
		d.id = GameState.uid(g, "d")
		d.name = name
		d.version = 1
		d.paint.primary = paint
		d.modelYear = Rules.year(g) - 1
		if extra then
			for k, v in extra do
				d[k] = v
			end
		end
		d.generation = DesignCalc.generationLabel(d.modelYear, d.gen)
		for _, it in DesignCalc.devItems(g, d) do
			if not Util.contains(g.devPaid, it.key) then
				table.insert(g.devPaid, it.key)
			end
		end
		table.insert(g.designs, d)
		return d
	end
	local ds
	if avanz then
		ds = {
			mk("brisa", "Brisa Sedán", "#E8ECF2", { objective = "Familiar", parts = { motor = "v6", turbo = "none", transmision = "auto4", traccion = "fwd", frenos = "abs", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none", seguridad = "airbag" } }),
			mk("titan", "Titán SUV", "#2E7D5B", { objective = "Familiar" }),
			mk("aurora", "Aurora GT", "#4F5BD5", { objective = "Deportivo", spoiler = true }),
			mk("vento", "Halcón Vento SS", "#F7C95C", { objective = "Competición", spoiler = true }),
		}
	else
		ds = {
			mk("brisa", "Brisa Familiar", "#E8ECF2", { objective = "Familiar" }),
			mk("pixel", "Pixel Ciudad", "#4F5BD5", { objective = "Económico" }),
			mk("toro", "Toro Trabajo", "#8D6E4F", { objective = "Todoterreno" }),
		}
	end
	g.counters.designsSaved = #ds

	-- Lotes: { diseño, encargadas, fabricadas, vendidas, estado de producción }
	local function lot(d: any, qty: number, produced: number, sold: number, prodState: string, priceK: number?): any
		local snap = Simulation.designSnapshot(g, d)
		local l = Simulation.makeLot(g, snap, qty, round(snap.calc.price * (priceK or 1) / 10) * 10)
		l.produced, l.sold = produced, sold
		l.costSpent = produced * l.unitCost
		l.revenue = sold * l.price
		l.prodState = prodState
		l.createdDay = g.time.day - 6
		return l
	end
	local scale = avanz and 40 or 1
	g.lots = {
		lot(ds[1], 600 * scale, 420 * scale, 300 * scale, "produciendo"),
		lot(ds[2], 300 * scale, 300 * scale, 180 * scale, "completado"),
		lot(ds[3], 1000 * scale, 0, 0, "cola", 0.95),
	}
	if avanz then
		table.insert(g.lots, lot(ds[4], 2500, 900, 640, "produciendo", 1.05))
	end
	local hist = lot(ds[1], 250 * scale, 250 * scale, 250 * scale, "completado")
	hist.saleState = "agotado"
	hist.endDay = g.time.day - 10
	local retired = lot(ds[2], 200 * scale, 180 * scale, 160 * scale, "cancelado", 1.25)
	retired.discarded = 20 * scale
	retired.qty = retired.produced
	retired.saleState = "retirado"
	retired.lossDiscarded = retired.discarded * retired.unitCost
	retired.endDay = g.time.day - 3
	-- El historial pasa por el mismo camino que el juego: resumen permanente + versión liviana.
	for _, l in { hist, retired } do
		local endDay = l.endDay
		Simulation.archiveLot(g, l)
		g.lotHistory[1].endDay = endDay
	end
	for _, l in g.lots do
		Simulation.registerModel(g, l)
		if l.sold >= Catalog.ECON.launchSold then
			g.launched[l.designId] = true
		end
	end
	-- Estados de producción coherentes con las líneas de la sede (sin avanzar el tiempo).
	Simulation.stepProduction(g, ctx, 0)
	g.counters.lotsLaunched = #g.lots + 2
	g.counters.lotsSoldOut = 1
	g.counters.lotsRetired = 1

	-- Personal
	local staff = avanz and 12 or 4
	local roles = { "Mecánico", "Ingeniero", "Vendedor", "Diseñador", "Inspector", "Marketing" }
	local assigns = { "chasis", "motor", "ventas", "laboratorio", "calidad", "marketing", "pintura", "interior", "entrega" }
	for i = 1, staff do
		local lvl = 2 + (i % 4)
		table.insert(g.employees, {
			id = GameState.uid(g, "e"),
			name = Simulation.pick(ctx, { "Sofía Arce", "Mateo Ruiz", "Lara Sosa", "Julián Paz", "Carla Vega", "Ramiro Gil", "Elena Mora", "Diego Núñez" }),
			role = roles[(i - 1) % #roles + 1],
			level = lvl,
			skill = 50 + lvl * 7,
			salary = 800 + lvl * 400,
			assign = assigns[(i - 1) % #assigns + 1],
		})
	end
	g.counters.hires = staff

	-- Meses anteriores: ventas y gastos coherentes con los lotes (demostración).
	for d = g.time.day - 23, g.time.day do
		local ds2 = GameState.day(g, d)
		local units = round((avanz and 900 or 22) * (0.75 + ctx.rng() * 0.5))
		local avg = g.lots[1].price
		local cost = g.lots[1].unitCost
		ds2.units = units
		ds2.revenue = units * avg
		ds2.cogs = units * cost
		ds2.margin = units * (avg - cost)
		ds2.produced = round(units * 1.1)
		ds2.flow.venta = ds2.revenue
		ds2.flow.fabricacion = -ds2.produced * cost
		ds2.flow.salarios = -Rules.salaries(g)
	end
	-- Los totales de la empresa coinciden con los lotes (activos e historial).
	local lotSold, lotMade, lotRev, lotMargin = 0, 0, 0, 0
	for _, list in { g.lots, g.lotHistory } do
		for _, l in list do
			lotSold += l.sold
			lotMade += l.produced
			lotRev += l.revenue
			lotMargin += l.sold * (l.price - l.unitCost)
		end
	end
	g.counters.unitsSold = lotSold
	g.counters.unitsProduced = lotMade
	g.counters.revenueTotal = lotRev
	g.counters.marginTotal = lotMargin
	table.insert(g.ledger, { day = g.time.day - 2, min = 0, type = "desarrollo", amount = -16000, note = "Licencia del modelo Brisa Sedán (demostración)" })
	table.insert(g.ledger, { day = g.time.day - 1, min = 0, type = "investigacion", amount = -9600, note = "Investigación: Control de calidad estadístico (demostración)" })
	return g
end

return Demo
