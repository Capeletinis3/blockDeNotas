--!strict
-- Diálogos (.dlg de la V3): nueva orden de producción, contraoferta y confirmación.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local DesignCalc = require(Shared.DesignCalc)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Dialogs = {}

local function header(box: Frame, title: string)
	Ui.row({
		Ui.grow(Ui.text(title, { size = Ui.S.h2, weight = W.bold })),
		Ui.button("✕", "default", function()
			App.closeDialog()
		end, { small = true, width = 36 }),
	}, 12, { Pad = { 18, 20, 6, 20 }, Parent = box })
end

local function body(box: Frame): Frame
	local s = Ui.scroll({}, { name = "CuerpoDialogo", gap = 12, pad = { 12, 20, 18, 20 } })
	s.Size = UDim2.new(1, 0, 0, 0)
	s.AutomaticSize = Enum.AutomaticSize.Y
	s.Parent = box
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(math.huge, App.vh - 200)
	limit.Parent = s
	return s
end

local function footer(box: Frame, buttons: { Instance? })
	Ui.row(buttons, 10, { BackgroundColor3 = Color3.fromHex("#0D0F14"), BackgroundTransparency = 0, Pad = { 14, 20, 18, 20 }, Parent = box })
end

-- Nueva orden de producción ------------------------------------------------------------
Dialogs.order = function(box: Frame, params: any)
	local g = App.g
	if #g.designs == 0 then
		header(box, "Nueva orden de producción")
		Ui.note("b", "Primero guardá un diseño en el editor.").Parent = body(box)
		footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
		return
	end
	local st = App.ui.orderDraft
	if not st or params.designId and st.designId ~= params.designId and not st.touched then
		st = { designId = params.designId or g.designs[#g.designs].id, qty = 1 }
		App.ui.orderDraft = st
	end
	local d = nil
	for _, x in g.designs do
		if x.id == st.designId then
			d = x
		end
	end
	if not d then
		d = g.designs[#g.designs]
		st.designId = d.id
	end
	local c = DesignCalc.computeDesign(g, d)
	local qty = st.qty

	header(box, "Nueva orden de producción")
	local b = body(box)
	Ui.lbl("Modelo (diseño guardado)").Parent = b
	local opts = {}
	for _, x in g.designs do
		table.insert(opts, Ui.opt(x.name .. " v" .. x.version, x.id == d.id, function()
			st.designId = x.id
			st.touched = true
			App.renderDialog()
		end))
	end
	Ui.row(opts, 8, { wrap = true }).Parent = b

	Ui.lbl("Cantidad (1–" .. Catalog.RULES.maxQty .. ")").Parent = b
	local function setQty(n: number)
		st.qty = math.clamp(n, 1, Catalog.RULES.maxQty)
		st.touched = true
		App.renderDialog()
	end
	local qtyBox = Ui.input(tostring(qty), "1", function(text: string)
		local n = tonumber(text)
		if n then
			setQty(math.floor(n))
		else
			App.renderDialog()
		end
	end, { width = 90 })
	Ui.row({
		Ui.button("−", "default", function()
			setQty(qty - 1)
		end, { width = 44 }),
		qtyBox,
		Ui.button("+", "default", function()
			setQty(qty + 1)
		end, { width = 44 }),
		Ui.opt("1", qty == 1, function()
			setQty(1)
		end, { width = 44 }),
		Ui.opt("3", qty == 3, function()
			setQty(3)
		end, { width = 44 }),
		Ui.opt("6", qty == 6, function()
			setQty(6)
		end, { width = 44 }),
	}, 8).Parent = b

	local minutes = c.build / math.max(0.01, g.derived.lineSpeed)
	local secs = g.time.speed > 0 and math.ceil(minutes / (Catalog.RULES.minutesPerRealSecond * g.time.speed)) or nil
	local free = g.derived.caps.warehouse - g.derived.warehouseUsed - g.derived.inProgress
	local k1 = Ui.kv("Costo por unidad", Util.money(c.unitCost), { sub = "Se cobra al empezar cada unidad" })
	local k2 = Ui.kv("Costo total estimado", Util.money(c.unitCost * qty), { color = T.or_ })
	local k3 = Ui.kv("Tiempo por unidad", Util.gameDuration(minutes) .. " de juego", { sub = secs and ("≈ " .. secs .. " s reales a la velocidad actual") or "Simulación en pausa" })
	local k4 = Ui.kv("Lugar libre en el almacén", tostring(free), { color = free < qty and T.ye or T.tx })
	Ui.grid({ k1, k2, k3, k4 }, 2, 78).Parent = b

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
	Ui.note("b", "La orden guarda una copia de «" .. d.name .. "» v" .. d.version .. ": aunque después edites el proyecto, estas unidades se fabrican con esta versión y este costo unitario.").Parent = b
	if short then
		Ui.note("y", "Los materiales no alcanzan para toda la orden. Se fabricará hasta donde alcancen y la orden se detendrá mostrando qué falta.").Parent = b
	end
	if free < qty then
		Ui.note("y", "No hay lugar para todas las unidades: la orden se detendrá cuando el almacén se llene.").Parent = b
	end
	if g.money < c.unitCost then
		Ui.note("r", "No alcanza el dinero para empezar la primera unidad.").Parent = b
	end
	footer(box, {
		Ui.spacer(),
		Ui.button("Cancelar", "default", App.closeDialog),
		Ui.button("Crear orden", "p", function()
			local r = App.request("createOrder", { designId = d.id, qty = st.qty })
			if r.ok then
				App.ui.orderDraft = nil
				App.closeDialog()
				if App.ui.route ~= "fabrica" then
					App.go("fabrica")
				end
			end
		end),
	})
end

-- Contraoferta ------------------------------------------------------------------------
-- La probabilidad que se muestra usa la misma regla que el servidor, salvo el presupuesto
-- (oculto): si el monto lo supera, el cliente rechaza.
local function chanceFor(c: any, amount: number): number
	local budgetGuess = math.max(c.offer, math.floor(c.offer / 0.88))
	local span = math.max(1, budgetGuess - c.offer)
	local over = math.clamp((amount - c.offer) / span, 0, 1)
	return math.clamp(Util.round((c.interest / 100) * (95 - over * 70) - c.rounds * 8), 3, 95)
end

Dialogs.counter = function(box: Frame, params: any)
	local g = App.g
	local c = nil
	for _, x in g.customers do
		if x.id == params.customerId then
			c = x
		end
	end
	local u = nil
	if c then
		for _, x in g.units do
			if x.id == c.unitId then
				u = x
			end
		end
	end
	App.ui.dialog.sig = function(gg: any): string
		for _, x in gg.customers do
			if x.id == params.customerId then
				return x.state .. tostring(x.offer) .. tostring(x.rounds)
			end
		end
		return "gone"
	end
	header(box, "Negociación" .. (c and (" · " .. c.name) or ""))
	local b = body(box)
	if not c or c.state ~= "oferta" or not u then
		Ui.note("y", "El cliente o el auto ya no están disponibles. No se vendió nada.").Parent = b
		footer(box, { Ui.spacer(), Ui.button("Cerrar", "default", App.closeDialog) })
		return
	end
	local st = App.ui.counterDraft
	if not st or st.customerId ~= c.id then
		st = { customerId = c.id, amount = Util.round(((c.offer + u.price) / 2) / 100) * 100 }
		App.ui.counterDraft = st
	end
	if st.amount <= c.offer then
		st.amount = c.offer + 500
	end

	Ui.grid({
		Ui.card({
			Ui.lbl("Auto"),
			Ui.row({ Ui.paintChip(u.spec, 44, 28), Ui.grow(Ui.text(u.name .. "  <font color=\"#7D8493\">" .. u.serial .. "</font>", { size = 15, weight = W.bold })) }, 8),
			Ui.text("Precio de lista " .. Util.money(u.price) .. " · costo " .. Util.money(u.cost), { size = Ui.S.xs, color = T.mut }),
		}, { gap = 6 }),
		Ui.card({
			Ui.lbl("Cliente"),
			Ui.text(c.name, { size = 15, weight = W.bold }),
			Ui.text("Busca " .. string.lower(Catalog.TYPES[c.wants] or c.wants) .. " · valora " .. (Catalog.PREF_LABEL[c.pref] or c.pref) .. " · interés " .. c.interest .. "% · rondas " .. c.rounds, { size = Ui.S.xs, color = T.mut }),
			Ui.chip("Su oferta: " .. Util.money(c.offer), "cb"),
		}, { gap = 6 }),
	}, 2, 112).Parent = b

	local chanceKv, chanceValue = Ui.kv("Probabilidad estimada de que acepte", "")
	local marginKv, marginValue = Ui.kv("Margen si acepta", "")
	local function refresh()
		local ch = chanceFor(c, st.amount)
		chanceValue.Text = ch .. "%"
		chanceValue.TextColor3 = ch >= 60 and T.gr or (ch >= 30 and T.ye or T.re2)
		local m = st.amount - u.cost
		marginValue.Text = Util.money(m)
		marginValue.TextColor3 = m >= 0 and T.gr or T.re2
	end
	local amountBox = Ui.input(tostring(st.amount), "Monto", function(text: string)
		local n = tonumber((string.gsub(text, "[^%d]", "")))
		if n then
			st.amount = n
		end
		App.renderDialog()
	end, { width = 160, onChange = function(text: string)
		local n = tonumber((string.gsub(text, "[^%d]", "")))
		if n then
			st.amount = n
			refresh()
		end
	end })
	Ui.lbl("Tu contraoferta").Parent = b
	Ui.row({
		Ui.button("−500", "default", function()
			st.amount = math.max(c.offer + 100, st.amount - 500)
			App.renderDialog()
		end, { small = true }),
		amountBox,
		Ui.button("+500", "default", function()
			st.amount += 500
			App.renderDialog()
		end, { small = true }),
	}, 8).Parent = b
	Ui.grid({ chanceKv, marginKv }, 2, 64).Parent = b
	refresh()
	Ui.text("El servidor tira un número del 0 al 99: si es menor que la probabilidad, el cliente acepta. Si tu monto supera su presupuesto (que no conocés), no acepta. Cada rechazo baja la probabilidad y le resta paciencia.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.25 }).Parent = b
	if params.lastMsg then
		Ui.note(params.lastSold and "g" or "y", params.lastMsg).Parent = b
	end
	footer(box, {
		Ui.button("Rechazar y despedir", "q", function()
			App.request("rejectCustomer", { customerId = c.id })
			App.closeDialog()
		end),
		Ui.spacer(),
		Ui.button("Aceptar " .. Util.money(c.offer), "g", function()
			local r = App.request("acceptOffer", { customerId = c.id })
			if r.ok then
				App.closeDialog()
			end
		end),
		Ui.button("Contraofertar " .. Util.money(st.amount), "p", function()
			local r = App.request("counterOffer", { customerId = c.id, amount = st.amount })
			if r.ok and r.sold ~= false then
				App.closeDialog()
			elseif r.ok then
				App.ui.dialog.params.lastMsg = r.msg
				App.ui.dialog.params.lastSold = false
				App.renderDialog()
			end
		end),
	})
end

-- Confirmación genérica -------------------------------------------------------------------
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
		end),
	})
end

return Dialogs
