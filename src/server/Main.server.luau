-- Fase 1: patear, provocar cadenas, cobrar, entrenar y comprar mejoras.
local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Balance = require(Shared.Balance)
local Aim = require(Shared.Aim)
local Progression = require(Shared.Progression)

local progression = Progression.new(Balance)

-- Remotos y estado compartido -------------------------------------------------

local remotes = Instance.new("Folder")
remotes.Name = "Remotes"
for _, name in {
	"Patear",
	"Reiniciar",
	"Resultado",
	"Aviso",
	"MejorarPelota",
	"ComprarZapatillas",
	"EquiparZapatillas",
	"Entrenar",
} do
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = remotes
end
remotes.Parent = ReplicatedStorage

-- El piso queda por encima de y = 0 para no superponerse con un Baseplate.
local GROUND = 1
local BALL_SPOT = Vector3.new(0, GROUND + Config.Ball.Diameter / 2, 10)
local TRAIN_SPOT = Vector3.new(-18, GROUND, 6)

remotes:SetAttribute("PelotaPos", BALL_SPOT)
remotes:SetAttribute("EntrenamientoPos", TRAIN_SPOT)

-- La barrera frena a los personajes pero deja pasar la pelota y las piezas.
PhysicsService:RegisterCollisionGroup("Escenario")
PhysicsService:RegisterCollisionGroup("Barrera")
PhysicsService:CollisionGroupSetCollidable("Escenario", "Barrera", false)

local random = Random.new()

local state = "Reiniciando"
local attemptId = 0
local lastReset = 0
local nextPieceId = 0

local scenario: Folder? = nil
local ball: Part? = nil
local platform: Part? = nil
local platformOrigin: Vector3? = nil
local dynamic: { BasePart } = {} -- piezas que se sueltan al patear
local tracked: { BasePart } = {} -- piezas sueltas cuyas velocidades seguimos
local velocities: { [BasePart]: Vector3 } = {}

local attempt = nil -- Attempt de Progression
local breakLog: { { label: string, direct: boolean, kind: string } } = {}
local bestResist = nil
local ballStats = Balance.BallLevels[1]

local players: { [Player]: any } = {} -- estado de progresión de cada jugador en la sesión

local function setState(newState)
	state = newState
	remotes:SetAttribute("Estado", newState)
end

local function at(x, y, z)
	return Vector3.new(x, GROUND + y, z)
end

local function newPart(name, size, cframe)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function addSign(part: BasePart, text: string)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(200, 40)
	billboard.StudsOffset = Vector3.new(0, 4, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 80
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.3
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = text
	label.Parent = billboard
	billboard.Parent = part
end

-- Sonido 3D en una posición, con un tope para no saturar cuando se rompe mucho junto.
local lastSoundAt: { [string]: number } = {}
local function playSoundAt(kind: string, position: Vector3)
	local now = os.clock()
	if now - (lastSoundAt[kind] or 0) < 0.06 then
		return
	end
	lastSoundAt[kind] = now
	local holder = newPart("Sonido", Vector3.new(0.2, 0.2, 0.2), CFrame.new(position))
	holder.Transparency = 1
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	local sound = Instance.new("Sound")
	sound.SoundId = Config.Sounds[kind]
	sound.RollOffMaxDistance = 150
	sound.Parent = holder
	holder.Parent = workspace
	sound:Play()
	Debris:AddItem(holder, 3)
end

-- Progreso de cada jugador ----------------------------------------------------

-- Copia el estado de progresión a lo que ven los clientes.
local function sync(player: Player)
	local data = players[player]
	local leaderstats = player:FindFirstChild("leaderstats")
	if not data or not leaderstats then
		return
	end
	leaderstats.Plata.Value = data.money
	leaderstats.Fuerza.Value = data.strength
	player:SetAttribute("NivelPelota", data.ballLevel)
	player:SetAttribute("Zapatillas", data.shoeEquipped)
	local owned = {}
	for id in data.shoesOwned do
		table.insert(owned, tostring(id))
	end
	table.sort(owned)
	player:SetAttribute("ZapatillasCompradas", table.concat(owned, ","))
	player:SetAttribute("VelocidadPatada", math.floor(progression:kickSpeed(data)))
end

-- Partes fijas -------------------------------------------------------------------

local static = Instance.new("Model")
static.Name = "Pista"
static.Parent = workspace

local floor = newPart("Piso", Vector3.new(60, 2, 100), CFrame.new(0, GROUND - 1, 35))
floor.Material = Enum.Material.Grass
floor.Color = Color3.fromRGB(90, 140, 70)
floor.Parent = static

local pad = newPart("ZonaDePatada", Vector3.new(10, 0.2, 12), CFrame.new(at(0, 0.1, 5)))
pad.Material = Enum.Material.SmoothPlastic
pad.Color = Color3.fromRGB(240, 200, 60)
pad.CanCollide = false
pad.Parent = static
addSign(pad, "ZONA DE PATADA")

local trainPad = newPart("ZonaDeEntrenamiento", Vector3.new(8, 0.2, 8), CFrame.new(TRAIN_SPOT + Vector3.new(0, 0.1, 0)))
trainPad.Material = Enum.Material.SmoothPlastic
trainPad.Color = Color3.fromRGB(80, 160, 230)
trainPad.CanCollide = false
trainPad.Parent = static
addSign(trainPad, "ENTRENAMIENTO")

local barrier = newPart("Barrera", Vector3.new(60, 30, 1), CFrame.new(at(0, 15, 20)))
barrier.Transparency = 1
barrier.CanQuery = false
barrier.CollisionGroup = "Barrera"
barrier.Parent = static

local fx = Instance.new("Folder")
fx.Name = "Efectos"
fx.Parent = workspace

-- Escenario destructible --------------------------------------------------------

local function spawnFragments(part: BasePart, velocity: Vector3)
	local size = part.Size
	for _ = 1, Config.FragmentsPerBreak do
		if #fx:GetChildren() >= Config.MaxFragments then
			return
		end
		local fragSize = Vector3.new(
			math.clamp(size.X * random:NextNumber(0.2, 0.45), 0.3, 2.5),
			math.clamp(size.Y * random:NextNumber(0.2, 0.45), 0.3, 2.5),
			math.clamp(size.Z * random:NextNumber(0.2, 0.45), 0.3, 2.5)
		)
		local offset = Vector3.new(
			random:NextNumber(-0.5, 0.5) * size.X,
			random:NextNumber(-0.5, 0.5) * size.Y,
			random:NextNumber(-0.5, 0.5) * size.Z
		)
		local frag = newPart("Fragmento", fragSize, part.CFrame * CFrame.new(offset))
		frag.Anchored = false
		frag.CanTouch = false
		frag.CanQuery = false
		frag.CollisionGroup = "Escenario"
		frag.Material = part.Material
		frag.Color = part.Color
		frag.CustomPhysicalProperties = PhysicalProperties.new(0.05, 0.5, 0.2)
		frag.Parent = fx
		frag.AssemblyLinearVelocity = velocity * 0.5 + random:NextUnitVector() * Config.FragmentSpeed
		Debris:AddItem(frag, Config.FragmentLifetime)
	end
end

local function breakPart(part: BasePart, direct: boolean)
	part:SetAttribute("Roto", true)
	if attempt:recordBreak(part:GetAttribute("Id"), direct) then
		table.insert(breakLog, { label = part:GetAttribute("Label"), direct = direct, kind = part.Name })
	end
	playSoundAt("Break", part.Position)
	spawnFragments(part, velocities[part] or Vector3.zero)
	part:Destroy()
end

local function onTouched(part: BasePart, other: BasePart)
	if state ~= "Pateando" or not attempt or part:GetAttribute("Roto") then
		return
	end
	-- Solo cuentan las piezas del escenario y lo anclado (piso, pared).
	-- Así los personajes no rompen nada al caminar.
	if not other.Anchored and velocities[other] == nil then
		return
	end
	if part.Anchored and other.Anchored then
		return
	end

	local material = Config.Materials[part.Name]
	local vPart = if part.Anchored then Vector3.zero else (velocities[part] or Vector3.zero)
	local vOther = if other.Anchored then Vector3.zero else velocities[other]

	local mass
	if part.Anchored then
		mass = other.AssemblyMass
	elseif other.Anchored then
		mass = part.AssemblyMass
	else
		local a, b = part.AssemblyMass, other.AssemblyMass
		mass = a * b / (a + b)
	end
	local isBall = other == ball
	local impulse = (vPart - vOther).Magnitude * mass
	if isBall then
		impulse *= ballStats.BreakMultiplier
	end

	if impulse >= material.Strength then
		breakPart(part, isBall)
		if isBall then
			-- La pelota atraviesa lo que rompe, perdiendo parte de su impulso.
			other.AssemblyLinearVelocity = vOther * (1 - material.Absorb * ballStats.AbsorbMultiplier)
		end
	elseif isBall then
		playSoundAt("Impact", part.Position)
		local ratio = impulse / material.Strength
		if not bestResist or ratio > bestResist.ratio then
			bestResist = { label = material.Label, ratio = ratio }
		end
	end
end

-- Las piezas sueltas quedan ancladas hasta la patada: así la estructura no se
-- mueve sola ni la empujan los personajes antes de patear.
local function addPiece(kind: string, size: Vector3, cframe: CFrame, label: string?, fixed: boolean?): Part
	local material = Config.Materials[kind]
	local part = newPart(kind, size, cframe)
	part.Material = material.Material
	part.Color = material.Color
	part.CollisionGroup = "Escenario"
	part.CustomPhysicalProperties =
		PhysicalProperties.new(material.Density, material.Friction, material.Elasticity)
	nextPieceId += 1
	part:SetAttribute("Id", nextPieceId)
	part:SetAttribute("Label", label or string.lower(material.Label or kind))
	part.Parent = scenario

	if not fixed then
		table.insert(dynamic, part)
		table.insert(tracked, part)
	end
	if material.Strength then
		part.Touched:Connect(function(other)
			onTouched(part, other)
		end)
	end
	return part
end

local function buildScenario()
	scenario = Instance.new("Folder")
	scenario.Name = "Escenario"
	scenario.Parent = workspace
	dynamic = {}
	tracked = {}
	velocities = {}

	-- Dos soportes sostienen una plataforma con cajas encima.
	-- Ángulo positivo = derecha del jugador = -X.
	addPiece("Madera", Vector3.new(1.5, 10, 1.5), CFrame.new(at(8, 5, 40)), "el soporte izquierdo")
	addPiece("Madera", Vector3.new(1.5, 10, 1.5), CFrame.new(at(-8, 5, 40)), "el soporte derecho")
	platform = addPiece("Plataforma", Vector3.new(20, 1, 6), CFrame.new(at(0, 10.5, 40)), "la plataforma")
	platformOrigin = platform.Position
	for _, x in { -5, 0, 5 } do
		addPiece("Caja", Vector3.new(3, 3, 3), CFrame.new(at(x, 12.5, 40)), "una caja")
	end

	-- Panel reforzado en el centro, para comparar los niveles de la pelota.
	addPiece("Reforzado", Vector3.new(8, 6, 1), CFrame.new(at(0, 3, 50)), "el panel reforzado", true)

	-- Pared que frena la pelota si no golpea nada.
	addPiece("Pared", Vector3.new(40, 8, 2), CFrame.new(at(0, 4, 62)), "la pared", true)

	local d = Config.Ball.Diameter
	ball = newPart("Pelota", Vector3.new(d, d, d), CFrame.new(BALL_SPOT))
	ball.Shape = Enum.PartType.Ball
	ball.Material = Enum.Material.SmoothPlastic
	ball.Color = Config.BallColors[1]
	ball.CollisionGroup = "Escenario"
	ball.CustomPhysicalProperties =
		PhysicalProperties.new(Config.Ball.Density, Config.Ball.Friction, Config.Ball.Elasticity)
	ball.Parent = scenario
	table.insert(dynamic, ball)
	table.insert(tracked, ball)
end

-- Guardamos la velocidad previa a cada paso de física: cuando se dispara
-- Touched, la colisión ya cambió las velocidades.
RunService.Stepped:Connect(function()
	for _, part in tracked do
		if part.Parent then
			velocities[part] = part.AssemblyLinearVelocity
		end
	end
end)

-- Cobro --------------------------------------------------------------------------

-- Paga una sola vez por intento (lo garantiza Attempt), aunque se reinicie a mitad de la patada.
local function payAttempt(): number
	if not attempt then
		return 0
	end
	local earned = attempt:settle()
	local kicker = attempt.kicker
	local data = players[kicker]
	if data and earned > 0 then
		data.money += earned
		sync(kicker)
	end
	return earned
end

local function reset()
	if state == "Pateando" then
		payAttempt()
	end
	attemptId += 1
	lastReset = os.clock()
	setState("Reiniciando")
	if scenario then
		scenario:Destroy()
	end
	fx:ClearAllChildren()
	buildScenario()
	attempt = nil
	setState("Listo")
end

-- Intento -------------------------------------------------------------------------

local function explain(toppled: boolean, chain: number): string
	local firstDirect = nil
	for _, entry in breakLog do
		if entry.direct then
			firstDirect = entry
			break
		end
	end

	if toppled then
		local cause = if firstDirect then "Rompiste " .. firstDirect.label else "La estructura se desarmó"
		if chain > 0 then
			return string.format("¡Derribada! %s y cayeron %d piezas en cadena.", cause, chain)
		end
		return string.format("¡Derribada! %s y cayó la plataforma.", cause)
	end
	for _, entry in breakLog do
		if entry.kind == "Reforzado" then
			return "¡Atravesaste el panel reforzado!"
		end
	end
	if firstDirect then
		return string.format("Rompiste %s, pero la estructura sigue en pie. Probá otro ángulo.", firstDirect.label)
	elseif bestResist then
		return string.format(
			"%s resistió: le llegó el %d%% de la fuerza necesaria. Entrená o mejorá la pelota.",
			bestResist.label,
			math.floor(bestResist.ratio * 100)
		)
	end
	return "No le pegaste a nada. Apuntá a un soporte."
end

local function finishAttempt()
	setState("Resultado")

	local toppled = platform ~= nil
		and platform.Parent ~= nil
		and (platform.Position - platformOrigin).Magnitude > Config.ToppleDistance

	local direct, chain = attempt.direct, attempt.chain
	local earned = payAttempt()

	remotes.Resultado:FireAllClients({
		message = explain(toppled, chain),
		direct = direct,
		chain = chain,
		toppled = toppled,
		earned = earned,
		kicker = attempt.kicker,
	})

	local id = attemptId
	task.delay(Config.ResetDelay, function()
		if attemptId == id and state == "Resultado" then
			reset()
		end
	end)
end

local function watchAttempt(id: number)
	local start = os.clock()
	local quietSince = nil
	while attemptId == id do
		task.wait(0.1)
		if attemptId ~= id then
			return
		end

		local moving = false
		for _, part in tracked do
			-- Lo que cayó fuera del piso no cuenta.
			if part.Parent and part.Position.Y > GROUND - 10
				and part.AssemblyLinearVelocity.Magnitude > Config.SettleSpeed then
				moving = true
				break
			end
		end

		local now = os.clock()
		if moving then
			quietSince = nil
		elseif not quietSince then
			quietSince = now
		end

		local elapsed = now - start
		if elapsed > Config.MaxAttemptTime
			or (elapsed > 0.5 and quietSince and now - quietSince >= Config.SettleTime) then
			finishAttempt()
			return
		end
	end
end

-- Mueve la pierna derecha hacia adelante y la vuelve a su lugar.
local function playKickAnimation(character: Model, direction: Vector3)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		local flat = Vector3.new(direction.X, 0, direction.Z)
		root.CFrame = CFrame.lookAt(root.Position, root.Position + flat)
	end

	-- R15 usa RightHip; R6 usa "Right Hip", que rota sobre su eje Z local.
	local hip = character:FindFirstChild("RightHip", true) or character:FindFirstChild("Right Hip", true)
	if not hip or not hip:IsA("Motor6D") or hip:GetAttribute("Pateando") then
		return
	end
	local swing = if hip.Name == "RightHip" then CFrame.Angles(math.rad(75), 0, 0) else CFrame.Angles(0, 0, math.rad(75))
	local original = hip.C0
	hip:SetAttribute("Pateando", true)
	TweenService:Create(hip, TweenInfo.new(Config.KickWindup, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		C0 = original * swing,
	}):Play()
	task.delay(Config.KickWindup + 0.1, function()
		local back = TweenService:Create(hip, TweenInfo.new(0.2), { C0 = original })
		back.Completed:Connect(function()
			hip:SetAttribute("Pateando", nil)
		end)
		back:Play()
	end)
end

remotes.Patear.OnServerEvent:Connect(function(player, angle)
	if typeof(angle) ~= "number" or angle ~= angle then
		return
	end
	local data = players[player]
	if not data then
		return
	end
	if state == "Pateando" or state == "Resultado" then
		remotes.Aviso:FireClient(player, "Esperá a que termine la patada.")
		return
	elseif state ~= "Listo" then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or (root.Position - ball.Position).Magnitude > Config.KickRange then
		remotes.Aviso:FireClient(player, "Acercate a la pelota para patear.")
		return
	end

	-- Cambiar el estado primero hace que una segunda pulsación no patee de nuevo.
	attemptId += 1
	local id = attemptId
	setState("Pateando")
	attempt = progression:newAttempt(player)
	breakLog = {}
	bestResist = nil
	ballStats = progression:ballStats(data)
	local speed = progression:kickSpeed(data)
	local direction = Aim.direction(angle)

	ball.Color = Config.BallColors[data.ballLevel]
	playKickAnimation(character, direction)
	playSoundAt("Kick", ball.Position)

	task.delay(Config.KickWindup, function()
		if attemptId ~= id then
			return
		end
		for _, part in dynamic do
			if part.Parent then
				part.Anchored = false
				part:SetNetworkOwner(nil)
			end
		end
		ball.AssemblyLinearVelocity = direction * speed
		watchAttempt(id)
	end)
end)

remotes.Reiniciar.OnServerEvent:Connect(function()
	if state == "Reiniciando" or os.clock() - lastReset < Config.ResetCooldown then
		return
	end
	reset()
end)

-- Compras y entrenamiento ----------------------------------------------------------
-- El progreso vive en el jugador, así que reiniciar el escenario no lo cambia.
-- Una compra hecha durante una patada rige desde la siguiente.

local REASONS = {
	funds = "No te alcanza la plata.",
	max = "La pelota ya está al nivel máximo.",
	owned = "Ya tenés esas zapatillas.",
	notOwned = "Primero tenés que comprar esas zapatillas.",
	invalid = "Ese modelo no existe.",
}

remotes.MejorarPelota.OnServerEvent:Connect(function(player)
	local data = players[player]
	if not data then
		return
	end
	local nextLevel = Balance.BallLevels[data.ballLevel + 1]
	local ok, reason = progression:buyBallLevel(data)
	if ok then
		sync(player)
		remotes.Aviso:FireClient(player, string.format("¡Pelota mejorada a nivel %d!", data.ballLevel))
	elseif reason == "funds" then
		remotes.Aviso:FireClient(player, string.format("Te faltan $%d para mejorar la pelota.", nextLevel.Price - data.money))
	else
		remotes.Aviso:FireClient(player, REASONS[reason])
	end
end)

remotes.ComprarZapatillas.OnServerEvent:Connect(function(player, id)
	local data = players[player]
	if not data or typeof(id) ~= "number" then
		return
	end
	local ok, reason = progression:buyShoe(data, id)
	if ok then
		sync(player)
		remotes.Aviso:FireClient(player, string.format("¡Compraste %s!", Balance.Shoes[id].Name))
	elseif reason == "funds" then
		remotes.Aviso:FireClient(player, string.format("Te faltan $%d para %s.", Balance.Shoes[id].Price - data.money, Balance.Shoes[id].Name))
	else
		remotes.Aviso:FireClient(player, REASONS[reason])
	end
end)

remotes.EquiparZapatillas.OnServerEvent:Connect(function(player, id)
	local data = players[player]
	if not data or typeof(id) ~= "number" then
		return
	end
	local ok, reason = progression:equipShoe(data, id)
	if ok then
		sync(player)
	else
		remotes.Aviso:FireClient(player, REASONS[reason])
	end
end)

remotes.Entrenar.OnServerEvent:Connect(function(player)
	local data = players[player]
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not data or not root then
		return
	end
	local offset = root.Position - TRAIN_SPOT
	if Vector3.new(offset.X, 0, offset.Z).Magnitude > Config.TrainRange then
		remotes.Aviso:FireClient(player, "Andá a la zona azul de entrenamiento.")
		return
	end
	-- El límite de ritmo lo aplica Progression; las pulsaciones de más se ignoran.
	if progression:train(data, os.clock()) then
		sync(player)
	end
end)

-- Jugadores ---------------------------------------------------------------------------

-- Los jugadores aparecen en la zona de patada, mirando hacia la estructura.
local function placeCharacter(character: Model)
	local root = character:WaitForChild("HumanoidRootPart", 5)
	if root then
		task.defer(function()
			character:PivotTo(CFrame.lookAt(at(0, 3, 3), at(0, 3, 40)))
		end)
	end
end

local function onPlayerAdded(player: Player)
	-- leaderstats muestra la plata y la fuerza en la tabla de jugadores de Roblox.
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	for _, name in { "Plata", "Fuerza" } do
		local value = Instance.new("IntValue")
		value.Name = name
		value.Parent = leaderstats
	end
	leaderstats.Parent = player

	players[player] = progression:newPlayer()
	sync(player)

	player.CharacterAdded:Connect(placeCharacter)
	if player.Character then
		placeCharacter(player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	players[player] = nil
end)

reset()
