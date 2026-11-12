--[[
	Medición de rendimiento del SERVIDOR fuera de Roblox (Lune). Sirve para comparar versiones del código
	con la misma partida; NO mide FPS, render, física ni memoria del motor (eso es del MicroProfiler y de
	las estadísticas de Studio, ver docs/PRUEBAS_ROBLOX_STUDIO.md).
	Mide: costo de Sessions:tick (1 s real) por cantidad de jugadores y etapa de la partida, tamaño del
	estado completo enviado al cliente, del envío segundo a segundo y del guardado.
	Uso: lune run tests/perf.luau
]]
local serde = require("@lune/serde")
_G.BALANCE_AS_MODULE = true
local Bot = require("./balance") -- prepara tests/.build
local Catalog = require("./.build/shared/Catalog")
local Rules = require("./.build/shared/Rules")
local Util = require("./.build/shared/Util")
local GameState = require("./.build/server/GameState")
local DataService = require("./.build/server/DataService")
local Sessions = require("./.build/server/Sessions")

local function jsonCopy(v: any): any
	return serde.decode("json", serde.encode("json", v))
end

local function server(clock: any)
	local sizes = { full = 0, tick = 0, fullN = 0, tickN = 0 }
	local store = DataService.MemoryStore.new(jsonCopy)
	local data = DataService.new(store, {
		jobId = "perf",
		now = function()
			return clock.t
		end,
		wait = function() end,
		copy = jsonCopy,
		validate = GameState.validate,
		loadProfile = GameState.loadProfile,
	})
	local mgr = Sessions.new({
		data = data,
		filter = function(t: string)
			return t, nil
		end,
		push = function(_, payload: any)
			local n = #serde.encode("json", payload)
			if payload.tick then
				sizes.tick += n
				sizes.tickN += 1
			else
				sizes.full += n
				sizes.fullN += 1
			end
		end,
		notice = function() end,
		newRng = function()
			local state = 1
			return function(): number
				state = (state * 1103515245 + 12345) % 2147483648
				return state / 2147483648
			end
		end,
		now = function()
			return clock.t
		end,
		clock = function()
			return clock.c
		end,
		wait = function() end,
		spawn = function(fn: any)
			fn()
		end,
		log = function() end,
		saveMode = "memory",
	})
	return mgr, sizes, store
end

local function measure(label: string, start: any?, players: number, ticks: number)
	local clock = { t = 1000, c = 0 }
	local mgr, sizes, store = server(clock)
	local list = {}
	for i = 1, players do
		local p = { UserId = 9000 + i, Name = "p" .. i }
		mgr:add(p)
		assert(mgr:request(p, "createCompany", { slot = "1", name = "Perf " .. i, color = "#7667FF", logo = "pico" }).ok)
		if start then
			clock.c += 3
			assert(mgr:request(p, "leaveCompany", {}).ok)
			mgr.list[p].profile.slots["1"] = jsonCopy(start)
			clock.c += 3
			assert(mgr:request(p, "selectSlot", { slot = "1" }).ok)
		end
		mgr:request(p, "setSpeed", { speed = 3 })
		table.insert(list, p)
	end
	sizes.full, sizes.tick, sizes.fullN, sizes.tickN = 0, 0, 0, 0
	local times = {}
	for _ = 1, ticks do
		clock.c += 1
		clock.t += 1
		local t0 = os.clock()
		mgr:tick()
		table.insert(times, (os.clock() - t0) * 1000)
	end
	table.sort(times)
	local sum = 0
	for _, v in times do
		sum += v
	end
	local g = mgr.list[list[1]].game
	local saved = store.data["player_9001"] and #serde.encode("json", store.data["player_9001"]) or 0
	print(string.format("%-34s %2d jug · tick medio %6.2f ms · p95 %6.2f ms · máx %6.2f ms · estado %6.1f KB · seg. a seg. %5.1f KB · guardado %6.1f KB · año %d",
		label, players, sum / #times, times[math.ceil(#times * 0.95)], times[#times],
		sizes.fullN > 0 and sizes.full / sizes.fullN / 1024 or 0, sizes.tickN > 0 and sizes.tick / sizes.tickN / 1024 or 0, saved / 1024, Rules.year(g)))
	print(string.format("%-34s        envíos completos %4d (%.2f por jugador y minuto) · red al cliente %.1f KB/s por jugador",
		"", sizes.fullN, sizes.fullN / players / (ticks / 60), (sizes.full + sizes.tick) / players / ticks / 1024))
end

print("Rendimiento del servidor (Lune " .. tostring(_VERSION) .. ", fuera de Roblox)")
local mid = Bot.play("normal", 300).g
local late = Bot.play("normal", 760).g
measure("A/B empresa nueva", nil, 1, 300)
measure("D empresa ≈1990 (fábrica y ventas)", mid, 1, 300)
measure("H empresa avanzada (≈2030)", late, 1, 300)
measure("I ocho jugadores ≈1990", mid, 8, 120)
measure("I ocho jugadores avanzados", late, 8, 60)
local _ = Catalog
local _u = Util
require("./build").clean()
