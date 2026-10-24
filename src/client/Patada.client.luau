-- Interfaz y controles: apuntar, patear, entrenar y comprar.
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Balance = require(Shared:WaitForChild("Balance"))
local Aim = require(Shared:WaitForChild("Aim"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local angle = 0
local keyTurn = 0
local buttonTurn = 0
local lastKickPress = 0
local lastEarned = 0

local isTouch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local KICK_HINT = if isTouch
	then "Apuntá con ◀ ▶ y tocá PATEAR"
	else "Apuntá con Q/E (o ◀ ▶) y pateá con F"
local TRAIN_HINT = if isTouch then "Tocá ENTRENAR para sumar fuerza" else "Apretá T o ENTRENAR para sumar fuerza"

local COLORS = {
	panel = Color3.fromRGB(20, 22, 28),
	neutral = Color3.fromRGB(60, 60, 70),
	kick = Color3.fromRGB(220, 70, 50),
	buy = Color3.fromRGB(40, 140, 60),
	equipped = Color3.fromRGB(70, 110, 180),
	train = Color3.fromRGB(60, 130, 210),
}

local function playLocalSound(kind: string)
	local sound = Instance.new("Sound")
	sound.SoundId = Config.Sounds[kind]
	SoundService:PlayLocalSound(sound)
	task.delay(3, function()
		sound:Destroy()
	end)
end

local function multiplierText(value: number): string
	return (string.format("x%g", value):gsub("%.", ","))
end

local function getStat(name: string): number
	local leaderstats = player:FindFirstChild("leaderstats")
	local value = leaderstats and leaderstats:FindFirstChild(name)
	return if value then value.Value else 0
end

-- Interfaz --------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "PatadaUI"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

-- En pantallas chicas (celular) todo se achica para no tapar el escenario.
local scale = Instance.new("UIScale")
scale.Parent = gui
local function updateScale()
	local size = camera.ViewportSize
	scale.Scale = math.clamp(math.min(size.X / 1000, size.Y / 600), 0.6, 1)
end
camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
updateScale()

local function round(instance: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 12)
	corner.Parent = instance
end

local function makeLabel(props): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundColor3 = COLORS.panel
	label.BackgroundTransparency = 0.35
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 18
	label.TextWrapped = true
	for key, value in props do
		label[key] = value
	end
	round(label)
	label.Parent = props.Parent or gui
	return label
end

local function makeButton(props): TextButton
	local button = Instance.new("TextButton")
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Font = Enum.Font.GothamBold
	button.TextSize = 18
	button.AutoButtonColor = true
	for key, value in props do
		button[key] = value
	end
	round(button)
	button.Parent = props.Parent or gui
	return button
end

-- Arriba al centro: qué hacer ahora y resultado de la última patada.
local status = makeLabel({
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 8),
	Size = UDim2.fromOffset(560, 40),
	TextScaled = true,
	Text = KICK_HINT,
})

local details = makeLabel({
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 54),
	Size = UDim2.fromOffset(360, 50),
	Font = Enum.Font.Gotham,
	TextSize = 17,
	Visible = false,
})

-- Arriba a la izquierda: estadísticas.
local stats = makeLabel({
	AnchorPoint = Vector2.new(0, 0),
	Position = UDim2.new(0, 12, 0, 56),
	Size = UDim2.fromOffset(240, 118),
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextSize = 17,
	RichText = true,
})
local statsPadding = Instance.new("UIPadding")
statsPadding.PaddingLeft = UDim.new(0, 10)
statsPadding.PaddingTop = UDim.new(0, 8)
statsPadding.Parent = stats

-- Abajo al centro: apuntar y patear.
local leftButton = makeButton({
	Text = "◀",
	TextScaled = true,
	Size = UDim2.fromOffset(70, 70),
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, -140, 1, -24),
	BackgroundColor3 = COLORS.neutral,
})
local kickButton = makeButton({
	Text = "PATEAR",
	TextScaled = true,
	Size = UDim2.fromOffset(170, 70),
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -24),
	BackgroundColor3 = COLORS.kick,
})
local rightButton = makeButton({
	Text = "▶",
	TextScaled = true,
	Size = UDim2.fromOffset(70, 70),
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 140, 1, -24),
	BackgroundColor3 = COLORS.neutral,
})
local trainButton = makeButton({
	Text = "ENTRENAR",
	TextScaled = true,
	Size = UDim2.fromOffset(200, 70),
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -24),
	BackgroundColor3 = COLORS.train,
	Visible = false,
})

-- Arriba a la derecha: reiniciar y tienda.
local resetButton = makeButton({
	Text = "Reiniciar (R)",
	Size = UDim2.fromOffset(130, 40),
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -12, 0, 56),
	BackgroundColor3 = COLORS.equipped,
})
local shopButton = makeButton({
	Text = "TIENDA",
	Size = UDim2.fromOffset(130, 40),
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -12, 0, 102),
	BackgroundColor3 = COLORS.buy,
})

local shop = Instance.new("Frame")
shop.AnchorPoint = Vector2.new(1, 0)
shop.Position = UDim2.new(1, -12, 0, 148)
shop.Size = UDim2.fromOffset(260, 0)
shop.AutomaticSize = Enum.AutomaticSize.Y
shop.BackgroundColor3 = COLORS.panel
shop.BackgroundTransparency = 0.2
shop.Visible = false
round(shop)
shop.Parent = gui
local shopLayout = Instance.new("UIListLayout")
shopLayout.Padding = UDim.new(0, 6)
shopLayout.SortOrder = Enum.SortOrder.LayoutOrder
shopLayout.Parent = shop
local shopPadding = Instance.new("UIPadding")
for _, side in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
	shopPadding[side] = UDim.new(0, 8)
end
shopPadding.Parent = shop

local function shopTitle(text: string, order: number)
	makeLabel({
		Parent = shop,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, 22),
		BackgroundTransparency = 1,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 16,
		Text = text,
	})
end

shopTitle("Pelota: rompe más y frena menos", 1)
local ballButton = makeButton({
	Parent = shop,
	LayoutOrder = 2,
	Size = UDim2.new(1, 0, 0, 52),
	TextSize = 15,
	BackgroundColor3 = COLORS.neutral,
})
shopTitle("Zapatillas: multiplican tu fuerza", 3)
local shoeButtons = {}
for id, shoe in Balance.Shoes do
	shoeButtons[id] = makeButton({
		Parent = shop,
		LayoutOrder = 3 + id,
		Size = UDim2.new(1, 0, 0, 44),
		TextSize = 15,
		BackgroundColor3 = COLORS.neutral,
	})
end

-- Explicación inicial, una vez por sesión.
local intro = makeLabel({
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(460, 270),
	BackgroundTransparency = 0.1,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
	TextSize = 18,
	RichText = true,
	Text = table.concat({
		"<b>PATADA DEMOLEDORA</b>",
		"",
		"1. Apuntá con " .. (if isTouch then "◀ ▶" else "Q/E") .. " y pateá la pelota.",
		"2. Rompé un soporte y derribá la estructura: las roturas en cadena pagan más.",
		"3. En la zona azul podés entrenar para sumar fuerza.",
		"4. En la TIENDA mejorá la pelota o comprá zapatillas.",
	}, "\n"),
})
local introPadding = Instance.new("UIPadding")
for _, side in { "PaddingTop", "PaddingLeft", "PaddingRight" } do
	introPadding[side] = UDim.new(0, 16)
end
introPadding.Parent = intro
local introButton = makeButton({
	Parent = intro,
	Text = "¡A patear!",
	Size = UDim2.fromOffset(180, 46),
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, -16, 1, -14),
	BackgroundColor3 = COLORS.kick,
})
introButton.Activated:Connect(function()
	intro.Visible = false
end)

-- Actualización de la interfaz ---------------------------------------------------

local function ownedShoes(): { [number]: boolean }
	local owned = {}
	for _, id in string.split(player:GetAttribute("ZapatillasCompradas") or "1", ",") do
		owned[tonumber(id)] = true
	end
	return owned
end

local function refresh()
	local money = getStat("Plata")
	local strength = getStat("Fuerza")
	local level = player:GetAttribute("NivelPelota") or 1
	local shoeId = player:GetAttribute("Zapatillas") or 1
	local shoe = Balance.Shoes[shoeId]
	local ball = Balance.BallLevels[level]

	stats.Text = table.concat({
		string.format("<font color='#7CFC7C'>Plata: $%d</font>  (última: +$%d)", money, lastEarned),
		string.format("Fuerza: %d", strength),
		string.format("Zapatillas: %s %s", shoe.Name, multiplierText(shoe.Multiplier)),
		string.format("Pelota: nivel %d (rompe %s)", level, multiplierText(ball.BreakMultiplier)),
		string.format("Potencia de patada: %d", player:GetAttribute("VelocidadPatada") or 0),
	}, "\n")

	local nextBall = Balance.BallLevels[level + 1]
	if nextBall then
		ballButton.Text = string.format(
			"Nivel %d → %d (rompe %s)\n$%d",
			level,
			level + 1,
			multiplierText(nextBall.BreakMultiplier),
			nextBall.Price
		)
		ballButton.BackgroundColor3 = if money >= nextBall.Price then COLORS.buy else COLORS.neutral
	else
		ballButton.Text = string.format("Nivel %d: máximo", level)
		ballButton.BackgroundColor3 = COLORS.neutral
	end

	local owned = ownedShoes()
	for id, button in shoeButtons do
		local model = Balance.Shoes[id]
		if id == shoeId then
			button.Text = string.format("%s %s — equipadas", model.Name, multiplierText(model.Multiplier))
			button.BackgroundColor3 = COLORS.equipped
		elseif owned[id] then
			button.Text = string.format("%s %s — equipar", model.Name, multiplierText(model.Multiplier))
			button.BackgroundColor3 = COLORS.neutral
		else
			button.Text = string.format("%s %s — $%d", model.Name, multiplierText(model.Multiplier), model.Price)
			button.BackgroundColor3 = if money >= model.Price then COLORS.buy else COLORS.neutral
		end
	end
end

-- Sonidos de compra y entrenamiento: se disparan cuando el servidor confirma el cambio.
local lastStrength = nil
local function onStatsChanged()
	local strength = getStat("Fuerza")
	if lastStrength and lastStrength > 0 and strength > lastStrength then
		playLocalSound("Train")
	end
	lastStrength = strength
	refresh()
end

local purchases = {
	NivelPelota = player:GetAttribute("NivelPelota"),
	ZapatillasCompradas = player:GetAttribute("ZapatillasCompradas"),
}
local function onPurchaseChanged(attribute: string)
	return function()
		-- El primer valor lo pone el servidor al entrar; no es una compra.
		if purchases[attribute] ~= nil then
			playLocalSound("Purchase")
		end
		purchases[attribute] = player:GetAttribute(attribute)
		refresh()
	end
end

task.spawn(function()
	local leaderstats = player:WaitForChild("leaderstats")
	leaderstats:WaitForChild("Plata").Changed:Connect(refresh)
	leaderstats:WaitForChild("Fuerza").Changed:Connect(onStatsChanged)
	lastStrength = getStat("Fuerza")
	refresh()
end)
player:GetAttributeChangedSignal("NivelPelota"):Connect(onPurchaseChanged("NivelPelota"))
player:GetAttributeChangedSignal("ZapatillasCompradas"):Connect(onPurchaseChanged("ZapatillasCompradas"))
player:GetAttributeChangedSignal("Zapatillas"):Connect(refresh)
player:GetAttributeChangedSignal("VelocidadPatada"):Connect(refresh)
refresh()

-- Flecha de apuntado (solo existe en este cliente) ----------------------------

local arrow = Instance.new("Part")
arrow.Name = "FlechaDeApuntado"
arrow.Anchored = true
arrow.CanCollide = false
arrow.CanQuery = false
arrow.CanTouch = false
arrow.CastShadow = false
arrow.Material = Enum.Material.Neon
arrow.Color = Color3.fromRGB(255, 210, 60)
arrow.Transparency = 0.2
arrow.Size = Vector3.new(0.6, 0.2, 10)

-- Acciones --------------------------------------------------------------------

local function nearTraining(): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local spot = remotes:GetAttribute("EntrenamientoPos")
	if not root or not spot then
		return false
	end
	local offset = root.Position - spot
	return Vector3.new(offset.X, 0, offset.Z).Magnitude <= Config.TrainRange
end

local function kick()
	-- Una pulsación = una patada. El servidor además ignora pedidos fuera del estado Listo.
	local now = os.clock()
	if now - lastKickPress < 0.3 or remotes:GetAttribute("Estado") ~= "Listo" then
		return
	end
	lastKickPress = now
	remotes.Patear:FireServer(angle)
end

local function train()
	if not nearTraining() then
		status.Text = "Andá a la zona azul de entrenamiento."
		return
	end
	-- Sentadilla con salto: el servidor decide si la repetición cuenta.
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.FloorMaterial ~= Enum.Material.Air then
		humanoid.Jump = true
	end
	remotes.Entrenar:FireServer()
end

local function requestReset()
	remotes.Reiniciar:FireServer()
end

local function isPress(input: InputObject)
	return input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch
end

local function bindHold(button: TextButton, direction: number)
	button.InputBegan:Connect(function(input)
		if isPress(input) then
			buttonTurn = direction
		end
	end)
	button.InputEnded:Connect(function(input)
		if isPress(input) and buttonTurn == direction then
			buttonTurn = 0
		end
	end)
end

-- Ángulo positivo = derecha, así que ◀ resta.
bindHold(leftButton, -1)
bindHold(rightButton, 1)

-- Si se suelta el dedo fuera del botón, InputEnded del botón puede no llegar.
UserInputService.InputEnded:Connect(function(input)
	if isPress(input) then
		buttonTurn = 0
	end
end)

kickButton.Activated:Connect(kick)
trainButton.Activated:Connect(train)
resetButton.Activated:Connect(requestReset)
shopButton.Activated:Connect(function()
	shop.Visible = not shop.Visible
end)
ballButton.Activated:Connect(function()
	remotes.MejorarPelota:FireServer()
end)
for id, button in shoeButtons do
	button.Activated:Connect(function()
		if ownedShoes()[id] then
			remotes.EquiparZapatillas:FireServer(id)
		else
			remotes.ComprarZapatillas:FireServer(id)
		end
	end)
end

local function onTurnKey(actionName: string, inputState: Enum.UserInputState)
	local direction = if actionName == "ApuntarIzquierda" then -1 else 1
	if inputState == Enum.UserInputState.Begin then
		keyTurn = direction
	elseif keyTurn == direction then
		keyTurn = 0
	end
	return Enum.ContextActionResult.Sink
end

local function onPress(callback)
	return function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			callback()
		end
		return Enum.ContextActionResult.Sink
	end
end

ContextActionService:BindAction("ApuntarIzquierda", onTurnKey, false, Enum.KeyCode.Q)
ContextActionService:BindAction("ApuntarDerecha", onTurnKey, false, Enum.KeyCode.E)
ContextActionService:BindAction("Patear", onPress(kick), false, Enum.KeyCode.F)
ContextActionService:BindAction("Entrenar", onPress(train), false, Enum.KeyCode.T)
ContextActionService:BindAction("Reiniciar", onPress(requestReset), false, Enum.KeyCode.R)

-- Cuadro a cuadro ------------------------------------------------------------------

local wasTraining = false

RunService.RenderStepped:Connect(function(dt)
	local turn = math.clamp(keyTurn + buttonTurn, -1, 1)
	angle = math.clamp(angle + turn * Config.AimSpeed * dt, -Config.MaxAimAngle, Config.MaxAimAngle)

	-- En la zona de entrenamiento el botón principal pasa a ser ENTRENAR.
	local training = nearTraining()
	trainButton.Visible = training
	kickButton.Visible = not training
	leftButton.Visible = not training
	rightButton.Visible = not training
	if training ~= wasTraining then
		wasTraining = training
		if remotes:GetAttribute("Estado") == "Listo" then
			status.Text = if training then TRAIN_HINT else KICK_HINT
		end
	end

	local ballPos = remotes:GetAttribute("PelotaPos")
	if ballPos and not training and remotes:GetAttribute("Estado") == "Listo" then
		local direction = Aim.direction(angle)
		local flat = Vector3.new(direction.X, 0, direction.Z).Unit
		local base = ballPos - Vector3.new(0, Config.Ball.Diameter / 2 - 0.15, 0)
		local center = base + flat * (Config.Ball.Diameter / 2 + 1 + arrow.Size.Z / 2)
		arrow.CFrame = CFrame.lookAt(center, center + flat)
		arrow.Parent = workspace
	else
		arrow.Parent = nil
	end
end)

-- Estado y resultados ---------------------------------------------------------

local function onStateChanged()
	local state = remotes:GetAttribute("Estado")
	if state == "Pateando" then
		status.Text = "¡Patada!"
		details.Visible = false
	elseif state == "Reiniciando" then
		status.Text = "Reiniciando escenario..."
	elseif state == "Listo" then
		status.Text = if wasTraining then TRAIN_HINT else KICK_HINT
	end
end

remotes:GetAttributeChangedSignal("Estado"):Connect(onStateChanged)
onStateChanged()

remotes.Resultado.OnClientEvent:Connect(function(result)
	status.Text = result.message
	local earnedText = if result.kicker == player
		then string.format("Ganaste $%d", result.earned)
		else "Patada de otro jugador"
	details.Text = string.format("Roturas: %d directas, %d en cadena\n%s", result.direct, result.chain, earnedText)
	details.Visible = true
	if result.kicker == player then
		lastEarned = result.earned
		refresh()
	end
end)

remotes.Aviso.OnClientEvent:Connect(function(text)
	status.Text = text
end)
