--!strict
--[[
	Modelo provisional de un vehículo hecho con piezas básicas (Parts).
	Lo usan el editor (vista previa en un ViewportFrame) y el garaje del servidor.
	Refleja: tipo de base (proporciones), pintura principal y secundaria, acabado,
	tamaño y color de llantas, pinzas de freno y alerón. Los modelos definitivos llegan después.
	Orientación: el frente del auto mira hacia -Z; el pivote queda a ras del suelo.
]]

local Catalog = require(script.Parent.Catalog)

local CarModel = {}

-- Proporciones por tipo: largo, ancho, alto de carrocería, alto de cabina, despeje.
local SHAPES = {
	compacto = { L = 12, W = 6.0, H = 2.1, C = 2.0, clear = 0.5, cabin = 0.52, cabinZ = 0.6 },
	sedan = { L = 14, W = 6.2, H = 2.0, C = 1.9, clear = 0.5, cabin = 0.48, cabinZ = 0.4 },
	deportivo = { L = 14, W = 6.4, H = 1.7, C = 1.5, clear = 0.35, cabin = 0.40, cabinZ = 0.8 },
	superdeportivo = { L = 14.5, W = 6.6, H = 1.5, C = 1.3, clear = 0.3, cabin = 0.34, cabinZ = 0.6 },
	suv = { L = 15, W = 7.0, H = 2.8, C = 2.3, clear = 1.1, cabin = 0.62, cabinZ = 1.0 },
	pickup = { L = 16, W = 7.0, H = 2.7, C = 2.2, clear = 1.2, cabin = 0.34, cabinZ = -2.4 },
	clasico = { L = 14, W = 6.2, H = 2.0, C = 1.8, clear = 0.6, cabin = 0.42, cabinZ = 0.8 },
	electrico = { L = 13.5, W = 6.4, H = 1.9, C = 1.8, clear = 0.5, cabin = 0.55, cabinZ = 0.2 },
}

local FINISH_LOOK = {
	["Mate"] = { material = Enum.Material.SmoothPlastic, reflect = 0 },
	["Metálico"] = { material = Enum.Material.SmoothPlastic, reflect = 0.12 },
	["Perlado"] = { material = Enum.Material.SmoothPlastic, reflect = 0.22 },
	["Cromado"] = { material = Enum.Material.Foil, reflect = 0.35 },
}

local function color(hex: string?, fallback: string): Color3
	local ok, c = pcall(Color3.fromHex, hex or fallback)
	if ok then
		return c
	end
	return Color3.fromHex(fallback)
end

local function scaleColor(c: Color3, k: number): Color3
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end

local function part(model: Model, name: string, size: Vector3, cf: CFrame, props: { [string]: any }?): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	p.Size = size
	p.CFrame = cf
	if props then
		for k, v in props do
			(p :: any)[k] = v
		end
	end
	p.Parent = model
	return p
end

--[[
	spec: diseño (campos baseId, paint, wheels, caliper, spoiler).
	opts.ghost = true dibuja la unidad semitransparente (unidad en fabricación).
]]
function CarModel.build(spec: any, opts: { ghost: boolean? }?): Model
	local base = Catalog.base(spec.baseId) or Catalog.BASES[1]
	local s = SHAPES[base.type] or SHAPES.sedan
	local ghost = opts and opts.ghost or false
	local model = Instance.new("Model")
	model.Name = "Auto"

	local paint = spec.paint or {}
	local look = FINISH_LOOK[paint.finish] or FINISH_LOOK["Metálico"]
	local intensity = (tonumber(paint.intensity) or 100) / 100
	local primary = scaleColor(color(paint.primary, "#C0C6D0"), intensity)
	local secondary = color(paint.secondary, "#15171C")
	local wheels = spec.wheels or {}
	local wheelSize = tonumber(wheels.size) or 18
	local tireD = 2.3 + (wheelSize - 18) * 0.14
	local tireW = 1.2
	local rimColor = color(wheels.rim, "#C9CED8")
	local caliper = color(spec.caliper, "#5D6371")
	local transp = ghost and 0.55 or 0

	local bodyY = s.clear + tireD * 0.45 + s.H / 2
	local body = part(model, "Carroceria", Vector3.new(s.W, s.H, s.L), CFrame.new(0, bodyY, 0), {
		Color = primary,
		Material = look.material,
		Reflectance = look.reflect,
		Transparency = transp,
	})
	-- Capó levemente más bajo al frente para dar forma.
	part(model, "Capo", Vector3.new(s.W * 0.96, 0.25, s.L * 0.3), CFrame.new(0, bodyY + s.H / 2 + 0.05, -s.L * 0.33), {
		Color = scaleColor(primary, 0.92),
		Material = look.material,
		Reflectance = look.reflect,
		Transparency = transp,
	})
	-- Cabina en el color secundario (techo y pilares) con vidrios oscuros.
	local cabinL = s.L * s.cabin
	local cabinY = bodyY + s.H / 2 + s.C / 2
	local cabin = part(model, "Cabina", Vector3.new(s.W * 0.86, s.C, cabinL), CFrame.new(0, cabinY, s.cabinZ), {
		Color = secondary,
		Transparency = transp,
	})
	local glass = { Color = Color3.fromHex("#0B0F18"), Material = Enum.Material.Glass, Transparency = ghost and 0.7 or 0.25, Reflectance = 0.1 }
	part(model, "Parabrisas", Vector3.new(s.W * 0.8, s.C * 0.78, 0.15), cabin.CFrame * CFrame.new(0, 0, -cabinL / 2 - 0.05), glass)
	part(model, "Luneta", Vector3.new(s.W * 0.8, s.C * 0.7, 0.15), cabin.CFrame * CFrame.new(0, 0, cabinL / 2 + 0.05), glass)
	for _, side in { -1, 1 } do
		part(model, "Ventana", Vector3.new(0.15, s.C * 0.65, cabinL * 0.86), cabin.CFrame * CFrame.new(side * (s.W * 0.43 + 0.05), 0, 0), glass)
	end
	if base.type == "pickup" then
		-- Caja de carga abierta.
		part(model, "Caja", Vector3.new(s.W * 0.9, 0.6, s.L * 0.36), CFrame.new(0, bodyY + s.H / 2 + 0.3, s.L * 0.28), { Color = secondary, Transparency = transp })
	end

	-- Faros y luces traseras.
	local lightY = bodyY + s.H * 0.15
	for _, side in { -1, 1 } do
		part(model, "Faro", Vector3.new(s.W * 0.22, 0.45, 0.2), CFrame.new(side * s.W * 0.32, lightY, -s.L / 2 - 0.05), {
			Color = Color3.fromHex("#F5F7FA"),
			Material = Enum.Material.Neon,
			Transparency = transp,
		})
		part(model, "LuzTrasera", Vector3.new(s.W * 0.22, 0.4, 0.2), CFrame.new(side * s.W * 0.32, lightY, s.L / 2 + 0.05), {
			Color = Color3.fromHex("#D6333F"),
			Material = Enum.Material.Neon,
			Transparency = transp,
		})
	end

	-- Ruedas: neumático + llanta + pinza de freno.
	local axleY = tireD / 2
	local axles = { -s.L * 0.32, s.L * 0.32 }
	for _, z in axles do
		for _, side in { -1, 1 } do
			local x = side * (s.W / 2 - tireW * 0.35)
			local cf = CFrame.new(x, axleY, z)
			part(model, "Neumatico", Vector3.new(tireW, tireD, tireD), cf, {
				Shape = Enum.PartType.Cylinder,
				Color = Color3.fromHex("#15171C"),
				Transparency = transp,
			})
			part(model, "Llanta", Vector3.new(tireW + 0.05, tireD * 0.62, tireD * 0.62), cf, {
				Shape = Enum.PartType.Cylinder,
				Color = rimColor,
				Material = Enum.Material.SmoothPlastic,
				Reflectance = 0.25,
				Transparency = transp,
			})
			part(model, "Pinza", Vector3.new(0.3, tireD * 0.22, tireD * 0.3), cf * CFrame.new(side * -0.25, tireD * 0.18, 0), {
				Color = caliper,
				Transparency = transp,
			})
		end
	end

	if spec.spoiler then
		local wingY = bodyY + s.H / 2 + 1.0
		local wingZ = s.L / 2 - 0.9
		part(model, "Aleron", Vector3.new(s.W * 0.92, 0.18, 1.3), CFrame.new(0, wingY, wingZ), {
			Color = secondary,
			Transparency = transp,
		})
		for _, side in { -1, 1 } do
			part(model, "SoporteAleron", Vector3.new(0.2, 0.9, 0.3), CFrame.new(side * s.W * 0.3, wingY - 0.5, wingZ), {
				Color = secondary,
				Transparency = transp,
			})
		end
	end

	model.PrimaryPart = body
	model.WorldPivot = CFrame.new(0, 0, 0)
	return model
end

-- Radio aproximado para encuadrar la cámara de una vista previa.
function CarModel.extent(spec: any): number
	local base = Catalog.base(spec.baseId) or Catalog.BASES[1]
	local s = SHAPES[base.type] or SHAPES.sedan
	return s.L / 2 + 1
end

return CarModel
