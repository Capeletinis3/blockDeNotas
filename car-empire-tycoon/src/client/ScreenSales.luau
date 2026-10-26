--!strict
--[[
	Ventas y concesionario (SCREENS.ventas de la V3): clientes con su paciencia y ofertas, autos en
	exhibición con precio de lista, descuento, precio final, margen y demanda, unidades en el almacén,
	historial de ventas (cada línea abre el detalle) y, al costado, promoción, últimos 7 días y reglas.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Sheet = require(script.Parent.ScreenSheet)
local Inventory = require(script.Parent.ScreenInventory)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Ventas y concesionario",
	icon = "tag",
}

function Screen.head(g: any): { Instance }
	local out = { Ui.chip("Salón " .. g.derived.showroomUsed .. "/" .. g.derived.caps.showroom, "cg") }
	if g.promo then
		table.insert(out, Ui.chip("Promoción activa", "cy"))
	end
	return out
end

local function findUnit(g: any, id: any): any
	for _, u in g.units do
		if u.id == id then
			return u
		end
	end
	return nil
end

local function custRow(g: any, c: any): Frame
	local u = findUnit(g, c.unitId)
	local gone = c.state == "se fue"
	local stateChip = gone and Ui.chip("Se fue sin comprar", "cn") or (c.state == "oferta" and Ui.chip("Ofrece " .. Util.money(c.offer), "cb") or Ui.chip("Mirando", "cn"))
	local nodes: { Instance? } = {
		Ui.row({
			Ui.ico("users", T.pink, Ui.hex("#FF78AA"), 32, { alpha = 0.14, iconSize = 16 }),
			Ui.grow(Ui.col({
				Ui.text(c.name, { size = 15, weight = W.bold }),
				Ui.text("Busca: " .. (Catalog.TYPES[c.wants] or c.wants) .. " · valora " .. (Catalog.PREF_LABEL[c.pref] or c.pref) .. " · interés " .. c.interest .. "%" .. (u and (" · mira " .. u.name .. " (" .. u.serial .. ")") or ""), { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			stateChip,
		}, 10, { wrap = App.isPhone() }),
	}
	if not gone then
		local bar, fill = Ui.bar(100, T.ye)
		local label = Ui.inline("", { size = Ui.S.xs })
		App.live(function(gg: any)
			for _, x in gg.customers do
				if x.id == c.id then
					Ui.setBar(fill, math.clamp(100 - x.waited / math.max(1, x.patience) * 100, 0, 100))
					label.Text = x.state == "se fue" and "Se fue" or ("Se va en " .. Util.gameDuration(math.max(0, x.patience - x.waited)))
				end
			end
		end)
		table.insert(nodes, Ui.row({ Ui.inline("Paciencia", { size = Ui.S.xs, color = T.mut, width = 70 }), Ui.grow(bar), label }, 10))
	end
	if c.state == "oferta" and u then
		local accept
		accept = Ui.button("Aceptar " .. Util.money(c.offer), "g", function()
			App.request("acceptOffer", { customerId = c.id }, { button = accept })
		end, { small = true, name = "Aceptar_" .. c.id })
		table.insert(nodes, Ui.row({
			Ui.button("Negociar", "p", function()
				App.ui.counterDraft = nil
				App.openDialog("counter", { customerId = c.id, wide = true })
			end, { small = true, name = "Negociar_" .. c.id }),
			accept,
			Ui.button("Rechazar", "q", function()
				App.request("rejectCustomer", { customerId = c.id })
			end, { small = true }),
			Ui.button("Ver el auto", "q", function()
				App.openDialog("unitDetail", { unitId = u.id, wide = true })
			end, { small = true, icon = "eye", iconSize = 14 }),
			Ui.inline("Precio de lista " .. Util.money(Rules.finalPrice(u)) .. " · margen con su oferta " .. Util.money(c.offer - u.cost), { size = Ui.S.xs, color = T.mut }),
		}, 6, { wrap = true }))
	end
	local card = Ui.card(nodes, { gap = 8, stroke = c.state == "oferta" and T.bl or nil, name = "Cliente_" .. c.id })
	if c.state == "oferta" then
		local s = card:FindFirstChildOfClass("UIStroke")
		if s then
			s.Transparency = 0.45
		end
	end
	if gone then
		-- opacity .55 de la V3
		for _, d in card:GetDescendants() do
			if d:IsA("TextLabel") then
				d.TextTransparency = 0.45
			end
		end
		card.BackgroundTransparency = 0.45
	end
	return card
end

local function showCard(g: any, u: any): Frame
	local fp = Rules.finalPrice(u)
	local dem = Rules.interest(g, u, nil)
	local discLabel = Ui.inline("Descuento: <b>" .. u.discount .. "%</b>", { size = Ui.S.xs, color = T.mut })
	return Ui.card({
		Ui.row({
			Ui.paintChip(u.spec, 44, 28),
			Ui.grow(Ui.text(u.name .. " <font color=\"#A3AAB8\" size=\"11\">" .. u.serial .. "</font>", { size = 15, weight = W.bold })),
			Ui.inline("Recomendado " .. Util.money(u.stats.price), { size = Ui.S.xs, color = T.mut }),
		}, 10),
		Ui.grid({
			Ui.col({
				Ui.text("Precio de lista ($)", { size = Ui.S.xs, color = T.mut }),
				Ui.input(tostring(u.price), "Precio", function(text: string)
					local n = tonumber((string.gsub(text, "[^%d]", "")))
					if n and n ~= u.price then
						App.request("setPrice", { unitId = u.id, price = n })
					else
						App.forceRender()
					end
				end, { name = "Precio_" .. u.serial, numeric = true }),
			}, 4),
			Ui.col({
				discLabel,
				Ui.slider(u.discount, 0, Catalog.RULES.maxDiscount, 1, function(v: number, final: boolean)
					discLabel.Text = "Descuento: <b>" .. v .. "%</b>"
					if final and v ~= u.discount then
						App.request("setDiscount", { unitId = u.id, discount = v })
					end
				end, { name = "Descuento_" .. u.serial }),
			}, 4),
			Ui.col({
				Ui.text("Precio final · margen", { size = Ui.S.xs, color = T.mut }),
				Ui.text(Util.money(fp), { size = 15, weight = W.bold }),
				Ui.text(Util.money(fp - u.cost) .. " por unidad", { size = Ui.S.xs, weight = W.bold, color = fp - u.cost >= 0 and T.gr or T.re2 }),
			}, 2),
		}, 3, nil, 10),
		Ui.row({ Ui.inline("Demanda", { size = Ui.S.xs, color = T.mut, width = 62 }), Ui.grow((Ui.bar(dem, dem > 66 and T.gr or (dem > 33 and T.bl or T.ye)))), Ui.inline(dem .. "/100", { size = Ui.S.xs, weight = W.bold }) }, 10),
		Ui.row((function()
			local acts = Inventory.unitActions(g, u)
			table.insert(acts, Ui.button("Mayorista · " .. Util.money(Rules.wholesale(u)), "default", function()
				Inventory.askWholesale(g, u)
			end, { small = true }))
			return acts
		end)(), 6, { wrap = true }),
	}, { gap = 8, name = "Exhibido_" .. u.serial })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local offers = 0
	local cust = {}
	for _, c in g.customers do
		if c.state ~= "compró" then
			table.insert(cust, c)
			if c.state == "oferta" then
				offers += 1
			end
		end
	end
	local show, store = {}, {}
	for _, u in g.units do
		if u.status == "salon" then
			table.insert(show, u)
		elseif u.status == "almacen" then
			table.insert(store, u)
		end
	end
	local tabs, tab = Sheet.tabs("ventas", { { "salon", "Salón y clientes", offers > 0 and offers or nil }, { "hist", "Historial de ventas" } }, "salon")
	tabs.Parent = main
	if tab == "salon" then
		local sec: { Instance? } = { Ui.row({ Ui.grow(Ui.lbl("Clientes en el concesionario")), (App.narrowPhone and Ui.text("Llegan solo si hay autos en el salón", { size = Ui.S.xs, color = T.mut, width = 150, align = "R" }) or Ui.inline("Llegan solo si hay autos en el salón", { size = Ui.S.xs, color = T.mut })) }, 10) }
		if #cust == 0 then
			table.insert(sec, Ui.empty("users", #show > 0 and "Todavía no llegó nadie. Los clientes aparecen con el tiempo de juego; una promoción atrae más." or "El salón está vacío. Enviá un auto desde el almacén para recibir clientes."))
		end
		for _, c in cust do
			table.insert(sec, custRow(g, c))
		end
		Ui.col(sec, 8).Parent = main
		local sec2: { Instance? } = { Ui.lbl("En exhibición (" .. #show .. "/" .. g.derived.caps.showroom .. ")") }
		if #show == 0 then
			table.insert(sec2, Ui.empty(nil, "Sin autos en el salón."))
		end
		for _, u in show do
			table.insert(sec2, showCard(g, u))
		end
		Ui.col(sec2, 8).Parent = main
		local sec3: { Instance? } = { Ui.lbl("En el almacén (" .. #store .. ")") }
		if #store == 0 then
			table.insert(sec3, Ui.empty(nil, "No hay unidades esperando.", Ui.button("Ir a Fábrica", "default", function()
				App.go("fabrica")
			end, { small = true })))
		end
		for _, u in store do
			local send
			send = Ui.button("Enviar al salón", "p", function()
				App.request("sendToShowroom", { unitId = u.id }, { button = send })
			end, { small = true, disabled = g.derived.showroomUsed >= g.derived.caps.showroom, why = "Salón lleno" })
			table.insert(sec3, Ui.card({
				Ui.paintChip(u.spec, 36, 24),
				Ui.grow(Ui.text(u.name .. " <font color=\"#A3AAB8\" size=\"11\">" .. u.serial .. " · costo " .. Util.money(u.cost) .. "</font>", { size = 15, weight = W.bold })),
				send,
				Ui.button("Mayorista · " .. Util.money(Rules.wholesale(u)), "default", function()
					Inventory.askWholesale(g, u)
				end, { small = true }),
			}, { dir = "H", v = "C", gap = 10, wrap = true }))
		end
		Ui.col(sec3, 8).Parent = main
	else
		if #g.sales == 0 then
			Ui.empty("tag", "Todavía no vendiste ningún auto.").Parent = main
		else
			local lines: { Instance? } = {}
			local n = 0
			for i = #g.sales, 1, -1 do
				n += 1
				if n > 60 then
					break
				end
				local s = g.sales[i]
				local line = Ui.new("TextButton", {
					Name = "Venta_" .. s.id,
					Text = "",
					BackgroundTransparency = 1,
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					Pad = { 8, 0 },
					List = { dir = "H", gap = 12, v = "C" },
				}, {
					Ui.grow(Ui.text(s.name .. " <font color=\"#A3AAB8\" size=\"11\">" .. s.serial .. " · día " .. (s.day + 1) .. " · " .. s.channel .. (s.buyer and (" · " .. s.buyer) or "") .. (s.demo and " · demostración" or "") .. "</font>", { size = 14 })),
					Ui.inline(Util.money(s.price), { size = 14, weight = W.bold }),
					Ui.inline((s.margin >= 0 and "▲ " or "▼ ") .. Util.money(s.margin), { size = 14, weight = W.bold, color = s.margin >= 0 and T.gr or T.re2, width = 110, align = "R" }),
				})
				line.Activated:Connect(function()
					App.openDialog("saleDetail", { saleId = s.id })
				end)
				table.insert(lines, Ui.underline(line))
			end
			Ui.card(lines, { gap = 0, pad = { 4, 14 } }).Parent = main
		end
	end

	-- Columna lateral
	local hasPromo = Rules.has(g, "mk2")
	local promoNode = Catalog.researchNode("mk2")
	Ui.card({
		Ui.lbl("Promoción del concesionario"),
		Ui.row({
			Ui.grow(Ui.text("Atrae 35% más clientes. Cuesta " .. Util.money(Catalog.RULES.promoCostPerDay) .. " por día de juego (se cobra al cambiar de día)." .. (hasPromo and "" or (" Requiere investigar «" .. (promoNode and promoNode.name or "Promociones") .. "».")), { size = Ui.S.xs, color = T.mut, lineHeight = 1.4 })),
			Ui.toggle(g.promo == true, function()
				App.request("togglePromo")
			end, not hasPromo and not g.promo, "Requiere investigar «" .. (promoNode and promoNode.name or "Promociones") .. "»."),
		}, 10),
	}, { gap = 10, name = "Promocion" }).Parent = side
	local f = Rules.finance(g, 7)
	Ui.card({
		Ui.lbl("Últimos 7 días"),
		Ui.between("Autos vendidos", tostring(f.units)),
		Ui.between("Ingresos por venta", Util.money(f.revenue)),
		Ui.between("Margen bruto", Util.money(f.margin), { color = f.margin >= 0 and T.gr or T.re2 }),
		Ui.between("Comisiones", Util.money(-f.fees), { color = T.or_ }),
		f.demo and Ui.text("Incluye ventas de demostración", { size = Ui.S.xs, color = T.ye }) or nil,
	}, { gap = 6 }).Parent = side
	Ui.card({
		Ui.lbl("Cómo deciden los clientes"),
		Ui.text("Cada cliente tiene un presupuesto oculto, un tipo de auto buscado, una preferencia y paciencia. El interés sube con la calidad, la reputación, el objetivo del diseño y vendedores asignados, y baja si el precio supera al recomendado. Una contraoferta por encima del presupuesto nunca se acepta. Vender al mayorista es inmediato: paga el costo × " .. Util.num(Catalog.RULES.wholesaleFactor, 2) .. ".", { size = Ui.S.xs, color = T.mut, lineHeight = 1.45 }),
	}, { gap = 4 }).Parent = side
end

return Screen
