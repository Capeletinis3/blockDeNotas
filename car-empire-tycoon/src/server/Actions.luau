--!strict
--[[
	Acciones que pide el jugador. Todas validan contra la partida del servidor:
	el cliente solo envía identificadores y valores elegidos; precios, costos y propiedad
	se calculan aquí. Cada acción devuelve { ok, msg, ... } y no cambia nada si falla.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local DesignCalc = require(Shared.DesignCalc)
local GameState = require(script.Parent.GameState)
local Simulation = require(script.Parent.Simulation)

local money = Util.money
local round = Util.round

local Actions = {}

local function fail(msg: string): any
	return { ok = false, msg = msg }
end

local function findById(list: { any }, id: any): (any, number?)
	if type(id) ~= "string" then
		return nil, nil
	end
	for i, x in list do
		if x.id == id then
			return x, i
		end
	end
	return nil, nil
end

-- Empresa ---------------------------------------------------------------------

function Actions.validateCompany(payload: any): (any?, string?)
	if type(payload) ~= "table" or type(payload.name) ~= "string" then
		return nil, "Falta el nombre de la empresa."
	end
	local name = Util.trim(payload.name)
	local n = Util.charCount(name)
	if n < 3 or n > 24 then
		return nil, "Usá entre 3 y 24 caracteres para el nombre."
	end
	if string.find(name, "[%c<>&]") then
		return nil, "El nombre tiene caracteres no permitidos."
	end
	if not Catalog.isBrandColor(payload.color) then
		return nil, "Elegí un color de marca de la lista."
	end
	local difficulty = payload.difficulty
	if difficulty == nil then
		difficulty = "normal"
	end
	if not Catalog.DIFFICULTIES[difficulty] then
		return nil, "Dificultad desconocida."
	end
	return { name = name, color = payload.color, difficulty = difficulty }, nil
end

-- Diseños ---------------------------------------------------------------------

--[[
	Guarda un diseño (nuevo o una nueva versión de uno existente).
	El desarrollo se cobra una sola vez por empresa y por ítem (licencia del modelo o prototipo de pieza):
	las claves pagadas quedan en g.devPaid y nunca se vuelven a cobrar.
	payload = { draft = <borrador>, sourceId = <id del diseño que se edita o nil> }
]]
function Actions.saveDesign(g: any, ctx: any, payload: any): any
	if type(payload) ~= "table" then
		return fail("Solicitud inválida.")
	end
	local d, err = DesignCalc.sanitize(g, payload.draft)
	if not d then
		return fail(err or "El diseño no es válido.")
	end
	local source = nil
	if payload.sourceId ~= nil then
		source = findById(g.designs, payload.sourceId)
		if not source then
			return fail("El diseño que estabas editando ya no existe.")
		end
		if DesignCalc.sameSpec(source, d) then
			return fail("No hay cambios para guardar.")
		end
	elseif #g.designs >= Catalog.RULES.maxDesigns then
		return fail("Llegaste al máximo de " .. Catalog.RULES.maxDesigns .. " diseños.")
	end

	local items = DesignCalc.devItems(g, d)
	local cash = 0
	for _, it in items do
		if not it.paid then
			cash += it.cost
		end
	end
	if g.money < cash then
		return fail("Fondos insuficientes: el desarrollo cuesta " .. money(cash) .. " y tenés " .. money(g.money) .. ".")
	end
	for _, it in items do
		if not it.paid then
			Simulation.spend(g, it.cost, "desarrollo", it.label)
			table.insert(g.devPaid, it.key)
		end
	end

	local first = source == nil
	if first then
		d.id = GameState.uid(g, "d")
		d.version = 1
		d.createdDay = g.time.day
		table.insert(g.designs, d)
		g.counters.designsSaved += 1
		Simulation.addXp(g, ctx, 200)
	else
		d.id = source.id
		d.version = (source.version or 1) + 1
		d.createdDay = source.createdDay
		local _, i = findById(g.designs, source.id)
		g.designs[i :: number] = d
	end
	d.updatedDay = g.time.day
	return {
		ok = true,
		msg = "Diseño guardado: «" .. d.name .. "» v" .. d.version .. (cash > 0 and (" · desarrollo pagado " .. money(cash)) or " · sin costo de desarrollo pendiente"),
		designId = d.id,
		version = d.version,
		paid = cash,
	}
end

-- Producción -------------------------------------------------------------------

-- payload = { designId, qty }
function Actions.createOrder(g: any, _ctx: any, payload: any): any
	if type(payload) ~= "table" then
		return fail("Solicitud inválida.")
	end
	local d = findById(g.designs, payload.designId)
	if not d then
		return fail("El diseño no existe.")
	end
	local qty = payload.qty
	if not Util.isFiniteNumber(qty) or qty ~= math.floor(qty) or qty < 1 or qty > Catalog.RULES.maxQty then
		return fail("La cantidad debe estar entre 1 y " .. Catalog.RULES.maxQty .. ".")
	end
	if #g.production.orders >= 10 then
		return fail("La cola ya tiene 10 órdenes. Esperá a que avance o cancelá alguna.")
	end
	local snap = Simulation.designSnapshot(g, d)
	local order = {
		id = GameState.uid(g, "o"),
		designId = d.id,
		design = snap,
		qty = qty,
		done = 0,
		line = 1,
		paused = false,
		status = "en cola",
		reason = "",
		progress = 0,
		unitStarted = false,
		cur = nil,
		created = GameState.absMinute(g),
	}
	table.insert(g.production.orders, order)
	g.counters.ordersCreated = (g.counters.ordersCreated or 0) + 1
	return {
		ok = true,
		msg = "Orden creada: " .. qty .. " × " .. d.name .. " v" .. snap.version .. ". La orden queda fijada a esa versión y a " .. money(snap.calc.unitCost) .. " por unidad.",
		orderId = order.id,
	}
end

-- Cancela una orden. La unidad en curso devuelve exactamente lo cobrado al empezarla.
function Actions.cancelOrder(g: any, _ctx: any, payload: any): any
	local o, i = findById(g.production.orders, type(payload) == "table" and payload.orderId or nil)
	if not o then
		return fail("La orden ya no existe.")
	end
	local refund = 0
	if o.unitStarted and o.cur then
		for k, n in o.cur.mats do
			g.materials[k] = (g.materials[k] or 0) + n
		end
		refund = o.cur.charged
		Simulation.earn(g, refund, "reintegro", "Reintegro por cancelar " .. o.design.name .. " v" .. o.design.version)
	end
	table.remove(g.production.orders, i)
	return { ok = true, msg = "Orden cancelada" .. (refund > 0 and (": se reintegraron " .. money(refund) .. " y los materiales de la unidad en curso.") or ".") }
end

function Actions.togglePause(g: any, _ctx: any, payload: any): any
	local o = findById(g.production.orders, type(payload) == "table" and payload.orderId or nil)
	if not o then
		return fail("La orden ya no existe.")
	end
	o.paused = not o.paused
	o.status = o.paused and "pausada" or "en cola"
	return { ok = true, msg = o.paused and "Orden pausada." or "Orden reanudada." }
end

function Actions.supplierPrice(mat: string, qty: number): any
	local m = Catalog.material(mat)
	local base = round(m[3] * qty)
	local tax = round(base * Catalog.RULES.taxRate)
	return { base = base, tax = tax, total = base + tax }
end

-- Compra de materiales al proveedor (precio + impuesto), con tope del depósito.
function Actions.buyMaterial(g: any, _ctx: any, payload: any): any
	if type(payload) ~= "table" or not Catalog.material(payload.mat) then
		return fail("Material desconocido.")
	end
	local qty = payload.qty
	if not Util.contains(Catalog.SUPPLIER_PACKS, qty) then
		return fail("Cantidad no disponible en el proveedor.")
	end
	local caps = GameState.caps(g)
	if GameState.matsUsed(g) + qty > caps.mats then
		return fail("No hay lugar para materiales (" .. GameState.matsUsed(g) .. "/" .. caps.mats .. ").")
	end
	local p = Actions.supplierPrice(payload.mat, qty)
	if g.money < p.total then
		return fail("Fondos insuficientes: necesitás " .. money(p.total) .. ".")
	end
	local label = string.lower(Catalog.matLabel(payload.mat))
	Simulation.spend(g, p.base, "materiales", "Compra de " .. qty .. " de " .. label)
	Simulation.spend(g, p.tax, "impuesto", "Impuesto por " .. qty .. " de " .. label)
	g.materials[payload.mat] = (g.materials[payload.mat] or 0) + qty
	for _, o in g.production.orders do
		if o.status == "detenida" and o.missing then
			o.status = "en cola"
			o.reason = ""
		end
	end
	return { ok = true, msg = "Compraste " .. qty .. " de " .. label .. " por " .. money(p.total) .. " (incluye impuesto)." }
end

-- Inventario y concesionario -------------------------------------------------------

function Actions.sendToShowroom(g: any, _ctx: any, payload: any): any
	local u = findById(g.units, type(payload) == "table" and payload.unitId or nil)
	if not u then
		return fail("La unidad no existe.")
	end
	if u.status ~= "almacen" then
		return fail("La unidad no está en el almacén.")
	end
	local caps = GameState.caps(g)
	if GameState.showroomUsed(g) >= caps.showroom then
		return fail("Salón lleno (" .. GameState.showroomUsed(g) .. "/" .. caps.showroom .. ").")
	end
	u.status = "salon"
	g.counters.sentToShowroom += 1
	return { ok = true, msg = u.name .. " (" .. u.serial .. ") está en el salón. Los clientes empezarán a llegar." }
end

function Actions.returnToWarehouse(g: any, _ctx: any, payload: any): any
	local u = findById(g.units, type(payload) == "table" and payload.unitId or nil)
	if not u or u.status ~= "salon" then
		return fail("La unidad no está en el salón.")
	end
	local caps = GameState.caps(g)
	if GameState.warehouseUsed(g) + GameState.inProgress(g) >= caps.warehouse then
		return fail("Almacén lleno.")
	end
	u.status = "almacen"
	return { ok = true, msg = u.name .. " volvió al almacén." }
end

local function offerContext(g: any, payload: any): (any, any, string?)
	local c = findById(g.customers, type(payload) == "table" and payload.customerId or nil)
	if not c or c.state ~= "oferta" then
		return nil, nil, "La oferta ya no está disponible."
	end
	local u = Simulation.findUnit(g, c.unitId)
	if not u or u.status ~= "salon" then
		return nil, nil, "El auto ya no está en el salón."
	end
	return c, u, nil
end

function Actions.acceptOffer(g: any, ctx: any, payload: any): any
	local c, u, err = offerContext(g, payload)
	if err then
		return fail(err)
	end
	local r = Simulation.sellUnit(g, ctx, u.id, c.offer, "concesionario", c.name)
	if r.ok then
		c.state = "compró"
		c.unitId = u.id
	end
	return r
end

-- payload = { customerId, amount }. Tirada del servidor contra la probabilidad mostrada.
function Actions.counterOffer(g: any, ctx: any, payload: any): any
	local c, u, err = offerContext(g, payload)
	if err then
		return fail(err)
	end
	local amount = payload.amount
	if not Util.isFiniteNumber(amount) then
		return fail("Ingresá un monto válido.")
	end
	amount = round(amount / 100) * 100
	if amount <= 0 then
		return fail("Ingresá un monto válido.")
	end
	if amount <= c.offer then
		return fail("Tu contraoferta tiene que superar su oferta; si te sirve, aceptala directamente.")
	end
	local chance = Simulation.counterChance(c, amount)
	local roll = math.floor(ctx.rng() * 100)
	if roll < chance then
		local r = Simulation.sellUnit(g, ctx, u.id, amount, "concesionario", c.name)
		if r.ok then
			c.state = "compró"
			r.msg = c.name .. " aceptó tu contraoferta (probabilidad " .. chance .. "%, tirada " .. roll .. "). " .. r.msg
		end
		r.chance = chance
		r.roll = roll
		return r
	end
	c.rounds += 1
	c.waited += 45
	if c.rounds >= 3 or c.waited >= c.patience then
		c.state = "se fue"
		c.leftAt = GameState.absMinute(g)
		return { ok = true, sold = false, chance = chance, roll = roll, msg = c.name .. " rechazó " .. money(amount) .. " (probabilidad " .. chance .. "%, tirada " .. roll .. ") y se fue. No se vendió nada." }
	end
	local newOffer = math.min(c.budget, round((c.offer * 0.6 + amount * 0.4) / 100) * 100)
	c.offer = math.max(c.offer, newOffer)
	return { ok = true, sold = false, chance = chance, roll = roll, msg = c.name .. " rechazó " .. money(amount) .. " (probabilidad " .. chance .. "%, tirada " .. roll .. "). Nueva oferta: " .. money(c.offer) .. "." }
end

function Actions.rejectCustomer(g: any, _ctx: any, payload: any): any
	local c = findById(g.customers, type(payload) == "table" and payload.customerId or nil)
	if not c or c.state == "se fue" or c.state == "compró" then
		return fail("El cliente ya no está.")
	end
	c.state = "se fue"
	c.leftAt = GameState.absMinute(g)
	return { ok = true, msg = c.name .. " se fue. No se vendió nada." }
end

function Actions.setSpeed(g: any, _ctx: any, payload: any): any
	local v = type(payload) == "table" and payload.speed or nil
	if not Util.contains(Catalog.RULES.speeds, v) then
		return fail("Velocidad inválida.")
	end
	g.time.speed = v
	return { ok = true, msg = v == 0 and "Simulación en pausa." or ("Velocidad " .. v .. "×."), quiet = true }
end

Actions.handlers = {
	saveDesign = Actions.saveDesign,
	createOrder = Actions.createOrder,
	cancelOrder = Actions.cancelOrder,
	togglePause = Actions.togglePause,
	buyMaterial = Actions.buyMaterial,
	sendToShowroom = Actions.sendToShowroom,
	returnToWarehouse = Actions.returnToWarehouse,
	acceptOffer = Actions.acceptOffer,
	counterOffer = Actions.counterOffer,
	rejectCustomer = Actions.rejectCustomer,
	setSpeed = Actions.setSpeed,
}

-- Acciones que justifican guardar enseguida (además del autoguardado periódico).
Actions.important = {
	saveDesign = true,
	createOrder = true,
	acceptOffer = true,
	counterOffer = true,
	buyMaterial = true,
}

return Actions
