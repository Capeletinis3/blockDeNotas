--!strict
--[[
	NO SE INICIA (decisión de diseño: las instalaciones se administran desde los menús, sin caminar).
	Main.client no llama a WorldPrompts.start() y el servidor crea los ProximityPrompt del garaje desactivados
	(Garage.PROMPTS_ENABLED = false). Se conserva sin conectar como base si más adelante se decide mostrar
	indicadores sobre los objetos del mundo. Pendiente de decidir antes de usarlo:
	· si los puntos sobre los objetos deben existir (hoy duplicarían la barra de navegación);
	· qué hace un clic: WorldPrompts.onOpen(pantalla) no está asignado; para activarlo, Main.client debería
	  asignarlo a App.go y Garage.PROMPTS_ENABLED pasar a true.
	Lo que haría al iniciarse:
	· cerca de un objeto, la píldora clara «[E] Escritorio de diseño» (.prompt), que también se toca en celular;
	· lejos, un punto (.dot3d) sobre cada objeto de tu garaje que abre su pantalla.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local UserInputService = game:GetService("UserInputService")

local Ui = require(script.Parent.Ui)
local T = Ui.T
local W = Ui.W

local WorldPrompts = {}
-- Lo asigna Main.client: abre la pantalla de gestión del objeto (mismo camino que el ProximityPrompt).
WorldPrompts.onOpen = nil :: ((string) -> ())?

local player = Players.LocalPlayer
local shown: { [Instance]: BillboardGui } = {}
local dots: { [Instance]: BillboardGui } = {}

local function adornee(prompt: ProximityPrompt): Instance?
	local p = prompt.Parent
	if p and (p:IsA("BasePart") or p:IsA("Attachment") or p:IsA("Model")) then
		return p
	end
	return nil
end

local function mine(prompt: ProximityPrompt): boolean
	return prompt:GetAttribute("CarEmpire") == true and prompt:GetAttribute("OwnerId") == player.UserId
end

local function billboard(name: string, prompt: ProximityPrompt, size: UDim2): BillboardGui
	local b = Instance.new("BillboardGui")
	b.Name = name
	b.Adornee = adornee(prompt)
	b.AlwaysOnTop = true
	b.Size = size
	b.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
	b.LightInfluence = 0
	b.ResetOnSpawn = false
	b.Parent = player:WaitForChild("PlayerGui")
	return b
end

-- Píldora .prompt: fondo claro, tecla oscura redonda y el nombre del objeto.
local function showPill(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
	if shown[prompt] then
		return
	end
	local dot = dots[prompt]
	if dot then
		dot.Enabled = false
	end
	local gui = billboard("IndicacionCarEmpire", prompt, UDim2.fromOffset(300, 52))
	local touch = inputType == Enum.ProximityPromptInputType.Touch
	local keyText = touch and "Tocar" or (inputType == Enum.ProximityPromptInputType.Gamepad and "X" or prompt.KeyboardKeyCode.Name)
	local pill = Ui.new("TextButton", {
		Name = "Indicacion", Text = "", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 44), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = T.tx, BackgroundTransparency = 0.03,
		Corner = 22, Stroke = { T.vi, 4, 0.6 }, Pad = { 6, 14, 6, 6 }, List = { dir = "H", gap = 10, v = "C" },
	}, {
		Ui.new("TextLabel", {
			Name = "Tecla", Text = keyText, TextSize = 13, Weight = W.bold, TextColor3 = T.tx, TextXAlignment = Enum.TextXAlignment.Center,
			BackgroundColor3 = T.dark, BackgroundTransparency = 0, Size = UDim2.fromOffset(32, 32), AutomaticSize = Enum.AutomaticSize.X, Corner = 16, Pad = { 0, 8 },
		}),
		Ui.inline(prompt.ObjectText ~= "" and prompt.ObjectText or prompt.ActionText, { size = 15, weight = W.heavy, color = T.dark }),
	})
	pill.Activated:Connect(function()
		prompt:InputHoldBegin()
		prompt:InputHoldEnd()
	end)
	pill.Parent = gui
	gui.Active = true
	shown[prompt] = gui
end

local function hidePill(prompt: ProximityPrompt)
	local g = shown[prompt]
	if g then
		g:Destroy()
		shown[prompt] = nil
	end
	local dot = dots[prompt]
	if dot then
		dot.Enabled = true
	end
end

-- Punto .dot3d: círculo oscuro con borde claro; el nombre aparece al pasar el puntero.
local function addDot(prompt: ProximityPrompt)
	if dots[prompt] or not mine(prompt) then
		return
	end
	local gui = billboard("PuntoCarEmpire", prompt, UDim2.fromOffset(200, 40))
	gui.MaxDistance = 140
	gui.Active = true
	local tip = Ui.new("TextLabel", {
		Name = "Rotulo", Text = prompt.ObjectText, TextSize = 12, Weight = W.bold, Position = UDim2.fromOffset(122, 9), Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = Color3.fromHex("#080A0F"), BackgroundTransparency = 0.15, Corner = 6, Pad = { 0, 8 }, Visible = false,
	})
	local b = Ui.new("TextButton", {
		Name = "Punto", Text = "", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(34, 34),
		BackgroundColor3 = Color3.fromHex("#0E1626"), BackgroundTransparency = 0.15, Corner = 17, Stroke = { T.tx, 2, 0.15 },
	}, {
		Ui.new("Frame", { Size = UDim2.fromOffset(9, 9), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundColor3 = T.tx, BackgroundTransparency = 0, Corner = 5 }),
	})
	b.MouseEnter:Connect(function()
		tip.Visible = true
	end)
	b.MouseLeave:Connect(function()
		tip.Visible = false
	end)
	-- Sin personaje jugable: el punto abre directamente el menú de ese objeto (no hace falta caminar).
	b.Activated:Connect(function()
		local screen = prompt:GetAttribute("Screen")
		if type(screen) == "string" and WorldPrompts.onOpen then
			WorldPrompts.onOpen(screen)
		end
	end)
	b.Parent = gui
	tip.Parent = gui
	dots[prompt] = gui
	prompt.Destroying:Connect(function()
		hidePill(prompt)
		local d = dots[prompt]
		if d then
			d:Destroy()
			dots[prompt] = nil
		end
	end)
end

local function watch(inst: Instance)
	if inst:IsA("ProximityPrompt") then
		-- El dueño se marca en el servidor; si llega después, se vuelve a mirar.
		addDot(inst)
		inst:GetAttributeChangedSignal("OwnerId"):Connect(function()
			addDot(inst)
		end)
	end
end

function WorldPrompts.start()
	local ok = pcall(function()
		ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
			if prompt:GetAttribute("CarEmpire") == true then
				showPill(prompt, inputType)
			end
		end)
		ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
			hidePill(prompt)
		end)
		for _, d in workspace:GetDescendants() do
			watch(d)
		end
		workspace.DescendantAdded:Connect(watch)
	end)
	-- En el entorno de pruebas sin Roblox no existen estos eventos: la interfaz sigue funcionando.
	return ok and UserInputService ~= nil
end

return WorldPrompts
