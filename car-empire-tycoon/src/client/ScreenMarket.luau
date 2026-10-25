--!strict
--[[
	Mercado global (SCREENS.mercado de la V3): vehículos, piezas, diseños y materiales de vendedores
	ficticios con búsqueda, filtros y orden; favoritos; mis publicaciones y ofertas recibidas.
	Es una simulación dentro de la partida: no hay comercio entre jugadores ni pagos reales.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Sheet = require(script.Parent.ScreenSheet)
local T = Ui.T
local W = Ui.W
local hex = Ui.hex

local Screen = {
	title = "Mercado global",
	icon = "globe",
	noSide = true,
}

Screen.RARITY = { ["Común"] = "cn", Rara = "cb", ["Épica"] = "cv", Legendaria = "cy" }

function Screen.head(_g: any): { Instance }
	return { Ui.chip("Simulación local · vendedores ficticios", "cy") }
end

function Screen.total(l: any, amount: number?): any
	local p = amount or (l.mode == "subasta" and l.bid or l.price)
	local tax = Util.round(p * Catalog.RULES.taxRate)
	local fee = Util.round(p * Catalog.RULES.feeRate)
	return { price = p, tax = tax, fee = fee, total = p + tax + fee }
end

-- Misma verificación que el servidor (se muestra antes de comprar).
function Screen.buyCheck(g: any, l: any, amount: number?): string?
	local t = Screen.total(l, amount)
	local d = g.derived
	if l.status ~= "activa" then
		return "La publicación ya no está disponible."
	end
	if g.money < t.total then
		return "Fondos insuficientes: necesitás " .. Util.money(t.total) .. " y tenés " .. Util.money(g.money) .. "."
	end
	if l.kind == "vehiculo" and d.warehouseUsed >= d.caps.warehouse then
		return "Almacén lleno (" .. d.warehouseUsed .. "/" .. d.caps.warehouse .. "). Vendé o enviá autos al salón."
	end
	if l.kind == "material" and d.matsUsed + l.qty > d.caps.mats then
		return "No hay lugar para materiales (" .. d.matsUsed .. "/" .. d.caps.mats .. ")."
	end
	return nil
end

-- LIVE.auction de la V3
function Screen.auctionText(g: any, id: any): string
	local l = nil
	for _, x in g.market.listings do
		if x.id == id then
			l = x
		end
	end
	for _, x in g.market.mine do
		if x.id == id then
			l = x
		end
	end
	if not l or l.mode ~= "subasta" then
		return ""
	end
	if l.status ~= "activa" then
		return l.status
	end
	return "Termina en " .. Util.gameDuration(math.max(0, l.ends - Rules.absMinute(g)))
end

local KIND_COLOR = { material = "#7A8090", pieza = "#4B3FB8", diseno = "#2A6DB8" }

local function listingCard(g: any, l: any): Frame
	local fav = table.find(g.market.favorites, l.id) ~= nil
	local lead = l.playerBid and l.playerBid >= (l.bid or 0)
	local price = l.mode == "subasta" and l.bid or l.price
	local sw = l.kind == "vehiculo" and l.spec.paint.primary or KIND_COLOR[l.kind] or "#7A8090"
	local icon = l.kind == "vehiculo" and "car" or (l.kind == "pieza" and "wrench" or (l.kind == "diseno" and "pen" or "box"))
	-- Franja de 64 px con degradado del color al fondo (linear-gradient 135°).
	local band = Ui.new("Frame", { Name = "Franja", Size = UDim2.new(1, 0, 0, 64), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0 })
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(Color3.fromHex(sw), hex("#11131A"))
	grad.Rotation = 35
	grad.Parent = band
	local ic = Ui.icon(icon, 28, hex("#FFFFFF"))
	ic.AnchorPoint = Vector2.new(0.5, 0.5)
	ic.Position = UDim2.fromScale(0.5, 0.5)
	ic.Parent = band
	local favBtn = Ui.button("", "q", function()
		App.request("marketFavorite", { listingId = l.id })
	end, { small = true, icon = "heart", iconSize = 16, fg = fav and hex("#FF5F8A") or hex("#FFFFFF"), name = "Favorito" })
	favBtn.AnchorPoint = Vector2.new(1, 0)
	favBtn.Position = UDim2.new(1, -6, 0, 6)
	favBtn.Parent = band
	local right: Instance
	if l.mode == "subasta" then
		local lab = Ui.inline(Screen.auctionText(g, l.id), { size = Ui.S.xs, color = T.mut })
		App.live(function(gg: any)
			lab.Text = Screen.auctionText(gg, l.id)
		end)
		right = lab
	else
		right = Ui.inline("+ impuesto y comisión", { size = Ui.S.xs, color = T.mut })
	end
	local card = Ui.card({
		band,
		Ui.col({
			Ui.text(l.name, { size = Ui.S.sm, weight = W.bold }),
			Ui.text(l.seller .. " · " .. l.cond .. (l.km and (" · " .. Util.num(l.km) .. " km") or "") .. (l.hp and (" · " .. l.hp .. " hp") or ""), { size = Ui.S.xs, color = T.mut }),
			Ui.row({
				Ui.chip(l.rarity, Screen.RARITY[l.rarity] or "cn"),
				l.mode == "subasta" and Ui.chip("Subasta", "cy") or nil,
				l.status ~= "activa" and Ui.chip(l.status, "cn") or nil,
				(l.playerBid and l.status == "activa") and Ui.chip(lead and "Vas ganando" or "Te superaron", lead and "cg" or "cr") or nil,
			}, 4, { wrap = true }),
			Ui.row({ Ui.grow(Ui.inline(Util.money(price or 0), { size = 15, weight = W.bold })), right }, 10),
			Ui.button("Ver publicación", "default", function()
				App.openDialog("listing", { listingId = l.id, wide = true })
			end, { small = true, fill = true, name = "VerPublicacion" }),
		}, 5, { Pad = 14 }),
	}, { gap = 0, pad = 0, clip = true, name = "Publicacion_" .. l.id })
	return card
end

function Screen.build(main: Frame, _side: Frame)
	local g = App.g
	local pend, active = 0, 0
	for _, o in g.market.offers do
		if o.status == "pendiente" then
			pend += 1
		end
	end
	for _, l in g.market.mine do
		if l.status == "activa" then
			active += 1
		end
	end
	local tabs, tab = Sheet.tabs("mercado", {
		{ "vehiculo", "Vehículos" }, { "pieza", "Piezas" }, { "diseno", "Diseños" }, { "material", "Materiales" },
		{ "fav", "Favoritos", #g.market.favorites > 0 and #g.market.favorites or nil },
		{ "mine", "Mis publicaciones", active > 0 and active or nil },
		{ "offers", "Ofertas recibidas", pend > 0 and pend or nil },
	}, "vehiculo")
	tabs.Parent = main
	Ui.note("b", "Este mercado funciona dentro de tu partida. Los vendedores y compradores son ficticios; no hay otros jugadores ni pagos reales. Comprar suma impuesto (" .. Util.round(Catalog.RULES.taxRate * 100) .. "%) y comisión (" .. Util.round(Catalog.RULES.feeRate * 100) .. "%).").Parent = main
	if tab == "mine" then
		local avail = 0
		for _, u in g.units do
			if u.status == "almacen" then
				avail += 1
			end
		end
		Ui.row({
			Ui.button("Publicar una unidad", "p", function()
				App.openDialog("publish", {})
			end, { small = true, icon = "plus", disabled = avail == 0, why = "Necesitás una unidad terminada en el almacén" }),
			Ui.inline("Las unidades publicadas siguen ocupando lugar del almacén.", { size = Ui.S.xs, color = T.mut }),
		}, 10, { wrap = true }).Parent = main
		if #g.market.mine == 0 then
			Ui.empty(nil, "No publicaste nada todavía.").Parent = main
		end
		for i = #g.market.mine, 1, -1 do
			local l = g.market.mine[i]
			local u = nil
			for _, x in g.units do
				if x.id == l.unitId then
					u = x
				end
			end
			local desc
			if l.mode == "subasta" then
				desc = Ui.inline("Subasta · oferta actual " .. (l.bid and (Util.money(l.bid) .. " de " .. tostring(l.bidder or "")) or "sin ofertas") .. " · " .. Screen.auctionText(g, l.id), { size = Ui.S.xs, color = T.mut })
				App.live(function(gg: any)
					desc.Text = "Subasta · oferta actual " .. (l.bid and (Util.money(l.bid) .. " de " .. tostring(l.bidder or "")) or "sin ofertas") .. " · " .. Screen.auctionText(gg, l.id)
				end)
			else
				desc = Ui.inline("Precio " .. Util.money(l.price), { size = Ui.S.xs, color = T.mut })
			end
			Ui.card({
				Ui.paintChip(u and u.spec or { paint = { primary = "#444444" } }, 40, 26),
				Ui.grow(Ui.col({ Ui.text(l.name, { size = 15, weight = W.bold }), desc }, 2)),
				Ui.chip(l.status, l.status == "activa" and "cg" or (l.status == "vendida" and "cb" or "cn")),
				l.status == "activa" and Ui.button("Retirar", "default", function()
					App.request("marketUnpublish", { unitId = l.unitId })
				end, { small = true }) or nil,
			}, { dir = "H", v = "C", gap = 10, wrap = true }).Parent = main
		end
		return
	elseif tab == "offers" then
		if #g.market.offers == 0 then
			Ui.empty(nil, "No recibiste ofertas. Llegan a tus publicaciones de precio fijo.").Parent = main
		end
		for i = #g.market.offers, 1, -1 do
			local o = g.market.offers[i]
			local l = nil
			for _, x in g.market.mine do
				if x.id == o.listingId then
					l = x
				end
			end
			local u = nil
			if l then
				for _, x in g.units do
					if x.id == l.unitId then
						u = x
					end
				end
			end
			local actions: { Instance? }
			if o.status == "pendiente" and l and l.status == "activa" then
				local acc
				acc = Ui.button("Aceptar", "g", function()
					App.request("marketAcceptOffer", { offerId = o.id }, { button = acc })
				end, { small = true })
				actions = { acc, Ui.button("Rechazar", "q", function()
					App.request("marketRejectOffer", { offerId = o.id })
				end, { small = true }) }
			else
				actions = { Ui.chip(o.status == "pendiente" and "ya no disponible" or o.status, "cn") }
			end
			local row = Ui.card({
				Ui.grow(Ui.col({
					Ui.text(o.from .. " ofrece " .. Util.money(o.amount), { size = 15, weight = W.bold }),
					Ui.text("por " .. (l and l.name or "—") .. (l and (" · tu precio " .. Util.money(l.price)) or "") .. (u and (" · margen " .. Util.money(o.amount - Util.round(o.amount * Catalog.RULES.feeRate) - u.cost) .. " después de la comisión") or ""), { size = Ui.S.xs, color = T.mut }),
				}, 2)),
			}, { dir = "H", v = "C", gap = 10, wrap = true })
			for _, a in actions do
				if a then
					a.Parent = row
				end
			end
			row.Parent = main
		end
		return
	end

	local filters: { Instance? } = { Sheet.search("mkt", "Buscar por nombre o vendedor") }
	if tab == "vehiculo" then
		local typeOpts = { { "todos", "Todos" } }
		for _, k in Catalog.TYPE_ORDER do
			table.insert(typeOpts, { k, Catalog.TYPES[k] })
		end
		table.insert(filters, Sheet.filter("mMode", "Modalidad", { { "todas", "Todas" }, { "directa", "Compra directa" }, { "subasta", "Subasta" } }, "todas"))
		table.insert(filters, Sheet.filter("mType", "Tipo", typeOpts, "todos"))
	end
	table.insert(filters, Sheet.filter("mRar", "Rareza", { { "todas", "Todas" }, { "Común", "Común" }, { "Rara", "Rara" }, { "Épica", "Épica" }, { "Legendaria", "Legendaria" } }, "todas"))
	table.insert(filters, Sheet.filter("mSort", "Orden", { { "precio", "Precio: menor a mayor" }, { "precio-d", "Precio: mayor a menor" }, { "nombre", "Nombre" }, { "fin", "Termina antes" } }, "precio"))
	Ui.row(filters, 10, { wrap = true }).Parent = main
	local mode, ty, rar, so = Sheet.value("mMode", "todas"), Sheet.value("mType", "todos"), Sheet.value("mRar", "todas"), Sheet.value("mSort", "precio")
	local list = {}
	for _, l in g.market.listings do
		local okTab = tab == "fav" and table.find(g.market.favorites, l.id) ~= nil or l.kind == tab
		local okStatus = l.status == "activa" or l.playerBid or tab == "fav"
		local okVeh = tab ~= "vehiculo" or ((mode == "todas" or l.mode == mode) and (ty == "todos" or l.type == ty))
		if okTab and okStatus and okVeh and (rar == "todas" or l.rarity == rar) and Sheet.matches("mkt", l.name, l.seller) then
			table.insert(list, l)
		end
	end
	local function pr(l: any): number
		return (l.mode == "subasta" and l.bid or l.price) or 0
	end
	table.sort(list, function(a, b)
		if so == "precio-d" then
			return pr(a) > pr(b)
		elseif so == "nombre" then
			return a.name < b.name
		elseif so == "fin" then
			return a.ends < b.ends
		end
		return pr(a) < pr(b)
	end)
	if #list == 0 then
		Ui.empty("search", tab == "fav" and "No marcaste favoritos. Tocá el corazón de una publicación." or "No hay publicaciones con esos filtros.").Parent = main
	else
		local cards = {}
		for _, l in list do
			table.insert(cards, listingCard(g, l))
		end
		Ui.grid(cards, App.isPhone() and 2 or 3, nil, 10).Parent = main
	end
	Ui.text("Las publicaciones se renuevan cada día de juego. Las subastas activas se mantienen hasta terminar.", { size = Ui.S.xs, color = T.mut }).Parent = main
end

return Screen
