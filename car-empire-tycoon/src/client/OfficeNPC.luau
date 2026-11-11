--!strict
--[[ Representación visual de un empleado en el editor de oficinas (cliente, solo local).

	Personaje provisional: un rig sencillo de Parts ancladas y sin colisión (cabeza, torso, brazos, muslos,
	piernas, manos y zapatos) de ~5,3 studs de alto, a escala de los muebles (escritorio de 2,6 studs, asiento
	de silla a 1,5). Vestimenta de oficina de 1970: saco, camisa clara, corbata ancha y pantalón de tonos
	tierra. El aspecto sale de un hash del id del empleado: siempre el mismo para la misma persona, con
	variaciones moderadas (piel, pelo, saco, corbata, pantalón).

	Modelos definitivos: si existe ReplicatedStorage.CarEmpireAssets.Empleados con Models, se usa una copia
	(elegida de forma estable por el id) y se mueve entera con PivotTo; si ese modelo trae Humanoid con Animator
	y una carpeta «Animaciones» con objetos Animation nombrados como las poses (idle, walk, sit, sitwork, work,
	browse, rest, meet, sitmeet), OfficeAnimations los reproduce con AnimationTrack (cargados una sola vez). Sin
	eso, se usa este rig con poses procedurales. Navegación y actividades no cambian en ningún caso.
	No se usan IDs de animación inventados ni assets externos.

	El modelo lleva el atributo employeeId (el id real del empleado) y su nombre visible sobre la cabeza. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)

local NPC = {}

-- Medidas del rig provisional (studs). Las usa OfficeAnimations para ubicar cada pieza.
NPC.DIM = {
	hipH = 2.5, -- altura de la cadera de pie (muslo 1,25 + pierna 1,25)
	thigh = 1.25,
	shin = 1.15,
	torso = 1.75,
	shoulderX = 0.84,
	shoulderY = 1.6,
	hipX = 0.32,
	arm = 1.5,
	labelY = 1.25, -- nombre sobre la cabeza
}

local SKIN = { "#F1C9A5", "#E0AC82", "#C68A5E", "#9C6640", "#6E4529" }
local HAIR = { "#1E1A17", "#3B2A1E", "#5C4030", "#8A5A35", "#C9A26A", "#8E8A86" }
local JACKET = { "#6B4F35", "#3E4A5C", "#7A7468", "#8C6A3F", "#5C6B4A", "#5A3E36" }
local SHIRT = { "#F2EFE6", "#DCE6F0", "#EFE3C8" }
local TIE = { "#B5542A", "#C99A2E", "#6E3B1F", "#7A2631", "#3F5A3A" }
local PANTS = { "#4A3A2C", "#55555A", "#2F3647", "#8A7A5E" }
local SHOES = { "#2A1D15", "#151515" }

local function hash(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 2147483647
	end
	return h
end

local function pick(list: { string }, h: number, salt: number): Color3
	return Color3.fromHex(list[(h // salt) % #list + 1])
end

local function part(model: Model, name: string, size: Vector3, color: Color3, props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = true
	p.CastShadow = true
	p.Size = size
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

-- Aspecto estable de un empleado (mismos colores siempre para el mismo id).
function NPC.look(employeeId: string): any
	local h = hash(employeeId)
	return {
		skin = pick(SKIN, h, 1),
		hair = pick(HAIR, h, 7),
		hairStyle = (h // 41) % 3, -- 0 corto, 1 largo hasta los hombros, 2 muy corto
		jacket = pick(JACKET, h, 13),
		shirt = pick(SHIRT, h, 17),
		tie = pick(TIE, h, 23),
		pants = pick(PANTS, h, 29),
		shoes = pick(SHOES, h, 31),
		height = 0.96 + ((h // 37) % 9) * 0.01, -- 0,96 a 1,04
	}
end

local function deptColor(deptId: any): Color3
	local d = Catalog.department(deptId)
	return Color3.fromHex(d and d.color or "#F5F7FA")
end

-- Nombre visible sobre la cabeza (color del departamento).
local function label(rig: any, adornee: BasePart)
	local bb = Instance.new("BillboardGui")
	bb.Name = "NombreEmpleado"
	bb.Size = UDim2.fromOffset(170, 22)
	bb.StudsOffset = Vector3.new(0, NPC.DIM.labelY, 0)
	bb.LightInfluence = 0
	bb.MaxDistance = 140
	bb.Adornee = adornee
	bb.Parent = adornee
	local t = Instance.new("TextLabel")
	t.Name = "Nombre"
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.TextStrokeTransparency = 0.35
	t.TextSize = 14
	t.Font = Enum.Font.GothamBold
	t.Text = ""
	t.Parent = bb
	rig.label = t
	rig.billboard = bb
end

-- Modelo definitivo opcional (ReplicatedStorage.CarEmpireAssets.Empleados).
local function assetFor(employeeId: string): Model?
	local root = ReplicatedStorage:FindFirstChild("CarEmpireAssets")
	local folder = root and root:FindFirstChild("Empleados")
	if not folder then
		return nil
	end
	local models = {}
	for _, c in folder:GetChildren() do
		if c:IsA("Model") then
			table.insert(models, c)
		end
	end
	if #models == 0 then
		return nil
	end
	table.sort(models, function(a: Instance, b: Instance): boolean
		return a.Name < b.Name
	end)
	return models[hash(employeeId) % #models + 1]
end

--[[ Arma el personaje de un empleado. Devuelve el rig:
	{ model, employeeId, kind = "procedural" | "asset", parts = { torso, head, … } (procedural), look, label,
	  animator? (asset con Animator), anims? (carpeta Animaciones) } ]]
function NPC.build(employeeId: string, name: string, dept: any): any
	local rig = { employeeId = employeeId, kind = "procedural", parts = {} :: { [string]: BasePart }, look = NPC.look(employeeId) }
	local asset = assetFor(employeeId)
	if asset then
		local m = asset:Clone()
		m.Name = "Empleado_" .. employeeId
		m:SetAttribute("employeeId", employeeId)
		rig.model = m
		rig.kind = "asset"
		local pivot = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d.CanCollide = false
				d.CanTouch = false
			end
		end
		if m.PrimaryPart then
			m.PrimaryPart.Anchored = true
		end
		local hum = m:FindFirstChildWhichIsA("Humanoid", true)
		local animator = hum and hum:FindFirstChildWhichIsA("Animator", true)
		local anims = m:FindFirstChild("Animaciones", true)
		if animator and anims then
			rig.animator = animator
			rig.anims = anims
			rig.tracks = {}
		end
		if pivot then
			label(rig, pivot :: BasePart)
			rig.billboard.StudsOffset = Vector3.new(0, 3.5, 0)
		end
		NPC.setInfo(rig, name, dept)
		return rig
	end
	local L = rig.look
	local m = Instance.new("Model")
	m.Name = "Empleado_" .. employeeId
	m:SetAttribute("employeeId", employeeId)
	rig.model = m
	local P = rig.parts
	local root = part(m, "Raiz", Vector3.new(1, 0.2, 1), Color3.new(0, 0, 0), { Transparency = 1, CastShadow = false, CanQuery = false })
	m.PrimaryPart = root
	P.root = root
	P.torso = part(m, "Torso", Vector3.new(1.3, 1.75, 0.65), L.jacket)
	P.shirt = part(m, "Camisa", Vector3.new(0.5, 0.85, 0.06), L.shirt, { CastShadow = false })
	P.tie = part(m, "Corbata", Vector3.new(0.22, 0.85, 0.05), L.tie, { CastShadow = false })
	P.head = part(m, "Cabeza", Vector3.new(0.75, 0.85, 0.8), L.skin)
	P.eyeL = part(m, "Ojo", Vector3.new(0.1, 0.1, 0.04), Color3.fromHex("#1A1A1A"), { CastShadow = false, CanQuery = false })
	P.eyeR = part(m, "Ojo", Vector3.new(0.1, 0.1, 0.04), Color3.fromHex("#1A1A1A"), { CastShadow = false, CanQuery = false })
	if L.hairStyle == 2 then
		P.hair = part(m, "Pelo", Vector3.new(0.8, 0.12, 0.84), L.hair, { CastShadow = false })
	else
		P.hair = part(m, "Pelo", Vector3.new(0.82, 0.26, 0.86), L.hair, { CastShadow = false })
	end
	if L.hairStyle == 1 then
		P.hairBack = part(m, "PeloAtras", Vector3.new(0.84, 0.75, 0.2), L.hair, { CastShadow = false })
	end
	for _, s in { "L", "R" } do
		P["arm" .. s] = part(m, "Brazo" .. s, Vector3.new(0.36, 1.3, 0.4), L.jacket)
		P["hand" .. s] = part(m, "Mano" .. s, Vector3.new(0.3, 0.3, 0.32), L.skin)
		P["thigh" .. s] = part(m, "Muslo" .. s, Vector3.new(0.52, 1.3, 0.58), L.pants)
		P["shin" .. s] = part(m, "Pierna" .. s, Vector3.new(0.48, 1.15, 0.52), L.pants)
		P["shoe" .. s] = part(m, "Zapato" .. s, Vector3.new(0.5, 0.22, 0.78), L.shoes)
	end
	label(rig, P.head)
	NPC.setInfo(rig, name, dept)
	return rig
end

-- Actualiza nombre y departamento sin rearmar el personaje (cambio de departamento, de nombre…).
function NPC.setInfo(rig: any, name: string, dept: any)
	rig.name, rig.dept = name, dept
	if rig.label then
		rig.label.Text = name
		rig.label.TextColor3 = deptColor(dept)
	end
	if rig.model then
		rig.model:SetAttribute("employeeName", name)
		rig.model:SetAttribute("dept", tostring(dept))
	end
end

function NPC.setLabelVisible(rig: any, on: boolean)
	if rig.billboard then
		rig.billboard.Enabled = on
	end
end

function NPC.destroy(rig: any)
	if rig.tracks then
		for _, tr in rig.tracks do
			pcall(function()
				tr:Stop(0)
				tr:Destroy()
			end)
		end
		table.clear(rig.tracks)
	end
	if rig.model then
		rig.model:Destroy()
	end
	rig.model = nil
	rig.parts = {}
	rig.label, rig.billboard = nil, nil
end

return NPC
