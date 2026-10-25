--!strict
--[[
	Núcleo de la interfaz del cliente: recibe el estado del servidor, decide qué pantalla mostrar,
	reconstruye solo cuando cambia la estructura y actualiza en vivo relojes, barras y dinero.
	El cliente nunca calcula resultados de dinero: todo pasa por App.request → servidor.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Ui = require(script.Parent.Ui)
local T = Ui.T

local App = {}

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("CarEmpireRemotes")
local Request = remotes:WaitForChild("Request") :: RemoteFunction

App.payload = nil :: any -- último estado recibido { status, saveMode, saveWarning, loadError, game }
App.g = nil :: any -- vista de la partida
App.ui = {
	route = "juego",
	tabs = {},
	editor = nil,
	dialog = nil,
	busy = {},
	newCompany = { name = "", color = "#7667FF", difficulty = "normal" },
}
App.screens = {} :: { [string]: any }
App.dialogs = {} :: { [string]: any }

local liveFns: { (any) -> () } = {}
local dialogLive: { (any) -> () } = {}
local scrollMem: { [string]: Vector2 } = {}
local lastSig: string? = nil
local lastDialogSig: string? = nil
local pendingRebuild = false

-- Raíz ------------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "CarEmpireUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 5
gui.Parent = player:WaitForChild("PlayerGui")

local scaleObj = Instance.new("UIScale")
scaleObj.Parent = gui

local function layer(name: string, z: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.Size = UDim2.fromScale(1, 1)
	f.ZIndex = z
	f.Parent = gui
	return f
end

App.content = layer("Contenido", 1)
App.dialogLayer = layer("Dialogos", 50)
App.toastLayer = layer("Avisos", 60)

local toastList = Ui.new("Frame", {
	Name = "Pila",
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -16, 1, -24),
	Size = UDim2.fromOffset(360, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	List = { dir = "V", gap = 8, v = "B" },
	Parent = App.toastLayer,
})

-- Tamaño virtual (en «píxeles de la V3») para decidir el diseño.
App.vw = 1280
App.vh = 720
local function updateScale()
	local cam = Workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	local s = math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.55, 1)
	scaleObj.Scale = s
	App.vw = vp.X / s
	App.vh = vp.Y / s
end
updateScale()

-- Controles del personaje: se desactivan con paneles de pantalla completa abiertos.
local controls: any = nil
task.spawn(function()
	local ok, mod = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: any)
	end)
	if ok and mod then
		controls = mod:GetControls()
	end
end)
local function setControls(enabled: boolean)
	if controls then
		if enabled then
			controls:Enable()
		else
			controls:Disable()
		end
	end
end

-- Avisos (toasts) ---------------------------------------------------------------------
local TOAST_BORDER = { ok = T.gr, aviso = T.ye, error = T.re, info = T.vi, nivel = T.vi }
local TOAST_ICON = { ok = "✓", aviso = "⚠", error = "✕", info = "ⓘ", nivel = "★" }
function App.toast(kind: string, text: string)
	if not text or text == "" then
		return
	end
	local t = Ui.new("Frame", {
		Name = "Aviso",
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0.03,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Corner = 12,
		Stroke = TOAST_BORDER[kind] or T.line,
		Pad = { 10, 12 },
		List = { dir = "H", gap = 10, v = "C" },
	}, {
		Ui.inline(TOAST_ICON[kind] or "•", { color = TOAST_BORDER[kind] or T.tx, weight = Ui.W.bold, size = 15 }),
		Ui.grow(Ui.text(text, { size = Ui.S.sm, lineHeight = 1.2 }), { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }),
	})
	t.Parent = toastList
	Ui.fadeIn(t)
	local kids = toastList:GetChildren()
	local frames = {}
	for _, k in kids do
		if k:IsA("Frame") then
			table.insert(frames, k)
		end
	end
	if #frames > 5 then
		table.sort(frames, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		frames[1]:Destroy()
	end
	task.delay(kind == "error" and 6 or 4.5, function()
		if t.Parent then
			t:Destroy()
		end
	end)
end
Ui.onDisabled = function(why: string)
	App.toast("aviso", why)
end

-- Red ---------------------------------------------------------------------------------
-- Envía una acción al servidor. Evita dobles clics: la misma acción no se repite mientras espera.
function App.request(action: string, payload: any?): any
	if App.ui.busy[action] then
		return { ok = false, msg = "", quiet = true }
	end
	App.ui.busy[action] = true
	local ok, result = pcall(function()
		return Request:InvokeServer(action, payload)
	end)
	App.ui.busy[action] = nil
	if not ok or type(result) ~= "table" then
		App.toast("error", "No hubo respuesta del servidor. Probá de nuevo.")
		return { ok = false, msg = "" }
	end
	if result.msg and result.msg ~= "" and not result.quiet then
		App.toast(result.ok and "ok" or "error", result.msg)
	end
	return result
end

-- Live bindings -------------------------------------------------------------------------
-- fn(g) se ejecuta en cada actualización del servidor sin reconstruir la pantalla.
function App.live(fn: (any) -> ())
	table.insert(liveFns, fn)
	if App.g then
		fn(App.g)
	end
end
function App.dialogLive(fn: (any) -> ())
	table.insert(dialogLive, fn)
	if App.g then
		fn(App.g)
	end
end

function App.keepScroll(s: ScrollingFrame, key: string)
	local pos = scrollMem[key]
	s:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		scrollMem[key] = s.CanvasPosition
	end)
	if pos then
		task.defer(function()
			s.CanvasPosition = pos
		end)
	end
end

-- Firma estructural: el estado sin los campos que cambian cada segundo.
local function structuralSig(p: any): string
	if not p then
		return "nil"
	end
	local g = p.game
	local stripped: any = { s = p.status, m = p.saveMode, w = p.saveWarning, e = p.loadError }
	if g then
		local copy = table.clone(g)
		copy.time = { day = g.time.day, speed = g.time.speed }
		copy.notifications = #g.notifications
		local orders = {}
		for _, o in g.production.orders do
			local oc = table.clone(o)
			oc.progress = nil
			oc.design = o.design and o.design.version or nil
			table.insert(orders, oc)
		end
		copy.production = { orders = orders, history = g.production.history }
		local customers = {}
		for _, c in g.customers do
			local cc = table.clone(c)
			cc.waited = nil
			table.insert(customers, cc)
		end
		copy.customers = customers
		stripped.g = copy
	end
	local ok, enc = pcall(HttpService.JSONEncode, HttpService, stripped)
	return ok and enc or tostring(os.clock())
end

-- Navegación ----------------------------------------------------------------------------
local FULLSCREEN = { editor = true, fabrica = true, autos = true, ventas = true }

function App.go(route: string, params: any?)
	if App.ui.route == "editor" and route ~= "editor" and App.screens.editor and App.screens.editor.leave then
		App.screens.editor.leave()
	end
	App.ui.route = route
	App.ui.params = params or {}
	if route == "editor" and App.screens.editor and App.screens.editor.enter then
		App.screens.editor.enter(App.ui.params)
	end
	App.closeDialog()
	App.render()
end

function App.openDialog(kind: string, params: any?)
	App.ui.dialog = { kind = kind, params = params or {} }
	lastDialogSig = nil
	App.renderDialog()
end

function App.closeDialog()
	if App.ui.dialog then
		App.ui.dialog = nil
		App.renderDialog()
	end
end

-- Construcción ---------------------------------------------------------------------------
local function clearChildren(f: Instance)
	for _, c in f:GetChildren() do
		if not c:IsA("UIBase") then
			c:Destroy()
		end
	end
end

function App.renderDialog()
	clearChildren(App.dialogLayer)
	table.clear(dialogLive)
	local d = App.ui.dialog
	if not d or not App.g then
		return
	end
	local builder = App.dialogs[d.kind]
	if not builder then
		return
	end
	local back = Ui.new("TextButton", {
		Name = "Fondo",
		Text = "",
		BackgroundColor3 = Color3.fromHex("#040508"),
		BackgroundTransparency = 0.28,
		Size = UDim2.fromScale(1, 1),
		AutoButtonColor = false,
		Parent = App.dialogLayer,
	})
	back.Activated:Connect(function() end)
	local width = d.params.wide and 760 or 560
	local box = Ui.new("Frame", {
		Name = "Dialogo",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(math.min(width, App.vw - 32), 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Corner = 16,
		Stroke = T.btnLine,
		List = { dir = "V", gap = 0 },
		ClipsDescendants = true,
		Parent = App.dialogLayer,
	})
	local maxH = Instance.new("UISizeConstraint")
	maxH.MaxSize = Vector2.new(width, App.vh - 32)
	maxH.Parent = box
	builder(box, d.params)
	Ui.fadeIn(box)
	lastDialogSig = d.sig and d.sig(App.g) or nil
end

function App.render()
	clearChildren(App.content)
	table.clear(liveFns)
	pendingRebuild = false
	local p = App.payload
	if not p then
		App.screens.status.loading(App.content)
		return
	end
	if p.status == "loading" then
		setControls(false)
		App.screens.status.loading(App.content)
		return
	end
	if p.status == "failed" then
		setControls(false)
		App.screens.status.failed(App.content, p)
		return
	end
	if not App.g then
		setControls(false)
		App.screens.company.build(App.content)
		return
	end
	local route = App.ui.route
	setControls(not FULLSCREEN[route])
	if route == "editor" then
		App.screens.editor.build(App.content)
	else
		App.screens.hud.build(App.content, route)
		if route ~= "juego" and App.screens[route] then
			App.screens.sheet.build(App.content, route)
		end
	end
	App.screens.status.banners(App.content, p)
end

-- Estado entrante --------------------------------------------------------------------------
function App.onState(payload: any)
	local hadGame = App.g ~= nil
	App.payload = payload
	App.g = payload.game
	if not hadGame and App.g then
		App.ui.route = "juego"
	end
	local sig = structuralSig(payload)
	local focused = UserInputService:GetFocusedTextBox()
	if sig ~= lastSig or pendingRebuild then
		if focused and focused:IsDescendantOf(gui) then
			pendingRebuild = true
			lastSig = sig
		else
			lastSig = sig
			App.render()
			if App.ui.dialog then
				local d = App.ui.dialog
				local ds = d.sig and App.g and d.sig(App.g) or nil
				if d.rebuildAlways or ds ~= lastDialogSig then
					App.renderDialog()
				end
			end
		end
	end
	if App.g then
		for _, fn in liveFns do
			pcall(fn, App.g)
		end
		for _, fn in dialogLive do
			pcall(fn, App.g)
		end
	end
end

function App.forceRender()
	lastSig = nil
	if App.payload then
		App.onState(App.payload)
	else
		App.render()
	end
end

-- Al soltar un campo de texto se aplican las reconstrucciones pendientes.
UserInputService.TextBoxFocusReleased:Connect(function()
	task.defer(function()
		if pendingRebuild and App.payload then
			App.render()
		end
	end)
end)

local cam = Workspace.CurrentCamera
if cam then
	cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		updateScale()
		App.forceRender()
		if App.ui.dialog then
			App.renderDialog()
		end
	end)
end

App.gui = gui
return App
