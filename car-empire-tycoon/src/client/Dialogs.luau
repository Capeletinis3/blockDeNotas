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
	fabrica = "Elegí una línea libre y tocá «Iniciar producción»: aparece el catálogo de tus modelos finalizados (los borradores no se fabrican). Escribí cuántas unidades querés, revisá el costo total, la duración y las bonificaciones, y confirmá. El lote se paga completo al confirmarlo, no se puede cancelar ni pausar y cada modelo produce un solo lote. Cada línea fabrica un lote por vez; la 2 se desbloquea con dinero del juego y la 3 con Robux para toda la cuenta. La fabricación avanza con el calendario (1×, 2× o 3×) y se detiene en pausa.",
	autos = "El catálogo reúne tus diseños con su año de modelo y generación. Desde acá lanzás lotes, editás, creás una nueva generación de un modelo o lo duplicás. «Historia de modelos» muestra cada generación con sus lotes, ventas y resultado.",
	ventas = "Lo fabricado se vende solo, sin negociar. Elegí un modelo de la lista para ver su precio, costo, precio recomendado, demanda estimada (de muy baja a muy alta), ventas, stock, ingresos y la nota de los críticos. El precio es libre: escribilo y la demanda prevista y el margen se actualizan antes de aplicarlo; afecta solo las ventas futuras. La demanda depende del precio, la calidad, las prestaciones, las reseñas, tu reputación, los rivales y las campañas. «Cerrar venta» (con el lote ya fabricado) deja de vender el modelo y descarta lo que no se vendió, sin reintegro.",
	mercado = "Muestra la demanda de cada tipo de vehículo este año y cómo se reparte entre tus modelos, las marcas rivales ficticias y el resto del mercado. Es el mismo cálculo que usa la simulación para vender.",
	investigacion = "Cuatro categorías en el menú de la izquierda: Chasis, Motores, Seguridad y Tecnología. Arriba ves tus PI y todas las investigaciones en curso. Los filtros (Todas, Disponibles, En curso, Bloqueadas, Completadas) solo cambian qué tarjetas se ven: en «Todas» está el catálogo completo, también lo futuro con su año y sus requisitos. «Investigar» abre una confirmación con el costo definitivo en dinero y PI, la duración y el recargo si la adelantás (hasta 5 años: +15 % de dinero y PI y +10 % de duración por año); recién al confirmar se descuentan los recursos. Podés llevar varias a la vez y no se cancelan. Los PI los genera el centro de investigación y cada línea que fabrica; con la empresa en pausa (o con este menú abierto) no avanzan. Lo investigado aparece en el editor para elegirlo en diseños nuevos: no se instala solo en los autos.",
	personal = "El personal es opcional. Contratar tiene un costo único y un salario mensual. Asignado a una estación acelera la fábrica, en ventas o marketing suma alcance comercial (con topes). No hay cansancio ni descansos que atender.",
	compania = "Datos de marca, sede y finanzas acumuladas. Hay cinco sedes, del Garaje inicial al Imperio automotriz: cada una da más PI por minuto, más líneas de producción, más alcance comercial y más lugar para personal.",
	misiones = "Las misiones avanzan con acciones reales. Las del año se reinician cada enero. Una recompensa reclamada queda registrada en la partida.",
	estadisticas = "Todo se calcula con el historial mensual de la partida (base de caja). «Fabricación pagada» es lo que costaron las unidades terminadas en el período. «Margen de lo vendido» es informativo (precio − costo de cada auto vendido) y no se descuenta dos veces.",
	editor = "Cinco etapas: chasis, motor, seguridad, tecnología y confort, y resumen. Cada tarjeta se aplica al instante y el panel derecho muestra cómo cambian las estadísticas y el costo (verde mejora, rojo empeora). El borrador se guarda solo en la partida: podés salir, investigar y volver. Solo aparecen componentes de tu época o investigados. Al «Finalizar diseño» se paga el desarrollo (licencia, prototipos e ingeniería) y el modelo queda definitivo, listo para Producción; el costo de fabricación se paga por cada unidad del lote.",
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

-- Iniciar producción: catálogo de modelos finalizados → cantidad → confirmación obligatoria ------------------
-- params = { line?, designId? }. Sin línea se usa la primera libre. Todo lo vuelve a validar el servidor
-- (Actions.createLot): modelo, línea, cantidad y dinero; el costo y la duración salen de los mismos cálculos.
local QTY_PRESETS = { 10, 50, 100, 500, 1000 }

local parseNumber = Util.parseNumber

-- Cantidad escrita: entero positivo dentro del tope técnico, o nil (y el motivo).
local function validQty(n: any): (number?, string?)
	if type(n) ~= "number" or n ~= n or n ~= math.floor(n) then
		return nil, "Escribí una cantidad entera de unidades."
	end
	if n < 1 then
		return nil, "La cantidad tiene que ser al menos 1."
	end
	if n > Catalog.RULES.maxLotQty then
		return nil, "El tope técnico de un lote es " .. Util.num(Catalog.RULES.maxLotQty) .. " unidades."
	end
	return n, nil
end
Dialogs.validQty = validQty

-- Estado de fabricación de un modelo para el catálogo: nil si se puede fabricar, o el motivo.
local function lotBlock(g: any, d: any): string?
	if d.template then
		return "Plantilla: no se fabrica"
	end
	if d.lotLaunched then
		for _, l in g.lots do
			if l.designId == d.id and Rules.lotProducing(l) then
				return "En fabricación (su único lote)"
			end
		end
		return "Ya fabricó su único lote: para producir otra vez, creá un modelo nuevo o una nueva generación"
	end
	return nil
end
Dialogs.lotBlock = lotBlock

Dialogs.lot = function(box: Frame, params: any)
	local g = App.g
	local st = App.ui.lotDraft
	if not st or st.line ~= params.line then
		st = { step = params.designId and "config" or "catalogo", designId = params.designId, line = params.line, qtyText = "" }
		App.ui.lotDraft = st
	end
	-- Línea: la elegida (si sigue libre) o la primera libre.
	local line = params.line
	if line and (not Rules.ownsLine(g, line) or Rules.lineLot(g, line)) then
		line = nil
	end
	line = line or Rules.freeLine(g)
	if not line then
		info(box, "Iniciar producción", { Ui.note("b", "Todas tus líneas están fabricando. Cada línea completa su lote antes de empezar otro; mirá el avance en Ventas › Producción.") })
		return
	end
	local design = nil
	for _, d in g.designs do
		if d.id == st.designId then
			design = d
		end
	end
	if st.step == "config" and (not design or lotBlock(g, design)) then
		st.step = "catalogo"
	end

	if st.step == "catalogo" then
		header(box, "Iniciar producción · línea " .. line)
		local b = body(box)
		Ui.text("Elegí un modelo finalizado. Los borradores no se fabrican y cada modelo produce un solo lote.", { size = Ui.S.sm, color = T.mut }).Parent = b
		local cards = {}
		local any = false
		for _, d in g.designs do
			if not d.template then
				any = true
				local why = lotBlock(g, d)
				local c = DesignCalc.computeDesign(g, d)
				local base = Catalog.base(d.baseId)
				local motor = Catalog.part("motor", d.parts.motor)
				local card = Ui.new("TextButton", {
					Name = "Vehiculo_" .. d.id, Text = "", AutoButtonColor = false,
					BackgroundColor3 = Ui.hex("#111A2B"), BackgroundTransparency = why and 0.45 or 0.1,
					Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Corner = 12, Stroke = { Ui.hex("#22304A"), 1 }, Pad = 10,
					List = { dir = "V", gap = 6 },
				}, {
					Ui.carThumb(d, 240, 120),
					Ui.text(d.name, { size = 15, weight = W.bold, color = why and T.mut or T.tx }),
					Ui.text((base and base.name or "") .. " · " .. (motor and (string.gsub(motor.name, " · nivel %d+$", "")) .. " nivel " .. tostring(d.motorLevel or 1) or ""), { size = Ui.S.xs, color = T.mut }),
					Ui.text(tostring(d.generation or ""), { size = Ui.S.xs, color = T.mut }),
					Ui.between("Costo estimado por unidad", Util.money(Rules.lotUnitCost(g, c.unitCost))),
					why and Ui.why(why) or Ui.chip("● Disponible para fabricar", "cg"),
				})
				local thumb = card:FindFirstChild("Miniatura") :: any
				if thumb then
					thumb.Size = UDim2.new(1, 0, 0, 120)
				end
				card:SetAttribute("disponible", why == nil)
				card.Activated:Connect(function()
					if why then
						App.toast("info", d.name .. ": " .. why)
						return
					end
					st.designId = d.id
					st.step = "config"
					App.renderDialog()
				end)
				table.insert(cards, card)
			end
		end
		if not any then
			Ui.note("b", "Todavía no finalizaste ningún diseño. Abrí el editor, recorré las cinco etapas y tocá «Finalizar diseño».").Parent = b
		else
			Ui.grid(cards, App.isPhone() and 1 or 3, nil, 10).Parent = b
		end
		footer(box, { closeBtn() })
		return
	end

	-- Configuración del lote.
	local d = design :: any
	local c = DesignCalc.computeDesign(g, d)
	local unit = Rules.lotUnitCost(g, c.unitCost) -- el mismo costo que cobra el servidor
	local qty, qtyWhy = validQty(st.qty)
	header(box, "Lote de «" .. d.name .. "» · línea " .. line)
	local b = body(box)
	local presets = {}
	for _, q in QTY_PRESETS do
		table.insert(presets, Ui.opt(Util.num(q), qty == q, function()
			st.qty, st.qtyText = q, tostring(q)
			App.renderDialog()
		end, { height = 34, name = "Cantidad_" .. q }))
	end
	local afford = unit > 0 and math.floor(g.money / unit) or 0
	table.insert(presets, Ui.opt("Máximo que alcanza (" .. Util.num(afford) .. ")", qty == afford and afford > 0, function()
		st.qty, st.qtyText = afford, tostring(afford)
		App.renderDialog()
	end, { height = 34, name = "CantidadMaxima", disabled = afford < 1, why = "No alcanza para una unidad" }))
	local qtyBox = Ui.input(st.qtyText or "", "Cantidad de unidades", function(text: string)
		st.qtyText = text
		st.qty = parseNumber(text)
		App.renderDialog()
	end, { name = "Cantidad", width = 200 })
	Ui.row({
		Ui.carThumb(d, 200, 112),
		Ui.grow(Ui.col({
			Ui.text(d.name, { size = 18, weight = W.bold }),
			Ui.text(tostring(d.generation or "") .. " · " .. (Catalog.base(d.baseId) and Catalog.base(d.baseId).name or ""), { size = Ui.S.xs, color = T.mut }),
			Ui.button("Cambiar de modelo", "q", function()
				st.step = "catalogo"
				App.renderDialog()
			end, { small = true, icon = "left", name = "VolverCatalogo" }),
		}, 4)),
	}, 14, { v = "T" }).Parent = b
	Ui.col({
		Ui.fl("Cantidad de unidades (cualquier número entero positivo)"),
		qtyBox,
		Ui.row(presets, 8, { wrap = true }),
		(qty == nil and (st.qtyText or "") ~= "") and Ui.text(qtyWhy or "", { size = Ui.S.xs, color = T.re2, name = "CantidadInvalida" }) or nil,
	}, 6).Parent = b
	local total = (qty or 0) * unit
	local days = Rules.daysFor(g, qty or 0)
	local speed = math.max(1, g.time.speed)
	local realSec = days * Catalog.CALENDAR.realSecondsPerDay / speed
	local Factory = App.screens.fabrica
	Ui.grid({
		(Ui.kv("Línea", "Línea " .. line, { sub = Util.num(g.derived.lineRate, 1) .. " autos/min real a 1×" })),
		(Ui.kv("Costo por unidad", Util.money(unit), { sub = "Con las bonificaciones de Producción" })),
		(Ui.kv("Costo total", qty and Util.money(total) or "—", { color = total > g.money and T.re2 or T.or_, sub = "Tenés " .. Util.money(g.money) .. " · se paga al confirmar", name = "CostoTotal" })),
		(Ui.kv("Duración estimada", qty and Factory.daysText(days) or "—", { sub = qty and ("≈ " .. Util.realTime(realSec) .. " reales a " .. speed .. "×") or "Escribí la cantidad", name = "Duracion" })),
	}, App.isPhone() and 2 or 4, nil, 10).Parent = b
	Ui.col({ Ui.lbl("Bonificaciones aplicadas"), Factory.bonusList(g) }, 6).Parent = b
	if qty and total > g.money then
		Ui.note("r", "No alcanza el dinero: el lote cuesta " .. Util.money(total) .. " y tenés " .. Util.money(g.money) .. ". Podés pagar hasta " .. Util.num(afford) .. " unidades.").Parent = b
	end
	local why = (qty == nil and (qtyWhy or "Escribí la cantidad")) or (total > g.money and "No alcanza el dinero") or nil
	local continue = Ui.button("Continuar", "p", function()
		local n = qty :: number
		App.openDialog("confirm", {
			title = "Confirmar producción",
			body = "Revisá el lote antes de empezar.",
			lines = {
				"Modelo|" .. d.name,
				"Cantidad de unidades|" .. Util.num(n),
				"Costo total|" .. Util.money(n * unit),
				"Duración estimada|" .. Factory.daysText(Rules.daysFor(g, n)),
				"Línea|Línea " .. line,
			},
			note = { "y", "Una vez iniciada la fabricación, este lote no podrá cancelarse. Cada modelo solo puede producir un lote." },
			okLabel = "Confirmar producción",
			cancel = "Volver",
			onOk = function()
				local r = App.request("createLot", { designId = d.id, qty = n, line = line }, { key = "lote" })
				if r.ok then
					App.ui.lotDraft = nil
					App.ui.lineSel = r.line or line
					App.closeAllDialogs()
					if App.ui.route ~= "fabrica" then
						App.go("fabrica")
					else
						App.forceRender()
					end
				end
			end,
		})
	end, { name = "ContinuarLote", icon = "right", iconAfter = true, disabled = why ~= nil, why = why })
	footer(box, { Ui.button("Cancelar", "default", App.closeDialog, { name = "CancelarLote" }), continue })
end

--[[ Reseñas de los críticos (al terminar un lote): aparecen de a una, con un segundo entre cada una, y se
	pueden saltar. Las notas vienen guardadas del servidor (se calcularon una sola vez). La primera vez, al
	terminar la secuencia (o al saltarla) el diálogo se cierra solo y lleva a Ventas con ese modelo elegido,
	donde se fija el precio. Mientras está abierto, la empresa queda en pausa (como cualquier diálogo). ]]
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
	App.ui.reviewDone = App.ui.reviewDone or {}
	local replay = App.ui.reviewDone[l.id] == true -- ya se vio completa: se muestra todo junto
	local shown = replay and #rv.scores or (App.ui.reviewShown[l.id] or 1)
	local lotId = l.id
	local function finish()
		App.ui.reviewShown[lotId] = #rv.scores
		App.ui.reviewDone[lotId] = true
		local top = App.topDialog()
		if top and top.kind == "reviews" and top.params.lotId == lotId then
			App.closeDialog()
		end
		-- Siguiente paso: el precio, en Ventas (si todavía no está a la venta).
		App.ui.salesSel = lotId
		if App.ui.route ~= "ventas" then
			App.go("ventas")
		else
			App.forceRender()
		end
	end
	header(box, "Reseñas de «" .. l.design.name .. "»")
	local b = body(box)
	Ui.text("Cuatro críticos especializados probaron el auto (" .. Util.num(l.produced) .. " unidades fabricadas).", { size = Ui.S.sm, color = T.mut }).Parent = b
	for i, sc in rv.scores do
		if i <= shown then
			local color = sc.score >= 7.5 and T.gr or (sc.score >= 5 and T.ye or T.re2)
			local card = Ui.card({
				Ui.row({
					Ui.grow(Ui.col({
						Ui.text(sc.name, { size = 16, weight = W.bold }),
						Ui.text(sc.outlet, { size = Ui.S.xs, color = T.mut }),
					}, 2)),
					Ui.inline(Util.num(sc.score, 1), { size = 28, weight = W.heavy, color = color, name = "Nota" }),
				}, 10),
				Ui.text("«" .. sc.text .. "»", { size = Ui.S.sm, color = T.tx2, lineHeight = 1.4 }),
			}, { gap = 6, bg = T.p2, name = "Critico_" .. sc.critic })
			card.Parent = b
			if i == shown and not replay and not Ui.reduceMotion then
				Ui.fadeIn(card)
			end
		end
	end
	local done = shown >= #rv.scores
	if done then
		local factor = Rules.reviewFactor(l)
		Ui.card({
			Ui.row({
				Ui.grow(Ui.col({
					Ui.text("Nota final (promedio de los cuatro)", { size = Ui.S.sm, color = T.mut }),
					Ui.text("Demanda ×" .. Util.num(factor, 2) .. (factor >= 1 and " por las buenas reseñas" or " por las reseñas"), { size = Ui.S.xs, color = factor >= 1 and T.gr or T.re2 }),
				}, 2)),
				Ui.inline(Util.num(rv.avg, 1) .. " / 10", { size = 30, weight = W.heavy, name = "NotaFinal" }),
			}, 10),
		}, { gap = 6, name = "NotaFinal" }).Parent = b
	end
	if not replay then
		-- El siguiente crítico aparece en un segundo; al terminar, la nota final queda un momento y se cierra.
		local token = {}
		dd.revealToken = token
		task.delay(done and 1.2 or 1, function()
			local top = App.topDialog()
			if dd.revealToken ~= token or not top or top.kind ~= "reviews" or top.params.lotId ~= lotId then
				return
			end
			if done then
				finish()
			else
				App.ui.reviewShown[lotId] = math.max(App.ui.reviewShown[lotId] or 1, shown + 1)
				App.renderDialog()
			end
		end)
		footer(box, { Ui.button("Saltar", "default", finish, { name = "SaltarResenas" }) })
	else
		footer(box, { closeBtn() })
	end
end

-- Modificar el precio de un lote (el mismo editor de precio que el panel de Ventas).
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
	App.screens.ventas.priceEditor(g, l, function()
		App.closeDialog()
	end).Parent = b
	footer(box, { Ui.button("Cerrar", "default", App.closeDialog) })
end

--[[ Confirmar investigación: muestra los costos definitivos (los mismos de Rules.researchCost que cobra el
	servidor), el desglose del recargo por adelanto, requisitos y recursos actuales. Abrirla no cobra nada; si
	algo cambia mientras está abierta (dinero, PI, cupo, estado) se vuelve a dibujar con los datos nuevos.
	params = { id } ]]
Dialogs.research = function(box: Frame, params: any, dd: any)
	local g = App.g
	local n = Catalog.researchNode(params.id)
	local R = App.screens.investigacion
	dd.sig = function(gg: any): string
		return table.concat({ tostring(math.floor(gg.rp)), tostring(gg.money), tostring(#gg.research.projects), tostring(Rules.researchState(gg, n)), tostring(Rules.year(gg)) }, "|")
	end
	if not n then
		info(box, "Investigación", { Ui.note("r", "Esa investigación no existe.") })
		return
	end
	local st, why, ahead = R.status(g, n)
	local pi, cost, days, detail = Rules.researchCost(g, n)
	local block = R.blockReason(g, n)
	header(box, "Investigar «" .. n.name .. "»")
	local b = body(box)
	Ui.row({ Ui.chip(R.levelLabel(n), "cn"), Ui.chip(Catalog.RESEARCH[n.category].label, "cb"), ahead > 0 and Ui.chip("Adelantada " .. ahead .. (ahead == 1 and " año" or " años"), "cy") or nil }, 6, { wrap = true }).Parent = b
	Ui.text(n.desc or ("Tecnología de " .. string.lower(Catalog.RESEARCH[n.category].label) .. " que aparece en " .. n.year .. "."), { size = Ui.S.sm, color = T.mut, lineHeight = 1.35 }).Parent = b
	Ui.text("<b>Beneficios:</b> " .. n.gain, { size = Ui.S.sm, lineHeight = 1.35, name = "Beneficios" }).Parent = b
	local function withBase(value: string, base: string, pct: number): string
		return pct > 0 and (value .. " <font size=\"11\" color=\"#F7C95C\">(base " .. base .. " +" .. Util.round(pct * 100) .. " %)</font>") or value
	end
	local effective = Rules.researchEffectiveDays(g, days)
	Ui.grid({
		(Ui.kv("Costo", withBase(Util.money(cost), Util.money(detail.base.money), detail.penalty.money), { color = cost > g.money and T.re2 or T.or_, name = "CostoInvestigacion" })),
		(Ui.kv("Puntos de investigación", withBase(Util.num(pi) .. " PI", Util.num(detail.base.pi), detail.penalty.pi), { color = pi > g.rp and T.re2 or T.vi2, name = "PIInvestigacion" })),
		(Ui.kv("Duración", withBase(Util.num(days) .. " días", Util.num(detail.base.days), detail.penalty.days), { sub = math.abs(effective - days) >= 0.5 and ("≈ " .. Util.num(math.ceil(effective)) .. " días con el personal de Investigación") or "días del juego", name = "DuracionInvestigacion" })),
		(Ui.kv("Año de la tecnología", tostring(n.year), { sub = "Año actual " .. Rules.year(g) })),
	}, App.isPhone() and 2 or 4, nil, 10).Parent = b
	if #n.req > 0 then
		local names = {}
		for _, r in n.req do
			local rn = Catalog.researchNode(r)
			table.insert(names, (Rules.has(g, r) and "✓ " or "✕ ") .. (rn and rn.name or r))
		end
		Ui.text("<b>Requisitos:</b> " .. table.concat(names, " · "), { size = Ui.S.sm, lineHeight = 1.35 }).Parent = b
	else
		Ui.text("<b>Requisitos:</b> ninguno", { size = Ui.S.sm }).Parent = b
	end
	if ahead > 0 then
		Ui.note("y", "Adelanto de " .. ahead .. (ahead == 1 and " año" or " años") .. " (aparece en " .. n.year .. "): +" .. Util.round(detail.penalty.money * 100) .. " % de dinero, +" .. Util.round(detail.penalty.pi * 100) .. " % de PI y +" .. Util.round(detail.penalty.days * 100) .. " % de duración, ya incluidos arriba.").Parent = b
	end
	Ui.grid({
		(Ui.kv("Tu dinero", Util.money(g.money), { sub = block == nil and ("después: " .. Util.money(g.money - cost)) or nil })),
		(Ui.kv("Tus PI", Util.num(math.floor(g.rp)) .. " PI", { sub = block == nil and ("después: " .. Util.num(math.floor(g.rp - pi)) .. " PI") or nil })),
		(Ui.kv("Investigaciones en curso", #g.research.projects .. " de " .. Catalog.RESEARCH_RULES.maxParallel)),
	}, 3, nil, 10).Parent = b
	Ui.note("y", "Una vez iniciada, esta investigación no podrá cancelarse. Los recursos se descontarán al confirmar.").Parent = b
	if block then
		Ui.note("r", (st == "bloqueada" and why) or block, nil, "warn").Parent = b
	end
	local ok
	ok = Ui.button("Confirmar investigación", "p", function()
		-- El servidor vuelve a validar todo (recursos, requisitos, año, que no esté hecha ni en curso) y cobra una vez.
		local r = App.request("startResearch", { id = n.id }, { button = ok, key = "investigar:" .. n.id })
		if r.ok then
			App.closeDialog()
		else
			App.renderDialog()
		end
	end, { name = "ConfirmarInvestigacion", icon = "flask", disabled = block ~= nil, why = block })
	footer(box, { Ui.button("Volver", "default", App.closeDialog, { name = "VolverInvestigacion" }), ok })
end

-- No se pudo guardar el borrador del editor: el editor no se cierra solo; se puede reintentar sin perder nada.
Dialogs.unsaved = function(box: Frame, params: any)
	header(box, "No se pudo guardar el borrador", false)
	local b = body(box)
	Ui.text("Los últimos cambios de «" .. tostring(params.name) .. "» todavía no llegaron al servidor" .. (params.reason and (" (" .. tostring(params.reason) .. ")") or "") .. ". Siguen en el editor: podés reintentar o seguir editando.", { size = 15, lineHeight = 1.5, name = "MotivoGuardado" }).Parent = b
	Ui.note("y", "Si salís igual, los cambios que no se guardaron pueden perderse.").Parent = b
	local retry
	retry = Ui.button("Reintentar", "p", function()
		Ui.setBusy(retry, true)
		params.onRetry()
		if retry.Parent then
			Ui.setBusy(retry, false)
		end
	end, { name = "ReintentarGuardado", icon = "reset" })
	footer(box, {
		Ui.button("Seguir editando", "default", App.closeDialog, { name = "SeguirEditando" }),
		Ui.button("Salir igual", "d", params.onLeave, { name = "SalirIgual" }),
		retry,
	})
end

Dialogs.prevModels = function(box: Frame)
	local g = App.g
	local Ed = App.screens.editor
	header(box, "Borradores, modelos y plantillas")
	local b = body(box)
	Ui.button("Empezar un proyecto nuevo", "p", function()
		App.closeDialog()
		Ed.newProject()
	end, { small = true, icon = "plus", name = "NuevoProyecto" }).Parent = b
	-- Borradores: se guardan solos con la empresa; no se fabrican hasta finalizarlos.
	local drafts = Ed.drafts()
	Ui.lbl("Borradores (" .. #drafts .. " de " .. Catalog.RULES.maxDrafts .. ")").Parent = b
	if #drafts == 0 then
		Ui.text("No hay borradores guardados.", { size = Ui.S.sm, color = T.mut }).Parent = b
	end
	local open = App.ui.editor and App.ui.editor.draftId
	for _, dr in drafts do
		local base = Catalog.base(dr.spec.baseId)
		local del
		del = Ui.button("", "q", function()
			App.openDialog("confirm", {
				title = "¿Eliminar el borrador «" .. tostring(dr.spec.name) .. "»?",
				body = "Se borra solo este borrador. Los modelos terminados no se tocan.",
				okLabel = "Eliminar borrador",
				danger = true,
				onOk = function()
					Ed.deleteDraft(dr.id, del)
					App.renderDialog()
				end,
			})
		end, { small = true, icon = "trash", fg = T.re2, name = "EliminarBorrador_" .. dr.id })
		Ui.card({
			Ui.grow(Ui.col({
				Ui.text(tostring(dr.spec.name) .. (open == dr.id and " <font color=\"#8DB8FF\">· abierto</font>" or ""), { size = Ui.S.base, weight = W.bold }),
				Ui.text((base and base.name or "—") .. " · etapa " .. dr.step .. " de " .. #Ed.STEPS .. " (" .. Ed.STEPS[dr.step][2] .. ")" .. (dr.newGenOf and " · nueva generación" or ""), { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			Ui.button(open == dr.id and "Seguir" or "Continuar", "p", function()
				App.closeDialog()
				App.go("editor", { draftId = dr.id })
			end, { small = true, name = "ContinuarBorrador_" .. dr.id }),
			del,
		}, { dir = "H", v = "C", gap = 10, name = "Borrador_" .. dr.id }).Parent = b
	end
	Ui.lbl("Modelos terminados y plantillas").Parent = b
	if #g.designs == 0 then
		Ui.empty(nil, "Todavía no finalizaste diseños.").Parent = b
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
