--!strict
--[[ Animaciones provisionales de los empleados visibles (cliente, solo local; nada se replica).

	Cada pose es una tabla de ángulos y alturas (cadera, inclinación del torso, cuello, hombros, codos, muslos
	y rodillas) pensada para un cuerpo de NPC.DIM. Cada paso se calcula la pose de la actividad actual y se
	aplica al avatar R15 del amigo recorriendo sus articulaciones desde la raíz (todas las piezas ancladas: sin
	física, sin Animator, sin IDs de animación). Cambiar de pose mezcla suavemente desde la anterior (BLEND) y
	después la anterior se descarta: al entrar o salir de un estado no quedan restos. Sentarse y levantarse
	mezclan la pose de pie con la sentada según el avance de la fase (OfficeActivities), y la cadera baja hasta
	la altura real del asiento con la medida del avatar.

	Poses: idle, walk, sit, sitwork (escribir sentado), work (de pie en el escritorio), browse (consultar la
	estantería), rest (recostado en el sofá), meet / sitmeet (gestos de reunión). ]]

local NPC = require(script.Parent.OfficeNPC)

local Anim = {}

Anim.BLEND = 0.3 -- segundos de mezcla entre poses
Anim.SIT_TIME = 0.8 -- debe coincidir con OfficeActivities.SIT_TIME (lo asigna el gestor)

local D = NPC.DIM
local HALF_PI = math.pi / 2

local FIELDS = { "hipH", "hipZ", "back", "twist", "neckP", "neckY", "armLP", "armLR", "armRP", "armRR", "elbowL", "elbowR", "thighL", "thighR", "shinL", "shinR" }

local function base(): any
	return { hipH = D.hipH, hipZ = 0, back = 0, twist = 0, neckP = 0, neckY = 0, armLP = 0, armLR = 0.05, armRP = 0, armRR = 0.05, elbowL = 0.1, elbowR = 0.1, thighL = 0, thighR = 0, shinL = 0, shinR = 0 }
end

local function seated(p: any, seatH: number?)
	p.hipH = seatH or 1.5
	p.hipZ = 0.25 -- la cadera un poco atrás: los muslos apoyan en el asiento
	p.thighL, p.thighR = HALF_PI, HALF_PI
	p.shinL, p.shinR = -HALF_PI, -HALF_PI
end

local POSES: { [string]: (any, number, any) -> () } = {}

POSES.idle = function(p, t, npc)
	p.back = math.sin(t * 1.4) * 0.015
	p.neckY = math.sin(t * 0.35 + (npc.seed or 0) % 7) * 0.3
	p.armLP, p.armRP = math.sin(t * 1.4) * 0.02, math.sin(t * 1.4 + 1) * 0.02
end

POSES.walk = function(p, t, _npc)
	local ph = t * 2 * math.pi * 1.6
	local s = math.sin(ph)
	p.thighL, p.thighR = s * 0.5, -s * 0.5
	p.shinL = -math.max(0, -math.sin(ph - 0.6)) * 0.7
	p.shinR = -math.max(0, math.sin(ph - 0.6)) * 0.7
	p.armLP, p.armRP = -s * 0.45, s * 0.45
	p.hipH = D.hipH - 0.05 + math.abs(math.cos(ph)) * 0.06
	p.back = -0.04
end

POSES.work = function(p, t, _npc)
	p.back = -0.12
	p.neckP = -0.3
	p.armRP = 0.8 + math.sin(t * 6) * 0.05
	p.armLP = 0.6
	p.armLR, p.armRR = -0.05, -0.05
	p.elbowL, p.elbowR = 0.5, 0.6
end

POSES.sit = function(p, t, npc)
	seated(p, npc.activity and npc.activity.spot.seatH)
	p.armLP, p.armRP = 0.55, 0.55
	p.elbowL, p.elbowR = 0.5, 0.5
	p.neckY = math.sin(t * 0.3) * 0.25
end

POSES.sitwork = function(p, t, npc)
	seated(p, npc.activity and npc.activity.spot.seatH)
	p.back = -0.06
	p.neckP = -0.22
	p.armLP = 1.15 + math.sin(t * 9) * 0.06
	p.armRP = 1.15 + math.sin(t * 9 + 1.7) * 0.06
	p.armLR, p.armRR = -0.12, -0.12
	p.elbowL, p.elbowR = 0.55, 0.55
end

POSES.browse = function(p, t, _npc)
	local k = 0.5 + 0.5 * math.sin(t * 0.8)
	p.armRP = 1.7 + 0.7 * k -- busca en un estante alto y en uno más bajo
	p.armLP = 0.45
	p.elbowR, p.elbowL = 0.15, 0.7
	p.neckP = 0.15 + 0.2 * k
	p.twist = math.sin(t * 0.4) * 0.08
end

POSES.rest = function(p, t, npc)
	seated(p, npc.activity and npc.activity.spot.seatH)
	p.back = 0.28 -- recostado
	p.thighL, p.thighR = 1.35, 1.35
	p.shinL, p.shinR = -1.05, -1.05
	p.armLP, p.armRP = 0.3, 0.3
	p.armLR, p.armRR = 0.3, 0.3
	p.neckP = 0.1 + math.sin(t * 0.5) * 0.04
end

local function gestures(p: any, t: number, npc: any)
	local off = (npc.seed or 0) % 11
	p.armRP = 0.55 + 0.45 * math.max(0, math.sin(t * 1.7 + off))
	p.elbowR = 0.4 + 0.4 * math.max(0, math.sin(t * 1.7 + off))
	p.elbowL = 0.3
	p.armLP = 0.35 + 0.3 * math.max(0, math.sin(t * 1.3 + off + 2))
	p.neckY = math.sin(t * 0.6 + off) * 0.45
	p.neckP = -0.05
end

POSES.meet = function(p, t, npc)
	gestures(p, t, npc)
end

POSES.sitmeet = function(p, t, npc)
	seated(p, npc.activity and npc.activity.spot.seatH)
	gestures(p, t, npc)
end

Anim.POSES = POSES

-- Pose objetivo de un empleado ahora (con la fase de sentarse o levantarse ya mezclada).
function Anim.target(npc: any, t: number): (any, string)
	local name = npc.state == "Walking" and "walk" or (npc.pose or "idle")
	if not POSES[name] then
		name = "idle"
	end
	local p = base()
	POSES[name](p, t, npc)
	if npc.phase == "down" or npc.phase == "up" then
		local k = math.clamp((npc.phaseT or 0) / Anim.SIT_TIME, 0, 1)
		if npc.phase == "up" then
			k = 1 - k
		end
		local stand = base()
		POSES.idle(stand, t, npc)
		k = k * k * (3 - 2 * k)
		for _, f in FIELDS do
			p[f] = stand[f] + (p[f] - stand[f]) * k
		end
		name = name .. (npc.phase == "down" and ":sentarse" or ":levantarse")
	end
	return p, name
end

local function lerpPose(a: any, b: any, k: number): any
	local out = {}
	for _, f in FIELDS do
		out[f] = a[f] + (b[f] - a[f]) * k
	end
	return out
end

-- Giro de cada articulación R15 para una pose (las que no figuran quedan como en la plantilla).
local function transforms(p: any): { [string]: CFrame }
	return {
		Waist = CFrame.Angles(p.back, p.twist, 0),
		Neck = CFrame.Angles(p.neckP, p.neckY, 0),
		LeftShoulder = CFrame.Angles(p.armLP, 0, -p.armLR),
		RightShoulder = CFrame.Angles(p.armRP, 0, p.armRR),
		LeftElbow = CFrame.Angles(p.elbowL, 0, 0),
		RightElbow = CFrame.Angles(p.elbowR, 0, 0),
		LeftHip = CFrame.Angles(p.thighL, 0, 0),
		RightHip = CFrame.Angles(p.thighR, 0, 0),
		LeftKnee = CFrame.Angles(p.shinL, 0, 0),
		RightKnee = CFrame.Angles(p.shinR, 0, 0),
	}
end
Anim._transforms = transforms

-- Altura de la cadera del avatar para la pose: de pie la suya; sentado, la del asiento (lineal en el medio).
local function hipOffset(rig: any, p: any, seatH: number): number
	if p.hipH >= D.hipH - 1e-6 then
		return p.hipH - D.hipH -- vaivén al caminar
	end
	local k = math.clamp((D.hipH - p.hipH) / math.max(0.1, D.hipH - seatH), 0, 1)
	return (seatH - rig.hipStand) * k
end

--[[ Ubica el avatar: rootCF = punto del piso mirando al frente del empleado (−Z). Cada pieza se calcula desde
	su padre en el árbol de articulaciones (pieza1 = pieza0 · C0 · giro · C1⁻¹). ]]
function Anim.apply(rig: any, rootCF: CFrame, p: any, seatH: number?)
	if not rig.root or not rig.model then
		return
	end
	local cf: { [any]: CFrame } = {}
	local rootAt = rootCF * CFrame.new(0, rig.rootToFloor + hipOffset(rig, p, seatH or 1.5), p.hipZ)
	cf[rig.root] = rootAt
	rig.root.CFrame = rootAt
	local T = transforms(p)
	for _, rec in rig.chain do
		local parentCF = cf[rec.parent]
		if parentCF then
			local at
			if rec.rel then
				at = parentCF * rec.rel
			elseif rec.inverse then
				at = parentCF * rec.c1 * (T[rec.name] or CFrame.new()):Inverse() * rec.c0:Inverse()
			else
				at = parentCF * rec.c0 * (T[rec.name] or CFrame.new()) * rec.c1:Inverse()
			end
			cf[rec.part] = at
			rec.part.CFrame = at
		end
	end
end

--[[ Un paso de animación de un empleado: mezcla hacia la pose objetivo y ubica el personaje. t = reloj
	visual; dt = tiempo desde el paso anterior. ]]
function Anim.update(rig: any, npc: any, rootCF: CFrame, t: number, dt: number)
	if not rig.model then
		return
	end
	local target, name = Anim.target(npc, t)
	local baseName = string.split(name, ":")[1]
	if rig.poseName and string.split(rig.poseName, ":")[1] ~= baseName and rig.current then
		-- Cambio de pose: se parte de la pose que se veía y se mezcla; la anterior se descarta al terminar.
		rig.from = rig.current
		rig.blendT = 0
	end
	rig.poseName = name
	local p = target
	if rig.from then
		rig.blendT = (rig.blendT or 0) + dt
		local k = math.clamp(rig.blendT / Anim.BLEND, 0, 1)
		if k >= 1 then
			rig.from = nil
		else
			p = lerpPose(rig.from, target, k * k * (3 - 2 * k))
		end
	end
	rig.current = p
	local spot = npc.activity and npc.activity.spot
	Anim.apply(rig, rootCF, p, spot and spot.seatH or 1.5)
end

-- Pose base de una pose (sin la mezcla): para las pruebas y para verificar que una salida limpia la anterior.
function Anim.baseName(rig: any): string?
	return rig.poseName and string.split(rig.poseName, ":")[1] or nil
end

return Anim
