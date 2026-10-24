-- Apuntar y patear: Q/E o ◀ ▶ para apuntar, F o PATEAR para patear, R para reiniciar.
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Aim = require(Shared:WaitForChild("Aim"))
local remotes = ReplicatedStorage:WaitForChild("Remotes")

local player = Players.LocalPlayer

local angle = 0
local keyTurn = 0
local buttonTurn = 0

local isTouch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local HINT = if isTouch
	then "Apuntá con ◀ ▶ y tocá PATEAR"
	else "Apuntá con Q/E (o ◀ ▶) y pateá con F"

-- Interfaz --------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "PatadaUI"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local function round(instance: GuiObject)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = instance
end

local status = Instance.new("TextLabel")
status.AnchorPoint = Vector2.new(0.5, 0)
status.Position = UDim2.new(0.5, 0, 0, 8)
status.Size = UDim2.new(0.7, 0, 0, 36)
status.BackgroundColor3 = Color3.new(0, 0, 0)
status.BackgroundTransparency = 0.4
status.TextColor3 = Color3.new(1, 1, 1)
status.Font = Enum.Font.GothamBold
status.TextScaled = true
status.Text = HINT
round(status)
status.Parent = gui

local details = Instance.new("TextLabel")
details.AnchorPoint = Vector2.new(0.5, 0)
details.Position = UDim2.new(0.5, 0, 0, 50)
details.Size = UDim2.new(0, 300, 0, 56)
details.BackgroundColor3 = Color3.new(0, 0, 0)
details.BackgroundTransparency = 0.5
details.TextColor3 = Color3.new(1, 1, 1)
details.Font = Enum.Font.Gotham
details.TextSize = 18
details.Visible = false
round(details)
details.Parent = gui

local function makeButton(text: string, size: UDim2, position: UDim2, color: Color3, anchor: Vector2?): TextButton
	local button = Instance.new("TextButton")
	button.Text = text
	button.Size = size
	button.Position = position
	button.AnchorPoint = anchor or Vector2.new(0.5, 1)
	button.BackgroundColor3 = color
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Font = Enum.Font.GothamBold
	button.TextScaled = true
	round(button)
	button.Parent = gui
	return button
end

local leftButton = makeButton("◀", UDim2.fromOffset(70, 70), UDim2.new(0.5, -140, 1, -16), Color3.fromRGB(60, 60, 70))
local kickButton = makeButton("PATEAR", UDim2.fromOffset(170, 70), UDim2.new(0.5, 0, 1, -16), Color3.fromRGB(220, 70, 50))
local rightButton = makeButton("▶", UDim2.fromOffset(70, 70), UDim2.new(0.5, 140, 1, -16), Color3.fromRGB(60, 60, 70))
local resetButton = makeButton(
	"Reiniciar",
	UDim2.fromOffset(120, 40),
	UDim2.new(1, -12, 0, 56),
	Color3.fromRGB(70, 110, 180),
	Vector2.new(1, 0)
)

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

local function kick()
	if remotes:GetAttribute("Estado") == "Listo" then
		remotes.Patear:FireServer(angle)
	end
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
resetButton.Activated:Connect(requestReset)

local function onTurnKey(actionName: string, inputState: Enum.UserInputState)
	local direction = if actionName == "ApuntarIzquierda" then -1 else 1
	if inputState == Enum.UserInputState.Begin then
		keyTurn = direction
	elseif keyTurn == direction then
		keyTurn = 0
	end
	return Enum.ContextActionResult.Sink
end

ContextActionService:BindAction("ApuntarIzquierda", onTurnKey, false, Enum.KeyCode.Q)
ContextActionService:BindAction("ApuntarDerecha", onTurnKey, false, Enum.KeyCode.E)
ContextActionService:BindAction("Patear", function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		kick()
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.F)
ContextActionService:BindAction("Reiniciar", function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		requestReset()
	end
	return Enum.ContextActionResult.Sink
end, false, Enum.KeyCode.R)

RunService.RenderStepped:Connect(function(dt)
	local turn = math.clamp(keyTurn + buttonTurn, -1, 1)
	angle = math.clamp(angle + turn * Config.AimSpeed * dt, -Config.MaxAimAngle, Config.MaxAimAngle)

	local ballPos = remotes:GetAttribute("PelotaPos")
	if ballPos and remotes:GetAttribute("Estado") == "Listo" then
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
		status.Text = HINT
	end
end

remotes:GetAttributeChangedSignal("Estado"):Connect(onStateChanged)
onStateChanged()

remotes.Resultado.OnClientEvent:Connect(function(result)
	status.Text = result.message
	details.Text = string.format("Roturas: %d directas, %d en cadena", result.direct, result.chain)
	details.Visible = true
end)

remotes.Aviso.OnClientEvent:Connect(function(text)
	status.Text = text
end)
