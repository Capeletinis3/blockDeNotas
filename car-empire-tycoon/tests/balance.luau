--[[
	Bot de balance: juega una partida completa sin interfaz con una estrategia razonable (la que sugiere el
	tutorial) y muestra el ritmo en minutos reales: primera venta, misiones del tutorial, sedes, investigaciones
	y dinero. Sirve para ajustar Catalog.ECON / DEMAND / SEDES; no es una prueba que falle.
	Uso:  lune run tests/balance.luau [dificultad] [minutos reales]
]]

local process = require("@lune/process")

local Build = require("./build")
Build.prepare()

local Catalog = require("./.build/shared/Catalog")
local Util = require("./.build/shared/Util")
local DesignCalc = require("./.build/shared/DesignCalc")
local Rules = require("./.build/shared/Rules")
local GameState = require("./.build/server/GameState")
local Simulation = require("./.build/server/Simulation")
local Actions = require("./.build/server/Actions")

local Bot = {}

local function seeded(seed: number)
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

-- Juega `minutes` minutos reales. Devuelve el registro de hitos y el estado final.
function Bot.play(difficulty: string, minutes: number, verbose: boolean?): any
	local ctx = { events = {}, today = "2026-10-25", yesterday = "2026-10-24", rng = seeded(7) }
	ctx.notify = function() end
	local g = GameState.newGame({ name = "Bot Motors", color = "#7667FF", logo = "pico", difficulty = difficulty, now = 1 })
	local log = { milestones = {}, research = {}, minMoney = g.money, samples = {} }
	local t = 0 -- segundos reales
	local function mark(key: string, text: string?)
		if not log.milestones[key] then
			log.milestones[key] = t / 60
			if verbose then
				print(string.format("  %6.1f min  %-6s %s  %s", t / 60, Util.gameDate(g.time.day), key, text or ""))
			end
		end
	end
	local function claim()
		for _, m in Catalog.MISSIONS do
			if Rules.missionState(g, m) == "lista" then
				local r = Actions.claimMission(g, ctx, { id = m.id })
				if r.ok then
					mark("mision " .. m.id, m.title)
				end
			end
		end
	end
	local plan = { { "pixel", "Pixel Uno" }, { "brisa", "Brisa Uno" }, { "toro", "Toro Uno" }, { "duna", "Duna Uno" } }
	local function design(i: number)
		local d = DesignCalc.newDraft(g, plan[i][1])
		d.name = plan[i][2]
		local r = Actions.saveDesign(g, ctx, { draft = d })
		if r.ok then
			mark("diseño " .. i, plan[i][2])
		end
	end
	local function hasLot(designId: string): boolean
		for _, l in g.lots do
			if l.designId == designId then
				return true
			end
		end
		return false
	end
	local function launch()
		for _, d in g.designs do
			if not hasLot(d.id) then
				local calc = DesignCalc.computeDesign(g, d)
				local est = Rules.designSalesEstimate(g, calc, d, calc.price)
				-- Un lote para unos 8 minutos de ventas, que se pueda pagar con la mitad de la caja.
				local qty = math.floor(math.min(est.rate * 8, g.money * 0.5 / calc.unitCost))
				qty = math.max(qty, 0)
				if qty >= 10 then
					local r = Actions.createLot(g, ctx, { designId = d.id, qty = qty })
					if r.ok then
						mark("lote " .. d.name, Util.num(qty) .. " u · " .. Util.num(est.rate, 1) .. "/min")
					end
				end
			end
		end
	end
	local function research()
		if g.research.active then
			return
		end
		local best = nil
		for _, key in Catalog.RESEARCH_ORDER do
			for _, n in Catalog.RESEARCH[key].nodes do
				if Rules.researchState(g, n) == "disponible" and g.money >= n.cost * 2 and (not best or n.rp < best.rp) then
					best = n
				end
			end
		end
		if best then
			local r = Actions.startResearch(g, ctx, { id = best.id })
			if r.ok then
				table.insert(log.research, { start = t / 60, id = best.id, name = best.name, rp = best.rp, cost = best.cost })
			end
		end
	end
	local function upgrade()
		for _, s in Catalog.STATIONS do
			local st = g.stations[s[1]]
			if st.level < Rules.maxStationLevel(g) and g.money > Rules.upgradeCost(st) * 4 then
				Actions.upgradeStation(g, ctx, { station = s[1] })
			end
		end
	end
	local doneBefore = 0
	local lastYear = Rules.year(g)
	while t < minutes * 60 do
		Simulation.simulate(g, ctx, 10)
		t += 1
		if g.money < log.minMoney then
			log.minMoney = g.money
		end
		assert(g.money >= 0, "dinero negativo")
		if #g.research.done > doneBefore then
			for i = doneBefore + 1, #g.research.done do
				for _, r in log.research do
					if r.id == g.research.done[i] and not r.finish then
						r.finish = t / 60
					end
				end
			end
			doneBefore = #g.research.done
		end
		if g.counters.unitsSold > 0 then
			mark("primera venta")
		end
		if t % 10 == 0 then
			claim()
			if #g.designs == 0 then
				design(1)
			elseif #g.designs == 1 and g.claimed.t5 then
				design(2)
			elseif #g.designs < #plan and g.sede >= #g.designs then
				design(#g.designs + 1)
			end
			launch()
			research()
			upgrade()
			local ok = true
			for _, c in Rules.expandChecks(g) do
				ok = ok and c[1]
			end
			if Rules.nextSede(g) and ok then
				local r = Actions.expandSede(g, ctx, {})
				if r.ok then
					mark("sede " .. g.sede, Rules.sede(g).name)
				end
			end
		end
		if t % 60 == 0 then
			table.insert(log.samples, { min = t / 60, money = g.money, sold = g.counters.unitsSold, year = Rules.year(g) })
		end
		if Rules.year(g) ~= lastYear then
			lastYear = Rules.year(g)
			if verbose and lastYear % 5 == 0 then
				print(string.format("  %6.1f min  %d · %s · vendidos %s · sede %d · %d tecnologías · %.1f PI/min", t / 60, lastYear, Util.money(g.money), Util.num(g.counters.unitsSold), g.sede, #g.research.done, Rules.piPerMinute(g)))
			end
		end
	end
	log.g = g
	return log
end

if not _G.BALANCE_AS_MODULE then
	local args = process.args
	local dif = args[1] or "normal"
	local minutes = tonumber(args[2]) or 120
	print("Bot de balance · dificultad " .. dif .. " · " .. minutes .. " minutos reales")
	local log = Bot.play(dif, minutes, true)
	print("\nInvestigaciones (minutos reales desde que empezó hasta que terminó):")
	for _, r in log.research do
		print(string.format("  %-34s %5d PI  %9s  %s", r.name, r.rp, Util.money(r.cost), r.finish and string.format("%.1f min", r.finish - r.start) or "sin terminar"))
	end
	print("Dinero mínimo: " .. Util.money(log.minMoney))
	Build.clean()
end

return Bot
