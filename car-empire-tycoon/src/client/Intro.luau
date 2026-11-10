--!strict
--[[ Introducción cinematográfica al fundar una empresa (se puede saltar).
	Dura unos segundos: franjas de cine, el logo y el nombre de la empresa, la fecha de inicio y un recorrido de
	la cámara sobre el garaje (SceneCamera.cinematic). Mientras se ve, la empresa está en pausa (App.menuPaused
	incluye App.ui.intro), así no se pierde tiempo de juego. «Saltar», Espacio, Enter o Esc la terminan.
	Con «Reducir movimiento» no hay recorrido de cámara y los textos aparecen sin animación. ]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local SceneCamera = require(script.Parent.SceneCamera)
local T = Ui.T
local W = Ui.W

local Intro = {}

Intro.DURATION = 9 -- segundos
Intro.LINES = {
	{ at = 0.6, text = "1 de enero de 1970" },
	{ at = 2.8, text = "Un garaje, " .. Util.money(Catalog.START.money) .. " y una idea." },
	{ at = 5.0, text = "Diseñá tu primer auto, fabricalo y salí a venderlo." },
}

local layer: Frame? = nil
local conns: { RBXScriptConnection } = {}

local function clear()
	for _, c in conns do
		c:Disconnect()
	end
	table.clear(conns)
	if layer then
		layer:Destroy()
		layer = nil
	end
end

function Intro.active(): boolean
	return App.ui.intro ~= nil
end

-- Termina la introducción (al saltarla o al llegar al final) y reanuda la empresa.
function Intro.finish()
	if not App.ui.intro then
		return
	end
	App.ui.intro = nil
	SceneCamera.cinematic(nil)
	clear()
	App.syncPause()
end

-- Empieza la introducción para la empresa recién creada (company = { name, color, logo }).
function Intro.play(company: any)
	clear()
	App.ui.intro = { t = 0 }
	App.syncPause()
	local reduce = App.settings and App.settings.reduceMotion == true
	if not reduce then
		SceneCamera.cinematic(Intro.DURATION)
	end
	-- Active: el fondo absorbe los clics (no se toca el HUD de abajo mientras dura).
	local root = Ui.new("Frame", { Name = "Intro", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.55, Active = true, ZIndex = 70, Parent = App.introLayer })
	layer = root
	-- Franjas de cine arriba y abajo.
	for i, y in { 0, 1 } do
		Ui.new("Frame", { Name = "Franja" .. i, AnchorPoint = Vector2.new(0, y), Position = UDim2.fromScale(0, y), Size = UDim2.new(1, 0, 0.12, 0), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0, Parent = root })
	end
	local card = Ui.col({
		Ui.logo(company, 84),
		Ui.text(company.name or "", { size = 40, weight = W.heavy, align = "C", name = "IntroNombre" }),
	}, 12, { Name = "IntroMarca", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.42), Size = UDim2.fromOffset(math.min(720, App.vw - 32), 0), AutomaticSize = Enum.AutomaticSize.Y, h = "C", Parent = root })
	local _ = card
	local lines = Ui.col({}, 8, { Name = "IntroTextos", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.6), Size = UDim2.fromOffset(math.min(720, App.vw - 32), 0), AutomaticSize = Enum.AutomaticSize.Y, h = "C", Parent = root })
	local shown = {}
	local skip = Ui.button("Saltar", "default", Intro.finish, { small = true, name = "SaltarIntro", kbd = "Esc" })
	skip.AnchorPoint = Vector2.new(1, 1)
	skip.Position = UDim2.new(1, -24, 0.88, -12)
	skip.ZIndex = 72
	skip.Parent = root
	local function step(t: number)
		for i, l in Intro.LINES do
			if not shown[i] and (reduce or t >= l.at) then
				shown[i] = true
				Ui.text(l.text, { size = i == 1 and 24 or 18, weight = i == 1 and W.bold or W.med, color = i == 1 and T.ye or T.tx2, align = "C", name = "IntroLinea" .. i }).Parent = lines
			end
		end
	end
	step(0)
	table.insert(conns, RunService.RenderStepped:Connect(function(dt: number)
		local st = App.ui.intro
		if not st then
			return
		end
		st.t += dt
		step(st.t)
		if st.t >= Intro.DURATION then
			Intro.finish()
		end
	end))
	table.insert(conns, UserInputService.InputBegan:Connect(function(input: InputObject)
		local k = input.KeyCode
		if k == Enum.KeyCode.Escape or k == Enum.KeyCode.Space or k == Enum.KeyCode.Return then
			Intro.finish()
		end
	end))
end

return Intro
