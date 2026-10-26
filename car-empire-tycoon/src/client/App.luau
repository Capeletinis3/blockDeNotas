--!strict
--[[
	Núcleo de la interfaz del cliente: recibe el estado del servidor, decide qué pantalla mostrar,
	reconstruye solo cuando cambia la estructura y actualiza en vivo relojes, barras y dinero.
	El cliente nunca decide resultados: todo pasa por App.request → servidor.

	Distribuciones: "desktop" · "compact" (computadora chica) · "tablet" · "phone".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Rules = require(Shared.Rules)
local Util = require(Shared.Util)
local Ui = require(script.Parent.Ui)
local T = Ui.T

local App = {}

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("CarEmpireRemotes")
local Request = remotes:WaitForChild("Request") :: RemoteFunction

App.payload = nil :: any -- último estado { status, saveMode, saveWarning, blocked, loadError, profile, game }
App.g = nil :: any -- vista de la empresa activa
App.profile = nil :: any
App.settings = { sound = true, reduceMotion = false, keyHints = true, textScale = 1, camSpeed = 1, tips = true }
App.ui = {
	route = "menu",
	params = {},
	tabs = {},
	filters = {},
	collapsed = {},
	editor = nil,
	dialogs = {},
	newCompany = { name = "", color = "#7667FF", logo = "pico", difficulty = "normal", slot = "1" },
	sidePanel = nil, -- celular: panel lateral abierto ("l" | "r")
	statRange = 12,
	pop = nil, -- menú emergente abierto: "more" | "mob"
	popX = nil,
	panelsHidden = false, -- «Ocultar paneles» (Tab)
	newsHidden = false, -- cinta de noticias
	allSale = false,
}
App.screens = {} :: { [string]: any }
App.dialogBuilders = {} :: { [string]: any }

local liveFns: { (any) -> () } = {}
local dialogLive: { (any) -> () } = {}
local scrollMem: { [string]: Vector2 } = {}
local lastSig: string? = nil
local lastDialogSig: string? = nil
local pendingRebuild = false

-- Raíz ----------------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "CarEmpireUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 5
gui.Parent = player:WaitForChild("PlayerGui")

-- Raíz escalada: un UIScale dentro de un marco de tamaño 1/escala hace que, ya escalado, cubra justo la
-- pantalla (un UIScale bajo el ScreenGui achicaría también los marcos de tamaño 1,0,1,0).
local root = Instance.new("Frame")
root.Name = "Raiz"
root.BackgroundTransparency = 1
root.BorderSizePixel = 0
root.Size = UDim2.fromScale(1, 1)
root.Parent = gui
local scaleObj = Instance.new("UIScale")
scaleObj.Parent = root

local function layer(name: string, z: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BackgroundTransparency = 1
	f.Size = UDim2.fromScale(1, 1)
	f.ZIndex = z
	f.Parent = root
	return f
end

App.content = layer("Contenido", 1)
App.popLayer = layer("Menus", 40)
App.dialogLayer = layer("Dialogos", 50)
App.dropLayer = layer("Desplegables", 55)
App.toastLayer = layer("Avisos", 60)

local toastSeq = 0
local toastList = Ui.new("Frame", {
	Name = "Pila",
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -16, 1, -56),
	Size = UDim2.fromOffset(360, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	List = { dir = "V", gap = 8, v = "B" },
	Parent = App.toastLayer,
})

-- Tamaño virtual y distribución -------------------------------------------------------------
App.vw = 1280
App.vh = 720
App.layout = "desktop"
App.touch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

local function updateScale()
	local cam = Workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
	-- Como la V3, la interfaz no se achica: en pantallas chicas cambia la distribución. El tamaño del
	-- texto (Configuración) agranda solo los textos, igual que la escala de rem de la V3.
	local s = 1
	scaleObj.Scale = s
	root.Size = UDim2.fromScale(1 / s, 1 / s)
	Ui.textScale = App.settings.textScale or 1
	App.vw = vp.X / s
	App.vh = vp.Y / s
	-- Cortes de la V3: ≤900 px celular, ≤600 celular angosto, ≤1100 tableta, ≤1560 escritorio compacto.
	if App.vw <= 900 or App.vh < 480 then
		App.layout = "phone"
	elseif App.vw <= 1100 then
		App.layout = "tablet"
	elseif App.vw <= 1560 then
		App.layout = "compact"
	else
		App.layout = "desktop"
	end
	App.narrowPhone = App.vw <= 600
	-- Como en el CSS de la V3: a ≤900 px las grillas de 3 y 4 columnas pasan a 2.
	Ui.gridTwo = App.vw <= 900
	toastList.Size = UDim2.fromOffset(math.min(360, App.vw - 32), 0)
	toastList.Position = App.layout == "phone" and UDim2.new(1, -16, 1, -90) or UDim2.new(1, -16, 1, -56)
	toastList.AnchorPoint = Vector2.new(1, 1)
end
updateScale()

function App.isPhone(): boolean
	return App.layout == "phone"
end
function App.isNarrow(): boolean
	return App.layout == "phone" or App.layout == "tablet"
end

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

-- Avisos (toasts) ----------------------------------------------------------------------------
-- Sonido breve de la interfaz (Configuración › Sonidos). Usa un sonido incluido en Roblox.
local SoundService = game:GetService("SoundService")
local ping = Instance.new("Sound")
ping.Name = "AvisoInterfaz"
ping.SoundId = "rbxasset://sounds/electronicpingshort.wav"
ping.Volume = 0.35
function App.playSound(kind: string)
	if not App.settings.sound then
		return
	end
	-- Como la V3 (WebAudio): clic corto en cada acción, subida al confirmar y bajada en los errores.
	ping.PlaybackSpeed = kind == "error" and 0.7 or (kind == "aviso" and 0.85 or (kind == "click" and 1.6 or 1.1))
	ping.Volume = kind == "click" and 0.12 or 0.35
	pcall(function()
		SoundService:PlayLocalSound(ping)
	end)
end

-- Avisos flotantes (UI_TOAST de la V3): ícono de color, texto y botón para cerrar; como máximo 4.
local TOAST_STROKE = { ok = { T.gr, 0.5 }, aviso = { T.ye, 0.5 }, error = { T.re, 0.45 }, info = { T.vi, 0.45 }, nivel = { T.vi, 0.45 } }
local TOAST_COLOR = { ok = T.gr, aviso = T.ye, error = T.re2, info = T.vi2, nivel = T.vi2 }
local TOAST_ICON2 = { ok = "check", aviso = "warn", error = "x", info = "bell", nivel = "bell" }
function App.toast(kind: string, text: string)
	if not text or text == "" then
		return
	end
	if kind == "ok" or kind == "error" then
		App.playSound(kind)
	end
	local st = TOAST_STROKE[kind] or { T.line, 0 }
	local close = Ui.button("", "q", nil, { small = true, icon = "x", iconSize = 14, name = "CerrarAviso" })
	local t = Ui.new("Frame", {
		Name = "Aviso",
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0.03,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Corner = 12,
		Stroke = { st[1], 1, 1 - st[2] },
		Pad = { 10, 12 },
		List = { dir = "H", gap = 10, v = "C" },
	}, {
		Ui.icon(TOAST_ICON2[kind] or "bell", 16, TOAST_COLOR[kind] or T.vi2),
		Ui.grow(Ui.text(text, { size = 13, lineHeight = 1.25 }), { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }),
		close,
	})
	close.Activated:Connect(function()
		t:Destroy()
	end)
	-- El más nuevo abajo (column-reverse de la V3); en el editor, arriba al centro y el más nuevo arriba.
	toastSeq -= 1
	t.LayoutOrder = App.ui.route == "editor" and toastSeq or -toastSeq
	t.Parent = toastList
	Ui.fadeIn(t)
	local frames = {}
	for _, k in toastList:GetChildren() do
		if k:IsA("Frame") then
			table.insert(frames, k)
		end
	end
	if #frames > 4 then
		table.sort(frames, function(a, b)
			return math.abs(a.LayoutOrder) < math.abs(b.LayoutOrder)
		end)
		frames[1]:Destroy()
	end
	task.delay(kind == "error" and 9 or 4.5, function()
		if t.Parent then
			t:Destroy()
		end
	end)
end
function App.placeToasts()
	if App.ui.route == "editor" then
		toastList.AnchorPoint = Vector2.new(0.5, 0)
		toastList.Position = UDim2.new(0.5, 0, 0, 78)
	elseif App.layout == "phone" then
		toastList.AnchorPoint = Vector2.new(1, 1)
		toastList.Position = UDim2.new(1, -16, 1, -90)
	else
		toastList.AnchorPoint = Vector2.new(1, 1)
		toastList.Position = UDim2.new(1, -16, 1, -56)
	end
end
Ui.onClickSound = function()
	App.playSound("click")
end
Ui.onDisabled = function(why: string)
	App.toast("aviso", why)
end

-- Red ----------------------------------------------------------------------------------------
--[[
	Envía una acción al servidor con un identificador único (un reenvío nunca se aplica dos veces).
	opts.button: botón que muestra «Procesando…» mientras espera. Mientras la misma acción está en
	curso, otro clic no sale de nuevo. El servidor valida todo igual: esto solo evita esperas confusas.
]]
local inFlight: { [string]: boolean } = {}
function App.request(action: string, payload: any?, opts: any?): any
	local key = action .. (opts and opts.key or "")
	if inFlight[key] then
		return { ok = false, msg = "", quiet = true, pending = true }
	end
	inFlight[key] = true
	local btn = opts and opts.button
	if btn then
		Ui.setBusy(btn, true)
	end
	local body = type(payload) == "table" and table.clone(payload) or {}
	body.requestId = HttpService:GenerateGUID(false)
	local ok, result = pcall(function()
		return Request:InvokeServer(action, body)
	end)
	inFlight[key] = nil
	if btn then
		Ui.setBusy(btn, false)
	end
	if not ok or type(result) ~= "table" then
		App.toast("error", "No hubo respuesta del servidor. Probá de nuevo: tus datos escritos se conservan.")
		return { ok = false, msg = "" }
	end
	if result.msg and result.msg ~= "" and not result.quiet then
		App.toast(result.ok and "ok" or "error", result.msg)
	end
	return result
end

-- Valores en vivo -----------------------------------------------------------------------------
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
	local stripped: any = { s = p.status, m = p.saveMode, w = p.saveWarning, b = p.blocked, e = p.loadError, pr = p.profile, r = App.ui.route }
	if g then
		local copy = table.clone(g)
		copy.time = { day = g.time.day, speed = g.time.speed }
		copy.ledger = #g.ledger
		copy.stats = nil
		copy.derived = nil
		-- Lotes: solo lo que cambia la estructura (estado, precio, si hay stock); los contadores se
		-- actualizan en vivo sin reconstruir.
		local lots = {}
		for _, l in g.lots do
			table.insert(lots, { l.id, l.prodState, l.saleState, l.price, l.produced < l.qty, l.produced - l.sold - l.discarded > 0 })
		end
		copy.lots = lots
		copy.lotHistory = #g.lotHistory > 0 and g.lotHistory[1].id or nil
		-- Contadores que cambian con cada venta: van en tramos (las misiones se recalculan al cruzar uno).
		local counters = table.clone(g.counters)
		for _, k in { "unitsSold", "unitsProduced", "revenueTotal", "marginTotal" } do
			counters[k] = counters[k] and math.floor(math.log(counters[k] + 1) / math.log(1.25)) or nil
		end
		copy.counters = counters
		copy.rp = math.floor(g.rp / 5)
		-- El dinero cambia cada segundo: se reconstruye solo cuando cambia un 25 % (botones habilitados).
		copy.money = math.floor(math.log(math.max(1, g.money)) / math.log(1.25))
		copy.reputation = math.floor(g.reputation * 10)
		-- Misiones que pasan a «lista para reclamar» (botones de recompensa).
		local ready = {}
		for _, m in Catalog.MISSIONS do
			table.insert(ready, Rules.missionState(g, m) == "lista" and 1 or 0)
		end
		copy.ready = table.concat(ready)
		local emps = {}
		for _, e in g.employees do
			table.insert(emps, { e.id, e.assign })
		end
		copy.employees = emps
		copy.research = { done = g.research.done, active = g.research.active and g.research.active.id }
		stripped.g = copy
	end
	local ok, enc = pcall(HttpService.JSONEncode, HttpService, stripped)
	return ok and enc or tostring(os.clock())
end

-- Navegación ------------------------------------------------------------------------------------
local FULLSCREEN = {
	editor = true, fabrica = true, autos = true, ventas = true, mercado = true, investigacion = true,
	personal = true, compania = true, misiones = true, estadisticas = true, menu = true, nueva = true,
}

-- Si el editor tiene cambios sin guardar, pregunta antes de seguir (guardar, descartar o seguir editando).
function App.guardEditor(proceed: () -> ())
	local ed = App.ui.editor
	if App.ui.route == "editor" and ed and ed.dirty and App.screens.editor and App.screens.editor.askUnsaved then
		App.screens.editor.askUnsaved(proceed)
	else
		proceed()
	end
end

function App.go(route: string, params: any?)
	if route == "editor" and App.screens.editor and App.screens.editor.needsConfirm(params) then
		-- Abrir otro proyecto reemplazaría un borrador con cambios: preguntar primero.
		App.screens.editor.askReplace(params)
		return
	end
	local function doIt()
		if App.ui.route == "editor" and route ~= "editor" and App.screens.editor and App.screens.editor.leave then
			App.screens.editor.leave()
		end
		App.ui.route = route
		App.ui.params = params or {}
		App.ui.sidePanel = nil
		App.ui.pop = nil
		if route == "editor" and App.screens.editor and App.screens.editor.enter then
			App.screens.editor.enter(App.ui.params)
		end
		App.closeAllDialogs()
		App.forceRender()
	end
	if App.ui.route == "editor" and route ~= "editor" then
		App.guardEditor(doIt)
	else
		doIt()
	end
end

-- Diálogos (pila: un diálogo puede abrir una confirmación encima) ----------------------------------
function App.openDialog(kind: string, params: any?)
	table.insert(App.ui.dialogs, { kind = kind, params = params or {} })
	lastDialogSig = nil
	App.renderDialog()
end

function App.closeDialog()
	if #App.ui.dialogs > 0 then
		table.remove(App.ui.dialogs)
		App.renderDialog()
	end
end

function App.closeAllDialogs()
	if #App.ui.dialogs > 0 then
		table.clear(App.ui.dialogs)
		App.renderDialog()
	end
end

-- Volver al menú de empresas (pregunta si el editor tiene cambios sin guardar).
function App.leaveToMenu()
	App.ui.pop = nil
	App.guardEditor(function()
		App.request("leaveCompany")
		App.ui.route = "menu"
		App.closeAllDialogs()
		App.forceRender()
	end)
end

-- Lista desplegable (equivalente a <select>): se abre debajo (o encima) del botón.
function App.dropdown(anchor: GuiObject, options: { any }, value: any, onPick: (any) -> ())
	for _, c in App.dropLayer:GetChildren() do
		c:Destroy()
	end
	local function close()
		for _, c in App.dropLayer:GetChildren() do
			c:Destroy()
		end
	end
	local catcher = Ui.new("TextButton", { Name = "CerrarLista", Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = App.dropLayer })
	catcher.Activated:Connect(close)
	local s = scaleObj.Scale
	local x = (anchor.AbsolutePosition.X - root.AbsolutePosition.X) / s
	local y = (anchor.AbsolutePosition.Y - root.AbsolutePosition.Y) / s
	local w = math.max(anchor.AbsoluteSize.X / s, 180)
	local h = anchor.AbsoluteSize.Y / s
	local listH = math.min(#options * 38 + 12, 320)
	local below = y + h + 4 + listH <= App.vh - 8
	local list = Ui.new("ScrollingFrame", {
		Name = "Opciones",
		Position = UDim2.fromOffset(math.clamp(x, 8, math.max(8, App.vw - w - 8)), below and (y + h + 4) or math.max(8, y - listH - 4)),
		Size = UDim2.fromOffset(w, listH),
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Corner = 10,
		Stroke = T.line,
		Pad = 6,
		List = { dir = "V", gap = 2 },
		Parent = App.dropLayer,
	})
	for _, op in options do
		local selected = op[1] == value
		local disabled = op[3] == true
		local b = Ui.new("TextButton", {
			Name = "Opcion_" .. tostring(op[1]),
			Text = "",
			BackgroundColor3 = selected and T.vi or Color3.new(1, 1, 1),
			BackgroundTransparency = selected and 0.8 or 1,
			Size = UDim2.new(1, 0, 0, 36),
			Corner = 7,
			Pad = { 0, 10 },
			List = { dir = "H", gap = 8, v = "C" },
		}, {
			Ui.grow(Ui.inline(op[2], { size = 14, color = disabled and T.disabledTx or T.tx, truncate = true })),
			selected and Ui.icon("check", 14, T.vi2) or nil,
		})
		if not selected and not disabled then
			b.MouseEnter:Connect(function()
				b.BackgroundTransparency = 0.94
			end)
			b.MouseLeave:Connect(function()
				b.BackgroundTransparency = 1
			end)
		end
		b.Activated:Connect(function()
			if disabled then
				return
			end
			close()
			if op[1] ~= value then
				onPick(op[1])
			end
		end)
		b.Parent = list
	end
end
Ui.openDropdown = function(anchor: Instance, options: { any }, value: any, onPick: (any) -> ())
	App.dropdown(anchor :: GuiObject, options, value, onPick)
end

function App.topDialog(): any
	return App.ui.dialogs[#App.ui.dialogs]
end

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
	local d = App.topDialog()
	if not d then
		return
	end
	local builder = App.dialogBuilders[d.kind]
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
	-- Como en la V3, tocar el fondo cierra el diálogo de arriba.
	back.Activated:Connect(function()
		if d.params.modal ~= true then
			App.closeDialog()
		end
	end)
	local width = math.min(d.params.wide and 760 or 560, App.vw - 32)
	local phone = App.isPhone()
	local box = Ui.new("Frame", {
		Name = "Dialogo",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = T.p1,
		BackgroundTransparency = 0,
		Corner = 16,
		Stroke = T.btnLine,
		List = { dir = "V", gap = 0 },
		ClipsDescendants = true,
		Parent = App.dialogLayer,
	})
	-- Alto máximo: pantalla − 32 px (− 16 en celular); el cuerpo se desplaza.
	App.dialogMaxBody = math.max(160, (phone and App.vh - 16 or App.vh - 32) - (phone and 175 or 150))
	local ok, err = pcall(builder, box, d.params, d)
	if not ok then
		warn("[CarEmpire] Error al construir el diálogo " .. d.kind .. ": " .. tostring(err))
	end
	Ui.fadeIn(box)
	lastDialogSig = d.sig and App.g and d.sig(App.g) or nil
end

-- Construcción de la pantalla ------------------------------------------------------------------------
function App.render()
	App.placeToasts()
	clearChildren(App.content)
	clearChildren(App.dropLayer)
	clearChildren(App.popLayer)
	table.clear(liveFns)
	pendingRebuild = false
	local p = App.payload
	local status = App.screens.status
	if not p or p.status == "loading" then
		setControls(false)
		status.loading(App.content)
		return
	end
	if p.status == "failed" then
		setControls(false)
		status.failed(App.content, p)
		return
	end
	if p.status == "lost" then
		setControls(false)
		status.lost(App.content, p)
		return
	end
	local route = App.ui.route
	if not App.g then
		if route ~= "menu" and route ~= "nueva" then
			route = "menu"
			App.ui.route = "menu"
		end
	elseif route == "menu" or route == "nueva" then
		-- Hay empresa activa pero el jugador está en el menú (por ejemplo, tras crearla): seguir al juego.
		if App.ui.enteringGame then
			App.ui.enteringGame = false
			route = "juego"
			App.ui.route = "juego"
		end
	end
	setControls(not FULLSCREEN[route])
	local ok, err = pcall(function()
		if route == "menu" then
			App.screens.menu.build(App.content)
		elseif route == "nueva" then
			App.screens.company.build(App.content)
		elseif route == "editor" then
			App.screens.editor.build(App.content)
		else
			App.screens.hud.build(App.content, route)
			if route ~= "juego" and App.screens[route] then
				App.screens.sheet.build(App.content, route)
			end
		end
	end)
	if not ok then
		warn("[CarEmpire] Error al construir la pantalla " .. route .. ": " .. tostring(err))
		App.renderError = err
	end
	status.banners(App.content, p)
end

-- Estado entrante -------------------------------------------------------------------------------
local function applySettings(settings: any)
	if not settings then
		return
	end
	local changedScale = settings.textScale ~= App.settings.textScale
	for k, v in settings do
		App.settings[k] = v
	end
	Ui.reduceMotion = App.settings.reduceMotion == true
	Ui.showKeys = App.settings.keyHints ~= false
	if changedScale then
		updateScale()
	end
end

local lastIdentity: string? = nil
local function leaveEditor()
	App.ui.editor = nil
	if App.screens.editor and App.screens.editor.leave then
		App.screens.editor.leave()
	end
end

function App.onState(payload: any)
	-- Segundo a segundo el servidor manda solo lo que cambia: se aplica sobre la última partida completa.
	if payload.tick then
		if not (App.payload and App.payload.game) then
			return
		end
		Util.mergeLive(App.payload.game, payload.live)
		payload = App.payload
	end
	local hadGame = App.g ~= nil
	App.payload = payload
	App.g = payload.game
	App.profile = payload.profile
	if payload.profile then
		applySettings(payload.profile.settings)
	end
	-- El borrador del editor pertenece a una empresa: al cambiar de ranura o entrar a una demostración
	-- no se arrastra a la otra partida.
	local identity = App.g and (tostring(payload.profile and payload.profile.active) .. "|" .. tostring(App.g.demo)) or nil
	if App.g and hadGame and identity ~= lastIdentity then
		leaveEditor()
		App.closeAllDialogs()
		App.ui.route = "juego"
	end
	lastIdentity = identity
	if App.g and not hadGame and App.ui.route ~= "editor" then
		App.ui.route = "juego"
	elseif not App.g and hadGame then
		App.ui.route = "menu"
		leaveEditor()
	end
	local sig = structuralSig(payload)
	local focused = UserInputService:GetFocusedTextBox()
	if sig ~= lastSig or pendingRebuild then
		lastSig = sig
		if focused and focused:IsDescendantOf(gui) then
			-- No se reconstruye mientras se escribe: se aplica al soltar el campo.
			pendingRebuild = true
		else
			App.render()
			local d = App.topDialog()
			if d then
				local ds = d.sig and App.g and d.sig(App.g) or nil
				if ds ~= lastDialogSig then
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

UserInputService.TextBoxFocusReleased:Connect(function()
	task.defer(function()
		if pendingRebuild and App.payload and not UserInputService:GetFocusedTextBox() then
			App.render()
		end
	end)
end)

local cam = Workspace.CurrentCamera
if cam then
	cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		updateScale()
		App.forceRender()
		if App.topDialog() then
			App.renderDialog()
		end
	end)
end

App.gui = gui
App.scale = function(): number
	return scaleObj.Scale
end
return App
