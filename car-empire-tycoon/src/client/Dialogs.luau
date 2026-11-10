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
local Staff = require(Shared.Staff)

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
	juego = "La sede es tu espacio 3D: arrastrá para girar la cámara y usá la rueda (o pellizcá en celular) para acercar o alejar. Todo se maneja desde la barra de arriba: Diseño, Catálogo, Ventas (con Producción), Mercado, Investigación, Personal y Compañía (con Instalaciones).",
	fabrica = "Lanzá un lote eligiendo un diseño y cuántas unidades querés (100, 1.000, 10.000, 50.000 o cualquier número). La fábrica produce exactamente esa cantidad y se detiene: nunca repite sola. El lote se paga completo al ordenarlo y cada modelo tiene un solo lote; al terminar llegan las reseñas y elegís el precio. Cada línea de la sede fabrica un lote a la vez; los demás esperan en cola.",
	autos = "El catálogo reúne tus diseños con su año de modelo y generación. Desde acá lanzás lotes, editás, creás una nueva generación de un modelo o lo duplicás. «Historia de modelos» muestra cada generación con sus lotes, ventas y resultado.",
	ventas = "Lo fabricado se vende solo, sin negociar. El ritmo depende de la demanda del tipo de auto en el año, de su atractivo frente a los rivales, del precio, de tu reputación y del alcance de tu sede. «Modificar precio» cambia el ritmo desde ese momento. «Cerrar venta» deja de vender el modelo: las unidades sin vender se descartan sin reintegro y lo que faltaba fabricar se cancela y se reintegra. Estados: En fabricación, Por lanzar, En venta, Agotado y Retirado.",
	mercado = "Muestra la demanda de cada tipo de vehículo este año y cómo se reparte entre tus modelos, las marcas rivales ficticias y el resto del mercado. Es el mismo cálculo que usa la simulación para vender.",
	investigacion = "Cuatro áreas: Chasis, Motores, Seguridad y Tecnología. Cada investigación cuesta dinero y puntos de investigación (PI), que se pagan al empezar, y dura una cantidad de días de juego. Podés llevar varias a la vez y no se cancelan. Los PI los genera el centro de investigación (la sede) y cada línea que está fabricando. Se puede adelantar hasta 5 años, con recargo por año. Lo investigado queda para siempre; el equipamiento se elige al diseñar.",
	personal = "El personal es opcional. Contratar tiene un costo único y un salario mensual. Asignado a una estación acelera la fábrica, en ventas o marketing suma alcance comercial (con topes). No hay cansancio ni descansos que atender.",
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
	-- Pestañas: Audio, Gráficos, Accesibilidad y Datos.
	local tab = App.ui.settingsTab or "audio"
	local tabs = {}
	for _, t in { { "audio", "Audio" }, { "graficos", "Gráficos" }, { "accesibilidad", "Accesibilidad" }, { "datos", "Datos" } } do
		table.insert(tabs, Ui.opt(t[2], tab == t[1], function()
			App.ui.settingsTab = t[1]
			App.renderDialog()
		end, { name = "Ajustes_" .. t[1], height = 34 }))
	end
	Ui.row(tabs, 8, { Name = "PestanasAjustes", wrap = true }).Parent = b
	if tab == "audio" then
		section("Audio", true)
		row("Efectos de sonido", "Sonidos cortos al confirmar acciones.", Ui.toggle(s.sound ~= false, function()
			setting("sound", s.sound == false)
		end))
	elseif tab == "graficos" then
		section("Gráficos", true)
		row("Sombras 3D", "Desactivalas si el equipo funciona lento.", Ui.toggle(s.shadows ~= false, function()
			setting("shadows", s.shadows == false)
		end))
		row("Sensibilidad de la cámara", "Velocidad de rotación al arrastrar en el editor y en el escenario.", Ui.slider(s.camSpeed or 1, 0.4, 2, 0.1, function(v: number, final: boolean)
			if final then
				setting("camSpeed", math.floor(v * 10 + 0.5) / 10)
			end
		end, { width = 180, name = "SensibilidadCamara" }))
	elseif tab == "accesibilidad" then
		section("Accesibilidad", true)
		local sizes = {}
		for _, v in { { 1, "Normal" }, { 1.12, "Grande" }, { 1.25, "Muy grande" } } do
			table.insert(sizes, Ui.opt(v[2], s.textScale == v[1], function()
				setting("textScale", v[1])
			end))
		end
		row("Tamaño del texto", "Aumenta todos los textos de la interfaz.", Ui.row(sizes, 10, { Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY }))
		row("Reducir movimiento", "Quita animaciones, el giro del showroom y transiciones de cámara.", Ui.toggle(s.reduceMotion == true, function()
			setting("reduceMotion", not s.reduceMotion)
		end))
		row("Mostrar atajos de teclado", "Indicadores como «1», «E» o «Esc» junto a los botones.", Ui.toggle(s.keyHints ~= false, function()
			setting("keyHints", s.keyHints == false)
		end))
		row("Idioma", "Por ahora el juego está solo en español.", Ui.chip("Español", "cn"))
		row("Atajos", "0 Sede · 1–7 secciones · arrastrar para girar la cámara y rueda para acercar · Tab ocultar paneles · Esc cerrar. En el editor: [ y ] pasos, Ctrl+Z/Ctrl+Y.", nil)
	else
		section("Datos", true)
		local mode = App.payload and App.payload.saveMode
		row("Guardado en Roblox", mode == "memory" and "Studio sin acceso a la API: se guarda solo durante esta prueba." or "Tus empresas se guardan automáticamente en tu cuenta.", mode == "memory" and Ui.chip("Temporal", "cy") or Ui.chip("Activo", "cg"))
		row("Borrar todos los datos", "Elimina todas las empresas de tu cuenta. No se puede deshacer.", Ui.button("Borrar todo", "d", function()
			App.openDialog("confirm", {
				title = "¿Borrar todos los datos?",
				body = "Se eliminan todas las empresas de tu cuenta (las ranuras desbloqueadas se conservan). No se puede deshacer.",
				okLabel = "Borrar todo",
				danger = true,
				onOk = function()
					App.request("wipeAll", { confirm = "BORRAR" })
				end,
			})
		end, { small = true, name = "BorrarTodo" }))
	end
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
	-- Cada modelo se fabrica una sola vez: solo se ofrecen los que todavía no tuvieron su lote.
	local list = {}
	local launched = 0
	for _, d in g.designs do
		if not d.template and not d.lotLaunched then
			table.insert(list, d)
		elseif d.lotLaunched then
			launched += 1
		end
	end
	header(box, "Ordenar lote de producción")
	local b = body(box)
	if #list == 0 then
		Ui.note("b", launched > 0 and "Todos tus modelos ya tuvieron su lote: cada modelo se fabrica una sola vez. Para volver a producir, creá un modelo nuevo (Duplicar en el Catálogo) o una nueva generación."
			or "Primero guardá un diseño en el editor.").Parent = b
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
		local dd = list[#list]
		for _, x in list do
			if x.id == def then
				dd = x
			end
		end
		local unitNow = Rules.lotUnitCost(g, DesignCalc.computeDesign(g, dd).unitCost)
		st = { designId = def, qty = math.max(1, math.min(100, unitNow > 0 and math.floor(g.money / unitNow) or 100)) }
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

	local price = c.price -- el precio final se elige al ponerlo a la venta, después de las reseñas
	-- Estimación (mismo cálculo que el servidor).
	local est = Rules.designSalesEstimate(g, c, d, price)
	local lineRate = g.derived.lineRate
	local sellRate = math.max(0.01, est.rate)
	local prodMin = qty / math.max(0.01, lineRate)
	local sellMin = qty / math.min(sellRate, math.max(0.01, lineRate))
	-- El mismo costo por unidad que cobra el servidor (con la eficiencia del personal de Producción).
	local unit = Rules.lotUnitCost(g, c.unitCost)
	local totalCost = qty * unit
	local margin = price - unit
	local afford = unit > 0 and math.floor(g.money / unit) or qty
	local caps = g.derived.caps
	Ui.grid({
		(Ui.kv("Costo por unidad", Util.money(unit), { sub = "Calidad " .. Catalog.QUALITY_TIERS[d.quality + 1] .. " · " .. c.hp .. " hp" })),
		(Ui.kv("Costo total (se paga al ordenar)", Util.money(totalCost), { color = totalCost > g.money and T.re2 or T.or_, sub = "Tenés " .. Util.money(g.money) })),
		(Ui.kv("Precio de referencia", Util.money(price), { sub = "Lo elegís al ponerlo a la venta · ganancia ≈ " .. Util.money(margin) .. "/u" })),
		(Ui.kv("Ingresos potenciales (estimado)", Util.money(price * qty), { color = T.gr, sub = "Si se vende todo el lote" })),
		(Ui.kv("Ganancia potencial (estimada)", Util.money(margin * qty), { color = margin >= 0 and T.gr or T.re2, sub = "Ingresos − costo total" })),
		(Ui.kv("Ventas estimadas", Util.num(est.rate, 1) .. " por minuto", { color = T.gr, sub = "Cuota del " .. Util.num(est.share * 100, 1) .. " % de " .. Util.num(est.demand, 0) .. " autos/min" })),
		(Ui.kv("Tiempo de producción (estimado)", "≈ " .. Util.realTime(prodMin * 60), { sub = "A la velocidad actual, en una línea" })),
		(Ui.kv("Capacidad de fabricación", Util.num(lineRate, 1) .. " autos/min por línea", { sub = caps.lines .. (caps.lines == 1 and " línea" or " líneas") .. " · " .. Util.num(caps.capacity, 1) .. "/min en total" })),
		(Ui.kv("Venta completa (estimada)", "≈ " .. Util.realTime(sellMin * 60), { sub = est.rate < lineRate and "limitada por la demanda" or "limitada por la fábrica" })),
	}, App.isPhone() and 2 or 3, nil, 10).Parent = b
	Ui.text("Los ingresos, la ganancia y los tiempos son estimaciones con la demanda y los rivales de hoy: cambian con el precio, la competencia y los años.", { size = Ui.S.xs, color = T.mut }).Parent = b
	if sellMin > 45 then
		Ui.note("y", "Riesgo: a este ritmo el lote tardaría " .. Util.realTime(sellMin * 60) .. " en venderse. Si después lo cerrás, las unidades sin vender se pierden.").Parent = b
	end
	if afford < qty then
		Ui.note("r", "No alcanza el dinero: el lote cuesta " .. Util.money(totalCost) .. " y tenés " .. Util.money(g.money) .. ". Podés pagar hasta " .. Util.num(afford) .. " unidades.").Parent = b
		Ui.button("Usar el máximo que alcanza (" .. Util.num(afford) .. ")", "default", function()
			st.qty = math.max(1, afford)
			st.touched = true
			App.renderDialog()
		end, { small = true, name = "CantidadMaxima", disabled = afford < 1 }).Parent = b
	end
	Ui.note("b", "Cada modelo tiene UN solo lote: se fabrican " .. Util.num(qty) .. " unidades de «" .. d.name .. "» y la línea se detiene. Al terminar, cuatro críticos evalúan el auto y vos elegís el precio para ponerlo a la venta. Para volver a fabricar hará falta un modelo nuevo o una nueva generación.").Parent = b
	local create
	create = Ui.button("Ordenar " .. Util.num(qty) .. " unidades · " .. Util.money(totalCost), "p", function()
		local r = App.request("createLot", { designId = d.id, qty = qty }, { button = create })
		if r.ok then
			App.ui.lotDraft = nil
			App.closeAllDialogs()
			if App.ui.route ~= "fabrica" and App.ui.route ~= "editor" and App.ui.route ~= "ventas" then
				App.go("fabrica")
			end
		end
	end, { name = "ConfirmarLote", disabled = afford < qty, why = "No alcanza el dinero" })
	footer(box, { Ui.button("Cancelar", "default", App.closeDialog), create })
end

--[[ Reseñas de los críticos (al terminar un lote): aparecen de a una, con un segundo entre cada una, y se
	pueden saltar. Las notas vienen guardadas del servidor (no cambian al reabrir). Si el lote está «por
	lanzar», abajo se elige el precio y se pone a la venta. ]]
Dialogs.reviews = function(box: Frame, params: any, dd: any)
	local g = App.g
	local l = nil
	for _, x in g.lots do
		if x.id == params.lotId then
			l = x
		end
	end
	if not l then
		for _, x in g.lotHistory or {} do
			if x.id == params.lotId then
				l = x
			end
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
	if not l or not l.review then
		info(box, "Reseñas", { Ui.note("b", "Ese lote todavía no tiene reseñas: llegan cuando termina la fabricación.") })
		return
	end
	local rv = l.review
	App.ui.reviewShown = App.ui.reviewShown or {}
	local shown = App.ui.reviewShown[l.id] or 1
	header(box, "Reseñas de «" .. l.design.name .. "»")
	local b = body(box)
	Ui.text("Cuatro críticos especializados probaron el auto (" .. Util.num(l.produced) .. " unidades fabricadas).", { size = Ui.S.sm, color = T.mut }).Parent = b
	for i, sc in rv.scores do
		if i <= shown then
			local color = sc.score >= 7.5 and T.gr or (sc.score >= 5 and T.ye or T.re2)
			Ui.card({
				Ui.row({
					Ui.grow(Ui.col({
						Ui.text(sc.name, { size = 16, weight = W.bold }),
						Ui.text(sc.outlet, { size = Ui.S.xs, color = T.mut }),
					}, 2)),
					Ui.inline(Util.num(sc.score, 1), { size = 28, weight = W.heavy, color = color, name = "Nota" }),
				}, 10),
				Ui.text("«" .. sc.text .. "»", { size = Ui.S.sm, color = T.tx2, lineHeight = 1.4 }),
			}, { gap = 6, bg = T.p2, name = "Critico_" .. sc.critic }).Parent = b
		end
	end
	local done = shown >= #rv.scores
	if not done then
		-- El siguiente crítico aparece en un segundo (si el diálogo sigue abierto en este lote).
		local token = {}
		dd.revealToken = token
		task.delay(1, function()
			local top = App.topDialog()
			if dd.revealToken == token and top and top.kind == "reviews" and top.params.lotId == l.id then
				App.ui.reviewShown[l.id] = math.max(App.ui.reviewShown[l.id] or 1, shown + 1)
				App.renderDialog()
			end
		end)
	else
		local factor = Rules.reviewFactor(l)
		Ui.card({
			Ui.row({
				Ui.grow(Ui.col({
					Ui.text("Nota final (promedio)", { size = Ui.S.sm, color = T.mut }),
					Ui.text("Demanda ×" .. Util.num(factor, 2) .. (factor >= 1 and " por las buenas reseñas" or " por las reseñas"), { size = Ui.S.xs, color = factor >= 1 and T.gr or T.re2 }),
				}, 2)),
				Ui.inline(Util.num(rv.avg, 1) .. " / 10", { size = 30, weight = W.heavy, name = "NotaFinal" }),
			}, 10),
		}, { gap = 6, name = "NotaFinal" }).Parent = b
	end
	local buttons: { Instance? } = {}
	if not done then
		table.insert(buttons, Ui.button("Saltar", "default", function()
			App.ui.reviewShown[l.id] = #rv.scores
			App.renderDialog()
		end, { name = "SaltarResenas" }))
	elseif l.saleState == "por lanzar" then
		-- Precio de lanzamiento (mismo rango que el servidor) y estimación de ventas.
		local lo, hi = Rules.priceRange(l.unitCost, l.refPrice)
		params.price = math.clamp(params.price or l.refPrice, lo, hi)
		local price = params.price
		local function setPrice(p: number)
			params.price = math.clamp(Util.round(p / 10) * 10, lo, hi)
			App.renderDialog()
		end
		local saved = l.price
		l.price = price
		local rate = Rules.lotPotentialRate(g, l)
		l.price = saved
		Ui.col({
			Ui.fl("Precio de venta (" .. Util.money(lo) .. " a " .. Util.money(hi) .. ")"),
			Ui.row({
				Ui.input(tostring(price), "Precio", function(text: string)
					local n = tonumber((string.gsub(text, "[^%d]", "")))
					if n then
						setPrice(n)
					else
						App.renderDialog()
					end
				end, { name = "Precio", numeric = true, width = 140 }),
				Ui.button("−10 %", "default", function()
					setPrice(price * 0.9)
				end, { small = true, name = "PrecioMenos" }),
				Ui.button("Referencia " .. Util.money(l.refPrice), "default", function()
					setPrice(l.refPrice)
				end, { small = true, name = "PrecioReferencia" }),
				Ui.button("+10 %", "default", function()
					setPrice(price * 1.1)
				end, { small = true, name = "PrecioMas" }),
			}, 8, { wrap = true }),
		}, 6).Parent = b
		Ui.grid({
			(Ui.kv("Ventas estimadas", Util.num(rate, 1) .. " por minuto", { color = T.gr, sub = "Con las reseñas, el precio y la reputación" })),
			(Ui.kv("Ganancia por unidad", Util.money(price - l.unitCost), { color = price >= l.unitCost and T.gr or T.re2, sub = "Costo " .. Util.money(l.unitCost) })),
			(Ui.kv("Ingresos si se vende todo", Util.money(price * Rules.lotAvailable(l)), { color = T.gr, sub = Util.num(Rules.lotAvailable(l)) .. " unidades" })),
		}, App.isPhone() and 1 or 3, nil, 10).Parent = b
		if price < l.unitCost then
			Ui.note("r", "Por debajo del costo: cada venta pierde " .. Util.money(l.unitCost - price) .. ".").Parent = b
		elseif price > l.refPrice * 1.3 then
			Ui.note("y", "Un precio muy alto vende mucho más lento.").Parent = b
		end
		local launch
		launch = Ui.button("Poner a la venta a " .. Util.money(price), "p", function()
			local r = App.request("launchSale", { lotId = l.id, price = price }, { button = launch })
			if r.ok then
				App.closeDialog()
			end
		end, { name = "PonerALaVenta" })
		table.insert(buttons, Ui.button("Más tarde", "default", App.closeDialog, { name = "MasTarde" }))
		table.insert(buttons, launch)
	else
		table.insert(buttons, closeBtn())
	end
	footer(box, buttons)
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
--[[ Capacitación: params = { scope = "individual" | "departamento" | "general", employeeId?, dept? }. Muestra
	antes de pagar el costo, la duración, la mejora garantizada y el resultado de cada participante (el mismo
	cálculo que cobra el servidor: Staff.trainingPlan). ]]
Dialogs.training = function(box: Frame, params: any)
	local g = App.g
	local st = App.ui.trainDraft
	if not st or st.scope ~= params.scope or st.employeeId ~= params.employeeId or st.dept ~= params.dept then
		local dept = params.dept or "produccion"
		st = { scope = params.scope or "general", employeeId = params.employeeId, dept = params.dept, level = "basico", skill = Staff.dept(dept).skills[1] }
		App.ui.trainDraft = st
	end
	header(box, "Capacitación · " .. (Catalog.TRAINING.scopes[st.scope] or st.scope))
	local b = body(box)
	local office = Rules.officeLevel(g)
	local levels = {}
	for _, l in Catalog.TRAINING.levels do
		local locked = office < l.office
		table.insert(levels, Ui.opt(l.name .. " · +" .. l.gain .. " · " .. l.days .. " días" .. (locked and (" · oficinas nivel " .. l.office) or ""), st.level == l.id, function()
			if not locked then
				st.level = l.id
				App.renderDialog()
			end
		end, { name = "Nivel_" .. l.id, fill = true, height = 36, disabled = locked }))
	end
	Ui.col({ Ui.lbl("Nivel"), Ui.grid(levels, App.isPhone() and 1 or 3, nil, 8) }, 6).Parent = b
	local skills = {}
	for _, id in Staff.DEPT_ORDER do
		for _, k in Staff.dept(id).skills do
			table.insert(skills, { k, Staff.dept(id).name .. " · " .. Staff.skill(k).name })
		end
	end
	Ui.selectF("Habilidad a mejorar", st.skill, skills, function(v: any)
		st.skill = v
		App.renderDialog()
	end, { height = 34, name = "HabilidadCapacitacion" }).Parent = b
	local plan, why = Staff.trainingPlan(g, { scope = st.scope, level = st.level, skill = st.skill, employeeId = st.employeeId, dept = st.dept }, office, Rules.year(g))
	if not plan then
		Ui.note("y", why or "No se puede capacitar.").Parent = b
	else
		priceCard({ "Participantes|" .. #plan.members, "Duración|" .. plan.days .. " días de juego", "Mejora garantizada|+" .. plan.gain .. " (hasta el potencial)" }, Util.money(plan.cost)).Parent = b
		local rows: { Instance? } = { Ui.lbl("Resultado final de cada participante") }
		for _, m in plan.members do
			table.insert(rows, Ui.row({ Ui.grow(Ui.text(m.name, { size = Ui.S.sm })), Ui.inline(m.from .. " → " .. m.to, { size = Ui.S.sm, weight = W.bold, color = T.gr }) }, 8))
		end
		Ui.card(rows, { gap = 4, name = "Participantes" }).Parent = b
		Ui.text("Mientras se capacitan siguen trabajando al " .. Util.round(Catalog.STAFF.trainingProductivity * 100) .. " % y al terminar recuperan su productividad. Cada empleado hace una capacitación a la vez.", { size = Ui.S.xs, color = T.mut }).Parent = b
	end
	local ok
	ok = Ui.button("Pagar y empezar", "p", function()
		local r = App.request("startTraining", { scope = st.scope, level = st.level, skill = st.skill, employeeId = st.employeeId, dept = st.dept }, { button = ok })
		if r and r.ok then
			App.ui.trainDraft = nil
			App.closeDialog()
		end
	end, { name = "EmpezarCapacitacion", disabled = plan == nil or g.money < plan.cost, why = plan and "Fondos insuficientes" or why })
	footer(box, { closeBtn("Cancelar"), ok })
end

--[[ Nueva campaña: tipo, modelo (de modelo), presupuesto mensual y duración. Muestra costo total y efecto
	antes de pagar con el mismo cálculo que cobra el servidor (Rules.campaignPlan). ]]
local BUDGET_STEPS = { 0.25, 0.5, 1, 2, 4, 8 }
local DAY_STEPS = { 15, 30, 60, 90, 120, 180 }
Dialogs.campaign = function(box: Frame, _params: any)
	local g = App.g
	local MK = Catalog.MARKETING
	local era = Rules.marketingEra(g)
	local st = App.ui.campaignDraft
	if not st then
		st = { kind = "modelo", designId = nil, budget = Util.round(MK.budgetRef * era), days = 30 }
		App.ui.campaignDraft = st
	end
	header(box, "Nueva campaña publicitaria")
	local b = body(box)
	local kinds = {}
	for _, k in MK.order do
		local kd = MK.kinds[k]
		table.insert(kinds, Ui.opt(kd.name, st.kind == k, function()
			st.kind = k
			App.renderDialog()
		end, { name = "Tipo_" .. k, fill = true, height = 36 }))
	end
	Ui.col({ Ui.lbl("Tipo"), Ui.grid(kinds, 2, nil, 8), Ui.text(MK.kinds[st.kind].desc, { size = Ui.S.xs, color = T.mut }) }, 6).Parent = b
	if st.kind == "modelo" then
		local models = {}
		for _, l in g.lots do
			if l.saleState ~= "agotado" and l.saleState ~= "retirado" then
				table.insert(models, { l.designId, l.design.name .. " · " .. l.saleState })
			end
		end
		if #models > 0 and not st.designId then
			st.designId = models[1][1]
		end
		if #models > 0 then
			Ui.selectF("Modelo promocionado", st.designId, models, function(v: any)
				st.designId = v
				App.renderDialog()
			end, { height = 34, name = "ModeloCampana" }).Parent = b
		end
	end
	local budgets = {}
	for _, m in BUDGET_STEPS do
		local v = Util.round(MK.budgetRef * era * m / 100) * 100
		table.insert(budgets, Ui.opt(Util.money(v), st.budget == v, function()
			st.budget = v
			App.renderDialog()
		end, { name = "Presupuesto_" .. m, fill = true, height = 34 }))
	end
	Ui.col({ Ui.lbl("Presupuesto mensual"), Ui.grid(budgets, App.isPhone() and 2 or 3, nil, 6) }, 6).Parent = b
	local days = {}
	for _, d in DAY_STEPS do
		table.insert(days, Ui.opt(d .. " días", st.days == d, function()
			st.days = d
			App.renderDialog()
		end, { name = "Dias_" .. d, fill = true, height = 34 }))
	end
	Ui.col({ Ui.lbl("Duración"), Ui.grid(days, App.isPhone() and 2 or 3, nil, 6) }, 6).Parent = b
	local plan, why = Rules.campaignPlan(g, { kind = st.kind, designId = st.designId, budget = st.budget, days = st.days })
	if plan then
		local eff = plan.boost * (1 + Rules.staff(g, "mk_creatividad"))
		priceCard({ "Efecto|+" .. Util.round(eff * 100) .. " % de demanda", "Duración|" .. plan.days .. " días de juego" }, Util.money(plan.cost)).Parent = b
		Ui.text("Más presupuesto suma efecto, cada vez menos (rendimientos decrecientes). Se paga al empezar; cancelar no devuelve dinero.", { size = Ui.S.xs, color = T.mut }).Parent = b
	else
		Ui.note("y", why or "Campaña inválida.").Parent = b
	end
	local ok
	ok = Ui.button("Pagar y lanzar", "p", function()
		local r = App.request("startCampaign", { kind = st.kind, designId = st.designId, budget = st.budget, days = st.days }, { button = ok })
		if r and r.ok then
			App.ui.campaignDraft = nil
			App.closeDialog()
		end
	end, { name = "LanzarCampana", disabled = plan == nil or Rules.campaign(g) ~= nil or g.money < plan.cost, why = Rules.campaign(g) and "Ya hay una campaña activa" or (plan and "Fondos insuficientes" or why) })
	footer(box, { closeBtn("Cancelar"), ok })
end

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
