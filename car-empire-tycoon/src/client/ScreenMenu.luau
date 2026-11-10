--!strict
--[[
	Menú principal: showroom 3D de fondo (Showroom.luau) con el auto exhibido y el color de la empresa elegida.
	A la izquierda, una columna compacta con los cuatro espacios de empresa (dos gratuitos y dos que se
	desbloquean con Robux). La tarjeta elegida se expande con sus datos; las demás quedan compactas.
	Abajo a la derecha, la acción principal del espacio elegido (Continuar / Crear empresa / Desbloquear) y las
	secundarias (renombrar, eliminar). Abajo a la izquierda: configuración, novedades y demostraciones.
	El auto y su transición son del showroom: acá solo se le dice qué empresa mostrar (Showroom.show).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Showroom = require(script.Parent.Showroom)
local T = Ui.T
local W = Ui.W

local Screen = {}

Screen.NEWS = {
	version = "Actualización 2.0 · «Desde 1970»",
	title = "Lotes, ventas automáticas y 60 años de historia",
	body = "Tu empresa empieza en 1970. Diseñás un auto, elegís cuántas unidades fabricar y se venden solas según la demanda, el precio y la competencia. La sede genera puntos de investigación por minuto y las tecnologías llegan en su época, hasta los eléctricos.",
	event = "Eventos de temporada (función futura)",
	when = "Todavía no implementado",
}

-- Estilo de las tarjetas: base oscura azulada, semitransparente, borde discreto; la elegida usa el color
-- corporativo solo en el borde y en un leve tinte del fondo.
local STYLE = {
	base = Ui.hex("#0C1220"),
	baseAlpha = 0.22, -- transparencia de las compactas
	selAlpha = 0.1, -- transparencia de la elegida
	tint = 0.1, -- cuánto del color corporativo entra en el fondo de la elegida
	line = Ui.hex("#2A3347"),
	lineAlpha = 0.25,
	divider = Ui.hex("#263045"),
	radius = 14,
	shadowAlpha = 0.78,
	anim = 0.26, -- segundos de la expansión / compactación
}
Screen.STYLE = STYLE

local rename = { slot = nil :: string?, draft = "", err = "" }
function Screen.startRename(key: string)
	local s = App.profile and App.profile.slots[key]
	rename.slot, rename.draft, rename.err = key, s and s.name or "", ""
	App.forceRender()
end
function Screen.cancelRename()
	rename.slot = nil
	App.forceRender()
end
function Screen.isRenaming(): boolean
	return rename.slot ~= nil
end

local function firstSlot(): string?
	local slots = App.profile and App.profile.slots or {}
	for i = 1, Catalog.RULES.slots do
		local s = slots[tostring(i)]
		if s and not s.damaged then
			return tostring(i)
		end
	end
	return nil
end
Screen.firstSlot = firstSlot

function Screen.play(key: string, btn: any?)
	local r = App.request("selectSlot", { slot = key }, { button = btn })
	if r.ok then
		App.ui.enteringGame = true
		App.go("juego")
	end
end

-- La creación usa el formulario existente (nombre, símbolo y color); todas empiezan con Catalog.START.
function Screen.newCompany(key: string)
	local nc = App.ui.newCompany
	nc.name, nc.color, nc.logo, nc.slot = "", "#7667FF", "pico", key
	App.go("nueva")
end

-- Estado de un espacio: "company" | "damaged" | "empty" | "locked".
local function slotState(key: string): string
	local slots = App.profile and App.profile.slots or {}
	local usable = App.profile and App.profile.usable or {}
	local s = slots[key]
	if s then
		return s.damaged and "damaged" or "company"
	end
	if usable[key] or tonumber(key) <= Catalog.RULES.slotsFree then
		return "empty"
	end
	return "locked"
end
Screen.slotState = slotState

-- Espacio elegido (el expandido): el que eligió el jugador, la última empresa jugada o la primera ocupada.
local function selectedSlot(): string
	local slots = App.profile and App.profile.slots or {}
	local sel = App.ui.menuSel
	local n = sel and tonumber(sel)
	if n and n >= 1 and n <= Catalog.RULES.slots and n == math.floor(n) then
		return tostring(n)
	end
	local active = App.profile and App.profile.active
	if active and slots[active] then
		return active
	end
	return firstSlot() or "1"
end
Screen.selectedSlot = selectedSlot

function Screen.select(key: string)
	if key == selectedSlot() and App.ui.menuSel == key then
		return
	end
	if rename.slot and rename.slot ~= key then
		rename.slot = nil
	end
	App.ui.menuSel = key
	App.forceRender()
end

-- Acción principal del espacio elegido (Enter en el teclado): solo continuar una empresa existente; crear y
-- desbloquear se hacen con el botón (no se abre una compra con una tecla).
function Screen.enterKey()
	local key = selectedSlot()
	if slotState(key) == "company" then
		Screen.play(key)
	end
end

-- Medidas ------------------------------------------------------------------------------------------------
local function heights(): (number, number)
	local ts = Ui.textScale or 1
	local compact = 20 + math.max(40, math.ceil(30 * ts))
	local expanded = math.ceil(100 + 44 * ts)
	return compact, expanded
end
Screen.heights = heights

-- Texto de una línea que se corta con «…» si no entra (nombres largos).
local function line(text: string, size: number, opts: { [string]: any }?): TextLabel
	local o: { [string]: any } = opts or {}
	local px = math.ceil(size * (Ui.textScale or 1) * 1.4)
	return Ui.new("TextLabel", {
		Name = o.name or "Texto",
		Text = text,
		TextSize = size,
		Weight = o.weight or W.med,
		TextColor3 = o.color or T.tx,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, px),
	})
end

-- Ícono de espacio (crear, candado, aviso) del mismo tamaño que el logo.
local function slotIcon(kind: string, size: number): Frame
	if kind == "empty" then
		local box = Ui.new("Frame", { Name = "Mas", Size = UDim2.fromOffset(size, size), BackgroundTransparency = 1, Corner = 10, Stroke = { Ui.hex("#55607A"), 1.5, 0.15 } })
		local ic = Ui.icon("plus", math.floor(size * 0.45), Ui.hex("#C3CAD8"))
		ic.AnchorPoint = Vector2.new(0.5, 0.5)
		ic.Position = UDim2.fromScale(0.5, 0.5)
		ic.Parent = box
		return box
	elseif kind == "locked" then
		return Ui.ico("lock", T.ye, T.ye, size, { alpha = 0.1, radius = 10, iconSize = math.floor(size * 0.42) })
	end
	return Ui.ico("warn", T.re2, T.re, size, { alpha = 0.12, radius = 10, iconSize = math.floor(size * 0.42) })
end

local function divider(): Frame
	return Ui.new("Frame", { Name = "Divisor", Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = STYLE.divider, BackgroundTransparency = 0.2 })
end

local function stat(label: string, value: string, opts: { [string]: any }?): Frame
	local o: { [string]: any } = opts or {}
	return Ui.col({
		line(label, Ui.S.xs, { color = T.mut2 }),
		line(value, 14, { weight = o.weight or W.bold, color = o.color or T.tx, name = o.name }),
	}, 2, { Size = UDim2.new(0.5, -6, 0, 0) })
end

-- Contenido de las tarjetas --------------------------------------------------------------------------------
local function companyName(key: string, s: any): Instance
	if rename.slot ~= key then
		return line(s.name, 17, { weight = W.bold, name = "NombreEmpresa" })
	end
	local save
	local box = Ui.input(rename.draft, "Nuevo nombre", function(text: string, enter: boolean?)
		rename.draft = text
		if enter and save then
			save:SetAttribute("_enter", true)
		end
	end, { onChange = function(text: string)
		rename.draft = text
	end, name = "NombreRanura", flex = true, height = 32 })
	save = Ui.button("Guardar", "p", function()
		local r = App.request("renameCompany", { slot = key, name = rename.draft }, { button = save })
		if r.ok then
			rename.slot = nil
		else
			rename.err = r.msg or ""
		end
		App.forceRender()
	end, { small = true, height = 32, name = "GuardarNombre" })
	return Ui.row({ box, save, Ui.button("", "q", Screen.cancelRename, { small = true, height = 32, icon = "x", name = "CancelarNombre" }) }, 6)
end

-- Tarjeta expandida (la elegida).
local function expandedContent(key: string, state: string, s: any?): { Instance? }
	if state == "company" and s then
		local sub = rename.slot == key and rename.err ~= "" and line(rename.err, Ui.S.xs, { color = T.re2 }) or line("Año " .. tostring(s.year or "—"), Ui.S.sm, { color = T.mut, name = "Anio" })
		local last = s.lastModel
		return {
			Ui.row({ Ui.logo(s, 48), Ui.grow(Ui.col({ companyName(key, s), sub }, 3)) }, 14),
			divider(),
			Ui.row({
				stat("Dinero", Util.money(s.money), { name = "Dinero" }),
				stat("Último vehículo", last or "Sin vehículos creados", { name = "UltimoVehiculo", weight = last and W.bold or W.med, color = last and T.tx or T.mut2 }),
			}, 12, { v = "T" }),
		}
	end
	local title, sub, body, subColor
	if state == "empty" then
		title, sub, subColor = "Crear empresa", "Espacio " .. key .. " · disponible", T.gr
		body = "Todas las empresas empiezan igual: un garaje, " .. Util.money(Catalog.START.money) .. " y una idea, el 1 de enero de 1970."
	elseif state == "locked" then
		local product = Catalog.PRODUCTS["slot" .. key]
		local ready = product ~= nil and product.id ~= 0
		title, sub, subColor = "Espacio " .. key, "Espacio adicional · bloqueado", T.ye
		body = ready and "Desbloqueo permanente con Robux, independiente del otro espacio. Roblox muestra el precio antes de confirmar." or "Desbloqueo con Robux: la compra todavía no está configurada en este juego."
	else
		title, sub, subColor = "Espacio " .. key, "Datos dañados", T.re2
		body = "Se conserva tal como estaba guardado y no se puede abrir (" .. tostring(s and s.reason or "sin detalle") .. "). Para liberar el espacio, eliminalo."
	end
	return {
		Ui.row({ slotIcon(state, 48), Ui.grow(Ui.col({ line(title, 17, { weight = W.bold, name = "Titulo" }), line(sub, Ui.S.sm, { color = subColor }) }, 3)) }, 14),
		divider(),
		Ui.text(body, { size = Ui.S.xs, color = T.mut, lineHeight = 1.25, name = "Detalle" }),
	}
end

-- Tarjeta compacta: logo, nombre y año (o crear / bloqueado). Un clic la elige.
local function compactContent(key: string, state: string, s: any?): Instance
	local title, sub, icon, subColor
	if state == "company" and s then
		title, sub, icon = s.name, "Año " .. tostring(s.year or "—"), Ui.logo(s, 40)
	elseif state == "empty" then
		title, sub, icon, subColor = "Crear empresa", "Espacio " .. key .. " · disponible", slotIcon("empty", 40), T.gr
	elseif state == "locked" then
		title, sub, icon = "Espacio " .. key, "Espacio adicional · bloqueado", slotIcon("locked", 40)
	else
		title, sub, icon, subColor = "Espacio " .. key, "Datos dañados", slotIcon("damaged", 40), T.re2
	end
	return Ui.row({
		icon,
		Ui.grow(Ui.col({ line(title, Ui.S.base, { weight = W.bold }), line(sub, Ui.S.xs, { color = subColor or T.mut }) }, 2)),
		Ui.icon("right", 14, T.mut2),
	}, 12, { Size = UDim2.fromScale(1, 1), AutomaticSize = Enum.AutomaticSize.None })
end

-- Altura de cada tarjeta en el dibujo anterior: al redibujar, cada una parte de donde estaba y se anima
-- hasta su tamaño nuevo (así un cambio rápido de selección nunca salta ni acumula animaciones).
local lastHeights: { [string]: number } = {}
local running: { any } = {}
Screen._running = running

local function stopTweens()
	for _, tw in running do
		tw:Cancel()
	end
	table.clear(running)
end

local function slotCard(key: string, selected: boolean): Frame
	local state = slotState(key)
	local s = App.profile and App.profile.slots[key]
	local compactH, expandedH = heights()
	local target = selected and expandedH or compactH
	local accent = (state == "company" and s and s.color) and Color3.fromHex(s.color) or nil
	local stroke, strokeAlpha, thick
	if selected then
		stroke = accent or (state == "locked" and T.ye) or (state == "damaged" and T.re) or Ui.hex("#8C96AA")
		strokeAlpha, thick = accent and 0 or 0.35, accent and 1.5 or 1
	else
		stroke, strokeAlpha, thick = STYLE.line, STYLE.lineAlpha, 1
	end
	local holder = Ui.new("Frame", { Name = "Espacio_" .. key, Size = UDim2.new(1, 0, 0, target), BackgroundTransparency = 1 })
	holder:SetAttribute("estado", state)
	holder:SetAttribute("elegido", selected)
	-- Sombra suave (un marco oscuro corrido hacia abajo, con borde difuso).
	Ui.new("Frame", {
		Name = "Sombra",
		Size = UDim2.new(1, 4, 1, 4),
		Position = UDim2.fromOffset(-2, 2),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = selected and STYLE.shadowAlpha - 0.12 or STYLE.shadowAlpha,
		Corner = STYLE.radius + 2,
		Stroke = { Color3.new(0, 0, 0), 3, 0.9 },
		ZIndex = 1,
		Parent = holder,
	})
	local name = (state == "locked" and "Bloqueada_" or (selected and "Ranura_" or "Elegir_")) .. key
	local bg = selected and (accent and STYLE.base:Lerp(accent, STYLE.tint) or STYLE.base:Lerp(Color3.new(1, 1, 1), 0.03)) or STYLE.base
	local props = {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = bg,
		BackgroundTransparency = selected and STYLE.selAlpha or STYLE.baseAlpha,
		Corner = STYLE.radius,
		Stroke = { stroke, thick, strokeAlpha },
		ClipsDescendants = true,
		ZIndex = 2,
		Parent = holder,
	}
	local card
	if selected then
		props.Pad = { 14, 16 }
		props.List = { dir = "V", gap = 12 }
		card = Ui.new("Frame", props, expandedContent(key, state, s))
	else
		props.Text = ""
		props.AutoButtonColor = false
		props.Pad = { 10, 14 }
		card = Ui.new("TextButton", props, { compactContent(key, state, s) })
		local normal = props.BackgroundTransparency
		card.MouseEnter:Connect(function()
			card.BackgroundTransparency = normal - 0.1
		end)
		card.MouseLeave:Connect(function()
			card.BackgroundTransparency = normal
		end)
		card.Activated:Connect(function()
			Screen.select(key)
		end)
	end
	-- Brillo moderado de la elegida: el fondo se aclara apenas hacia la izquierda.
	if selected then
		local g = Instance.new("UIGradient")
		g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(196, 200, 210))
		g.Parent = card
	end
	-- Animación: de la altura que tenía a la nueva (0,26 s); sin animación con «Reducir movimiento».
	local from = lastHeights[key]
	lastHeights[key] = target
	if from and from ~= target and not Ui.reduceMotion then
		holder.Size = UDim2.new(1, 0, 0, from)
		local tw = TweenService:Create(holder, TweenInfo.new(STYLE.anim, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.new(1, 0, 0, target) })
		table.insert(running, tw)
		tw:Play()
	end
	return holder
end

-- Botones principales (abajo a la derecha en PC): la acción depende del espacio elegido.
local function actions(key: string, phone: boolean): (Frame, TextLabel?)
	local state = slotState(key)
	local s = App.profile and App.profile.slots[key]
	local items: { Instance? } = {}
	local note: TextLabel? = nil
	local function secondary(label: string, icon: string, fn: () -> (), opts: { [string]: any }?): TextButton
		local o: { [string]: any } = opts or {}
		return Ui.button(phone and "" or label, "q", fn, { small = true, icon = icon, name = o.name, fg = o.fg, height = 40 })
	end
	local primary
	if state == "company" and s then
		table.insert(items, secondary("Renombrar", "pen", function()
			Screen.startRename(key)
		end, { name = "Renombrar_" .. key }))
		table.insert(items, secondary("Eliminar", "trash", function()
			App.openDialog("confirm", {
				title = "¿Eliminar «" .. s.name .. "»?",
				body = "Se borra solo el <b>espacio " .. key .. "</b> (" .. Util.money(s.money) .. ", año " .. tostring(s.year or "—") .. "). Las otras empresas no se tocan. No se puede deshacer.",
				okLabel = "Eliminar definitivamente",
				danger = true,
				onOk = function()
					App.request("deleteCompany", { slot = key, confirm = s.name })
				end,
			})
		end, { name = "Eliminar_" .. key, fg = T.re2 }))
		primary = Ui.button("Continuar", "p", function()
			Screen.play(key, primary)
		end, { name = "Continuar_" .. key, height = 48, padX = 26, size = 15, icon = "play", kbd = (not phone) and "Enter" or nil })
	elseif state == "empty" then
		primary = Ui.button("Crear empresa", "p", function()
			Screen.newCompany(key)
		end, { name = "Crear_" .. key, height = 48, padX = 26, size = 15, icon = "plus" })
	elseif state == "locked" then
		-- Ranuras 3 y 4: Developer Product propio cada una; con id 0 (sin configurar) el botón queda deshabilitado.
		local product = Catalog.PRODUCTS["slot" .. key]
		local ready = product ~= nil and product.id ~= 0
		primary = Ui.button("Desbloquear", "p", function()
			App.request("buyProduct", { product = "slot" .. key })
		end, { name = "Comprar_" .. key, height = 48, padX = 26, size = 15, icon = "lock", disabled = not ready, why = (not ready) and "Compra no configurada todavía" or nil })
		if not ready then
			note = Ui.inline("Compra no configurada todavía", { size = Ui.S.xs, color = T.mut2, name = "NotaCompra" })
		end
	else
		primary = Ui.button("Liberar espacio", "d", function()
			App.openDialog("deleteCompany", { slot = key, expected = "BORRAR", name = "el espacio dañado", damaged = true })
		end, { name = "Eliminar_" .. key, height = 48, padX = 22, size = 15, icon = "trash" })
	end
	table.insert(items, primary)
	local bar = Ui.row(items, 8, { Name = "Acciones", h = "R", Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.XY })
	return bar, note
end

function Screen.build(parent: Instance)
	local phone = App.isPhone()
	local vw, vh = App.vw, App.vh
	local sel = selectedSlot()
	local slots = App.profile and App.profile.slots or {}
	local selected = slots[sel]
	stopTweens()

	-- Fondo: showroom 3D. Solo se le dice qué auto y qué color mostrar; la transición del auto es suya.
	-- Prioridad del auto: el exhibido por el jugador, si no el más reciente, si no el provisional.
	local valid = selected and not selected.damaged
	Showroom.show(valid and selected.showcase or nil, valid and selected.color or nil, sel)

	-- Columna de tarjetas: ≈ 27 % del ancho en PC (entre 300 y 520 px), a la izquierda del auto.
	local margin = 40
	local colW = phone and (vw - 28) or math.floor(math.clamp(vw * 0.27, 300, 520))
	local bottomBar = phone and 84 or 92
	local wrap = Ui.new("ScrollingFrame", {
		Name = "MenuWrap",
		Size = phone and UDim2.new(1, 0, 1, -bottomBar) or UDim2.new(0, colW + margin * 2, 1, -bottomBar),
		BackgroundTransparency = 1,
		ScrollBarThickness = phone and 4 or 0, -- en PC la barra quedaría en medio de la escena
		ZIndex = 2,
		Parent = parent,
	})
	App.keepScroll(wrap, "menu")
	-- Velo lateral suave para que la columna se lea sobre la escena sin tapar el auto.
	local veil = Ui.new("Frame", { Name = "Velo", Size = UDim2.new(0, phone and vw or (colW + margin + 220), 1, 0), BackgroundColor3 = Ui.hex("#05070C"), BackgroundTransparency = 0, ZIndex = 1, Parent = parent })
	local vg = Instance.new("UIGradient")
	vg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, phone and 0.25 or 0.35), NumberSequenceKeypoint.new(0.6, 0.6), NumberSequenceKeypoint.new(1, 1) })
	vg.Parent = veil

	local brand = Ui.row({
		Ui.new("Frame", { Name = "LogoJuego", Size = UDim2.fromOffset(38, 38), BackgroundColor3 = T.p1, BackgroundTransparency = 0, Corner = 9, Stroke = T.vi }, {
			(function()
				local ic = Ui.icon("car", 20, T.tx)
				ic.AnchorPoint = Vector2.new(0.5, 0.5)
				ic.Position = UDim2.fromScale(0.5, 0.5)
				return ic
			end)(),
		}),
		Ui.col({
			Ui.inline("C A R   E M P I R E", { size = 14, weight = W.bold }),
			Ui.inline("T  Y  C  O  O  N", { size = 10, weight = W.bold, color = T.vi2 }),
		}, 0, { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.XY }),
	}, 10)

	local items: { Instance? } = {
		brand,
		Ui.new("Frame", { Name = "Aire", Size = UDim2.new(1, 0, 0, 6), BackgroundTransparency = 1 }),
		Ui.col({
			Ui.text("Tus empresas", { size = 18, weight = W.bold, name = "Titular" }),
			Ui.text("Elegí una empresa o un espacio libre.", { size = Ui.S.xs, color = T.mut }),
		}, 2),
	}
	if App.payload and App.payload.saveMode == "memory" then
		table.insert(items, Ui.note("y", "Studio sin acceso a la API de DataStore: las empresas se guardan solo mientras dure esta prueba."))
	end
	for i = 1, Catalog.RULES.slots do
		local key = tostring(i)
		table.insert(items, slotCard(key, key == sel))
	end
	local left = Ui.col(items, 10, { Name = "Empresas" })
	local utilities = Ui.row({
		Ui.button(phone and "" or "Configuración", "default", function()
			App.openDialog("settings", { wide = true })
		end, { small = true, icon = "gear", name = "Configuracion" }),
		Ui.button("Novedades", "q", function()
			App.openDialog("news", {})
		end, { small = true, name = "Novedades" }),
		(function()
			local demo
			demo = Ui.button("Demostraciones", "q", function()
				App.dropdown(demo, { { "tutorial", "Demo: garaje" }, { "avanzada", "Demo: fábrica avanzada" }, { "imperio", "Demo: después de 2030" } }, nil, function(kind: any)
					App.request("playDemo", { kind = kind })
					App.ui.enteringGame = true
				end)
			end, { small = true, icon = "down", iconAfter = true, name = "Demostraciones" })
			return demo
		end)(),
	}, 6, { Name = "Utilidades", Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.XY })

	local bar, note = actions(sel, phone)
	if phone then
		Ui.new("UIPadding", { PaddingTop = UDim.new(0, 18), PaddingBottom = UDim.new(0, 18), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), Parent = wrap })
		Ui.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 14), Parent = wrap })
		left.Size = UDim2.new(1, 0, 0, 0)
		left.Parent = wrap
		utilities.Parent = wrap
		-- Barra inferior fija con la acción principal.
		local dock = Ui.new("Frame", { Name = "Acciones_Base", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, bottomBar), BackgroundColor3 = STYLE.base, BackgroundTransparency = 0.12, ZIndex = 3, Pad = { 0, 14 }, List = { dir = "H", gap = 8, v = "C", h = "R" }, Parent = parent })
		if note then
			note.Parent = dock
		end
		bar.Parent = dock
	else
		left.Position = UDim2.fromOffset(margin, 32)
		left.Size = UDim2.fromOffset(colW, 0)
		left.Parent = wrap
		Ui.new("Frame", { Name = "Margen", Size = UDim2.fromOffset(1, 24), Position = UDim2.fromOffset(0, vh - bottomBar), BackgroundTransparency = 1, Parent = wrap })
		utilities.AnchorPoint = Vector2.new(0, 1)
		utilities.Position = UDim2.new(0, margin, 1, -28)
		utilities.ZIndex = 3
		utilities.Parent = parent
		local dock = Ui.col({
			note,
			bar,
			Ui.inline("Tus empresas se guardan en tu cuenta de Roblox", { size = Ui.S.xs, color = T.mut2, name = "Pie" }),
		}, 8, { Name = "Acciones_Base", h = "R", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -margin, 1, -24), Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.XY, ZIndex = 3 })
		dock.Parent = parent
	end
end

return Screen
