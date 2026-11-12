--!strict
--[[
	Car Empire Tycoon — autoprueba para Roblox Studio (etapa 11).

	NO se ejecuta sola y no forma parte del juego: vive en ServerStorage (los clientes no la ven).
	Se usa durante una prueba (Play) desde la barra de comandos en modo SERVIDOR:

		require(game.ServerStorage.CarEmpireStudioTests.AutoPrueba)()

	Qué hace (todo sobre una empresa de prueba en memoria, aislada):
	  1. Entorno: Studio, servidor, remotos creados por el servidor, módulos compartidos y carrocería 3D.
	  2. Carga de módulos: requiere cada ModuleScript compartido y del servidor y avisa si alguno falla.
	  3. Primer ciclo real con el motor de Roblox: crea una empresa NUEVA en memoria (no la de ningún
	     jugador), diseña, fabrica, recibe reseñas, vende y vuelve a diseñar, con el capital inicial del
	     catálogo y sin fondos extra. Comprueba la contabilidad (saldo final = inicial + ingresos − egresos).
	  4. Rechazos: solicitudes inválidas y repetidas no cambian la partida.

	NO toca DataStore, no lee ni modifica partidas de jugadores, no compra nada y no cambia la configuración.
	Para publicar el juego se puede borrar esta carpeta sin afectar nada.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local results = { ok = 0, fail = 0, lines = {} :: { string } }

local function report(cond: any, what: string)
	if cond then
		results.ok += 1
		print("[AUTOPRUEBA] ✓ " .. what)
	else
		results.fail += 1
		warn("[AUTOPRUEBA] ✗ " .. what)
	end
end

local function section(name: string)
	print("[AUTOPRUEBA] —— " .. name)
end

-- opts.modules (solo para las pruebas automáticas fuera de Studio): módulos ya cargados; se omiten las
-- secciones 1 y 2, que dependen del árbol real de Roblox.
return function(opts: any?): any
	results.ok, results.fail = 0, 0
	local t0 = os.clock()
	local loaded: { [string]: any } = {}
	if opts and opts.modules then
		loaded = opts.modules
	else
		section("1. Entorno")
		report(RunService:IsStudio(), "se ejecuta en Roblox Studio")
		report(RunService:IsServer(), "se ejecuta del lado del servidor (barra de comandos en modo Server)")
		local remotes = ReplicatedStorage:FindFirstChild("CarEmpireRemotes")
		report(remotes ~= nil, "el servidor creó ReplicatedStorage.CarEmpireRemotes")
		for _, pair in { { "Request", "RemoteFunction" }, { "State", "RemoteEvent" }, { "Notice", "RemoteEvent" }, { "Open", "RemoteEvent" }, { "Avatares", "RemoteEvent" } } do
			local r = remotes and remotes:FindFirstChild(pair[1])
			report(r ~= nil and r:IsA(pair[2]), "remoto " .. pair[1] .. " (" .. pair[2] .. ")")
		end
		local shared = ReplicatedStorage:FindFirstChild("CarEmpireShared")
		local server = ServerScriptService:FindFirstChild("CarEmpireServer")
		report(shared ~= nil, "módulos compartidos en ReplicatedStorage.CarEmpireShared")
		report(server ~= nil, "scripts del servidor en ServerScriptService.CarEmpireServer")
		local vehicles = ServerStorage:FindFirstChild("VehicleModels")
		report(vehicles ~= nil and vehicles:FindFirstChild("Pioneer70_World") ~= nil, "carrocería original Pioneer 70 en ServerStorage.VehicleModels")
		local assets = ReplicatedStorage:FindFirstChild("CarEmpireAssets")
		local publicCopy = assets and assets:FindFirstChild("VehicleModels") and assets.VehicleModels:FindFirstChild("Pioneer70_World")
		report(publicCopy ~= nil, "copia pública de la carrocería (sin scripts) para el cliente")
		if publicCopy then
			local scripts = 0
			for _, d in publicCopy:GetDescendants() do
				if d:IsA("LuaSourceContainer") then
					scripts += 1
				end
			end
			report(scripts == 0, "la copia pública no tiene scripts")
		end
		if not shared or not server then
			warn("[AUTOPRUEBA] faltan carpetas del juego: no se sigue")
			return results
		end

		section("2. Carga de módulos")
		for _, folder in { shared, server } do
			for _, m in folder:GetChildren() do
				if m:IsA("ModuleScript") then
					local ok, mod = pcall(require, m)
					report(ok, "require " .. folder.Name .. "." .. m.Name .. (ok and "" or (": " .. tostring(mod))))
					if ok then
						loaded[m.Name] = mod
					end
				end
			end
		end
	end
	local Catalog, Rules, DesignCalc = loaded.Catalog, loaded.Rules, loaded.DesignCalc
	local GameState, Simulation, Actions = loaded.GameState, loaded.Simulation, loaded.Actions
	if not (Catalog and Rules and DesignCalc and GameState and Simulation and Actions) then
		warn("[AUTOPRUEBA] no cargaron los módulos principales: no se sigue")
		return results
	end

	section("3. Primer ciclo (empresa de prueba en memoria)")
	local rng = Random.new(20261112)
	local ctx = { events = {}, today = "2026-11-12", yesterday = "2026-11-11", rng = function(): number
		return rng:NextNumber()
	end }
	ctx.notify = function(kind: string, text: string)
		table.insert(ctx.events, { kind, text })
	end
	local g = GameState.newGame({ name = "Autoprueba SA", color = "#7667FF", logo = "pico", now = os.time(), id = "autoprueba-" .. HttpService:GenerateGUID(false) })
	report(g.money == Catalog.START.money, "capital inicial del catálogo: $" .. tostring(g.money))
	report(Rules.year(g) == 1970, "año inicial 1970 (" .. tostring(Rules.year(g)) .. ")")
	local valid, why = GameState.validate(g)
	report(valid, "estado inicial válido" .. (valid and "" or (": " .. tostring(why))))

	local function flows(): number
		local sum = 0
		for _, ds in g.stats.days do
			for _, v in ds.flow or {} do
				sum += v
			end
		end
		return sum
	end
	local money0, flow0 = g.money, flows()
	local function balanced(what: string)
		local d = (g.money - money0) - (flows() - flow0)
		report(math.abs(d) < 0.5, "contabilidad después de " .. what .. " (diferencia " .. tostring(d) .. ")")
	end
	local function run(minutes: number, stop: () -> boolean): boolean
		for _ = 1, math.ceil(minutes / 10) do
			Simulation.simulate(g, ctx, 10)
			if stop() then
				return true
			end
		end
		return stop()
	end

	local draft = DesignCalc.newDraft(g, "brisa")
	draft.name = "Autoprueba 70"
	local r = Actions.saveDesign(g, ctx, { draft = draft })
	report(r.ok, "diseño finalizado: " .. tostring(r.msg))
	balanced("finalizar el diseño")
	local d = g.designs[#g.designs]
	local again = Actions.createLot(g, ctx, { designId = "no-existe", qty = 10 })
	report(not again.ok, "un lote de un diseño inexistente se rechaza")
	local before = HttpService:JSONEncode(g)
	local tooBig = Actions.createLot(g, ctx, { designId = d and d.id, qty = Catalog.RULES.maxLotQty })
	report(not tooBig.ok and HttpService:JSONEncode(g) == before, "un lote impagable se rechaza sin cambiar nada")
	local qty = 30
	r = Actions.createLot(g, ctx, { designId = d and d.id, qty = qty })
	report(r.ok, "lote de " .. qty .. " unidades: " .. tostring(r.msg))
	balanced("pagar la fabricación")
	local dup = Actions.createLot(g, ctx, { designId = d and d.id, qty = qty })
	report(not dup.ok, "el mismo modelo no se fabrica dos veces")
	local lotId = r.lotId
	local function lot(): any
		for _, l in g.lots do
			if l.id == lotId then
				return l
			end
		end
		return nil
	end
	run(60 * 24 * 60, function()
		local l = lot()
		return l == nil or l.saleState ~= "produccion"
	end)
	local l = lot()
	report(l and l.produced == qty, "fabricación completa (" .. tostring(l and l.produced) .. "/" .. qty .. ")")
	report(l and l.review and #(l.review.scores or {}) == 4, "reseñas de los cuatro críticos (promedio " .. tostring(l and l.review and l.review.avg) .. "/10)")
	local reviewBefore = l and l.review and HttpService:JSONEncode(l.review)
	report(l and l.saleState == "por lanzar" and l.refPrice and l.refPrice > 0, "precio recomendado: $" .. tostring(l and l.refPrice))
	r = Actions.launchSale(g, ctx, { lotId = lotId, price = l and l.refPrice })
	report(r.ok, "a la venta: " .. tostring(r.msg))
	run(60 * 24 * 365 * 3, function()
		local x = lot()
		return x == nil or x.sold >= x.produced
	end)
	local h = nil
	for _, x in g.lotHistory do
		if x.id == lotId then
			h = x
		end
	end
	local sold = (lot() and lot().sold) or (h and h.sold) or 0
	report(sold == qty, "ventas progresivas hasta agotar el inventario (" .. tostring(sold) .. "/" .. qty .. ")")
	report(g.counters.unitsSold <= g.counters.unitsProduced, "nunca se vende más de lo fabricado")
	report(lot() == nil or HttpService:JSONEncode(lot().review) == reviewBefore, "las reseñas no se regeneraron")
	balanced("vender el lote")
	report(g.money >= 0, "el dinero nunca queda negativo ($" .. tostring(g.money) .. ")")
	local draft2 = DesignCalc.newDraft(g, "brisa")
	draft2.name = "Autoprueba 71"
	r = Actions.saveDesign(g, ctx, { draft = draft2 })
	report(r.ok, "se puede diseñar otro auto: " .. tostring(r.msg))
	valid, why = GameState.validate(g)
	report(valid, "la partida de prueba sigue siendo válida" .. (valid and "" or (": " .. tostring(why))))

	print(string.format("[AUTOPRUEBA] Resultado: %d correctas, %d fallidas (%.1f s). Copiá estas líneas del Output al informar.", results.ok, results.fail, os.clock() - t0))
	return results
end
