--!strict
--[[
	Car Empire Tycoon — servidor (etapa 1).
	• Una sesión por jugador; todas las acciones usan la partida de quien las pide (Player del remoto).
	• El cliente solo solicita acciones; dinero, compras, fabricación, ventas y propiedad se validan aquí.
	• Guardado por jugador con candado de sesión, reintentos y sin pisar datos válidos (DataService).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)

local GameState = require(script.Parent.GameState)
local Simulation = require(script.Parent.Simulation)
local Actions = require(script.Parent.Actions)
local DataService = require(script.Parent.DataService)
local Garage = require(script.Parent.Garage)

local STORE_NAME = "CarEmpireTycoon_v1"
local AUTOSAVE_SECONDS = 45
local MIN_SAVE_GAP = 7 -- límite de escritura por clave del DataStore

-- Remotos -------------------------------------------------------------------------
local remotes = Instance.new("Folder")
remotes.Name = "CarEmpireRemotes"
local Request = Instance.new("RemoteFunction")
Request.Name = "Request"
Request.Parent = remotes
local StateEvent = Instance.new("RemoteEvent")
StateEvent.Name = "State"
StateEvent.Parent = remotes
local NoticeEvent = Instance.new("RemoteEvent")
NoticeEvent.Name = "Notice"
NoticeEvent.Parent = remotes
local OpenEvent = Instance.new("RemoteEvent")
OpenEvent.Name = "Open"
OpenEvent.Parent = remotes
remotes.Parent = ReplicatedStorage

-- Almacenamiento ---------------------------------------------------------------------
local saveMode = "datastore" -- o "memory" (Studio sin acceso a la API: guardado temporal)
local data: any = nil
local storeReady = false

local function log(msg: string)
	warn("[CarEmpire] " .. msg)
end

task.spawn(function()
	local store: any = nil
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
		if RunService:IsStudio() then
			-- En Studio, comprobar si «Enable Studio Access to API Services» está activo.
			local probeOk, err = pcall(function()
				return result:GetAsync("probe_access")
			end)
			if not probeOk then
				log("DataStore no disponible en Studio (" .. tostring(err) .. "). Se usa guardado temporal en memoria.")
				store = nil
			end
		end
	else
		log("No se pudo abrir el DataStore: " .. tostring(result))
	end
	if store == nil then
		if RunService:IsStudio() then
			saveMode = "memory"
			store = DataService.MemoryStore.new(Util.deepCopy)
		else
			-- En un servidor publicado no se usa memoria: las cargas fallarán y no se pisará nada.
			store = {
				UpdateAsync = function()
					error("DataStore no disponible")
				end,
			}
		end
	end
	data = DataService.new(store, {
		jobId = game.JobId ~= "" and game.JobId or ("studio-" .. HttpService:GenerateGUID(false)),
		now = os.time,
		wait = function(s: number)
			task.wait(s)
		end,
		log = log,
		validate = GameState.validate,
		migrate = function(g: any)
			return GameState.migrate(g, os.time())
		end,
	})
	storeReady = true
end)

-- Sesiones ----------------------------------------------------------------------------
type Session = {
	player: Player,
	status: string, -- "loading" | "ready" | "failed"
	game: any,
	loadError: string?,
	loadCode: string?,
	canSave: boolean,
	dirty: boolean,
	saving: boolean,
	pendingSave: boolean,
	lastSave: number,
	lastAutosave: number,
	saveWarning: string?,
	busy: boolean,
	rng: Random,
	ctx: any,
	requests: { number },
	leaving: boolean,
}

local sessions: { [Player]: Session } = {}

local garage = Garage.new(function(who: Player, owner: Player?, screen: string)
	if owner == who then
		OpenEvent:FireClient(who, screen)
	elseif owner then
		NoticeEvent:FireClient(who, "info", "Este garaje es de " .. owner.DisplayName .. ".")
	end
end)

local function viewFor(g: any): any
	local v = GameState.view(g)
	-- El presupuesto de cada cliente es información oculta: no se envía al cliente.
	for _, c in v.customers do
		c.budget = nil
	end
	return v
end

local function push(s: Session)
	if s.leaving then
		return
	end
	StateEvent:FireClient(s.player, {
		status = s.status,
		saveMode = saveMode,
		saveWarning = s.saveWarning,
		loadError = s.loadError,
		loadCode = s.loadCode,
		game = s.game and viewFor(s.game) or nil,
	})
end

local function saveSession(s: Session, release: boolean?)
	if not data or not s.canSave then
		return
	end
	if not s.game then
		if release then
			data:release(s.player.UserId)
		end
		return
	end
	while s.saving do
		if not release then
			s.pendingSave = true
			return
		end
		task.wait(0.2)
	end
	s.saving = true
	s.pendingSave = false
	local wasDirty = s.dirty
	s.dirty = false
	local ok, msg, code = data:save(s.player.UserId, s.game, { release = release })
	s.saving = false
	s.lastSave = os.clock()
	if ok then
		if s.saveWarning and code == nil then
			s.saveWarning = nil
			push(s)
		end
	else
		s.dirty = s.dirty or wasDirty
		s.saveWarning = msg
		if code == "lost_lock" or code == "invalid" then
			s.canSave = false
		end
		push(s)
	end
end

local function requestSave(s: Session)
	s.pendingSave = true
end

local function loadSession(s: Session)
	while not storeReady do
		task.wait(0.1)
	end
	s.status = "loading"
	s.loadError = nil
	push(s)
	local ok, g, err, code = data:load(s.player.UserId)
	if sessions[s.player] ~= s then
		-- El jugador salió durante la carga: liberar el candado sin escribir la partida.
		if ok then
			data:release(s.player.UserId)
		end
		return
	end
	if ok then
		s.game = g
		s.status = "ready"
		s.canSave = true
		s.loadError = nil
		if g then
			local plot = garage:assign(s.player, g.company)
			if plot then
				garage:teleport(s.player)
				garage:update(s.player, g)
			end
		end
	else
		s.status = "failed"
		s.canSave = false
		s.loadError = err
		s.loadCode = code
	end
	push(s)
end

local function newSession(player: Player): Session
	local s: Session = {
		player = player,
		status = "loading",
		game = nil,
		loadError = nil,
		loadCode = nil,
		canSave = false,
		dirty = false,
		saving = false,
		pendingSave = false,
		lastSave = 0,
		lastAutosave = os.clock(),
		saveWarning = nil,
		busy = false,
		rng = Random.new(),
		ctx = nil,
		requests = {},
		leaving = false,
	}
	s.ctx = {
		rng = function(): number
			return s.rng:NextNumber()
		end,
		notify = function(kind: string, text: string)
			if not s.leaving then
				NoticeEvent:FireClient(player, kind, text)
			end
		end,
	}
	return s
end

local function onPlayerAdded(player: Player)
	local s = newSession(player)
	sessions[player] = s
	player.CharacterAdded:Connect(function()
		task.wait(0.3)
		if sessions[player] == s and s.game then
			garage:teleport(player)
		end
	end)
	task.spawn(loadSession, s)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in Players:GetPlayers() do
	task.spawn(onPlayerAdded, p)
end

Players.PlayerRemoving:Connect(function(player: Player)
	local s = sessions[player]
	if not s then
		return
	end
	s.leaving = true
	garage:release(player)
	saveSession(s, true)
	if sessions[player] == s then
		sessions[player] = nil
	end
end)

game:BindToClose(function()
	local pending = 0
	for _, s in sessions do
		pending += 1
		task.spawn(function()
			s.leaving = true
			saveSession(s, true)
			pending -= 1
		end)
	end
	local t = os.clock()
	while pending > 0 and os.clock() - t < 25 do
		task.wait(0.2)
	end
end)

-- Texto de los jugadores: se filtra porque el nombre aparece en el garaje para todos.
local function filterText(text: string, userId: number): (string?, string?)
	local ok, result = pcall(function()
		return TextService:FilterStringAsync(text, userId)
	end)
	if not ok then
		return nil, "No se pudo verificar el nombre con el filtro de Roblox. Probá de nuevo."
	end
	local ok2, filtered = pcall(function()
		return (result :: any):GetNonChatStringForBroadcastAsync()
	end)
	if not ok2 then
		return nil, "No se pudo verificar el nombre con el filtro de Roblox. Probá de nuevo."
	end
	if filtered ~= text then
		return nil, "Ese nombre no está permitido por el filtro de Roblox. Probá con otro."
	end
	return filtered, nil
end

local function createCompany(s: Session, payload: any): any
	if s.game then
		return { ok = false, msg = "Ya tenés una empresa en esta cuenta." }
	end
	local clean, err = Actions.validateCompany(payload)
	if not clean then
		return { ok = false, msg = err }
	end
	local name, ferr = filterText(clean.name, s.player.UserId)
	if not name then
		return { ok = false, msg = ferr }
	end
	if sessions[s.player] ~= s or s.game then
		return { ok = false, msg = "La sesión cambió; volvé a intentar." }
	end
	s.game = GameState.newGame({ name = name, color = clean.color, difficulty = clean.difficulty, now = os.time() })
	Simulation.notify(s.game, nil, "ok", "¡" .. name .. " fue fundada!")
	s.dirty = true
	requestSave(s)
	local plot = garage:assign(s.player, s.game.company)
	if plot then
		garage:teleport(s.player)
		garage:update(s.player, s.game)
	end
	return {
		ok = true,
		msg = "¡" .. name .. " fue fundada! Tu garaje te espera." .. (plot and "" or " (No hay garajes libres en este servidor.)"),
	}
end

local function dispatch(s: Session, action: string, payload: any): any
	if action == "createCompany" then
		return createCompany(s, payload)
	end
	local g = s.game
	if not g then
		return { ok = false, msg = "Primero creá tu empresa." }
	end
	if action == "saveDesign" then
		local draft = type(payload) == "table" and payload.draft or nil
		if type(draft) ~= "table" or type(draft.name) ~= "string" then
			return { ok = false, msg = "El diseño no es válido." }
		end
		local name = Util.trim(draft.name)
		if Util.charCount(name) < 2 or Util.charCount(name) > 24 then
			return { ok = false, msg = "El nombre del proyecto debe tener entre 2 y 24 caracteres." }
		end
		local filtered, ferr = filterText(name, s.player.UserId)
		if not filtered then
			return { ok = false, msg = ferr }
		end
		if sessions[s.player] ~= s or s.game ~= g then
			return { ok = false, msg = "La sesión cambió; volvé a intentar." }
		end
		draft.name = filtered
	end
	local handler = Actions.handlers[action]
	if not handler then
		return { ok = false, msg = "Acción desconocida." }
	end
	return handler(g, s.ctx, payload)
end

local function rateLimited(s: Session): boolean
	local now = os.clock()
	local keep = {}
	for _, t in s.requests do
		if now - t < 2 then
			table.insert(keep, t)
		end
	end
	s.requests = keep
	if #keep >= 12 then
		return true
	end
	table.insert(s.requests, now)
	return false
end

Request.OnServerInvoke = function(player: Player, action: any, payload: any): any
	local s = sessions[player]
	if not s or type(action) ~= "string" then
		return { ok = false, msg = "Sesión no disponible." }
	end
	if rateLimited(s) then
		return { ok = false, msg = "Demasiadas acciones seguidas. Esperá un momento." }
	end
	if action == "sync" then
		push(s)
		return { ok = true, quiet = true }
	end
	if action == "retryLoad" then
		if s.status == "failed" then
			task.spawn(loadSession, s)
			return { ok = true, msg = "Reintentando la carga…" }
		end
		return { ok = false, msg = "La partida ya está cargada." }
	end
	if s.status ~= "ready" then
		return { ok = false, msg = "Tu partida todavía no está cargada." }
	end
	if s.busy then
		return { ok = false, msg = "Esperá a que termine la acción anterior." }
	end
	s.busy = true
	local ok, result = pcall(dispatch, s, action, payload)
	s.busy = false
	if not ok then
		log("Error en la acción " .. action .. " de " .. player.Name .. ": " .. tostring(result))
		return { ok = false, msg = "Error interno del servidor. No se aplicó ningún cambio a medias." }
	end
	if result.ok then
		s.dirty = true
		if Actions.important[action] or action == "createCompany" then
			requestSave(s)
		end
		if s.game then
			garage:update(player, s.game)
		end
	end
	push(s)
	-- Solo se devuelven campos simples.
	return {
		ok = result.ok,
		msg = result.msg,
		quiet = result.quiet,
		designId = result.designId,
		version = result.version,
		orderId = result.orderId,
		sold = result.sold,
		chance = result.chance,
		roll = result.roll,
	}
end

-- Bucle de simulación: 1 s real = 10 min de juego × velocidad elegida ---------------------
local accumulator = 0
RunService.Heartbeat:Connect(function(dt: number)
	accumulator += dt
	if accumulator < 1 then
		return
	end
	accumulator = math.min(accumulator - 1, 1)
	local now = os.clock()
	for player, s in sessions do
		if s.status == "ready" and s.game and not s.leaving then
			local g = s.game
			if g.time.speed > 0 then
				local ok, err = pcall(Simulation.simulate, g, s.ctx, Catalog.RULES.minutesPerRealSecond * g.time.speed)
				if not ok then
					log("Error de simulación para " .. player.Name .. ": " .. tostring(err))
				end
				s.dirty = true
				garage:update(player, g)
				push(s)
			end
			if s.canSave and not s.saving then
				local due = s.pendingSave and now - s.lastSave >= MIN_SAVE_GAP
				local auto = s.dirty and now - s.lastAutosave >= AUTOSAVE_SECONDS
				if due or auto then
					s.lastAutosave = now
					task.spawn(saveSession, s)
				end
			end
		end
	end
end)
