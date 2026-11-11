--!strict
--[[ Animaciones provisionales de los empleados visibles (cliente, solo local; nada se replica).

	Rig procedural (OfficeNPC): cada pose es una tabla de ángulos y alturas (cadera, inclinación del torso,
	cuello, hombros, muslos y piernas). Cada cuadro se calcula la pose de la actividad actual y se ubica cada
	pieza desde la raíz; no hay Motor6D ni física. Cambiar de pose mezcla suavemente desde la anterior
	(BLEND segundos) y después la anterior se descarta: al entrar o salir de un estado no quedan restos.
	Sentarse y levantarse mezclan la pose de pie con la sentada según el avance de la fase (OfficeActivities).

	Poses: idle, walk, sit, sitwork (escribir sentado), work (de pie en el escritorio), browse (consultar la
	estantería), rest (recostado en el sofá), meet / sitmeet (gestos de reunión).

	Modelos definitivos con Animator (OfficeNPC): cada pose busca un objeto Animation con ese nombre en la
	carpeta Animaciones del modelo, lo carga UNA vez (AnimationTrack en caché) y lo reproduce en bucle; al
	cambiar de pose se detiene el anterior. Sin Animation para una pose, se queda la anterior. No se inventan IDs. ]]

local NPC = require(script.Parent.OfficeNPC)

local Anim = {}

Anim.BLEND = 0.3 -- segundos de mezcla entre poses
Anim.SIT_TIME = 0.8 -- debe coincidir con OfficeActivities.SIT_TIME (lo asigna el gestor)

local D = NPC.DIM
local HALF_PI = math.pi / 2

local FIELDS = { "hipH", "hipZ", "back", "twist", "neckP", "neckY", "armLP", "armLR", "armRP", "armRR", "thighL", "thighR", "shinL", "shinR" }

local function base(): any
	return { hipH = D.hipH, hipZ = 0, back = 0, twist = 0, neckP = 0, neckY = 0, armLP = 0, armLR = 0.05, armRP = 0, armRR = 0.05, thighL = 0, thighR = 0, shinL = 0, shinR = 0 }
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
end

POSES.sit = function(p, t, npc)
	seated(p, npc.activity and npc.activity.spot.seatH)
	p.armLP, p.armRP = 0.55, 0.55
	p.neckY = math.sin(t * 0.3) * 0.25
end

POSES.sitwork = function(p, t, npc)
	seated(p, npc.activity and npc.activity.spot.seatH)
	p.back = -0.06
	p.neckP = -0.22
	p.armLP = 1.15 + math.sin(t * 9) * 0.06
	p.armRP = 1.15 + math.sin(t * 9 + 1.7) * 0.06
	p.armLR, p.armRR = -0.12, -0.12
end

POSES.browse = function(p, t, _npc)
	local k = 0.5 + 0.5 * math.sin(t * 0.8)
	p.armRP = 1.7 + 0.7 * k -- busca en un estante alto y en uno más bajo
	p.armLP = 0.45
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

-- Ubica cada pieza del rig procedural según la pose. rootCF = piso del empleado mirando a su frente (−Z).
function Anim.apply(rig: any, rootCF: CFrame, p: any)
	local P = rig.parts
	if not P.torso then
		return
	end
	local s = rig.look and rig.look.height or 1
	P.root.CFrame = rootCF
	local hip = rootCF * CFrame.new(0, p.hipH * s, p.hipZ)
	local chest = hip * CFrame.Angles(p.back, p.twist, 0)
	P.torso.CFrame = chest * CFrame.new(0, D.torso * s / 2, 0)
	P.shirt.CFrame = chest * CFrame.new(0, D.torso * s - 0.5, -0.31)
	P.tie.CFrame = chest * CFrame.new(0, D.torso * s - 0.55, -0.34)
	local neck = chest * CFrame.new(0, D.torso * s, 0) * CFrame.Angles(p.neckP, p.neckY, 0)
	local head = neck * CFrame.new(0, 0.48, 0)
	P.head.CFrame = head
	P.eyeL.CFrame = head * CFrame.new(-0.17, 0.08, -0.41)
	P.eyeR.CFrame = head * CFrame.new(0.17, 0.08, -0.41)
	P.hair.CFrame = head * CFrame.new(0, 0.42 - P.hair.Size.Y / 2 + 0.06, 0.02)
	if P.hairBack then
		P.hairBack.CFrame = head * CFrame.new(0, 0.05, 0.36)
	end
	for _, side in { -1, 1 } do
		local k = side < 0 and "L" or "R"
		local sh = chest * CFrame.new(side * D.shoulderX, D.shoulderY * s, 0) * CFrame.Angles(p["arm" .. k .. "P"], 0, p["arm" .. k .. "R"] * side)
		P["arm" .. k].CFrame = sh * CFrame.new(0, -0.62, 0)
		P["hand" .. k].CFrame = sh * CFrame.new(0, -D.arm, 0)
		local hj = hip * CFrame.new(side * D.hipX, 0, 0) * CFrame.Angles(p["thigh" .. k], 0, 0)
		P["thigh" .. k].CFrame = hj * CFrame.new(0, -D.thigh * s / 2, 0)
		local knee = hj * CFrame.new(0, -D.thigh * s, 0) * CFrame.Angles(p["shin" .. k], 0, 0)
		P["shin" .. k].CFrame = knee * CFrame.new(0, -D.shin * s / 2, 0)
		P["shoe" .. k].CFrame = knee * CFrame.new(0, -D.shin * s - 0.08, -0.12)
	end
end

-- Modelo con Animator: reproduce el AnimationTrack de la pose (cargado una sola vez).
local function playTrack(rig: any, name: string)
	local base = string.split(name, ":")[1]
	if rig.playing == base then
		return
	end
	local anim = rig.anims and rig.anims:FindFirstChild(base)
	if not anim or not anim:IsA("Animation") then
		return
	end
	local track = rig.tracks[base]
	if not track then
		local ok, tr = pcall(function()
			return rig.animator:LoadAnimation(anim)
		end)
		if not ok or not tr then
			return
		end
		track = tr
		track.Looped = true
		rig.tracks[base] = track
	end
	local prev = rig.playing and rig.tracks[rig.playing]
	if prev then
		prev:Stop(Anim.BLEND)
	end
	track:Play(Anim.BLEND)
	rig.playing = base
end

--[[ Un paso de animación de un empleado: mezcla hacia la pose objetivo y ubica el personaje. t = reloj
	visual; dt = tiempo desde el paso anterior. ]]
function Anim.update(rig: any, npc: any, rootCF: CFrame, t: number, dt: number)
	if not rig.model then
		return
	end
	local target, name = Anim.target(npc, t)
	if rig.kind ~= "procedural" then
		rig.model:PivotTo(rootCF)
		if rig.animator then
			playTrack(rig, name)
		end
		rig.poseName = name
		return
	end
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
	Anim.apply(rig, rootCF, p)
end

-- Pose base de una pose (sin la mezcla): para las pruebas y para verificar que una salida limpia la anterior.
function Anim.baseName(rig: any): string?
	return rig.poseName and string.split(rig.poseName, ":")[1] or nil
end

return Anim
