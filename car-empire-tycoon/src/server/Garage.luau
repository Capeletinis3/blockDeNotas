--!strict
--[[
	Mundo provisional: un vestíbulo y un garaje básico por jugador (parcela).
	Cada garaje tiene cuatro puntos de interacción (ProximityPrompt) y muestra con modelos
	provisionales lo que pasa en la partida: unidad en fabricación, almacén, salón y clientes.
	La decoración definitiva del mapa queda para etapas posteriores.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local CarModel = require(Shared.CarModel)
local Rules = require(Shared.Rules)

local Garage = {}
Garage.__index = Garage

local PLOT_COUNT = 8
local PLOT_W, PLOT_D = 90, 70
local PLOT_SPACING = 110
local PLOTS_Z = 130

local C = {
	floor = Color3.fromHex("#2B303D"),
	wall = Color3.fromHex("#343A48"),
	dark = Color3.fromHex("#111319"),
	line = Color3.fromHex("#F7C95C"),
	ground = Color3.fromHex("#151A24"),
	tx = Color3.fromHex("#F5F7FA"),
	mut = Color3.fromHex("#A3AAB8"),
	vi = Color3.fromHex("#7667FF"),
	gr = Color3.fromHex("#42E58D"),
	or_ = Color3.fromHex("#FFB36B"),
	bl = Color3.fromHex("#8DB8FF"),
}

local function block(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props then
		for k, v in props do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

local function label(parent: Instance, text: string, size: UDim2, offset: Vector3, color: Color3?): TextLabel
	local bb = Instance.new("BillboardGui")
	bb.Name = "Etiqueta"
	bb.Size = size
	bb.StudsOffset = offset
	bb.AlwaysOnTop = false
	bb.MaxDistance = 90
	bb.LightInfluence = 0
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = C.dark
	t.BackgroundTransparency = 0.15
	t.TextColor3 = color or C.tx
	t.TextScaled = true
	t.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
	t.Text = text
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = t
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = t
	t.Parent = bb
	bb.Parent = parent
	return t
end

function Garage.new(onPrompt: (player: Player, owner: Player?, screen: string) -> ())
	local self = setmetatable({}, Garage)
	self.onPrompt = onPrompt
	self.plots = {} -- índice → { owner, cf, model, dynamic, sig, progressLabels }
	self.byPlayer = {} -- Player → índice
	self.root = Instance.new("Folder")
	self.root.Name = "CarEmpireWorld"
	self.root.Parent = Workspace
	self:buildLobby()
	for i = 1, PLOT_COUNT do
		local x = (i - (PLOT_COUNT + 1) / 2) * PLOT_SPACING
		-- El frente abierto del garaje mira hacia el vestíbulo (−Z del mundo).
		local cf = CFrame.new(x, 0, PLOTS_Z) * CFrame.Angles(0, math.pi, 0)
		self.plots[i] = { owner = nil, cf = cf }
		self:buildEmptyPlot(i)
	end
	return self
end

function Garage:buildLobby()
	local lobby = Instance.new("Folder")
	lobby.Name = "Vestibulo"
	lobby.Parent = self.root
	block(lobby, "Terreno", Vector3.new(PLOT_COUNT * PLOT_SPACING + 120, 1, 260), CFrame.new(0, -0.5, 70), C.ground, { Material = Enum.Material.Asphalt })
	block(lobby, "Plaza", Vector3.new(70, 0.4, 50), CFrame.new(0, 0.2, 0), C.floor)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Llegada"
	spawn.Anchored = true
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = CFrame.new(0, 0.5, 0)
	spawn.Color = C.vi
	spawn.Material = Enum.Material.Neon
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = lobby
	local sign = block(lobby, "Cartel", Vector3.new(30, 6, 1), CFrame.new(0, 6, -22), C.dark)
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Back
	sg.PixelsPerStud = 30
	sg.LightInfluence = 0
	sg.Parent = sign
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.TextColor3 = C.tx
	t.TextScaled = true
	t.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Heavy)
	t.Text = "CAR EMPIRE TYCOON"
	t.Parent = sg
	-- Camino hacia la fila de garajes.
	block(lobby, "Camino", Vector3.new(PLOT_COUNT * PLOT_SPACING, 0.2, 40), CFrame.new(0, 0.1, 70), Color3.fromHex("#20242E"))
end

function Garage:plotPart(i: number, name: string, size: Vector3, localCf: CFrame, color: Color3, props: { [string]: any }?): Part
	local plot = self.plots[i]
	return block(plot.model, name, size, plot.cf * localCf, color, props)
end

function Garage:buildEmptyPlot(i: number)
	local plot = self.plots[i]
	if plot.model then
		plot.model:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "Garaje" .. i
	model.Parent = self.root
	plot.model = model
	plot.sig = nil
	plot.sedeLevel, plot.sedeModel = nil, nil
	self:plotPart(i, "Piso", Vector3.new(PLOT_W, 0.4, PLOT_D), CFrame.new(0, 0.2, 0), Color3.fromHex("#1D2029"))
	local free = self:plotPart(i, "Libre", Vector3.new(16, 0.2, 6), CFrame.new(0, 0.5, PLOT_D / 2 - 6), Color3.fromHex("#292D38"))
	label(free, "Garaje libre", UDim2.fromOffset(160, 36), Vector3.new(0, 3, 0), C.mut)
end

-- Construye el garaje del dueño. Devuelve el índice de parcela o nil si no hay lugar.
function Garage:assign(player: Player, g: any): number?
	local company = g.company
	local existing = self.byPlayer[player]
	if existing then
		self:refreshSign(existing, company)
		return existing
	end
	local index = nil
	for i, plot in self.plots do
		if plot.owner == nil then
			index = i
			break
		end
	end
	if not index then
		return nil
	end
	local plot = self.plots[index]
	plot.owner = player
	self.byPlayer[player] = index
	self:buildPlot(index, company)
	return index
end

function Garage:release(player: Player)
	local i = self.byPlayer[player]
	if not i then
		return
	end
	self.byPlayer[player] = nil
	self.plots[i].owner = nil
	self:buildEmptyPlot(i)
end

function Garage:prompt(parent: Instance, action: string, object: string, screen: string, index: number)
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = action
	pp.ObjectText = object
	pp.HoldDuration = 0
	pp.MaxActivationDistance = 14
	pp.RequiresLineOfSight = false
	pp.KeyboardKeyCode = Enum.KeyCode.E
	-- La indicación se dibuja en el cliente con el aspecto de la V3 (WorldPrompts).
	pp.Style = Enum.ProximityPromptStyle.Custom
	pp:SetAttribute("CarEmpire", true)
	local owner = self.plots[index].owner
	if owner then
		pp:SetAttribute("OwnerId", owner.UserId)
	end
	pp.Triggered:Connect(function(who: Player)
		self.onPrompt(who, self.plots[index].owner, screen)
	end)
	pp.Parent = parent
end

function Garage:buildPlot(i: number, company: any)
	local plot = self.plots[i]
	if plot.model then
		plot.model:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = "Garaje" .. i
	model.Parent = self.root
	plot.model = model
	plot.sig = nil
	plot.sedeLevel, plot.sedeModel = nil, nil
	local brand = Color3.fromHex(company.color)

	self:plotPart(i, "Piso", Vector3.new(PLOT_W, 0.4, PLOT_D), CFrame.new(0, 0.2, 0), C.floor, { Material = Enum.Material.Concrete })
	self:plotPart(i, "ParedFondo", Vector3.new(PLOT_W, 18, 1), CFrame.new(0, 9, -PLOT_D / 2), C.wall)
	self:plotPart(i, "ParedIzq", Vector3.new(1, 18, PLOT_D), CFrame.new(-PLOT_W / 2, 9, 0), C.wall)
	self:plotPart(i, "ParedDer", Vector3.new(1, 18, PLOT_D), CFrame.new(PLOT_W / 2, 9, 0), C.wall)
	-- Franja de luz con el color de la marca.
	self:plotPart(i, "FranjaMarca", Vector3.new(PLOT_W - 2, 0.4, 0.3), CFrame.new(0, 16.5, -PLOT_D / 2 + 0.7), brand, { Material = Enum.Material.Neon })
	local sign = self:plotPart(i, "Cartel", Vector3.new(34, 6, 0.4), CFrame.new(0, 12, -PLOT_D / 2 + 0.75), C.dark)
	plot.sign = sign
	self:refreshSign(i, company)

	-- Escritorio de diseño
	local desk = self:plotPart(i, "EscritorioDiseno", Vector3.new(10, 3, 4), CFrame.new(-30, 1.9, -24), Color3.fromHex("#171A21"))
	self:plotPart(i, "Monitor", Vector3.new(6, 3.4, 0.3), CFrame.new(-30, 5.2, -25.4), C.dark)
	self:plotPart(i, "Pantalla", Vector3.new(5.6, 3, 0.1), CFrame.new(-30, 5.2, -25.2), C.vi, { Material = Enum.Material.Neon, Transparency = 0.2 })
	label(desk, "✎  Escritorio de diseño", UDim2.fromOffset(220, 38), Vector3.new(0, 7, 0), Color3.fromHex("#B3AAFF"))
	self:prompt(desk, "Diseñar", "Escritorio de diseño", "editor", i)

	-- Línea de producción
	local belt = self:plotPart(i, "LineaProduccion", Vector3.new(30, 1.2, 9), CFrame.new(2, 1, -20), Color3.fromHex("#20242E"))
	for k = -2, 2 do
		self:plotPart(i, "Rodillo", Vector3.new(0.4, 0.2, 8.6), CFrame.new(2 + k * 6, 1.7, -20), Color3.fromHex("#3A4152"))
	end
	self:plotPart(i, "Portico", Vector3.new(1, 10, 1), CFrame.new(-12, 5.4, -25), C.or_)
	self:plotPart(i, "Portico", Vector3.new(1, 10, 1), CFrame.new(16, 5.4, -25), C.or_)
	self:plotPart(i, "Portico", Vector3.new(29, 1, 1), CFrame.new(2, 10.4, -25), C.or_)
	plot.lineLabel = label(belt, "🏭  Línea 1 · libre", UDim2.fromOffset(300, 40), Vector3.new(0, 11, 0), C.or_)
	self:prompt(belt, "Ver producción", "Fábrica", "fabrica", i)

	-- Almacén: 6 lugares marcados (2 filas × 3)
	local wh = self:plotPart(i, "Almacen", Vector3.new(26, 0.1, 32), CFrame.new(30, 0.45, 2), Color3.fromHex("#23262F"))
	for r = 0, 1 do
		for c = 0, 2 do
			local x = 22 + r * 16
			local z = -10 + c * 12
			self:plotPart(i, "LineaPlaza", Vector3.new(9, 0.12, 0.3), CFrame.new(x, 0.52, z - 5.5), C.line, { Material = Enum.Material.Neon })
		end
	end
	label(wh, "🚗  Stock terminado", UDim2.fromOffset(160, 36), Vector3.new(0, 7, -14), C.bl)
	self:prompt(wh, "Catálogo", "Stock y catálogo", "autos", i)

	-- Concesionario: dos plataformas al frente
	local show = self:plotPart(i, "Concesionario", Vector3.new(44, 0.3, 18), CFrame.new(-8, 0.5, 22), Color3.fromHex("#0C0E13"), { Material = Enum.Material.Glass })
	for k = 0, 1 do
		self:plotPart(i, "Plataforma", Vector3.new(1, 15, 15), CFrame.new(-19 + k * 22, 0.9, 22) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromHex("#292D38"), { Shape = Enum.PartType.Cylinder })
	end
	label(show, "🏷  Concesionario", UDim2.fromOffset(200, 38), Vector3.new(0, 9, 0), C.gr)
	self:prompt(show, "Ventas", "Concesionario", "ventas", i)

	local dynamic = Instance.new("Folder")
	dynamic.Name = "Dinamico"
	dynamic.Parent = model
	plot.dynamic = dynamic
end

function Garage:refreshSign(i: number, company: any)
	local plot = self.plots[i]
	local sign = plot.sign
	if not sign then
		return
	end
	sign:ClearAllChildren()
	local sg = Instance.new("SurfaceGui")
	-- La cara «Back» de la pieza mira hacia el interior del garaje (+Z local de la parcela).
	sg.Face = Enum.NormalId.Back
	sg.PixelsPerStud = 25
	sg.LightInfluence = 0
	sg.Parent = sign
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = C.dark
	frame.Parent = sg
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromHex(company.color)
	stroke.Thickness = 10
	stroke.Parent = frame
	local t = Instance.new("TextLabel")
	t.Size = UDim2.new(1, -40, 1, -30)
	t.Position = UDim2.fromOffset(20, 15)
	t.BackgroundTransparency = 1
	t.TextColor3 = C.tx
	t.TextScaled = true
	t.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Heavy)
	t.Text = string.upper(company.name)
	t.Parent = frame
end

function Garage:teleport(player: Player)
	local i = self.byPlayer[player]
	local char = player.Character
	if not i or not char then
		return
	end
	local cf = self.plots[i].cf * CFrame.new(0, 4, PLOT_D / 2 - 4) * CFrame.Angles(0, 0, 0)
	char:PivotTo(CFrame.lookAt(cf.Position, (self.plots[i].cf * CFrame.new(0, 4, 0)).Position))
end

-- Solo cambia si cambia qué modelos se fabrican o venden (no por cada unidad: con lotes de miles de autos
-- la escena muestra un auto representativo por modelo, nunca un objeto por unidad).
local function signature(g: any): string
	local parts = { g.company.name, g.company.color }
	for _, l in g.lots do
		table.insert(parts, l.id .. (Rules.lotAvailable(l) > 0 and "s" or "-") .. (Rules.lotProducing(l) and "p" or "-"))
	end
	return table.concat(parts, "|")
end

-- Refleja el estado de la partida en el garaje. Reconstruye lo dinámico solo si cambió.
--[[ Fase 3D futura: cada sede puede tener su edificio en ServerStorage.CarEmpireAssets.Sedes.<asset>
	(Catalog.SEDES[n].asset), ubicado con su PrimaryPart en el centro de la parcela. Si no existe, la
	parcela conserva el edificio provisional; la sede cambia igual sus beneficios. Ver docs/FASE-3D.md. ]]
function Garage:applySedeModel(i: number, sedeLevel: number)
	local plot = self.plots[i]
	if plot.sedeLevel == sedeLevel then
		return
	end
	plot.sedeLevel = sedeLevel
	if plot.sedeModel then
		plot.sedeModel:Destroy()
		plot.sedeModel = nil
	end
	local def = Catalog.SEDES[sedeLevel]
	local ok, asset = pcall(function()
		local folder = game:GetService("ServerStorage"):FindFirstChild("CarEmpireAssets")
		local sedes = folder and folder:FindFirstChild("Sedes")
		return sedes and def and def.asset and sedes:FindFirstChild(def.asset)
	end)
	if ok and asset and asset:IsA("Model") and plot.model then
		local m = (asset :: Model):Clone()
		m:PivotTo(plot.cf)
		m.Parent = plot.model
		plot.sedeModel = m
	end
end

function Garage:update(player: Player, g: any, refreshSign: boolean?)
	local i = self.byPlayer[player]
	if not i then
		return
	end
	local plot = self.plots[i]
	self:applySedeModel(i, g.sede or 1)
	if refreshSign then
		self:refreshSign(i, g.company)
	end
	if not plot.dynamic then
		return
	end
	local producing = Rules.producingLots(g)
	local current = producing[1]
	-- Texto de la línea (se actualiza cada segundo).
	if plot.lineLabel then
		if current then
			plot.lineLabel.Text = string.format("🏭  %s · %s de %s%s", current.design.name, Util.num(current.produced), Util.num(current.qty), current.prodState == "sin fondos" and " · sin fondos" or (" · " .. Util.num(Rules.lineRate(g), 1) .. "/min"))
		else
			plot.lineLabel.Text = "🏭  Fábrica libre · lanzá un lote"
		end
	end

	local sig = signature(g)
	if sig == plot.sig then
		return
	end
	plot.sig = sig
	plot.dynamic:ClearAllChildren()

	-- Cada auto es una copia (clon de la plantilla 3D o modelo provisional); la carpeta se vacía antes de
	-- reconstruir, así que nunca hay más de 9 autos por parcela (1 en la línea, 6 en stock y 2 en el salón).
	local function place(spec: any, localCf: CFrame, ghost: boolean?): Model
		local car = CarModel.build(spec, { ghost = ghost })
		car:PivotTo(plot.cf * localCf)
		car.Parent = plot.dynamic
		return car
	end

	if current then
		place(current.design.spec, CFrame.new(2, 1.6, -20) * CFrame.Angles(0, math.pi / 2, 0), true)
	end
	-- Stock: un auto representativo por modelo con unidades terminadas (máximo 6).
	local slot = 0
	local selling = {}
	for _, l in g.lots do
		if Rules.lotAvailable(l) > 0 then
			table.insert(selling, l)
			if slot < 6 then
				local r, c = slot // 3, slot % 3
				-- Filas a 18 studs: entran autos de hasta 18 de largo (el Pioneer 70 mide 17,5 con paragolpes).
				local car = place(l.design.spec, CFrame.new(21 + r * 18, 0.5, -10 + c * 12) * CFrame.Angles(0, math.pi / 2, 0))
				label(car.PrimaryPart :: BasePart, l.design.name .. " · en stock", UDim2.fromOffset(200, 30), Vector3.new(0, 5, 0), C.bl)
				slot += 1
			end
		end
	end
	-- Concesionario: los dos modelos en venta más recientes.
	for spot = 0, math.min(2, #selling) - 1 do
		local l = selling[#selling - spot]
		local car = place(l.design.spec, CFrame.new(-19 + spot * 22, 1.4, 22) * CFrame.Angles(0, math.rad(200), 0))
		label(car.PrimaryPart :: BasePart, l.design.name .. " · " .. Util.money(l.price), UDim2.fromOffset(220, 32), Vector3.new(0, 6, 0), C.gr)
	end
end

return Garage
