--!strict
--[[ Representación visual de un empleado en el editor de oficinas (cliente, solo local).

	Cada empleado visible ES un amigo de Roblox del jugador: su personaje es el avatar real de ese amigo (rig
	R15) que arma el servidor (server/EmployeeAvatars) y deja en PlayerGui.AvataresEmpleados. Acá se copia esa
	plantilla en la escena local y se prepara para animarla. No hay personajes genéricos: un empleado sin amigo
	asignado o cuyo avatar todavía no llegó simplemente no se dibuja.

	Animación sin física: todas las piezas quedan ancladas y sin colisión, y OfficeAnimations ubica cada una
	recorriendo las articulaciones del rig desde la raíz (pieza1 = pieza0 · C0 · giro · C1⁻¹, lo mismo que haría
	un Motor6D). Accesorios y soldaduras siguen a su pieza. No se usan IDs de animación.

	El modelo lleva los atributos employeeId y userId, y el nombre visible (DisplayName del amigo) sobre la
	cabeza con el color del departamento. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)

local NPC = {}

-- Medidas de referencia del cuerpo (studs) con las que están pensadas las poses: el avatar se lleva a esta
-- altura (dentro de MIN_SCALE…MAX_SCALE) para que encaje con los muebles.
NPC.DIM = {
	hipH = 2.5, -- altura de la cadera de pie
	height = 5.3,
}
NPC.MIN_SCALE, NPC.MAX_SCALE = 0.7, 1.35

local function deptColor(deptId: any): Color3
	local d = Catalog.department(deptId)
	return Color3.fromHex(d and d.color or "#F5F7FA")
end

local function bounds(parts: { BasePart }): (number, number)
	local lo, hi = math.huge, -math.huge
	for _, p in parts do
		local y, h = p.CFrame.Position.Y, p.Size.Y / 2
		lo, hi = math.min(lo, y - h), math.max(hi, y + h)
	end
	return lo, hi
end

local function bodyParts(m: Model): { BasePart }
	local out = {}
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and d.Transparency < 1 then
			table.insert(out, d)
		end
	end
	return out
end

local JOINTS = { Motor6D = true, Weld = true, ManualWeld = true, WeldConstraint = true, RigidConstraint = true }

--[[ Árbol de articulaciones desde la raíz: lista ordenada de { part, parent, joint (nombre), c0, c1, rel,
	inverse } para ubicar cada pieza a partir de su padre. Las soldaduras sin C0/C1 (WeldConstraint) guardan
	la posición relativa de la plantilla. ]]
local function jointTree(m: Model, root: BasePart): { any }
	local edges = {}
	for _, d in m:GetDescendants() do
		if JOINTS[d.ClassName] then
			local a, b = (d :: any).Part0, (d :: any).Part1
			if a and b and a:IsDescendantOf(m) and b:IsDescendantOf(m) then
				table.insert(edges, { joint = d, a = a, b = b })
			end
		end
	end
	local out, placed = {}, { [root] = true }
	local progress = true
	while progress do
		progress = false
		for _, e in edges do
			if not e.done then
				local j = e.joint :: any
				local isMotor = j.ClassName == "Motor6D" or j.ClassName == "Weld" or j.ClassName == "ManualWeld"
				if placed[e.a] and not placed[e.b] then
					local rec = { part = e.b, parent = e.a, name = j.Name, inverse = false }
					if isMotor then
						rec.c0, rec.c1 = j.C0, j.C1
					else
						rec.rel = e.a.CFrame:Inverse() * e.b.CFrame
					end
					table.insert(out, rec)
					placed[e.b], e.done, progress = true, true, true
				elseif placed[e.b] and not placed[e.a] then
					local rec = { part = e.a, parent = e.b, name = j.Name, inverse = true }
					if isMotor then
						rec.c0, rec.c1 = j.C0, j.C1
					else
						rec.rel = e.b.CFrame:Inverse() * e.a.CFrame
					end
					table.insert(out, rec)
					placed[e.a], e.done, progress = true, true, true
				elseif placed[e.a] and placed[e.b] then
					e.done = true
				end
			end
		end
	end
	return out
end

--[[ Arma el personaje de un empleado a partir de la plantilla del avatar de su amigo. Devuelve el rig:
	{ model, employeeId, userId, kind = "avatar", root, chain, joints = { [nombre] = registro }, rootToFloor,
	  hipStand, builtAt, label } o nil si la plantilla no sirve (sin HumanoidRootPart). ]]
function NPC.build(employeeId: string, name: string, dept: any, template: Model): any
	if not template then
		return nil
	end
	local m = template:Clone()
	m.Name = "Empleado_" .. employeeId
	m:SetAttribute("employeeId", employeeId)
	local root = m:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		m:Destroy()
		return nil
	end
	for _, d in m:GetDescendants() do
		if d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = d ~= root
		end
	end
	m.PrimaryPart = root
	-- Altura acorde a los muebles (sin deformar: escala uniforme del modelo, si el motor la ofrece).
	local lo, hi = bounds(bodyParts(m))
	local height = hi - lo
	if height > 0.5 and height < 100 then
		local k = math.clamp(NPC.DIM.height / height, NPC.MIN_SCALE, NPC.MAX_SCALE)
		if math.abs(k - 1) > 0.02 then
			pcall(function()
				(m :: any):ScaleTo((m :: any):GetScale() * k)
			end)
			lo, hi = bounds(bodyParts(m))
		end
	end
	local rig = {
		model = m,
		employeeId = employeeId,
		userId = template:GetAttribute("userId"),
		builtAt = template:GetAttribute("builtAt"),
		kind = "avatar",
		root = root,
		chain = jointTree(m, root),
		joints = {} :: { [string]: any },
		rootToFloor = root.CFrame.Position.Y - lo,
		hipStand = 0,
		parts = {} :: { [string]: BasePart },
	}
	for _, rec in rig.chain do
		rig.joints[rec.name] = rig.joints[rec.name] or rec
		rig.parts[rec.part.Name] = rec.part
	end
	-- Altura de la cadera de pie (para sentarse a la altura real del asiento).
	local hip = rig.joints.LeftHip or rig.joints.RightHip
	local lower = m:FindFirstChild("LowerTorso") :: BasePart?
	if hip and lower and hip.c0 then
		rig.hipStand = (lower.CFrame * hip.c0).Position.Y - lo
	else
		rig.hipStand = rig.rootToFloor * 0.85
	end
	local head = m:FindFirstChild("Head") :: BasePart?
	local bb = Instance.new("BillboardGui")
	bb.Name = "NombreEmpleado"
	bb.Size = UDim2.fromOffset(170, 22)
	bb.StudsOffset = Vector3.new(0, 1.6, 0)
	bb.LightInfluence = 0
	bb.MaxDistance = 140
	bb.Adornee = head or root
	bb.Parent = head or root
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
	NPC.setInfo(rig, name, dept)
	return rig
end

-- Actualiza nombre y departamento sin rearmar el personaje.
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
	if rig.model then
		rig.model:Destroy()
	end
	rig.model = nil
	rig.chain, rig.joints, rig.parts = {}, {}, {}
	rig.label, rig.billboard = nil, nil
end

return NPC
