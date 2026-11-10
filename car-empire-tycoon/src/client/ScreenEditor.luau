--!strict
--[[
	Editor de vehículos en cinco etapas: Chasis → Motor → Seguridad → Tecnología y confort → Resumen.
	- La primera vez guía etapa por etapa; después se puede ir directo a cualquier etapa ya visitada.
	- Cada tarjeta se aplica al instante al borrador: se recalculan estadísticas y costos con DesignCalc (los
	  mismos cálculos que usa el servidor) y el panel derecho muestra antes → ahora con la diferencia.
	- El borrador se guarda solo en la partida (Actions.saveDraft) unos segundos después de cada cambio y al
	  salir del editor; el DataStore lo escribe el autoguardado de la sesión. Varios borradores por empresa.
	- «Finalizar diseño» valida y crea el modelo en el servidor (Actions.finalizeDesign): desde ahí es
	  inmutable y pasa a Producción (un lote por modelo).
	Vista 3D: ViewportFrame propio con el modelo de CarModel (no usa Workspace.CurrentCamera, así que no
	interfiere con el showroom ni con la cámara de gestión). Giro manual, zoom con límites y cámaras fijas.
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local DesignCalc = require(Shared.DesignCalc)
local Rules = require(Shared.Rules)
local CarModel = require(Shared.CarModel)

local Ui = require(script.Parent.Ui)
local Icons = require(script.Parent.Icons)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {}

local STEPS = { { 1, "Chasis" }, { 2, "Motor" }, { 3, "Seguridad" }, { 4, "Tecnología y confort" }, { 5, "Resumen" } }
Screen.STEPS = STEPS
local LAST = #STEPS
-- Pestañas dentro de una etapa (la 3 y la 5 son una sola página).
local TABS: { [number]: { any } } = {
	[1] = { { "base", "Chasis" }, { "rodaje", "Tren de rodaje" }, { "carroceria", "Carrocería y pintura" } },
	[2] = { { "motor", "Motor" }, { "tren", "Transmisión y sistemas" } },
	[4] = { { "tecnologia", "Equipamiento" }, { "interior", "Interior" } },
}
Screen.TABS = TABS
-- Etapa (y pestaña) de cada categoría de piezas.
local CAT_STAGE: { [string]: { any } } = {
	traccion = { 1, "rodaje" }, suspension = { 1, "rodaje" }, neumaticos = { 1, "rodaje" }, peso = { 1, "rodaje" },
	motor = { 2, "motor" }, turbo = { 2, "tren" }, transmision = { 2, "tren" }, refrigeracion = { 2, "tren" }, escape = { 2, "tren" }, bateria = { 2, "tren" },
	frenos = { 3 }, seguridad = { 3 },
}
Screen.CAT_STAGE = CAT_STAGE
local RAR = { ["Común"] = "cn", ["Rara"] = "cb", ["Épica"] = "cv", ["Legendaria"] = "cy" }
-- Cámaras predefinidas. yaw 0 = desde atrás; 180 = de frente (la inicial es tres cuartos frontal).
local CAMS = {
	{ "angulo", "Ángulo", 145, 16, "1" },
	{ "frontal", "Frontal", 180, 6, "2" },
	{ "lateral", "Lateral", 90, 4, "3" },
	{ "trasera", "Trasera", 0, 8, "4" },
	{ "superior", "Superior", 150, 72, "5" },
	{ "interior", "Interior", 180, 0, "6" },
	{ "libre", "Vista libre", nil, nil, "7" },
}
Screen.CAMS = CAMS
local BODY_LABELS = {
	{ "bumper", "Paragolpes" }, { "hood", "Capó" }, { "diffuser", "Difusor" }, { "skirts", "Faldones" },
	{ "lights", "Faros" }, { "tint", "Cristales" }, { "vinyl", "Vinilos" }, { "number", "Número de competición" }, { "logo", "Emblema de la empresa" },
}
local INTERIOR_LABELS = { { "seats", "Asientos" }, { "material", "Material del tapizado" }, { "wheel", "Volante" }, { "dash", "Tablero" }, { "ambient", "Iluminación ambiental" } }
local UPHOLSTERY = { { "#1A1B1F", "Negro" }, { "#6B3A2A", "Coñac" }, { "#D9D3C7", "Arena" }, { "#7A1F2B", "Bordó" } }
local ZOOM_MIN, ZOOM_MAX = 0.55, 1.7
local PITCH_MIN, PITCH_MAX = -5, 80
-- Estilo del editor: base azul oscura, acentos azules y tarjetas semitransparentes.
local ACCENT = Color3.fromHex("#3B8BFF")
local ACCENT2 = Color3.fromHex("#8DB8FF")
local PANEL = Color3.fromHex("#0B1220")
local CARD = Color3.fromHex("#111A2B")
local CARD_LINE = Color3.fromHex("#22304A")
local SYNC_DELAY = 2.5 -- segundos sin cambios antes de guardar el borrador en la partida
Screen.SYNC_DELAY = SYNC_DELAY

-- Vista 3D persistente ------------------------------------------------------------------------
local view3d = Instance.new("ScreenGui")
view3d.Name = "CarEmpireEditor3D"
view3d.IgnoreGuiInset = true
view3d.ResetOnSpawn = false
view3d.DisplayOrder = 4
view3d.Enabled = false
view3d.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local backdrop = Instance.new("Frame")
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.new(1, 1, 1)
backdrop.BorderSizePixel = 0
backdrop.Parent = view3d
-- Fondo de la V3: arriba casi negro y, desde el horizonte, luz lavanda.
local grad = Instance.new("UIGradient")
grad.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromHex("#0A0D18")),
	ColorSequenceKeypoint.new(0.2, Color3.fromHex("#0C0F1D")),
	ColorSequenceKeypoint.new(0.42, Color3.fromHex("#4E5294")),
	ColorSequenceKeypoint.new(1, Color3.fromHex("#5F63AE")),
})
grad.Rotation = 90
grad.Parent = backdrop

local function makeViewport(name: string): (ViewportFrame, Camera, WorldModel)
	local vp = Instance.new("ViewportFrame")
	vp.Name = name
	vp.BackgroundTransparency = 1
	vp.Ambient = Color3.fromHex("#A6A9D6")
	vp.LightColor = Color3.fromHex("#FFFFFF")
	vp.LightDirection = Vector3.new(-0.6, -1, -0.4)
	vp.Parent = view3d
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.Parent = vp
	vp.CurrentCamera = camera
	local world = Instance.new("WorldModel")
	world.Parent = vp
	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Shape = Enum.PartType.Cylinder
	floor.Size = Vector3.new(0.3, 30, 30)
	floor.CFrame = CFrame.new(0, -0.15, 0) * CFrame.Angles(0, 0, math.pi / 2)
	floor.Color = Color3.fromHex("#6266B8")
	floor.Material = Enum.Material.SmoothPlastic
	floor.Parent = world
	-- Borde blanco del disco giratorio.
	local rim = floor:Clone()
	rim.Size = Vector3.new(0.26, 30.8, 30.8)
	rim.CFrame = CFrame.new(0, -0.18, 0) * CFrame.Angles(0, 0, math.pi / 2)
	rim.Color = Color3.fromHex("#F2F3FF")
	rim.Parent = world
	return vp, camera, world
end

local viewport, vpCamera, world = makeViewport("Vista")
local compareVp, compareCam, compareWorld = makeViewport("Comparacion")
compareVp.Visible = false
local hotspotLayer = Instance.new("Frame")
hotspotLayer.Name = "PuntosDePiezas"
hotspotLayer.BackgroundTransparency = 1
hotspotLayer.Size = UDim2.fromScale(1, 1)
hotspotLayer.Parent = viewport

local currentModel: Model? = nil
local compareModel: Model? = nil
local modelSig, compareSig = "", ""
local dims = Vector3.new(7, 5, 14)

local view = { yaw = 145, pitch = 16, zoom = 1, cam = "angulo", auto = false, drag = nil :: Vector2? }

local function visualSig(d: any): string
	local ok, enc = pcall(function()
		return game:GetService("HttpService"):JSONEncode({ d.baseId, d.paint, d.wheels, d.caliper, d.spoiler, d.body, d.interior, d.vehicleModel or "" })
	end)
	return ok and enc or tostring(os.clock())
end

local function setModel(target: WorldModel, current: Model?, spec: any): Model
	if current then
		current:Destroy()
	end
	local brand = App.g and App.g.company.color or nil
	local m = CarModel.build(spec, { brandColor = brand })
	m.Parent = target
	return m
end

-- Distancia para que el bloque del auto entre completo en el ViewportFrame según su relación de aspecto.
-- fw y fh: qué fracción del ViewportFrame ocupa el rectángulo libre (como el encuadre de la V3).
function Screen.fitDistance(size: Vector3, aspect: number, fov: number, zoom: number, fw: number?, fh: number?): number
	local radius = size.Magnitude / 2
	local tv = math.tan(math.rad(fov) / 2)
	local vfov = 2 * math.atan(tv * (fh or 1))
	local hfov = 2 * math.atan(tv * math.max(0.2, aspect) * (fw or 1))
	return radius / math.sin(math.min(vfov, hfov) / 2) * 1.04 * zoom
end

-- Rectángulo libre para el auto (en píxeles de pantalla) y fracción que ocupa en el ViewportFrame.
local frame = { fw = 1, fh = 1, rect = { x = 0, y = 0, w = 1, h = 1 }, vpPos = Vector2.new(0, 0) }

local function cameraCFrame(aspect: number): CFrame
	local target = Vector3.new(0, dims.Y * 0.42, 0)
	if view.cam == "interior" then
		local s = CarModel.SHAPES[(Catalog.base(App.ui.editor and App.ui.editor.draft.baseId) or Catalog.BASES[1]).type] or CarModel.SHAPES.sedan
		local eye = Vector3.new(-s.W * 0.2, dims.Y - s.C * 0.45, s.cabinZ + 0.8)
		return CFrame.lookAt(eye, eye + Vector3.new(math.sin(math.rad(view.yaw)) * -1, -0.12, math.cos(math.rad(view.yaw))))
	end
	local dist = Screen.fitDistance(dims, aspect, 40, view.zoom, frame.fw, frame.fh)
	local yaw, pitch = math.rad(view.yaw), math.rad(view.pitch)
	local offset = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)) * dist
	return CFrame.lookAt(target + offset, target)
end

-- Proyección de un punto 3D a la superficie del ViewportFrame (para los puntos de piezas).
local function project(cf: CFrame, point: Vector3, size: Vector2): Vector2?
	local p = cf:PointToObjectSpace(point)
	if p.Z >= -0.1 then
		return nil
	end
	local vfov = math.rad(40)
	local aspect = size.X / math.max(1, size.Y)
	local tv = math.tan(vfov / 2)
	local x = (p.X / -p.Z) / (tv * aspect)
	local y = (p.Y / -p.Z) / tv
	if math.abs(x) > 1 or math.abs(y) > 1 then
		return nil
	end
	return Vector2.new((x + 1) / 2 * size.X, (1 - (y + 1) / 2) * size.Y)
end

local hotspotButtons: { any } = {}

RunService.RenderStepped:Connect(function(dt: number)
	if not view3d.Enabled then
		return
	end
	if view.auto and not view.drag then
		view.yaw = (view.yaw + dt * 20 * (App.settings.camSpeed or 1)) % 360
	end
	local size = viewport.AbsoluteSize
	local cf = cameraCFrame(size.X / math.max(1, size.Y))
	vpCamera.CFrame = cf
	compareCam.CFrame = cf
	for _, h in hotspotButtons do
		local pos = project(cf, h.pos, size)
		-- Como en la V3, solo se muestran los puntos que caen dentro del rectángulo libre.
		local r = frame.rect
		if pos then
			local sx, sy = pos.X + frame.vpPos.X, pos.Y + frame.vpPos.Y
			if sx < r.x or sx > r.x + r.w or sy < r.y or sy > r.y + r.h then
				pos = nil
			end
		end
		if pos and hotspotLayer.Visible then
			h.button.Visible = true
			h.button.Position = UDim2.fromOffset(pos.X, pos.Y)
		else
			h.button.Visible = false
		end
	end
end)

-- Giro manual (arrastre) y zoom (rueda) sobre la vista.
viewport.InputBegan:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		view.drag = Vector2.new(input.Position.X, input.Position.Y)
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		view.zoom = math.clamp(view.zoom * (input.Position.Z > 0 and 0.9 or 1.1), ZOOM_MIN, ZOOM_MAX)
	end
end)
UserInputService.InputChanged:Connect(function(input: InputObject)
	local d = view.drag
	if d and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local now = Vector2.new(input.Position.X, input.Position.Y)
		local delta = now - d
		view.drag = now
		local k = 0.4 * (App.settings.camSpeed or 1)
		view.yaw = (view.yaw - delta.X * k) % 360
		view.pitch = math.clamp(view.pitch + delta.Y * k, PITCH_MIN, PITCH_MAX)
		if view.cam ~= "libre" and view.cam ~= "interior" then
			view.cam = "libre"
			Screen.refreshCamButtons()
		end
	end
end)
UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		view.drag = nil
	end
end)

local camButtons: { [string]: TextButton } = {}
local paintTool: (TextButton, boolean) -> () = nil :: any
function Screen.refreshCamButtons()
	for id, b in camButtons do
		if b.Parent then
			paintTool(b, id == view.cam)
		end
	end
end

function Screen.setCam(id: string)
	for _, c in CAMS do
		if c[1] == id then
			view.cam = id
			if c[3] then
				view.yaw, view.pitch, view.zoom = c[3], c[4], 1
			end
		end
	end
	Screen.refreshCamButtons()
end

function Screen.zoom(factor: number)
	view.zoom = math.clamp(view.zoom * factor, ZOOM_MIN, ZOOM_MAX)
	if view.cam ~= "interior" then
		view.cam = "libre"
	end
	Screen.refreshCamButtons()
end
-- Estado del editor ------------------------------------------------------------------------------------
local function ed(): any
	return App.ui.editor
end

local function findDesign(id: any): any
	for _, d in App.g.designs do
		if d.id == id then
			return d
		end
	end
	return nil
end

local function findDraft(id: any): any
	for _, dr in App.g.drafts or {} do
		if dr.id == id then
			return dr
		end
	end
	return nil
end
Screen.findDraft = findDraft

local function newEditor(draft: any, o: { [string]: any }?): any
	local opts: { [string]: any } = o or {}
	local step = opts.step or 1
	return {
		draft = draft, draftId = opts.draftId or HttpService:GenerateGUID(false), step = step, visited = math.max(opts.visited or 1, step),
		newGenOf = opts.newGenOf, companyId = App.g and App.g.company.id or nil, touched = opts.touched == true, pendingSync = false,
		rev = opts.rev or 0, ackRev = opts.rev or 0, onServer = opts.onServer == true,
		start = Util.deepCopy(draft), tabs = {}, cmp = nil, colorTarget = "primary", undo = {}, redo = {}, compare = false, split = 0.5,
		hideUI = false, hotspots = true,
	}
end

--[[ Guardado del borrador en la partida (no en DataStore en cada clic: el servidor lo guarda con la empresa).
	Cada cambio sube e.rev; e.ackRev es la última revisión que el servidor confirmó. Hay como mucho una solicitud
	en curso por editor, una respuesta vieja nunca baja e.ackRev y el servidor descarta revisiones más viejas que
	la guardada: así un envío atrasado no pisa cambios más nuevos. Si falla, el borrador sigue en memoria y se
	reintenta solo (cada RETRY_DELAY segundos), nunca con un envío por clic. ]]
local RETRY_DELAY = 10
Screen.RETRY_DELAY = RETRY_DELAY
local syncToken = 0
local queueSync: (number?) -> () = nil :: any

local function syncNow(): boolean
	local e = ed()
	if not e or not App.g or not e.touched or e.finalized then
		return true
	end
	if e.companyId ~= App.g.company.id then
		return false
	end
	if e.ackRev >= e.rev then
		e.pendingSync = false
		return true
	end
	if e.syncing then
		return false -- ya hay un envío en curso: lo pendiente sale cuando termine
	end
	local rev = e.rev
	e.syncing = true
	local r = App.request("saveDraft", { draftId = e.draftId, draft = Util.deepCopy(e.draft), step = e.step, visited = e.visited, newGenOf = e.newGenOf, rev = rev }, { key = "borrador:" .. e.draftId })
	e.syncing = false
	if r.ok then
		e.ackRev = math.max(e.ackRev, rev)
		e.onServer = true
		e.syncError = nil
	elseif not r.pending then
		local first = e.syncError == nil
		e.syncError = (type(r.msg) == "string" and r.msg ~= "") and r.msg or "sin respuesta del servidor"
		-- Los rechazos del servidor llegan sin aviso (quiet); los de red ya los avisa App.request.
		if first and r.quiet then
			App.toast("error", "No se pudo guardar el borrador «" .. tostring(e.draft.name) .. "»: " .. e.syncError .. " Tus cambios siguen en el editor.")
		end
	end
	e.pendingSync = e.ackRev < e.rev
	if e.pendingSync and ed() == e then
		-- Cambios hechos mientras se guardaba (o un fallo): otro intento más tarde.
		queueSync(if r.ok then SYNC_DELAY else RETRY_DELAY)
	end
	return not e.pendingSync
end
Screen.syncNow = syncNow

queueSync = function(delay: number?)
	local e = ed()
	if not e then
		return
	end
	syncToken += 1
	local token = syncToken
	task.delay(delay or SYNC_DELAY, function()
		if token == syncToken and ed() == e and e.pendingSync then
			syncNow()
			if App.ui.route == "editor" and ed() == e then
				App.forceRender()
			end
		end
	end)
end

-- Marca un cambio del borrador: nueva revisión y guardado diferido (unos segundos sin cambios).
local function scheduleSync()
	local e = ed()
	if not e then
		return
	end
	e.touched = true
	e.rev += 1
	e.pendingSync = true
	queueSync(SYNC_DELAY)
end
Screen.scheduleSync = scheduleSync

-- Intento inmediato de lo pendiente (sin garantía: para salir del editor se usa ensureSaved).
function Screen.flush()
	local e = ed()
	if e and e.pendingSync then
		syncNow()
	end
end

--[[ ¿Están los últimos cambios aceptados por el servidor? Espera un envío en curso y, si falta, guarda ya.
	Devuelve (true) o (false, motivo). App.guardEditor no deja salir del editor mientras sea false. ]]
function Screen.ensureSaved(): (boolean, string?)
	local e = ed()
	if not e or not App.g or not e.touched or e.finalized or e.companyId ~= App.g.company.id then
		return true, nil
	end
	local t0 = os.clock()
	while e.syncing and os.clock() - t0 < 15 do
		task.wait(0.05)
	end
	if e.ackRev >= e.rev then
		return true, nil
	end
	syncNow()
	if e.ackRev >= e.rev then
		return true, nil
	end
	return false, e.syncError or (e.syncing and "el guardado anterior todavía no terminó" or "el servidor no confirmó el guardado")
end

-- ¿Abrir el editor con estos parámetros reemplazaría el borrador abierto por otro?
function Screen.wouldSwitch(params: any): boolean
	local e = ed()
	if not e or not params then
		return false
	end
	if params.draftId then
		return params.draftId ~= e.draftId
	end
	return params.new == true or params.fresh == true or params.fromTemplate ~= nil or params.newGenOf ~= nil or params.basedOn ~= nil or params.designId ~= nil
end

-- Aviso cuando no se pudo guardar: reintentar, seguir editando o salir igual (elección explícita del jugador).
function Screen.askUnsaved(proceed: () -> (), why: string?)
	local e = ed()
	local params: any = { name = e and e.draft.name or "", reason = why }
	params.onRetry = function()
		local ok, again = Screen.ensureSaved()
		if ok then
			App.closeDialog()
			proceed()
		else
			params.reason = again
			App.renderDialog()
		end
	end
	params.onLeave = function()
		App.closeDialog()
		proceed()
	end
	App.openDialog("unsaved", params)
end

-- Después de un cambio: comparación antes/después (cálculo real de DesignCalc) y guardado diferido.
local function afterChange(before: any, label: string?)
	local e = ed()
	e.cmp = { before = DesignCalc.computeDesign(App.g, before), label = label or "Cambio" }
	scheduleSync()
end

-- Aplica un cambio al borrador (sin confirmación) guardando el estado anterior para deshacer.
local function change(fn: (any) -> (), label: string?)
	local e = ed()
	local before = Util.deepCopy(e.draft)
	fn(e.draft)
	if DesignCalc.sameSpec(before, e.draft) and before.name == e.draft.name then
		return
	end
	table.insert(e.undo, before)
	if #e.undo > 80 then
		table.remove(e.undo, 1)
	end
	table.clear(e.redo)
	afterChange(before, label)
	App.forceRender()
end
Screen.change = change

function Screen.undo()
	local e = ed()
	if not e or #e.undo == 0 then
		return
	end
	local before = Util.deepCopy(e.draft)
	table.insert(e.redo, before)
	e.draft = table.remove(e.undo) :: any
	afterChange(before, "Deshacer")
	App.forceRender()
end

function Screen.redo()
	local e = ed()
	if not e or #e.redo == 0 then
		return
	end
	local before = Util.deepCopy(e.draft)
	table.insert(e.undo, before)
	e.draft = table.remove(e.redo) :: any
	afterChange(before, "Rehacer")
	App.forceRender()
end

-- Los borradores se guardan solos: abrir otro proyecto nunca pierde trabajo y no hace falta preguntar.
function Screen.needsConfirm(_params: any): boolean
	return false
end

local function latestDraft(g: any): any
	local best = nil
	for _, dr in g.drafts or {} do
		if not best or (dr.updatedDay or 0) >= (best.updatedDay or 0) then
			best = dr
		end
	end
	return best
end

local function fromRecord(dr: any): any
	return newEditor(Util.deepCopy(dr.spec), { draftId = dr.id, step = dr.step, visited = dr.visited, newGenOf = dr.newGenOf, touched = true, rev = dr.rev or 0, onServer = true })
end

-- Borrador nuevo a partir de un modelo, una plantilla o una generación anterior.
local function fromSpec(spec: any, name: string?, newGenOf: string?): any
	local nd = Util.deepCopy(spec)
	nd.id, nd.template, nd.version, nd.lotLaunched, nd.createdDay, nd.updatedDay = nil, nil, 0, nil, nil, nil
	if name then
		nd.name = name
	end
	return newEditor(nd, { newGenOf = newGenOf, touched = true })
end

--[[ Abre el editor. params:
	draftId     = continuar ese borrador
	new / fresh = borrador nuevo
	fromTemplate, basedOn / designId (modelo terminado), newGenOf = borrador nuevo a partir de ese diseño
	installPart = { cat, id } (desde el inventario): abre la etapa de esa pieza
	sin nada    = el borrador abierto, o el último guardado, o uno nuevo ]]
function Screen.enter(params: any)
	local g = App.g
	params = params or {}
	local e = ed()
	if e and e.companyId ~= g.company.id then
		e = nil
	end
	local function switch(n: any)
		if e and e ~= n then
			Screen.flush()
		end
		e = n
	end
	if params.draftId then
		local dr = findDraft(params.draftId)
		if dr and (not e or e.draftId ~= dr.id) then
			switch(fromRecord(dr))
		end
	elseif params.fromTemplate then
		local t = findDesign(params.fromTemplate)
		if t then
			switch(fromSpec(t, Util.truncateChars((string.gsub(t.name, " %(plantilla%)$", "")), 18) .. " nuevo"))
		end
	elseif params.newGenOf then
		-- Nueva generación: parte del modelo anterior; al finalizar toma el año actual y el número siguiente.
		local p = findDesign(params.newGenOf)
		if p and not p.template then
			switch(fromSpec(p, nil, p.id))
		end
	elseif params.basedOn or params.designId then
		-- Un modelo terminado no se edita: se empieza un diseño nuevo con su configuración.
		local d = findDesign(params.basedOn or params.designId)
		if d and not d.template then
			switch(fromSpec(d, Util.truncateChars(d.name, 18) .. " nuevo"))
		end
	elseif params.new or params.fresh then
		switch(newEditor(DesignCalc.newDraft(g, DesignCalc.firstBase(g).id)))
	end
	if not e then
		local dr = latestDraft(g)
		e = dr and fromRecord(dr) or newEditor(DesignCalc.newDraft(g, DesignCalc.firstBase(g).id))
	end
	if params.installPart and CAT_STAGE[params.installPart.cat] then
		local m = CAT_STAGE[params.installPart.cat]
		e.step = m[1]
		e.visited = math.max(e.visited, m[1])
		if m[2] then
			e.tabs[m[1]] = m[2]
		end
		e.focus = params.installPart.id
	end
	App.ui.editor = e
	view3d.Enabled = true
	if RunService:IsStudio() then
		task.delay(1.5, function()
			if not view3d.Enabled then
				return
			end
			local r = Screen.diagnose()
			if r.ok then
				print("[CarEmpire] Editor 3D: el auto se ve (" .. r.parts .. " piezas, vista de " .. math.floor(r.size.X) .. "×" .. math.floor(r.size.Y) .. ").")
			else
				warn("[CarEmpire] Editor 3D: posible auto invisible: " .. table.concat(r.problems, "; "))
			end
		end)
	end
end

function Screen.leave()
	Screen.flush()
	view3d.Enabled = false
end

--[[ Diagnóstico de la vista 3D: comprueba lo necesario para que el auto se vea dentro del ViewportFrame
	(ScreenGui activa, ViewportFrame visible y con tamaño, cámara asignada, modelo con piezas dentro del
	WorldModel y centro del auto delante de la cámara y dentro del encuadre). En Studio se imprime en la
	ventana Output al abrir el editor; las pruebas sin Roblox lo usan también. ]]
function Screen.diagnose(): any
	local problems = {}
	local function need(cond: boolean, text: string)
		if not cond then
			table.insert(problems, text)
		end
	end
	need(view3d.Enabled, "la ScreenGui de la vista 3D está desactivada")
	need(viewport.Visible, "el ViewportFrame no está visible")
	local size = viewport.AbsoluteSize
	need(size.X > 10 and size.Y > 10, "el ViewportFrame no tiene tamaño (" .. tostring(size) .. ")")
	need(viewport.CurrentCamera == vpCamera, "el ViewportFrame no tiene la cámara asignada")
	local parts = 0
	if currentModel then
		for _, d in currentModel:GetDescendants() do
			if d:IsA("BasePart") and d.Transparency < 1 then
				parts += 1
			end
		end
	end
	need(currentModel ~= nil and currentModel.Parent == world, "el modelo del auto no está dentro del WorldModel")
	need(parts > 0, "el modelo del auto no tiene piezas visibles")
	local cf = vpCamera.CFrame
	local pos = cf.Position
	need(pos.X == pos.X and pos.Magnitude < 1e4, "la posición de la cámara no es válida")
	local center = Vector3.new(0, dims.Y * 0.42, 0)
	local seen = project(cf, center, Vector2.new(math.max(1, size.X), math.max(1, size.Y)))
	need(seen ~= nil, "el centro del auto queda fuera del encuadre de la cámara")
	need((pos - center).Magnitude > dims.Magnitude / 2, "la cámara está dentro del auto")
	return { ok = #problems == 0, problems = problems, parts = parts, size = size }
end

-- Navegación entre etapas: la primera vez, en orden; después, cualquier etapa visitada.
function Screen.canGo(n: number): boolean
	local e = ed()
	return e ~= nil and n >= 1 and n <= LAST and n <= e.visited + 1 and (n <= e.visited or n == e.step + 1)
end

function Screen.goStep(n: number)
	local e = ed()
	if not e then
		return
	end
	n = math.clamp(n, 1, LAST)
	if n == e.step then
		return
	end
	if not Screen.canGo(n) then
		App.toast("info", "La primera vez se recorren las etapas en orden: completá «" .. STEPS[e.step][2] .. "» y tocá Siguiente.")
		return
	end
	e.step = n
	e.visited = math.max(e.visited, n)
	e.focus = nil
	scheduleSync()
	App.forceRender()
end

function Screen.openStage(n: number, tab: string?)
	local e = ed()
	if not e then
		return
	end
	if tab then
		e.tabs[n] = tab
	end
	if n == e.step then
		App.forceRender()
	else
		Screen.goStep(n)
	end
end

local function tabOf(e: any, n: number): string?
	local list = TABS[n]
	if not list then
		return nil
	end
	local t = e.tabs[n]
	for _, x in list do
		if x[1] == t then
			return t
		end
	end
	return list[1][1]
end
Screen.tabOf = tabOf

-- Componentes ---------------------------------------------------------------------------------------
local function fmtStat(k: string, v: number): string
	if k == "accel" or k == "consumption" then
		return Util.num(v, 1)
	end
	return Util.num(v)
end

local GLASS = Color3.fromHex("#111319") -- rgba(17,19,25,.9)

-- Conversión HSV ↔ HEX (hsv2hex/hex2hsv de la V3).
local function hsv2hex(h: number, s: number, v: number): string
	local function f(n: number): number
		local k = (n + h / 60) % 6
		return v - v * s * math.max(0, math.min(k, 4 - k, 1))
	end
	return string.format("#%02X%02X%02X", Util.round(f(5) * 255), Util.round(f(3) * 255), Util.round(f(1) * 255))
end
local function hex2hsv(hex: string): (number, number, number)
	local n = tonumber(string.sub(hex, 2), 16) or 0x888888
	local r, g, b = bit32.band(bit32.rshift(n, 16), 255) / 255, bit32.band(bit32.rshift(n, 8), 255) / 255, bit32.band(n, 255) / 255
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local d = mx - mn
	local h = 0
	if d > 0 then
		if mx == r then
			h = ((g - b) / d) % 6
		elseif mx == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h = (h * 60 + 360) % 360
	end
	return h, mx > 0 and d / mx or 0, mx
end
Screen.hsv2hex, Screen.hex2hsv = hsv2hex, hex2hsv

-- Botón de cámara (.ed-tools button.t): texto a la izquierda, tecla a la derecha.
paintTool = function(b: TextButton, on: boolean)
	b.BackgroundColor3 = Color3.fromHex("#F5F7FA")
	b.BackgroundTransparency = on and 0.88 or 1
	local t = b:FindFirstChild("Etiqueta") :: TextLabel?
	if t then
		t.TextColor3 = on and T.tx or Color3.fromHex("#C3C8D2")
		t.FontFace = Ui.font(on and W.bold or W.med)
	end
end
-- Botón de la barra de herramientas (.toolbar button).
local function toolbarBtn(icon: string, label: string?, onClick: () -> (), opts: { [string]: any }?): TextButton
	local o = opts or {}
	local disabled = o.disabled == true
	local fg = disabled and Color3.fromHex("#555B68") or (o.pressed and T.tx or Color3.fromHex("#C3C8D2"))
	local b = Ui.new("TextButton", {
		Name = o.name or ("Herramienta_" .. icon), Text = "", Size = UDim2.fromOffset(0, 40), AutomaticSize = Enum.AutomaticSize.X,
		Corner = 8, Pad = { 0, 12 }, BackgroundColor3 = T.vi, BackgroundTransparency = o.pressed and 0.75 or 1,
		List = { dir = "H", gap = 7, v = "C" },
	}, {
		Icons.make(icon, 17, fg),
		label and Ui.inline(label, { size = Ui.S.base, weight = W.semi, color = fg }) or nil,
		(o.kbd and Ui.showKeys) and Ui.kbd(o.kbd) or nil,
	})
	b.MouseEnter:Connect(function()
		if not disabled and not o.pressed then
			b.BackgroundColor3 = Color3.new(1, 1, 1)
			b.BackgroundTransparency = 0.94
		end
	end)
	b.MouseLeave:Connect(function()
		b.BackgroundColor3 = T.vi
		b.BackgroundTransparency = o.pressed and 0.75 or 1
	end)
	b.Activated:Connect(function()
		if disabled then
			return
		end
		if Ui.onClickSound then
			Ui.onClickSound()
		end
		onClick()
	end)
	return b
end

-- Fila de opciones (optRow de la V3): etiqueta .fl y botones .opt con el costo en gris.
local function optRow(label: string?, options: { any }, current: any, onPick: (any) -> (), opts: { [string]: any }?): Frame
	local o = opts or {}
	local items = {}
	for _, op in options do
		local value, text, cost, extra = op[1], op[2], op[3], op[4]
		local full = text .. ((cost and cost > 0 and o.cost ~= false) and (" <font size=\"11\" color=\"#A3AAB8\">+" .. Util.money(cost) .. "/u</font>") or "")
		table.insert(items, Ui.opt(full, current == value, function()
			onPick(value)
		end, { height = o.height or 36, disabled = extra ~= nil and extra.disabled ~= nil, why = extra and extra.disabled, name = o.name and (o.name .. "_" .. tostring(value)) or nil }))
	end
	local holder = o.columns and Ui.grid(items, o.columns, nil, 8) or Ui.row(items, 8, { wrap = true })
	if not label then
		return holder
	end
	return Ui.col({ Ui.fl(label), holder }, 6)
end

local function section(title: string, children: { Instance? }, gap: number?, right: Instance?): Frame
	local list: { Instance? } = { right and Ui.row({ Ui.grow(Ui.lbl(title)), right }, 10) or Ui.lbl(title) }
	for _, c in children do
		table.insert(list, c)
	end
	return Ui.col(list, gap or 10)
end

-- Edición continua (deslizadores y selector de color): el 3D se actualiza al instante y el cambio
-- entra en deshacer una sola vez, al soltar.
local liveBefore: any = nil
local function liveEdit(fn: (any) -> (), final: boolean)
	local e = ed()
	if not liveBefore then
		liveBefore = Util.deepCopy(e.draft)
	end
	fn(e.draft)
	Screen.sync3d()
	if final then
		local before = liveBefore
		liveBefore = nil
		if not (DesignCalc.sameSpec(before, e.draft) and before.name == e.draft.name) then
			table.insert(e.undo, before)
			if #e.undo > 80 then
				table.remove(e.undo, 1)
			end
			table.clear(e.redo)
		end
		afterChange(before, "Ajuste")
		App.forceRender()
	end
end

local function labeledSlider(label: string, valueText: string, slider: Instance): Frame
	return Ui.col({ Ui.row({ Ui.grow(Ui.inline(label, { size = Ui.S.xs, color = T.mut })), Ui.inline(valueText, { size = Ui.S.xs, weight = W.bold }) }, 6), slider }, 4)
end
-- Efectos de una pieza en palabras (lo que cambia en las estadísticas aunque no se vea en el modelo 3D).
local FX_LABEL = {
	{ "hp", "potencia", " hp" }, { "eff", "eficiencia", "" }, { "safety", "seguridad", "" }, { "comfort", "comodidad", "" },
	{ "dur", "fiabilidad", "" }, { "grip", "manejo", "" }, { "brake", "frenado", "" }, { "q", "calidad", "" }, { "kg", "peso", " kg" },
}
function Screen.effectsText(fx: any): string
	local out = {}
	for _, f in FX_LABEL do
		local v = fx and fx[f[1]]
		if v and v ~= 0 then
			table.insert(out, (v > 0 and "+" or "−") .. tostring(math.abs(v)) .. f[3] .. " " .. f[2])
		end
	end
	return #out > 0 and table.concat(out, " · ") or "Sin cambios en las estadísticas"
end

-- Tarjetas de componentes -------------------------------------------------------------------------------
local leftW = 420 -- ancho del panel de opciones (lo fija build según la pantalla)
local function columns(): number
	return (leftW - 36 >= 3 * 150 + 16) and 3 or 2
end

local function statDef(k: string): any
	for _, s in Catalog.STAT_DEFS do
		if s[1] == k then
			return s
		end
	end
	return nil
end

-- Diferencias reales entre dos cálculos (DesignCalc.computeDesign): las más relevantes, con color según si
-- conviene (más potencia es mejor; menos consumo, peso, frenado, aceleración y costo también).
local IMPACT_KEYS = { "hp", "accel", "top", "consumption", "handling", "stop", "safety", "comfort", "durability", "quality", "kg" }
local function impactText(a: any, b: any, max: number?): string
	local out = {}
	for _, k in IMPACT_KEYS do
		local s = statDef(k)
		local dl = Util.round(((b[k] or 0) - (a[k] or 0)) * 10) / 10
		if s and dl ~= 0 then
			local good = (s[5] > 0 and dl > 0) or (s[5] < 0 and dl < 0)
			local unit = k == "consumption" and "" or (string.gsub(s[3], "índice 0–100", ""))
			local label = (unit == "" and (" " .. string.lower(s[2])) or (" " .. unit))
			table.insert(out, "<font color=\"" .. (good and "#42E58D" or "#FF8A91") .. "\">" .. (dl > 0 and "+" or "−") .. fmtStat(k, math.abs(dl)) .. label .. "</font>")
			if #out >= (max or 3) then
				break
			end
		end
	end
	local du = (b.unitCost or 0) - (a.unitCost or 0)
	if du ~= 0 then
		table.insert(out, "<font color=\"" .. (du < 0 and "#42E58D" or "#F7C95C") .. "\">" .. (du > 0 and "+" or "−") .. Util.money(math.abs(du)) .. "/u</font>")
	end
	return table.concat(out, "  ")
end
Screen.impactText = impactText

-- Cálculo del borrador con un cambio aplicado (para mostrar el impacto de cada tarjeta antes de elegirla).
local function calcWith(g: any, d: any, fn: (any) -> ()): any
	local t = Util.deepCopy(d)
	fn(t)
	return DesignCalc.computeDesign(g, t)
end

--[[ Tarjeta: o = { name, title, icon, tag, sub, impact, cost, blocked, selected, toggle, onPick }
	Se aplica al tocarla (sin confirmación); las bloqueadas muestran el requisito y no se pueden usar. ]]
local function componentCard(o: { [string]: any }): TextButton
	local sel, blocked = o.selected == true, o.blocked ~= nil
	local status = sel and Ui.chip(o.toggle and "✓ Instalado" or "✓ Elegido", "cb") or (blocked and Ui.chip("🔒 Bloqueado", "cy") or Ui.chip(o.toggle and "Disponible" or "● Disponible", "cg"))
	local card = Ui.new("TextButton", {
		Name = o.name, Text = "", AutoButtonColor = false,
		BackgroundColor3 = sel and ACCENT or CARD, BackgroundTransparency = sel and 0.8 or (blocked and 0.45 or 0.12),
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Corner = 12,
		Stroke = sel and { ACCENT, 2 } or { CARD_LINE, 1, blocked and 0.45 or 0 }, Pad = 10, List = { dir = "V", gap = 6 },
	}, {
		Ui.row({
			Ui.ico(blocked and "lock" or (o.icon or "wrench"), blocked and T.mut2 or (sel and T.tx or ACCENT2), sel and ACCENT or Color3.fromHex("#16223A"), 30, { radius = 8, iconSize = 15, alpha = sel and 0.55 or 1 }),
			Ui.grow(Ui.text(o.title, { size = 13, weight = W.bold, color = blocked and T.mut or T.tx, lineHeight = 1.15, name = "Titulo" })),
		}, 8, { v = "T" }),
		Ui.row({ status, o.tag and Ui.chip(o.tag, o.tagKind or "cn") or nil }, 4, { wrap = true }),
		o.sub and Ui.text(o.sub, { size = Ui.S.xs, color = T.mut, lineHeight = 1.25 }) or nil,
		(o.impact and o.impact ~= "") and Ui.text(o.impact, { size = Ui.S.xs, lineHeight = 1.25, name = "Impacto" }) or nil,
		o.cost and Ui.text(o.cost, { size = Ui.S.xs, color = T.mut, lineHeight = 1.25, name = "Costo" }) or nil,
		blocked and Ui.why(o.blocked) or nil,
	})
	card:SetAttribute("elegido", sel)
	card:SetAttribute("bloqueado", blocked)
	if not sel and not blocked then
		card.MouseEnter:Connect(function()
			card.BackgroundTransparency = 0.02
		end)
		card.MouseLeave:Connect(function()
			card.BackgroundTransparency = 0.12
		end)
	end
	card.Activated:Connect(function()
		if blocked then
			App.toast("error", o.title .. ": " .. o.blocked)
			return
		end
		if sel and not o.toggle then
			return
		end
		if Ui.onClickSound then
			Ui.onClickSound()
		end
		o.onPick()
	end)
	return card
end
Screen.componentCard = componentCard

local function cardGrid(cards: { Instance? }): Frame
	return Ui.grid(cards, columns(), nil, 8)
end

local function devText(g: any, d: any, cat: string, p: any): string
	local b = Catalog.base(d.baseId)
	if b.defaults[cat] == p.id then
		return "Desarrollo: incluido en la licencia"
	elseif p.proto > 0 then
		return Util.contains(g.devPaid, cat .. ":" .. p.id) and "Desarrollo: pagado" or ("Desarrollo: " .. Util.money(p.proto) .. " (una vez, al finalizar)")
	end
	return "Desarrollo: sin costo"
end

-- Nombre de la pieza sin el «· nivel N» del catálogo (el nivel real del motor se elige aparte).
local function partName(p: any): string
	return (string.gsub(p.name, " · nivel %d+$", ""))
end
Screen.partName = partName

local function partCard(g: any, d: any, cur: any, cat: string, p: any): TextButton
	local sel = d.parts[cat] == p.id
	local block = DesignCalc.partBlock(g, d, p)
	local function apply(dd: any)
		dd.motorFamily = DesignCalc.engineFamily(dd)
		dd.parts[cat] = p.id
		DesignCalc.fixEngine(g, dd)
	end
	local impact = (not sel and not block) and impactText(cur, calcWith(g, d, apply)) or nil
	local tag = p.rarity
	if cat == "motor" and p.family then
		tag = "Familia " .. p.family .. " · nivel máx. " .. Rules.engineLevelMax(g, p.family)
	end
	return componentCard({
		name = "Pieza_" .. p.id, title = partName(p), icon = (cat == "motor" and "wrench") or (cat == "seguridad" and "check") or "wrench",
		tag = tag, tagKind = RAR[p.rarity] or "cn", sub = p.desc .. " Desde " .. tostring(p.year or 1970) .. ".",
		impact = impact or (sel and Screen.effectsText(p.fx) or nil), cost = devText(g, d, cat, p), blocked = block, selected = sel,
		onPick = function()
			local from = Catalog.part(cat, d.parts[cat])
			change(apply, Catalog.catLabel(cat) .. ": " .. (from and partName(from) or "—") .. " → " .. partName(p))
		end,
	})
end

local function partSection(g: any, d: any, cur: any, cat: string, title: string?, intro: string?): Frame
	local cards: { Instance? } = {}
	local b = Catalog.base(d.baseId)
	for _, p in Catalog.partsOf(cat) do
		-- Las piezas de otra clase de vehículo (eléctrico, todoterreno) no se muestran.
		if not (p.need and not Util.contains(b.tags, p.need)) then
			table.insert(cards, partCard(g, d, cur, cat, p))
		end
	end
	return section(title or Catalog.catLabel(cat), {
		intro and Ui.text(intro, { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }) or nil,
		cardGrid(cards),
	}, 8)
end

local function equipmentSection(g: any, d: any, cur: any, group: string, title: string, intro: string): Frame
	local cards: { Instance? } = {}
	for _, eq in Catalog.EQUIPMENT do
		if eq.group == group then
			local on = table.find(d.equipment or {}, eq.id) ~= nil
			local why = DesignCalc.equipmentBlock(g, eq)
			local function toggle(dd: any)
				local want = {}
				for _, id in dd.equipment or {} do
					want[id] = id ~= eq.id
				end
				if not on then
					want[eq.id] = true
				end
				-- Sin repetir y en el orden del catálogo (el servidor lo guarda igual).
				local ordered = {}
				for _, x in Catalog.EQUIPMENT do
					if want[x.id] then
						table.insert(ordered, x.id)
					end
				end
				dd.equipment = ordered
			end
			table.insert(cards, componentCard({
				name = "Equipo_" .. eq.id, title = eq.name, icon = group == "seguridad" and "check" or "gear", toggle = true,
				sub = on and "Tocá para quitarlo." or "Tocá para instalarlo.",
				impact = why == nil and impactText(cur, calcWith(g, d, toggle)) or nil,
				cost = why == nil and ("Investigado · +" .. Util.money(eq.unit * Catalog.ECON.unitCostScale) .. "/u de catálogo") or nil,
				blocked = why, selected = on,
				onPick = function()
					change(toggle, (on and "Quitar " or "Instalar ") .. eq.name)
				end,
			}))
		end
	end
	return section(title, { Ui.text(intro, { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }), cardGrid(cards) }, 8)
end

-- Etapa 1: chasis -----------------------------------------------------------------------------------------
local function stageChassis(g: any, d: any, cur: any, body: Instance)
	local e = ed()
	local tab = tabOf(e, 1)
	if tab == "rodaje" then
		for _, cat in { "traccion", "suspension", "neumaticos", "peso" } do
			partSection(g, d, cur, cat).Parent = body
		end
		return
	elseif tab == "carroceria" then
		Screen.exterior(g, d, body)
		return
	end
	Ui.text("Cada chasis conserva sus estadísticas reales. Las generaciones nuevas se suman: las anteriores siguen disponibles.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }).Parent = body
	-- Chasis por familia, con sus generaciones en orden.
	local families: { [string]: { any } }, order: { string } = {}, {}
	for _, x in Catalog.BASES do
		local fam = x.family or Catalog.TYPES[x.type]
		if not families[fam] then
			families[fam] = {}
			table.insert(order, fam)
		end
		table.insert(families[fam], x)
	end
	-- Primero las familias con algún chasis disponible (en el orden del catálogo); después las bloqueadas.
	local rank = {}
	for i, fam in order do
		local any = false
		for _, x in families[fam] do
			any = any or DesignCalc.baseAvailable(g, x) == nil
		end
		rank[fam] = (any and 0 or 1000) + i
	end
	table.sort(order, function(x: string, y: string): boolean
		return rank[x] < rank[y]
	end)
	for _, fam in order do
		local cards: { Instance? } = {}
		local open = 0
		for _, x in families[fam] do
			local block = DesignCalc.baseAvailable(g, x)
			open += block and 0 or 1
			local sel = d.baseId == x.id
			local paid = Util.contains(g.devPaid, "base:" .. x.id)
			local preview = DesignCalc.computeDesign(g, DesignCalc.newDraft(g, x.id))
			local impact = (not sel and not block) and impactText(cur, calcWith(g, d, function(dd)
				DesignCalc.changeBase(g, dd, x.id)
			end)) or nil
			table.insert(cards, componentCard({
				name = "Base_" .. x.id, title = x.name, icon = "car", tag = "Gen. " .. tostring(x.gen or 1) .. " · desde " .. tostring(x.year or 1970), tagKind = "cb",
				sub = Catalog.TYPES[x.type] .. " · " .. preview.hp .. " hp de serie · manejo " .. preview.handling .. " · seguridad " .. preview.safety,
				impact = impact,
				cost = "Licencia " .. (paid and "pagada" or Util.money(x.dev)) .. " · base " .. Util.money(x.unit) .. "/u de catálogo",
				blocked = block, selected = sel,
				onPick = function()
					local from = Catalog.base(d.baseId)
					change(function(dd)
						DesignCalc.changeBase(g, dd, x.id)
					end, "Chasis: " .. (from and from.name or "—") .. " → " .. x.name)
				end,
			}))
		end
		section(fam .. " · " .. open .. " de " .. #families[fam] .. " disponibles", { cardGrid(cards) }, 8).Parent = body
	end
	-- Estructura del chasis (monocasco, tubular, escalera).
	local b = Catalog.base(d.baseId)
	local cards: { Instance? } = {}
	for _, k in Catalog.CHASSIS_ORDER do
		local ch = Catalog.CHASSIS[k]
		local block = (ch.need and not Util.contains(b.tags, ch.need)) and "Solo para SUV y pickup" or nil
		local sel = d.chassis == k
		local function apply(dd: any)
			dd.chassis = k
		end
		table.insert(cards, componentCard({
			name = "Estructura_" .. k, title = k, icon = "box", sub = ch.unit > 0 and ("+" .. Util.money(ch.unit) .. "/u de catálogo") or "Sin costo extra",
			impact = (not sel and not block) and impactText(cur, calcWith(g, d, apply)) or nil, blocked = block, selected = sel,
			onPick = function()
				change(apply, "Estructura: " .. d.chassis .. " → " .. k)
			end,
		}))
	end
	section("Estructura", { cardGrid(cards) }, 8).Parent = body
end

-- Etapa 2: motor -------------------------------------------------------------------------------------------
local function stageMotor(g: any, d: any, cur: any, body: Instance)
	local e = ed()
	if tabOf(e, 2) == "tren" then
		for _, cat in { "transmision", "turbo", "refrigeracion", "escape", "bateria" } do
			partSection(g, d, cur, cat).Parent = body
		end
		return
	end
	partSection(g, d, cur, "motor", "Motor", "Cada familia se desarrolla hasta el nivel 10 en Investigación. Los niveles anteriores siguen disponibles.").Parent = body
	local fam = DesignCalc.engineFamily(d)
	local maxLvl = DesignCalc.maxEngineLevel(g, d)
	local levels = {}
	for l = 1, Catalog.RESEARCH_RULES.engineMaxLevel do
		local ok = l <= maxLvl
		local diff = (ok and l ~= (d.motorLevel or 1)) and calcWith(g, d, function(dd)
			dd.motorLevel = l
		end) or nil
		local hint = diff and (" <font size=\"10\" color=\"#A3AAB8\">" .. (diff.hp >= cur.hp and "+" or "−") .. math.abs(diff.hp - cur.hp) .. " hp</font>") or ""
		table.insert(levels, { l, "Nivel " .. l .. hint, 0, (not ok) and { disabled = "Requiere investigar " .. tostring(fam) .. " nivel " .. l } or nil })
	end
	section("Nivel del motor" .. (fam and (" · familia " .. fam .. " (investigado hasta el " .. maxLvl .. ")") or ""), {
		optRow(nil, levels, d.motorLevel or 1, function(v)
			change(function(dd)
				dd.motorLevel = v
			end, "Nivel del motor: " .. tostring(d.motorLevel or 1) .. " → " .. tostring(v))
		end, { columns = 5, height = 34, name = "NivelMotor" }),
		Ui.text("Cada nivel suma +" .. Util.round(Catalog.ENGINE_LEVEL_FX.hp * 100) .. " % de potencia y " .. Util.round(Catalog.ENGINE_LEVEL_FX.cons * 100) .. " % de consumo; el motor cuesta +" .. Util.round(Catalog.ENGINE_LEVEL_FX.cost * 100) .. " % por nivel.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }),
	}, 8).Parent = body
	local cards: { Instance? } = {}
	for _, v in Catalog.ENGINE_VARIANTS do
		local why = DesignCalc.variantBlock(g, d, v)
		local sel = (d.motorVariant or "balanced") == v.id
		local function apply(dd: any)
			dd.motorVariant = v.id
		end
		table.insert(cards, componentCard({
			name = "VarianteMotor_" .. v.id, title = v.name, icon = "gear",
			sub = "Potencia ×" .. Util.num(v.hp, 2) .. " · consumo ×" .. Util.num(v.cons, 2) .. " · costo del motor ×" .. Util.num(v.cost, 2),
			impact = (not sel and not why) and impactText(cur, calcWith(g, d, apply), 4) or nil, blocked = why, selected = sel,
			onPick = function()
				local from = Catalog.engineVariant(d.motorVariant or "balanced")
				change(apply, "Variante: " .. (from and from.name or "—") .. " → " .. v.name)
			end,
		}))
	end
	section("Variante", { Ui.text("Las variantes investigadas sirven para todas las familias a combustión.", { size = Ui.S.xs, color = T.mut }), cardGrid(cards) }, 8).Parent = body
end

-- Etapa 3: seguridad ---------------------------------------------------------------------------------------
local function stageSafety(g: any, d: any, cur: any, body: Instance)
	partSection(g, d, cur, "seguridad", "Paquete de seguridad", "Cada paquete incluye lo del anterior. Los no investigados aparecen bloqueados.").Parent = body
	equipmentSection(g, d, cur, "seguridad", "Sistemas adicionales", "Se eligen por diseño: nada se instala solo. Cada sistema suma seguridad y costo.").Parent = body
	partSection(g, d, cur, "frenos", "Frenos").Parent = body
end

-- Etapa 4: tecnología y confort -------------------------------------------------------------------------
local function stageTech(g: any, d: any, cur: any, body: Instance)
	local e = ed()
	if tabOf(e, 4) == "interior" then
		Screen.interior(g, d, body)
		return
	end
	equipmentSection(g, d, cur, "tecnologia", "Tecnología y confort", "Las tecnologías llegan con la investigación y sus fechas. Elegí cuáles lleva este modelo: cada una cambia estadísticas y costo.").Parent = body
end

-- Selector de saturación y brillo (#sv): fondo del tono, degradé blanco → transparente y negro desde abajo.
local function svPicker(color: string, onPick: (string, boolean) -> ()): Frame
	local h, s, v = hex2hsv(color)
	local box = Ui.new("Frame", {
		Name = "SaturacionBrillo", Size = UDim2.new(1, 0, 0, 130), BackgroundColor3 = Color3.fromHex(hsv2hex(h, 1, 1)), BackgroundTransparency = 0,
		Corner = 10, Active = true, ClipsDescendants = true,
	})
	local white = Ui.new("Frame", { Name = "Blanco", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0, Parent = box })
	local wg = Instance.new("UIGradient")
	wg.Transparency = NumberSequence.new(0, 1)
	wg.Parent = white
	local black = Ui.new("Frame", { Name = "Negro", Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0, Parent = box })
	local bg = Instance.new("UIGradient")
	bg.Transparency = NumberSequence.new(1, 0)
	bg.Rotation = 90
	bg.Parent = black
	local knob = Ui.new("Frame", {
		Name = "Puntero", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(s, 1 - v), Size = UDim2.fromOffset(18, 18),
		BackgroundColor3 = Color3.fromHex(color), BackgroundTransparency = 0, Corner = 9, Stroke = { T.tx, 3 }, ZIndex = 3, Parent = box,
	})
	local dragging = false
	local function set(pos: Vector3, final: boolean)
		local w, hh = box.AbsoluteSize.X, box.AbsoluteSize.Y
		if w <= 0 or hh <= 0 then
			return
		end
		local ns = math.clamp((pos.X - box.AbsolutePosition.X) / w, 0, 1)
		local nv = math.clamp(1 - (pos.Y - box.AbsolutePosition.Y) / hh, 0, 1)
		knob.Position = UDim2.fromScale(ns, 1 - nv)
		local hex = hsv2hex(h, ns, nv)
		knob.BackgroundColor3 = Color3.fromHex(hex)
		onPick(hex, final)
	end
	box.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			Ui.dragging = true
			set(input.Position, false)
		end
	end)
	local moveConn = UserInputService.InputChanged:Connect(function(input: InputObject)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			set(input.Position, false)
		end
	end)
	local endConn = UserInputService.InputEnded:Connect(function(input: InputObject)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			Ui.dragging = false
			set(input.Position, true)
		end
	end)
	box.Destroying:Connect(function()
		moveConn:Disconnect()
		endConn:Disconnect()
		if dragging then
			Ui.dragging = false
		end
	end)
	return box
end

local function swatchRow(list: { any }, current: string?, onPick: (string) -> (), name: string): Frame
	local items = {}
	for _, c in list do
		local sw = Ui.swatch(c[1], current ~= nil and string.upper(current) == string.upper(c[1]), function()
			onPick(c[1])
		end)
		sw.Name = name .. "_" .. c[2]
		table.insert(items, sw)
	end
	return Ui.row(items, 10, { wrap = true })
end

-- Exterior (etapa 1 › Carrocería y pintura): carrocería 3D, pintura, ruedas y detalles.
function Screen.exterior(g: any, d: any, body: Instance)
	local e = ed()
	local target = e.colorTarget
	local color = d.paint[target]
	local h = hex2hsv(Util.isHexColor(color) and color or "#888888")
	local targets = {}
	for _, t in { { "primary", "Principal" }, { "secondary", "Secundario" } } do
		table.insert(targets, Ui.opt(t[2], target == t[1], function()
			e.colorTarget = t[1]
			App.forceRender()
		end, { height = 34, name = "Color_" .. t[1] }))
	end
	local hexBox = Ui.input(color, "#D6333F", function(text: string)
		local v = string.upper(Util.trim(text))
		if string.sub(v, 1, 1) ~= "#" then
			v = "#" .. v
		end
		if Util.isHexColor(v) then
			if v ~= d.paint[target] then
				change(function(dd)
					dd.paint[target] = v
				end)
			end
		else
			App.toast("error", "Código inválido. Usá el formato #RRGGBB.")
			App.forceRender()
		end
	end, { name = "Hex", font = "mono" })
	hexBox.FontFace = Font.fromEnum(Enum.Font.RobotoMono)
	local hueSlider = Ui.slider(Util.round(h), 0, 359, 1, function(v: number, final: boolean)
		liveEdit(function(dd)
			local _, cs, cv = hex2hsv(dd.paint[target])
			dd.paint[target] = hsv2hex(v, math.max(cs, 0.05), math.max(cv, 0.05))
		end, final)
	end, { color = Color3.fromHex(hsv2hex(h, 0.9, 1)), name = "Tono" })
	local maxW = DesignCalc.maxWheel(g)
	local finishes = {}
	for _, k in Catalog.FINISH_ORDER do
		local f = Catalog.FINISHES[k]
		local why = DesignCalc.finishBlock(g, k)
		table.insert(finishes, { k, k, f.unit, why and { disabled = why } or nil })
	end
	section("Pintura", {
		target == "secondary" and Ui.text("El color secundario pinta el techo, los pilares, los faldones y los vinilos.", { size = Ui.S.xs, color = T.mut }) or nil,
		svPicker(color, function(hex: string, final: boolean)
			liveEdit(function(dd)
				dd.paint[target] = hex
			end, final)
		end),
		Ui.col({ Ui.inline("Tono", { size = Ui.S.xs, color = T.mut }), hueSlider }, 4),
		Ui.row({
			Ui.new("Frame", { Size = UDim2.fromOffset(44, 44), BackgroundColor3 = Color3.fromHex(color), BackgroundTransparency = 0, Corner = 10, Stroke = Color3.fromHex("#333847") }),
			Ui.fl("HEX"),
			Ui.grow(hexBox),
		}, 10),
		Ui.text("Escribí un código como #D6333F y presioná Enter.", { size = Ui.S.xs, color = T.mut }),
		swatchRow(Catalog.PAINTS, color, function(c)
			change(function(dd)
				dd.paint[target] = string.upper(c)
			end)
		end, "Pintura"),
		Ui.grid({
			labeledSlider("Intensidad", d.paint.intensity .. "%", Ui.slider(d.paint.intensity, 50, 130, 1, function(v: number, final: boolean)
				liveEdit(function(dd)
					dd.paint.intensity = math.clamp(Util.round(v), 50, 130)
				end, final)
			end, { name = "Intensidad" })),
			labeledSlider("Brillo del barniz", d.paint.gloss .. "%", Ui.slider(d.paint.gloss, 0, 100, 1, function(v: number, final: boolean)
				liveEdit(function(dd)
					dd.paint.gloss = math.clamp(Util.round(v), 0, 100)
				end, final)
			end, { name = "Barniz" })),
		}, 2, nil, 12),
		optRow("Acabado", finishes, d.paint.finish, function(v)
			change(function(dd)
				dd.paint.finish = v
			end)
		end, { name = "Acabado" }),
	}, 10, Ui.row(targets, 8, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY })).Parent = body

	local styles = {}
	for _, st in Catalog.WHEEL_STYLES do
		table.insert(styles, { st[1], st[2], 0 })
	end
	section("Ruedas y frenos", {
		optRow("Llantas", styles, d.wheels.style, function(v)
			change(function(dd)
				dd.wheels.style = v
			end)
		end, { name = "Llantas" }),
		Ui.col({ Ui.fl("Color de llantas"), swatchRow(Catalog.RIM_COLORS, d.wheels.rim, function(c)
			change(function(dd)
				dd.wheels.rim = c
			end)
		end, "Llanta") }, 6),
		labeledSlider("Tamaño de las ruedas (hasta " .. maxW .. "″ en " .. Rules.year(g) .. ")", d.wheels.size .. "″ · +" .. Util.money(math.max(0, d.wheels.size - 15) * 150) .. "/u", Ui.slider(d.wheels.size, Catalog.WHEEL_SIZE.min, maxW, 1, function(v: number, final: boolean)
			liveEdit(function(dd)
				dd.wheels.size = math.clamp(Util.round(v), Catalog.WHEEL_SIZE.min, maxW)
			end, final)
		end, { name = "Rodado" })),
		Ui.col({ Ui.fl("Pinzas de freno"), swatchRow(Catalog.CALIPER_COLORS, d.caliper, function(c)
			change(function(dd)
				dd.caliper = c
			end)
		end, "Pinzas") }, 6),
	}, 10).Parent = body
	local bodyRows: { Instance? } = {}
	-- Carrocería 3D definitiva del tipo (por ejemplo, el Pioneer 70 para los sedanes): solo cambia el aspecto.
	local models3d = Catalog.vehicleModelsFor((Catalog.base(d.baseId) or Catalog.BASES[1]).type)
	if #models3d > 0 then
		local cur = Catalog.resolveVehicleModel(d)
		local opts3d = {}
		for _, m in models3d do
			local why = DesignCalc.vehicleModelBlock(g, d, m)
			local def = m.default and (" · predeterminada " .. m.default[1] .. "–" .. m.default[2]) or ""
			table.insert(opts3d, { m.id, m.name .. " <font size=\"11\" color=\"#A3AAB8\">" .. def .. "</font>", 0, why and { disabled = why } or nil })
		end
		table.insert(opts3d, { Catalog.PROVISIONAL_MODEL, "Provisional (genérica)", 0 })
		table.insert(bodyRows, optRow("Carrocería 3D", opts3d, cur and cur.id or Catalog.PROVISIONAL_MODEL, function(v)
			change(function(dd)
				dd.vehicleModel = v
			end)
		end, { name = "Carroceria3D" }))
		table.insert(bodyRows, Ui.text((cur and (cur.name .. ": " .. cur.desc .. ". ") or "") .. "Solo cambia el aspecto del auto (editor, garaje y concesionario); no cambia costos ni ventas.", { size = Ui.S.xs, color = T.mut }))
	end
	table.insert(bodyRows,
		Ui.card({
			Ui.grow(Ui.col({ Ui.text("Alerón trasero", { size = Ui.S.sm, weight = W.bold }), Ui.text("+3 de manejo, −4 km/h de velocidad máxima, +" .. Util.money(600) .. "/u", { size = Ui.S.xs, color = T.mut }) }, 2)),
			Ui.toggle(d.spoiler, function()
				change(function(dd)
					dd.spoiler = not dd.spoiler
				end)
			end),
		}, { dir = "H", v = "C", gap = 10, name = "Aleron" })
	)
	for _, grp in BODY_LABELS do
		local opts = {}
		for _, o in Catalog.BODY_OPTS[grp[1]] do
			local why = DesignCalc.optionBlock(g, Catalog.bodyOpt(grp[1], o[1]))
			table.insert(opts, { o[1], o[2], o[3], why and { disabled = why } or nil })
		end
		table.insert(bodyRows, optRow(grp[2], opts, d.body[grp[1]], function(v)
			change(function(dd)
				dd.body[grp[1]] = v
			end)
		end, { name = "Carroceria_" .. grp[1] }))
	end
	local plateBox = Ui.input(d.body.plate or "", "CET 001", function(text: string)
		local v = string.sub((string.gsub(string.upper(text), "[^A-Z0-9 %-]", "")), 1, 9)
		if v ~= d.body.plate then
			change(function(dd)
				dd.body.plate = v
			end)
		end
	end, { name = "Matricula" })
	table.insert(bodyRows, Ui.col({ Ui.fl("Matrícula"), plateBox }, 6))
	section("Carrocería y detalles", bodyRows, 10).Parent = body
end

-- Interior (etapa 4 › Interior).
function Screen.interior(g: any, d: any, body: Instance)
		Ui.button("Ver interior", "default", function()
			Screen.setCam("interior")
		end, { small = true, icon = "cam", name = "VerInterior" }).Parent = body
		for _, grp in INTERIOR_LABELS do
			local opts = {}
			for _, o in Catalog.INTERIOR[grp[1]] do
				local fx = {}
				for _, k in { "comfort", "q", "grip" } do
					local v = o[4][k]
					if v then
						table.insert(fx, (v > 0 and "+" or "") .. v .. " " .. ({ comfort = "comodidad", q = "calidad", grip = "manejo" })[k])
					end
				end
				local why = DesignCalc.optionBlock(g, Catalog.interiorOpt(grp[1], o[1]))
				table.insert(opts, { o[1], o[2] .. (#fx > 0 and (" (" .. table.concat(fx, ", ") .. ")") or ""), o[3], why and { disabled = why } or nil })
			end
			optRow(grp[2], opts, d.interior[grp[1]], function(v)
				change(function(dd)
					dd.interior[grp[1]] = v
				end)
			end, { name = "Interior_" .. grp[1] }).Parent = body
		end
		Ui.col({ Ui.fl("Color del tapizado"), swatchRow(UPHOLSTERY, d.interior.color, function(c)
			change(function(dd)
				dd.interior.color = c
			end)
		end, "Tapizado") }, 6).Parent = body
end

-- Panel de estadísticas (derecha): valores de DesignCalc, barra y comparación antes → ahora.
local function statsPanel(g: any, d: any, c: any): Frame
	local e = ed()
	local before = e.cmp and e.cmp.before or nil
	local rows: { Instance? } = {
		Ui.row({ Ui.grow(Ui.lbl("Estadísticas")), Ui.inline(before and "antes → ahora" or "diseño actual", { size = Ui.S.xs, color = T.mut }) }, 8),
		before and Ui.text("Último cambio: <b>" .. e.cmp.label .. "</b>", { size = Ui.S.xs, color = ACCENT2, lineHeight = 1.25, name = "UltimoCambio" }) or nil,
	}
	local function row(k: string, label: string, unit: string, dir: number, max: number?, fmt: (number) -> string): Frame
		local v = c[k]
		local pv = before and before[k] or v
		local dl = Util.round((v - pv) * 10) / 10
		local good = (dir > 0 and dl > 0) or (dir < 0 and dl < 0)
		local color = dl == 0 and T.tx or (dir == 0 and T.tx2 or (good and T.gr or T.re2))
		local items: { Instance? } = {
			Ui.row({
				Ui.grow(Ui.text(label .. (unit ~= "" and (" <font size=\"11\" color=\"#6C7382\">" .. unit .. "</font>") or ""), { size = 13, color = T.mut })),
				dl ~= 0 and Ui.inline(fmt(pv) .. " →", { size = Ui.S.xs, color = T.mut2, name = "Antes" }) or nil,
				Ui.inline(fmt(v), { size = 13, weight = W.bold, name = "Valor" }),
				dl ~= 0 and Ui.inline((dl > 0 and "+" or "−") .. fmt(math.abs(dl)), { size = Ui.S.xs, weight = W.bold, color = color, name = "Diferencia" }) or nil,
			}, 6),
		}
		if max then
			local pct = math.clamp((dir > 0 and v / max or 1 - v / max) * 100, 2, 100)
			table.insert(items, (Ui.bar(pct, dl ~= 0 and (good and T.gr or T.re) or ACCENT)))
		end
		local f = Ui.col(items, 4, { Pad = { 2, 0 }, Name = "Stat_" .. k })
		f:SetAttribute("antes", pv)
		f:SetAttribute("ahora", v)
		f:SetAttribute("favorable", if dl ~= 0 then good else nil)
		return f
	end
	for _, s in Catalog.STAT_DEFS do
		local k = s[1]
		table.insert(rows, row(k, s[2], k == "consumption" and c.consUnit or (string.gsub(s[3], "índice 0–100", "")), s[5], s[6], function(x: number): string
			return fmtStat(k, x)
		end))
	end
	table.insert(rows, Ui.new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = CARD_LINE, BackgroundTransparency = 0 }))
	table.insert(rows, row("unitCost", "Costo de fabricación", "por unidad", -1, nil, Util.money))
	table.insert(rows, row("price", "Precio de referencia", "", 0, nil, Util.money))
	local pend = DesignCalc.devPending(g, d, "nuevo")
	table.insert(rows, Ui.between("Desarrollo al finalizar", pend > 0 and Util.money(pend) or "Nada pendiente", { color = pend > g.money and T.re2 or (pend > 0 and T.or_ or T.gr) }))
	table.insert(rows, Ui.text("Verde: mejora. Rojo: empeora (en consumo, peso, frenado, aceleración y costo, menos es mejor).", { size = Ui.S.xs, color = T.mut, lineHeight = 1.35 }))
	return Ui.col(rows, 6, { Name = "Estadisticas" })
end
Screen.statsPanel = statsPanel

-- Etapa 5: presentación del modelo -----------------------------------------------------------------------
local function equipmentNames(d: any, group: string): { string }
	local out = {}
	for _, id in d.equipment or {} do
		local x = Catalog.equipment(id)
		if x and x.group == group then
			table.insert(out, x.name)
		end
	end
	return out
end

local function presentation(g: any, d: any, c: any, body: Instance)
	local b = Catalog.base(d.baseId)
	local nameBox = Ui.input(d.name, "Nombre del modelo", function(text: string)
		local t = Util.truncateChars(Util.trim(text), 24)
		if t ~= d.name then
			change(function(dd)
				dd.name = t
			end, "Nombre: «" .. t .. "»")
		end
	end, { name = "NombreModelo" })
	nameBox.TextSize = math.floor(20 * (Ui.textScale or 1))
	local motor = Catalog.part("motor", d.parts.motor)
	local variant = Catalog.engineVariant(d.motorVariant or "balanced")
	local safety = Catalog.part("seguridad", d.parts.seguridad)
	local frenos = Catalog.part("frenos", d.parts.frenos)
	local secs = equipmentNames(d, "seguridad")
	local tech = equipmentNames(d, "tecnologia")
	local function line(label: string, value: string, stage: number, tab: string?): Frame
		local f = Ui.row({
			Ui.inline(label, { size = Ui.S.xs, color = T.mut, width = 96 }),
			Ui.grow(Ui.text(value, { size = Ui.S.sm, weight = W.semi, lineHeight = 1.25 })),
			Ui.button("", "q", function()
				Screen.openStage(stage, tab)
			end, { small = true, icon = "pen", iconSize = 13, height = 28, name = "Cambiar_" .. stage .. (tab and ("_" .. tab) or "") }),
		}, 8, { v = "T", Name = "Ficha_" .. label })
		return f
	end
	Ui.col({
		Ui.inline(string.upper(d.brand) .. " · PRESENTACIÓN " .. Rules.year(g), { size = Ui.S.xs, weight = W.bold, color = ACCENT2 }),
		Ui.fl("Nombre del modelo"),
		nameBox,
		Ui.text("Se valida al finalizar: de 2 a 24 caracteres.", { size = Ui.S.xs, color = T.mut }),
	}, 6).Parent = body
	section("Ficha técnica", {
		line("Chasis", b.name .. " · " .. d.chassis, 1, "base"),
		line("Motor", (motor and partName(motor) or "—") .. " · nivel " .. tostring(d.motorLevel or 1), 2, "motor"),
		line("Variante", variant and variant.name or "Equilibrada", 2, "motor"),
		line("Seguridad", (safety and safety.name or "—") .. (#secs > 0 and (" · " .. table.concat(secs, ", ")) or "") .. " · " .. (frenos and frenos.name or ""), 3),
		line("Tecnología", #tech > 0 and table.concat(tech, ", ") or "Sin equipamiento", 4, "tecnologia"),
		line("Carrocería", (Catalog.colorName(Catalog.PAINTS, d.paint.primary) or d.paint.primary) .. " " .. string.lower(d.paint.finish) .. " · llantas " .. d.wheels.size .. "″", 1, "carroceria"),
	}, 6).Parent = body
	-- Posicionamiento comercial (pesa en el precio y en a quién le vende el auto).
	local company = g.company.name
	local brands = { { company, company }, { company .. " Sport", company .. " Sport" }, { company .. " Lux", company .. " Lux" } }
	local segs = {}
	for _, k in Catalog.SEGMENT_ORDER do
		table.insert(segs, { k, k .. " · precio ×" .. Util.num(Catalog.SEGMENTS[k].price, 2) })
	end
	local objs = {}
	for _, k in Catalog.OBJECTIVE_ORDER do
		table.insert(objs, { k, k })
	end
	local function sel(label: string, value: any, options: { any }, field: string): Frame
		return Ui.col({ Ui.fl(label), Ui.select(value, options, function(v: any)
			change(function(dd)
				dd[field] = v
			end, label .. ": " .. tostring(v))
		end, { fill = true, name = "Lista_" .. field }) }, 6)
	end
	section("Posicionamiento", {
		Ui.grid({ sel("Marca", d.brand, brands, "brand"), sel("Segmento", d.segment, segs, "segment") }, 2, nil, 10),
		sel("Objetivo del vehículo", d.objective, objs, "objective"),
		labeledSlider("Calidad de terminación", Catalog.QUALITY_TIERS[d.quality + 1] .. " · +" .. Util.money(d.quality * 700) .. "/u de catálogo", Ui.slider(d.quality, 0, 5, 1, function(v: number, final: boolean)
			liveEdit(function(dd)
				dd.quality = math.clamp(Util.round(v), 0, 5)
			end, final)
		end, { name = "Calidad" })),
	}, 8).Parent = body
	local est = Rules.designSalesEstimate(g, c, d, c.price)
	section("Economía", {
		Ui.between("Costo estimado de fabricación", Util.money(c.unitCost) .. " por unidad"),
		Ui.between("Precio de referencia", Util.money(c.price)),
		Ui.between("Ventas estimadas hoy", Util.num(est.rate, 1) .. " por minuto"),
		Ui.text("La cantidad de unidades se elige después, en Producción (un lote por modelo).", { size = Ui.S.xs, color = T.mut }),
	}, 6).Parent = body
	local devRows: { Instance? } = {}
	for _, it in DesignCalc.devItems(g, d, "nuevo") do
		table.insert(devRows, Ui.line(it.label, it.paid and "Pagado" or (it.stock and "Pieza en inventario" or Util.money(it.cost)), { size = Ui.S.sm, color = (it.paid or it.stock) and T.gr or T.tx }))
	end
	section("Desarrollo (se paga al finalizar)", { Ui.card(devRows, { gap = 0, pad = { 4, 12 }, bg = CARD, transparency = 0.2, stroke = CARD_LINE }) }, 8).Parent = body
	local tpl
	tpl = Ui.button("Guardar como plantilla", "default", function()
		App.request("saveDesign", { draft = Util.deepCopy(d), template = true }, { button = tpl })
	end, { small = true, name = "GuardarPlantilla" })
	Ui.row({
		tpl,
		Ui.button("Prueba en pista", "default", function()
			App.openDialog("testDrive", {})
		end, { small = true, name = "ProbarVehiculo" }),
	}, 8, { wrap = true }).Parent = body
end

-- Finalizar: validación local (mismas reglas que el servidor), confirmación y creación en el servidor.
function Screen.finalizeCheck(): string?
	local e = ed()
	local g = App.g
	local d = e.draft
	local name = Util.trim(d.name or "")
	if Util.charCount(name) < 2 or Util.charCount(name) > 24 then
		return "El nombre del modelo debe tener entre 2 y 24 caracteres."
	end
	if string.find(name, "[%c<>&]") then
		return "El nombre del modelo tiene caracteres no permitidos."
	end
	local clean, why = DesignCalc.sanitize(g, d)
	if not clean then
		return why or "La configuración no es válida."
	end
	local pend = DesignCalc.devPending(g, d, "nuevo")
	if pend > g.money then
		return "Fondos insuficientes: el desarrollo cuesta " .. Util.money(pend) .. " y tenés " .. Util.money(g.money) .. "."
	end
	return nil
end

local function doFinalize()
	local e = ed()
	if not e or e.finalizing or e.finalized then
		return
	end
	e.finalizing = true
	-- El borrador tiene que existir en el servidor con la última revisión (si nunca se guardó, se guarda ahora).
	if not e.onServer and e.ackRev >= e.rev then
		e.touched = true
		e.rev += 1
		e.pendingSync = true
	end
	local saved, why = Screen.ensureSaved()
	if not saved then
		e.finalizing = false
		App.toast("error", "No se pudo guardar el borrador antes de finalizar: " .. tostring(why) .. ". Tus cambios siguen en el editor; probá de nuevo.")
		return
	end
	local r = App.request("finalizeDesign", { draftId = e.draftId, draft = Util.deepCopy(e.draft) }, { key = "finalizar" })
	e.finalizing = false
	if r.ok then
		e.finalized = true
		App.ui.editor = nil
		App.ui.lastFinalized = r.designId
		view3d.Enabled = false
		App.go("fabrica")
	end
end
Screen.doFinalize = doFinalize

function Screen.finalize()
	local e = ed()
	if not e or e.finalizing then
		return
	end
	local why = Screen.finalizeCheck()
	if why then
		App.toast("error", why)
		return
	end
	local pend = DesignCalc.devPending(App.g, e.draft, "nuevo")
	App.openDialog("confirm", {
		title = "¿Finalizar «" .. Util.trim(e.draft.name) .. "»?",
		body = "El diseño será <b>definitivo</b>: sus especificaciones ya no se podrán cambiar (para otra versión, un diseño nuevo o una nueva generación). "
			.. (pend > 0 and ("Se paga el desarrollo pendiente de <b>" .. Util.money(pend) .. "</b>. ") or "No hay desarrollo pendiente. ")
			.. "Después elegís cuántas unidades fabricar en Producción.",
		okLabel = "Finalizar diseño",
		onOk = doFinalize,
	})
end

-- Vista 3D --------------------------------------------------------------------------------------------------
-- Reconstruye el modelo si cambió algo visible (también durante un arrastre, sin reconstruir la interfaz).
function Screen.sync3d()
	local e = ed()
	if not e then
		return
	end
	local d = e.draft
	local sig = visualSig(d)
	if sig ~= modelSig or not currentModel then
		modelSig = sig
		currentModel = setModel(world, currentModel, d)
		dims = CarModel.dims(d)
	end
	if e.compare then
		local before = e.start
		local bsig = visualSig(before)
		if bsig ~= compareSig or not compareModel then
			compareSig = bsig
			compareModel = setModel(compareWorld, compareModel, before)
		end
	end
end

-- Geometría (PC): barra superior con las etapas, opciones a la izquierda, auto en el centro, estadísticas a la
-- derecha y navegación abajo. En celular: auto arriba, opciones abajo y estadísticas en un botón.
local function geometry(e: any): any
	local Wd, Hd = App.vw, App.vh
	local phone = App.isPhone()
	local G: any = { phone = phone, topH = phone and 56 or 64, navH = phone and 60 or 68 }
	local final = e.step == LAST
	if phone then
		local sheet = math.floor(Hd * 0.48)
		G.left = { x = 0, y = Hd - G.navH - sheet, w = Wd, h = sheet }
		G.right = nil
	else
		local lw = final and math.clamp(Wd * 0.27, 340, 430) or math.clamp(Wd * 0.33, 380, 540)
		local rw = math.clamp(Wd * 0.2, 270, 330)
		G.left = { x = 14, y = G.topH + 8, w = lw, h = Hd - G.topH - G.navH - 16 }
		G.right = { x = Wd - 14 - rw, y = G.topH + 8, w = rw, h = Hd - G.topH - G.navH - 16 }
	end
	local l, t, r, b = 0, 0, Wd, Hd
	if not e.hideUI then
		t = G.topH + (final and 70 or 0)
		b = Hd - G.navH - 52
		if phone then
			b = math.min(b, G.left.y - 44)
		else
			l = G.left.x + G.left.w
			r = G.right.x
		end
	end
	local m = 10
	l, t, r, b = l + m, t + m, r - m, b - m
	if r - l < 160 then
		l = math.max(0, r - 160)
	end
	if b - t < 140 then
		t = math.max(0, b - 140)
	end
	G.rect = { x = l, y = t, w = r - l, h = b - t }
	return G
end
Screen.geometry = geometry

local function placeViewports(e: any, G: any)
	local k = App.scale()
	local r = G.rect
	local cx, cy = r.x + r.w / 2, r.y + r.h / 2
	-- El ViewportFrame se centra en el rectángulo libre y cubre toda la pantalla: así el piso y el fondo
	-- siguen detrás de los paneles, como el lienzo 3D de la V3, y el auto queda en el centro del hueco.
	local halfW = math.max(cx, App.vw - cx)
	local halfH = math.max(cy, App.vh - cy)
	local pos = Vector2.new(cx - halfW, cy - halfH)
	local size = Vector2.new(halfW * 2, halfH * 2)
	frame.fw, frame.fh = r.w / size.X, r.h / size.Y
	frame.rect = { x = r.x * k, y = r.y * k, w = r.w * k, h = r.h * k }
	frame.vpPos = pos * k
	viewport.Position = UDim2.fromOffset(pos.X * k, pos.Y * k)
	viewport.Size = UDim2.fromOffset(size.X * k, size.Y * k)
	-- Antes / después: la vista anterior se recorta a la izquierda del divisor (el mismo encuadre).
	local clip = view3d:FindFirstChild("RecorteAntes") :: Frame?
	if not clip then
		local c = Instance.new("Frame")
		c.Name = "RecorteAntes"
		c.BackgroundTransparency = 1
		c.ClipsDescendants = true
		c.Parent = view3d
		clip = c
	end
	local cl = clip :: Frame
	cl.Visible = e.compare == true
	cl.Position = UDim2.fromOffset(0, 0)
	cl.Size = UDim2.fromOffset(App.vw * (e.split or 0.5) * k, App.vh * k)
	compareVp.Parent = cl
	compareVp.Visible = e.compare == true
	compareVp.Position = viewport.Position
	compareVp.Size = viewport.Size
	compareVp.ZIndex = 2
end

local function hotspots(e: any, d: any)
	local k = App.scale()
	hotspotLayer:ClearAllChildren()
	table.clear(hotspotButtons)
	hotspotLayer.Visible = e.hotspots and not e.hideUI and view.cam ~= "interior" and e.step < LAST
	for _, h in CarModel.hotspots(d) do
		local tip = Ui.new("TextLabel", {
			Name = "Rotulo", Text = h.label, TextSize = 12, Weight = W.bold, Position = UDim2.fromOffset(40, 6), Size = UDim2.fromOffset(0, 22),
			AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = Color3.fromHex("#080A0F"), BackgroundTransparency = 0.15, Corner = 6, Pad = { 0, 8 }, Visible = false,
		})
		local b = Ui.new("TextButton", {
			Name = "Punto_" .. h.label, Text = "", Size = UDim2.fromOffset(34, 34), AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = GLASS, BackgroundTransparency = 0.15, Corner = 17, Stroke = { T.tx, 2, 0.15 },
		}, {
			Ui.new("Frame", { Size = UDim2.fromOffset(9, 9), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundColor3 = T.tx, BackgroundTransparency = 0, Corner = 5 }),
			tip,
		})
		b.Parent = hotspotLayer
		local scale = Instance.new("UIScale")
		scale.Scale = k
		scale.Parent = b
		b.MouseEnter:Connect(function()
			tip.Visible = true
		end)
		b.MouseLeave:Connect(function()
			tip.Visible = false
		end)
		-- Cada punto abre la etapa de esa pieza (si ya se visitó).
		b.Activated:Connect(function()
			local m = h.cat and CAT_STAGE[h.cat] or nil
			if h.tab == "int" then
				m = { 4, "interior" }
			elseif h.tab == "ext" then
				m = { 1, "carroceria" }
			end
			if m then
				Screen.openStage(m[1], m[2])
			end
		end)
		table.insert(hotspotButtons, { button = b, pos = h.pos })
	end
end

-- Acciones de la barra --------------------------------------------------------------------------------------
function Screen.toggleHide()
	local e = ed()
	if e then
		e.hideUI = not e.hideUI
		App.forceRender()
	end
end

function Screen.toggleCompare()
	local e = ed()
	e.compare = not e.compare
	if e.compare then
		App.toast("info", "Izquierda: inicio del borrador · derecha: ahora. Mové el divisor.")
	end
	App.forceRender()
end

-- Captura: Roblox no deja guardar imágenes desde un script. Se ocultan la interfaz y los avisos unos
-- segundos para sacar la captura con la herramienta de Roblox o del dispositivo.
function Screen.capture()
	local e = ed()
	App.toast("info", "Modo foto: la interfaz se oculta 5 segundos. Usá la captura de pantalla de Roblox o de tu dispositivo.")
	task.delay(1.2, function()
		if App.ui.route ~= "editor" then
			return
		end
		e.photo = true
		App.toastLayer.Visible = false
		App.forceRender()
		task.delay(5, function()
			e.photo = false
			App.toastLayer.Visible = true
			if App.ui.route == "editor" then
				App.forceRender()
			end
		end)
	end)
end

-- Nuevo diseño: el actual queda guardado como borrador (no se pierde nada).
function Screen.newProject()
	App.guardEditor(function()
		App.closeAllDialogs()
		local b = DesignCalc.firstBase(App.g)
		App.ui.editor = newEditor(DesignCalc.newDraft(App.g, b.id))
		if App.ui.route == "editor" then
			App.forceRender()
		else
			App.go("editor")
		end
	end)
end

-- Borradores de la empresa (para el diálogo de borradores y modelos).
function Screen.drafts(): { any }
	local list = table.clone(App.g and App.g.drafts or {})
	table.sort(list, function(a: any, b: any): boolean
		return (a.updatedDay or 0) > (b.updatedDay or 0)
	end)
	return list
end

function Screen.deleteDraft(id: string, btn: any?)
	local e = ed()
	local r = App.request("deleteDraft", { draftId = id }, { button = btn })
	if r.ok and e and e.draftId == id then
		App.ui.editor = nil
	end
	App.forceRender()
	return r.ok
end

-- Construcción ---------------------------------------------------------------------------------------------
local function tabsRow(e: any, n: number): Frame?
	local list = TABS[n]
	if not list then
		return nil
	end
	local cur = tabOf(e, n)
	local row = Ui.row({}, 16)
	for _, t in list do
		local on = cur == t[1]
		local b = Ui.new("TextButton", { Name = "Pestana_" .. t[1], Text = "", Size = UDim2.fromOffset(0, 40), AutomaticSize = Enum.AutomaticSize.X }, {
			Ui.inline(t[2], { size = 14, weight = W.semi, color = on and T.tx or T.mut }),
			on and Ui.new("Frame", { Name = "Subrayado", BackgroundColor3 = ACCENT, BackgroundTransparency = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 2), ZIndex = 2 }) or nil,
		})
		local lab = b:FindFirstChildOfClass("TextLabel")
		if lab then
			lab.Size = UDim2.new(0, 0, 1, 0)
			lab.AutomaticSize = Enum.AutomaticSize.X
		end
		b.Activated:Connect(function()
			e.tabs[n] = t[1]
			if t[1] == "interior" then
				Screen.setCam("interior")
			elseif view.cam == "interior" then
				Screen.setCam("angulo")
			end
			App.forceRender()
		end)
		b.Parent = row
	end
	return Ui.new("Frame", { Name = "Pestanas", Size = UDim2.new(1, 0, 0, 40) }, {
		Ui.new("Frame", { Name = "Linea", BackgroundColor3 = CARD_LINE, BackgroundTransparency = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 1) }),
		row,
	})
end

local function stepIndicator(e: any, phone: boolean): Frame
	local items = {}
	for _, st in STEPS do
		local n = st[1]
		local current = e.step == n
		local done = n < e.step or (n <= e.visited and n ~= e.step)
		local reachable = Screen.canGo(n) or current
		local showLabel = not phone and (current or App.vw >= 1240)
		local btn = Ui.new("TextButton", {
			Name = "Paso_" .. n, Text = "", AutoButtonColor = false, BackgroundColor3 = current and ACCENT or PANEL, BackgroundTransparency = current and 0.78 or 0.15,
			Size = UDim2.fromOffset(0, 38), AutomaticSize = Enum.AutomaticSize.X, Corner = 19, Stroke = { current and ACCENT or CARD_LINE, 1, reachable and 0 or 0.5 },
			Pad = { 0, showLabel and 14 or 4, 0, 4 }, List = { dir = "H", gap = 8, v = "C" },
		}, {
			Ui.new("TextLabel", { Name = "Numero", Text = (done and not current) and "✓" or tostring(n), TextSize = 13, Weight = W.heavy, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = (done and not current) and Color3.fromHex("#05230F") or T.tx, BackgroundColor3 = current and ACCENT or ((done and T.gr) or Color3.fromHex("#1A2438")), BackgroundTransparency = 0, Size = UDim2.fromOffset(28, 28), Corner = 14 }),
			showLabel and Ui.inline(st[2], { size = 13, weight = W.semi, color = current and T.tx or (reachable and Color3.fromHex("#B4BAC6") or T.mut2) }) or nil,
		})
		btn:SetAttribute("visitado", n <= e.visited)
		btn.Activated:Connect(function()
			Screen.goStep(n)
		end)
		table.insert(items, btn)
	end
	return Ui.row(items, 6, { Name = "Pasos", Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY })
end

local function draftStatus(e: any): (string, Color3)
	if e.syncError then
		return "No se pudo guardar: " .. e.syncError, T.re2
	elseif e.syncing or e.pendingSync then
		return "Guardando borrador…", T.ye
	elseif e.touched then
		return "Borrador guardado en la partida", T.gr
	end
	return "Borrador nuevo", T.mut
end
Screen.draftStatus = draftStatus

function Screen.build(parent: Instance)
	local g = App.g
	if not ed() or ed().companyId ~= g.company.id then
		Screen.enter({})
	end
	local e = ed()
	view3d.Enabled = true
	local d = e.draft
	local c = DesignCalc.computeDesign(g, d)
	Screen.sync3d()
	local G = geometry(e)
	placeViewports(e, G)
	hotspots(e, d)
	local phone = G.phone
	if e.photo then
		hotspotLayer.Visible = false
		return
	end
	if e.compare then
		Ui.new("Frame", { Name = "Divisor", Position = UDim2.fromOffset(App.vw * e.split - 1, G.topH), Size = UDim2.new(0, 3, 1, -G.topH - G.navH), BackgroundColor3 = T.tx, BackgroundTransparency = 0, Parent = parent })
		local tagB = Ui.inline("ANTES · inicio del borrador", { size = 12, weight = W.heavy, name = "RotuloAntes" })
		tagB.Position = UDim2.fromOffset((G.left and G.left.x + G.left.w or 0) + 20, G.topH + 16)
		tagB.Parent = parent
		local tagA = Ui.inline("AHORA", { size = 12, weight = W.heavy, color = T.gr, name = "RotuloDespues" })
		tagA.AnchorPoint = Vector2.new(1, 0)
		tagA.Position = UDim2.new(0, (G.right and G.right.x or App.vw) - 20, 0, G.topH + 16)
		tagA.Parent = parent
	end

	if e.hideUI then
		local show = Ui.button("Mostrar interfaz", "p", Screen.toggleHide, { kbd = "H", name = "MostrarInterfaz" })
		show.AnchorPoint = Vector2.new(0.5, 1)
		show.Position = UDim2.new(0.5, 0, 1, -20)
		show.ZIndex = 9
		show.Parent = parent
		return
	end

	-- Barra superior: proyecto, indicador de las cinco etapas y accesos.
	local statusText, statusColor = draftStatus(e)
	local top = Ui.new("Frame", { Name = "BarraEditor", Size = UDim2.new(1, 0, 0, G.topH), BackgroundColor3 = PANEL, BackgroundTransparency = 0.08, Parent = parent })
	local tg = Instance.new("UIGradient")
	tg.Transparency = NumberSequence.new(0, 0.35)
	tg.Rotation = 90
	tg.Parent = top
	local titleCol = Ui.col({
		Ui.inline(phone and "Diseño" or "Diseñar un auto", { size = phone and 15 or 17, weight = W.bold }),
		Ui.inline(Util.truncateChars(d.name, 24) .. " · " .. statusText, { size = Ui.S.xs, color = statusColor, name = "EstadoBorrador" }),
	}, 2, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, Position = UDim2.fromOffset(phone and 120 or 128, phone and 9 or 12), Parent = top }) -- a la derecha de los botones de Roblox
	titleCol.ZIndex = 2
	local steps = stepIndicator(e, phone)
	steps.AnchorPoint = Vector2.new(0.5, 0.5)
	steps.Position = UDim2.fromScale(phone and 0.62 or 0.5, 0.5)
	steps.Parent = top
	local tools = Ui.row({
		(not phone) and Ui.button("", "q", Screen.undo, { small = true, icon = "undo", iconSize = 16, disabled = #e.undo == 0, why = "Nada para deshacer", name = "Deshacer" }) or nil,
		(not phone) and Ui.button("", "q", Screen.redo, { small = true, icon = "redo", iconSize = 16, disabled = #e.redo == 0, why = "Nada para rehacer", name = "Rehacer" }) or nil,
		Ui.button(phone and "" or ("Borradores (" .. #(g.drafts or {}) .. ")"), "default", function()
			Screen.flush()
			App.openDialog("prevModels", { wide = true })
		end, { small = true, icon = "copy", name = "ModelosAnteriores" }),
		Ui.button("", "default", function()
			App.openDialog("help", { screen = "editor" })
		end, { small = true, icon = "help", iconSize = 16, name = "AyudaEditor" }),
	}, 8, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), Parent = top })
	tools.ZIndex = 2

	-- Panel izquierdo: opciones de la etapa (en la última, la presentación del modelo).
	leftW = G.left.w
	local panel = Ui.new("Frame", {
		Name = "PanelEditor", Position = UDim2.fromOffset(G.left.x, G.left.y), Size = UDim2.fromOffset(G.left.w, G.left.h),
		BackgroundColor3 = PANEL, BackgroundTransparency = 0.12, Corner = phone and 0 or 16, Stroke = { CARD_LINE, 1 }, ClipsDescendants = true,
		List = { dir = "V", gap = 0 }, Parent = parent,
	})
	local head = Ui.col({
		Ui.inline("ETAPA " .. e.step .. " DE " .. LAST, { size = Ui.S.xs, weight = W.bold, color = ACCENT2 }),
		Ui.text(STEPS[e.step][2], { size = Ui.S.h1, weight = W.bold, name = "TituloEtapa" }),
		tabsRow(e, e.step),
	}, 6, { Name = "Cabecera", Pad = { 14, 16, 4, 16 } })
	head.Parent = panel
	local body = Ui.scroll({}, { name = "CuerpoPaso", gap = 16, pad = { 12, 16, 16, 16 } })
	body.Size = UDim2.new(1, 0, 0, 0)
	local flex = Instance.new("UIFlexItem")
	flex.FlexMode = Enum.UIFlexMode.Fill
	flex.Parent = body
	body.Parent = panel
	if e.step == 1 then
		stageChassis(g, d, c, body)
	elseif e.step == 2 then
		stageMotor(g, d, c, body)
	elseif e.step == 3 then
		stageSafety(g, d, c, body)
	elseif e.step == 4 then
		stageTech(g, d, c, body)
	else
		presentation(g, d, c, body)
	end
	App.keepScroll(body, "editor:" .. e.step .. ":" .. tostring(tabOf(e, e.step)))

	-- Panel derecho: estadísticas, prestaciones y costos.
	if G.right or e.statsOpen then
		local holder = Ui.scroll({ statsPanel(g, d, c) }, { name = "EstadisticasEditor", gap = 0, pad = { 14, 14, 14, 14 } })
		holder.AutomaticSize = Enum.AutomaticSize.None
		if G.right then
			holder.Position = UDim2.fromOffset(G.right.x, G.right.y)
			holder.Size = UDim2.fromOffset(G.right.w, G.right.h)
		else
			holder.Position = UDim2.fromOffset(8, G.topH + 8)
			holder.Size = UDim2.new(1, -16, 0, math.max(160, G.left.y - G.topH - 16))
			holder.ZIndex = 8
		end
		holder.BackgroundColor3 = PANEL
		holder.BackgroundTransparency = 0.12
		Ui.new("UICorner", { CornerRadius = UDim.new(0, 16), Parent = holder })
		Ui.new("UIStroke", { Color = CARD_LINE, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = holder })
		holder.Parent = parent
	end

	-- Etapa final: título de presentación sobre el auto.
	if e.step == LAST then
		local hero = Ui.col({
			Ui.inline(string.upper(d.brand), { size = Ui.S.xs, weight = W.bold, color = ACCENT2 }),
			Ui.inline(d.name, { size = phone and 22 or 30, weight = W.heavy, name = "TituloPresentacion" }),
			Ui.inline(Catalog.TYPES[Catalog.base(d.baseId).type] .. " · modelo " .. Rules.year(g) .. " · " .. Util.money(c.unitCost) .. " por unidad", { size = Ui.S.sm, color = T.tx2 }),
		}, 2, { Name = "Presentacion", h = "C", Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromOffset(G.rect.x + G.rect.w / 2, G.topH + 14), Parent = parent })
		Ui.fadeIn(hero)
	end

	-- Cámara y herramientas sobre la vista (abajo del auto).
	local camLabel = "Ángulo"
	for _, cam in CAMS do
		if cam[1] == view.cam then
			camLabel = cam[2]
		end
	end
	local camBtn
	camBtn = Ui.button((phone and "" or "Cámara: ") .. camLabel, "default", function()
		local opts = {}
		for _, cam in CAMS do
			table.insert(opts, { cam[1], cam[2] .. "  (" .. cam[5] .. ")" })
		end
		App.dropdown(camBtn, opts, view.cam, function(id: any)
			Screen.setCam(id)
			App.forceRender()
		end)
	end, { small = true, icon = "cam", name = "Camaras" })
	local viewTools = Ui.row({
		camBtn,
		toolbarBtn("minus", nil, function()
			Screen.zoom(1.18)
		end, { name = "Alejar" }),
		toolbarBtn("plus", nil, function()
			Screen.zoom(0.85)
		end, { name = "Acercar" }),
		toolbarBtn("reset", nil, function()
			Screen.setCam("angulo")
		end, { name = "RestablecerBarra" }),
		toolbarBtn("compare", (not phone) and "Antes / ahora" or nil, Screen.toggleCompare, { pressed = e.compare, name = "AntesDespues" }),
		toolbarBtn("eyeoff", nil, Screen.toggleHide, { pressed = e.hideUI, kbd = (not phone) and "H" or nil, name = "OcultarInterfaz" }),
		(not phone) and toolbarBtn("cam", nil, Screen.capture, { name = "Captura" }) or nil,
		phone and toolbarBtn("chart", nil, function()
			e.statsOpen = not e.statsOpen
			App.forceRender()
		end, { pressed = e.statsOpen, name = "AbrirEstadisticas" }) or nil,
	}, 4, { Name = "HerramientasVista", Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, BackgroundColor3 = PANEL, BackgroundTransparency = 0.15, Corner = 12, Pad = 4 })
	viewTools.AnchorPoint = Vector2.new(0.5, 1)
	viewTools.Position = UDim2.fromOffset(G.rect.x + G.rect.w / 2, phone and (G.left.y - 6) or (App.vh - G.navH - 8))
	viewTools.Parent = parent
	if e.compare then
		local split = Ui.row({
			Ui.inline("Divisor", { size = Ui.S.xs }),
			Ui.slider(e.split, 0.1, 0.9, 0.01, function(v: number, _final: boolean)
				e.split = math.clamp(v, 0.1, 0.9)
				local bar = (parent :: any):FindFirstChild("Divisor")
				if bar then
					bar.Position = UDim2.fromOffset(App.vw * e.split - 1, G.topH)
				end
				local clip = view3d:FindFirstChild("RecorteAntes") :: Frame?
				if clip then
					clip.Size = UDim2.fromOffset(App.vw * e.split * App.scale(), App.vh * App.scale())
				end
			end, { width = 160, name = "Divisor" }),
		}, 8, { Name = "FilaDivisor", Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, BackgroundColor3 = PANEL, BackgroundTransparency = 0.15, Corner = 8, Pad = { 4, 10 } })
		split.AnchorPoint = Vector2.new(0.5, 1)
		split.Position = UDim2.fromOffset(G.rect.x + G.rect.w / 2, (phone and (G.left.y - 6) or (App.vh - G.navH - 8)) - 54)
		split.Parent = parent
	end

	-- Navegación inferior: salir, volver y siguiente (o finalizar en el resumen).
	local back = e.step > 1 and Ui.button("Volver", "default", function()
		Screen.goStep(e.step - 1)
	end, { kbd = (not phone) and "[" or nil, icon = "left", name = "VolverPaso" }) or nil
	local nextBtn
	if e.step < LAST then
		nextBtn = Ui.button("Siguiente: " .. STEPS[e.step + 1][2], "p", function()
			Screen.goStep(e.step + 1)
		end, { kbd = (not phone) and "]" or nil, icon = "right", iconAfter = true, name = "Siguiente" })
	else
		local why = Screen.finalizeCheck()
		nextBtn = Ui.button("Finalizar diseño", "p", Screen.finalize, { icon = "check", name = "FinalizarDiseno", disabled = why ~= nil, why = why })
	end
	local money = Ui.inline(Util.money(g.money), { size = Ui.S.sm, weight = W.bold, name = "Dinero" })
	App.live(function(gg: any)
		money.Text = Util.money(gg.money)
	end)
	local nav = Ui.row({
		Ui.button(phone and "" or "Salir del editor", "default", function()
			App.go("juego")
		end, { icon = "x", kbd = (not phone) and "Esc" or nil, name = "SalirEditor" }),
		(not phone) and Ui.row({ Ui.inline("Dinero", { size = Ui.S.xs, color = T.mut }), money }, 6, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY }) or nil,
		Ui.spacer(),
		(not phone) and Ui.inline("El borrador se guarda solo", { size = Ui.S.xs, color = T.mut2 }) or nil,
		back,
		nextBtn,
	}, 10, { Name = "NavegacionEditor", Size = UDim2.new(1, 0, 0, G.navH), AutomaticSize = Enum.AutomaticSize.None, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), BackgroundColor3 = PANEL, BackgroundTransparency = 0.05, Pad = { 0, 14 }, Parent = parent })
	nav.ZIndex = 3
end

return Screen
