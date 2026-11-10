--!strict
--[[ Showroom 3D del menú principal.

	El escenario vive en el Workspace del CLIENTE (no se replica), lejos del garaje, y persiste entre
	redibujos del menú: ScreenMenu solo llama Showroom.show(spec, color, clave) y App.render llama
	Showroom.setVisible(ruta == "menu"). Así las luces son reales (un ViewportFrame solo admite una luz
	direccional) y no se reconstruye nada en cada redibujo.

	· Escenario: piso grafito semibrillante, plataforma baja, paneles oscuros y líneas de luz sutiles del
	  color corporativo. Cerrado (piso, paredes y techo) para que no entre el sol del lugar.
	· Luces: principal blanca suave, relleno, contorno (blancas, sobre el auto) y luces de acento del color
	  corporativo cerca de las paredes, con alcance corto para no teñir la pintura del auto.
	· Cámara: tres cuartos frontal y algo baja, órbita lenta cuando no hay interacción (el auto queda
	  quieto). Arrastrar con el botón izquierdo sobre el área libre rota; la rueda acerca y aleja. Las
	  tarjetas y botones tienen prioridad (si la entrada la usó la interfaz, la cámara no la toma). Al
	  soltar, vuelve de a poco a la órbita. Los límites salen del tamaño real del modelo.
	· Cambio de empresa: el auto anterior se desvanece (0,4 s), cambia el color de acento (0,8 s), se
	  reencuadra y aparece el nuevo (0,5 s). Un cambio nuevo cancela el anterior sin acumular modelos.
	· Rendimiento: una sola conexión por evento, una sola cámara (la del Workspace), sin trabajo cuando el
	  showroom no se ve (el escenario se saca del Workspace).
	Para celular quedan preparadas Showroom.rotate y Showroom.zoom (sin controles táctiles en esta etapa).
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local CarModel = require(Shared.CarModel)
local DesignCalc = require(Shared.DesignCalc)

local Showroom = {}

-- Parámetros (centralizados para ajustarlos después de verlo en Studio).
Showroom.CONFIG = {
	origin = Vector3.new(0, 1200, -3000), -- lejos del garaje y de las parcelas
	room = 56, -- medio lado de la sala (studs; el Pioneer 70 mide ≈ 17 de largo)
	height = 32,
	fov = 38,
	yawDefault = 145, -- tres cuartos frontal (misma convención que la cámara «ángulo» del editor)
	pitchDefault = 8, -- algo baja
	pitchMin = 3,
	pitchMax = 30,
	autoSpeed = 4, -- grados por segundo de la órbita
	idleDelay = 2.5, -- segundos sin interacción antes de volver a la órbita
	returnTime = 1.8, -- segundos para recuperar la órbita completa
	smoothing = 7, -- suavizado de la cámara (más alto = responde más rápido)
	dragSensitivity = 0.28, -- grados por píxel
	zoomStep = 0.88,
	frameShift = 0.2, -- corrimiento del auto hacia la derecha (fracción del semiancho de la pantalla)
	fadeOut = 0.4,
	fadeIn = 0.5,
	colorTime = 0.8,
}
local C = Showroom.CONFIG

local GRAPHITE = Color3.fromHex("#1C1E23")
local PANEL = Color3.fromHex("#16181E")
local PANEL_GAP = Color3.fromHex("#0A0B0E")
local CEILING = Color3.fromHex("#0B0C0F")
local PLATFORM = Color3.fromHex("#26282E")

type CarState = { model: Model, parts: { [BasePart]: number }, sig: string }

local state = {
	stage = nil :: Folder?,
	accentParts = {} :: { BasePart },
	accentLights = {} :: { Light },
	platform = nil :: BasePart?,
	ring = nil :: BasePart?,
	lights = {} :: { [string]: BasePart }, -- soportes de las luces blancas (se ubican según el auto)
	accentHolders = {} :: { BasePart },
	visible = false,
	reduce = false,
	current = nil :: CarState?,
	outgoing = nil :: CarState?,
	pending = nil :: { spec: any, color: string?, sig: string }?,
	phase = nil :: string?, -- "out" | "in" | nil
	timer = 0,
	accent = Color3.fromHex("#7667FF"),
	accentFrom = Color3.fromHex("#7667FF"),
	accentTo = Color3.fromHex("#7667FF"),
	accentT = 1,
	-- Cámara: valores actuales y objetivos (grados y metros). El yaw no se envuelve (evita saltos).
	yaw = C.yawDefault, pitch = C.pitchDefault, dist = 12,
	tYaw = C.yawDefault, tPitch = C.pitchDefault, tDist = 12,
	distDefault = 12, distMin = 6, distMax = 20, target = Vector3.new(0, 1, 0), radius = 3,
	blend = 1, -- 0 = control manual, 1 = órbita cinematográfica
	lastInput = -math.huge,
	dragging = false,
	lastPos = nil :: Vector3?,
	clock = 0,
	phone = false,
	conns = {} :: { RBXScriptConnection },
	savedLighting = nil :: { [string]: any }?,
	savedCamera = nil :: { fov: number, type: any }?,
}
Showroom._state = state -- para las pruebas

local function damp(cur: number, target: number, rate: number, dt: number): number
	return cur + (target - cur) * (1 - math.exp(-rate * dt))
end

local function world(cf: CFrame): CFrame
	return CFrame.new(C.origin) * cf
end

local function part(name: string, size: Vector3, cf: CFrame, color: Color3, props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Size = size
	p.CFrame = world(cf)
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props or {} do
		(p :: any)[k] = v
	end
	p.Parent = state.stage
	return p
end

-- Luz en un soporte invisible que apunta a `target` (la cara frontal del soporte mira al auto).
local function spot(name: string, color: Color3, brightness: number, angle: number, shadows: boolean): SpotLight
	local rig = part(name, Vector3.new(0.2, 0.2, 0.2), CFrame.new(), Color3.new(0, 0, 0), { Transparency = 1, CastShadow = false })
	state.lights[name] = rig
	local l = Instance.new("SpotLight")
	l.Face = Enum.NormalId.Front
	l.Color = color
	l.Brightness = brightness
	l.Range = 60
	l.Angle = angle
	l.Shadows = shadows
	l.Parent = rig
	return l
end

-- Arma el escenario una sola vez (se reutiliza para todas las empresas).
local function buildStage()
	if state.stage then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "ShowroomMenu"
	state.stage = folder
	local R, H = C.room, C.height
	-- Piso grafito semibrillante (reflectancia baja: sin reflejos costosos).
	part("Piso", Vector3.new(R * 2, 1, R * 2), CFrame.new(0, -0.5, 0), GRAPHITE, { Reflectance = 0.06 })
	part("Techo", Vector3.new(R * 2, 1, R * 2), CFrame.new(0, H + 0.5, 0), CEILING, { CastShadow = false })
	-- Plataforma discreta y apenas elevada, con un anillo de luz tenue del color corporativo.
	state.platform = part("Plataforma", Vector3.new(0.3, 9, 9), CFrame.new(0, 0.15, 0) * CFrame.Angles(0, 0, math.rad(90)), PLATFORM, { Shape = Enum.PartType.Cylinder, Reflectance = 0.04 })
	state.ring = part("Anillo", Vector3.new(0.04, 9.6, 9.6), CFrame.new(0, 0.02, 0) * CFrame.Angles(0, 0, math.rad(90)), state.accent, { Shape = Enum.PartType.Cylinder, Material = Enum.Material.Neon, Transparency = 0.55, CastShadow = false })
	table.insert(state.accentParts, state.ring :: BasePart)
	-- Paneles arquitectónicos en las cuatro paredes, con una juntura oscura y dos líneas de luz finas.
	for side = 0, 3 do
		local rot = CFrame.Angles(0, math.rad(90 * side), 0)
		local n = 10
		local w = R * 2 / n
		for i = 1, n do
			local x = -R + w * (i - 0.5)
			part("Panel", Vector3.new(w - 0.25, H, 0.6), rot * CFrame.new(x, H / 2, -R + 0.3), PANEL, { CastShadow = false })
			part("Juntura", Vector3.new(0.25, H, 0.4), rot * CFrame.new(x + w / 2, H / 2, -R + 0.2), PANEL_GAP, { CastShadow = false })
		end
		for _, y in { 1.2, H - 6 } do
			local strip = part("LineaLuz", Vector3.new(R * 2 - 1, 0.12, 0.12), rot * CFrame.new(0, y, -R + 0.7), state.accent, { Material = Enum.Material.Neon, Transparency = 0.5, CastShadow = false })
			table.insert(state.accentParts, strip)
		end
		-- Acento: luz de color cerca de la pared (alcance corto: tiñe paneles y piso, no el auto).
		local accent = Instance.new("PointLight")
		accent.Color = state.accent
		accent.Brightness = 0.7
		accent.Range = 14
		accent.Shadows = false
		local holder = part("Acento", Vector3.new(0.2, 0.2, 0.2), rot * CFrame.new(0, 6, -R + 3), Color3.new(0, 0, 0), { Transparency = 1, CastShadow = false })
		accent.Parent = holder
		table.insert(state.accentHolders, holder)
		table.insert(state.accentLights, accent)
	end
	-- Luces cinematográficas blancas sobre el auto (se ubican según su tamaño en placeLights).
	spot("LuzPrincipal", Color3.fromRGB(255, 247, 238), 2.4, 55, true)
	spot("LuzRelleno", Color3.fromRGB(220, 230, 255), 0.7, 80, false)
	spot("LuzContorno", Color3.fromRGB(255, 255, 255), 1.6, 50, false)
end

-- Ubica las luces según el radio del auto: principal arriba a un costado del frente, relleno bajo del otro
-- lado y contorno desde atrás (ángulos en la misma convención que la cámara: 145° = tres cuartos frontal).
local LIGHT_RIG = {
	LuzPrincipal = { yaw = 100, dist = 2.6, up = 2.0 },
	LuzRelleno = { yaw = 200, dist = 2.4, up = 0.7 },
	LuzContorno = { yaw = 325, dist = 2.6, up = 1.5 },
}
local function placeLights(target: Vector3, radius: number)
	for name, rig in LIGHT_RIG do
		local holder = state.lights[name]
		if holder then
			local a = math.rad(rig.yaw)
			local pos = target + Vector3.new(math.sin(a) * radius * rig.dist, radius * rig.up, math.cos(a) * radius * rig.dist)
			holder.CFrame = CFrame.lookAt(pos, target)
			local l = holder:FindFirstChildWhichIsA("SpotLight")
			if l then
				l.Range = math.min(60, radius * rig.dist * 1.6 + radius)
			end
		end
	end
	-- Las luces de acento iluminan paneles y piso, nunca llegan al auto (así no tiñen la pintura).
	for _, h in state.accentHolders do
		local l = h:FindFirstChildWhichIsA("PointLight")
		local toCar = (h.CFrame.Position - target).Magnitude - radius
		if l then
			l.Range = math.clamp(toCar * 0.8, 4, 24)
		end
	end
end

local function applyAccent(c: Color3)
	state.accent = c
	for _, p in state.accentParts do
		p.Color = c
	end
	for _, l in state.accentLights do
		l.Color = c
	end
end

-- Firma visual de un diseño (para no reconstruir el auto si no cambió nada visible).
local function encode(v: any, depth: number): string
	if type(v) ~= "table" then
		return tostring(v)
	end
	if depth > 4 then
		return "{…}"
	end
	local keys = {}
	for k in v do
		table.insert(keys, tostring(k))
	end
	table.sort(keys)
	local out = {}
	for _, k in keys do
		table.insert(out, k .. "=" .. encode(v[k] ~= nil and v[k] or v[tonumber(k) or k], depth + 1))
	end
	return "{" .. table.concat(out, ",") .. "}"
end

function Showroom.signature(spec: any): string
	if type(spec) ~= "table" then
		return "provisional"
	end
	return encode({ spec.baseId, spec.vehicleModel or "", spec.paint, spec.wheels, spec.caliper, spec.spoiler, spec.body, spec.interior }, 0)
end

-- Auto provisional (empresa nueva o sin diseños): el sedán de 1970 (con su carrocería Pioneer 70).
local function defaultSpec(): any
	local fake = { time = { day = 0, minute = 0 }, research = { done = {}, projects = {} }, company = { name = "Showroom" }, devPaid = {}, facilities = { factory = 1, research = 1, lines = {}, builds = {} } }
	return DesignCalc.newDraft(fake, "brisa")
end

local function setFade(car: CarState, k: number)
	for p, base in car.parts do
		if p.Parent then
			p.Transparency = base + (1 - base) * math.clamp(k, 0, 1)
		end
	end
end

local function destroyCar(car: CarState?)
	if car and car.model then
		car.model:Destroy()
	end
end

-- Arma el auto sobre la plataforma (quieto, anclado y sin colisiones) y recalcula el encuadre.
local function placeCar(spec: any, color: string?, sig: string): CarState?
	local ok, m = pcall(function()
		return CarModel.build(spec or defaultSpec(), { brandColor = color })
	end)
	if not ok or not m then
		warn("[CarEmpire] Showroom: no se pudo armar el auto (" .. tostring(m) .. ")")
		return nil
	end
	local model = m :: Model
	local parts = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			parts[d] = d.Transparency
		elseif d:IsA("LuaSourceContainer") then
			d:Destroy()
		end
	end
	-- Medidas reales del modelo: CarModel las deja como atributos (largo, ancho, alto) y pone el pivote en el
	-- centro de la planta, a ras del suelo (ruedas). Si faltaran, se usa la caja del modelo.
	local L, Wd, Ht = model:GetAttribute("length"), model:GetAttribute("width"), model:GetAttribute("height")
	local size = (type(L) == "number" and type(Wd) == "number" and type(Ht) == "number") and Vector3.new(Wd, Ht, L) or model:GetExtentsSize()
	local radius = size.Magnitude / 2
	-- Plataforma discreta, apenas elevada y a la medida del auto (todo proporcional a su tamaño real).
	local top = math.max(0.3, radius * 0.05)
	local d = math.max(size.X, size.Z) * 1.3 + 1
	if state.platform then
		state.platform.Size = Vector3.new(top, d, d)
		state.platform.CFrame = world(CFrame.new(0, top / 2, 0) * CFrame.Angles(0, 0, math.rad(90)))
	end
	if state.ring then
		state.ring.Size = Vector3.new(0.05, d + radius * 0.12, d + radius * 0.12)
	end
	-- Sobre la plataforma, centrado y con el frente hacia −Z (la orientación que deja CarModel).
	model:PivotTo(CFrame.new(C.origin + Vector3.new(0, top, 0)) * model:GetPivot().Rotation)
	model.Parent = state.stage
	-- Encuadre según las dimensiones reales del modelo.
	local fit = radius / math.sin(math.rad(C.fov) / 2)
	state.radius = radius
	state.target = C.origin + Vector3.new(0, top + size.Y * 0.42, 0)
	state.distMax = math.min(fit * 1.9, C.room - 6) -- nunca fuera de la sala
	state.distMin = math.min(math.max(radius * 1.3, fit * 0.6), state.distMax) -- nunca dentro de la carrocería
	state.distDefault = math.clamp(fit * 1.05, state.distMin, state.distMax)
	state.tDist = state.distDefault
	placeLights(state.target, radius)
	return { model = model, parts = parts, sig = sig }
end

-- Rota la cámara (grados de pantalla: dx horizontal, dy vertical). Lo usa el arrastre del mouse y, en el
-- futuro, el arrastre táctil.
function Showroom.rotate(dx: number, dy: number)
	state.tYaw -= dx * C.dragSensitivity
	state.tPitch = math.clamp(state.tPitch + dy * C.dragSensitivity * 0.6, C.pitchMin, C.pitchMax)
	state.lastInput = state.clock
end

-- Acerca (dir > 0) o aleja (dir < 0) la cámara, dentro de los límites del modelo.
function Showroom.zoom(dir: number)
	local f = dir > 0 and C.zoomStep or 1 / C.zoomStep
	state.tDist = math.clamp(state.tDist * f, state.distMin, state.distMax)
	state.lastInput = state.clock
end

-- Muestra el auto `spec` (o el provisional) de la empresa `key` con su color corporativo. Idempotente: si
-- no cambió nada, solo ajusta el color. Un cambio nuevo cancela la transición anterior de forma segura.
function Showroom.show(spec: any?, color: string?, key: string?)
	buildStage()
	local c = Color3.fromHex(color or "#7667FF")
	local t = state.accentTo
	if math.abs(c.R - t.R) + math.abs(c.G - t.G) + math.abs(c.B - t.B) > 1e-3 then
		state.accentFrom = state.accent
		state.accentTo = c
		state.accentT = 0
	end
	local sig = tostring(key) .. "|" .. Showroom.signature(spec)
	local showing = state.pending and state.pending.sig or (state.current and state.current.sig)
	if showing == sig then
		return
	end
	if state.reduce then
		destroyCar(state.outgoing)
		destroyCar(state.current)
		state.outgoing, state.pending, state.phase = nil, nil, nil
		state.current = placeCar(spec, color, sig)
		state.yaw, state.pitch, state.dist = state.tYaw, state.tPitch, state.tDist
		applyAccent(c)
		state.accentT = 1
		return
	end
	state.pending = { spec = spec, color = color, sig = sig }
	if state.phase == "out" then
		return -- el que se está yendo sigue desapareciendo; al terminar aparece el último pedido
	end
	-- Lo que estaba entrando (o el auto actual) pasa a salir; uno anterior que seguía saliendo se quita ya.
	-- Si estaba apareciendo, la salida arranca desde su visibilidad actual (sin saltos).
	local wasIn = state.phase == "in"
	local visibleK = wasIn and math.clamp(state.timer / C.fadeIn, 0, 1) or 1
	destroyCar(state.outgoing)
	state.outgoing = state.current
	state.current = nil
	state.timer = (1 - visibleK) * C.fadeOut
	state.phase = state.outgoing and "out" or "swap"
end

-- Paso de animación (lo llama RenderStepped; las pruebas lo llaman directamente).
function Showroom.update(dt: number)
	if not state.visible or not state.stage then
		return
	end
	state.clock += dt
	-- Color de acento: transición suave.
	if state.accentT < 1 then
		state.accentT = math.min(1, state.accentT + dt / C.colorTime)
		applyAccent(state.accentFrom:Lerp(state.accentTo, state.accentT))
	end
	-- Transición entre autos.
	if state.phase == "out" then
		state.timer += dt
		local out = state.outgoing
		if out then
			setFade(out, state.timer / C.fadeOut)
		end
		if state.timer >= C.fadeOut or not out then
			state.phase = "swap"
		end
	end
	if state.phase == "swap" then
		destroyCar(state.outgoing)
		state.outgoing = nil
		local p = state.pending
		state.pending = nil
		state.current = p and placeCar(p.spec, p.color, p.sig) or state.current
		if state.current then
			setFade(state.current, 1)
		end
		state.timer = 0
		state.phase = "in"
	end
	if state.phase == "in" then
		state.timer += dt
		if state.current then
			setFade(state.current, 1 - state.timer / C.fadeIn)
		end
		if state.timer >= C.fadeIn then
			if state.current then
				setFade(state.current, 0)
			end
			state.phase = nil
		end
	end
	-- Cámara: manual mientras hay interacción; después vuelve de a poco a la órbita cinematográfica.
	local idle = not state.dragging and (state.clock - state.lastInput) >= C.idleDelay
	if idle then
		state.blend = math.min(1, state.blend + dt / C.returnTime)
	else
		state.blend = math.max(0, state.blend - dt / 0.3)
	end
	local b = state.blend
	if not state.reduce then
		state.tYaw += C.autoSpeed * b * dt
	end
	state.tPitch = damp(state.tPitch, C.pitchDefault, 0.9 * b, dt)
	state.tDist = damp(state.tDist, state.distDefault, 0.9 * b, dt)
	state.tPitch = math.clamp(state.tPitch, C.pitchMin, C.pitchMax)
	state.tDist = math.clamp(state.tDist, state.distMin, state.distMax)
	state.yaw = damp(state.yaw, state.tYaw, C.smoothing, dt)
	state.pitch = damp(state.pitch, state.tPitch, C.smoothing, dt)
	state.dist = damp(state.dist, state.tDist, C.smoothing, dt)
	Showroom.place()
end

-- Ubica la cámara del Workspace (la única) mirando al auto, corrido a la derecha en pantallas anchas.
function Showroom.place()
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	local yaw, pitch = math.rad(state.yaw), math.rad(math.clamp(state.pitch, C.pitchMin, C.pitchMax))
	local offset = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)) * state.dist
	local eye = state.target + offset
	-- Nunca por debajo del piso ni por encima del techo.
	local floorY, ceilY = C.origin.Y + 0.5, C.origin.Y + C.height - 1
	eye = Vector3.new(eye.X, math.clamp(eye.Y, floorY, ceilY), eye.Z)
	local cf = CFrame.lookAt(eye, state.target)
	local vp = cam.ViewportSize
	local aspect = vp.X / math.max(1, vp.Y)
	if not state.phone and aspect > 1.2 then
		local hfov = 2 * math.atan(math.tan(math.rad(C.fov) / 2) * aspect)
		cf *= CFrame.Angles(0, math.atan(math.tan(hfov / 2) * C.frameShift), 0)
	end
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = C.fov
	cam.CFrame = cf
end

-- Ambiente global oscuro mientras se ve el showroom (solo en este cliente); al ocultarlo se restauran los
-- valores exactos que tenía el lugar, así el garaje y el resto del juego no cambian.
local LIGHTING_SHOWROOM = { Ambient = Color3.fromRGB(14, 15, 18), OutdoorAmbient = Color3.fromRGB(18, 19, 23) }
local function overrideLighting(on: boolean)
	pcall(function()
		if on and not state.savedLighting then
			local saved = {}
			for k, v in LIGHTING_SHOWROOM do
				saved[k] = (Lighting :: any)[k]
				;(Lighting :: any)[k] = v
			end
			state.savedLighting = saved
		elseif not on and state.savedLighting then
			for k, v in state.savedLighting do
				(Lighting :: any)[k] = v
			end
			state.savedLighting = nil
		end
	end)
end

-- Muestra u oculta el showroom. Oculto, el escenario sale del Workspace y no se hace ningún trabajo.
function Showroom.setVisible(v: boolean, opts: { reduce: boolean?, phone: boolean? }?)
	state.reduce = opts ~= nil and opts.reduce == true
	state.phone = opts ~= nil and opts.phone == true
	if v == state.visible then
		return
	end
	state.visible = v
	state.dragging = false
	state.lastPos = nil
	if v then
		buildStage()
		if state.stage then
			state.stage.Parent = Workspace
		end
		-- Al volver al menú arranca en el encuadre predeterminado (sin barrer desde donde estaba la cámara).
		state.yaw, state.tYaw = C.yawDefault, C.yawDefault
		state.pitch, state.tPitch = C.pitchDefault, C.pitchDefault
		state.dist, state.tDist = state.distDefault, state.distDefault
		state.blend = 1
		overrideLighting(true)
		local cam = Workspace.CurrentCamera
		if cam and not state.savedCamera then
			state.savedCamera = { fov = cam.FieldOfView, type = cam.CameraType }
		end
		Showroom.place()
	else
		if state.stage then
			state.stage.Parent = nil
		end
		overrideLighting(false)
		-- La cámara vuelve a como estaba (campo de visión y tipo); la del escenario la toma SceneCamera.
		local cam = Workspace.CurrentCamera
		if cam and state.savedCamera then
			cam.FieldOfView = state.savedCamera.fov
			cam.CameraType = state.savedCamera.type
		end
		state.savedCamera = nil
	end
end

function Showroom.isVisible(): boolean
	return state.visible
end

-- Entrada del mouse: la interfaz tiene prioridad (si la usó un botón o una tarjeta, `processed` es true).
local function onBegan(input: InputObject, processed: boolean)
	if not state.visible or processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		state.dragging = true
		state.lastPos = input.Position
		state.lastInput = state.clock
	end
end

local function onChanged(input: InputObject, processed: boolean)
	if not state.visible then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseMovement and state.dragging and state.lastPos then
		local d = input.Position - state.lastPos
		state.lastPos = input.Position
		-- Movimientos grandes de un cuadro (por ejemplo, al volver el foco a la ventana) se recortan.
		Showroom.rotate(math.clamp(d.X, -60, 60), math.clamp(d.Y, -60, 60))
	elseif input.UserInputType == Enum.UserInputType.MouseWheel and not processed then
		Showroom.zoom(input.Position.Z > 0 and 1 or -1)
	end
end

local function onEnded(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		state.dragging = false
		state.lastPos = nil
	end
end

-- Conecta los eventos una sola vez.
function Showroom.start()
	if #state.conns > 0 then
		return
	end
	table.insert(state.conns, RunService.RenderStepped:Connect(Showroom.update))
	table.insert(state.conns, UserInputService.InputBegan:Connect(onBegan))
	table.insert(state.conns, UserInputService.InputChanged:Connect(onChanged))
	table.insert(state.conns, UserInputService.InputEnded:Connect(onEnded))
end

-- Libera todo (conexiones, autos y escenario). No se usa en el juego normal; queda para limpieza y pruebas.
function Showroom.destroy()
	for _, c in state.conns do
		c:Disconnect()
	end
	table.clear(state.conns)
	destroyCar(state.outgoing)
	destroyCar(state.current)
	state.outgoing, state.current, state.pending, state.phase = nil, nil, nil, nil
	if state.stage then
		state.stage:Destroy()
	end
	state.stage, state.platform, state.ring = nil, nil, nil
	table.clear(state.accentParts)
	table.clear(state.accentLights)
	table.clear(state.accentHolders)
	table.clear(state.lights)
	overrideLighting(false)
	state.visible = false
end

function Showroom.connectionCount(): number
	return #state.conns
end

return Showroom
