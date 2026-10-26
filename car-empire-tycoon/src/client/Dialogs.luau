--!strict
--[[
	Diálogos de la V3 (.dlg): encabezado (.dlg-h), cuerpo desplazable (.dlg-b) y pie (.dlg-f) con botones
	de igual ancho. Cada constructor recibe (caja, parámetros, registro del diálogo); si define d.sig(g),
	el diálogo se reconstruye cuando cambia (por ejemplo, si el cliente se va o el auto se vende).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local DesignCalc = require(Shared.DesignCalc)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W
local hex = Ui.hex

local Dialogs = {}

-- Estructura ----------------------------------------------------------------------------------------
local function header(box: Frame, title: string, closable: boolean?, extra: { Instance? }?)
	local items: { Instance? } = { Ui.grow(Ui.text(title, { size = 19, weight = W.bold, name = "Titulo" })) }
	for _, e in extra or {} do
		table.insert(items, e)
	end
	if closable ~= false then
		table.insert(items, Ui.button("", "default", function()
			App.closeDialog()
		end, { small = true, icon = "x", iconSize = 16, name = "CerrarDialogo" }))
	end
	Ui.row(items, 12, { Name = "Encabezado", Pad = { 18, 20, 6, 20 }, Parent = box })
end

local function body(box: Frame, gap: number?): ScrollingFrame
	local s = Ui.scroll({}, { name = "CuerpoDialogo", gap = gap or 12, pad = { 12, 20, 18, 20 } })
	s.Size = UDim2.new(1, 0, 0, 0)
	s.AutomaticSize = Enum.AutomaticSize.Y
	s.Parent = box
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(math.huge, App.dialogMaxBody or 500)
	limit.Parent = s
	return s
end

-- Pie: botones con flex 1 (todos del mismo ancho), sobre fondo #0D0F14 con borde superior.
local function footer(box: Frame, buttons: { Instance? })
	local list: { Instance? } = {}
	for _, b in buttons do
		if b then
			local f = b:FindFirstChildOfClass("UIFlexItem")
			if not f then
				local flex = Instance.new("UIFlexItem")
				flex.FlexMode = Enum.UIFlexMode.Fill
				flex.Parent = b
			end
			table.insert(list, b)
		end
	end
	Ui.new("Frame", { Name = "BordePie", Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = T.line3, BackgroundTransparency = 0, Parent = box })
	Ui.row(list, 10, { Name = "Pie", BackgroundColor3 = hex("#0D0F14"), BackgroundTransparency = 0, Pad = { 14, 20, 18, 20 }, wrap = App.isPhone(), Parent = box })
end

local function closeBtn(label: string?): TextButton
	return Ui.button(label or "Cerrar", "default", App.closeDialog, { name = "Cerrar" })
end

local function findUnit(g: any, id: any): any
	for _, u in g.units do
		if u.id == id then
			return u
		end
	end
	return nil
end

-- Tarjeta con líneas «etiqueta | valor» y total (precios, impuestos).
local function priceCard(lines: { string }, total: string?): Frame
	local items: { Instance? } = {}
	for i, l in lines do
		local a, b = string.match(l, "^(.-)|(.*)$")
		table.insert(items, Ui.line(a or l, b or "", { size = 14, border = i < #lines or total ~= nil }))
	end
	if total then
		table.insert(items, Ui.line("<b>Total</b>", total, { size = 14, border = false }))
	end
	return Ui.card(items, { gap = 0, pad = { 4, 12 }, name = "Precios" })
end

-- Confirmación genérica (confirmDlg de la V3): título, cuerpo y «Cancelar / Aceptar».
-- params: { title, body, lines, total, note = { tipo, texto }, after, okLabel, cancel, danger, extra, onOk }
Dialogs.confirm = function(box: Frame, params: any)
	header(box, params.title or "¿Confirmar?", false)
	local b = body(box)
	if params.body then
		Ui.text(params.body, { size = 15, color = T.tx, lineHeight = 1.45 }).Parent = b
	end
	if params.lines then
		priceCard(params.lines, params.total).Parent = b
	end
	if params.note then
		Ui.note(params.note[1], params.note[2]).Parent = b
	end
	if params.after then
		Ui.text(params.after, { size = Ui.S.xs, color = T.mut }).Parent = b
	end
	local ok = Ui.button(params.okLabel or "Confirmar", params.danger and "d" or "p", function()
		App.closeDialog()
		if params.onOk then
			params.onOk()
		end
	end, { name = "Confirmar" })
	footer(box, { params.extra, Ui.button(params.cancel or "Cancelar", "default", App.closeDialog, { name = "Cancelar" }), ok })
end

-- Diálogo informativo (infoDlg): «Cerrar» y «Entendido».
local function info(box: Frame, title: string, nodes: { Instance? })
	header(box, title, false)
	local b = body(box)
	for _, n in nodes do
		if n then
			n.Parent = b
		end
	end
	footer(box, { closeBtn(), Ui.button("Entendido", "p", App.closeDialog, { name = "Entendido" }) })
end

-- Novedades (newsDlg)
Dialogs.news = function(box: Frame)
	local N = App.screens.menu.NEWS
	info(box, N.version, {
		Ui.text("<b>" .. N.title .. "</b>", { size = 15 }),
		Ui.text(N.body, { size = 15, lineHeight = 1.5 }),
		Ui.text("•  Un solo estado compartido por todas las pantallas, con guardado por ranura.\n•  Editor con modelos 3D, 11 categorías de piezas y costos separados.\n•  Fábrica con cola, materiales, averías y tiempo de juego.\n•  Concesionario con negociación por probabilidad visible.\n•  Mercado simulado con subastas y vendedores ficticios.", { size = 15, lineHeight = 1.55 }),
		Ui.text("Próximo evento: " .. N.event .. " (demostración).", { size = Ui.S.xs, color = T.mut }),
	})
end

-- Amigos, evento y tienda (funciones futuras de la V3)
Dialogs.future = function(box: Frame, params: any)
	local g = App.g
	local N = App.screens.menu.NEWS
	if params.what == "amigos" then
		info(box, "Amigos", { Ui.text("Función futura. En Roblox, esta sección mostraría a tus amigos conectados y te dejaría visitar sus sedes. Todavía no está implementada.", { size = 15, lineHeight = 1.5 }) })
	elseif params.what == "eventos" then
		info(box, "Evento · " .. N.event, {
			Ui.row({ Ui.chip("Demostración", "cy"), Ui.grow(Ui.text("Así se presentaría un evento de temporada. Todavía no modifica la simulación ni entrega premios.", { size = 15, lineHeight = 1.5 })) }, 8),
		})
	else
		info(box, "Tienda", { Ui.text("No hay compras con dinero real. Las gemas se ganan subiendo de nivel, con misiones y con la recompensa diaria. Tenés <b>" .. (g and g.gems or 0) .. " gemas</b>. Usarlas (por ejemplo, para terminar una investigación al instante) es una función futura.", { size = 15, lineHeight = 1.5 }) })
	end
end

-- Ayuda por sección (helpDialog)
local HELP = {
	juego = "La sede es tu espacio 3D. Caminá con WASD o flechas (en celular, con la palanca táctil), acercate a un objeto y presioná E (o tocá la indicación). Las tarjetas laterales muestran objetivo, resultados de 7 días, alertas y sede. La simulación avanza con el reloj: 1 segundo real equivale a 10 minutos de juego a velocidad 1×.",
	fabrica = "Cada orden fabrica unidades de un diseño guardado. Al empezar cada unidad se descuentan sus materiales y su costo de fabricación. Si faltan materiales, dinero o lugar en el almacén, o una estación se avería, la orden se detiene y te dice por qué. Las órdenes de una línea se procesan por prioridad y, dentro de la misma prioridad, en el orden que elijas.",
	autos = "Acá están todas tus unidades, piezas sueltas, materiales y diseños. Cada tipo de objeto muestra solo sus acciones válidas. Capacidad del almacén: cuentan las unidades terminadas en el almacén, reservadas o publicadas en el mercado. Las del salón usan la capacidad del salón.",
	ventas = "Los clientes llegan cuando hay autos en el salón. Cada uno tiene presupuesto, preferencia y paciencia. Podés aceptar, rechazar o contraofertar: la probabilidad mostrada es la que usa la simulación para decidir. Una contraoferta mayor que el presupuesto nunca se acepta.",
	mercado = "Mercado simulado dentro de tu partida, con vendedores ficticios: no hay intercambio con otros jugadores. Comprar suma impuesto (5%) y comisión (2%). Al vender tus unidades en el mercado se cobra la comisión del 2%.",
	investigacion = "Cada investigación cuesta dinero y puntos de investigación (PI) y tarda un tiempo de juego. Los PI se generan cada día (más con ingenieros en el laboratorio). Los requisitos se calculan con tu empresa actual.",
	personal = "Contratar tiene un costo único y un salario diario. Cada persona puede tener un solo puesto. La energía baja mientras trabaja; con menos de 20% rinde la mitad. Dar descanso la saca del puesto hasta recuperarse.",
	compania = "Datos de marca, sede, capacidades y finanzas acumuladas. Ampliar la sede aumenta líneas, almacén, salón y personal, y cambia la escena 3D.",
	misiones = "Las misiones avanzan con acciones reales. Las diarias se reinician cada día de juego. Una recompensa reclamada queda registrada en la partida.",
	estadisticas = "Todo se calcula con el historial de la partida. «Margen» = ingresos por venta − costo de fabricación de lo vendido. «Resultado neto» = todo el dinero que entró menos todo el que salió en el período (incluye compras y desarrollo).",
	editor = "El proyecto se guarda en la partida mientras editás. Costos: la licencia del modelo y el desarrollo de piezas se pagan una sola vez al guardar el diseño; el costo de fabricación se paga por cada unidad fabricada.",
}
Dialogs.HELP = HELP
Dialogs.help = function(box: Frame, params: any)
	local k = params.screen or App.ui.route
	local sc = App.screens[k]
	local title = "Ayuda" .. ((sc and sc.title) and (" · " .. sc.title) or (k == "editor" and " · Editor" or ""))
	info(box, title, { Ui.text(HELP[k] or HELP.juego, { size = 15, lineHeight = 1.55 }) })
end

-- Configuración (settingsDialog)
Dialogs.settings = function(box: Frame)
	local s = App.settings
	header(box, "Configuración")
	local b = body(box, 0)
	local function setting(key: string, value: any)
		App.request("setSetting", { key = key, value = value })
	end
	local function row(label: string, desc: string, ctrl: Instance?)
		local r = Ui.row({
			Ui.grow(Ui.col({ Ui.text(label, { size = Ui.S.sm, weight = W.bold }), Ui.text(desc, { size = Ui.S.xs, color = T.mut }) }, 2)),
			ctrl,
		}, 10, { Pad = { 10, 0 }, Name = "Fila" })
		Ui.underline(r).Parent = b
	end
	local function section(text: string, top: boolean?)
		local l = Ui.lbl(text)
		if top then
			local pad = Instance.new("UIPadding")
			pad.PaddingTop = UDim.new(0, 8)
			pad.Parent = l
		end
		l.Parent = b
	end
	section("Accesibilidad")
	local sizes = {}
	for _, v in { { 1, "Normal" }, { 1.12, "Grande" }, { 1.25, "Muy grande" } } do
		table.insert(sizes, Ui.opt(v[2], s.textScale == v[1], function()
			setting("textScale", v[1])
		end))
	end
	row("Tamaño del texto", "Aumenta todos los textos de la interfaz.", Ui.row(sizes, 10, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY }))
	row("Reducir movimiento", "Quita animaciones y transiciones de cámara.", Ui.toggle(s.reduceMotion == true, function()
		setting("reduceMotion", not s.reduceMotion)
	end))
	row("Mostrar atajos de teclado", "Indicadores como «1», «E» o «Esc» junto a los botones.", Ui.toggle(s.keyHints ~= false, function()
		setting("keyHints", s.keyHints == false)
	end))
	section("Juego", true)
	row("Efectos de sonido", "Sonidos cortos al confirmar acciones.", Ui.toggle(s.sound ~= false, function()
		setting("sound", s.sound == false)
	end))
	row("Sombras 3D", "Desactivalas si el equipo funciona lento.", Ui.toggle(s.shadows ~= false, function()
		setting("shadows", s.shadows == false)
	end))
	row("Sensibilidad de la cámara", "Velocidad de rotación al arrastrar en el editor.", Ui.slider(s.camSpeed or 1, 0.4, 2, 0.1, function(v: number, final: boolean)
		if final then
			setting("camSpeed", math.floor(v * 10 + 0.5) / 10)
		end
	end, { width = 180, name = "SensibilidadCamara" }))
	row("Idioma", "Por ahora el juego está solo en español.", Ui.chip("Español", "cn"))
	row("Atajos", "0 Sede · 1–8 secciones · WASD o flechas para caminar · E interactuar · Tab ocultar paneles · Esc cerrar. En el editor: [ y ] pasos, Ctrl+Z/Ctrl+Y.", nil)
	section("Datos", true)
	local mode = App.payload and App.payload.saveMode
	row("Guardado en Roblox", mode == "memory" and "Studio sin acceso a la API: se guarda solo durante esta prueba." or "Tus empresas se guardan automáticamente en tu cuenta.", mode == "memory" and Ui.chip("Temporal", "cy") or Ui.chip("Activo", "cg"))
	row("Borrar todos los datos", "Elimina las tres ranuras de tu cuenta. No se puede deshacer.", Ui.button("Borrar todo", "d", function()
		App.openDialog("confirm", {
			title = "¿Borrar todos los datos?",
			body = "Se eliminan las tres ranuras de tu cuenta. No se puede deshacer.",
			okLabel = "Borrar todo",
			danger = true,
			onOk = function()
				App.request("wipeAll", { confirm = "BORRAR" })
			end,
		})
	end, { small = true, name = "BorrarTodo" }))
end

-- Notificaciones (notifsDialog)
local NOTIF = { ok = { "cg", "✓" }, aviso = { "cy", "⚠" }, error = { "cr", "✕" }, info = { "cb", "i" }, nivel = { "cv", "★" } }
Dialogs.notifications = function(box: Frame)
	local g = App.g
	header(box, "Notificaciones", true, {
		Ui.button("Marcar todo como leído", "q", function()
			App.request("markRead", {})
		end, { small = true, name = "MarcarLeidas" }),
	})
	local b = body(box, 12)
	if #g.notifications == 0 then
		Ui.empty("bell", "No hay notificaciones todavía.").Parent = b
	end
	for i, n in g.notifications do
		if i > 40 then
			break
		end
		local k = NOTIF[n.kind] or { "cn", "•" }
		local item = Ui.new("TextButton", {
			Name = "Notif_" .. n.id,
			Text = "",
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = T.p2,
			BackgroundTransparency = 0,
			Corner = 10,
			Stroke = n.read and T.line2 or { T.vi, 1, 0.55 },
			Pad = { 10, 12 },
			List = { dir = "H", gap = 10, v = "C" },
		}, {
			Ui.chip(k[2], k[1]),
			Ui.grow(Ui.text(n.text, { size = Ui.S.sm, transparency = n.read and 0.3 or 0 })),
			Ui.inline("Día " .. (n.day + 1) .. " " .. tostring(n.at), { size = Ui.S.xs, color = T.mut }),
		})
		item.Activated:Connect(function()
			App.request("markRead", { id = n.id })
			App.closeDialog()
			if n.go and (App.screens[n.go] or n.go == "juego") then
				App.go(n.go)
			end
		end)
		item.Parent = b
	end
end

-- Recompensa diaria (dailyDialog)
Dialogs.daily = function(box: Frame)
	local g = App.g
	header(box, "Recompensa diaria")
	local b = body(box)
	local today = App.payload.today or ""
	local can = g.daily.last ~= today
	local yesterday = App.payload.yesterday
	local nextStreak = (yesterday and g.daily.last == yesterday) and (g.daily.streak + 1) or 1
	local idx = math.min(nextStreak, 7)
	Ui.text("Se usa la fecha real del servidor (" .. string.gsub(today, "(%d+)%-(%d+)%-(%d+)", "%3/%2/%1") .. ", UTC). Entrar días seguidos mejora el premio; si salteás un día, la racha vuelve al día 1.", { size = Ui.S.sm, color = T.mut }).Parent = b
	local cards = {}
	for i, r in Catalog.DAILY_REWARDS do
		local current = can and i == idx
		local past = (i < idx and can) or (not can and i <= math.min(g.daily.streak, 7))
		table.insert(cards, Ui.card({
			Ui.text("Día " .. i, { size = Ui.S.xs, color = T.mut, align = "C" }),
			Ui.text((string.gsub(Rules.rewardText(r), " · ", "\n")), { size = Ui.S.xs, weight = W.bold, align = "C" }),
		}, { gap = 4, pad = { 8, 4 }, bg = current and T.vi or T.p2, transparency = current and 0.85 or (past and 0.45 or 0), stroke = current and T.vi or T.line2 }))
	end
	Ui.grid(cards, 7, nil, 10).Parent = b
	if can then
		local claim
		claim = Ui.button("Reclamar " .. Rules.rewardText(Catalog.DAILY_REWARDS[idx]), "g", function()
			local r = App.request("claimDaily", nil, { button = claim })
			if r.ok then
				App.closeDialog()
			end
		end, { fill = true, name = "ReclamarDiaria" })
		claim.Parent = b
	else
		Ui.note("g", "Ya reclamaste la recompensa de hoy. Volvé mañana (fecha real).").Parent = b
	end
end

-- Nueva orden de producción (orderDlg) ---------------------------------------------------------------------
Dialogs.order = function(box: Frame, params: any)
	local g = App.g
	local list = {}
	for _, d in g.designs do
		if not d.template then
			table.insert(list, d)
		end
	end
	header(box, "Nueva orden de producción")
	local b = body(box)
	if #list == 0 then
		Ui.note("b", "Primero guardá un diseño en el editor.").Parent = b
		footer(box, { closeBtn() })
		return
	end
	local st = App.ui.orderDraft
	if not st or (params.designId and st.designId ~= params.designId and not st.touched) then
		local def = list[#list].id
		for _, d in list do
			if d.id == params.designId or (not params.designId and d.id == g.production.lastDesign) then
				def = d.id
			end
		end
		-- Línea con menos órdenes (como la V3).
		local best, bn = 1, math.huge
		for l = 1, g.derived.caps.lines do
			local n = 0
			for _, o in g.production.orders do
				if o.line == l then
					n += 1
				end
			end
			if n < bn then
				best, bn = l, n
			end
		end
		st = { designId = def, qty = 1, line = best, priority = "media" }
		App.ui.orderDraft = st
	end
	local d = list[#list]
	for _, x in list do
		if x.id == st.designId then
			d = x
		end
	end
	st.designId = d.id
	local c = DesignCalc.computeDesign(g, d)
	local qty = math.clamp(math.floor(st.qty or 1), 1, Catalog.RULES.maxQty)
	local factor = Rules.unitCostFactor(g)
	local cost = Util.round(c.unitCost * factor)
	local free = g.derived.caps.warehouse - g.derived.warehouseUsed
	local t = c.build / math.max(0.01, g.derived.lineSpeed)

	local designOpts = {}
	for _, x in list do
		table.insert(designOpts, { x.id, x.name .. " · v" .. x.version })
	end
	Ui.col({ Ui.fl("Modelo (diseño guardado)"), Ui.select(d.id, designOpts, function(v: any)
		st.designId = v
		st.touched = true
		App.renderDialog()
	end, { fill = true, name = "ModeloOrden" }) }, 6).Parent = b
	local lineOpts = {}
	for l = 1, g.derived.caps.lines do
		local n = 0
		for _, o in g.production.orders do
			if o.line == l then
				n += 1
			end
		end
		table.insert(lineOpts, { l, "Línea " .. l .. " · " .. n .. " órdenes" })
	end
	Ui.grid({
		Ui.col({ Ui.fl("Cantidad (1–" .. Catalog.RULES.maxQty .. ")"), Ui.input(tostring(qty), "1", function(text: string)
			local n = tonumber(text)
			st.qty = n and math.clamp(math.floor(n), 1, Catalog.RULES.maxQty) or 1
			st.touched = true
			App.renderDialog()
		end, { name = "Cantidad", numeric = true }) }, 6),
		Ui.col({ Ui.fl("Línea"), Ui.select(st.line, lineOpts, function(v: any)
			st.line = v
			App.renderDialog()
		end, { fill = true, name = "LineaOrden" }) }, 6),
		Ui.col({ Ui.fl("Prioridad"), Ui.select(st.priority, { { "alta", "Alta" }, { "media", "Media" }, { "baja", "Baja" } }, function(v: any)
			st.priority = v
			App.renderDialog()
		end, { fill = true, name = "PrioridadOrden" }) }, 6),
	}, 3, nil, 10).Parent = b
	Ui.grid({
		(Ui.kv("Costo por unidad" .. (factor > 1 and " (acelerada)" or ""), Util.money(cost), { sub = "Se cobra al empezar cada unidad" })),
		(Ui.kv("Costo total estimado", Util.money(cost * qty), { sub = "Tenés " .. Util.money(g.money) })),
		(Ui.kv("Tiempo por unidad", Util.gameDuration(t) .. " de juego", { sub = Util.realDur(t, g.time.speed) .. " a la velocidad actual" })),
		(Ui.kv("Lugar libre en el almacén", tostring(math.max(0, free)), { color = free < qty and T.ye or nil, sub = free < qty and "La orden se detendrá al llenarse" or "Alcanza para la orden" })),
	}, 2, nil, 10).Parent = b
	local lines: { Instance? } = {}
	local short = false
	local keys = Util.keys(c.mats)
	for i, k in keys do
		local need = c.mats[k] * qty
		local have = g.materials[k] or 0
		if have < need then
			short = true
		end
		table.insert(lines, Ui.line(Catalog.matLabel(k), "necesita " .. need .. " · tenés " .. have, { size = Ui.S.sm, color = have < need and T.ye or T.gr, weight = W.med, border = i < #keys }))
	end
	Ui.card(lines, { gap = 0, pad = { 4, 12 } }).Parent = b
	Ui.note("b", "La orden guarda una copia de «" .. d.name .. "» v" .. (d.version or 1) .. ": aunque después edites o elimines el proyecto, estas unidades se fabrican con esta versión y este costo unitario.").Parent = b
	if short then
		Ui.note("y", "Los materiales no alcanzan para toda la orden. Se fabricará hasta donde alcancen y la orden se detendrá mostrando qué falta.").Parent = b
	end
	if g.money < cost then
		Ui.note("r", "No alcanza el dinero para empezar la primera unidad.").Parent = b
	end
	local create
	create = Ui.button("Crear orden", "p", function()
		local r = App.request("createOrder", { designId = d.id, qty = qty, line = st.line, priority = st.priority }, { button = create })
		if r.ok then
			App.ui.orderDraft = nil
			App.closeAllDialogs()
			if App.ui.route ~= "fabrica" and App.ui.route ~= "editor" then
				App.go("fabrica")
			end
		end
	end, { name = "CrearOrden" })
	footer(box, { Ui.button("Cancelar", "default", App.closeDialog), create })
end

-- Negociación (negRender): la probabilidad la calcula el servidor para ese monto y ese estado.
Dialogs.counter = function(box: Frame, params: any, d: any)
	local g = App.g
	local c = nil
	for _, x in g.customers do
		if x.id == params.customerId then
			c = x
		end
	end
	local u = c and findUnit(g, c.unitId) or nil
	d.sig = function(gg: any): string
		for _, x in gg.customers do
			if x.id == params.customerId then
				local uu = findUnit(gg, x.unitId)
				return x.state .. tostring(x.offer) .. tostring(x.rev) .. (uu and uu.status or "-")
			end
		end
		return "gone"
	end
	header(box, "Negociación" .. (c and (" · " .. c.name) or ""))
	local b = body(box)
	params.log = params.log or {}
	if not c or not u then
		Ui.text("El cliente o el auto ya no están disponibles.", { size = 15 }).Parent = b
		footer(box, { closeBtn() })
		return
	end
	local open = c.state == "oferta" and u.status == "salon" and not params.done
	local st = App.ui.counterDraft
	if not st or st.customerId ~= c.id then
		st = { customerId = c.id, amount = Util.round(((c.offer + Rules.finalPrice(u)) / 2) / 100) * 100, quote = nil }
		App.ui.counterDraft = st
	end
	if st.amount < (c.offer or 0) then
		st.amount = c.offer
	end
	local q = st.quote
	local valid = q and q.amount == st.amount and q.rev == c.rev
	local function requote()
		local r = App.request("quoteCounter", { customerId = c.id, amount = st.amount }, { key = c.id })
		if r.ok then
			st.quote = { amount = r.amount, chance = r.chance, rev = r.rev, offer = r.offer }
			st.amount = r.amount
			st.failed = nil
		elseif not r.pending then
			st.quote = nil
			st.failed = tostring(st.amount) .. ":" .. tostring(c.rev)
		end
		if App.topDialog() == d then
			App.renderDialog()
		end
	end
	if open and not valid and not st.quoting and st.failed ~= (tostring(st.amount) .. ":" .. tostring(c.rev)) then
		st.quoting = true
		task.spawn(function()
			requote()
			st.quoting = false
		end)
	end
	local s = u.stats
	local fp = Rules.finalPrice(u)
	local patienceBar, patienceFill = Ui.bar(100, T.ye)
	App.dialogLive(function(gg: any)
		for _, x in gg.customers do
			if x.id == c.id then
				Ui.setBar(patienceFill, math.clamp(100 - x.waited / math.max(1, x.patience) * 100, 0, 100))
			end
		end
	end)
	Ui.grid({
		Ui.card({
			Ui.lbl("Auto"),
			Ui.row({ Ui.paintChip(u.spec, 44, 28), Ui.inline(u.name, { size = 15, weight = W.bold }), Ui.inline(u.serial, { size = Ui.S.xs, color = T.mut }) }, 10),
			Ui.text(Catalog.TYPES[u.type] .. " · " .. s.hp .. " hp · 0–100 en " .. Util.num(s.accel, 1) .. " s · comodidad " .. s.comfort .. " · consumo " .. Util.num(s.consumption, 1) .. " " .. (s.consUnit or "") .. " · calidad " .. u.quality, { size = Ui.S.xs, color = T.mut }),
			Ui.between("Precio de lista", Util.money(fp)),
			Ui.between("Costo de fabricación", Util.money(u.cost)),
		}, { gap = 4 }),
		Ui.card({
			Ui.lbl("Cliente"),
			Ui.text(c.name, { size = 15, weight = W.bold }),
			Ui.text("Busca " .. string.lower(Catalog.TYPES[c.wants] or c.wants) .. " · valora " .. (Catalog.PREF_LABEL[c.pref] or c.pref) .. " · interés " .. c.interest .. "% · rondas " .. c.rounds .. "/3", { size = Ui.S.xs, color = T.mut }),
			Ui.between("Su oferta", Util.money(c.offer or 0), { color = T.gr }),
			Ui.row({ Ui.inline("Paciencia", { size = Ui.S.xs, color = T.mut, width = 70 }), Ui.grow(patienceBar) }, 10),
		}, { gap = 4 }),
	}, App.isPhone() and 1 or 2, nil, 10).Parent = b

	local chance = valid and q.chance or nil
	if open then
		local maxA = Util.round(fp * 1.15 / 100) * 100
		local function setAmount(v: number)
			st.amount = math.max(c.offer, Util.round(v / 100) * 100)
			App.renderDialog()
		end
		Ui.col({
			Ui.fl("Tu contraoferta"),
			Ui.row({
				Ui.input(tostring(st.amount), "Monto", function(text: string)
					local n = tonumber((string.gsub(text, "[^%d]", "")))
					if n then
						setAmount(n)
					end
				end, { width = 180, name = "MontoContraoferta", numeric = true }),
				Ui.slider(math.clamp(st.amount, c.offer, maxA), c.offer, math.max(c.offer + 100, maxA), 100, function(v: number, final: boolean)
					if final then
						setAmount(v)
					end
				end, { flex = true, name = "MontoDeslizador" }),
			}, 10),
			Ui.grid({
				(Ui.kv("Probabilidad de que acepte", chance and (chance .. "%") or (st.failed and "—" or "Calculando…"), { color = chance and (chance >= 60 and T.gr or (chance >= 30 and T.ye or T.re2)) or T.mut })),
				(Ui.kv("Margen si acepta", Util.money(st.amount - u.cost), { color = st.amount - u.cost >= 0 and T.gr or T.re2 })),
				(Ui.kv("Si rechaza", "Pierde paciencia; en la 3.ª ronda se va", { valueSize = 13 })),
			}, App.isPhone() and 1 or 3, nil, 10),
			Ui.text("La simulación tira un número del 0 al 99: si es menor que la probabilidad mostrada, acepta. Si tu monto supera su presupuesto (que no conocés), la probabilidad es 0%.", { size = Ui.S.xs, color = T.mut }),
		}, 8).Parent = b
	end
	if #params.log > 0 then
		local items: { Instance? } = {}
		for i, l in params.log do
			table.insert(items, Ui.line(l, "", { size = Ui.S.sm, border = i < #params.log }))
		end
		Ui.card(items, { gap = 0, pad = { 4, 12 } }).Parent = b
	end
	if params.done then
		Ui.note(params.done.ok and "g" or "y", params.done.msg).Parent = b
	end
	if not open then
		footer(box, { Ui.button("Cerrar", "p", App.closeDialog) })
		return
	end
	local accept, counter
	accept = Ui.button("Aceptar su oferta · " .. Util.money(c.offer), "g", function()
		local r = App.request("acceptOffer", { customerId = c.id }, { button = accept })
		if r.ok then
			table.insert(params.log, "Aceptaste " .. Util.money(c.offer) .. ".")
			params.done = { ok = true, msg = r.msg or "Venta realizada." }
			App.renderDialog()
		end
	end, { name = "AceptarOferta" })
	counter = Ui.button("Contraofertar · " .. Util.money(st.amount), "p", function()
		if not valid then
			App.toast("aviso", "Esperá a que se calcule la probabilidad.")
			return
		end
		local amount, pct = st.quote.amount, st.quote.chance
		local r = App.request("counterOffer", { customerId = c.id, amount = amount, rev = st.quote.rev }, { button = counter })
		st.quote = nil
		if r.ok then
			if r.sold then
				table.insert(params.log, "Contraoferta " .. Util.money(amount) .. " · probabilidad " .. tostring(pct) .. "% → <font color=\"#42E58D\"><b>aceptó</b></font>")
				params.done = { ok = true, msg = r.msg }
			elseif r.left then
				table.insert(params.log, "Contraoferta " .. Util.money(amount) .. " · probabilidad " .. tostring(pct) .. "% → <font color=\"#FF8A91\"><b>rechazó y se fue</b></font>")
				params.done = { ok = false, msg = r.msg }
			else
				table.insert(params.log, "Contraoferta " .. Util.money(amount) .. " · probabilidad " .. tostring(pct) .. "% → <font color=\"#F7C95C\"><b>rechazó</b></font>. " .. (r.msg or ""))
			end
		end
		App.renderDialog()
	end, { name = "Contraofertar", disabled = chance == nil, why = "Esperá a que se calcule la probabilidad" })
	footer(box, {
		Ui.button("Rechazar y despedir", "q", function()
			App.request("rejectCustomer", { customerId = c.id })
			params.done = { ok = false, msg = "Rechazaste la oferta. " .. c.name .. " se fue y no se vendió nada." }
			App.renderDialog()
		end),
		accept,
		counter,
	})
end

-- Detalle de una unidad (unitDialog)
Dialogs.unitDetail = function(box: Frame, params: any, d: any)
	local g = App.g
	local u = findUnit(g, params.unitId)
	d.sig = function(gg: any): string
		local x = findUnit(gg, params.unitId)
		return x and (x.status .. x.price .. x.discount) or "gone"
	end
	if not u then
		local b = body(box)
		Ui.text("La unidad ya no existe.", { size = 15 }).Parent = b
		footer(box, { closeBtn() })
		return
	end
	header(box, u.name .. " · " .. u.serial)
	local b = body(box)
	local Inventory = App.screens.autos
	local spec = u.spec
	Ui.row({
		Ui.chip(Inventory.STATUS_LABEL[u.status] or u.status, Inventory.STATUS_CHIP[u.status]),
		Ui.chip(Catalog.TYPES[u.type], "cn"),
		Ui.chip("Calidad " .. u.quality, "cv"),
		Ui.inline("Pintura " .. spec.paint.primary .. " " .. string.lower(spec.paint.finish) .. " · llantas " .. spec.wheels.size .. "″ · " .. (spec.spoiler and "con alerón" or "sin alerón"), { size = Ui.S.xs, color = T.mut }),
	}, 10, { wrap = true }).Parent = b
	local fp = Rules.finalPrice(u)
	Ui.grid({
		(Ui.kv("Costo de fabricación", Util.money(u.cost))),
		(Ui.kv("Precio de venta", Util.money(u.status == "vendido" and (u.soldPrice or fp) or fp))),
		(Ui.kv("Margen esperado", Util.money(fp - u.cost), { color = fp - u.cost >= 0 and T.gr or T.re2 })),
		(Ui.kv("Demanda", Rules.interest(g, u, nil) .. " / 100")),
	}, App.isPhone() and 2 or 4, nil, 10).Parent = b
	local stats = {}
	for i, s in Catalog.STAT_DEFS do
		if i > 8 then
			break
		end
		local k = s[1]
		local unit = k == "consumption" and (u.stats.consUnit or "") or string.gsub(s[3], "índice 0–100", "/100")
		table.insert(stats, Ui.between(s[2], Util.num(u.stats[k], (k == "accel" or k == "consumption") and 1 or 0) .. " <font color=\"#A3AAB8\" size=\"11\">" .. unit .. "</font>"))
	end
	Ui.card({ Ui.grid(stats, 2, nil, 10) }, { gap = 0 }).Parent = b
	Ui.row(Inventory.unitActions(g, u), 6, { wrap = true }).Parent = b
end

-- Detalle de una venta (al tocar una línea del historial; agrega lista, oferta, ingreso y margen)
Dialogs.saleDetail = function(box: Frame, params: any)
	local g = App.g
	local s = nil
	for _, x in g.sales do
		if x.id == params.saleId then
			s = x
		end
	end
	header(box, s and ("Venta · " .. s.name) or "Venta")
	local b = body(box)
	if not s then
		Ui.text("La venta ya no está en el historial con detalle.", { size = 15 }).Parent = b
		footer(box, { closeBtn() })
		return
	end
	Ui.card({
		Ui.line("Unidad", s.serial .. " · " .. s.name .. (s.designVersion and (" v" .. s.designVersion) or ""), { size = Ui.S.sm }),
		Ui.line("Día y hora", "Día " .. (s.day + 1) .. " " .. (s.at or ""), { size = Ui.S.sm }),
		Ui.line("Canal · comprador", s.channel .. " · " .. tostring(s.buyer), { size = Ui.S.sm }),
		Ui.line("Precio de lista", s.listPrice and Util.money(s.listPrice) or "—", { size = Ui.S.sm }),
		Ui.line("Precio final de lista", s.finalListPrice and Util.money(s.finalListPrice) or "—", { size = Ui.S.sm }),
		Ui.line("Oferta del cliente", s.offer and Util.money(s.offer) or "—", { size = Ui.S.sm }),
		Ui.line("Ingreso final", Util.money(s.price), { size = Ui.S.sm, color = T.gr }),
		Ui.line("Comisión", Util.money(-(s.fee or 0)), { size = Ui.S.sm, color = T.or_ }),
		Ui.line("Costo registrado", Util.money(-s.cost), { size = Ui.S.sm, color = T.or_ }),
		Ui.line("<b>Margen</b>", (s.margin >= 0 and "▲ " or "▼ ") .. Util.money(s.margin), { size = Ui.S.sm, color = s.margin >= 0 and T.gr or T.re2, border = false }),
	}, { gap = 0, pad = { 4, 12 } }).Parent = b
	footer(box, { closeBtn() })
end

-- Mercado: publicación (listingDialog) y publicar (publishDialog) -------------------------------------------
Dialogs.listing = function(box: Frame, params: any, d: any)
	local g = App.g
	local Market = App.screens.mercado
	local l = nil
	for _, x in g.market.listings do
		if x.id == params.listingId then
			l = x
		end
	end
	d.sig = function(gg: any): string
		for _, x in gg.market.listings do
			if x.id == params.listingId then
				return x.status .. tostring(x.bid) .. tostring(x.playerBid)
			end
		end
		return "gone"
	end
	if not l then
		header(box, "Publicación", false)
		local b = body(box)
		Ui.text("Esta publicación ya no existe (el mercado se renovó).", { size = 15 }).Parent = b
		footer(box, { closeBtn() })
		return
	end
	header(box, l.name)
	local b = body(box)
	local auction = l.mode == "subasta"
	local bidMin = auction and ((l.bid or 0) + 100) or 0
	params.bid = math.max(bidMin, params.bid or bidMin)
	local t = Market.total(l, auction and params.bid or l.price)
	local err = nil
	if l.status ~= "activa" then
		err = "La publicación está " .. l.status .. "."
	elseif auction then
		err = g.money < t.total and ("Fondos insuficientes para respaldar esa oferta (" .. Util.money(t.total) .. ").") or nil
	else
		err = Market.buyCheck(g, l)
	end
	local auctionChip = nil
	if auction then
		auctionChip = Ui.chip("Subasta · " .. (l.bids or 0) .. " ofertas · ", "cy")
		local lab = auctionChip:FindFirstChildOfClass("TextLabel") :: TextLabel
		App.dialogLive(function(gg: any)
			lab.Text = "Subasta · " .. (l.bids or 0) .. " ofertas · " .. Market.auctionText(gg, l.id)
		end)
	end
	Ui.row({ Ui.chip(l.rarity, Market.RARITY[l.rarity] or "cn"), Ui.chip("Vendedor ficticio: " .. l.seller, "cn"), Ui.chip(l.cond, "cn"), auctionChip }, 6, { wrap = true }).Parent = b
	if l.kind == "vehiculo" then
		local c = DesignCalc.computeDesign(nil, l.spec)
		local stats = {}
		for i, s in Catalog.STAT_DEFS do
			if i > 8 then
				break
			end
			local k = s[1]
			table.insert(stats, Ui.between(s[2], Util.num(c[k], (k == "accel" or k == "consumption") and 1 or 0) .. " <font color=\"#A3AAB8\" size=\"11\">" .. (k == "consumption" and (c.consUnit or "") or string.gsub(s[3], "índice 0–100", "/100")) .. "</font>"))
		end
		Ui.card({ Ui.grid(stats, 2, nil, 10) }, { gap = 0 }).Parent = b
		Ui.text("Al comprarlo entra al almacén como unidad propia (ocupa 1 lugar). Lo podés exhibir o revender.", { size = Ui.S.xs, color = T.mut }).Parent = b
	elseif l.kind == "pieza" then
		local p = Catalog.part(l.part.cat, l.part.id)
		Ui.text(Catalog.catLabel(p.cat) .. " · " .. p.desc .. ". Entra a Inventario › Piezas y, al instalarla en un diseño, cubre su costo de desarrollo (" .. Util.money(p.proto) .. ").", { size = Ui.S.sm, color = T.mut }).Parent = b
		if p.research and not Rules.has(g, p.research) then
			Ui.note("y", "Podés comprarla, pero para instalarla necesitás investigar «" .. Catalog.researchNode(p.research).name .. "».").Parent = b
		end
	elseif l.kind == "diseno" then
		Ui.text("Plano listo basado en " .. Catalog.base(l.baseId).name .. ". Se agrega como plantilla y la licencia del modelo queda pagada.", { size = Ui.S.sm, color = T.mut }).Parent = b
	else
		Ui.text(l.qty .. " unidades de " .. string.lower(Catalog.matLabel(l.mat)) .. ". Depósito: " .. g.derived.matsUsed .. "/" .. g.derived.caps.mats .. ".", { size = Ui.S.sm, color = T.mut }).Parent = b
	end
	if auction then
		Ui.col({
			Ui.fl("Tu oferta (mínimo " .. Util.money(bidMin) .. ")"),
			Ui.input(tostring(params.bid), "Oferta", function(text: string)
				local n = tonumber((string.gsub(text, "[^%d]", "")))
				if n then
					params.bid = Util.round(n / 100) * 100
				end
				App.renderDialog()
			end, { width = 200, name = "Oferta", numeric = true }),
			Ui.text("No se cobra ahora. Si al terminar sos la oferta más alta, se cobra el total y el auto entra a tu almacén (si hay lugar y dinero). " .. (l.playerBid and ("Tu oferta actual: " .. Util.money(l.playerBid) .. ".") or ""), { size = Ui.S.xs, color = T.mut }),
		}, 6).Parent = b
	end
	priceCard({
		"Precio" .. (auction and " ofertado" or "") .. "|" .. Util.money(t.price),
		"Impuesto (" .. Util.round(Catalog.RULES.taxRate * 100) .. "%)|" .. Util.money(t.tax),
		"Comisión del mercado (" .. Util.round(Catalog.RULES.feeRate * 100) .. "%)|" .. Util.money(t.fee),
	}, Util.money(t.total)).Parent = b
	if err then
		Ui.note("r", err).Parent = b
	end
	local act
	if auction then
		act = Ui.button("Ofertar " .. Util.money(params.bid), "p", function()
			App.request("marketBid", { listingId = l.id, amount = params.bid }, { button = act })
		end, { disabled = err ~= nil, why = err, name = "Ofertar" })
	else
		act = Ui.button("Comprar · " .. Util.money(t.total), "p", function()
			App.openDialog("confirm", {
				title = "Confirmar compra",
				body = "Vas a pagar <b>" .. Util.money(t.total) .. "</b> por «" .. l.name .. "» (" .. Util.money(t.price) .. " + impuesto " .. Util.money(t.tax) .. " + comisión " .. Util.money(t.fee) .. "). Te quedan " .. Util.money(g.money - t.total) .. ".",
				okLabel = "Pagar " .. Util.money(t.total),
				onOk = function()
					local r = App.request("marketBuy", { listingId = l.id })
					if r.ok then
						App.closeAllDialogs()
					end
				end,
			})
		end, { disabled = err ~= nil, why = err, name = "Comprar" })
	end
	footer(box, { closeBtn(), act })
end

Dialogs.publish = function(box: Frame, params: any)
	local g = App.g
	local avail = {}
	for _, u in g.units do
		if u.status == "almacen" then
			table.insert(avail, u)
		end
	end
	header(box, "Publicar en el mercado")
	local b = body(box)
	if #avail == 0 then
		Ui.note("y", "Necesitás una unidad terminada en el almacén para publicar.").Parent = b
		footer(box, { closeBtn() })
		return
	end
	local u = findUnit(g, params.unitId)
	if not u or u.status ~= "almacen" then
		u = avail[1]
		params.unitId = u.id
		params.price = nil
	end
	params.mode = params.mode or "directa"
	params.hours = params.hours or 6
	params.price = params.price or u.stats.price
	local price = Util.round(params.price)
	local ok = price >= 100 and price <= u.stats.price * 3
	local fee = Util.round(price * Catalog.RULES.feeRate)
	local unitOpts = {}
	for _, x in avail do
		table.insert(unitOpts, { x.id, x.name .. " · " .. x.serial })
	end
	Ui.col({ Ui.fl("Unidad"), Ui.select(u.id, unitOpts, function(v: any)
		params.unitId = v
		params.price = nil
		App.renderDialog()
	end, { fill = true, name = "UnidadPublicar" }) }, 6).Parent = b
	Ui.row({
		Ui.opt("Precio fijo", params.mode == "directa", function()
			params.mode = "directa"
			App.renderDialog()
		end, { fill = true }),
		Ui.opt("Subasta", params.mode == "subasta", function()
			params.mode = "subasta"
			App.renderDialog()
		end, { fill = true }),
	}, 10).Parent = b
	for _, c in b:GetChildren() do
		if c:IsA("Frame") and c:FindFirstChild("Opcion") then
			for _, o in c:GetChildren() do
				if o:IsA("TextButton") then
					local f = Instance.new("UIFlexItem")
					f.FlexMode = Enum.UIFlexMode.Fill
					f.Parent = o
					o.Size = UDim2.new(0, 0, 0, 40)
				end
			end
		end
	end
	Ui.col({
		Ui.fl((params.mode == "subasta" and "Precio de referencia" or "Precio") .. " (recomendado " .. Util.money(u.stats.price) .. ")"),
		Ui.input(tostring(price), "Precio", function(text: string)
			local n = tonumber((string.gsub(text, "[^%d]", "")))
			params.price = n or 0
			App.renderDialog()
		end, { name = "PrecioPublicar", numeric = true, invalid = not ok }),
		(not ok) and Ui.text("Ingresá un precio entre $100 y " .. Util.money(u.stats.price * 3) .. ".", { size = Ui.S.xs, color = T.re2 }) or nil,
	}, 6).Parent = b
	if params.mode == "subasta" then
		local hours = {}
		for _, h in { 3, 6, 12 } do
			local o = Ui.opt(h .. " h de juego", params.hours == h, function()
				params.hours = h
				App.renderDialog()
			end, { height = 40 })
			local f = Instance.new("UIFlexItem")
			f.FlexMode = Enum.UIFlexMode.Fill
			f.Parent = o
			table.insert(hours, o)
		end
		Ui.row(hours, 10).Parent = b
	end
	local margin = price - fee - u.cost
	local card = Ui.card({
		Ui.line("Costo de fabricación", Util.money(u.cost), { size = 14 }),
		Ui.line("Comisión al vender (" .. Util.round(Catalog.RULES.feeRate * 100) .. "%)", Util.money(-fee), { size = 14, color = T.or_ }),
		Ui.line("<b>Margen estimado</b>", Util.money(margin), { size = 14, color = margin >= 0 and T.gr or T.re2, border = false }),
	}, { gap = 0, pad = { 4, 12 } })
	card.Parent = b
	Ui.text("Mientras está publicada no se ofrece en el salón y sigue ocupando lugar del almacén. Podés retirarla en cualquier momento.", { size = Ui.S.xs, color = T.mut }).Parent = b
	local pub
	pub = Ui.button("Publicar", "p", function()
		local r = App.request("marketPublish", { unitId = u.id, price = price, mode = params.mode, hours = params.hours }, { button = pub })
		if r.ok then
			App.closeAllDialogs()
		end
	end, { disabled = not ok, why = "Precio inválido", name = "Publicar" })
	footer(box, { Ui.button("Cancelar", "default", App.closeDialog), pub })
end

-- Editor: cambios sin guardar (askLeaveEditor), modelos anteriores (prevModels) y prueba en pista --------------
Dialogs.unsaved = function(box: Frame, params: any)
	header(box, params.title or "Tenés cambios sin guardar", false)
	local b = body(box)
	local pend = params.pending or 0
	Ui.text("«" .. tostring(params.name) .. "» tiene cambios que no se guardaron como diseño. " .. (pend > 0 and ("Guardar cobra el desarrollo pendiente de " .. Util.money(pend) .. ".") or "Guardar no tiene costo adicional."), { size = 15, lineHeight = 1.5 }).Parent = b
	local save
	save = Ui.button(params.saveLabel or "Guardar y salir", "p", function()
		params.onSave(save)
	end, { name = "GuardarCambios" })
	footer(box, {
		Ui.button("Seguir editando", "default", App.closeDialog, { name = "SeguirEditando" }),
		Ui.button("Descartar", "d", params.onDiscard, { name = "Descartar" }),
		save,
	})
end

Dialogs.prevModels = function(box: Frame)
	local g = App.g
	header(box, "Modelos anteriores y plantillas")
	local b = body(box)
	Ui.button("Empezar un proyecto nuevo", "p", function()
		App.closeDialog()
		App.screens.editor.newProject()
	end, { small = true, icon = "plus" }).Parent = b
	if #g.designs == 0 then
		Ui.empty(nil, "Todavía no guardaste diseños.").Parent = b
	end
	for _, d in g.designs do
		App.screens.autos.designRow(g, d).Parent = b
	end
end

Dialogs.testDrive = function(box: Frame)
	local g = App.g
	local e = App.ui.editor
	local dd = e and e.draft
	if not dd then
		info(box, "Prueba en pista", {})
		return
	end
	local c = DesignCalc.computeDesign(g, dd)
	local lap = 60 + c.accel * 2.2 + (100 - c.handling) * 0.35 + c.stop * 0.25 - c.top * 0.05
	local drag = 7 + c.accel * 0.75
	info(box, "Prueba en pista · " .. dd.name, {
		Ui.text("Simulación con los valores actuales del proyecto (no consume dinero ni materiales).", { size = Ui.S.sm, color = T.mut }),
		Ui.grid({
			(Ui.kv("Vuelta al circuito de pruebas (2,1 km)", Util.num(lap, 1) .. " s")),
			(Ui.kv("Cuarto de milla (402 m)", Util.num(drag, 1) .. " s")),
			(Ui.kv("0–100 km/h", Util.num(c.accel, 1) .. " s")),
			(Ui.kv("Frenado 100→0", c.stop .. " m")),
			(Ui.kv("Velocidad máxima", c.top .. " km/h")),
			(Ui.kv("Autonomía estimada", Util.round((c.ev and 6000 or 5500) / c.consumption) .. " km")),
		}, 2, nil, 10),
		Ui.text("Menos segundos y metros es mejor. " .. (c.handling < 50 and "El manejo es bajo: probá frenos o suspensión mejores." or "Buen equilibrio en curvas."), { size = Ui.S.xs, color = T.mut }),
	})
end

-- Eliminar una ranura con datos dañados: se pide escribir BORRAR.
Dialogs.deleteCompany = function(box: Frame, params: any)
	header(box, "¿Eliminar " .. tostring(params.name) .. "?", false)
	local b = body(box)
	Ui.text("Se borra solo la ranura " .. params.slot .. ". Las otras empresas no se tocan. No se puede deshacer.", { size = 15, lineHeight = 1.5 }).Parent = b
	Ui.fl("Para confirmar, escribí «" .. params.expected .. "»").Parent = b
	Ui.input(params.typed or "", params.expected, function(text: string)
		params.typed = text
	end, { onChange = function(text: string)
		params.typed = text
	end, name = "ConfirmarNombre" }).Parent = b
	local del
	del = Ui.button("Eliminar definitivamente", "d", function()
		local r = App.request("deleteCompany", { slot = params.slot, confirm = params.typed or "" }, { button = del })
		if r.ok then
			App.closeDialog()
		end
	end, { name = "EliminarEmpresa" })
	footer(box, { Ui.button("Cancelar", "default", App.closeDialog), del })
end

return Dialogs
