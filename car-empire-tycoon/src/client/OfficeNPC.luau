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

-- Lectura segura de una propiedad (en Roblox leer una propiedad que la clase no tiene da error).
local function prop(inst: Instance, name: string): any
	local ok, v = pcall(function()
		return (inst :: any)[name]
	end)
	return ok and v or nil
end

local function isPart(v: any): boolean
	return typeof(v) == "Instance" and v:IsA("BasePart")
end

local function isCFrame(v: any): boolean
	return typeof(v) == "CFrame"
end

-- Clases que unen dos piezas con C0/C1 (JointInstance): pieza1 = pieza0 · C0 · giro · C1⁻¹.
local MOTOR_LIKE = { Motor6D = true, Motor = true, Weld = true, ManualWeld = true, Snap = true, Glue = true }
-- Restricciones rígidas por Attachment (RigidConstraint): los dos Attachment coinciden en el mundo.
local ATTACH_RIGID = { RigidConstraint = true }

--[[ Une dos piezas según la clase de la unión. Devuelve { a, b, kind, c0, c1 } o nil si la unión no sirve
	(desconocida, incompleta o que no une piezas de este modelo). Nunca da error. ]]
local function readJoint(d: Instance, m: Model): any
	local cls = d.ClassName
	local a, b, kind, c0, c1
	if MOTOR_LIKE[cls] then
		a, b = prop(d, "Part0"), prop(d, "Part1")
		c0, c1 = prop(d, "C0"), prop(d, "C1")
		if not (isCFrame(c0) and isCFrame(c1)) then
			return nil
		end
		kind = "motor"
	elseif cls == "WeldConstraint" then
		a, b = prop(d, "Part0"), prop(d, "Part1")
		kind = "rel"
	elseif ATTACH_RIGID[cls] then
		local a0, a1 = prop(d, "Attachment0"), prop(d, "Attachment1")
		if not (typeof(a0) == "Instance" and a0:IsA("Attachment") and typeof(a1) == "Instance" and a1:IsA("Attachment")) then
			return nil
		end
		a, b = a0.Parent, a1.Parent
		c0, c1 = prop(a0, "CFrame"), prop(a1, "CFrame")
		if not (isCFrame(c0) and isCFrame(c1)) then
			return nil
		end
		kind = "motor" -- mismo cálculo: el Attachment0 de la pieza0 coincide con el Attachment1 de la pieza1
	else
		return nil -- otras restricciones (bisagras, resortes, alineaciones…): no fijan la pose; se ignoran
	end
	if not (isPart(a) and isPart(b)) or a == b or not a:IsDescendantOf(m) or not b:IsDescendantOf(m) then
		return nil
	end
	return { a = a, b = b, kind = kind, c0 = c0, c1 = c1, name = d.Name, joint = d }
end
NPC._readJoint = readJoint

--[[ Árbol de uniones desde la raíz: lista ordenada de { part, parent, name, c0, c1 | rel, inverse } para ubicar
	cada pieza a partir de su padre. Las WeldConstraint guardan la posición relativa de la plantilla. Las piezas
	que no cuelgan de ninguna unión válida siguen a la raíz con su posición relativa original (no se quedan
	atrás ni rompen el armado). ]]
local function jointTree(m: Model, root: BasePart): { any }
	local edges = {}
	for _, d in m:GetDescendants() do
		local ok, e = pcall(readJoint, d, m)
		if ok and e then
			table.insert(edges, e)
		end
	end
	local out, placed = {}, { [root] = true }
	local function add(e: any, inverse: boolean)
		local part, parent = (inverse and e.a or e.b), (inverse and e.b or e.a)
		local rec = { part = part, parent = parent, name = e.name, inverse = inverse }
		if e.kind == "motor" then
			rec.c0, rec.c1 = e.c0, e.c1
		else
			rec.rel = parent.CFrame:Inverse() * part.CFrame
		end
		table.insert(out, rec)
		placed[part] = true
	end
	local progress = true
	while progress do
		progress = false
		for _, e in edges do
			if not e.done then
				if placed[e.a] and not placed[e.b] then
					add(e, false)
					e.done, progress = true, true
				elseif placed[e.b] and not placed[e.a] then
					add(e, true)
					e.done, progress = true, true
				elseif placed[e.a] and placed[e.b] then
					e.done = true
				end
			end
		end
	end
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and not placed[d] then
			table.insert(out, { part = d, parent = root, name = "Suelta_" .. d.Name, rel = root.CFrame:Inverse() * d.CFrame, inverse = false })
			placed[d] = true
		end
	end
	return out
end
NPC._jointTree = jointTree

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
		userId = template:GetAttribute("userId") or tonumber(string.match(template.Name, "^Avatar_(%d+)$")),
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
