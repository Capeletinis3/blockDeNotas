--!strict
--[[ Avatares reales de los empleados (amigos de Roblox) para la oficina del editor.

	El servidor arma el modelo del avatar con las APIs oficiales (Players:GetHumanoidDescriptionFromUserId y
	Players:CreateHumanoidModelFromDescription, rig R15) y lo deja en PlayerGui.AvataresEmpleados de ESE
	jugador: lo que está en PlayerGui se replica solo a su dueño (nadie más ve los avatares ni la lista de
	amigos de otro jugador) y no se dibuja ahí. El cliente lo copia en su escena local y lo anima.

	Solo se arman avatares de los userId que la sesión ya tiene asignados a empleados de su empresa activa
	(Main.server lo comprueba): el cliente no puede pedir el avatar de cualquiera.

	Rendimiento y límites:
	  - Descripciones en caché DESC_TTL segundos (compartida en el servidor).
	  - Como mucho MAX_CONCURRENT armados a la vez y PER_MINUTE por jugador; lo que excede se ignora y el cliente
	    vuelve a pedir más tarde.
	  - Un modelo ya entregado vale MODEL_TTL segundos; después se rearma si se vuelve a pedir (avatar
	    actualizado). Hasta MAX_MODELS por jugador (se quitan los más viejos).
	  - Si falla, se marca en la carpeta (atributo Fallo_<userId> = hora) para que el cliente espere antes de
	    reintentar; nunca se reemplaza por un personaje genérico. ]]

local Players = game:GetService("Players")

local Avatars = {}

Avatars.FOLDER = "AvataresEmpleados"
Avatars.DESC_TTL = 1800
Avatars.MODEL_TTL = 1800
Avatars.MAX_CONCURRENT = 2
Avatars.PER_MINUTE = 20
Avatars.MAX_MODELS = 30
Avatars.RETRY_AFTER = 60 -- segundos antes de reintentar un avatar que falló

local descCache: { [number]: { desc: any, at: number } } = {}
local queue: { any } = {}
local active = 0
local perPlayer: { [any]: any } = {}
Avatars._stats = { built = 0, failed = 0, descFetched = 0 }

-- Llama al primer nombre de método que exista (las APIs con y sin sufijo Async según la versión del motor).
local function callFirst(names: { string }, ...: any): (boolean, any)
	local args = table.pack(...)
	local lastErr: any = "método no disponible"
	for _, n in names do
		local ok, fn = pcall(function()
			return (Players :: any)[n]
		end)
		if ok and type(fn) == "function" then
			local ok2, res = pcall(fn, Players, table.unpack(args, 1, args.n))
			if ok2 and res ~= nil then
				return true, res
			end
			lastErr = res
		end
	end
	return false, lastErr
end

function Avatars.folderFor(player: any): Instance?
	local gui = player:FindFirstChild("PlayerGui")
	if not gui then
		return nil
	end
	local f = gui:FindFirstChild(Avatars.FOLDER)
	if not f then
		f = Instance.new("Folder")
		f.Name = Avatars.FOLDER
		f.Parent = gui
	end
	return f
end

local function stateOf(player: any): any
	local st = perPlayer[player]
	if not st then
		st = { windowStart = os.clock(), count = 0, building = {} }
		perPlayer[player] = st
	end
	if os.clock() - st.windowStart >= 60 then
		st.windowStart, st.count = os.clock(), 0
	end
	return st
end

local function description(userId: number): (boolean, any)
	local c = descCache[userId]
	if c and os.time() - c.at < Avatars.DESC_TTL then
		return true, c.desc
	end
	local ok, desc = callFirst({ "GetHumanoidDescriptionFromUserIdAsync", "GetHumanoidDescriptionFromUserId" }, userId)
	if ok then
		Avatars._stats.descFetched += 1
		descCache[userId] = { desc = desc, at = os.time() }
	end
	return ok, desc
end

-- Deja el modelo listo para animarlo localmente: sin scripts, sin nombre ni barra de vida del Humanoid.
local function prepare(model: Model, userId: number)
	model.Name = "Avatar_" .. userId
	model:SetAttribute("userId", userId)
	model:SetAttribute("builtAt", os.time())
	for _, d in model:GetDescendants() do
		if d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
		elseif d:IsA("Humanoid") then
			pcall(function()
				d.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
				d.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			end)
		end
	end
end

local function build(job: any)
	local player, userId = job.player, job.userId
	local st = stateOf(player)
	local ok, desc = description(userId)
	local model: any = nil
	if ok then
		local okM, m = callFirst({ "CreateHumanoidModelFromDescriptionAsync", "CreateHumanoidModelFromDescription" }, desc, Enum.HumanoidRigType.R15)
		if okM then
			model = m
		end
	end
	st.building[userId] = nil
	local folder = player.Parent and Avatars.folderFor(player)
	if not folder then
		if model then
			model:Destroy()
		end
		return
	end
	if not model then
		Avatars._stats.failed += 1
		folder:SetAttribute("Fallo_" .. userId, os.time())
		return
	end
	prepare(model, userId)
	local old = folder:FindFirstChild("Avatar_" .. userId)
	if old then
		old:Destroy()
	end
	folder:SetAttribute("Fallo_" .. userId, nil)
	model.Parent = folder
	Avatars._stats.built += 1
	-- Tope de modelos por jugador: se van los más viejos.
	local models = {}
	for _, c in folder:GetChildren() do
		if c:IsA("Model") then
			table.insert(models, c)
		end
	end
	if #models > Avatars.MAX_MODELS then
		table.sort(models, function(a: Instance, b: Instance): boolean
			return (a:GetAttribute("builtAt") or 0) < (b:GetAttribute("builtAt") or 0)
		end)
		for i = 1, #models - Avatars.MAX_MODELS do
			models[i]:Destroy()
		end
	end
end

local function pump()
	while active < Avatars.MAX_CONCURRENT and #queue > 0 do
		local job = table.remove(queue, 1)
		active += 1
		task.spawn(function()
			local ok, err = pcall(build, job)
			if not ok then
				warn("[CarEmpire] Avatar de empleado: " .. tostring(err))
				local st = perPlayer[job.player]
				if st then
					st.building[job.userId] = nil
				end
			end
			active -= 1
			pump()
		end)
	end
end

--[[ Pide los avatares de estos userId (ya validados por Main.server). Ignora los que ya están entregados y
	vigentes, los que se están armando, los que fallaron hace poco y los que exceden el límite por minuto. ]]
function Avatars.request(player: any, userIds: { number })
	local folder = Avatars.folderFor(player)
	if not folder then
		return
	end
	local st = stateOf(player)
	for _, userId in userIds do
		local have = folder:FindFirstChild("Avatar_" .. userId)
		local fresh = have and os.time() - (have:GetAttribute("builtAt") or 0) < Avatars.MODEL_TTL
		local failedAt = folder:GetAttribute("Fallo_" .. userId)
		local recentFail = type(failedAt) == "number" and os.time() - failedAt < Avatars.RETRY_AFTER
		if not fresh and not st.building[userId] and not recentFail and st.count < Avatars.PER_MINUTE then
			st.count += 1
			st.building[userId] = true
			table.insert(queue, { player = player, userId = userId })
		end
	end
	pump()
end

function Avatars.forget(player: any)
	perPlayer[player] = nil
	for i = #queue, 1, -1 do
		if queue[i].player == player then
			table.remove(queue, i)
		end
	end
end

return Avatars
