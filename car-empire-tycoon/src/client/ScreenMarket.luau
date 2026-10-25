--!strict
-- Mercado global simulado (SCREENS.mercado de la V3): vehículos, piezas, diseños y materiales de
-- vendedores ficticios, favoritos, mis publicaciones y ofertas recibidas. Sin comercio entre jugadores.

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

local Screen = {
	title = "Mercado global",
	icon = "globe",
	color = Color3.fromHex("#F7C95C"),
	bg = Color3.fromHex("#322A14"),
}

local RAR = { ["Común"] = "cn", ["Rara"] = "cb", ["Épica"] = "cv", ["Legendaria"] = "cy" }

function Screen.head(_g: any): { Instance }
	return { Ui.chip("Vendedores ficticios · dentro de tu partida", "cy") }
end

function Screen.total(l: any, amount: number?): any
	local p = amount or (l.mode == "subasta" and l.bid or l.price)
	local tax = Util.round(p * Catalog.RULES.taxRate)
	local fee = Util.round(p * Catalog.RULES.feeRate)
	return { price = p, tax = tax, fee = fee, total = p + tax + fee }
end

local function timeLeft(g: any, l: any): string
	local left = l.ends - Rules.absMinute(g)
	if left <= 0 then
		return "terminó"
	end
	return "termina en " .. Util.gameDuration(left)
end

local function listingCard(g: any, l: any): Frame
	local fav = table.find(g.market.favorites, l.id) ~= nil
	local price = l.mode == "subasta" and l.bid or l.price
	local icon = l.kind == "vehiculo" and "car" or (l.kind == "pieza" and "wrench" or (l.kind == "diseno" and "pen" or "box"))
	local thumb = l.kind == "vehiculo" and Ui.carThumb(l.spec, 96, 56) or Ui.ico(icon, T.tx, Color3.fromHex("#2A2E38"), 56)
	local favBtn = Ui.button("", fav and "v" or "q", function()
		App.request("marketFavorite", { listingId = l.id })
	end, { small = true, width = 36, icon = "heart", name = "Favorito" })
	local liveLabel = Ui.inline(l.mode == "subasta" and timeLeft(g, l) or "+ impuesto y comisión", { size = Ui.S.xs, color = T.mut })
	if l.mode == "subasta" then
		App.live(function(gg: any)
			liveLabel.Text = timeLeft(gg, l)
		end)
	end
	local lead = l.playerBid and l.playerBid >= l.bid
	return Ui.card({
		Ui.row({ thumb, Ui.spacer(), favBtn }, 8),
		Ui.text(l.name, { size = 14, weight = W.bold }),
		Ui.text(l.seller .. " · " .. l.cond .. (l.km and (" · " .. Util.num(l.km) .. " km") or "") .. (l.hp and (" · " .. l.hp .. " hp") or ""), { size = Ui.S.xs, color = T.mut }),
		Ui.row({
			Ui.chip(l.rarity, RAR[l.rarity] or "cn"),
			l.mode == "subasta" and Ui.chip("Subasta · " .. l.bids .. " ofertas", "cy") or nil,
			l.status ~= "activa" and Ui.chip(l.status, "cn") or nil,
			lead and Ui.chip("Vas ganando", "cg") or nil,
		}, 4, { wrap = true }),
		Ui.row({ Ui.inline(Util.money(price), { size = 15, weight = W.bold }), Ui.spacer(), liveLabel }, 8),
		Ui.button("Ver publicación", "default", function()
			App.openDialog("listing", { listingId = l.id })
		end, { small = true, fill = true }),
	}, { gap = 6, name = "Publicacion_" .. l.id })
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local pend = 0
	for _, o in g.market.offers do
		if o.status == "pendiente" then
			pend += 1
		end
	end
	local active = 0
	for _, l in g.market.mine do
		if l.status == "activa" then
			active += 1
		end
	end
	local tabs, tab = Sheet.tabs("mercado", {
		{ "vehiculo", "Vehículos" }, { "pieza", "Piezas" }, { "diseno", "Diseños" }, { "material", "Materiales" },
		{ "fav", "Favoritos", #g.market.favorites }, { "mine", "Mis publicaciones", active }, { "offers", "Ofertas recibidas", pend },
	}, "vehiculo")
	tabs.Parent = main
	Ui.note("b", "Este mercado funciona dentro de tu partida: los vendedores y compradores son ficticios, no hay otros jugadores ni pagos reales. Comprar suma impuesto (" .. Util.round(Catalog.RULES.taxRate * 100) .. " %) y comisión (" .. Util.round(Catalog.RULES.feeRate * 100) .. " %). Las publicaciones se renuevan cada día de juego.").Parent = main
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
			Ui.text("Las unidades publicadas siguen ocupando lugar del almacén.", { size = Ui.S.xs, color = T.mut }),
		}, 10, { wrap = true }).Parent = main
		if #g.market.mine == 0 then
			Ui.note("b", "Todavía no publicaste nada.").Parent = main
		end
		for i = #g.market.mine, 1, -1 do
			local l = g.market.mine[i]
			local u
			for _, x in g.units do
				if x.id == l.unitId then
					u = x
				end
			end
			Ui.card({
				Ui.row({
					u and Ui.carThumb(u.spec, 64, 38) or Ui.ico("car", T.mut, T.p3, 38),
					Ui.grow(Ui.col({
						Ui.text(l.name, { size = 14, weight = W.bold }),
						Ui.text((l.mode == "subasta" and ("Subasta · mejor oferta " .. (l.bid and Util.money(l.bid) or "—") .. " · " .. timeLeft(g, l)) or ("Precio fijo " .. Util.money(l.price))) .. " · " .. l.status, { size = Ui.S.xs, color = T.mut }),
					}, 2)),
					(l.status == "activa" and u) and Ui.button("Retirar", "default", function()
						App.request("marketUnpublish", { unitId = u.id })
					end, { small = true }) or nil,
				}, 10),
			}).Parent = main
		end
	elseif tab == "offers" then
		if #g.market.offers == 0 then
			Ui.note("b", "Todavía no recibiste ofertas. Llegan para tus publicaciones a precio fijo.").Parent = main
		end
		for i = #g.market.offers, 1, -1 do
			local o = g.market.offers[i]
			local l, u
			for _, x in g.market.mine do
				if x.id == o.listingId then
					l = x
				end
			end
			if l then
				for _, x in g.units do
					if x.id == l.unitId then
						u = x
					end
				end
			end
			local accept
			accept = Ui.button("Aceptar", "g", function()
				App.request("marketAcceptOffer", { offerId = o.id }, { button = accept })
			end, { small = true })
			Ui.card({
				Ui.row({
					Ui.grow(Ui.col({
						Ui.text(o.from .. " ofrece " .. Util.money(o.amount), { size = 14, weight = W.bold }),
						Ui.text("por " .. (l and l.name or "—") .. (l and (" · tu precio " .. Util.money(l.price)) or "") .. (u and (" · margen " .. Util.money(o.amount - Util.round(o.amount * Catalog.RULES.feeRate) - u.cost)) or "") .. " · " .. o.status, { size = Ui.S.xs, color = T.mut }),
					}, 2)),
					o.status == "pendiente" and accept or nil,
					o.status == "pendiente" and Ui.button("Rechazar", "q", function()
						App.request("marketRejectOffer", { offerId = o.id })
					end, { small = true }) or nil,
				}, 8, { wrap = true }),
			}).Parent = main
		end
	else
		local filters: { Instance? } = { Sheet.search("mkt", "Buscar por nombre o vendedor") }
		if tab == "vehiculo" then
			table.insert(filters, Sheet.filter("mMode", "Modalidad", { { "todas", "Todas" }, { "directa", "Compra directa" }, { "subasta", "Subasta" } }, "todas"))
			local typeOpts = { { "todos", "Todos" } }
			for _, k in Util.keys(Catalog.TYPES) do
				table.insert(typeOpts, { k, Catalog.TYPES[k] })
			end
			table.insert(filters, Sheet.filter("mType", "Tipo", typeOpts, "todos"))
		end
		table.insert(filters, Sheet.filter("mRar", "Rareza", { { "todas", "Todas" }, { "Común", "Común" }, { "Rara", "Rara" }, { "Épica", "Épica" }, { "Legendaria", "Legendaria" } }, "todas"))
		table.insert(filters, Sheet.filter("mSort", "Orden", { { "precio", "Precio ↑" }, { "precio-d", "Precio ↓" }, { "nombre", "Nombre" }, { "fin", "Termina antes" } }, "precio"))
		Ui.row(filters, 8, { wrap = true }).Parent = main
		local mode = App.ui.filters.mMode or "todas"
		local ty = App.ui.filters.mType or "todos"
		local rar = App.ui.filters.mRar or "todas"
		local so = App.ui.filters.mSort or "precio"
		local list = {}
		for _, l in g.market.listings do
			local inTab = tab == "fav" and table.find(g.market.favorites, l.id) ~= nil or l.kind == tab
			local visible = l.status == "activa" or l.playerBid ~= nil or tab == "fav"
			local okVeh = tab ~= "vehiculo" or ((mode == "todas" or l.mode == mode) and (ty == "todos" or l.type == ty))
			if inTab and visible and okVeh and (rar == "todas" or l.rarity == rar) and Sheet.matches("mkt", l.name, l.seller) then
				table.insert(list, l)
			end
		end
		local function pr(l: any): number
			return l.mode == "subasta" and l.bid or l.price
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
			Ui.note("b", tab == "fav" and "No marcaste favoritos. Tocá el corazón de una publicación." or "No hay publicaciones con esos filtros.").Parent = main
		else
			local cards = {}
			for _, l in list do
				table.insert(cards, listingCard(g, l))
			end
			local cols = App.isPhone() and 1 or (App.layout == "tablet" and 2 or 3)
			local grid = Ui.new("Frame", { Name = "Grilla", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, List = { dir = "V", gap = 12 } })
			for i = 1, #cards, cols do
				local row = Ui.row({}, 12, { v = "T" })
				for j = i, math.min(i + cols - 1, #cards) do
					Ui.grow(cards[j], { Size = UDim2.new(1 / cols, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }).Parent = row
				end
				row.Parent = grid
			end
			grid.Parent = main
		end
	end

	-- Lateral
	local caps = g.derived.caps
	Ui.card({
		Ui.lbl("Tu capacidad"),
		Ui.line("Dinero", Util.money(g.money), { leftColor = T.mut }),
		Ui.line("Almacén", g.derived.warehouseUsed .. "/" .. caps.warehouse, { leftColor = T.mut }),
		Ui.line("Depósito de materiales", g.derived.matsUsed .. "/" .. caps.mats, { leftColor = T.mut }),
		Ui.text("Un vehículo comprado ocupa lugar del almacén; los materiales, del depósito. Una pieza entra a Mis autos › Piezas y cubre su costo de desarrollo al instalarla. Un plano se agrega como plantilla con la licencia del modelo pagada.", { size = Ui.S.xs, color = T.mut }),
	}, { gap = 4 }).Parent = side
end

return Screen
