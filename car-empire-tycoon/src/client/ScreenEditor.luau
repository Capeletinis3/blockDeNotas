--!strict
--[[
	Editor de vehículos (V3: Vehículo base → Rendimiento → Diseño → Revisión).
	El borrador vive en el cliente; al guardar, el servidor lo sanea, recalcula y cobra el desarrollo.
	Vista 3D: ViewportFrame con el modelo provisional (CarModel) en una ScreenGui propia, debajo de los paneles.
	Cámaras predefinidas, giro manual y zoom con límites, encuadre por dimensiones reales, comparación
	antes/después, puntos de piezas, deshacer/rehacer y protección de cambios sin guardar.
]]

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

local STEPS = { { 1, "Vehículo base" }, { 2, "Rendimiento" }, { 3, "Diseño" }, { 4, "Revisión" } }
local RAR = { ["Común"] = "cn", ["Rara"] = "cb", ["Épica"] = "cv", ["Legendaria"] = "cy" }
-- Cámaras predefinidas (V3: CAMS). yaw 0 = desde atrás; 180 = de frente.
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
		return game:GetService("HttpService"):JSONEncode({ d.baseId, d.paint, d.wheels, d.caliper, d.spoiler, d.body, d.interior })
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

local function recomputeDirty()
	local e = ed()
	-- Se compara con el último guardado; un proyecto nuevo, con cómo estaba al empezar (si no se tocó, salir no pregunta).
	local ref = e.saved or e.start
	e.dirty = e.orphan == true or not DesignCalc.sameSpec(ref, e.draft) or ref.name ~= e.draft.name
end

-- Aplica un cambio al borrador guardando el estado anterior para deshacer.
local function change(fn: (any) -> ())
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
	recomputeDirty()
	App.forceRender()
end
Screen.change = change

function Screen.undo()
	local e = ed()
	if not e or #e.undo == 0 then
		return
	end
	table.insert(e.redo, Util.deepCopy(e.draft))
	e.draft = table.remove(e.undo) :: any
	recomputeDirty()
	App.forceRender()
end

function Screen.redo()
	local e = ed()
	if not e or #e.redo == 0 then
		return
	end
	table.insert(e.undo, Util.deepCopy(e.draft))
	e.draft = table.remove(e.redo) :: any
	recomputeDirty()
	App.forceRender()
end

local function newEditor(draft: any, sourceId: string?, saved: any?, step: number?): any
	return {
		draft = draft, sourceId = sourceId, saved = saved, start = Util.deepCopy(draft), step = step or 1, cat = "motor",
		colorTarget = "primary", tab = "ext", dirty = false, undo = {}, redo = {}, compare = false, split = 0.5,
		hideUI = false, hotspots = true, sel = nil, typeFilter = "todos",
	}
end

local function findDesign(id: any): any
	for _, d in App.g.designs do
		if d.id == id then
			return d
		end
	end
	return nil
end

-- ¿Abrir con estos parámetros reemplazaría un borrador con cambios sin guardar?
function Screen.needsConfirm(params: any): boolean
	local e = ed()
	if not e or not e.dirty or not params or params.force then
		return false
	end
	if params.new or params.fresh or params.fromTemplate or params.newGenOf then
		return true
	end
	if params.designId and params.designId ~= e.sourceId then
		return true
	end
	return false
end

function Screen.enter(params: any)
	local g = App.g
	local e = ed()
	params = params or {}
	if params.designId then
		local d = findDesign(params.designId)
		if d and (not e or e.sourceId ~= d.id or params.force) then
			e = newEditor(Util.deepCopy(d), d.id, Util.deepCopy(d), 1)
		end
	elseif params.fromTemplate then
		local t = findDesign(params.fromTemplate)
		if t then
			local nd = Util.deepCopy(t)
			nd.id, nd.template, nd.version = nil, nil, 0
			nd.name = Util.truncateChars(string.gsub(nd.name, " %(plantilla%)$", ""), 18) .. " nuevo"
			e = newEditor(nd, nil, nil, 1)
		end
	elseif params.newGenOf then
		-- Nueva generación: parte del diseño anterior; al guardar toma el año actual y el número siguiente.
		local p = findDesign(params.newGenOf)
		if p and not p.template then
			local nd = Util.deepCopy(p)
			nd.id, nd.version = nil, 0
			e = newEditor(nd, nil, nil, 1)
			e.newGenOf = p.id
			e.dirty = true
		end
	elseif params.new or params.fresh or not e then
		local b = DesignCalc.firstBase(g)
		e = newEditor(DesignCalc.newDraft(g, b.id), nil, nil, 1)
	end
	if params.installPart and e then
		e.step = 2
		e.cat = params.installPart.cat
		e.sel = params.installPart.id
	end
	-- Si el proyecto que se editaba fue eliminado, el borrador pasa a ser un proyecto nuevo.
	if e.sourceId and not findDesign(e.sourceId) then
		e.sourceId, e.saved = nil, nil
		e.orphan = true
		e.dirty = true
		App.toast("aviso", "El proyecto original ya no existe: al guardar se crea uno nuevo.")
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

local function save(btn: any?, after: (() -> ())?)
	local e = ed()
	local r = App.request("saveDesign", { draft = e.draft, sourceId = e.sourceId, newGenOf = (e.sourceId == nil) and e.newGenOf or nil }, { button = btn })
	if r.ok then
		e.newGenOf = nil
		e.sourceId = r.designId
		e.draft.id = r.designId
		e.draft.version = r.version
		e.saved = Util.deepCopy(e.draft)
		e.orphan = nil
		e.dirty = false
		if after then
			after()
		else
			App.forceRender()
		end
	end
	-- Si falla, el borrador queda intacto y el mensaje del servidor explica el motivo.
	return r.ok
end
Screen.save = save

-- Cambios sin guardar: guardar, descartar o seguir editando.
function Screen.askUnsaved(proceed: () -> (), title: string?)
	local e = ed()
	App.openDialog("unsaved", {
		title = title or "Tenés cambios sin guardar",
		name = e and e.draft.name or "",
		pending = e and DesignCalc.devPending(App.g, e.draft) or 0,
		onSave = function(btn: any)
			save(btn, function()
				App.closeDialog()
				proceed()
			end)
		end,
		onDiscard = function()
			local cur = ed()
			if cur then
				if cur.saved then
					cur.draft = Util.deepCopy(cur.saved)
					cur.dirty = false
				else
					App.ui.editor = nil
				end
			end
			App.closeDialog()
			proceed()
		end,
	})
end

function Screen.askReplace(params: any)
	Screen.askUnsaved(function()
		local p = table.clone(params)
		p.force = true
		App.go("editor", p)
	end, "¿Abrir otro proyecto?")
end


-- Componentes ---------------------------------------------------------------------------------------
local function fmtStat(k: string, v: number): string
	if k == "accel" or k == "consumption" then
		return Util.num(v, 1)
	end
	return Util.num(v)
end

local GLASS = Color3.fromHex("#111319") -- rgba(17,19,25,.9)
local EDGE = Color3.fromHex("#2A2E39")
local RAR_PIPS = { ["Común"] = "◆", ["Rara"] = "◆◆", ["Épica"] = "◆◆◆", ["Legendaria"] = "◆◆◆◆" }
local TAG_LABEL = { combustion = "Combustión", electrico = "Eléctrico", offroad = "Todoterreno" }

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
local function camTool(id: string, label: string, key: string): TextButton
	local b = Ui.new("TextButton", {
		Name = "Camara_" .. id, Text = "", Size = UDim2.new(1, 0, 0, 40), Corner = 9, Pad = { 0, 12 },
		List = { dir = "H", gap = 8, v = "C" },
	}, {
		Ui.grow((function()
			local t = Ui.inline(label, { size = Ui.S.base, name = "Etiqueta" })
			return t
		end)()),
		Ui.kbd(key),
	})
	-- Ui.grow envuelve la etiqueta; se la deja con el nombre esperado por paintTool.
	local lab = b:FindFirstChild("Etiqueta", true) :: TextLabel?
	if lab then
		lab.Parent = b
		lab.LayoutOrder = 1
		local flex = Instance.new("UIFlexItem")
		flex.FlexMode = Enum.UIFlexMode.Fill
		flex.Parent = lab
		for _, c in b:GetChildren() do
			if c:IsA("Frame") and c.Name ~= "Tecla" and #c:GetChildren() == 1 then
				c:Destroy()
			end
		end
	end
	paintTool(b, view.cam == id)
	b.MouseEnter:Connect(function()
		if view.cam ~= id then
			b.BackgroundTransparency = 0.95
		end
	end)
	b.MouseLeave:Connect(function()
		paintTool(b, view.cam == id)
	end)
	b.Activated:Connect(function()
		Screen.setCam(id)
		local e = ed()
		if id == "interior" and e and e.step == 3 and e.tab ~= "int" then
			e.tab = "int"
			App.forceRender()
		end
	end)
	camButtons[id] = b
	return b
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

-- Tarjeta flotante con el fondo semitransparente del editor.
local function glass(children: { Instance? }, props: { [string]: any }): Frame
	local p = table.clone(props)
	p.BackgroundColor3 = p.BackgroundColor3 or Color3.fromHex("#0E1016")
	p.BackgroundTransparency = p.BackgroundTransparency or 0.08
	p.Stroke = p.Stroke or EDGE
	return Ui.new("Frame", p, children)
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
		recomputeDirty()
		App.forceRender()
	end
end

local function labeledSlider(label: string, valueText: string, slider: Instance): Frame
	return Ui.col({ Ui.row({ Ui.grow(Ui.inline(label, { size = Ui.S.xs, color = T.mut })), Ui.inline(valueText, { size = Ui.S.xs, weight = W.bold }) }, 6), slider }, 4)
end

-- Estadísticas (statsCard) --------------------------------------------------------------------------
local function statsCard(g: any, d: any): Frame
	local e = ed()
	local cur = DesignCalc.computeDesign(g, d)
	local prev = nil
	if e.step == 2 and e.sel and e.sel ~= d.parts[e.cat] then
		local t = Util.deepCopy(d)
		t.parts[e.cat] = e.sel
		prev = DesignCalc.computeDesign(g, t)
	end
	local rows: { Instance? } = {
		Ui.row({ Ui.grow(Ui.lbl("Estadísticas")), Ui.inline(prev and "vista previa de la pieza elegida" or "diseño actual", { size = Ui.S.xs, color = T.mut }) }, 8),
	}
	for _, s in Catalog.STAT_DEFS do
		local k, label, unit, dir, max = s[1], s[2], s[3], s[5], s[6]
		local v = cur[k]
		local nv = prev and prev[k] or v
		local dlt = Util.round((nv - v) * 10) / 10
		local good = (dir > 0 and dlt > 0) or (dir < 0 and dlt < 0)
		local pct = math.clamp((dir > 0 and nv / max or 1 - nv / max) * 100, 2, 100)
		local u = k == "consumption" and cur.consUnit or unit
		table.insert(rows, Ui.col({
			Ui.row({
				Ui.grow(Ui.text(label .. " <font size=\"11\" color=\"#6C7382\">" .. u .. "</font>", { size = 13, color = T.mut })),
				Ui.inline(fmtStat(k, nv), { size = 13, weight = W.bold }),
				dlt ~= 0 and Ui.inline((good and "▲ " or "▼ ") .. (dlt > 0 and "+" or "") .. fmtStat(k, dlt), { size = Ui.S.xs, weight = W.bold, color = good and T.gr or T.re2 }) or nil,
			}, 6),
			(Ui.bar(pct, dlt ~= 0 and (good and T.gr or T.re) or nil)),
		}, 4, { Pad = { 3, 0 } }))
	end
	table.insert(rows, Ui.text("Barras: más llena = mejor. En aceleración, frenado, consumo y peso, un número menor es mejor.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.45 }))
	return glass({ Ui.col(rows, 6) }, { Name = "Estadisticas", Size = UDim2.fromOffset(300, 0), AutomaticSize = Enum.AutomaticSize.Y, Corner = 14, Pad = { 12, 14 } })
end

-- Cabecera y pie del panel (edHeader / edFooter) ---------------------------------------------------------
local function panelHeader(e: any, d: any, title: string): Frame
	local status = e.sourceId and (e.dirty and "Cambios sin guardar" or "Guardado") or "Borrador"
	local statusKind = status == "Guardado" and "cg" or (status == "Borrador" and "cn" or "cy")
	local progress = {}
	for n = 1, 4 do
		table.insert(progress, Ui.grow(Ui.new("Frame", { Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = n < e.step and T.gr or (n == e.step and T.vi or Color3.fromHex("#292D38")), BackgroundTransparency = 0, Corner = 2 }), { Size = UDim2.new(0, 0, 0, 3) }))
	end
	return Ui.col({
		Ui.row({
			Ui.grow(Ui.lbl("Diseñar · Paso " .. e.step .. " de 4")),
			Ui.button("", "default", function()
				App.openDialog("help", { screen = "editor" })
			end, { small = true, icon = "help", iconSize = 16, name = "AyudaEditor" }),
			Ui.button("", "default", function()
				App.go("juego")
			end, { small = true, icon = "x", iconSize = 16, name = "CerrarEditor" }),
		}, 8),
		Ui.row({
			Ui.grow(Ui.text(title, { size = Ui.S.h1, weight = W.bold })),
			Ui.inline(d.name, { size = Ui.S.sm, color = T.mut }),
			Ui.chip("● " .. status, statusKind),
		}, 10),
		Ui.row(progress, 4),
	}, 10, { Name = "Cabecera", Pad = { 14, 18, 12, 18 } })
end

local function panelFooter(g: any, e: any, d: any, c: any, next: Instance?): Frame
	local pend = DesignCalc.devPending(g, d)
	local money = Ui.inline(Util.money(g.money), { size = Ui.S.sm, weight = W.bold })
	App.live(function(gg: any)
		money.Text = Util.money(gg.money)
	end)
	local back
	if e.step > 1 then
		back = Ui.button("Volver", "default", function()
			Screen.goStep(e.step - 1)
		end, { kbd = "[", flex = 1, name = "VolverPaso" })
	else
		back = Ui.button("Salir", "default", function()
			App.go("juego")
		end, { kbd = "Esc", flex = 1, name = "SalirEditor" })
	end
	next = next or Ui.button("Siguiente", "p", function()
		Screen.goStep(e.step + 1)
	end, { kbd = "]", flex = 2, name = "Siguiente" })
	local foot = Ui.col({
		Ui.between("Desarrollo pendiente <font size=\"11\">(se paga una vez al guardar)</font>", pend > 0 and Util.money(pend) or "$0", { color = pend > 0 and T.or_ or T.gr }),
		Ui.between("Fabricación por unidad <font size=\"11\">(se paga al fabricar)</font>", Util.money(c.unitCost)),
		Ui.row({ Ui.grow(Ui.text("Dinero disponible", { size = Ui.S.sm, color = T.mut })), money }, 10),
		pend > g.money and Ui.note("y", "No alcanza el dinero para pagar el desarrollo al guardar. Elegí piezas más simples o conseguí fondos.") or nil,
		Ui.row({ back, next }, 10),
	}, 9, { Name = "Pie", BackgroundColor3 = Color3.fromHex("#0D0F14"), BackgroundTransparency = 0, Pad = { 12, 18, 14, 18 } })
	return Ui.col({ Ui.new("Frame", { Name = "BordePie", Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Color3.fromHex("#1F222B"), BackgroundTransparency = 0 }), foot }, 0)
end

function Screen.goStep(n: number)
	local e = ed()
	n = math.clamp(n, 1, 4)
	if n > 1 and Util.charCount(Util.trim(e.draft.name)) < 2 then
		App.toast("error", "Poné un nombre al proyecto antes de seguir.")
		return
	end
	e.step = n
	e.sel = nil
	App.forceRender()
end

-- Paso 1: vehículo base (panelBase) ----------------------------------------------------------------------
local function baseCard(g: any, d: any, x: any): TextButton
	local block = DesignCalc.baseAvailable(g, x)
	local on = d.baseId == x.id
	local t = DesignCalc.newDraft(g, x.id)
	local st = DesignCalc.computeDesign(g, t)
	local paid = Util.contains(g.devPaid, "base:" .. x.id)
	local thumb = Ui.ico("car", block and Color3.fromHex("#666666") or T.tx, block and Color3.fromHex("#22252E") or Color3.fromHex(t.paint.primary), 38, { w = 56, h = 38, radius = 8, iconSize = 22 })
	if not block then
		local gr = Instance.new("UIGradient")
		gr.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromHex("#11131A"))
		gr.Rotation = 35
		gr.Parent = thumb
	end
	local tags = {}
	for _, tg in x.tags do
		table.insert(tags, TAG_LABEL[tg] or tg)
	end
	local card = Ui.new("TextButton", {
		Name = "Base_" .. x.id, Text = "", BackgroundColor3 = on and T.vi or T.p2, BackgroundTransparency = on and 0.9 or 0,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Corner = 12, Stroke = on and { T.vi, 2 } or T.line2, Pad = 12,
		List = { dir = "H", gap = 12, v = "T" },
	}, {
		thumb,
		Ui.grow(Ui.col({
			Ui.row({ Ui.grow(Ui.text(x.name, { size = Ui.S.base, weight = W.bold })), Ui.chip(RAR_PIPS[x.rarity] .. " " .. x.rarity, RAR[x.rarity]) }, 10),
			Ui.text(Catalog.TYPES[x.type] .. "   Desde " .. tostring(x.year or 1970) .. "   Licencia " .. (paid and "<font color=\"#42E58D\"><b>pagada</b></font>" or ("<font color=\"#F5F7FA\"><b>" .. Util.money(x.dev) .. "</b></font>")) .. "   Base/u " .. Util.money(x.unit), { size = Ui.S.xs, color = T.mut }),
			Ui.text(st.hp .. " hp   0–100 en " .. Util.num(st.accel, 1) .. " s   Manejo " .. st.handling .. "   " .. table.concat(tags, " · "), { size = Ui.S.xs, color = T.mut }),
			block and Ui.why("🔒 " .. block) or nil,
		}, 5)),
	})
	if block then
		local stroke = card:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = 0.2
		end
	end
	card.Activated:Connect(function()
		if block then
			App.toast("error", x.name .. ": " .. block)
			return
		end
		if d.baseId ~= x.id then
			change(function(dd)
				DesignCalc.changeBase(g, dd, x.id)
			end)
		end
	end)
	return card
end

local function panelBase(g: any, d: any, body: Instance)
	local e = ed()
	local nameBox = Ui.input(d.name, "Nombre del proyecto", function(text: string)
		local t = Util.truncateChars(Util.trim(text), 24)
		if t ~= d.name then
			change(function(dd)
				dd.name = t
			end)
		end
	end, { name = "NombreProyecto" })
	Ui.col({ Ui.fl("Nombre del proyecto"), nameBox }, 6).Parent = body
	local company = g.company.name
	local brands = { { company, company }, { company .. " Sport", company .. " Sport" }, { company .. " Lux", company .. " Lux" } }
	-- Año de modelo y generación: los fija el servidor al guardar (año actual; nueva generación = la siguiente).
	local year = Rules.year(g)
	local genText
	if e.newGenOf then
		local parent = nil
		for _, x in g.designs do
			if x.id == e.newGenOf then
				parent = x
			end
		end
		genText = year .. " · nueva generación" .. (parent and (" de «" .. parent.name .. "» (" .. tostring(parent.generation) .. ")") or "")
	elseif e.sourceId then
		genText = tostring(d.generation) .. " · nueva versión"
	else
		genText = DesignCalc.generationLabel(year, 1)
	end
	local genBox = Ui.col({ Ui.fl("Año de modelo y generación"), Ui.text(genText, { size = Ui.S.sm, weight = W.bold, name = "Generacion" }), Ui.text("Se fija al guardar: año en curso.", { size = Ui.S.xs, color = T.mut }) }, 4)
	local b = Catalog.base(d.baseId)
	local offroad = Util.contains(b.tags, "offroad")
	local chassis = {}
	for _, k in Catalog.CHASSIS_ORDER do
		local ch = Catalog.CHASSIS[k]
		local blocked = ch.need == "offroad" and not offroad
		table.insert(chassis, { k, k .. (ch.unit > 0 and (" (+" .. Util.money(ch.unit) .. "/u)") or "") .. (blocked and " · solo SUV/pickup" or ""), blocked })
	end
	local segs = {}
	for _, k in Catalog.SEGMENT_ORDER do
		table.insert(segs, { k, k .. " · precio ×" .. Util.num(Catalog.SEGMENTS[k].price, 2) })
	end
	local function sel(label: string, value: any, options: { any }, field: string): Frame
		return Ui.col({ Ui.fl(label), Ui.select(value, options, function(v: any)
			change(function(dd)
				dd[field] = v
			end)
		end, { fill = true, name = "Lista_" .. field }) }, 6)
	end
	Ui.grid({
		sel("Marca", d.brand, brands, "brand"),
		genBox,
		sel("Chasis", d.chassis, chassis, "chassis"),
		sel("Segmento de mercado", d.segment, segs, "segment"),
	}, 2, nil, 12).Parent = body
	local objs = {}
	for _, k in Catalog.OBJECTIVE_ORDER do
		table.insert(objs, { k, k })
	end
	Ui.col({
		Ui.text("<b>Objetivo del vehículo</b> <font size=\"11\" color=\"#A3AAB8\">(define qué estadísticas pesan en el atractivo y las ventas)</font>", { size = Ui.S.fl, color = T.tx2 }),
		optRow(nil, objs, d.objective, function(v)
			change(function(dd)
				dd.objective = v
			end)
		end, { columns = 3, height = 40, name = "Objetivo" }),
	}, 8).Parent = body
	-- Marcas debajo del deslizador, repartidas como justify-content: space-between.
	local tickRow = Ui.new("Frame", { Name = "Marcas", Size = UDim2.new(1, 0, 0, 16) })
	local nt = #Catalog.QUALITY_TIERS
	for i, q in Catalog.QUALITY_TIERS do
		local t = Ui.inline(q, { size = Ui.S.xs, color = T.mut })
		local a = (i - 1) / (nt - 1)
		t.AnchorPoint = Vector2.new(a, 0)
		t.Position = UDim2.fromScale(a, 0)
		t.Parent = tickRow
	end
	Ui.col({
		Ui.row({ Ui.grow(Ui.fl("Calidad de terminación")), Ui.chip(Catalog.QUALITY_TIERS[d.quality + 1] .. " · +" .. Util.money(d.quality * 700) .. "/u · +" .. d.quality * 3 .. " calidad", "cv") }, 10),
		Ui.slider(d.quality, 0, 5, 1, function(v: number, final: boolean)
			liveEdit(function(dd)
				dd.quality = math.clamp(Util.round(v), 0, 5)
			end, final)
		end, { name = "Calidad" }),
		tickRow,
	}, 6).Parent = body

	local filt = e.typeFilter or "todos"
	local typeOpts = { { "todos", "Todos" } }
	for _, k in Catalog.TYPE_ORDER do
		table.insert(typeOpts, { k, Catalog.TYPES[k] })
	end
	local available = 0
	for _, x in Catalog.BASES do
		if DesignCalc.baseAvailable(g, x) == nil then
			available += 1
		end
	end
	local cards: { Instance? } = {
		Ui.row({ Ui.grow(Ui.lbl("Modelo base")), Ui.inline(available .. " de " .. #Catalog.BASES .. " disponibles", { size = Ui.S.xs, color = T.mut }) }, 8),
		optRow(nil, typeOpts, filt, function(v)
			e.typeFilter = v
			App.forceRender()
		end, { height = 34, name = "Tipo" }),
	}
	local any = false
	for _, x in Catalog.BASES do
		if filt == "todos" or x.type == filt then
			any = true
			table.insert(cards, baseCard(g, d, x))
		end
	end
	if not any then
		table.insert(cards, Ui.empty(nil, "No hay modelos de ese tipo."))
	end
	Ui.col(cards, 8).Parent = body
end

-- Paso 2: rendimiento (panelPerf) ---------------------------------------------------------------------
local function partCard(g: any, d: any, e: any, p: any, selId: string): TextButton
	local cat = e.cat
	local b = Catalog.base(d.baseId)
	local bl = DesignCalc.partBlock(g, d, p)
	local on = p.id == selId
	local eq = p.id == d.parts[cat]
	local paid = Util.contains(g.devPaid, cat .. ":" .. p.id)
	local devText
	if b.defaults[cat] == p.id then
		devText = "<font color=\"#42E58D\"><b>incluido en la licencia</b></font>"
	elseif p.proto > 0 then
		devText = paid and "<font color=\"#42E58D\"><b>pagado</b></font>" or ("<font color=\"#F5F7FA\"><b>" .. Util.money(p.proto) .. "</b></font>")
	else
		devText = "<font color=\"#42E58D\"><b>sin costo</b></font>"
	end
	local chips: { Instance? } = {
		eq and Ui.chip("✓ Equipada", "cb") or (bl and Ui.chip("🔒 Bloqueada", "cy") or Ui.chip("● Disponible", "cg")),
		Ui.chip("Desde " .. tostring(p.year or 1970), "cn"),
	}
	local card = Ui.new("TextButton", {
		Name = "Pieza_" .. p.id, Text = "", BackgroundColor3 = on and T.vi or T.p2, BackgroundTransparency = on and 0.9 or 0,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Corner = 12, Stroke = on and { T.vi, 2 } or T.line2, Pad = 12,
		List = { dir = "H", gap = 12, v = "T" },
	}, {
		Ui.ico(bl and "lock" or "wrench", bl and Color3.fromHex("#666666") or T.vi2, T.input, 46, { radius = 10, iconSize = 22, stroke = Color3.fromHex("#23262F") }),
		Ui.grow(Ui.col({
			Ui.row({ Ui.grow(Ui.text(p.name, { size = Ui.S.base, weight = W.bold })), Ui.chip(p.rarity, RAR[p.rarity]) }, 10),
			Ui.row(chips, 5, { wrap = true }),
			Ui.text(p.desc, { size = Ui.S.xs, color = T.mut }),
			Ui.row({
				Ui.grow(Ui.text("Desarrollo: " .. devText, { size = Ui.S.xs, color = T.mut })),
				Ui.inline("Fabricación: <font color=\"#F5F7FA\"><b>+" .. Util.money(p.unit) .. "/u</b></font>", { size = Ui.S.xs, color = T.mut }),
			}, 8),
			bl and Ui.why(bl) or nil,
		}, 5)),
	})
	card.Activated:Connect(function()
		e.sel = p.id
		App.forceRender()
	end)
	return card
end

local function panelPerf(g: any, d: any, body: Instance): Instance
	local e = ed()
	local cat = e.cat
	local cats = {}
	for _, c in Catalog.CATS do
		table.insert(cats, Ui.opt(c[2], cat == c[1], function()
			e.cat = c[1]
			e.sel = nil
			App.forceRender()
		end, { height = 36, size = 12, name = "Categoria_" .. c[1] }))
	end
	section("Categoría", { Ui.grid(cats, 4, nil, 8) }, 8).Parent = body
	local list = Catalog.partsOf(cat)
	local current = Catalog.part(cat, d.parts[cat])
	local selId = e.sel or d.parts[cat]
	local selP = Catalog.part(cat, selId)
	local cards: { Instance? } = {
		Ui.row({
			Ui.grow(Ui.lbl(Catalog.catLabel(cat) .. " · " .. #list .. " opciones")),
			Ui.inline("Instalada: <font color=\"#F5F7FA\"><b>" .. (current and current.name or "—") .. "</b></font>", { size = Ui.S.xs, color = T.mut }),
		}, 8),
	}
	for _, p in list do
		table.insert(cards, partCard(g, d, e, p, selId))
	end
	Ui.col(cards, 8).Parent = body

	local installed = selP == nil or selP.id == d.parts[cat]
	local block = selP and DesignCalc.partBlock(g, d, selP)
	if selP and not installed then
		local b = Catalog.base(d.baseId)
		local t = Util.deepCopy(d)
		t.parts[cat] = selP.id
		local a, n = DesignCalc.computeDesign(g, d), DesignCalc.computeDesign(g, t)
		local chips = {}
		for _, s in Catalog.STAT_DEFS do
			local k, label, unit, dir = s[1], s[2], s[3], s[5]
			local dl = Util.round((n[k] - a[k]) * 10) / 10
			if dl ~= 0 then
				local good = (dir > 0 and dl > 0) or (dir < 0 and dl < 0)
				local u = k == "consumption" and "" or (string.gsub(unit, "índice 0–100", ""))
				table.insert(chips, Ui.chip((dl > 0 and "+" or "") .. fmtStat(k, dl) .. " " .. u .. " " .. string.lower(label), good and "cg" or "cr"))
			end
		end
		local du = n.unitCost - a.unitCost
		table.insert(chips, Ui.chip((du >= 0 and "+" or "") .. Util.money(du) .. " por unidad", du > 0 and "cy" or "cg"))
		local paid = Util.contains(g.devPaid, cat .. ":" .. selP.id)
		local stock = DesignCalc.partInStock(g, cat, selP.id)
		local noteText
		if paid or selP.proto == 0 or b.defaults[cat] == selP.id then
			noteText = "Su desarrollo ya está pagado o incluido: instalarla no cuesta nada extra."
		elseif stock then
			noteText = "Usarás una pieza de tu inventario en lugar de pagar el desarrollo."
		else
			noteText = "El desarrollo (" .. Util.money(selP.proto) .. ") se paga una sola vez al guardar el diseño. Cambiar de pieza antes de guardar no cobra nada."
		end
		local compare = Ui.card({
			Ui.grow(Ui.col({ Ui.inline("ACTUAL", { size = Ui.S.xs, color = T.mut }), Ui.text(current and current.name or "—", { size = Ui.S.sm, weight = W.bold }) }, 4, { Pad = 12 })),
			Ui.new("Frame", { Size = UDim2.new(0, 1, 0, 52), BackgroundColor3 = Color3.fromHex("#23262F"), BackgroundTransparency = 0 }),
			Ui.grow(Ui.col({ Ui.inline("ELEGIDA", { size = Ui.S.xs, color = Color3.fromHex("#C4BDFF") }), Ui.text(selP.name, { size = Ui.S.sm, weight = W.bold }) }, 4, { Pad = 12, BackgroundColor3 = T.vi, BackgroundTransparency = 0.92 })),
		}, { dir = "H", gap = 0, pad = 0, name = "Comparacion" })
		compare.ClipsDescendants = true
		section("Comparación con la pieza instalada", {
			compare,
			Ui.row(chips, 6, { wrap = true }),
			block and Ui.note("y", block) or Ui.note("b", noteText),
		}, 8).Parent = body
	end
	if installed then
		return Ui.button("Siguiente", "p", function()
			Screen.goStep(3)
		end, { kbd = "]", flex = 2, name = "Siguiente" })
	elseif block then
		return Ui.button("No se puede instalar", "default", nil, { disabled = true, why = block, flex = 2, icon = "lock", name = "Instalar" })
	end
	return Ui.button("Instalar en el prototipo", "p", function()
		local p = selP :: any
		change(function(dd)
			dd.parts[cat] = p.id
		end)
		e.sel = nil
		local paid = Util.contains(g.devPaid, cat .. ":" .. p.id)
		local stock = DesignCalc.partInStock(g, cat, p.id)
		App.toast("ok", p.name .. " instalada en el prototipo. " .. ((p.proto > 0 and not paid) and (stock and "Usará la pieza de tu inventario al guardar." or ("Desarrollo de " .. Util.money(p.proto) .. " se cobra al guardar.")) or "Sin costo de desarrollo."))
		App.forceRender()
	end, { flex = 2, icon = "wrench", name = "Instalar" })
end

-- Paso 3: diseño (panelDesign) -----------------------------------------------------------------------------
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

local function designTabs(e: any): Frame
	local row = Ui.row({}, 18)
	for _, t in { { "ext", "Exterior" }, { "int", "Interior" } } do
		local on = (e.tab or "ext") == t[1]
		local b = Ui.new("TextButton", { Name = "Zona_" .. t[1], Text = "", Size = UDim2.fromOffset(0, 44), AutomaticSize = Enum.AutomaticSize.X }, {
			Ui.inline(t[2], { size = 15, weight = W.semi, color = on and T.tx or T.mut }),
			on and Ui.new("Frame", { Name = "Subrayado", BackgroundColor3 = T.vi, BackgroundTransparency = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 2), ZIndex = 2 }) or nil,
		})
		local lab = b:FindFirstChildOfClass("TextLabel")
		if lab then
			lab.Size = UDim2.new(0, 0, 1, 0)
			lab.AutomaticSize = Enum.AutomaticSize.X
		end
		b.Activated:Connect(function()
			e.tab = t[1]
			if t[1] == "int" then
				Screen.setCam("interior")
			elseif view.cam == "interior" then
				Screen.setCam("angulo")
			end
			App.forceRender()
		end)
		b.Parent = row
	end
	return Ui.new("Frame", { Name = "Zonas", Size = UDim2.new(1, 0, 0, 44) }, {
		Ui.new("Frame", { Name = "Linea", BackgroundColor3 = T.line2, BackgroundTransparency = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 1) }),
		row,
	})
end

local function panelDesign(g: any, d: any, body: Instance)
	local e = ed()
	designTabs(e).Parent = body
	if (e.tab or "ext") == "int" then
		Ui.note("b", "Usá la cámara <b>Interior</b> para ver asientos, tapizado, volante, tablero e iluminación.").Parent = body
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
		return
	end

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

	local bodyRows: { Instance? } = {
		Ui.card({
			Ui.grow(Ui.col({ Ui.text("Alerón trasero", { size = Ui.S.sm, weight = W.bold }), Ui.text("+3 de manejo, −4 km/h de velocidad máxima, +" .. Util.money(600) .. "/u", { size = Ui.S.xs, color = T.mut }) }, 2)),
			Ui.toggle(d.spoiler, function()
				change(function(dd)
					dd.spoiler = not dd.spoiler
				end)
			end),
		}, { dir = "H", v = "C", gap = 10, name = "Aleron" }),
	}
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

-- Paso 4: revisión (panelReview) -----------------------------------------------------------------------------
local function panelReview(g: any, d: any, c: any, body: Instance): Instance
	local e = ed()
	local b = Catalog.base(d.baseId)
	local items = DesignCalc.devItems(g, d)
	local pend = DesignCalc.devPending(g, d)
	local saved = e.sourceId ~= nil and not e.dirty
	local margin = c.price - c.unitCost
	local est = Rules.designSalesEstimate(g, c, d, c.price)
	local paintName = Catalog.colorName(Catalog.PAINTS, d.paint.primary) or d.paint.primary
	Ui.card({
		Ui.text(d.name, { size = 17, weight = W.bold }),
		Ui.text(d.brand .. " · " .. b.name .. " (" .. Catalog.TYPES[b.type] .. ") · " .. tostring(d.generation) .. " · " .. d.chassis .. " · " .. d.segment .. " · objetivo " .. string.lower(d.objective), { size = Ui.S.sm, color = T.mut }),
		Ui.text("Pintura " .. paintName .. " " .. string.lower(d.paint.finish) .. " · secundario " .. d.paint.secondary .. " · llantas " .. d.wheels.size .. "″ · " .. (d.spoiler and "con alerón" or "sin alerón") .. " · calidad " .. Catalog.QUALITY_TIERS[d.quality + 1], { size = Ui.S.sm, color = T.mut }),
	}, { gap = 4, name = "Resumen" }).Parent = body
	section("Economía del modelo", {
		Ui.grid({
			(Ui.kv("Fabricación por unidad", Util.money(c.unitCost))),
			(Ui.kv("Precio recomendado", Util.money(c.price))),
			(Ui.kv("Margen por unidad", (margin >= 0 and "▲ " or "▼ ") .. Util.money(margin), { color = margin >= 0 and T.gr or T.re2 })),
			(Ui.kv("Ventas estimadas", Util.num(est.rate, 1) .. " por minuto", { color = T.gr, sub = "al precio recomendado, hoy" })),
			(Ui.kv("Atractivo", Util.round(est.appeal) .. " (el mercado espera " .. Util.round(est.baseline) .. ")", { color = est.appeal >= est.baseline and T.gr or T.ye })),
			(Ui.kv("Calidad", c.quality .. " / 100")),
		}, 2, nil, 10),
	}, 8).Parent = body
	local devRows: { Instance? } = {}
	for _, it in items do
		table.insert(devRows, Ui.line(it.label, it.paid and "Pagado" or (it.stock and "Pieza en inventario" or Util.money(it.cost)), { size = Ui.S.sm, color = (it.paid or it.stock) and T.gr or T.tx }))
	end
	table.insert(devRows, Ui.line("<b>Pendiente</b>", Util.money(pend), { border = false, color = pend > 0 and T.or_ or T.gr }))
	section("Desarrollo (pago único al guardar)", { Ui.card(devRows, { gap = 0, pad = { 4, 12 } }) }, 8).Parent = body
	local statRows = {}
	for _, s in Catalog.STAT_DEFS do
		local k = s[1]
		table.insert(statRows, Ui.between(s[2], fmtStat(k, c[k]) .. " <font size=\"11\" color=\"#A3AAB8\">" .. (k == "consumption" and c.consUnit or (string.gsub(s[3], "índice 0–100", "/100"))) .. "</font>"))
	end
	section("Estadísticas finales", { Ui.card({ Ui.grid(statRows, 2, nil, 8) }, { pad = 12 }) }, 8).Parent = body
	local partRows = {}
	for _, cat in Catalog.CATS do
		local p = Catalog.part(cat[1], d.parts[cat[1]])
		table.insert(partRows, Ui.line(cat[2], p and p.name or "—", { size = Ui.S.sm, leftColor = T.mut, weight = W.med }))
	end
	section("Piezas instaladas", { Ui.card(partRows, { gap = 0, pad = { 4, 12 } }) }, 8).Parent = body
	local warns = {}
	if c.comfort < 50 and (d.objective == "Familiar" or d.objective == "Lujo") then
		table.insert(warns, "La comodidad (" .. c.comfort .. ") es baja para un objetivo " .. string.lower(d.objective) .. ".")
	end
	if c.hp < 200 and (d.objective == "Deportivo" or d.objective == "Competición") then
		table.insert(warns, "Con " .. c.hp .. " hp va a costar convencer a clientes que buscan potencia.")
	end
	if margin < c.unitCost * 0.2 then
		table.insert(warns, "El margen por unidad es bajo: al lanzar el lote podés subir el precio, o bajá costos.")
	end
	if est.appeal < est.baseline then
		table.insert(warns, "El atractivo (" .. Util.round(est.appeal) .. ") está por debajo de lo que espera el mercado en " .. Rules.year(g) .. " (" .. Util.round(est.baseline) .. "): va a vender lento frente a los rivales.")
	end
	if #warns > 0 then
		local nodes = {}
		for _, w in warns do
			table.insert(nodes, Ui.note("y", w))
		end
		section("Advertencias", nodes, 8).Parent = body
	end
	local tpl
	tpl = Ui.button("Guardar como plantilla", "default", function()
		App.request("saveDesign", { draft = e.draft, template = true }, { button = tpl })
	end, { small = true, name = "GuardarPlantilla" })
	section("Acciones", {
		Ui.grid({
			tpl,
			Ui.button("Probar el vehículo", "default", function()
				App.openDialog("testDrive", {})
			end, { small = true, name = "ProbarVehiculo" }),
			Ui.button("Lanzar lote", "p", function()
				App.openDialog("lot", { designId = e.sourceId, wide = true })
			end, { small = true, disabled = not saved, why = "Guardá el diseño primero", name = "LanzarLote" }),
			Ui.button("Cancelar cambios", "d", function()
				App.openDialog("confirm", {
					title = "¿Descartar los cambios?",
					body = e.saved and "El proyecto vuelve al último guardado." or "El proyecto vuelve a cómo estaba al empezar.",
					okLabel = "Descartar",
					danger = true,
					onOk = function()
						e.draft = Util.deepCopy(e.saved or e.start)
						table.clear(e.undo)
						table.clear(e.redo)
						recomputeDirty()
						App.forceRender()
					end,
				})
			end, { small = true, disabled = not e.dirty and e.sourceId ~= nil, why = "No hay cambios", name = "CancelarCambios" }),
		}, 2, nil, 8),
		not saved and Ui.text("Para lanzar un lote, primero guardá el diseño.", { size = Ui.S.xs, color = T.mut }) or nil,
		saved and Ui.text("El lote elige cuántas unidades fabricar y a qué precio venderlas.", { size = Ui.S.xs, color = T.mut }) or nil,
	}, 8).Parent = body
	local sb
	sb = Ui.button((e.sourceId and "Guardar cambios" or "Guardar diseño") .. (pend > 0 and (" · " .. Util.money(pend)) or ""), "p", function()
		save(sb)
	end, { flex = 2, icon = "check", name = "GuardarDiseno", disabled = saved or pend > g.money, why = saved and "No hay cambios para guardar" or "Fondos insuficientes" })
	return sb
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
		local before = e.saved or e.start
		local bsig = visualSig(before)
		if bsig ~= compareSig or not compareModel then
			compareSig = bsig
			compareModel = setModel(compareWorld, compareModel, before)
		end
	end
end

-- Geometría de la pantalla (editorLayout de la V3): barra superior, panel, controles inferiores y el
-- rectángulo libre donde se encuadra el auto.
local function geometry(e: any): any
	local Wd, Hd = App.vw, App.vh
	local phone = App.isPhone()
	local landscape = Wd > Hd
	local G = { phone = phone, landscape = landscape, topH = phone and 56 or 64 }
	if phone then
		if landscape then
			local pw = math.min(Wd * 0.46, 420)
			G.panel = { x = Wd - pw, y = 56, w = pw, h = Hd - 56 }
			G.bottom = { l = 8, r = pw + 8, b = 8 }
		else
			G.panel = { x = 0, y = Hd * 0.5, w = Wd, h = Hd * 0.5 }
			G.bottom = { l = 8, r = 8, b = Hd * 0.5 + 8 }
		end
	else
		local pw = Wd <= 1100 and 380 or 440
		G.panel = { x = Wd - 14 - pw, y = 78, w = pw, h = Hd - 92 }
		G.bottom = { l = 218, r = pw + 28, b = 16 }
	end
	G.statsShown = not phone and (e.step == 2 or e.step == 3)
	-- Rectángulo libre
	local l, t, r, b = 0, 0, Wd, Hd
	if not e.hideUI then
		t = G.topH
		if phone and not landscape then
			b = math.min(b, G.panel.y)
		else
			r = math.min(r, G.panel.x)
		end
		local controls = 44 + 10 + 48 + (e.compare and 42 or 0)
		b = math.min(b, Hd - G.bottom.b - controls)
		if not phone then
			l = G.statsShown and 518 or 204
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
	hotspotLayer.Visible = e.hotspots and not e.hideUI and view.cam ~= "interior"
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
		-- Como el .tip de la V3: el nombre aparece al pasar el puntero.
		b.MouseEnter:Connect(function()
			tip.Visible = true
		end)
		b.MouseLeave:Connect(function()
			tip.Visible = false
		end)
		b.Activated:Connect(function()
			e.step = h.step
			if h.cat then
				e.cat = h.cat
			end
			if h.tab then
				e.tab = h.tab
			end
			e.sel = nil
			App.forceRender()
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
		App.toast("info", "Izquierda: " .. (e.saved and "último guardado" or "inicio del proyecto") .. " · derecha: actual. Mové el divisor.")
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

-- Nuevo proyecto (newProject de la V3): si hay cambios sin guardar, se confirma antes.
function Screen.newProject()
	local function doIt()
		App.closeAllDialogs()
		local b = DesignCalc.firstBase(App.g)
		App.ui.editor = newEditor(DesignCalc.newDraft(App.g, b.id), nil, nil, 1)
		if App.ui.route == "editor" then
			App.forceRender()
		else
			App.go("editor")
		end
	end
	local e = ed()
	if e and e.dirty then
		App.openDialog("confirm", {
			title = "¿Descartar el proyecto actual?",
			body = "«" .. e.draft.name .. "» tiene cambios sin guardar.",
			okLabel = "Descartar y empezar",
			danger = true,
			onOk = doIt,
		})
	else
		doIt()
	end
end

-- Construcción ---------------------------------------------------------------------------------------------
function Screen.build(parent: Instance)
	local g = App.g
	if not ed() then
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

	-- Comparación: rótulos y barra divisoria
	if e.compare then
		Ui.new("Frame", { Name = "Divisor", Position = UDim2.fromOffset(App.vw * e.split - 1, G.topH), Size = UDim2.new(0, 3, 1, -G.topH), BackgroundColor3 = T.tx, BackgroundTransparency = 0, Parent = parent })
		local function tag(text: string, color: Color3): TextLabel
			return Ui.new("TextLabel", {
				Text = text, TextSize = 12, Weight = W.heavy, TextColor3 = color, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X,
				BackgroundColor3 = T.p1, BackgroundTransparency = 0, Corner = 7, Stroke = T.line, Pad = { 0, 10 },
			})
		end
		local before = tag("ANTES · " .. (e.saved and "último guardado" or "inicio del proyecto"), T.tx)
		before.Name = "RotuloAntes"
		before.Position = UDim2.fromOffset(24, 90)
		before.Parent = parent
		local after = tag("DESPUÉS · actual", T.gr)
		after.Name = "RotuloDespues"
		after.AnchorPoint = Vector2.new(1, 0)
		after.Position = UDim2.new(1, -(phone and 8 or 480), 0, 90)
		after.Parent = parent
	end

	if not e.hideUI then
		-- Barra superior (.ed-top)
		local status = e.sourceId and ("Diseño guardado v" .. tostring(d.version or 1) .. (e.dirty and " · cambios sin guardar" or "")) or "Proyecto nuevo sin guardar"
		local money = Ui.inline(Util.money(g.money), { size = Ui.S.sm, weight = W.bold })
		App.live(function(gg: any)
			money.Text = Util.money(gg.money)
		end)
		local top = Ui.row({
			Ui.grow(phone and Ui.new("Frame", { Size = UDim2.new(0, 0, 0, 1) }) or Ui.col({
				Ui.text("Diseñar un auto", { size = Ui.S.h1, weight = W.bold }),
				Ui.text(d.name .. " · " .. Catalog.TYPES[Catalog.base(d.baseId).type] .. " · " .. status, { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			(not phone) and Ui.row({ Ui.new("Frame", { Size = UDim2.fromOffset(10, 10), BackgroundColor3 = T.gr, BackgroundTransparency = 0, Corner = 5 }), money }, 6, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY }) or nil,
			(not phone) and Ui.button("Deshacer", "q", Screen.undo, { small = true, icon = "undo", iconSize = 16, kbd = "Ctrl Z", disabled = #e.undo == 0, why = "Nada para deshacer", name = "Deshacer" }) or nil,
			(not phone) and Ui.button("Rehacer", "q", Screen.redo, { small = true, icon = "redo", iconSize = 16, kbd = "Ctrl Y", disabled = #e.redo == 0, why = "Nada para rehacer", name = "Rehacer" }) or nil,
			Ui.button(phone and "" or "Modelos anteriores", "default", function()
				App.openDialog("prevModels", { wide = true })
			end, { small = true, icon = "copy", name = "ModelosAnteriores" }),
			Ui.button("Volver a la empresa", "default", function()
				App.go("juego")
			end, { small = true, icon = "left", kbd = "Esc", name = "VolverEmpresa" }),
		}, 12, {
			Name = "BarraEditor", Size = UDim2.new(1, 0, 0, G.topH), AutomaticSize = Enum.AutomaticSize.None, BackgroundColor3 = Color3.fromHex("#080A0F"),
			BackgroundTransparency = 0.05, Pad = { 0, 16, 0, phone and (G.landscape and 96 or 118) or 150 }, Parent = parent,
		})
		local tg = Instance.new("UIGradient")
		tg.Transparency = NumberSequence.new(0, 0.4)
		tg.Rotation = 90
		tg.Parent = top

		-- Herramientas de cámara (.ed-tools); en celular se abren desde la barra.
		if not phone or e.toolsOpen then
			table.clear(camButtons)
			local cams: { Instance? } = { Ui.new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Pad = { 0, 12, 6, 12 } }, { Ui.lbl("Cámara") }) }
			for _, cam in CAMS do
				table.insert(cams, camTool(cam[1], cam[2], cam[5]))
			end
			table.insert(cams, Ui.row({
				Ui.button("", "default", function()
					Screen.zoom(1.18)
				end, { small = true, icon = "minus", iconSize = 16, name = "Alejar" }),
				Ui.button("", "default", function()
					Screen.zoom(0.85)
				end, { small = true, icon = "plus", iconSize = 16, name = "Acercar" }),
				Ui.button("", "default", function()
					Screen.setCam("angulo")
				end, { small = true, icon = "reset", iconSize = 16, name = "RestablecerCamara" }),
			}, 10, { Pad = { 6, 6, 0, 6 } }))
			local pend = DesignCalc.devPending(g, d)
			local toolsCol = Ui.col({
				Ui.col(cams, 2),
				glass({
					Ui.inline("Fabricación por unidad", { size = Ui.S.xs, color = T.mut }),
					Ui.inline(Util.money(c.unitCost), { size = 17, weight = W.bold }),
					Ui.text("Desarrollo pendiente (una vez)", { size = Ui.S.xs, color = T.mut }),
					Ui.inline(pend > 0 and Util.money(pend) or "Nada pendiente", { size = Ui.S.base, weight = W.bold, color = pend > 0 and T.or_ or T.gr }),
					Ui.text("Ventas estimadas: " .. Util.num(Rules.designSalesEstimate(g, c, d, c.price).rate, 1) .. " por minuto", { size = Ui.S.xs, color = T.mut }),
				}, { Name = "CostosEditor", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = GLASS, BackgroundTransparency = 0.1, Corner = 12, Pad = 14, List = { dir = "V", gap = 4 } }),
				Ui.text("Arrastrá sobre el auto para girarlo y usá la rueda o el pellizco para acercar.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.5 }),
			}, 14, { Name = "HerramientasEditor", Position = UDim2.fromOffset(phone and 8 or 14, phone and 64 or 78), Size = UDim2.fromOffset(190, 0) })
			if phone then
				toolsCol.BackgroundColor3 = Color3.fromHex("#0E1016")
				toolsCol.BackgroundTransparency = 0.04
				Ui.new("UICorner", { CornerRadius = UDim.new(0, 14), Parent = toolsCol })
				Ui.new("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = toolsCol })
				toolsCol.ZIndex = 8
			end
			toolsCol.Parent = parent
		end

		-- Estadísticas (.ed-stats): pasos 2 y 3; en celular, desde la barra.
		if G.statsShown or (phone and e.statsOpen) then
			local card = statsCard(g, d)
			local holder = Ui.scroll({ card }, { name = "EstadisticasEditor", pad = 0 })
			holder.Position = UDim2.fromOffset(phone and 8 or 218, phone and 64 or 78)
			holder.Size = phone and UDim2.new(1, -16, 0, math.min(App.vh - 140, 520)) or UDim2.new(0, 300, 1, -230 - 78)
			holder.AutomaticSize = Enum.AutomaticSize.None
			holder.ZIndex = phone and 8 or 1
			card.Size = UDim2.new(1, 0, 0, 0)
			holder.Parent = parent
		end

		-- Panel derecho (.ed-panel)
		local panel = Ui.new("Frame", {
			Name = "PanelEditor", Position = UDim2.fromOffset(G.panel.x, G.panel.y), Size = UDim2.fromOffset(G.panel.w, G.panel.h),
			BackgroundColor3 = Color3.fromHex("#0E1016"), BackgroundTransparency = 0.04, Corner = phone and 0 or 16, Stroke = EDGE, ClipsDescendants = true,
			List = { dir = "V", gap = 0 }, Parent = parent,
		})
		if phone then
			-- Bordes redondeados solo arriba (como la hoja inferior de la V3).
			local cr = panel:FindFirstChildOfClass("UICorner")
			if cr then
				cr.CornerRadius = UDim.new(0, 16)
			end
		end
		local titles = { "Vehículo base", "Rendimiento", "Diseño", "Revisión" }
		panelHeader(e, d, titles[e.step]).Parent = panel
		Ui.new("Frame", { Name = "BordeCabecera", Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = Color3.fromHex("#1F222B"), BackgroundTransparency = 0, Parent = panel })
		local body = Ui.scroll({}, { name = "CuerpoPaso", gap = 18, pad = { 16, 18, 16, 18 } })
		body.Size = UDim2.new(1, 0, 0, 0)
		local flex = Instance.new("UIFlexItem")
		flex.FlexMode = Enum.UIFlexMode.Fill
		flex.Parent = body
		body.Parent = panel
		local nextBtn: Instance? = nil
		if e.step == 1 then
			panelBase(g, d, body)
		elseif e.step == 2 then
			nextBtn = panelPerf(g, d, body)
		elseif e.step == 3 then
			panelDesign(g, d, body)
		else
			nextBtn = panelReview(g, d, c, body)
		end
		panelFooter(g, e, d, c, nextBtn).Parent = panel
		App.keepScroll(body, "editor:" .. e.step .. ":" .. tostring(e.cat) .. ":" .. tostring(e.tab))
	end

	-- Controles inferiores (.ed-bottom): pasos, barra de herramientas y divisor.
	local bottomItems: { Instance? } = {}
	if not e.hideUI then
		local stepButtons = {}
		for _, st in STEPS do
			local n = st[1]
			local current = e.step == n
			local done = n < e.step
			local btn = Ui.new("TextButton", {
				Name = "Paso_" .. n, Text = "", BackgroundColor3 = current and T.vi or GLASS, BackgroundTransparency = current and 0.8 or 0.1,
				Size = UDim2.fromOffset(0, 44), AutomaticSize = Enum.AutomaticSize.X, Corner = 22, Stroke = current and T.vi or EDGE,
				Pad = { 0, phone and 6 or 14, 0, 6 }, List = { dir = "H", gap = 8, v = "C" },
			}, {
				Ui.new("TextLabel", { Name = "Numero", Text = done and "✓" or tostring(n), TextSize = 13, Weight = W.heavy, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = done and Color3.fromHex("#05230F") or T.tx, BackgroundColor3 = current and T.vi or (done and T.gr or T.p3), BackgroundTransparency = 0, Size = UDim2.fromOffset(30, 30), Corner = 15 }),
				(not phone) and Ui.inline(st[2], { size = Ui.S.base, weight = W.semi, color = current and T.tx or Color3.fromHex("#B4BAC6") }) or nil,
			})
			btn.Activated:Connect(function()
				Screen.goStep(n)
			end)
			table.insert(stepButtons, btn)
		end
		table.insert(bottomItems, Ui.row(stepButtons, 6, { Name = "Pasos", h = "C", Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, wrap = true }))
	end
	local tools: { Instance? } = {
		toolbarBtn("undo", nil, Screen.undo, { disabled = #e.undo == 0, name = "DeshacerBarra" }),
		toolbarBtn("redo", nil, Screen.redo, { disabled = #e.redo == 0, name = "RehacerBarra" }),
		toolbarBtn("reset", (not phone) and "Restablecer cámara" or nil, function()
			Screen.setCam("angulo")
		end, { name = "RestablecerBarra" }),
		toolbarBtn("cam", (not phone) and "Captura" or nil, Screen.capture, { name = "Captura" }),
		toolbarBtn("compare", (not phone) and "Antes / después" or nil, Screen.toggleCompare, { pressed = e.compare, name = "AntesDespues" }),
		toolbarBtn("eyeoff", (not phone) and "Ocultar interfaz" or nil, Screen.toggleHide, { pressed = e.hideUI, kbd = (not phone) and "H" or nil, name = "OcultarInterfaz" }),
		phone and toolbarBtn("cam", nil, function()
			e.toolsOpen = not e.toolsOpen
			e.statsOpen = false
			App.forceRender()
		end, { pressed = e.toolsOpen, name = "AbrirCamaras" }) or nil,
		phone and toolbarBtn("chart", nil, function()
			e.statsOpen = not e.statsOpen
			e.toolsOpen = false
			App.forceRender()
		end, { pressed = e.statsOpen, name = "AbrirEstadisticas" }) or nil,
	}
	table.insert(bottomItems, glass({ Ui.row(tools, 4, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY }) }, {
		Name = "BarraHerramientas", Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, BackgroundColor3 = GLASS, BackgroundTransparency = 0.1, Corner = 12, Pad = 4,
	}))
	if e.compare then
		table.insert(bottomItems, Ui.row({
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
			end, { width = 180, name = "Divisor" }),
		}, 8, { Name = "FilaDivisor", Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, BackgroundColor3 = GLASS, BackgroundTransparency = 0.1, Corner = 8, Pad = { 4, 10 } }))
	end
	local bw = App.vw - G.bottom.l - G.bottom.r
	Ui.col(bottomItems, 10, {
		Name = "ControlesEditor", h = "C", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, G.bottom.l, 1, -G.bottom.b),
		Size = UDim2.fromOffset(bw, 0),
	}).Parent = parent

	if e.hideUI then
		local show = Ui.button("Mostrar interfaz", "p", Screen.toggleHide, { kbd = "H", name = "MostrarInterfaz" })
		show.AnchorPoint = Vector2.new(0.5, 1)
		show.Position = UDim2.new(0.5, 0, 1, -20)
		show.ZIndex = 9
		show.Parent = parent
	end
end

return Screen
