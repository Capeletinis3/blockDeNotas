--!strict
--[[
	Modelo PROVISIONAL de un vehículo hecho con piezas básicas (Parts anclados, no conducible).
	Lo usan el editor (vista 3D y miniaturas) y el garaje. Refleja todas las opciones visuales del diseño:
	carrocería por tipo, pintura principal/secundaria con intensidad y brillo, acabado, llantas (tamaño,
	estilo, color), pinzas, alerón, paragolpes, capó, difusor, faldones, faros, polarizado, vinilos, número,
	emblema, matrícula e interior (asientos, tapizado, volante, tablero, iluminación).
	Orientación: el frente mira hacia −Z; el pivote queda a ras del suelo.
	Si el diseño usa una carrocería 3D definitiva (Catalog.VEHICLE_MODELS, por ejemplo el Pioneer 70), se
	devuelve un clon de ese modelo pintado con el color del diseño (CarModel.fromVehicleModel).
]]

local Catalog = require(script.Parent.Catalog)

local CarModel = {}

-- Proporciones por tipo: largo, ancho, alto de carrocería, alto de cabina, despeje, largo relativo de cabina, desplazamiento.
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
CarModel.SHAPES = SHAPES

local FINISH_LOOK = {
	["Mate"] = { material = Enum.Material.SmoothPlastic, reflect = 0 },
	["Metálico"] = { material = Enum.Material.SmoothPlastic, reflect = 0.12 },
	["Perlado"] = { material = Enum.Material.SmoothPlastic, reflect = 0.22 },
	["Cromado"] = { material = Enum.Material.Foil, reflect = 0.35 },
}
local LIGHTS = { white = "#F5F7FA", amber = "#FFC46B", blue = "#9FD8FF" }
local TINT = { clear = 0.55, t30 = 0.3, t70 = 0.08 }
local AMBIENT = { violet = "#7667FF", white = "#FFE2B8", cyan = "#6FE3F0" }

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

local function surfaceText(p: BasePart, face: Enum.NormalId, text: string, fg: Color3, bg: Color3?)
	local sg = Instance.new("SurfaceGui")
	sg.Face = face
	sg.PixelsPerStud = 40
	sg.LightInfluence = 0.4
	sg.Parent = p
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = bg and 0 or 1
	if bg then
		t.BackgroundColor3 = bg
	end
	t.TextColor3 = fg
	t.TextScaled = true
	t.Text = text
	t.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Heavy)
	t.Parent = sg
end

--[[
	spec: diseño. opts.ghost = semitransparente (unidad en fabricación); opts.brandColor = color del emblema.
	Devuelve el Model. model:GetAttribute("length"|"height"|"width") da las dimensiones reales para encuadrar.
]]
--[[ Fase 3D futura: CarModel.assetResolver(baseId) puede devolver un Model definitivo para esa base (lo
	configuran Main.server y Main.client buscando ReplicatedStorage.CarEmpireAssets.Cars.<baseId>; el frente
	hacia −Z y el pivote a ras del suelo). Las piezas con el atributo «Pintura» = "primaria" o "secundaria"
	toman los colores del diseño. Sin recursos se usa el modelo provisional. Ver docs/FASE-3D.md. ]]
CarModel.assetResolver = nil :: ((string) -> Model?)?

function CarModel.fromAssets(spec: any): Model?
	local resolver = CarModel.assetResolver
	if not resolver then
		return nil
	end
	local ok, found = pcall(resolver, tostring(spec.baseId))
	if not ok or not found then
		return nil
	end
	local m = (found :: Model):Clone()
	local paint = spec.paint or {}
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			local role = d:GetAttribute("Pintura")
			if role == "primaria" and paint.primary then
				d.Color = Color3.fromHex(paint.primary)
			elseif role == "secundaria" and paint.secondary then
				d.Color = Color3.fromHex(paint.secondary)
			end
			d.Anchored = true
		end
	end
	return m
end

--[[ Carrocerías 3D definitivas (Catalog.VEHICLE_MODELS). vehicleResolver(asset) devuelve el Model
	original: en el servidor, ServerStorage.VehicleModels.<asset>; en el cliente, la copia que publica el
	servidor en ReplicatedStorage.CarEmpireAssets.VehicleModels (ver Main.server y Main.client).
	El original nunca se modifica. Se prepara UNA plantilla por modelo (sin scripts, piezas ancladas, sin
	colisión ni consultas, pivote en el centro a ras del suelo con el frente hacia −Z) y cada auto que se
	muestra es un clon de la plantilla: conserva geometría, materiales y piezas. ]]
CarModel.vehicleResolver = nil :: ((string) -> Model?)?
local templates: { [string]: any } = {}

-- Caja que ocupan todas las piezas (en coordenadas del mundo, contando la rotación de cada pieza).
local function bounds(m: Instance): (Vector3?, Vector3?)
	local x0, y0, z0, x1, y1, z1 = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			local cf, h = d.CFrame, d.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local w = cf:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
						x0, y0, z0 = math.min(x0, w.X), math.min(y0, w.Y), math.min(z0, w.Z)
						x1, y1, z1 = math.max(x1, w.X), math.max(y1, w.Y), math.max(z1, w.Z)
					end
				end
			end
		end
	end
	if x0 == math.huge then
		return nil, nil
	end
	return Vector3.new(x0, y0, z0), Vector3.new(x1, y1, z1)
end

-- Plantilla preparada de un modelo 3D (o nil si no está cargado). Se rehace solo si cambia el original.
function CarModel.template(asset: string): any
	local resolver = CarModel.vehicleResolver
	if not resolver then
		return nil
	end
	local ok, src = pcall(resolver, asset)
	if not ok or src == nil or typeof(src) ~= "Instance" or not (src :: Instance):IsA("Model") then
		return nil
	end
	local cached = templates[asset]
	if cached and cached.source == src then
		return cached
	end
	local m = (src :: Model):Clone()
	if not m then
		return nil -- Archivable = false en el original
	end
	-- Los scripts del modelo (por ejemplo, pruebas de pintura) no deben correr en cada copia.
	for _, d in m:GetDescendants() do
		if d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	local primary, biggest = nil, -1
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			local v = d.Size.X * d.Size.Y * d.Size.Z
			if v > biggest then
				primary, biggest = d, v
			end
		end
	end
	local lo, hi = bounds(m)
	if not primary or not lo or not hi then
		return nil
	end
	-- Pivote: centro de la planta, a la altura de la pieza más baja (las ruedas apoyan en el suelo).
	m.PrimaryPart = primary
	m.WorldPivot = CFrame.new((lo.X + hi.X) / 2, lo.Y, (lo.Z + hi.Z) / 2)
	m:PivotTo(CFrame.new())
	m.Name = "Auto"
	local size = hi - lo
	m:SetAttribute("length", size.Z)
	m:SetAttribute("width", size.X)
	m:SetAttribute("height", size.Y)
	cached = { source = src, model = m, size = size }
	templates[asset] = cached
	return cached
end

-- Auto con la carrocería 3D del diseño, o nil si el diseño no usa una (o el modelo no está cargado).
-- Pintura: las piezas cuyo nombre termina en paintSuffix («_Paint») toman el color principal con su
-- intensidad; también las que tienen el atributo «Pintura» = "primaria" ("secundaria" toma el segundo
-- color). Neumáticos, cristales, asientos, faros, cromados y el resto conservan su color y material.
function CarModel.fromVehicleModel(spec: any, opts: { ghost: boolean?, brandColor: string? }?): Model?
	local entry = Catalog.resolveVehicleModel(spec)
	if not entry then
		return nil
	end
	local t = CarModel.template(entry.asset)
	if not t then
		return nil
	end
	local m = t.model:Clone()
	local paint = spec.paint or {}
	local primary = scaleColor(color(paint.primary, "#C0C6D0"), (tonumber(paint.intensity) or 100) / 100)
	local secondary = color(paint.secondary, "#15171C")
	local suffix = entry.paintSuffix or "_Paint"
	local ghost = opts and opts.ghost or false
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			local role = d:GetAttribute("Pintura")
			if role == "secundaria" then
				d.Color = secondary
			elseif role == "primaria" or string.sub(d.Name, -#suffix) == suffix then
				d.Color = primary
			end
			if ghost then
				d.Transparency = 1 - (1 - d.Transparency) * 0.45
			end
		end
	end
	m:SetAttribute("vehicleModel", entry.id)
	return m
end

function CarModel.build(spec: any, opts: { ghost: boolean?, brandColor: string? }?): Model
	local custom = CarModel.fromVehicleModel(spec, opts) or CarModel.fromAssets(spec)
	if custom then
		return custom
	end
	local base = Catalog.base(spec.baseId) or Catalog.BASES[1]
	local s = SHAPES[base.type] or SHAPES.sedan
	local ghost = opts and opts.ghost or false
	local model = Instance.new("Model")
	model.Name = "Auto"

	local paint = spec.paint or {}
	local body = spec.body or {}
	local interior = spec.interior or {}
	local look = FINISH_LOOK[paint.finish] or FINISH_LOOK["Metálico"]
	local gloss = (tonumber(paint.gloss) or 60) / 100
	local reflect = look.reflect * (0.4 + gloss)
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
	local paintProps = { Color = primary, Material = look.material, Reflectance = reflect, Transparency = transp }

	local bodyY = s.clear + tireD * 0.45 + s.H / 2
	local mainBody = part(model, "Carroceria", Vector3.new(s.W, s.H, s.L), CFrame.new(0, bodyY, 0), paintProps)
	local top = bodyY + s.H / 2

	-- Capó
	local hoodCf = CFrame.new(0, top + 0.05, -s.L * 0.33)
	if body.hood == "carbon" then
		part(model, "CapoCarbono", Vector3.new(s.W * 0.9, 0.18, s.L * 0.28), hoodCf, { Color = Color3.fromHex("#1A1C21"), Material = Enum.Material.Fabric, Transparency = transp })
	else
		part(model, "Capo", Vector3.new(s.W * 0.96, 0.22, s.L * 0.3), hoodCf, { Color = scaleColor(primary, 0.93), Material = look.material, Reflectance = reflect, Transparency = transp })
		if body.hood == "vent" then
			for _, side in { -1, 1 } do
				part(model, "TomaAire", Vector3.new(s.W * 0.18, 0.18, s.L * 0.1), hoodCf * CFrame.new(side * s.W * 0.2, 0.15, 0), { Color = Color3.fromHex("#0B0F18"), Transparency = transp })
			end
		end
	end

	-- Cabina (color secundario en techo y pilares) con vidrios según el polarizado.
	local cabinL = s.L * s.cabin
	local cabinY = top + s.C / 2
	local cabin = part(model, "Cabina", Vector3.new(s.W * 0.86, s.C, cabinL), CFrame.new(0, cabinY, s.cabinZ), { Color = secondary, Transparency = transp })
	local glass = { Color = Color3.fromHex("#0B0F18"), Material = Enum.Material.Glass, Transparency = ghost and 0.8 or (TINT[body.tint] or 0.3), Reflectance = 0.1 }
	part(model, "Parabrisas", Vector3.new(s.W * 0.8, s.C * 0.78, 0.15), cabin.CFrame * CFrame.new(0, 0, -cabinL / 2 - 0.05), glass)
	part(model, "Luneta", Vector3.new(s.W * 0.8, s.C * 0.7, 0.15), cabin.CFrame * CFrame.new(0, 0, cabinL / 2 + 0.05), glass)
	for _, side in { -1, 1 } do
		part(model, "Ventana", Vector3.new(0.15, s.C * 0.65, cabinL * 0.86), cabin.CFrame * CFrame.new(side * (s.W * 0.43 + 0.05), 0, 0), glass)
	end
	if base.type == "pickup" then
		part(model, "Caja", Vector3.new(s.W * 0.9, 0.6, s.L * 0.36), CFrame.new(0, top + 0.3, s.L * 0.28), { Color = secondary, Transparency = transp })
	end

	-- Interior visible a través de los vidrios (y desde la cámara interior).
	local seatColor = color(interior.color, "#1A1B1F")
	local seatH = interior.seats == "sport" and 1.5 or 1.2
	for _, side in { -1, 1 } do
		part(model, "Asiento", Vector3.new(s.W * 0.26, 0.4, 1.2), CFrame.new(side * s.W * 0.2, top - 0.1, s.cabinZ + 0.3), { Color = seatColor, Transparency = transp })
		part(model, "Respaldo", Vector3.new(s.W * 0.26, seatH, 0.35), CFrame.new(side * s.W * 0.2, top + seatH / 2 - 0.1, s.cabinZ + 0.95), { Color = seatColor, Transparency = transp, Material = interior.material == "cuero" and Enum.Material.Leather or Enum.Material.Fabric })
		if interior.seats == "lux" then
			part(model, "Cabezal", Vector3.new(s.W * 0.18, 0.4, 0.35), CFrame.new(side * s.W * 0.2, top + seatH + 0.15, s.cabinZ + 0.95), { Color = seatColor, Transparency = transp })
		end
	end
	local dashZ = s.cabinZ - cabinL / 2 + 0.5
	part(model, "Tablero", Vector3.new(s.W * 0.8, 0.5, 0.6), CFrame.new(0, top + 0.35, dashZ), { Color = Color3.fromHex("#15171C"), Transparency = transp })
	if interior.dash == "digital" then
		part(model, "PantallaTablero", Vector3.new(s.W * 0.5, 0.3, 0.05), CFrame.new(0, top + 0.55, dashZ + 0.32), { Color = Color3.fromHex("#6FE3F0"), Material = Enum.Material.Neon, Transparency = transp })
	end
	local wheelShape = interior.wheel == "flat" and Vector3.new(0.12, 0.6, 0.8) or Vector3.new(0.12, 0.75, 0.75)
	part(model, "Volante", wheelShape, CFrame.new(-s.W * 0.2, top + 0.6, dashZ + 0.5) * CFrame.Angles(0, math.pi / 2, 0), { Shape = Enum.PartType.Cylinder, Color = Color3.fromHex("#22252E"), Transparency = transp })
	if AMBIENT[interior.ambient] then
		part(model, "LuzAmbiente", Vector3.new(s.W * 0.78, 0.06, 0.06), CFrame.new(0, top + 0.12, dashZ + 0.34), { Color = Color3.fromHex(AMBIENT[interior.ambient]), Material = Enum.Material.Neon, Transparency = transp })
	end

	-- Paragolpes, faldones y difusor
	local bumperColor = body.bumper == "offroad" and Color3.fromHex("#22252E") or scaleColor(primary, 0.85)
	local bumperDepth = body.bumper == "offroad" and 0.8 or 0.45
	part(model, "ParagolpesDel", Vector3.new(s.W * 1.0, s.H * 0.38, bumperDepth), CFrame.new(0, bodyY - s.H * 0.28, -s.L / 2 - bumperDepth / 2 + 0.05), { Color = bumperColor, Transparency = transp })
	part(model, "ParagolpesTras", Vector3.new(s.W * 1.0, s.H * 0.38, 0.45), CFrame.new(0, bodyY - s.H * 0.28, s.L / 2 + 0.2), { Color = scaleColor(primary, 0.85), Transparency = transp })
	if body.bumper == "sport" then
		part(model, "Labio", Vector3.new(s.W * 0.96, 0.12, 0.7), CFrame.new(0, bodyY - s.H / 2 - 0.02, -s.L / 2 - 0.2), { Color = Color3.fromHex("#15171C"), Transparency = transp })
	elseif body.bumper == "offroad" then
		part(model, "Defensa", Vector3.new(s.W * 0.7, 0.25, 0.25), CFrame.new(0, bodyY + 0.1, -s.L / 2 - 0.9), { Color = Color3.fromHex("#3A3F4D"), Material = Enum.Material.Metal, Transparency = transp })
	end
	if body.skirts == "low" then
		for _, side in { -1, 1 } do
			part(model, "Faldon", Vector3.new(0.2, 0.3, s.L * 0.42), CFrame.new(side * (s.W / 2 + 0.05), bodyY - s.H / 2 + 0.1, 0), { Color = secondary, Transparency = transp })
		end
	end
	if body.diffuser == "carbon" then
		part(model, "Difusor", Vector3.new(s.W * 0.7, 0.18, 0.8), CFrame.new(0, bodyY - s.H / 2 - 0.05, s.L / 2 + 0.25), { Color = Color3.fromHex("#1A1C21"), Material = Enum.Material.Fabric, Transparency = transp })
	end

	-- Vinilos, número y emblema
	if body.vinyl == "stripes" then
		for _, x in { -0.5, 0.5 } do
			part(model, "Franja", Vector3.new(0.45, 0.04, s.L * 0.98), CFrame.new(x, top + 0.03, 0), { Color = secondary, Transparency = transp })
		end
	elseif body.vinyl == "side" then
		for _, side in { -1, 1 } do
			part(model, "FranjaLateral", Vector3.new(0.04, 0.35, s.L * 0.82), CFrame.new(side * (s.W / 2 + 0.03), bodyY + 0.1, 0), { Color = secondary, Transparency = transp })
		end
	end
	if body.number == "27" or body.number == "8" then
		for _, side in { -1, 1 } do
			local plate = part(model, "Numero", Vector3.new(0.04, s.H * 0.6, s.H * 0.6), CFrame.new(side * (s.W / 2 + 0.04), bodyY, 0.6), { Color = Color3.fromHex("#F5F7FA"), Transparency = transp })
			surfaceText(plate, side < 0 and Enum.NormalId.Left or Enum.NormalId.Right, body.number, Color3.fromHex("#15171C"))
		end
	end
	if body.logo ~= "off" then
		part(model, "Emblema", Vector3.new(0.5, 0.5, 0.06), CFrame.new(0, bodyY + 0.1, -s.L / 2 - 0.05), { Color = color(opts and opts.brandColor, "#C9CED8"), Material = Enum.Material.Neon, Transparency = transp })
	end
	local plateText = type(body.plate) == "string" and body.plate or "CET 001"
	local plateBack = part(model, "Matricula", Vector3.new(1.6, 0.5, 0.05), CFrame.new(0, bodyY - 0.25, s.L / 2 + 0.44), { Color = Color3.fromHex("#F5F7FA"), Transparency = transp })
	surfaceText(plateBack, Enum.NormalId.Back, plateText, Color3.fromHex("#15171C"))

	-- Faros y luces traseras
	local lightY = bodyY + s.H * 0.15
	local headColor = color(LIGHTS[body.lights] or LIGHTS.white, "#F5F7FA")
	for _, side in { -1, 1 } do
		part(model, "Faro", Vector3.new(s.W * 0.22, 0.45, 0.2), CFrame.new(side * s.W * 0.32, lightY, -s.L / 2 - 0.05), { Color = headColor, Material = Enum.Material.Neon, Transparency = transp })
		part(model, "LuzTrasera", Vector3.new(s.W * 0.22, 0.4, 0.2), CFrame.new(side * s.W * 0.32, lightY, s.L / 2 + 0.05), { Color = Color3.fromHex("#D6333F"), Material = Enum.Material.Neon, Transparency = transp })
	end

	-- Ruedas: neumático + llanta con estilo + pinza de freno.
	local axleY = tireD / 2
	local style = wheels.style or "radial5"
	for _, z in { -s.L * 0.32, s.L * 0.32 } do
		for _, side in { -1, 1 } do
			local x = side * (s.W / 2 - tireW * 0.35)
			local cf = CFrame.new(x, axleY, z)
			part(model, "Neumatico", Vector3.new(tireW, tireD, tireD), cf, { Shape = Enum.PartType.Cylinder, Color = Color3.fromHex("#15171C"), Transparency = transp })
			local rimD = tireD * 0.64
			local face = cf * CFrame.new(side * (tireW / 2 + 0.02), 0, 0)
			if style == "solid" then
				part(model, "LlantaAero", Vector3.new(0.12, rimD, rimD), face, { Shape = Enum.PartType.Cylinder, Color = rimColor, Reflectance = 0.25, Transparency = transp })
			else
				part(model, "Aro", Vector3.new(0.1, rimD, rimD), face, { Shape = Enum.PartType.Cylinder, Color = Color3.fromHex("#2A2E38"), Transparency = transp })
				local spokes = style == "mesh" and 10 or 5
				local thick = style == "mesh" and 0.09 or 0.22
				for i = 1, spokes do
					local a = (i / spokes) * math.pi * 2
					part(model, "Rayo", Vector3.new(0.14, rimD * 0.92, thick), face * CFrame.Angles(a, 0, 0), { Color = rimColor, Reflectance = 0.25, Transparency = transp })
				end
				part(model, "Maza", Vector3.new(0.16, rimD * 0.28, rimD * 0.28), face, { Shape = Enum.PartType.Cylinder, Color = rimColor, Transparency = transp })
			end
			part(model, "Pinza", Vector3.new(0.3, tireD * 0.22, tireD * 0.3), cf * CFrame.new(side * 0.2, tireD * 0.18, 0), { Color = caliper, Transparency = transp })
		end
	end

	if spec.spoiler then
		local wingY = top + 1.0
		local wingZ = s.L / 2 - 0.9
		part(model, "Aleron", Vector3.new(s.W * 0.92, 0.18, 1.3), CFrame.new(0, wingY, wingZ), { Color = secondary, Transparency = transp })
		for _, side in { -1, 1 } do
			part(model, "SoporteAleron", Vector3.new(0.2, 0.9, 0.3), CFrame.new(side * s.W * 0.3, wingY - 0.5, wingZ), { Color = secondary, Transparency = transp })
		end
	end

	model.PrimaryPart = mainBody
	model.WorldPivot = CFrame.new(0, 0, 0)
	model:SetAttribute("length", s.L + 1.6)
	model:SetAttribute("width", s.W + 0.4)
	model:SetAttribute("height", cabinY + s.C / 2 + (spec.spoiler and 0.6 or 0))
	return model
end

-- Dimensiones del bloque que ocupa el auto (para encuadrar la cámara sin cortarlo).
function CarModel.dims(spec: any): Vector3
	local entry = Catalog.resolveVehicleModel(spec)
	local t = entry and CarModel.template(entry.asset)
	if t then
		return t.size + Vector3.new(0.2, 0, 0.2)
	end
	local base = Catalog.base(spec.baseId) or Catalog.BASES[1]
	local s = SHAPES[base.type] or SHAPES.sedan
	local tireD = 2.3 + ((tonumber(spec.wheels and spec.wheels.size) or 18) - 18) * 0.14
	local h = s.clear + tireD * 0.45 + s.H + s.C + (spec.spoiler and 0.6 or 0)
	return Vector3.new(s.W + 0.4, h, s.L + 1.6)
end

function CarModel.extent(spec: any): number
	local d = CarModel.dims(spec)
	return d.Z / 2
end

-- Puntos de identificación de piezas (coordenadas locales) → paso y categoría del editor.
function CarModel.hotspots(spec: any): { any }
	local d = CarModel.dims(spec)
	local base = Catalog.base(spec.baseId) or Catalog.BASES[1]
	local s = SHAPES[base.type] or SHAPES.sedan
	local top = d.Y - s.C
	return {
		{ label = "Motor", step = 2, cat = "motor", pos = Vector3.new(0, top + 0.3, -s.L * 0.33) },
		{ label = "Frenos y ruedas", step = 2, cat = "frenos", pos = Vector3.new(-s.W / 2 - 0.4, 1.2, -s.L * 0.32) },
		{ label = "Suspensión", step = 2, cat = "suspension", pos = Vector3.new(s.W / 2 + 0.4, 1.2, s.L * 0.32) },
		{ label = "Escape", step = 2, cat = "escape", pos = Vector3.new(s.W * 0.25, 0.9, s.L / 2 + 0.6) },
		{ label = "Pintura", step = 3, tab = "ext", pos = Vector3.new(s.W / 2 + 0.2, top - s.H * 0.4, 0) },
		{ label = "Interior", step = 3, tab = "int", pos = Vector3.new(0, top + s.C * 0.5, s.cabinZ) },
		{ label = "Alerón", step = 3, tab = "ext", pos = Vector3.new(0, top + 0.9, s.L / 2 - 0.9) },
	}
end

return CarModel
