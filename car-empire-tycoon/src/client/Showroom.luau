--!strict
--[[ Showroom 3D del menú principal: ocupa toda la pantalla detrás de las tarjetas de empresas. Muestra el
	auto exhibido de la empresa elegida (Compañía › Marca › «Auto exhibido en el menú») sobre una plataforma,
	con el fondo y las luces del color corporativo. Se arma con las mismas piezas que el editor
	(CarModel.build); no crea modelos nuevos. El auto gira despacio salvo con «Reducir movimiento». ]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local CarModel = require(Shared.CarModel)
local DesignCalc = require(Shared.DesignCalc)

local Showroom = {}

local state = { model = nil :: Model?, camera = nil :: Camera?, yaw = 35, dist = 14, height = 1.2, reduce = false }

-- Auto por defecto (empresa nueva o sin diseños): el sedán de 1970.
local function defaultSpec(): any
	local fake = { time = { day = 0, minute = 0 }, research = { done = {}, projects = {} }, company = { name = "Showroom" }, devPaid = {}, facilities = { factory = 1, research = 1, lines = {}, builds = {} } }
	return DesignCalc.newDraft(fake, "brisa")
end

local function darken(c: Color3, k: number): Color3
	return Color3.new(c.R * k, c.G * k, c.B * k)
end

--[[ Arma el showroom dentro de `parent`. spec = diseño a exhibir (o nil), color = color corporativo (#hex). ]]
function Showroom.mount(parent: Instance, spec: any?, color: string?, reduceMotion: boolean?): ViewportFrame
	local brand = Color3.fromHex(color or "#7667FF")
	local vp = Instance.new("ViewportFrame")
	vp.Name = "Showroom"
	vp.Size = UDim2.fromScale(1, 1)
	vp.BackgroundColor3 = darken(brand, 0.16)
	vp.BackgroundTransparency = 0
	vp.BorderSizePixel = 0
	vp.Ambient = darken(brand, 0.55)
	vp.LightColor = Color3.new(1, 1, 1)
	vp.LightDirection = Vector3.new(-0.6, -1, -0.4)
	vp.ZIndex = 0
	vp.Parent = parent
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(darken(brand, 1.6), darken(brand, 0.5))
	grad.Parent = vp
	local world = Instance.new("WorldModel")
	world.Parent = vp
	-- Plataforma giratoria y piso.
	local floor = Instance.new("Part")
	floor.Name = "Piso"
	floor.Anchored = true
	floor.Size = Vector3.new(80, 0.4, 80)
	floor.Position = Vector3.new(0, -0.2, 0)
	floor.Color = darken(brand, 0.22)
	floor.Material = Enum.Material.SmoothPlastic
	floor.Parent = world
	local disc = Instance.new("Part")
	disc.Name = "Plataforma"
	disc.Shape = Enum.PartType.Cylinder
	disc.Anchored = true
	disc.Size = Vector3.new(0.25, 20, 20)
	disc.CFrame = CFrame.new(0, 0.12, 0) * CFrame.Angles(0, 0, math.rad(90))
	disc.Color = darken(brand, 0.7)
	disc.Material = Enum.Material.SmoothPlastic
	disc.Parent = world
	local ok, m = pcall(function()
		return CarModel.build(spec or defaultSpec(), { brandColor = color })
	end)
	if ok and m then
		m.Parent = world
		local size = m:GetExtentsSize()
		local pivot = m:GetPivot()
		local cf, ext = m:GetBoundingBox()
		m:PivotTo(pivot + Vector3.new(-cf.Position.X, 0.25 - (cf.Position.Y - ext.Y / 2), -cf.Position.Z))
		state.model = m
		state.dist = math.max(9, size.Magnitude * 1.25)
		state.height = size.Y * 0.45
	else
		state.model = nil
	end
	local cam = Instance.new("Camera")
	cam.FieldOfView = 40
	cam.Parent = vp
	vp.CurrentCamera = cam
	state.camera = cam
	state.reduce = reduceMotion == true
	Showroom.place()
	return vp
end

-- Ubica la cámara (vista de tres cuartos, el auto a la derecha de la pantalla, detrás de las tarjetas).
function Showroom.place()
	local cam = state.camera
	if not cam or not cam.Parent then
		return
	end
	local yaw = math.rad(state.yaw)
	local target = Vector3.new(-state.dist * 0.18, state.height, 0)
	local eye = Vector3.new(math.sin(yaw) * state.dist, state.height + state.dist * 0.22, math.cos(yaw) * state.dist)
	cam.CFrame = CFrame.lookAt(eye, target)
end

RunService.RenderStepped:Connect(function(dt: number)
	if state.reduce or not state.camera or not state.camera.Parent then
		return
	end
	state.yaw = (state.yaw + dt * 8) % 360
	Showroom.place()
end)

return Showroom
