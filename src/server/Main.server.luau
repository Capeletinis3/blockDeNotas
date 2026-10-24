-- Prototipo 1: patear la pelota, romper un soporte y derribar la estructura.
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Aim = require(Shared.Aim)

-- Remotos y estado compartido -------------------------------------------------

local remotes = Instance.new("Folder")
remotes.Name = "Remotes"
for _, name in { "Patear", "Reiniciar", "Resultado", "Aviso" } do
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = remotes
end
remotes.Parent = ReplicatedStorage

-- El piso queda por encima de y = 0 para no superponerse con un Baseplate.
local GROUND = 1
local BALL_SPOT = Vector3.new(0, GROUND + Config.Ball.Diameter / 2, 10)

remotes:SetAttribute("PelotaPos", BALL_SPOT)

local random = Random.new()

local state = "Reiniciando"
local attemptId = 0
local lastReset = 0

local scenario: Folder? = nil
local ball: Part? = nil
local platform: Part? = nil
local platformOrigin: Vector3? = nil
local tracked: { BasePart } = {} -- piezas sueltas cuyas velocidades seguimos
local velocities: { [BasePart]: Vector3 } = {}
local result = nil
local bestResist = nil
local kicker: Player? = nil

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

local fx = Instance.new("Folder")
fx.Name = "Efectos"
fx.Parent = workspace

-- Escenario destructible --------------------------------------------------------

local function spawnFragments(part: BasePart, velocity: Vector3)
	local size = part.Size
	for _ = 1, Config.FragmentsPerBreak do
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
	table.insert(result.broken, { kind = part.Name, direct = direct })
	spawnFragments(part, velocities[part] or Vector3.zero)
	part:Destroy()
end

local function onTouched(part: BasePart, other: BasePart)
	if state ~= "Pateando" or part:GetAttribute("Roto") then
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
	local impulse = (vPart - vOther).Magnitude * mass
	local isBall = other == ball

	if impulse >= material.Strength then
		breakPart(part, isBall)
		if isBall then
			-- La pelota atraviesa lo que rompe, perdiendo parte de su impulso.
			other.AssemblyLinearVelocity = vOther * (1 - material.Absorb)
		end
	elseif isBall then
		local ratio = impulse / material.Strength
		if not bestResist or ratio > bestResist.ratio then
			bestResist = { label = material.Label, ratio = ratio }
		end
	end
end

local function addPiece(kind: string, size: Vector3, cframe: CFrame, anchored: boolean?): Part
	local material = Config.Materials[kind]
	local part = newPart(kind, size, cframe)
	part.Anchored = anchored == true
	part.Material = material.Material
	part.Color = material.Color
	part.CustomPhysicalProperties =
		PhysicalProperties.new(material.Density, material.Friction, material.Elasticity)
	part.Parent = scenario

	if not part.Anchored then
		part:SetNetworkOwner(nil)
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
	tracked = {}
	velocities = {}

	-- Dos soportes sostienen una plataforma con cajas encima.
	for _, x in { -8, 8 } do
		addPiece("Madera", Vector3.new(1.5, 10, 1.5), CFrame.new(at(x, 5, 40)))
	end
	platform = addPiece("Plataforma", Vector3.new(20, 1, 6), CFrame.new(at(0, 10.5, 40)))
	platformOrigin = platform.Position
	for _, x in { -5, 0, 5 } do
		addPiece("Caja", Vector3.new(3, 3, 3), CFrame.new(at(x, 12.5, 40)))
	end

	-- Pared que frena la pelota si no golpea nada.
	addPiece("Pared", Vector3.new(40, 8, 2), CFrame.new(at(0, 4, 62)), true)

	local d = Config.Ball.Diameter
	ball = newPart("Pelota", Vector3.new(d, d, d), CFrame.new(BALL_SPOT))
	ball.Shape = Enum.PartType.Ball
	ball.Material = Enum.Material.SmoothPlastic
	ball.Color = Color3.fromRGB(245, 245, 245)
	ball.CustomPhysicalProperties =
		PhysicalProperties.new(Config.Ball.Density, Config.Ball.Friction, Config.Ball.Elasticity)
	ball.Parent = scenario
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

-- Plata ---------------------------------------------------------------------------

local function countBreaks()
	local direct, chain = 0, 0
	for _, piece in result.broken do
		if piece.direct then
			direct += 1
		else
			chain += 1
		end
	end
	return direct, chain
end

-- Paga una sola vez por intento, aunque se reinicie a mitad de la patada.
local function payAttempt(): number
	if not result or result.paid then
		return 0
	end
	result.paid = true
	local direct, chain = countBreaks()
	local earned = direct * Config.MoneyDirect + chain * Config.MoneyChain
	local leaderstats = kicker and kicker.Parent and kicker:FindFirstChild("leaderstats")
	if leaderstats and earned > 0 then
		leaderstats.Plata.Value += earned
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
	setState("Listo")
end

-- Intento -------------------------------------------------------------------------

local function explain(toppled: boolean): string
	local broken = #result.broken
	if toppled then
		return "¡Estructura derribada!"
	elseif broken > 0 then
		return "Rompiste algo, pero la estructura sigue en pie. Probá otro ángulo."
	elseif bestResist then
		return string.format(
			"%s resistió: le llegó el %d%% de la fuerza necesaria.",
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

	local direct, chain = countBreaks()
	local earned = payAttempt()

	remotes.Resultado:FireAllClients({
		message = explain(toppled),
		direct = direct,
		chain = chain,
		toppled = toppled,
		earned = earned,
		kicker = kicker,
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

remotes.Patear.OnServerEvent:Connect(function(player, angle)
	if state ~= "Listo" or typeof(angle) ~= "number" or angle ~= angle then
		return
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or (root.Position - ball.Position).Magnitude > Config.KickRange then
		remotes.Aviso:FireClient(player, "Acercate a la pelota para patear.")
		return
	end

	attemptId += 1
	result = { broken = {}, paid = false }
	bestResist = nil
	kicker = player
	setState("Pateando")

	ball.Anchored = false
	ball:SetNetworkOwner(nil)
	ball.AssemblyLinearVelocity = Aim.direction(angle) * Config.KickSpeed
	task.spawn(watchAttempt, attemptId)
end)

remotes.Reiniciar.OnServerEvent:Connect(function()
	if state == "Reiniciando" or os.clock() - lastReset < Config.ResetCooldown then
		return
	end
	reset()
end)

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
	-- leaderstats muestra la plata en la tabla de jugadores de Roblox.
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local money = Instance.new("IntValue")
	money.Name = "Plata"
	money.Value = 0
	money.Parent = leaderstats
	leaderstats.Parent = player

	player.CharacterAdded:Connect(placeCharacter)
	if player.Character then
		placeCharacter(player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

reset()
