--!strict
-- Diálogos (.dlg de la V3). Cada constructor recibe (caja, parámetros, registro del diálogo).
-- Un diálogo puede definir d.sig(g): si cambia, se reconstruye (por ejemplo, si el cliente se va).

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

local Dialogs = {}

local function header(box: Frame, title: string)
	Ui.row({
		Ui.grow(Ui.text(title, { size = Ui.S.h2, weight = W.bold })),
		Ui.button("", "default", function()
			App.closeDialog()
		end, { small = true, width = 36, icon = "x", name = "CerrarDialogo" }),
	}, 12, { Pad = { 16, 18, 6, 18 }, Parent = box })
end

local function body(box: Frame): ScrollingFrame
	local s = Ui.scroll({}, { name = "CuerpoDialogo", gap = 12, pad = { 10, 18, 16, 18 } })
	s.Size = UDim2.new(1, 0, 0, 0)
	s.AutomaticSize = Enum.AutomaticSize.Y
	s.Parent = box
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(math.huge, App.dialogMaxBody or 500)
	limit.Parent = s
	return s
end

local function footer(box: Frame, buttons: { Instance? })
	Ui.row(buttons, 10, { BackgroundColor3 = Color3.fromHex("#0D0F14"), BackgroundTransparency = 0, Pad = { 12, 18, 16, 18 }, wrap = true, Parent = box })
end

local function findUnit(g: any, id: any): any
	for _, u in g.units do
		if u.id == id then
			return u
		end
	end
	return nil
end

-- Nueva orden de producción ----------------------------------------------------------------------
Dialogs.order = function(box: Frame, params: any)
	local g = App.g
	local designs = {}
	for _, d in g.designs do
		if not d.template then
			table.insert(designs, d)
		end
	end
	header(box, "Nueva orden de producción")
	if #designs == 0 then
		Ui.note("b", "Primero guardá un diseño en el editor.").Parent = body(box)
		footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
		return
	end
	local st = App.ui.orderDraft
	if not st or (params.designId and st.designId ~= params.designId and not st.touched) then
		st = { designId = params.designId or g.production.lastDesign or designs[#designs].id, qty = 1, line = nil, priority = "media" }
		App.ui.orderDraft = st
	end
	local d = nil
	for _, x in designs do
		if x.id == st.designId then
			d = x
		end
	end
	if not d then
		d = designs[#designs]
		st.designId = d.id
	end
	local c = DesignCalc.computeDesign(g, d)
	local qty = st.qty
	local b = body(box)
	Ui.lbl("Modelo (diseño guardado)").Parent = b
	local opts = {}
	for _, x in designs do
		table.insert(opts, Ui.opt(x.name .. " v" .. x.version, x.id == d.id, function()
			st.designId = x.id
			st.touched = true
			App.renderDialog()
		end))
	end
	Ui.row(opts, 8, { wrap = true }).Parent = b
	Ui.lbl("Cantidad (1–" .. Catalog.RULES.maxQty .. ")").Parent = b
	local function setQty(n: number)
		st.qty = math.clamp(math.floor(n), 1, Catalog.RULES.maxQty)
		st.touched = true
		App.renderDialog()
	end
	local qtyBox = Ui.input(tostring(qty), "1", function(text: string)
		local n = tonumber(text)
		if n then
			setQty(n)
		else
			App.renderDialog()
		end
	end, { width = 80, name = "Cantidad" })
	Ui.row({
		Ui.button("", "default", function()
			setQty(qty - 1)
		end, { width = 44, icon = "minus" }),
		qtyBox,
		Ui.button("", "default", function()
			setQty(qty + 1)
		end, { width = 44, icon = "plus" }),
		Ui.opt("1", qty == 1, function()
			setQty(1)
		end, { width = 44 }),
		Ui.opt("3", qty == 3, function()
			setQty(3)
		end, { width = 44 }),
		Ui.opt("6", qty == 6, function()
			setQty(6)
		end, { width = 44 }),
	}, 8, { wrap = true }).Parent = b
	local lines = g.derived.caps.lines
	if lines > 1 then
		local lineOpts = {}
		for l = 1, lines do
			local n = 0
			for _, o in g.production.orders do
				if o.line == l then
					n += 1
				end
			end
			table.insert(lineOpts, Ui.opt("Línea " .. l .. " · " .. n .. " órdenes", (st.line or 1) == l, function()
				st.line = l
				App.renderDialog()
			end))
		end
		Ui.lbl("Línea").Parent = b
		Ui.row(lineOpts, 6, { wrap = true }).Parent = b
	end
	local prios = {}
	for _, p in { { "alta", "Alta" }, { "media", "Media" }, { "baja", "Baja" } } do
		table.insert(prios, Ui.opt(p[2], st.priority == p[1], function()
			st.priority = p[1]
			App.renderDialog()
		end, { width = 90 }))
	end
	Ui.lbl("Prioridad").Parent = b
	Ui.row(prios, 6).Parent = b

	local factor = Rules.unitCostFactor(g)
	local cost = Util.round(c.unitCost * factor)
	local minutes = c.build / math.max(0.01, g.derived.lineSpeed)
	local secs = g.time.speed > 0 and math.ceil(minutes / (Catalog.RULES.minutesPerRealSecond * g.time.speed)) or nil
	local free = g.derived.caps.warehouse - g.derived.warehouseUsed
	Ui.grid({
		(Ui.kv("Costo por unidad" .. (factor > 1 and " (acelerada)" or ""), Util.money(cost), { sub = "Se cobra al empezar cada unidad" })),
		(Ui.kv("Costo total estimado", Util.money(cost * qty), { color = T.or_ })),
		(Ui.kv("Tiempo por unidad", Util.gameDuration(minutes) .. " de juego", { sub = secs and ("≈ " .. secs .. " s reales a la velocidad actual") or "Simulación en pausa" })),
		(Ui.kv("Lugar libre en el almacén", tostring(free), { color = free < qty and T.ye or T.tx, sub = "Incluye lo reservado por unidades en fabricación" })),
	}, App.isPhone() and 1 or 2, 80).Parent = b
	local matLines: { Instance? } = {}
	local short = false
	for _, k in Util.keys(c.mats) do
		local need = c.mats[k] * qty
		local have = g.materials[k] or 0
		if have < need then
			short = true
		end
		table.insert(matLines, Ui.line(Catalog.matLabel(k), "necesita " .. need .. " · tenés " .. have, { color = have < need and T.ye or T.gr, weight = W.semi }))
	end
	Ui.card(matLines, { gap = 0, pad = { 4, 12 } }).Parent = b
	Ui.note("b", "La orden guarda una copia de «" .. d.name .. "» v" .. d.version .. ": aunque después edites o elimines el proyecto, estas unidades se fabrican con esta versión y este costo unitario.").Parent = b
	if short then
		Ui.note("y", "Los materiales no alcanzan para toda la orden. Se fabricará hasta donde alcancen y la orden se detendrá mostrando qué falta.").Parent = b
	end
	if free < qty then
		Ui.note("y", "No hay lugar para todas las unidades: la orden se detendrá cuando el almacén se llene.").Parent = b
	end
	if g.money < cost then
		Ui.note("r", "No alcanza el dinero para empezar la primera unidad.").Parent = b
	end
	local create
	create = Ui.button("Crear orden", "p", function()
		local r = App.request("createOrder", { designId = d.id, qty = st.qty, line = st.line, priority = st.priority }, { button = create })
		if r.ok then
			App.ui.orderDraft = nil
			App.closeAllDialogs()
			if App.ui.route ~= "fabrica" and App.ui.route ~= "editor" then
				App.go("fabrica")
			end
		end
	end, { name = "CrearOrden" })
	footer(box, { Ui.spacer(), Ui.button("Cancelar", "default", App.closeDialog), create })
end

-- Negociación: la probabilidad mostrada la calcula el servidor para ese monto y ese estado. ----------
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
	if params.lastMsg then
		Ui.note(params.lastKind or "y", params.lastMsg).Parent = b
	end
	if not c or c.state ~= "oferta" or not u or u.status ~= "salon" then
		Ui.note("y", (c and c.state == "compró") and "La venta ya se realizó." or "El cliente o el auto ya no están disponibles. No hay nada para negociar.").Parent = b
		footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
		return
	end
	local st = App.ui.counterDraft
	if not st or st.customerId ~= c.id then
		st = { customerId = c.id, amount = Util.round(((c.offer + Rules.finalPrice(u)) / 2) / 100) * 100, quote = nil }
		App.ui.counterDraft = st
	end
	if st.amount <= c.offer then
		st.amount = Util.round((c.offer + 500) / 100) * 100
	end
	-- La consulta anterior deja de valer si cambió el monto o la negociación (rev).
	local q = st.quote
	local valid = q and q.amount == st.amount and q.rev == c.rev
	local function requote()
		local r = App.request("quoteCounter", { customerId = c.id, amount = st.amount }, { key = c.id })
		if r.ok then
			st.quote = { amount = r.amount, chance = r.chance, rev = r.rev, offer = r.offer }
			st.amount = r.amount
			st.failed = nil
		elseif not r.pending then
			-- No se reintenta en bucle: se vuelve a consultar cuando cambie el monto o la negociación.
			st.quote = nil
			st.failed = tostring(st.amount) .. ":" .. tostring(c.rev)
		end
		if App.topDialog() == d then
			App.renderDialog()
		end
	end
	if not valid and not st.quoting and st.failed ~= (tostring(st.amount) .. ":" .. tostring(c.rev)) then
		st.quoting = true
		task.spawn(function()
			requote()
			st.quoting = false
		end)
	end

	Ui.grid({
		Ui.card({
			Ui.lbl("Auto"),
			Ui.row({ Ui.carThumb(u.spec, 64, 38), Ui.grow(Ui.text(u.name .. "  <font color=\"#7D8493\">" .. u.serial .. "</font>", { size = 14, weight = W.bold })) }, 8),
			Ui.text("Lista " .. Util.money(u.price) .. " · final " .. Util.money(Rules.finalPrice(u)) .. " · costo " .. Util.money(u.cost), { size = Ui.S.xs, color = T.mut }),
		}, { gap = 6 }),
		Ui.card({
			Ui.lbl("Cliente"),
			Ui.text(c.name, { size = 14, weight = W.bold }),
			Ui.text("Busca " .. string.lower(Catalog.TYPES[c.wants] or c.wants) .. " · valora " .. (Catalog.PREF_LABEL[c.pref] or c.pref) .. " · interés " .. c.interest .. "% · rondas " .. c.rounds, { size = Ui.S.xs, color = T.mut }),
			Ui.chip("Su oferta: " .. Util.money(c.offer), "cb"),
		}, { gap = 6 }),
	}, App.isPhone() and 1 or 2, 116).Parent = b

	local chance = valid and q.chance or nil
	local chanceText = chance and (chance .. " %") or (valid and "—" or (st.failed and "No disponible" or "Calculando…"))
	local chanceColor = chance and (chance >= 60 and T.gr or (chance >= 30 and T.ye or T.re2)) or T.mut
	local m = st.amount - u.cost
	local amountBox = Ui.input(tostring(st.amount), "Monto", function(text: string)
		local n = tonumber((string.gsub(text, "[^%d]", "")))
		if n then
			st.amount = Util.round(n / 100) * 100
		end
		App.renderDialog()
	end, { width = 150, name = "MontoContraoferta" })
	Ui.lbl("Tu contraoferta (se redondea a $100)").Parent = b
	Ui.row({
		Ui.button("−500", "default", function()
			st.amount = math.max(Util.round((c.offer + 100) / 100) * 100, st.amount - 500)
			App.renderDialog()
		end, { small = true }),
		amountBox,
		Ui.button("+500", "default", function()
			st.amount += 500
			App.renderDialog()
		end, { small = true }),
	}, 8).Parent = b
	Ui.grid({
		(Ui.kv("Probabilidad de que acepte", chanceText, { color = chanceColor, sub = "Calculada por el servidor para este monto" })),
		(Ui.kv("Margen si acepta", Util.money(m), { color = m >= 0 and T.gr or T.re2 })),
	}, 2, 76).Parent = b
	Ui.text("Si el monto supera su presupuesto (que no conocés), la probabilidad es 0 %. Cada rechazo baja la probabilidad y le resta paciencia. Si cambia su oferta, la probabilidad se recalcula.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.25 }).Parent = b
	local accept, counter
	accept = Ui.button("Aceptar " .. Util.money(c.offer), "g", function()
		local r = App.request("acceptOffer", { customerId = c.id }, { button = accept })
		if r.ok then
			App.closeDialog()
		end
	end, { name = "AceptarOferta" })
	counter = Ui.button("Contraofertar " .. Util.money(st.amount), "p", function()
		if not (st.quote and st.quote.amount == st.amount) then
			App.toast("aviso", "Esperá a que se calcule la probabilidad.")
			return
		end
		local r = App.request("counterOffer", { customerId = c.id, amount = st.quote.amount, rev = st.quote.rev }, { button = counter })
		st.quote = nil
		if r.ok and r.sold ~= false then
			App.closeDialog()
		elseif r.ok then
			d.params.lastMsg = r.msg
			d.params.lastKind = r.left and "y" or "b"
			App.renderDialog()
		else
			App.renderDialog()
		end
	end, { name = "Contraofertar", disabled = chance == nil, why = "Esperá a que se calcule la probabilidad" })
	footer(box, {
		Ui.button("Rechazar y despedir", "q", function()
			App.request("rejectCustomer", { customerId = c.id })
			App.closeDialog()
		end),
		Ui.spacer(),
		accept,
		counter,
	})
end

-- Confirmación genérica --------------------------------------------------------------------------
Dialogs.confirm = function(box: Frame, params: any)
	header(box, params.title or "¿Confirmar?")
	local b = body(box)
	Ui.text(params.body or "", { size = 14, color = T.tx2, lineHeight = 1.3 }).Parent = b
	footer(box, {
		Ui.spacer(),
		Ui.button(params.cancel or "Volver", "default", App.closeDialog),
		Ui.button(params.okLabel or "Confirmar", params.danger and "d" or "p", function()
			App.closeDialog()
			if params.onOk then
				params.onOk()
			end
		end, { name = "Confirmar" }),
	})
end

-- Cambios sin guardar en el editor: guardar, descartar o seguir editando.
Dialogs.unsaved = function(box: Frame, params: any)
	header(box, params.title or "Cambios sin guardar")
	local b = body(box)
	Ui.text("«" .. tostring(params.name) .. "» tiene cambios sin guardar. ¿Qué querés hacer?", { size = 14, color = T.tx2 }).Parent = b
	Ui.text("Si guardar falla (por ejemplo, por fondos), el borrador se conserva y seguís editando.", { size = Ui.S.xs, color = T.mut }).Parent = b
	local save
	save = Ui.button("Guardar", "p", function()
		params.onSave(save)
	end, { name = "GuardarCambios" })
	footer(box, {
		Ui.button("Seguir editando", "default", App.closeDialog, { name = "SeguirEditando" }),
		Ui.spacer(),
		Ui.button("Descartar", "d", params.onDiscard, { name = "Descartar" }),
		save,
	})
end

-- Eliminar una empresa: hay que escribir su nombre (o BORRAR si está dañada).
Dialogs.deleteCompany = function(box: Frame, params: any)
	header(box, "¿Eliminar " .. tostring(params.name) .. "?")
	local b = body(box)
	Ui.text("Se borra solo la ranura " .. params.slot .. (params.level and (" (nivel " .. params.level .. ", " .. Util.money(params.money) .. ")") or "") .. ". Las otras empresas no se tocan. No se puede deshacer.", { size = 14, color = T.tx2 }).Parent = b
	Ui.text("Para confirmar, escribí «" .. params.expected .. "»:", { size = Ui.S.sm, color = T.mut }).Parent = b
	local typed = params.typed or ""
	local box2 = Ui.input(typed, params.expected, function(text: string)
		params.typed = text
	end, { onChange = function(text: string)
		params.typed = text
	end, name = "ConfirmarNombre" })
	box2.Parent = b
	local del
	del = Ui.button("Eliminar definitivamente", "d", function()
		local r = App.request("deleteCompany", { slot = params.slot, confirm = params.typed or "" }, { button = del })
		if r.ok then
			App.closeDialog()
		end
	end, { name = "EliminarEmpresa" })
	footer(box, { Ui.spacer(), Ui.button("Cancelar", "default", App.closeDialog), del })
end

-- Detalle de una unidad: vista reconocible, configuración, versión y lo que se cobró.
Dialogs.unitDetail = function(box: Frame, params: any, d: any)
	local g = App.g
	local u = findUnit(g, params.unitId)
	d.sig = function(gg: any): string
		local x = findUnit(gg, params.unitId)
		return x and (x.status .. x.price .. x.discount) or "gone"
	end
	header(box, u and (u.name .. " · " .. u.serial) or "Unidad")
	local b = body(box)
	if not u then
		Ui.note("y", "La unidad ya no existe (se recicló o se descartó del historial).").Parent = b
		footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
		return
	end
	local Inventory = App.screens.autos
	Ui.carThumb(u.spec, math.min(700, App.vw - 60), 220).Parent = b
	Ui.row({
		Ui.chip(Inventory.STATUS_LABEL[u.status] or u.status, Inventory.STATUS_CHIP[u.status]),
		Ui.chip(Catalog.TYPES[u.type], "cn"),
		Ui.chip("Calidad " .. u.quality, "cv"),
		u.designVersion and Ui.chip("Diseño v" .. u.designVersion, "cb") or Ui.chip("Comprada en el mercado", "cy"),
	}, 6, { wrap = true }).Parent = b
	local fp = Rules.finalPrice(u)
	Ui.grid({
		(Ui.kv("Costo registrado", Util.money(u.cost), { sub = u.charged and u.charged.boost and ("Incluye recargo ×" .. Util.num(u.charged.factor, 2)) or "Lo cobrado al fabricarla" })),
		(Ui.kv(u.status == "vendido" and "Vendida en" or "Precio final", Util.money(u.status == "vendido" and (u.soldPrice or 0) or fp))),
		(Ui.kv("Margen", Util.money((u.status == "vendido" and (u.soldPrice or 0) or fp) - u.cost), { color = ((u.status == "vendido" and (u.soldPrice or 0) or fp) - u.cost) >= 0 and T.gr or T.re2 })),
		(Ui.kv("Precio de lista", Util.money(u.price) .. (u.discount > 0 and (" (−" .. u.discount .. " %)") or ""))),
	}, App.isPhone() and 2 or 4, 76).Parent = b
	local statRows = {}
	for _, s in Catalog.STAT_DEFS do
		local k = s[1]
		local v = u.stats[k]
		table.insert(statRows, Ui.line(s[2], (k == "accel" or k == "consumption") and Util.num(v, 1) or Util.num(v), { leftColor = T.mut, size = 12 }))
	end
	Ui.card({ Ui.lbl("Estadísticas (fijadas al fabricarla)"), Ui.grid(statRows, App.isPhone() and 1 or 2, 24, 4) }, { gap = 6 }).Parent = b
	local spec = u.spec
	local cfg = {}
	for _, cat in Catalog.CATS do
		local p = Catalog.part(cat[1], spec.parts[cat[1]])
		table.insert(cfg, Ui.line(cat[2], p and p.name or "—", { leftColor = T.mut, weight = W.med, size = 12 }))
	end
	Ui.card({
		Ui.lbl("Configuración"),
		Ui.text("Base " .. Catalog.base(spec.baseId).name .. " · pintura " .. spec.paint.primary .. " / " .. spec.paint.secondary .. " " .. string.lower(spec.paint.finish) .. " · llantas " .. spec.wheels.size .. "″ · " .. (spec.spoiler and "con alerón" or "sin alerón") .. " · matrícula " .. tostring(spec.body.plate), { size = Ui.S.xs, color = T.tx2 }),
		Ui.grid(cfg, App.isPhone() and 1 or 2, 24, 4),
	}, { gap = 6 }).Parent = b
	local actions = Inventory.unitActions(g, u)
	footer(box, { table.unpack(actions) })
end

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
		Ui.note("y", "La venta ya no está en el historial con detalle.").Parent = b
		footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
		return
	end
	Ui.card({
		Ui.line("Unidad", s.serial .. " · " .. s.name .. " v" .. tostring(s.designVersion or "—")),
		Ui.line("Día y hora", "Día " .. (s.day + 1) .. " " .. (s.at or "")),
		Ui.line("Canal", s.channel),
		Ui.line("Comprador", tostring(s.buyer)),
		Ui.hr(),
		Ui.line("Precio de lista", s.listPrice and Util.money(s.listPrice) or "—", { leftColor = T.mut }),
		Ui.line("Precio final de lista (con descuento)", s.finalListPrice and Util.money(s.finalListPrice) or "—", { leftColor = T.mut }),
		Ui.line("Oferta del cliente", s.offer and Util.money(s.offer) or "—", { leftColor = T.mut }),
		Ui.line("Ingreso final", Util.money(s.price), { color = T.gr }),
		Ui.line("Comisión", Util.money(-(s.fee or 0)), { leftColor = T.mut, color = T.or_ }),
		Ui.line("Costo registrado", Util.money(-s.cost), { leftColor = T.mut, color = T.or_ }),
		Ui.hr(),
		Ui.line("Margen", Util.money(s.margin), { color = s.margin >= 0 and T.gr or T.re2, leftWeight = W.bold }),
	}, { gap = 0, pad = { 6, 14 } }).Parent = b
	footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
end

Dialogs.wholesale = function(box: Frame, params: any)
	local g = App.g
	local u = findUnit(g, params.unitId)
	header(box, "Vender al mayorista")
	local b = body(box)
	if not u or (u.status ~= "almacen" and u.status ~= "salon") then
		Ui.note("y", "La unidad ya no está disponible.").Parent = b
		footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
		return
	end
	local p = Rules.wholesale(u)
	Ui.text("Venta inmediata de " .. u.name .. " (" .. u.serial .. ") por " .. Util.money(p) .. " (costo " .. Util.money(u.cost) .. " × " .. Util.num(Catalog.RULES.wholesaleFactor, 2) .. "). Margen: " .. Util.money(p - u.cost) .. ". Frente al precio final de lista (" .. Util.money(Rules.finalPrice(u)) .. ") dejás de ganar " .. Util.money(math.max(0, Rules.finalPrice(u) - p)) .. ".", { size = 14, color = T.tx2 }).Parent = b
	local sell
	sell = Ui.button("Vender · " .. Util.money(p), "p", function()
		local r = App.request("wholesale", { unitId = u.id }, { button = sell })
		if r.ok then
			App.closeAllDialogs()
		end
	end)
	footer(box, { Ui.spacer(), Ui.button("Cancelar", "default", App.closeDialog), sell })
end

-- Mercado ------------------------------------------------------------------------------------------
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
	header(box, l and l.name or "Publicación")
	local b = body(box)
	if not l then
		Ui.note("y", "Esta publicación ya no existe (el mercado se renovó).").Parent = b
		footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
		return
	end
	local auction = l.mode == "subasta"
	local bidMin = auction and (l.bid + 100) or 0
	params.bid = math.max(bidMin, params.bid or bidMin)
	local t = Market.total(l, auction and params.bid or l.price)
	Ui.row({ Ui.chip(l.rarity, "cn"), Ui.chip("Vendedor ficticio: " .. l.seller, "cn"), Ui.chip(l.cond, "cn"), auction and Ui.chip("Subasta · " .. l.bids .. " ofertas", "cy") or nil }, 6, { wrap = true }).Parent = b
	if l.kind == "vehiculo" then
		Ui.carThumb(l.spec, math.min(520, App.vw - 60), 180).Parent = b
		local c = DesignCalc.computeDesign(nil, l.spec)
		local rows = {}
		for i, s in Catalog.STAT_DEFS do
			if i <= 8 then
				table.insert(rows, Ui.line(s[2], (s[1] == "accel" or s[1] == "consumption") and Util.num(c[s[1]], 1) or Util.num(c[s[1]]), { leftColor = T.mut, size = 12 }))
			end
		end
		Ui.card({ Ui.grid(rows, 2, 24, 4) }, { pad = { 6, 12 } }).Parent = b
		Ui.text("Entra a tu almacén como unidad comprada (sin diseño propio). Ocupa un lugar del almacén.", { size = Ui.S.xs, color = T.mut }).Parent = b
	elseif l.kind == "pieza" then
		local p = Catalog.part(l.part.cat, l.part.id)
		Ui.text(Catalog.catLabel(p.cat) .. " · " .. p.desc .. ". Entra a Mis autos › Piezas y, al instalarla en un diseño, cubre su costo de desarrollo (" .. Util.money(p.proto) .. ").", { size = Ui.S.sm, color = T.tx2 }).Parent = b
		if p.research and not Rules.has(g, p.research) then
			Ui.note("y", "Podés comprarla, pero para instalarla necesitás investigar «" .. Catalog.researchNode(p.research).name .. "».").Parent = b
		end
	elseif l.kind == "diseno" then
		Ui.text("Plano listo basado en " .. Catalog.base(l.baseId).name .. ". Se agrega como plantilla y la licencia del modelo queda pagada.", { size = Ui.S.sm, color = T.tx2 }).Parent = b
	else
		Ui.text(l.qty .. " unidades de " .. string.lower(Catalog.matLabel(l.mat)) .. ". Depósito: " .. g.derived.matsUsed .. "/" .. g.derived.caps.mats .. ".", { size = Ui.S.sm, color = T.tx2 }).Parent = b
	end
	if auction then
		local bidBox = Ui.input(tostring(params.bid), "Oferta", function(text: string)
			local n = tonumber((string.gsub(text, "[^%d]", "")))
			if n then
				params.bid = Util.round(n / 100) * 100
			end
			App.renderDialog()
		end, { width = 160 })
		Ui.row({ Ui.text("Tu oferta (mínimo " .. Util.money(bidMin) .. ")", { size = Ui.S.sm, width = 200 }), bidBox }, 8).Parent = b
		Ui.text("No se cobra ahora. Si al terminar sos la oferta más alta, se cobra el total y el auto entra al almacén.", { size = Ui.S.xs, color = T.mut }).Parent = b
	end
	Ui.card({
		Ui.line("Precio" .. (auction and " ofertado" or ""), Util.money(t.price)),
		Ui.line("Impuesto (" .. Util.round(Catalog.RULES.taxRate * 100) .. " %)", Util.money(t.tax)),
		Ui.line("Comisión del mercado (" .. Util.round(Catalog.RULES.feeRate * 100) .. " %)", Util.money(t.fee)),
		Ui.hr(),
		Ui.line("Total", Util.money(t.total), { leftWeight = W.bold }),
	}, { gap = 0, pad = { 4, 12 } }).Parent = b
	local act
	if auction then
		act = Ui.button("Ofertar " .. Util.money(params.bid), "p", function()
			App.request("marketBid", { listingId = l.id, amount = params.bid }, { button = act })
		end, { disabled = l.status ~= "activa", why = "La subasta terminó" })
	else
		act = Ui.button("Comprar · " .. Util.money(t.total), "p", function()
			local r = App.request("marketBuy", { listingId = l.id }, { button = act })
			if r.ok then
				App.closeDialog()
			end
		end, { disabled = l.status ~= "activa", why = "La publicación ya no está disponible", name = "Comprar" })
	end
	footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog), act })
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
		Ui.note("y", "Necesitás una unidad terminada en el almacén.").Parent = b
		footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
		return
	end
	local u = findUnit(g, params.unitId)
	if not u or u.status ~= "almacen" then
		u = avail[1]
		params.unitId = u.id
	end
	params.mode = params.mode or "directa"
	params.hours = params.hours or 6
	params.price = params.price or u.stats.price
	local unitOpts = {}
	for _, x in avail do
		table.insert(unitOpts, Ui.opt(x.name .. " · " .. x.serial, x.id == u.id, function()
			params.unitId = x.id
			params.price = x.stats.price
			App.renderDialog()
		end))
	end
	Ui.lbl("Unidad").Parent = b
	Ui.row(unitOpts, 6, { wrap = true }).Parent = b
	Ui.lbl("Modalidad").Parent = b
	Ui.row({
		Ui.opt("Precio fijo", params.mode == "directa", function()
			params.mode = "directa"
			App.renderDialog()
		end, { width = 120 }),
		Ui.opt("Subasta", params.mode == "subasta", function()
			params.mode = "subasta"
			App.renderDialog()
		end, { width = 120 }),
	}, 6).Parent = b
	local priceBox = Ui.input(tostring(params.price), "Precio", function(text: string)
		local n = tonumber((string.gsub(text, "[^%d]", "")))
		if n then
			params.price = Util.round(n / 100) * 100
		end
		App.renderDialog()
	end, { width = 160 })
	Ui.row({ Ui.text((params.mode == "subasta" and "Precio de referencia" or "Precio") .. " (recomendado " .. Util.money(u.stats.price) .. ")", { size = Ui.S.sm, width = 260 }), priceBox }, 8, { wrap = true }).Parent = b
	if params.mode == "subasta" then
		local hours = {}
		for _, h in { 3, 6, 12 } do
			table.insert(hours, Ui.opt(h .. " h de juego", params.hours == h, function()
				params.hours = h
				App.renderDialog()
			end, { width = 120 }))
		end
		Ui.row(hours, 6).Parent = b
	end
	local fee = Util.round(params.price * Catalog.RULES.feeRate)
	local ok = params.price >= 100 and params.price <= u.stats.price * 3
	Ui.card({
		Ui.line("Costo registrado", Util.money(u.cost)),
		Ui.line("Comisión al vender (" .. Util.round(Catalog.RULES.feeRate * 100) .. " %)", Util.money(-fee), { color = T.or_ }),
		Ui.hr(),
		Ui.line("Margen estimado", Util.money(params.price - fee - u.cost), { color = params.price - fee - u.cost >= 0 and T.gr or T.re2, leftWeight = W.bold }),
	}, { gap = 0, pad = { 4, 12 } }).Parent = b
	if not ok then
		Ui.note("r", "Ingresá un precio entre $100 y " .. Util.money(u.stats.price * 3) .. ".").Parent = b
	end
	Ui.text("Mientras está publicada no se ofrece en el salón y sigue ocupando lugar del almacén. Podés retirarla en cualquier momento.", { size = Ui.S.xs, color = T.mut }).Parent = b
	local pub
	pub = Ui.button("Publicar", "p", function()
		local r = App.request("marketPublish", { unitId = u.id, price = params.price, mode = params.mode, hours = params.hours }, { button = pub })
		if r.ok then
			App.closeAllDialogs()
		end
	end, { disabled = not ok, why = "Precio inválido" })
	footer(box, { Ui.spacer(), Ui.button("Cancelar", "default", App.closeDialog), pub })
end

-- Notificaciones, recompensa diaria, configuración, ayuda y funciones futuras ------------------------------
Dialogs.notifications = function(box: Frame)
	local g = App.g
	header(box, "Notificaciones")
	local b = body(box)
	if #g.notifications == 0 then
		Ui.note("b", "Sin notificaciones todavía.").Parent = b
	end
	for _, n in g.notifications do
		local item = Ui.new("TextButton", { Name = "Notif_" .. n.id, Text = "", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = n.read and T.p1 or T.p2, BackgroundTransparency = 0, Corner = 10, Pad = { 8, 12 }, List = { dir = "H", gap = 10, v = "C" } }, {
			Ui.icon(n.kind == "ok" and "check" or (n.kind == "error" and "x" or (n.kind == "aviso" and "warn" or "help")), 16, n.kind == "ok" and T.gr or (n.kind == "error" and T.re2 or (n.kind == "aviso" and T.ye or T.vi2))),
			Ui.grow(Ui.col({ Ui.text(n.text, { size = Ui.S.sm, weight = n.read and W.med or W.bold }), Ui.text("Día " .. (n.day + 1) .. " · " .. tostring(n.at), { size = Ui.S.xs, color = T.mut }) }, 2)),
		})
		item.Activated:Connect(function()
			App.request("markRead", { id = n.id })
			App.closeDialog()
			if n.go and (App.screens[n.go] or n.go == "juego" or n.go == "editor") then
				App.go(n.go)
			end
		end)
		item.Parent = b
	end
	footer(box, {
		Ui.button("Marcar todas como leídas", "default", function()
			App.request("markRead", {})
			App.closeDialog()
		end, { small = true }),
		Ui.spacer(),
		Ui.button("Cerrar", "default", App.closeDialog),
	})
end

Dialogs.daily = function(box: Frame)
	local g = App.g
	header(box, "Recompensa diaria")
	local b = body(box)
	local can = g.daily.last ~= App.payload.today
	local row = {}
	for i, r in Catalog.DAILY_REWARDS do
		local current = math.min(g.daily.streak + 1, #Catalog.DAILY_REWARDS)
		table.insert(row, Ui.card({ Ui.lbl("Día " .. i), Ui.text(Rules.rewardText(r), { size = Ui.S.xs }) }, { gap = 4, pad = 8, stroke = (can and i == current) and T.gr or nil }))
	end
	Ui.grid(row, App.isPhone() and 3 or 7, 70, 6).Parent = b
	Ui.text("Racha actual: " .. g.daily.streak .. " día(s). Se cuenta por fecha real del servidor (UTC).", { size = Ui.S.sm, color = T.mut }).Parent = b
	local claim
	claim = Ui.button(can and "Reclamar" or "Ya reclamada hoy", "g", function()
		local r = App.request("claimDaily", nil, { button = claim })
		if r.ok then
			App.closeDialog()
		end
	end, { disabled = not can, why = "Volvé mañana" })
	footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog), claim })
end

Dialogs.settings = function(box: Frame)
	local s = App.settings
	header(box, "Configuración")
	local b = body(box)
	local function setting(key: string, value: any)
		App.request("setSetting", { key = key, value = value })
	end
	local function toggleRow(label: string, help: string, key: string)
		return Ui.card({
			Ui.grow(Ui.col({ Ui.text(label, { size = 14, weight = W.bold }), Ui.text(help, { size = Ui.S.xs, color = T.mut }) }, 2)),
			Ui.toggle(s[key] == true, function()
				setting(key, not s[key])
			end),
		}, { dir = "H", v = "C", gap = 10 })
	end
	local scales = {}
	for _, v in { 0.9, 1, 1.15, 1.3 } do
		table.insert(scales, Ui.opt(Util.round(v * 100) .. " %", s.textScale == v, function()
			setting("textScale", v)
		end, { width = 70 }))
	end
	local cams = {}
	for _, v in { 0.5, 1, 1.5, 2 } do
		table.insert(cams, Ui.opt("×" .. Util.num(v, 1), s.camSpeed == v, function()
			setting("camSpeed", v)
		end, { width = 70 }))
	end
	Ui.col({ Ui.lbl("Tamaño de la interfaz"), Ui.row(scales, 6, { wrap = true }), Ui.text("Agranda textos y botones. En pantallas chicas la distribución cambia en lugar de achicar todo.", { size = Ui.S.xs, color = T.mut }) }, 8).Parent = b
	Ui.col({ Ui.lbl("Velocidad de la cámara del editor"), Ui.row(cams, 6, { wrap = true }) }, 8).Parent = b
	toggleRow("Reducir movimiento", "Sin animaciones de aparición ni giro automático.", "reduceMotion").Parent = b
	toggleRow("Atajos de teclado visibles", "Muestra los números 0–8 en la navegación.", "keyHints").Parent = b
	toggleRow("Sonidos de la interfaz", "Avisos breves al completar acciones.", "sound").Parent = b
	Ui.text("Las preferencias se guardan con tu cuenta y se aplican a todas tus empresas.", { size = Ui.S.xs, color = T.mut }).Parent = b
	footer(box, { Ui.spacer(), Ui.button("Listo", "p", App.closeDialog) })
end

local HELP = {
	general = "Diseñá autos en el escritorio de diseño, fabricalos en la línea de producción, envialos al salón y vendelos a los clientes. El servidor valida todo el dinero: tu cliente solo pide acciones.",
	editor = "Cuatro pasos: elegí la base, instalá piezas (el desarrollo se paga una sola vez al guardar), personalizá pintura, ruedas, carrocería e interior, y revisá antes de guardar. Arrastrá sobre el auto para girarlo, usá la rueda o los botones para el zoom. Ctrl+Z deshace y Ctrl+Y rehace.",
	fabrica = "Cada línea fabrica sus órdenes por prioridad. El costo y los materiales se cobran al empezar cada unidad. Las estaciones se desgastan; reparalas antes de que se averíen. Acelerar duplica la velocidad con +40 % de costo.",
	autos = "Tus unidades terminadas esperan en el almacén. Envialas al salón para que lleguen clientes, publicalas en el mercado o vendelas al mayorista.",
	ventas = "Los clientes llegan si hay autos en el salón. Aceptá su oferta o negociá: la probabilidad que ves la calcula el servidor para ese monto.",
	mercado = "Mercado simulado dentro de tu partida, con vendedores ficticios. Comprar suma impuesto y comisión.",
	investigacion = "Investigar cuesta dinero y puntos (PI). Los PI se generan cada día; los ingenieros en el laboratorio generan más.",
	personal = "Contratá personal y asignalo a estaciones (velocidad) o departamentos (PI, interés de clientes, visitas, costo de desarrollo).",
	compania = "Cambiá la identidad de tu marca y ampliá la sede cuando cumplas los requisitos.",
	misiones = "Las misiones dan dinero, gemas y experiencia. Cada recompensa se cobra una sola vez.",
	estadisticas = "Resultados de 7, 14 o 30 días calculados con agregados diarios completos.",
}
Dialogs.help = function(box: Frame, params: any)
	header(box, "Ayuda y controles")
	local b = body(box)
	local key = params.screen or "general"
	Ui.text(HELP[key] or HELP.general, { size = 14, color = T.tx2, lineHeight = 1.3 }).Parent = b
	Ui.card({
		Ui.lbl("Controles"),
		Ui.line("Caminar", "WASD / flechas · palanca táctil", { leftColor = T.mut, weight = W.med }),
		Ui.line("Interactuar con el garaje", "E · tocar el aviso", { leftColor = T.mut, weight = W.med }),
		Ui.line("Secciones", "0 Sede · 1 Diseño · 2 Mis autos · 3 Fábrica · 4 Ventas · 5 Mercado · 6 Investigación · 7 Personal · 8 Compañía", { leftColor = T.mut, weight = W.med }),
		Ui.line("Cerrar paneles y diálogos", "Esc", { leftColor = T.mut, weight = W.med }),
		Ui.line("Editor: deshacer / rehacer", "Ctrl+Z / Ctrl+Y", { leftColor = T.mut, weight = W.med }),
		Ui.line("Editor: girar y zoom", "Arrastrar · rueda del mouse · botones", { leftColor = T.mut, weight = W.med }),
	}, { gap = 0 }).Parent = b
	Ui.note("b", "Los autos son modelos provisionales hechos con piezas básicas: no se conducen. Los modelos y el mapa definitivos llegan en una etapa posterior.").Parent = b
	footer(box, { Ui.spacer(), Ui.button("Entendido", "p", App.closeDialog) })
end

local FUTURE = {
	amigos = { "Amigos", "Función futura: ver a tus amigos conectados y visitar sus sedes. Todavía no está implementada." },
	eventos = { "Eventos", "Función futura: eventos de temporada que cambian la demanda. Todavía no modifican la simulación ni entregan premios." },
	tienda = { "Tienda", "Función futura. No hay compras con dinero real. Las gemas se ganan subiendo de nivel, con misiones y con la recompensa diaria." },
}
Dialogs.future = function(box: Frame, params: any)
	local f = FUTURE[params.what] or FUTURE.tienda
	header(box, f[1])
	local b = body(box)
	Ui.chip("Función futura", "cy").Parent = b
	Ui.text(f[2], { size = 14, color = T.tx2 }).Parent = b
	footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
end

-- Menú de navegación (celular) y «Más» (escritorio).
Dialogs.navMenu = function(box: Frame, params: any)
	local Hud = App.screens.hud
	local g = App.g
	header(box, params.full and "Menú" or "Más")
	local b = body(box)
	local items = {}
	local counts = Hud.counts(g)
	local function item(id: string, label: string, icon: string, onClick: () -> ())
		local cnt = counts[id]
		local btn = Ui.new("TextButton", { Name = "Menu_" .. id, Text = "", Size = UDim2.new(1, 0, 0, 52), BackgroundColor3 = T.p2, BackgroundTransparency = 0, Corner = 10, Stroke = T.line2, Pad = { 0, 12 }, List = { dir = "H", gap = 10, v = "C" } }, {
			Ui.icon(icon, 18, T.tx),
			Ui.inline(label, { size = 14, weight = W.semi }),
			cnt and Ui.chip(tostring(cnt[1]), "cg") or nil,
		})
		btn.Activated:Connect(function()
			App.closeDialog()
			onClick()
		end)
		table.insert(items, btn)
	end
	if params.full then
		item("juego", "Sede", "home", function()
			App.go("juego")
		end)
		for _, n in Hud.NAV do
			item(n[1], n[2], n[3], function()
				App.go(n[1])
			end)
		end
	end
	for _, n in Hud.MORE do
		item(n[1], n[2], n[3], function()
			App.go(n[1])
		end)
	end
	item("notifs", "Notificaciones", "bell", function()
		App.openDialog("notifications", {})
	end)
	item("daily", "Recompensa diaria", "gift", function()
		App.openDialog("daily", {})
	end)
	item("settings", "Configuración", "gear", function()
		App.openDialog("settings", {})
	end)
	item("help", "Ayuda y controles", "help", function()
		App.openDialog("help", { screen = App.ui.route })
	end)
	item("amigos", "Amigos (futuro)", "users", function()
		App.openDialog("future", { what = "amigos" })
	end)
	item("tienda", "Tienda (futuro)", "gem", function()
		App.openDialog("future", { what = "tienda" })
	end)
	item("eventos", "Eventos (futuro)", "cal", function()
		App.openDialog("future", { what = "eventos" })
	end)
	item("menu", "Volver al menú de empresas", "left", function()
		App.guardEditor(function()
			App.request("leaveCompany")
			App.go("menu")
		end)
	end)
	Ui.grid(items, App.isPhone() and 2 or 2, 52, 8).Parent = b
	footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
end

-- Prueba en pista (V3: testDrive), calculada con los valores actuales del proyecto.
Dialogs.testDrive = function(box: Frame)
	local g = App.g
	local e = App.ui.editor
	local d = e and e.draft
	header(box, "Prueba en pista" .. (d and (" · " .. d.name) or ""))
	local b = body(box)
	if not d then
		footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
		return
	end
	local c = DesignCalc.computeDesign(g, d)
	local lap = 60 + c.accel * 2.2 + (100 - c.handling) * 0.35 + c.stop * 0.25 - c.top * 0.05
	local drag = 7 + c.accel * 0.75
	Ui.text("Simulación con los valores actuales del proyecto (no consume dinero ni materiales).", { size = Ui.S.sm, color = T.mut }).Parent = b
	Ui.grid({
		(Ui.kv("Vuelta al circuito (2,1 km)", Util.num(lap, 1) .. " s")),
		(Ui.kv("Cuarto de milla (402 m)", Util.num(drag, 1) .. " s")),
		(Ui.kv("0–100 km/h", Util.num(c.accel, 1) .. " s")),
		(Ui.kv("Frenado 100→0", c.stop .. " m")),
		(Ui.kv("Velocidad máxima", c.top .. " km/h")),
		(Ui.kv("Autonomía estimada", Util.round((c.ev and 6000 or 5500) / c.consumption) .. " km")),
	}, App.isPhone() and 2 or 3, 70).Parent = b
	Ui.text("Menos segundos y metros es mejor. " .. (c.handling < 50 and "El manejo es bajo: probá frenos o suspensión mejores." or "Buen equilibrio en curvas."), { size = Ui.S.xs, color = T.mut }).Parent = b
	footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
end

return Dialogs
