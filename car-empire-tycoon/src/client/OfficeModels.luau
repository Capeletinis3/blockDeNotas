--!strict
--[[ Modelos de muebles para el editor de oficinas (cliente).
	- Si existe ReplicatedStorage.CarEmpireAssets.Muebles.<item.model> (un Model), se usa una copia: así los
	  modelos definitivos reemplazan a los provisionales sin tocar compras, inventario ni colocación.
	- Si no, se arma una representación provisional con Parts y las medidas del catálogo (item.size =
	  ancho X, alto, largo Z en studs).
	Convención (también para los modelos definitivos): PrimaryPart = «Base», invisible, centrada en planta y a
	ras del piso; frente hacia −Z; ancho sobre X (item.cells[1]) y largo sobre Z (item.cells[2]). ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local OfficeModels = {}

local WOOD = Color3.fromHex("#8A5A36")
local WOOD_DARK = Color3.fromHex("#5C3B24")
local METAL = Color3.fromHex("#8C96A3")
local METAL_DARK = Color3.fromHex("#4A5361")
local FABRIC = Color3.fromHex("#3E5C8A")
local LEATHER = Color3.fromHex("#5A2E22")
local BEIGE = Color3.fromHex("#D9CBA8")

local function part(model: Model, name: string, size: Vector3, pos: Vector3, color: Color3, props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CastShadow = true
	p.Size = size
	p.CFrame = CFrame.new(pos)
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props then
		for k, v in props do
			(p :: any)[k] = v
		end
	end
	p.Parent = model
	return p
end

-- Constructores provisionales: (modelo, ancho, alto, largo). Coordenadas relativas al centro del piso.
local BUILDERS: { [string]: (Model, number, number, number) -> () } = {}

BUILDERS.escritorio_metal_1970 = function(m, w, h, l)
	part(m, "Tapa", Vector3.new(w, 0.2, l), Vector3.new(0, h - 0.1, 0), METAL)
	part(m, "Cajonera", Vector3.new(w * 0.32, h - 0.25, l * 0.9), Vector3.new(w * 0.32, (h - 0.25) / 2, 0), METAL_DARK)
	-- Dos patas del lado opuesto a la cajonera.
	for _, z in { -l / 2 + 0.15, l / 2 - 0.15 } do
		part(m, "Pata", Vector3.new(0.18, h - 0.2, 0.18), Vector3.new(-w / 2 + 0.15, (h - 0.2) / 2, z), METAL_DARK)
	end
end

BUILDERS.silla_oficina_1970 = function(m, w, h, l)
	part(m, "Pie", Vector3.new(0.25, h * 0.4, 0.25), Vector3.new(0, h * 0.2, 0), METAL_DARK)
	part(m, "Estrella", Vector3.new(w * 0.8, 0.12, 0.2), Vector3.new(0, 0.1, 0), METAL_DARK)
	part(m, "Estrella", Vector3.new(0.2, 0.12, l * 0.8), Vector3.new(0, 0.1, 0), METAL_DARK)
	part(m, "Asiento", Vector3.new(w * 0.85, 0.3, l * 0.85), Vector3.new(0, h * 0.45, 0), FABRIC)
	part(m, "Respaldo", Vector3.new(w * 0.85, h * 0.45, 0.25), Vector3.new(0, h * 0.75, l * 0.4), FABRIC)
end

BUILDERS.sofa_cuero_1970 = function(m, w, h, l)
	part(m, "Base", Vector3.new(w, h * 0.35, l), Vector3.new(0, h * 0.175, 0), LEATHER)
	part(m, "Respaldo", Vector3.new(w, h * 0.65, l * 0.25), Vector3.new(0, h * 0.5, l * 0.375), LEATHER)
	for _, x in { -w / 2 + 0.25, w / 2 - 0.25 } do
		part(m, "Brazo", Vector3.new(0.5, h * 0.55, l), Vector3.new(x, h * 0.275, 0), LEATHER)
	end
	part(m, "Almohadon", Vector3.new(w - 1.1, 0.25, l * 0.65), Vector3.new(0, h * 0.4, -l * 0.08), Color3.fromHex("#6E3A2B"))
end

BUILDERS.maquina_escribir_1970 = function(m, w, h, l)
	part(m, "Cuerpo", Vector3.new(w, h * 0.55, l), Vector3.new(0, h * 0.275, 0), Color3.fromHex("#2F6E62"))
	part(m, "Rodillo", Vector3.new(w, 0.22, 0.22), Vector3.new(0, h * 0.62, l * 0.3), METAL_DARK)
	part(m, "Hoja", Vector3.new(w * 0.6, h * 0.4, 0.04), Vector3.new(0, h * 0.78, l * 0.32), Color3.fromHex("#F4F1E8"))
	part(m, "Teclado", Vector3.new(w * 0.85, 0.1, l * 0.4), Vector3.new(0, h * 0.58, -l * 0.25), Color3.fromHex("#1F2A2A"))
end

BUILDERS.estanteria_madera_1970 = function(m, w, h, l)
	for _, x in { -w / 2 + 0.1, w / 2 - 0.1 } do
		part(m, "Lateral", Vector3.new(0.2, h, l), Vector3.new(x, h / 2, 0), WOOD_DARK)
	end
	part(m, "Fondo", Vector3.new(w, h, 0.1), Vector3.new(0, h / 2, l / 2 - 0.05), WOOD_DARK)
	for i = 0, 3 do
		part(m, "Estante", Vector3.new(w - 0.3, 0.15, l), Vector3.new(0, 0.1 + i * (h - 0.2) / 3, 0), WOOD)
	end
	for i = 0, 2 do
		part(m, "Carpetas", Vector3.new(w * 0.7, (h / 3) * 0.6, l * 0.7), Vector3.new(0, 0.2 + i * (h - 0.2) / 3 + (h / 3) * 0.3, 0), (i % 2 == 0) and Color3.fromHex("#B34A3C") or Color3.fromHex("#3C6EB3"))
	end
end

BUILDERS.mesa_reuniones_1970 = function(m, w, h, l)
	part(m, "Tapa", Vector3.new(w, 0.25, l), Vector3.new(0, h - 0.125, 0), WOOD)
	for _, x in { -w * 0.3, w * 0.3 } do
		part(m, "Pedestal", Vector3.new(0.5, h - 0.25, l * 0.5), Vector3.new(x, (h - 0.25) / 2, 0), WOOD_DARK)
	end
end

BUILDERS.lampara_pie_1970 = function(m, w, h, l)
	part(m, "Base", Vector3.new(w * 0.8, 0.15, l * 0.8), Vector3.new(0, 0.075, 0), METAL_DARK)
	part(m, "Varilla", Vector3.new(0.12, h * 0.8, 0.12), Vector3.new(0, h * 0.4, 0), METAL)
	local shade = part(m, "Pantalla", Vector3.new(w, h * 0.22, l), Vector3.new(0, h * 0.86, 0), BEIGE, { Material = Enum.Material.Fabric })
	local light = Instance.new("PointLight")
	light.Brightness = 0.8
	light.Range = 10
	light.Color = Color3.fromHex("#FFD9A0")
	light.Parent = shade
end

BUILDERS.planta_interior_1970 = function(m, w, h, l)
	part(m, "Maceta", Vector3.new(w * 0.7, h * 0.3, l * 0.7), Vector3.new(0, h * 0.15, 0), Color3.fromHex("#A65A3A"))
	local stemTop = h - math.min(w, l) + 0.1
	part(m, "Tallo", Vector3.new(0.15, stemTop - h * 0.3, 0.15), Vector3.new(0, (h * 0.3 + stemTop) / 2, 0), Color3.fromHex("#4E6B2E"))
	-- Una esfera en Roblox siempre es uniforme: se usa el lado menor para no salirse de la casilla.
	local r = math.min(w, l)
	part(m, "Follaje", Vector3.new(r, r, r), Vector3.new(0, h - r / 2, 0), Color3.fromHex("#3F8A4A"), { Shape = Enum.PartType.Ball, Material = Enum.Material.Grass })
end

-- Modelo definitivo si existe en los assets (sin scripts), o nil.
local function asset(item: any): Model?
	local ok, m = pcall(function()
		local root = ReplicatedStorage:FindFirstChild("CarEmpireAssets")
		local folder = root and root:FindFirstChild("Muebles")
		return folder and folder:FindFirstChild(item.model)
	end)
	if ok and m and (m :: Instance):IsA("Model") then
		local copy = (m :: Model):Clone()
		for _, d in copy:GetDescendants() do
			if d:IsA("LuaSourceContainer") then
				d:Destroy()
			elseif d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanTouch = false
			end
		end
		return copy
	end
	return nil
end

-- Arma el modelo de un mueble con su «Base» en el origen (luego se ubica con PivotTo).
function OfficeModels.build(item: any): Model
	local fromAsset = asset(item)
	if fromAsset then
		fromAsset.Name = item.id
		return fromAsset
	end
	local m = Instance.new("Model")
	m.Name = item.id
	local w, h, l = item.size[1], item.size[2], item.size[3]
	local base = part(m, "Base", Vector3.new(w, 0.05, l), Vector3.new(0, 0.025, 0), Color3.new(0, 0, 0), { Transparency = 1, CastShadow = false })
	m.PrimaryPart = base
	local builder = BUILDERS[item.id]
	if builder then
		builder(m, w, h, l)
	else
		part(m, "Caja", Vector3.new(w, h, l), Vector3.new(0, h / 2, 0), METAL)
	end
	m:SetAttribute("provisional", true)
	return m
end

return OfficeModels
