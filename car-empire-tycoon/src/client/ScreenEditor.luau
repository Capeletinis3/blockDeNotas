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
local CarModel = require(Shared.CarModel)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {}

local STEPS = { { 1, "Vehículo base" }, { 2, "Rendimiento" }, { 3, "Diseño" }, { 4, "Revisión" } }
local RAR = { ["Común"] = "cn", ["Rara"] = "cb", ["Épica"] = "cv", ["Legendaria"] = "cy" }
-- Cámaras predefinidas (V3: CAMS). yaw 0 = desde atrás; 180 = de frente.
local CAMS = {
	{ "angulo", "Ángulo", 145, 16 },
	{ "frontal", "Frontal", 180, 6 },
	{ "lateral", "Lateral", 90, 4 },
	{ "trasera", "Trasera", 0, 8 },
	{ "superior", "Superior", 150, 72 },
	{ "interior", "Interior", 180, 0 },
}
local BODY_LABELS = {
	{ "bumper", "Paragolpes" }, { "hood", "Capó" }, { "diffuser", "Difusor" }, { "skirts", "Faldones" },
	{ "lights", "Faros" }, { "tint", "Cristales" }, { "vinyl", "Vinilos" }, { "number", "Número de competición" }, { "logo", "Emblema de la empresa" },
}
local INTERIOR_LABELS = { { "seats", "Asientos" }, { "material", "Tapizado" }, { "wheel", "Volante" }, { "dash", "Tablero" }, { "ambient", "Iluminación interior" } }
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
backdrop.BackgroundColor3 = Color3.fromHex("#0B0E18")
backdrop.BorderSizePixel = 0
backdrop.Parent = view3d
local grad = Instance.new("UIGradient")
grad.Color = ColorSequence.new(Color3.fromHex("#1A1F2E"), Color3.fromHex("#07080C"))
grad.Rotation = 90
grad.Parent = backdrop

local function makeViewport(name: string): (ViewportFrame, Camera, WorldModel)
	local vp = Instance.new("ViewportFrame")
	vp.Name = name
	vp.BackgroundTransparency = 1
	vp.Ambient = Color3.fromHex("#8C93A8")
	vp.LightColor = Color3.fromHex("#FFF1DC")
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
	floor.Size = Vector3.new(0.2, 26, 26)
	floor.CFrame = CFrame.new(0, -0.1, 0) * CFrame.Angles(0, 0, math.pi / 2)
	floor.Color = Color3.fromHex("#1D2029")
	floor.Material = Enum.Material.SmoothPlastic
	floor.Parent = world
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
function Screen.fitDistance(size: Vector3, aspect: number, fov: number, zoom: number): number
	local radius = size.Magnitude / 2
	local vfov = math.rad(fov)
	local hfov = 2 * math.atan(math.tan(vfov / 2) * math.max(0.2, aspect))
	return radius / math.sin(math.min(vfov, hfov) / 2) * 1.04 * zoom
end

local function cameraCFrame(aspect: number): CFrame
	local target = Vector3.new(0, dims.Y * 0.42, 0)
	if view.cam == "interior" then
		local s = CarModel.SHAPES[(Catalog.base(App.ui.editor and App.ui.editor.draft.baseId) or Catalog.BASES[1]).type] or CarModel.SHAPES.sedan
		local eye = Vector3.new(-s.W * 0.2, dims.Y - s.C * 0.45, s.cabinZ + 0.8)
		return CFrame.lookAt(eye, eye + Vector3.new(math.sin(math.rad(view.yaw)) * -1, -0.12, math.cos(math.rad(view.yaw))))
	end
	local dist = Screen.fitDistance(dims, aspect, 40, view.zoom)
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
function Screen.refreshCamButtons()
	for id, b in camButtons do
		if b.Parent then
			b:SetAttribute("kind", id == view.cam and "v" or "default")
			Ui.setEnabled(b, true)
		end
	end
end

function Screen.setCam(id: string)
	for _, c in CAMS do
		if c[1] == id then
			view.cam, view.yaw, view.pitch, view.zoom = id, c[3], c[4], 1
		end
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
		colorTarget = "primary", tab = "ext", dirty = false, undo = {}, redo = {}, compare = false, hotspots = true, sel = nil,
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
	if params.new or params.fromTemplate then
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
	elseif params.new or not e then
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
end

function Screen.leave()
	view3d.Enabled = false
end

local function save(btn: any?, after: (() -> ())?)
	local e = ed()
	local r = App.request("saveDesign", { draft = e.draft, sourceId = e.sourceId }, { button = btn })
	if r.ok then
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
		title = title or "Cambios sin guardar",
		name = e and e.draft.name or "",
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
		Ui.row({ Ui.lbl("Estadísticas"), Ui.spacer(), Ui.inline(prev and "vista previa de la pieza elegida" or "diseño actual", { size = Ui.S.xs, color = T.mut }) }, 8),
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
				Ui.grow(Ui.text(label .. "  <font color=\"#6C7382\">" .. u .. "</font>", { size = Ui.S.sm, color = T.mut })),
				Ui.inline(fmtStat(k, nv), { size = 14, weight = W.bold }),
				dlt ~= 0 and Ui.inline((good and "▲ " or "▼ ") .. (dlt > 0 and "+" or "") .. fmtStat(k, dlt), { size = Ui.S.xs, weight = W.bold, color = good and T.gr or T.re2 }) or nil,
			}, 6),
			(Ui.bar(pct, dlt ~= 0 and (good and T.gr or T.re) or nil)),
		}, 4))
	end
	table.insert(rows, Ui.text("Barras: más llena = mejor. En aceleración, frenado, consumo y peso, un número menor es mejor.", { size = Ui.S.xs, color = T.mut }))
	return Ui.card(rows, { bg = Color3.fromHex("#0E1016"), transparency = 0.08, radius = 14, stroke = Color3.fromHex("#2A2E39"), gap = 6, pad = { 12, 14 }, name = "Estadisticas" })
end

local function section(title: string, children: { Instance? }, gap: number?): Frame
	local list: { Instance? } = { Ui.lbl(title) }
	for _, c in children do
		table.insert(list, c)
	end
	return Ui.col(list, gap or 8)
end

local function optRow(options: { any }, current: any, onPick: (any) -> (), opts: { [string]: any }?): Frame
	local items = {}
	for _, o in options do
		local value, label, extra = o[1], o[2], o[3]
		table.insert(items, Ui.opt(label, current == value, function()
			onPick(value)
		end, { height = 36, disabled = extra and extra.disabled ~= nil, why = extra and extra.disabled }))
	end
	if opts and opts.columns then
		return Ui.grid(items, App.isPhone() and math.min(opts.columns, 3) or opts.columns, opts.height or 36)
	end
	return Ui.row(items, 6, { wrap = true })
end

-- Paso 1: vehículo base -------------------------------------------------------------------------------
local function panelBase(g: any, d: any, body: Instance)
	local e = ed()
	local nameBox = Ui.input(d.name, "Nombre del proyecto", function(text: string)
		local t = Util.truncateChars(Util.trim(text), 24)
		if t ~= d.name then
			change(function(dd)
				dd.name = t
			end)
		end
	end)
	section("Nombre del proyecto", { nameBox, Ui.text("Entre 2 y 24 caracteres; no puede repetir el nombre de otro diseño tuyo.", { size = Ui.S.xs, color = T.mut }) }).Parent = body
	local company = g.company.name
	section("Marca", { optRow({ { company, company }, { company .. " Sport", company .. " Sport" }, { company .. " Lux", company .. " Lux" } }, d.brand, function(v)
		change(function(dd)
			dd.brand = v
		end)
	end) }).Parent = body
	local gens = {}
	for _, gen in DesignCalc.GENERATIONS do
		table.insert(gens, { gen, gen })
	end
	section("Año o generación", { optRow(gens, d.generation, function(v)
		change(function(dd)
			dd.generation = v
		end)
	end) }).Parent = body
	local b = Catalog.base(d.baseId)
	local chassis = {}
	for _, k in Catalog.CHASSIS_ORDER do
		local ch = Catalog.CHASSIS[k]
		local blocked = ch.need and not Util.contains(b.tags, ch.need)
		table.insert(chassis, { k, k .. (ch.unit > 0 and (" (+" .. Util.money(ch.unit) .. "/u)") or ""), blocked and { disabled = "Solo para SUV y pickup" } or nil })
	end
	section("Chasis", { optRow(chassis, d.chassis, function(v)
		change(function(dd)
			dd.chassis = v
		end)
	end) }).Parent = body
	local segs = {}
	for _, k in Catalog.SEGMENT_ORDER do
		table.insert(segs, { k, k .. " · precio ×" .. Util.num(Catalog.SEGMENTS[k].price, 2) })
	end
	section("Segmento de mercado", { optRow(segs, d.segment, function(v)
		change(function(dd)
			dd.segment = v
		end)
	end) }).Parent = body
	local objs = {}
	for _, k in Catalog.OBJECTIVE_ORDER do
		table.insert(objs, { k, k })
	end
	section("Objetivo del vehículo (atrae a clientes con esa preferencia)", { optRow(objs, d.objective, function(v)
		change(function(dd)
			dd.objective = v
		end)
	end, { columns = 3 }) }).Parent = body
	local q = {}
	for i, tier in Catalog.QUALITY_TIERS do
		table.insert(q, { i - 1, tier })
	end
	section("Calidad de terminación · " .. Catalog.QUALITY_TIERS[d.quality + 1] .. " · +" .. Util.money(d.quality * 700) .. "/u · +" .. d.quality * 3 .. " calidad", { optRow(q, d.quality, function(v)
		change(function(dd)
			dd.quality = v
		end)
	end, { columns = 6 }) }).Parent = body

	local filt = e.typeFilter or "todos"
	local typeOpts = { { "todos", "Todos" } }
	for _, k in Util.keys(Catalog.TYPES) do
		table.insert(typeOpts, { k, Catalog.TYPES[k] })
	end
	local available = 0
	for _, x in Catalog.BASES do
		if DesignCalc.baseAvailable(g, x) == nil then
			available += 1
		end
	end
	local cards: { Instance? } = {
		Ui.row({ Ui.lbl("Modelo base"), Ui.spacer(), Ui.inline(available .. " de " .. #Catalog.BASES .. " disponibles", { size = Ui.S.xs, color = T.mut }) }, 8),
		optRow(typeOpts, filt, function(v)
			e.typeFilter = v
			App.forceRender()
		end),
	}
	for _, x in Catalog.BASES do
		if filt == "todos" or x.type == filt then
			local block = DesignCalc.baseAvailable(g, x)
			local on = d.baseId == x.id
			local t = DesignCalc.newDraft(g, x.id)
			local st = DesignCalc.computeDesign(g, t)
			local paid = Util.contains(g.devPaid, "base:" .. x.id)
			local card = Ui.new("TextButton", {
				Name = "Base_" .. x.id, Text = "", BackgroundColor3 = on and Color3.fromHex("#1A1833") or T.p2, BackgroundTransparency = block and 0.25 or 0,
				Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Corner = 12, Stroke = on and { T.vi, 2 } or T.line2, Pad = 12,
				List = { dir = "H", gap = 12, v = "T" },
			}, {
				block and Ui.ico("lock", T.mut2, Color3.fromHex("#22252E"), 44) or Ui.carThumb(t, 76, 46),
				Ui.grow(Ui.col({
					Ui.row({ Ui.grow(Ui.text(x.name, { size = 15, weight = W.bold })), Ui.chip(x.rarity, RAR[x.rarity]) }, 6),
					Ui.text(Catalog.TYPES[x.type] .. " · Nv. " .. x.level .. " · " .. st.hp .. " hp · " .. Util.money(st.unitCost) .. "/u · precio " .. Util.money(st.price), { size = Ui.S.xs, color = T.mut }),
					block and Ui.chip(block, "cy") or Ui.chip(paid and "Licencia pagada" or ("Licencia " .. Util.money(x.dev) .. " (una vez)"), paid and "cg" or "co"),
				}, 5)),
			})
			card.Activated:Connect(function()
				if block then
					App.toast("aviso", x.name .. ": " .. block)
					return
				end
				if d.baseId ~= x.id then
					change(function(dd)
						DesignCalc.changeBase(g, dd, x.id)
					end)
				end
			end)
			table.insert(cards, card)
		end
	end
	Ui.col(cards, 8).Parent = body
end

-- Paso 2: rendimiento -------------------------------------------------------------------------------------
local function panelPerf(g: any, d: any, body: Instance): TextButton?
	local e = ed()
	local cat = e.cat
	local cats = {}
	for _, c in Catalog.CATS do
		table.insert(cats, Ui.opt(c[2], cat == c[1], function()
			e.cat = c[1]
			e.sel = nil
			App.forceRender()
		end, { height = 34, size = 12 }))
	end
	section("Categoría", { Ui.grid(cats, App.isPhone() and 3 or 4, 34, 6) }).Parent = body
	local list = Catalog.partsOf(cat)
	local current = Catalog.part(cat, d.parts[cat])
	local selId = e.sel or d.parts[cat]
	local selP = Catalog.part(cat, selId)
	local b = Catalog.base(d.baseId)
	local cards: { Instance? } = {
		Ui.row({ Ui.lbl(Catalog.catLabel(cat) .. " · " .. #list .. " opciones"), Ui.spacer(), Ui.inline("Instalada: " .. (current and current.name or "—"), { size = Ui.S.xs, color = T.mut }) }, 8),
	}
	for _, p in list do
		local bl = DesignCalc.partBlock(g, d, p)
		local on = p.id == selId
		local eq = p.id == d.parts[cat]
		local paid = Util.contains(g.devPaid, cat .. ":" .. p.id)
		local stock = DesignCalc.partInStock(g, cat, p.id)
		local isDefault = b.defaults[cat] == p.id
		local chips: { Instance? } = {}
		table.insert(chips, eq and Ui.chip("✓ Equipada", "cb") or (bl and Ui.chip("Bloqueada", "cy") or Ui.chip("● Disponible", "cg")))
		if p.proto > 0 and not isDefault then
			table.insert(chips, Ui.chip(paid and "Desarrollo pagado" or (stock and "Pieza en inventario" or ("Desarrollo " .. Util.money(p.proto))), (paid or stock) and "cg" or "co"))
		end
		if p.unit > 0 then
			table.insert(chips, Ui.chip("+" .. Util.money(p.unit) .. "/u", "cn"))
		end
		local card = Ui.new("TextButton", {
			Name = "Pieza_" .. p.id, Text = "", BackgroundColor3 = on and Color3.fromHex("#1A1833") or T.p2, BackgroundTransparency = bl and 0.25 or 0,
			Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Corner = 12, Stroke = on and { T.vi, 2 } or T.line2, Pad = 12,
			List = { dir = "H", gap = 12, v = "T" },
		}, {
			Ui.ico(bl and "lock" or "wrench", bl and T.mut2 or T.vi2, T.input, 40),
			Ui.grow(Ui.col({
				Ui.row({ Ui.grow(Ui.text(p.name, { size = 14, weight = W.bold })), Ui.chip(p.rarity, RAR[p.rarity]) }, 6),
				Ui.row(chips, 5, { wrap = true }),
				Ui.text(bl and bl or p.desc, { size = Ui.S.xs, color = bl and T.ye or T.mut }),
			}, 5)),
		})
		card.Activated:Connect(function()
			e.sel = p.id
			App.forceRender()
		end)
		table.insert(cards, card)
	end
	Ui.col(cards, 8).Parent = body

	if selP and selP.id ~= d.parts[cat] then
		local t = Util.deepCopy(d)
		t.parts[cat] = selP.id
		local a, n = DesignCalc.computeDesign(g, d), DesignCalc.computeDesign(g, t)
		local chips = {}
		for _, s in Catalog.STAT_DEFS do
			local k, label, unit, dir = s[1], s[2], s[3], s[5]
			local dl = Util.round((n[k] - a[k]) * 10) / 10
			if dl ~= 0 then
				local good = (dir > 0 and dl > 0) or (dir < 0 and dl < 0)
				table.insert(chips, Ui.chip((dl > 0 and "+" or "") .. fmtStat(k, dl) .. " " .. (k == "consumption" and "" or (string.gsub(unit, "0–100", ""))) .. " " .. string.lower(label), good and "cg" or "cr"))
			end
		end
		local du = n.unitCost - a.unitCost
		table.insert(chips, Ui.chip((du >= 0 and "+" or "") .. Util.money(du) .. " por unidad", du > 0 and "cy" or "cg"))
		local block = DesignCalc.partBlock(g, d, selP)
		local free = Util.contains(g.devPaid, cat .. ":" .. selP.id) or selP.proto == 0 or b.defaults[cat] == selP.id
		section("Comparación con la pieza instalada", {
			Ui.text((current and current.name or "—") .. "  →  <b>" .. selP.name .. "</b>", { size = Ui.S.sm }),
			Ui.row(chips, 6, { wrap = true }),
			block and Ui.note("y", block) or Ui.note("b", free and "Sin costo de desarrollo." or (DesignCalc.partInStock(g, cat, selP.id) and "Usará la pieza de tu inventario al guardar (cubre el desarrollo)." or ("El desarrollo de " .. Util.money(selP.proto) .. " se cobra una sola vez al guardar el diseño."))),
		}).Parent = body
		if block then
			return Ui.button("No se puede instalar", "default", nil, { disabled = true, why = block, flex = 2, icon = "lock" })
		end
		return Ui.button("Instalar en el prototipo", "p", function()
			change(function(dd)
				dd.parts[cat] = selP.id
			end)
			e.sel = nil
			App.forceRender()
		end, { flex = 2, icon = "wrench" })
	end
	return nil
end

-- Paso 3: diseño exterior e interior ---------------------------------------------------------------------
local function panelDesign(g: any, d: any, body: Instance)
	local e = ed()
	local tab = e.tab or "ext"
	local tabs = {}
	for _, t in { { "ext", "Exterior" }, { "int", "Interior" } } do
		table.insert(tabs, Ui.opt(t[2], tab == t[1], function()
			e.tab = t[1]
			if t[1] == "int" then
				Screen.setCam("interior")
			elseif view.cam == "interior" then
				Screen.setCam("angulo")
			end
			App.forceRender()
		end, { height = 36, width = 120 }))
	end
	Ui.row(tabs, 6).Parent = body
	if tab == "int" then
		Ui.note("b", "La cámara Interior muestra asientos, tapizado, volante, tablero e iluminación.").Parent = body
		for _, grp in INTERIOR_LABELS do
			local opts = {}
			for _, o in Catalog.INTERIOR[grp[1]] do
				local fx = {}
				for k, v in o[4] do
					table.insert(fx, (v > 0 and "+" or "") .. v .. " " .. ({ comfort = "comodidad", q = "calidad", grip = "manejo" })[k])
				end
				table.insert(opts, { o[1], o[2] .. (o[3] > 0 and (" +" .. Util.money(o[3]) .. "/u") or "") .. (#fx > 0 and (" (" .. table.concat(fx, ", ") .. ")") or "") })
			end
			section(grp[2], { optRow(opts, d.interior[grp[1]], function(v)
				change(function(dd)
					dd.interior[grp[1]] = v
				end)
			end) }).Parent = body
		end
		local ups = {}
		for _, c in UPHOLSTERY do
			table.insert(ups, Ui.swatch(c[1], string.upper(d.interior.color) == c[1], function()
				change(function(dd)
					dd.interior.color = c[1]
				end)
			end))
		end
		section("Color del tapizado", { Ui.row(ups, 8) }).Parent = body
		Ui.text("El cuero usa 1 de cuero por unidad y el tablero digital 1 de electrónica.", { size = Ui.S.xs, color = T.mut }).Parent = body
		return
	end

	local target = e.colorTarget
	local color = d.paint[target]
	local swatches = {}
	for _, p in Catalog.PAINTS do
		table.insert(swatches, Ui.swatch(p[1], string.upper(color) == string.upper(p[1]), function()
			change(function(dd)
				dd.paint[target] = string.upper(p[1])
			end)
		end))
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
			App.toast("error", "Código de color inválido. Usá el formato #RRGGBB.")
			App.forceRender()
		end
	end, { width = 140 })
	section("Pintura", {
		optRow({ { "primary", "Principal" }, { "secondary", "Secundario" } }, target, function(v)
			e.colorTarget = v
			App.forceRender()
		end),
		target == "secondary" and Ui.text("El color secundario pinta techo, pilares, alerón, faldones y vinilos.", { size = Ui.S.xs, color = T.mut }) or nil,
		Ui.row(swatches, 8, { wrap = true }),
		Ui.row({
			Ui.new("Frame", { Size = UDim2.fromOffset(44, 44), BackgroundColor3 = Color3.fromHex(color), BackgroundTransparency = 0, Corner = 10, Stroke = T.btnLine }),
			Ui.inline("HEX", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
			hexBox,
		}, 10),
		Ui.text("Intensidad del color", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
		optRow({ { 70, "70 %" }, { 85, "85 %" }, { 100, "100 %" }, { 115, "115 %" }, { 130, "130 %" } }, d.paint.intensity, function(v)
			change(function(dd)
				dd.paint.intensity = v
			end)
		end),
		Ui.text("Brillo del barniz", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
		optRow({ { 0, "0 %" }, { 30, "30 %" }, { 60, "60 %" }, { 80, "80 %" }, { 100, "100 %" } }, d.paint.gloss, function(v)
			change(function(dd)
				dd.paint.gloss = v
			end)
		end),
	}, 10).Parent = body

	local finishes = {}
	for _, k in Catalog.FINISH_ORDER do
		local f = Catalog.FINISHES[k]
		local locked = f.research and not DesignCalc.has(g, f.research)
		table.insert(finishes, { k, k .. (f.unit > 0 and (" +" .. Util.money(f.unit) .. "/u") or ""), locked and { disabled = "Requiere investigar «" .. DesignCalc.researchName(f.research) .. "»" } or nil })
	end
	section("Acabado", { optRow(finishes, d.paint.finish, function(v)
		change(function(dd)
			dd.paint.finish = v
		end)
	end, { columns = 2 }) }).Parent = body

	local sizes = {}
	for s = 16, 22 do
		table.insert(sizes, { s, s .. "″" })
	end
	local styles = {}
	for _, s in Catalog.WHEEL_STYLES do
		table.insert(styles, { s[1], s[2] })
	end
	local rims, calipers = {}, {}
	for _, r in Catalog.RIM_COLORS do
		table.insert(rims, Ui.swatch(r[1], d.wheels.rim == r[1], function()
			change(function(dd)
				dd.wheels.rim = r[1]
			end)
		end))
	end
	for _, cc in Catalog.CALIPER_COLORS do
		table.insert(calipers, Ui.swatch(cc[1], d.caliper == cc[1], function()
			change(function(dd)
				dd.caliper = cc[1]
			end)
		end))
	end
	section("Ruedas y frenos", {
		Ui.text("Llantas", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
		optRow(styles, d.wheels.style, function(v)
			change(function(dd)
				dd.wheels.style = v
			end)
		end),
		Ui.text("Tamaño · " .. d.wheels.size .. "″ · +" .. Util.money(math.max(0, d.wheels.size - 17) * 150) .. "/u", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
		optRow(sizes, d.wheels.size, function(v)
			change(function(dd)
				dd.wheels.size = v
			end)
		end, { columns = 7 }),
		Ui.text("Color de llantas", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
		Ui.row(rims, 8),
		Ui.text("Pinzas de freno", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
		Ui.row(calipers, 8),
	}, 8).Parent = body

	local bodyRows: { Instance? } = {
		Ui.card({
			Ui.grow(Ui.col({ Ui.text("Alerón trasero", { size = Ui.S.sm, weight = W.bold }), Ui.text("+3 de manejo, −4 km/h de velocidad máxima, +" .. Util.money(600) .. "/u", { size = Ui.S.xs, color = T.mut }) }, 2)),
			Ui.toggle(d.spoiler, function()
				change(function(dd)
					dd.spoiler = not dd.spoiler
				end)
			end),
		}, { dir = "H", v = "C", gap = 10 }),
	}
	for _, grp in BODY_LABELS do
		local opts = {}
		for _, o in Catalog.BODY_OPTS[grp[1]] do
			table.insert(opts, { o[1], o[2] .. (o[3] > 0 and (" +" .. Util.money(o[3]) .. "/u") or "") })
		end
		table.insert(bodyRows, Ui.text(grp[2], { size = Ui.S.sm, color = T.tx2, weight = W.semi }))
		table.insert(bodyRows, optRow(opts, d.body[grp[1]], function(v)
			change(function(dd)
				dd.body[grp[1]] = v
			end)
		end))
	end
	local plateBox = Ui.input(d.body.plate or "", "CET 001", function(text: string)
		local v = string.sub(string.upper(text):gsub("[^A-Z0-9 %-]", ""), 1, 9)
		if v ~= d.body.plate then
			change(function(dd)
				dd.body.plate = v
			end)
		end
	end, { width = 160 })
	table.insert(bodyRows, Ui.row({ Ui.text("Matrícula", { size = Ui.S.sm, color = T.tx2, weight = W.semi, width = 90 }), plateBox }, 10))
	section("Carrocería y detalles", bodyRows, 8).Parent = body
end

-- Paso 4: revisión -----------------------------------------------------------------------------------------
local function panelReview(g: any, d: any, c: any, body: Instance)
	local e = ed()
	local b = Catalog.base(d.baseId)
	local items = DesignCalc.devItems(g, d)
	local pend = DesignCalc.devPending(g, d)
	local margin = c.price - c.unitCost
	local paintName = Catalog.colorName(Catalog.PAINTS, d.paint.primary) or d.paint.primary
	Ui.card({
		Ui.text(d.name, { size = 17, weight = W.bold }),
		Ui.text(d.brand .. " · " .. b.name .. " (" .. Catalog.TYPES[b.type] .. ") · " .. d.generation .. " · " .. d.chassis .. " · " .. d.segment .. " · objetivo " .. string.lower(d.objective), { size = Ui.S.sm, color = T.mut }),
		Ui.text("Pintura " .. paintName .. " " .. string.lower(d.paint.finish) .. " · secundario " .. d.paint.secondary .. " · llantas " .. d.wheels.size .. "″ " .. string.lower(d.wheels.style) .. " · " .. (d.spoiler and "con alerón" or "sin alerón") .. " · calidad " .. Catalog.QUALITY_TIERS[d.quality + 1] .. " · matrícula " .. tostring(d.body.plate), { size = Ui.S.sm, color = T.mut }),
	}, { gap = 4 }).Parent = body
	local mats = {}
	for _, k in Util.keys(c.mats) do
		table.insert(mats, c.mats[k] .. " " .. string.lower(Catalog.matLabel(k)))
	end
	section("Economía del modelo", {
		Ui.grid({
			(Ui.kv("Fabricación por unidad", Util.money(c.unitCost))),
			(Ui.kv("Precio recomendado", Util.money(c.price))),
			(Ui.kv("Margen por unidad", (margin >= 0 and "▲ " or "▼ ") .. Util.money(margin), { color = margin >= 0 and T.gr or T.re2 })),
			(Ui.kv("Producción", Util.gameDuration(c.build), { sub = "de juego por unidad (velocidad base)" })),
		}, 2, 78),
		(Ui.kv("Materiales por unidad", table.concat(mats, ", "), { valueSize = 13 })),
	}).Parent = body
	local devRows: { Instance? } = {}
	for _, it in items do
		table.insert(devRows, Ui.line(it.label, it.paid and "Pagado" or (it.stock and "Pieza en inventario" or Util.money(it.cost)), { color = (it.paid or it.stock) and T.gr or T.tx }))
	end
	table.insert(devRows, Ui.hr())
	table.insert(devRows, Ui.line("Pendiente", Util.money(pend), { color = pend > 0 and T.or_ or T.gr, leftWeight = W.bold }))
	if DesignCalc.designDiscount(g) > 0 then
		table.insert(devRows, Ui.text("Incluye −" .. Util.round(DesignCalc.designDiscount(g) * 100) .. " % del estudio de diseño.", { size = Ui.S.xs, color = T.mut }))
	end
	section("Desarrollo (pago único al guardar)", { Ui.card(devRows, { gap = 0, pad = { 4, 12 } }) }).Parent = body
	local statRows = {}
	for _, s in Catalog.STAT_DEFS do
		local k = s[1]
		table.insert(statRows, Ui.line(s[2], fmtStat(k, c[k]) .. " " .. (k == "consumption" and c.consUnit or s[3]), { leftColor = T.mut, size = 12 }))
	end
	section("Estadísticas finales", { Ui.card({ Ui.grid(statRows, App.isPhone() and 1 or 2, 26, 4) }, { pad = { 6, 12 } }) }).Parent = body
	local partRows = {}
	for _, cat in Catalog.CATS do
		local p = Catalog.part(cat[1], d.parts[cat[1]])
		table.insert(partRows, Ui.line(cat[2], p and p.name or "—", { leftColor = T.mut, weight = W.med }))
	end
	section("Piezas instaladas", { Ui.card(partRows, { gap = 0, pad = { 4, 12 } }) }).Parent = body
	local warns = {}
	if c.comfort < 50 and (d.objective == "Familiar" or d.objective == "Lujo") then
		table.insert(warns, "La comodidad (" .. c.comfort .. ") es baja para un objetivo " .. string.lower(d.objective) .. ".")
	end
	if c.hp < 200 and (d.objective == "Deportivo" or d.objective == "Competición") then
		table.insert(warns, "Con " .. c.hp .. " hp va a costar convencer a clientes que buscan potencia.")
	end
	if margin < 3000 then
		table.insert(warns, "El margen por unidad es bajo: subí el precio en el concesionario o bajá costos.")
	end
	local miss = {}
	for _, k in Util.keys(c.mats) do
		local have = g.materials[k] or 0
		if have < c.mats[k] then
			table.insert(miss, (c.mats[k] - have) .. " de " .. string.lower(Catalog.matLabel(k)))
		end
	end
	if #miss > 0 then
		table.insert(warns, "Hoy no tenés materiales para fabricar una unidad: faltan " .. table.concat(miss, ", ") .. ".")
	end
	if #warns > 0 then
		local nodes = {}
		for _, w in warns do
			table.insert(nodes, Ui.note("y", w))
		end
		section("Advertencias", nodes).Parent = body
	end
	local saved = e.sourceId ~= nil and not e.dirty
	local tpl
	tpl = Ui.button("Guardar como plantilla", "default", function()
		App.request("saveDesign", { draft = e.draft, template = true }, { button = tpl })
	end, { small = true, icon = "copy" })
	section("Acciones", {
		Ui.row({
			Ui.button("Enviar a producción", "default", function()
				App.openDialog("order", { designId = e.sourceId })
			end, { small = true, disabled = not saved, why = "Guardá el diseño primero", icon = "factory" }),
			Ui.button("Probar el vehículo", "default", function()
				App.openDialog("testDrive", {})
			end, { small = true, icon = "play" }),
			tpl,
			Ui.button("Descartar cambios", "d", function()
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
			end, { small = true, disabled = not e.dirty, why = "No hay cambios para descartar" }),
			Ui.button("Nuevo proyecto", "q", function()
				App.go("editor", { new = true })
			end, { small = true, icon = "plus" }),
		}, 8, { wrap = true }),
		not saved and Ui.text("Enviar a producción requiere el diseño guardado.", { size = Ui.S.xs, color = T.mut }) or nil,
	}).Parent = body
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
	local sig = visualSig(d)
	if sig ~= modelSig or not currentModel then
		modelSig = sig
		currentModel = setModel(world, currentModel, d)
		dims = CarModel.dims(d)
	end
	-- Comparación antes/después: el último guardado (o el inicio del proyecto) a la izquierda.
	local before = e.saved or e.start
	compareVp.Visible = e.compare
	if e.compare then
		local bsig = visualSig(before)
		if bsig ~= compareSig or not compareModel then
			compareSig = bsig
			compareModel = setModel(compareWorld, compareModel, before)
		end
	end

	local phone = App.isPhone()
	local k = App.scale()
	local topH = phone and 56 or 64
	local panelW = phone and math.min(App.vw * 0.48, 420) or math.min(440, App.vw * 0.36)
	local statsW = (App.layout == "desktop" or App.layout == "compact") and 300 or 0
	local vpLeft = statsW > 0 and (14 + statsW + 10) or 0
	local vpRight = panelW + 28
	local vpBottom = phone and 70 or 150
	local areaW = App.vw - vpLeft - vpRight
	if e.compare then
		compareVp.Position = UDim2.fromOffset(vpLeft * k, topH * k)
		compareVp.Size = UDim2.new(0, areaW / 2 * k, 1, -(topH + vpBottom) * k)
		viewport.Position = UDim2.fromOffset((vpLeft + areaW / 2) * k, topH * k)
		viewport.Size = UDim2.new(0, areaW / 2 * k, 1, -(topH + vpBottom) * k)
	else
		viewport.Position = UDim2.fromOffset(vpLeft * k, topH * k)
		viewport.Size = UDim2.new(1, -(vpLeft + vpRight) * k, 1, -(topH + vpBottom) * k)
	end

	-- Puntos de piezas sobre la vista.
	hotspotLayer:ClearAllChildren()
	table.clear(hotspotButtons)
	hotspotLayer.Visible = e.hotspots and not e.compare and view.cam ~= "interior"
	for _, h in CarModel.hotspots(d) do
		local b = Ui.new("TextButton", {
			Name = "Punto_" .. h.label, Text = "", Size = UDim2.fromOffset(30, 30), AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = Color3.fromHex("#111319"), BackgroundTransparency = 0.15, Corner = 15, Stroke = { T.tx, 2, 0.15 },
		}, {
			Ui.new("Frame", { Size = UDim2.fromOffset(9, 9), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundColor3 = T.tx, BackgroundTransparency = 0, Corner = 5 }),
			Ui.new("TextLabel", { Text = h.label, TextSize = 12, Weight = W.bold, Position = UDim2.fromOffset(36, 4), Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = Color3.fromHex("#080A0F"), BackgroundTransparency = 0.15, Corner = 6, Pad = { 0, 8 } }),
		})
		b.Parent = hotspotLayer
		local scale = Instance.new("UIScale")
		scale.Scale = k
		scale.Parent = b
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

	-- Barra superior (.ed-top)
	local status = e.sourceId and (e.dirty and "Cambios sin guardar" or "Guardado") or "Borrador"
	local statusKind = status == "Guardado" and "cg" or (status == "Borrador" and "cn" or "cy")
	local moneyLabel = Ui.inline(Util.money(g.money), { size = 15, weight = W.bold })
	App.live(function(gg: any)
		moneyLabel.Text = Util.money(gg.money)
	end)
	Ui.row({
		Ui.ico("pen", T.vi2, Color3.fromHex("#211D45"), 32),
		(not phone) and Ui.inline("Diseño", { size = Ui.S.h2, weight = W.bold }) or nil,
		Ui.inline(d.name .. (e.sourceId and (" · v" .. tostring(d.version or 1)) or ""), { size = Ui.S.sm, color = T.mut }),
		Ui.chip("● " .. status, statusKind),
		Ui.button("", "default", Screen.undo, { small = true, width = 36, icon = "undo", disabled = #e.undo == 0, why = "Nada para deshacer", name = "Deshacer" }),
		Ui.button("", "default", Screen.redo, { small = true, width = 36, icon = "redo", disabled = #e.redo == 0, why = "Nada para rehacer", name = "Rehacer" }),
		Ui.spacer(),
		(not phone) and Ui.inline("Dinero", { size = Ui.S.xs, color = T.mut, weight = W.bold }) or nil,
		moneyLabel,
		(statsW == 0) and Ui.button("Estadísticas", "default", function()
			e.statsOpen = not e.statsOpen
			App.forceRender()
		end, { small = true, icon = "chart" }) or nil,
		Ui.button("Salir", "default", function()
			App.go("juego")
		end, { small = true, name = "SalirEditor" }),
	}, phone and 6 or 12, {
		Name = "BarraEditor", Size = UDim2.new(1, 0, 0, topH), AutomaticSize = Enum.AutomaticSize.None, BackgroundColor3 = T.bg,
		BackgroundTransparency = 0.25, Pad = { 0, 12, 0, phone and 96 or 150 }, Parent = parent,
	})

	if statsW > 0 or e.statsOpen then
		local card = statsCard(g, d)
		if statsW > 0 then
			card.Position = UDim2.fromOffset(14, topH + 14)
			card.Size = UDim2.fromOffset(300, 0)
			card.Parent = parent
		else
			local holder = Ui.scroll({ card }, { name = "EstadisticasMovil", pad = 0 })
			holder.Position = UDim2.fromOffset(8, topH + 8)
			holder.Size = UDim2.new(1, -(panelW + 24), 1, -(topH + 16))
			holder.ZIndex = 5
			holder.Parent = parent
		end
	end

	-- Controles de cámara y comparación (sobre la vista).
	table.clear(camButtons)
	local camRow: { Instance? } = {}
	for _, cam in CAMS do
		local b = Ui.button(cam[2], view.cam == cam[1] and "v" or "default", function()
			Screen.setCam(cam[1])
			if cam[1] == "interior" and e.step == 3 and e.tab ~= "int" then
				e.tab = "int"
				App.forceRender()
			end
		end, { small = true, height = 30, name = "Camara_" .. cam[1] })
		camButtons[cam[1]] = b
		table.insert(camRow, b)
	end
	local tools: { Instance? } = {
		Ui.button("", "default", function()
			view.zoom = math.clamp(view.zoom * 0.85, ZOOM_MIN, ZOOM_MAX)
		end, { small = true, width = 34, height = 30, icon = "zoomin", name = "Acercar" }),
		Ui.button("", "default", function()
			view.zoom = math.clamp(view.zoom * 1.18, ZOOM_MIN, ZOOM_MAX)
		end, { small = true, width = 34, height = 30, icon = "zoomout", name = "Alejar" }),
		Ui.button("", "default", function()
			view.yaw = (view.yaw + 30) % 360
			view.cam = "libre"
			Screen.refreshCamButtons()
		end, { small = true, width = 34, height = 30, icon = "rotate", name = "Girar" }),
		Ui.button("", "default", function()
			Screen.setCam("angulo")
		end, { small = true, width = 34, height = 30, icon = "reset", name = "RestablecerCamara" }),
		Ui.button(view.auto and "Giro: sí" or "Giro: no", view.auto and "v" or "default", function()
			view.auto = not view.auto
			App.forceRender()
		end, { small = true, height = 30 }),
		Ui.button("Comparar", e.compare and "v" or "default", function()
			e.compare = not e.compare
			App.forceRender()
		end, { small = true, height = 30, icon = "compare", name = "Comparar" }),
		Ui.button("Puntos", e.hotspots and "v" or "default", function()
			e.hotspots = not e.hotspots
			App.forceRender()
		end, { small = true, height = 30, name = "Puntos" }),
	}
	Ui.col({
		Ui.row(camRow, 4, { wrap = true }),
		Ui.row(tools, 4, { wrap = true }),
		e.compare and Ui.row({ Ui.chip("ANTES · " .. (e.saved and "último guardado" or "inicio del proyecto"), "cn"), Ui.spacer(), Ui.chip("AHORA", "cv") }, 6) or nil,
	}, 6, { Name = "Camaras", Position = UDim2.fromOffset(vpLeft + 8, topH + 8), Size = UDim2.fromOffset(areaW - 16, 0), Parent = parent })

	-- Panel derecho (.ed-panel)
	local panel = Ui.new("Frame", {
		Name = "PanelEditor", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, phone and 0 or -14, 0, topH + (phone and 0 or 14)),
		Size = UDim2.new(0, panelW, 1, -(topH + (phone and 0 or 28))), BackgroundColor3 = Color3.fromHex("#0E1016"), BackgroundTransparency = 0.04,
		Corner = phone and 0 or 16, Stroke = Color3.fromHex("#2A2E39"), ClipsDescendants = true, Parent = parent,
	})
	local progress = {}
	for n = 1, 4 do
		table.insert(progress, Ui.grow(Ui.new("Frame", { Size = UDim2.new(1, 0, 0, 3), BackgroundColor3 = n <= e.step and T.vi or T.p3, BackgroundTransparency = 0, Corner = 2 }), { Size = UDim2.new(0, 0, 0, 3) }))
	end
	local head = Ui.col({
		Ui.row({ Ui.lbl("Diseñar · Paso " .. e.step .. " de 4"), Ui.spacer(), Ui.button("", "default", function()
			App.openDialog("help", { screen = "editor" })
		end, { small = true, width = 36, icon = "help" }) }, 8),
		Ui.row({ Ui.grow(Ui.text(STEPS[e.step][2], { size = Ui.S.h2, weight = W.bold })), Ui.chip("● " .. status, statusKind) }, 8),
		Ui.row(progress, 4),
	}, 10, { Name = "Cabecera", Pad = { 12, 16, 10, 16 }, Size = UDim2.new(1, 0, 0, 0) })
	head.Parent = panel
	local pend = DesignCalc.devPending(g, d)
	local footMoney = Ui.inline(Util.money(g.money), { size = Ui.S.sm, weight = W.bold })
	App.live(function(gg: any)
		footMoney.Text = Util.money(gg.money)
	end)
	local nextBtn: Instance? = nil
	local body = Ui.scroll({}, { name = "CuerpoPaso", gap = 18, pad = { 14, 16, 16, 16 } })
	if e.step == 1 then
		panelBase(g, d, body)
	elseif e.step == 2 then
		nextBtn = panelPerf(g, d, body)
	elseif e.step == 3 then
		panelDesign(g, d, body)
	else
		panelReview(g, d, c, body)
		local saved = e.sourceId ~= nil and not e.dirty
		local sb
		sb = Ui.button((e.sourceId and "Guardar cambios" or "Guardar diseño") .. (pend > 0 and (" · " .. Util.money(pend)) or ""), "p", function()
			save(sb)
		end, { flex = 2, icon = "check", name = "GuardarDiseno", disabled = saved or pend > g.money, why = saved and "No hay cambios para guardar" or ("Fondos insuficientes: el desarrollo cuesta " .. Util.money(pend)) })
		nextBtn = sb
	end
	if not nextBtn then
		nextBtn = Ui.button("Siguiente", "p", function()
			if Util.charCount(Util.trim(e.draft.name)) < 2 then
				App.toast("error", "Poné un nombre al proyecto antes de seguir.")
				return
			end
			e.step = math.min(4, e.step + 1)
			e.sel = nil
			App.forceRender()
		end, { flex = 2, name = "Siguiente" })
	end
	local back = e.step > 1 and Ui.button("Volver", "default", function()
		e.step -= 1
		e.sel = nil
		App.forceRender()
	end, { flex = 1 }) or Ui.button("Salir", "default", function()
		App.go("juego")
	end, { flex = 1 })
	local foot = Ui.col({
		Ui.line("Desarrollo pendiente <font color=\"#7D8493\">(una vez al guardar)</font>", pend > 0 and Util.money(pend) or "$0", { leftColor = T.mut, color = pend > 0 and T.or_ or T.gr }),
		(not phone) and Ui.line("Fabricación por unidad <font color=\"#7D8493\">(al fabricar)</font>", Util.money(c.unitCost), { leftColor = T.mut }) or nil,
		Ui.row({ Ui.grow(Ui.text("Dinero disponible", { size = Ui.S.sm, color = T.mut })), footMoney }, 8),
		pend > g.money and Ui.note("y", "No alcanza el dinero para el desarrollo. Elegí piezas más simples o conseguí fondos.") or nil,
		Ui.row({ back, nextBtn }, 8),
	}, 6, { Name = "Pie", BackgroundColor3 = Color3.fromHex("#0D0F14"), BackgroundTransparency = 0, Pad = { 10, 16, 12, 16 }, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1) })
	foot.Parent = panel
	body.Parent = panel
	App.keepScroll(body, "editor:" .. e.step .. ":" .. tostring(e.cat) .. ":" .. tostring(e.tab))
	-- El cuerpo ocupa el espacio entre la cabecera y el pie; el pie siempre queda visible.
	local function fit()
		local kk = App.scale()
		local top = head.AbsoluteSize.Y / kk
		local bottom = foot.AbsoluteSize.Y / kk
		body.Position = UDim2.fromOffset(0, top)
		body.Size = UDim2.new(1, 0, 1, -(top + bottom))
	end
	head:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	foot:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	task.defer(fit)

	-- Pasos (.steps)
	local stepButtons = {}
	for _, st in STEPS do
		local n = st[1]
		local current = e.step == n
		local done = n < e.step
		local btn = Ui.new("TextButton", {
			Name = "Paso_" .. n, Text = "", BackgroundColor3 = current and Color3.fromHex("#1E1B3D") or Color3.fromHex("#111319"), BackgroundTransparency = 0.05,
			Size = UDim2.fromOffset(0, phone and 38 or 44), AutomaticSize = Enum.AutomaticSize.X, Corner = 22, Stroke = current and T.vi or Color3.fromHex("#2A2E39"),
			Pad = { 0, phone and 6 or 14, 0, 6 }, List = { dir = "H", gap = 8, v = "C" },
		}, {
			Ui.new("TextLabel", { Text = done and "✓" or tostring(n), TextSize = 13, Weight = W.heavy, TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = done and Color3.fromHex("#05230F") or T.tx, BackgroundColor3 = current and T.vi or (done and T.gr or T.p3), BackgroundTransparency = 0, Size = UDim2.fromOffset(28, 28), Corner = 14 }),
			(App.layout == "desktop") and Ui.inline(st[2], { size = 14, weight = W.semi, color = current and T.tx or Color3.fromHex("#B4BAC6") }) or nil,
		})
		btn.Activated:Connect(function()
			if n > 1 and Util.charCount(Util.trim(e.draft.name)) < 2 then
				App.toast("error", "Poné un nombre al proyecto antes de seguir.")
				return
			end
			e.step = n
			e.sel = nil
			App.forceRender()
		end)
		table.insert(stepButtons, btn)
	end
	Ui.row(stepButtons, 6, {
		Name = "Pasos", h = "C", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0, vpLeft + areaW / 2, 1, -12),
		Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, Parent = parent,
	})
end

return Screen
