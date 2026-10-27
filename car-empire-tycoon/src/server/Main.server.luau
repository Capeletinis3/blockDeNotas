--!strict
--[[
	Car Empire Tycoon — servidor. Conecta los servicios de Roblox con Sessions (lógica de sesiones),
	crea los remotos y el mundo provisional. Toda la economía se valida en Actions/Simulation.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Util = require(Shared.Util)
local Catalog = require(Shared.Catalog)
local CarModel = require(Shared.CarModel)
-- Modelos 3D por base (fase 3D): si existen en ReplicatedStorage.CarEmpireAssets.Cars, se usan.
CarModel.assetResolver = function(baseId: string): Model?
	local assets = ReplicatedStorage:FindFirstChild("CarEmpireAssets")
	local cars = assets and assets:FindFirstChild("Cars")
	local m = cars and cars:FindFirstChild(baseId)
	return (m and m:IsA("Model")) and m or nil
end

--[[ Carrocerías 3D definitivas (Catalog.VEHICLE_MODELS): el original vive en ServerStorage.VehicleModels
	(lo pone el equipo en Studio; Rojo no lo toca porque default.project.json no incluye ServerStorage).
	El servidor clona desde ahí y publica una copia SIN scripts en ReplicatedStorage.CarEmpireAssets.
	VehicleModels para que el cliente la use en el editor y las miniaturas. El original no se modifica. ]]
local function vehicleSource(asset: string): Model?
	local folder = ServerStorage:FindFirstChild("VehicleModels")
	local m = folder and folder:FindFirstChild(asset)
	return (m and m:IsA("Model")) and m or nil
end
CarModel.vehicleResolver = vehicleSource
do
	local assets = ReplicatedStorage:FindFirstChild("CarEmpireAssets")
	if not assets then
		assets = Instance.new("Folder")
		assets.Name = "CarEmpireAssets"
		assets.Parent = ReplicatedStorage
	end
	local public = assets:FindFirstChild("VehicleModels")
	if not public then
		public = Instance.new("Folder")
		public.Name = "VehicleModels"
		public.Parent = assets
	end
	for _, entry in Catalog.VEHICLE_MODELS do
		local src = vehicleSource(entry.asset)
		if not src then
			warn("[CarEmpire] Falta ServerStorage.VehicleModels." .. entry.asset .. " (" .. entry.name .. "): se usa el modelo provisional.")
		elseif not public:FindFirstChild(entry.asset) then
			local copy = src:Clone()
			if copy then
				for _, d in copy:GetDescendants() do
					if d:IsA("LuaSourceContainer") then
						d:Destroy()
					end
				end
				copy.Parent = public
				print("[CarEmpire] Carrocería 3D lista: " .. entry.name .. " (" .. entry.asset .. ")")
			end
		end
	end
end

local GameState = require(script.Parent.GameState)
local DataService = require(script.Parent.DataService)
local Sessions = require(script.Parent.Sessions)
local Garage = require(script.Parent.Garage)

local STORE_NAME = "CarEmpireTycoon_v1"

-- Remotos ---------------------------------------------------------------------------------
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

local function log(msg: string)
	warn("[CarEmpire] " .. msg)
end

-- Almacenamiento: DataStore real; en Studio sin acceso a la API, memoria temporal (con aviso visible).
local saveMode = "datastore"
local store: any = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
		if RunService:IsStudio() then
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
			-- En un servidor publicado no se usa memoria: las cargas fallan y no se pisa nada.
			store = {
				UpdateAsync = function()
					error("DataStore no disponible")
				end,
			}
		end
	end
end

local data = DataService.new(store, {
	jobId = game.JobId ~= "" and game.JobId or ("studio-" .. HttpService:GenerateGUID(false)),
	now = os.time,
	wait = function(s: number)
		task.wait(s)
	end,
	log = log,
	copy = Util.deepCopy,
	validate = GameState.validate,
	loadProfile = GameState.loadProfile,
})

-- Texto de los jugadores: se filtra porque los nombres aparecen en el garaje para todos.
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

local sessions: any = nil

local garage = Garage.new(function(who: Player, owner: Player?, screen: string)
	if owner == who then
		OpenEvent:FireClient(who, screen)
	elseif owner then
		NoticeEvent:FireClient(who, "info", "Este garaje es de " .. owner.DisplayName .. ".")
	end
end)

sessions = Sessions.new({
	data = data,
	filter = filterText,
	push = function(player: Player, payload: any)
		StateEvent:FireClient(player, payload)
	end,
	notice = function(player: Player, kind: string, text: string)
		NoticeEvent:FireClient(player, kind, text)
	end,
	garage = {
		assign = function(player: Player, g: any)
			return garage:assign(player, g)
		end,
		release = function(player: Player)
			garage:release(player)
		end,
		teleport = function(player: Player)
			garage:teleport(player)
		end,
		update = function(player: Player, g: any, refreshSign: boolean?)
			garage:update(player, g, refreshSign)
		end,
	},
	newRng = function()
		local r = Random.new()
		return function(): number
			return r:NextNumber()
		end
	end,
	now = os.time,
	clock = os.clock,
	wait = function(s: number)
		task.wait(s)
	end,
	spawn = function(fn: () -> ())
		task.spawn(fn)
	end,
	log = log,
	debug = RunService:IsStudio(),
	saveMode = saveMode,
})

local function onPlayerAdded(player: Player)
	sessions:add(player)
	player.CharacterAdded:Connect(function()
		task.wait(0.3)
		local s = sessions.list[player]
		if s and s.game and s.hasPlot then
			garage:teleport(player)
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in Players:GetPlayers() do
	task.spawn(onPlayerAdded, p)
end

Players.PlayerRemoving:Connect(function(player: Player)
	sessions:remove(player)
end)

game:BindToClose(function()
	sessions:closeAll(25)
end)

Request.OnServerInvoke = function(player: Player, action: any, payload: any): any
	return sessions:request(player, action, payload)
end

-- Reloj: 1 s real = 10 min de juego × velocidad elegida.
local accumulator = 0
RunService.Heartbeat:Connect(function(dt: number)
	accumulator += dt
	if accumulator < 1 then
		return
	end
	accumulator = math.min(accumulator - 1, 1)
	sessions:tick()
end)
