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
		Ui.text("•  Empezás en 1970 y el calendario avanza solo (un año cada " .. Util.round(Catalog.CALENDAR.realSecondsPerYear / 60) .. " minutos reales).\n•  Producción por lotes: elegís cuántas unidades fabricar y la fábrica se detiene al terminar.\n•  Ventas automáticas según demanda, precio, atractivo y competencia, con «Cerrar venta».\n•  Investigación histórica 1970–2030 con PI por minuto según la sede.\n•  Marcas rivales ficticias en cada tipo de vehículo.", { size = 15, lineHeight = 1.55 }),
		Ui.text("Eventos de temporada, amigos y tienda: todavía no implementados.", { size = Ui.S.xs, color = T.mut }),
	})
end

-- Amigos, evento y tienda (funciones futuras de la V3)
Dialogs.future = function(box: Frame, params: any)
	local N = App.screens.menu.NEWS
	if params.what == "amigos" then
		info(box, "Amigos", { Ui.text("Función futura. En Roblox, esta sección mostraría a tus amigos conectados y te dejaría visitar sus sedes. Todavía no está implementada.", { size = 15, lineHeight = 1.5 }) })
	elseif params.what == "eventos" then
		info(box, "Evento · " .. N.event, {
			Ui.row({ Ui.chip("No implementado", "cy"), Ui.grow(Ui.text("Los eventos de temporada son una función futura: todavía no modifican la simulación ni entregan premios.", { size = 15, lineHeight = 1.5 })) }, 8),
		})
	else
		info(box, "Tienda", { Ui.text("No hay compras con dinero real ni moneda premium. Todo se consigue jugando.", { size = 15, lineHeight = 1.5 }) })
	end
end

-- Ayuda por sección (helpDialog)
local HELP = {
	juego = "La sede es tu espacio 3D. Caminá con WASD o flechas (en celular, con la palanca táctil), acercate a un objeto y presioná E (o tocá la indicación). El calendario empieza en enero de 1970 y avanza solo: a 1×, un año dura unos 11 minutos reales. El ciclo es: diseñar un auto → lanzar un lote → se vende solo → mejorar la empresa → investigar → diseñar el siguiente.",
	fabrica = "Lanzá un lote eligiendo un diseño y cuántas unidades querés (100, 1.000, 10.000, 50.000 o cualquier número). La fábrica produce exactamente esa cantidad y se detiene: nunca repite sola. Cada unidad se paga al terminarla; si falta dinero, la línea espera sin generar deuda. Cada línea de la sede fabrica un lote a la vez; los demás esperan en cola.",
	autos = "El catálogo reúne tus diseños con su año de modelo y generación. Desde acá lanzás lotes, editás, creás una nueva generación de un modelo o lo duplicás. «Historia de modelos» muestra cada generación con sus lotes, ventas y resultado.",
	ventas = "Lo fabricado se vende solo, sin negociar. El ritmo depende de la demanda del tipo de auto en el año, de su atractivo frente a los rivales, del precio, de tu reputación y del alcance de tu sede. «Modificar precio» cambia el ritmo desde ese momento. «Cerrar venta» deja de vender el modelo: las unidades sin vender se descartan sin reintegro y lo que faltaba fabricar se cancela sin costo. Estados: En venta, Agotado y Retirado.",
	mercado = "Muestra la demanda de cada tipo de vehículo este año y cómo se reparte entre tus modelos, las marcas rivales ficticias y el resto del mercado. Es el mismo cálculo que usa la simulación para vender.",
	investigacion = "Las tecnologías aparecen en su época (por ejemplo, el turbo en 1977 o los eléctricos en 2010) y algunas requieren otras antes. Cada una cuesta dinero al empezar y puntos de investigación (PI). La sede genera PI por minuto: ampliarla acelera la investigación; el personal del laboratorio suma un extra.",
	personal = "El personal es opcional. Contratar tiene un costo único y un salario mensual. Asignado a una estación acelera la fábrica, en el laboratorio suma PI y en ventas o marketing suma alcance comercial (con topes). No hay cansancio ni descansos que atender.",
	compania = "Datos de marca, sede y finanzas acumuladas. Hay cinco sedes, del Garaje inicial al Imperio automotriz: cada una da más PI por minuto, más líneas de producción, más alcance comercial y más lugar para personal.",
	misiones = "Las misiones avanzan con acciones reales. Las del año se reinician cada enero. Una recompensa reclamada queda registrada en la partida.",
	estadisticas = "Todo se calcula con el historial mensual de la partida (base de caja). «Fabricación pagada» es lo que costaron las unidades terminadas en el período. «Margen de lo vendido» es informativo (precio − costo de cada auto vendido) y no se descuenta dos veces.",
	editor = "El proyecto se guarda en la partida mientras editás. Solo aparecen motores, cajas y opciones de tu época o investigadas. La licencia del modelo y el desarrollo de piezas se pagan una sola vez al guardar el diseño; el costo de fabricación se paga por cada unidad del lote.",
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
			Ui.inline(Util.gameDate(n.day), { size = Ui.S.xs, color = T.mut }),
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

-- Lanzar lote (reemplaza la orden de producción): diseño, cantidad libre, precio y estimación ----------------
local QTY_PRESETS = { 100, 1000, 10000, 50000 }

local function parseInt(text: string): number?
	local digits = string.gsub(text, "[^%d]", "")
	return tonumber(digits)
end

Dialogs.lot = function(box: Frame, params: any)
	local g = App.g
	local list = {}
	for _, d in g.designs do
		if not d.template then
			table.insert(list, d)
		end
	end
	header(box, "Lanzar lote de producción")
	local b = body(box)
	if #list == 0 then
		Ui.note("b", "Primero guardá un diseño en el editor.").Parent = b
		footer(box, { closeBtn() })
		return
	end
	local st = App.ui.lotDraft
	if not st or (params.designId and st.designId ~= params.designId and not st.touched) then
		local def = list[#list].id
		for _, d in list do
			if d.id == params.designId then
				def = d.id
			end
		end
		st = { designId = def, qty = 100 }
		App.ui.lotDraft = st
	end
	local d = list[#list]
	for _, x in list do
		if x.id == st.designId then
			d = x
		end
	end
	if st.designId ~= d.id or st.priceFor ~= d.id then
		st.price = nil
	end
	st.designId = d.id
	local c = DesignCalc.computeDesign(g, d)
	local lo, hi = Rules.priceRange(c.unitCost, c.price)
	local price = math.clamp(st.price or c.price, lo, hi)
	st.price, st.priceFor = price, d.id
	local qty = math.clamp(math.floor(st.qty or 100), 1, Catalog.RULES.maxLotQty)
	st.qty = qty

	local designOpts = {}
	for _, x in list do
		table.insert(designOpts, { x.id, x.name .. " · " .. (x.generation or "") })
	end
	Ui.col({ Ui.fl("Modelo (diseño guardado)"), Ui.select(d.id, designOpts, function(v: any)
		st.designId = v
		st.touched = true
		App.renderDialog()
	end, { fill = true, name = "ModeloLote" }) }, 6).Parent = b

	-- Cantidad: atajos y número libre.
	local presets = {}
	for _, q in QTY_PRESETS do
		table.insert(presets, Ui.opt(Util.num(q), qty == q, function()
			st.qty = q
			st.touched = true
			App.renderDialog()
		end, { height = 36, name = "Cantidad_" .. q }))
	end
	local qtyBox = Ui.input(tostring(qty), "Cantidad", function(text: string)
		local n = parseInt(text)
		st.qty = n and math.clamp(math.floor(n), 1, Catalog.RULES.maxLotQty) or qty
		st.touched = true
		App.renderDialog()
	end, { name = "Cantidad", numeric = true, width = 140 })
	Ui.col({
		Ui.fl("Cantidad de unidades (1 a " .. Util.num(Catalog.RULES.maxLotQty) .. ")"),
		Ui.row({ Ui.row(presets, 8, { wrap = true, Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY }), qtyBox }, 10, { wrap = true }),
	}, 6).Parent = b

	-- Precio: número libre dentro del rango y atajos respecto del de referencia.
	local function setPrice(p: number)
		st.price = math.clamp(Util.round(p / 10) * 10, lo, hi)
		App.renderDialog()
	end
	local priceBox = Ui.input(tostring(price), "Precio", function(text: string)
		local n = parseInt(text)
		if n then
			setPrice(n)
		else
			App.renderDialog()
		end
	end, { name = "Precio", numeric = true, width = 140 })
	Ui.col({
		Ui.fl("Precio de venta (" .. Util.money(lo) .. " a " .. Util.money(hi) .. ")"),
		Ui.row({
			priceBox,
			Ui.button("−10 %", "default", function()
				setPrice(price * 0.9)
			end, { small = true, name = "PrecioMenos" }),
			Ui.button("Referencia " .. Util.money(c.price), price == c.price and "p" or "default", function()
				setPrice(c.price)
			end, { small = true, name = "PrecioReferencia" }),
			Ui.button("+10 %", "default", function()
				setPrice(price * 1.1)
			end, { small = true, name = "PrecioMas" }),
		}, 8, { wrap = true }),
	}, 6).Parent = b

	-- Estimación (mismo cálculo que el servidor).
	local est = Rules.designSalesEstimate(g, c, d, price)
	local lineRate = g.derived.lineRate
	local sellRate = math.max(0.01, est.rate)
	local prodMin = qty / math.max(0.01, lineRate)
	local sellMin = qty / math.min(sellRate, math.max(0.01, lineRate))
	local totalCost = qty * c.unitCost
	local margin = price - c.unitCost
	local afford = c.unitCost > 0 and math.floor(g.money / c.unitCost) or qty
	Ui.grid({
		(Ui.kv("Costo por unidad", Util.money(c.unitCost), { sub = "Se paga al terminar cada unidad" })),
		(Ui.kv("Costo del lote", Util.money(totalCost), { sub = "Tenés " .. Util.money(g.money) })),
		(Ui.kv("Ventas estimadas", Util.num(est.rate, 1) .. " por minuto", { color = T.gr, sub = "Cuota del " .. Util.num(est.share * 100, 1) .. " % de " .. Util.num(est.demand, 0) .. " autos/min" })),
		(Ui.kv("Fabricación", "≈ " .. Util.realTime(prodMin * 60), { sub = Util.num(lineRate, 1) .. " autos/min en una línea" })),
		(Ui.kv("Venta completa", "≈ " .. Util.realTime(sellMin * 60), { sub = est.rate < lineRate and "limitada por la demanda" or "limitada por la fábrica" })),
		(Ui.kv("Ganancia por unidad", Util.money(margin), { color = margin >= 0 and T.gr or T.re2, sub = "Si se vende todo: " .. Util.money(margin * qty) })),
	}, App.isPhone() and 2 or 3, nil, 10).Parent = b
	if price < c.unitCost then
		Ui.note("r", "El precio está por debajo del costo: cada venta pierde " .. Util.money(c.unitCost - price) .. ".").Parent = b
	elseif price > c.price * 1.3 then
		Ui.note("y", "Un precio muy alto vende mucho más lento.").Parent = b
	end
	if afford < qty then
		Ui.note("b", "Hoy alcanza para fabricar " .. Util.num(afford) .. " unidades. El resto se fabrica con lo que entra por las ventas; si el dinero no alcanza, la línea espera sin generar deuda.").Parent = b
	end
	Ui.note("b", "Se fabrican exactamente " .. Util.num(qty) .. " unidades de «" .. d.name .. "» y la producción se detiene. Lo terminado se vende solo. El lote guarda una copia de esta versión del diseño.").Parent = b
	local create
	create = Ui.button("Lanzar " .. Util.num(qty) .. " unidades", "p", function()
		local r = App.request("createLot", { designId = d.id, qty = qty, price = price }, { button = create })
		if r.ok then
			App.ui.lotDraft = nil
			App.closeAllDialogs()
			if App.ui.route ~= "fabrica" and App.ui.route ~= "editor" and App.ui.route ~= "ventas" then
				App.go("fabrica")
			end
		end
	end, { name = "ConfirmarLote" })
	footer(box, { Ui.button("Cancelar", "default", App.closeDialog), create })
end

-- Modificar el precio de un lote a la venta (afecta las ventas desde ese momento).
Dialogs.price = function(box: Frame, params: any, dd: any)
	local g = App.g
	local l = nil
	for _, x in g.lots do
		if x.id == params.lotId then
			l = x
		end
	end
	dd.sig = function(gg: any): string
		for _, x in gg.lots do
			if x.id == params.lotId then
				return x.saleState
			end
		end
		return "fuera"
	end
	if not l then
		info(box, "Modificar precio", { Ui.note("b", "Ese lote ya no está a la venta.") })
		return
	end
	header(box, "Precio de " .. l.design.name)
	local b = body(box)
	local lo, hi = Rules.priceRange(l.unitCost, l.refPrice)
	params.price = math.clamp(params.price or l.price, lo, hi)
	local price = params.price
	local function setPrice(p: number)
		params.price = math.clamp(Util.round(p / 10) * 10, lo, hi)
		App.renderDialog()
	end
	local box2 = Ui.input(tostring(price), "Precio", function(text: string)
		local n = tonumber((string.gsub(text, "[^%d]", "")))
		if n then
			setPrice(n)
		else
			App.renderDialog()
		end
	end, { name = "Precio", numeric = true, width = 140 })
	Ui.col({
		Ui.fl("Nuevo precio (" .. Util.money(lo) .. " a " .. Util.money(hi) .. ")"),
		Ui.row({
			box2,
			Ui.button("−10 %", "default", function()
				setPrice(price * 0.9)
			end, { small = true }),
			Ui.button("Referencia " .. Util.money(l.refPrice), "default", function()
				setPrice(l.refPrice)
			end, { small = true }),
			Ui.button("+10 %", "default", function()
				setPrice(price * 1.1)
			end, { small = true }),
		}, 8, { wrap = true }),
	}, 6).Parent = b
	-- Comparación de ritmos con el precio actual y el nuevo (mismo cálculo que el servidor).
	local now = Rules.lotPotentialRate(g, l)
	local saved = l.price
	l.price = price
	local after = Rules.lotPotentialRate(g, l)
	l.price = saved
	Ui.grid({
		(Ui.kv("Precio actual", Util.money(saved), { sub = Util.num(now, 1) .. " ventas/min" })),
		(Ui.kv("Precio nuevo", Util.money(price), { color = T.vi2, sub = Util.num(after, 1) .. " ventas/min" })),
		(Ui.kv("Ganancia por unidad", Util.money(price - l.unitCost), { color = price >= l.unitCost and T.gr or T.re2, sub = "Costo " .. Util.money(l.unitCost) })),
	}, 3, nil, 10).Parent = b
	if price < l.unitCost then
		Ui.note("r", "Por debajo del costo: cada venta pierde dinero.").Parent = b
	end
	local ok
	ok = Ui.button("Aplicar precio", "p", function()
		local r = App.request("setLotPrice", { lotId = l.id, price = price }, { button = ok })
		if r.ok then
			App.closeDialog()
		end
	end, { name = "AplicarPrecio" })
	footer(box, { Ui.button("Cancelar", "default", App.closeDialog), ok })
end

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
