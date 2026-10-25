--!strict
--[[
	Mercado simulado (V3: marketRefresh, marketTick, buyListing, publicaciones y ofertas).
	Vendedores y compradores son ficticios y viven dentro de cada partida: no hay comercio entre
	jugadores. Toda compra o venta usa las mismas reglas de dinero, impuesto, comisión y capacidad.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local DesignCalc = require(Shared.DesignCalc)
local Rules = require(Shared.Rules)
local GameState = require(script.Parent.GameState)
local Simulation = require(script.Parent.Simulation)

local round = Util.round
local money = Util.money

local Market = {}

local function pick(ctx: any, list: { any }): any
	return list[math.floor(ctx.rng() * #list) + 1]
end

function Market.total(l: any, amount: number?): any
	local p = amount or (l.mode == "subasta" and l.bid or l.price)
	local tax = round(p * Catalog.RULES.taxRate)
	local fee = round(p * Catalog.RULES.feeRate)
	return { price = p, tax = tax, fee = fee, total = p + tax + fee }
end

-- Renueva las publicaciones una vez por día de juego. Las subastas activas siguen hasta terminar.
function Market.refresh(g: any, ctx: any)
	local m = g.market
	if m.seedDay == g.time.day and #m.listings > 0 then
		return
	end
	m.seedDay = g.time.day
	local now = Rules.absMinute(g)
	local out = {}
	for _, l in m.listings do
		if l.status == "activa" and l.kind == "vehiculo" and l.mode == "subasta" and l.ends > now and #out < 4 then
			table.insert(out, l)
		end
	end
	local avail = {}
	for _, b in Catalog.BASES do
		if b.level <= g.level + 3 then
			table.insert(avail, b)
		end
	end
	for _ = 1, 8 do
		local b = pick(ctx, avail)
		local d = DesignCalc.newDraft(nil, b.id)
		d.name = b.name
		d.brand = b.brand
		d.paint.primary = pick(ctx, Catalog.PAINTS)[1]
		d.spoiler = ctx.rng() < 0.3
		d.quality = math.floor(ctx.rng() * 5)
		local c = DesignCalc.computeDesign(nil, d)
		local auction = ctx.rng() < 0.4
		local km = math.floor(ctx.rng() * 60) * 1000
		local cond = km < 5000 and "Nuevo" or (km < 30000 and "Excelente" or "Bueno")
		local condK = cond == "Nuevo" and 0.95 or (cond == "Excelente" and 0.85 or 0.72)
		local price = round(c.price * condK * (0.9 + ctx.rng() * 0.25) / 100) * 100
		table.insert(out, {
			id = GameState.uid(g, "l"), kind = "vehiculo", name = b.name, seller = pick(ctx, Catalog.NPC_SELLERS),
			spec = d, km = km, cond = cond, rarity = b.rarity, type = b.type, brand = b.brand, hp = c.hp,
			price = price, mode = auction and "subasta" or "directa",
			bid = auction and (round(price * 0.7 / 100) * 100) or nil, bids = auction and math.floor(ctx.rng() * 6) or 0,
			playerBid = nil, ends = now + (auction and (180 + math.floor(ctx.rng() * 600)) or 4000), status = "activa",
		})
	end
	for _, p in Catalog.PARTS do
		if p.unit > 0 and ctx.rng() >= 0.45 then
			table.insert(out, {
				id = GameState.uid(g, "l"), kind = "pieza", name = p.name, seller = pick(ctx, Catalog.NPC_SELLERS),
				part = { cat = p.cat, id = p.id }, rarity = p.rarity, price = round(p.unit * (0.9 + ctx.rng() * 0.4) / 10) * 10,
				mode = "directa", status = "activa", cond = "Nuevo", ends = now + 4000,
			})
		end
	end
	for i = 1, 6 do
		local b = Catalog.BASES[i]
		if ctx.rng() >= 0.5 then
			table.insert(out, {
				id = GameState.uid(g, "l"), kind = "diseno", name = "Plano: " .. b.name .. " tuneado", seller = pick(ctx, Catalog.NPC_SELLERS),
				baseId = b.id, rarity = b.rarity, price = round(b.dev * 0.6 / 100) * 100, mode = "directa", status = "activa", cond = "Plano", ends = now + 4000,
			})
		end
	end
	local off = Rules.has(g, "l2") and 0.9 or 1
	for _, mat in Catalog.MATERIALS do
		for _, qty in { 20, 60 } do
			table.insert(out, {
				id = GameState.uid(g, "l"), kind = "material", name = mat[2] .. " ×" .. qty, seller = "Proveedor mayorista",
				mat = mat[1], qty = qty, rarity = "Común", price = round(mat[3] * qty * off * (qty == 60 and 0.9 or 1)),
				mode = "directa", status = "activa", cond = "Nuevo", ends = now + 4000,
			})
		end
	end
	m.listings = out
	-- Los favoritos que ya no existen se quitan.
	local ids = {}
	for _, l in out do
		ids[l.id] = true
	end
	local favs = {}
	for _, id in m.favorites do
		if ids[id] then
			table.insert(favs, id)
		end
	end
	m.favorites = favs
end

function Market.find(g: any, id: any): any
	for _, l in g.market.listings do
		if l.id == id then
			return l
		end
	end
	return nil
end

function Market.buyCheck(g: any, l: any, amount: number?): string?
	local t = Market.total(l, amount)
	local caps = Rules.caps(g)
	if l.status ~= "activa" then
		return "La publicación ya no está disponible."
	end
	if g.money < t.total then
		return "Fondos insuficientes: necesitás " .. money(t.total) .. " y tenés " .. money(g.money) .. "."
	end
	if l.kind == "vehiculo" and Rules.warehouseUsed(g) >= caps.warehouse then
		return "Almacén lleno (" .. Rules.warehouseUsed(g) .. "/" .. caps.warehouse .. "). Vendé o enviá autos al salón."
	end
	if l.kind == "material" and Rules.matsUsed(g) + l.qty > caps.mats then
		return "No hay lugar para materiales (" .. Rules.matsUsed(g) .. "/" .. caps.mats .. ")."
	end
	return nil
end

-- Compra directa (o cobro de una subasta ganada). Nada se cobra si falla alguna condición.
function Market.buy(g: any, _ctx: any, id: any, auctionWin: boolean?): any
	local l = Market.find(g, id)
	if not l then
		return { ok = false, msg = "La publicación ya no existe (el mercado se renovó)." }
	end
	if l.mode == "subasta" and not auctionWin then
		return { ok = false, msg = "En una subasta tenés que ofertar." }
	end
	local amount = auctionWin and l.playerBid or l.price
	local err = Market.buyCheck(g, l, amount)
	if err then
		return { ok = false, msg = err }
	end
	local t = Market.total(l, amount)
	Simulation.spend(g, t.price, "compra", "Compra en el mercado: " .. l.name)
	Simulation.spend(g, t.tax, "impuesto", "Impuesto por " .. l.name)
	Simulation.spend(g, t.fee, "comision", "Comisión por " .. l.name)
	l.status = "vendida"
	if l.kind == "vehiculo" then
		local d = Util.deepCopy(l.spec)
		d.id = nil
		local c = DesignCalc.computeDesign(nil, d)
		g.counters.serial = (g.counters.serial or 0) + 1
		table.insert(g.units, {
			id = GameState.uid(g, "u"), serial = "MK-" .. string.format("%04d", g.counters.serial), designId = nil, designVersion = nil,
			name = l.name, type = l.type, spec = d, stats = c, cost = t.total, charged = { money = t.total, mats = {} },
			quality = c.quality, status = "almacen", price = round(t.price * 1.2 / 100) * 100, discount = 0,
			createdDay = g.time.day, bought = true, km = l.km, cond = l.cond,
		})
	elseif l.kind == "pieza" then
		local found = false
		for _, p in g.parts do
			if p.cat == l.part.cat and p.id == l.part.id then
				p.qty += 1
				found = true
			end
		end
		if not found then
			table.insert(g.parts, { cat = l.part.cat, id = l.part.id, qty = 1 })
		end
	elseif l.kind == "material" then
		g.materials[l.mat] = (g.materials[l.mat] or 0) + l.qty
	elseif l.kind == "diseno" then
		local d = DesignCalc.newDraft(g, l.baseId)
		d.id = GameState.uid(g, "d")
		d.name = Util.truncateChars(string.gsub(l.name, "^Plano: ", ""), 24)
		d.version = 1
		d.template = true
		d.spoiler = true
		d.parts.neumaticos = "sport"
		DesignCalc.fixParts(d)
		table.insert(g.designs, d)
		if not Util.contains(g.devPaid, "base:" .. l.baseId) then
			table.insert(g.devPaid, "base:" .. l.baseId)
		end
	end
	return { ok = true, msg = "Compraste " .. l.name .. " por " .. money(t.total) .. " (incluye impuesto y comisión)." }
end

function Market.bid(g: any, id: any, amount: any): any
	local l = Market.find(g, id)
	if not l or l.status ~= "activa" or l.mode ~= "subasta" then
		return { ok = false, msg = "La subasta ya terminó." }
	end
	if not Util.isFiniteNumber(amount) then
		return { ok = false, msg = "Ingresá un monto válido." }
	end
	local amt = round(amount / 100) * 100
	local min = l.bid + 100
	if amt < min then
		return { ok = false, msg = "La oferta mínima es " .. money(min) .. "." }
	end
	local t = Market.total(l, amt)
	if g.money < t.total then
		return { ok = false, msg = "No podés respaldar esa oferta: el total sería " .. money(t.total) .. "." }
	end
	l.playerBid = amt
	l.bid = amt
	l.bids += 1
	return { ok = true, msg = "Ofertaste " .. money(amt) .. ". Si nadie te supera, al terminar se cobra " .. money(t.total) .. "." }
end

function Market.publish(g: any, unitId: any, price: any, mode: any, hours: any): any
	local u = Simulation.findUnit(g, unitId)
	if not u or u.status ~= "almacen" then
		return { ok = false, msg = "La unidad ya no está en el almacén." }
	end
	if mode ~= "directa" and mode ~= "subasta" then
		return { ok = false, msg = "Modalidad inválida." }
	end
	if not Util.isFiniteNumber(price) then
		return { ok = false, msg = "Precio inválido." }
	end
	local p = round(price / 100) * 100
	if p < 100 or p > u.stats.price * 3 then
		return { ok = false, msg = "Precio inválido: usá entre $100 y " .. money(u.stats.price * 3) .. "." }
	end
	if mode == "subasta" and not Util.contains({ 3, 6, 12 }, hours) then
		return { ok = false, msg = "Duración inválida." }
	end
	u.status = "mercado"
	table.insert(g.market.mine, {
		id = GameState.uid(g, "m"), unitId = u.id, name = u.name .. " · " .. u.serial, price = p, mode = mode,
		bid = nil, bidder = nil, bids = 0, ends = Rules.absMinute(g) + (mode == "subasta" and hours * 60 or 1e9), status = "activa",
	})
	return { ok = true, msg = u.name .. " publicado " .. (mode == "subasta" and ("en subasta por " .. hours .. " h de juego.") or ("a " .. money(p) .. ".")) }
end

function Market.unpublish(g: any, unitId: any): any
	local u = Simulation.findUnit(g, unitId)
	if not u or u.status ~= "mercado" then
		return { ok = false, msg = "La unidad no está publicada." }
	end
	for _, l in g.market.mine do
		if l.unitId == u.id and l.status == "activa" then
			l.status = "retirada"
			for _, o in g.market.offers do
				if o.listingId == l.id and o.status == "pendiente" then
					o.status = "cancelada"
				end
			end
		end
	end
	u.status = "almacen"
	return { ok = true, msg = u.name .. " volvió al almacén." }
end

function Market.acceptOffer(g: any, ctx: any, offerId: any): any
	local o = nil
	for _, x in g.market.offers do
		if x.id == offerId then
			o = x
		end
	end
	if not o or o.status ~= "pendiente" then
		return { ok = false, msg = "La oferta ya no está disponible." }
	end
	local l = nil
	for _, x in g.market.mine do
		if x.id == o.listingId then
			l = x
		end
	end
	if not l or l.status ~= "activa" then
		o.status = "cancelada"
		return { ok = false, msg = "La publicación ya no está activa." }
	end
	local u = Simulation.findUnit(g, l.unitId)
	local r = Simulation.sellUnit(g, ctx, l.unitId, o.amount, "mercado", o.from, { fee = round(o.amount * Catalog.RULES.feeRate), listPrice = u and u.price, offer = o.amount })
	if r.ok then
		o.status = "aceptada"
		l.status = "vendida"
		for _, x in g.market.offers do
			if x.listingId == l.id and x.status == "pendiente" then
				x.status = "cancelada"
			end
		end
	end
	return r
end

function Market.rejectOffer(g: any, offerId: any): any
	for _, o in g.market.offers do
		if o.id == offerId and o.status == "pendiente" then
			o.status = "rechazada"
			return { ok = true, msg = "Oferta rechazada." }
		end
	end
	return { ok = false, msg = "La oferta ya no está disponible." }
end

function Market.toggleFavorite(g: any, id: any): any
	if not Market.find(g, id) then
		return { ok = false, msg = "La publicación ya no existe." }
	end
	local favs = g.market.favorites
	local i = table.find(favs, id)
	if i then
		table.remove(favs, i)
	else
		table.insert(favs, id)
	end
	return { ok = true, quiet = true }
end

-- Subastas y compradores ficticios (cada paso de simulación).
function Market.tick(g: any, ctx: any)
	local now = Rules.absMinute(g)
	for _, l in g.market.listings do
		if l.status == "activa" and l.mode == "subasta" then
			if now >= l.ends then
				if l.playerBid and l.playerBid >= l.bid then
					local r = Market.buy(g, ctx, l.id, true)
					l.status = r.ok and "ganada" or "perdida"
					Simulation.notify(g, ctx, r.ok and "ok" or "aviso", r.ok and ("Ganaste la subasta de " .. l.name) or ("Perdiste la subasta: " .. r.msg), "mercado")
				else
					l.status = "cerrada"
				end
			elseif ctx.rng() < 0.02 then
				local inc = round(l.bid * 0.05 / 100) * 100 + 100
				if l.bid + inc <= l.price * 1.15 then
					local wasLeading = l.playerBid ~= nil and l.playerBid >= l.bid
					l.bid += inc
					l.bids += 1
					if wasLeading then
						Simulation.notify(g, ctx, "aviso", "Te superaron en la subasta de " .. l.name, "mercado")
					end
				end
			end
		end
	end
	for _, l in g.market.mine do
		if l.status == "activa" then
			local u = Simulation.findUnit(g, l.unitId)
			if not u or u.status ~= "mercado" then
				l.status = "cancelada"
			else
				local ratio = l.price / u.stats.price
				if l.mode == "subasta" then
					if now >= l.ends then
						if l.bid then
							local r = Simulation.sellUnit(g, ctx, u.id, l.bid, "mercado", l.bidder, { fee = round(l.bid * Catalog.RULES.feeRate), listPrice = l.price, offer = l.bid })
							l.status = r.ok and "vendida" or "cancelada"
							Simulation.notify(g, ctx, "ok", "Subasta terminada: vendiste " .. u.name .. " por " .. money(l.bid), "mercado")
						else
							l.status = "sin ofertas"
							u.status = "almacen"
							Simulation.notify(g, ctx, "aviso", "Tu subasta de " .. u.name .. " terminó sin ofertas.", "mercado")
						end
					elseif ctx.rng() < 0.03 then
						local b = round((l.bid or l.price) * 1.05 / 100) * 100
						if b <= u.stats.price * 1.2 then
							l.bid = b
							l.bidder = pick(ctx, Catalog.NPC_SELLERS)
							l.bids += 1
						end
					end
				else
					if ctx.rng() < 0.012 * Util.clamp(1.6 - ratio, 0.05, 1.2) then
						local buyer = pick(ctx, Catalog.NPC_SELLERS)
						local r = Simulation.sellUnit(g, ctx, u.id, l.price, "mercado", buyer, { fee = round(l.price * Catalog.RULES.feeRate), listPrice = l.price })
						if r.ok then
							l.status = "vendida"
							Simulation.notify(g, ctx, "ok", "Vendiste " .. u.name .. " en el mercado por " .. money(l.price), "mercado")
						end
					elseif ctx.rng() < 0.01 then
						local pending = false
						for _, o in g.market.offers do
							if o.listingId == l.id and o.status == "pendiente" then
								pending = true
							end
						end
						if not pending then
							table.insert(g.market.offers, {
								id = GameState.uid(g, "of"), listingId = l.id, from = pick(ctx, Catalog.NPC_SELLERS),
								amount = round(l.price * (0.85 + ctx.rng() * 0.1) / 100) * 100, status = "pendiente",
							})
							Simulation.notify(g, ctx, "info", "Recibiste una oferta por " .. u.name, "mercado")
						end
					end
				end
			end
		end
	end
	-- Limpieza de historiales del mercado.
	while #g.market.offers > 40 do
		table.remove(g.market.offers, 1)
	end
	while #g.market.mine > 40 do
		local removed = false
		for i, l in g.market.mine do
			if l.status ~= "activa" then
				table.remove(g.market.mine, i)
				removed = true
				break
			end
		end
		if not removed then
			break
		end
	end
end

return Market
