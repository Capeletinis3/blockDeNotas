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
--[[ Regeneración pedida por el cliente (la plantilla entregada no se pudo armar allá): se rearma aunque el
	modelo siga vigente, pero solo REBUILD_MAX veces por amigo cada REBUILD_WINDOW segundos y nunca antes de
	REBUILD_GAP segundos desde el último armado. Después de FAIL_MAX fallas seguidas de un amigo dentro de
	FAIL_WINDOW no se lo vuelve a intentar hasta que pase la ventana (sin reintentos infinitos). ]]
Avatars.REBUILD_GAP = 10
Avatars.REBUILD_MAX = 3
Avatars.REBUILD_WINDOW = 600
Avatars.FAIL_MAX = 3
Avatars.FAIL_WINDOW = 600

--[[ Comprobación de vigencia (la asigna Main.server): (player, userId, token) → ¿sigue siendo un empleado de la
	empresa activa con la que se pidió? token identifica esa empresa abierta. Se consulta antes de empezar a
	armar y al terminar: un avatar que llega tarde (se cambió de empresa, se despidió al empleado, se reasignó
	el amigo o el jugador se fue) se descarta y no se entrega. ]]
Avatars.stillWanted = nil :: ((any, number, any) -> boolean)?

local function wanted(job: any): boolean
	if not job.player.Parent then
		return false
	end
	local fn = Avatars.stillWanted
	return fn == nil or fn(job.player, job.userId, job.token) == true
end

local descCache: { [number]: { desc: any, at: number } } = {}
local queue: { any } = {}
local active = 0
local perPlayer: { [any]: any } = {}
Avatars._stats = { built = 0, failed = 0, descFetched = 0, discarded = 0, skipped = 0, rebuilt = 0, invalid = 0, refused = 0 }

--[[ ¿El modelo armado sirve para animarlo en el cliente? Tiene que ser un Model con HumanoidRootPart y las
	piezas del cuerpo unidas; si no, cuenta como falla (no se entrega una plantilla rota). ]]
function Avatars.validModel(model: any): boolean
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return false
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return false
	end
	local parts = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
		end
	end
	return parts >= 2 and model:FindFirstChild("Head", true) ~= nil
end

-- Registra una falla de un amigo (ventana deslizante) y avisa al cliente en la carpeta.
local function noteFail(st: any, folder: Instance, userId: number)
	local f = st.fails[userId]
	local now = os.time()
	if not f or now - f.since >= Avatars.FAIL_WINDOW then
		f = { n = 0, since = now }
		st.fails[userId] = f
	end
	f.n += 1
	folder:SetAttribute("Fallo_" .. userId, now)
	if f.n >= Avatars.FAIL_MAX then
		folder:SetAttribute("Agotado_" .. userId, now) -- el cliente deja de pedirlo por ahora
	end
end

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
		st = { windowStart = os.clock(), count = 0, building = {}, rebuilds = {}, fails = {} }
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
	if not wanted(job) then
		st.building[userId] = nil
		Avatars._stats.skipped += 1
		return -- ya no hace falta (cambio de empresa, despido o reasignación mientras esperaba)
	end
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
	if not folder or not wanted(job) then
		-- Resultado obsoleto: no se entrega.
		if model then
			model:Destroy()
		end
		Avatars._stats.discarded += 1
		return
	end
	if model and not Avatars.validModel(model) then
		-- Llegó algo que no sirve (sin raíz, sin cabeza…): se descarta y cuenta como falla.
		Avatars._stats.invalid += 1
		model:Destroy()
		model = nil
	end
	if not model then
		Avatars._stats.failed += 1
		noteFail(st, folder, userId)
		return
	end
	st.fails[userId] = nil
	folder:SetAttribute("Agotado_" .. userId, nil)
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
--[[ rebuild = { [userId] = true } (opcional): amigos cuya plantilla el cliente no pudo armar y pide regenerar.
	Ya validados por Main.server (empleados autorizados de la empresa activa). ]]
function Avatars.request(player: any, userIds: { number }, token: any?, rebuild: { [number]: boolean }?)
	local folder = Avatars.folderFor(player)
	if not folder then
		return
	end
	local st = stateOf(player)
	local now = os.time()
	for _, userId in userIds do
		local have = folder:FindFirstChild("Avatar_" .. userId)
		local builtAt = have and (have:GetAttribute("builtAt") or 0) or 0
		local fresh = have ~= nil and now - builtAt < Avatars.MODEL_TTL
		if fresh and rebuild and rebuild[userId] then
			-- Regenerar una plantilla que el cliente no pudo usar, dentro de los límites.
			local rb = st.rebuilds[userId]
			if not rb or now - rb.since >= Avatars.REBUILD_WINDOW then
				rb = { n = 0, since = now }
				st.rebuilds[userId] = rb
			end
			if rb.n < Avatars.REBUILD_MAX and now - builtAt >= Avatars.REBUILD_GAP and not st.building[userId] then
				rb.n += 1
				fresh = false
				Avatars._stats.rebuilt += 1
			else
				Avatars._stats.refused += 1
			end
		end
		local failedAt = folder:GetAttribute("Fallo_" .. userId)
		local recentFail = type(failedAt) == "number" and now - failedAt < Avatars.RETRY_AFTER
		local f = st.fails[userId]
		local exhausted = f ~= nil and f.n >= Avatars.FAIL_MAX and now - f.since < Avatars.FAIL_WINDOW
		if not fresh and not st.building[userId] and not recentFail and not exhausted and st.count < Avatars.PER_MINUTE then
			st.count += 1
			st.building[userId] = true
			table.insert(queue, { player = player, userId = userId, token = token })
		end
	end
	pump()
end

-- Descarta los pedidos en cola de un jugador (al irse del servidor). Los que ya se están armando se descartan
-- solos al terminar (wanted).
function Avatars.forget(player: any)
	perPlayer[player] = nil
	for i = #queue, 1, -1 do
		if queue[i].player == player then
			table.remove(queue, i)
		end
	end
end

-- Estado de límites de un jugador (para las pruebas).
function Avatars._perPlayer(player: any): any
	return stateOf(player)
end

-- Cuántos pedidos esperan (para las pruebas).
function Avatars.pending(): number
	return #queue
end

return Avatars
