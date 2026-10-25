--!strict
--[[
	Acciones que pide el jugador sobre su empresa activa. Todas validan contra la partida del servidor:
	el cliente solo envía identificadores y valores elegidos; precios, costos, capacidad y propiedad
	se calculan aquí. Cada acción devuelve { ok, msg, ... } y no cambia nada si falla.
	ctx = { rng, notify, today = "AAAA-MM-DD", yesterday = "AAAA-MM-DD" }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local DesignCalc = require(Shared.DesignCalc)
local Rules = require(Shared.Rules)
local GameState = require(script.Parent.GameState)
local Simulation = require(script.Parent.Simulation)
local Market = require(script.Parent.Market)

local money = Util.money
local round = Util.round

local Actions = {}

local function fail(msg: string): any
	return { ok = false, msg = msg }
end

local function arg(payload: any, key: string): any
	return type(payload) == "table" and payload[key] or nil
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

local function isInt(v: any, lo: number, hi: number): boolean
	return Util.isFiniteNumber(v) and v == math.floor(v) and v >= lo and v <= hi
end

-- Empresa ------------------------------------------------------------------------------

function Actions.validateName(raw: any, minLen: number): (string?, string?)
	if type(raw) ~= "string" then
		return nil, "Falta el nombre."
	end
	local name = Util.trim(raw)
	local n = Util.charCount(name)
	if n < minLen or n > 24 then
		return nil, "Usá entre " .. minLen .. " y 24 caracteres para el nombre."
	end
	if string.find(name, "[%c<>&]") then
		return nil, "El nombre tiene caracteres no permitidos."
	end
	return name, nil
end

function Actions.validateCompany(payload: any): (any?, string?)
	if type(payload) ~= "table" then
		return nil, "Faltan los datos de la empresa."
	end
	local name, err = Actions.validateName(payload.name, 3)
	if not name then
		return nil, err
	end
	-- Color, logo y dificultad tienen valores por defecto: alcanza con escribir un nombre válido.
	local color = payload.color
	if color == nil then
		color = Catalog.BRAND_COLORS[1][1]
	end
	if not Catalog.isBrandColor(color) then
		return nil, "Elegí un color de marca de la lista."
	end
	local logo = payload.logo
	if logo == nil then
		logo = "pico"
	end
	if not Catalog.isLogo(logo) then
		return nil, "Logotipo desconocido."
	end
	local difficulty = payload.difficulty
	if difficulty == nil then
		difficulty = "normal"
	end
	if not Catalog.DIFFICULTIES[difficulty] then
		return nil, "Dificultad desconocida."
	end
	return { name = name, color = color, logo = logo, difficulty = difficulty }, nil
end

function Actions.setIdentity(g: any, _ctx: any, payload: any): any
	local color, logo = arg(payload, "color"), arg(payload, "logo")
	if color ~= nil and not Catalog.isBrandColor(color) then
		return fail("Color de marca inválido.")
	end
	if logo ~= nil and not Catalog.isLogo(logo) then
		return fail("Logotipo desconocido.")
	end
	g.company.color = color or g.company.color
	g.company.logo = logo or g.company.logo
	return { ok = true, msg = "Identidad actualizada.", quiet = true }
end

function Actions.expandSede(g: any, ctx: any, _payload: any): any
	local next = Rules.nextSede(g)
	if not next then
		return fail("Ya tenés la sede máxima.")
	end
	for _, check in Rules.expandChecks(g) do
		if not check[1] then
			return fail("Faltan requisitos para ampliar: " .. check[2] .. ".")
		end
	end
	if not Simulation.spend(g, next.cost, "sede", "Ampliación a " .. next.name) then
		return fail("Fondos insuficientes.")
	end
	g.sede += 1
	g.counters.sedeLevel = g.sede
	Simulation.addXp(g, ctx, 500)
	Simulation.notify(g, ctx, "ok", "¡Nueva sede: " .. next.name .. "!", "compania")
	return { ok = true, msg = "Ampliaste a «" .. next.name .. "»: " .. next.lines .. " líneas, almacén " .. next.warehouse .. ", salón " .. next.showroom .. ", " .. next.staff .. " empleados." }
end

-- Diseños -------------------------------------------------------------------------------

local function nameTaken(g: any, name: string, exceptId: string?): boolean
	local lower = string.lower(name)
	for _, d in g.designs do
		if d.id ~= exceptId and not d.template and string.lower(d.name) == lower then
			return true
		end
	end
	return false
end

--[[
	Guarda un diseño (nuevo o una nueva versión). El desarrollo se cobra una sola vez por empresa y por
	ítem (licencia del modelo o prototipo de pieza); una pieza del inventario cubre su prototipo.
	payload = { draft, sourceId = id del diseño que se edita o nil, template = true para guardar plantilla }
]]
function Actions.saveDesign(g: any, ctx: any, payload: any): any
	if type(payload) ~= "table" then
		return fail("Solicitud inválida.")
	end
	local d, err = DesignCalc.sanitize(g, payload.draft)
	if not d then
		return fail(err or "El diseño no es válido.")
	end
	if payload.template == true then
		if #g.designs >= Catalog.RULES.maxDesigns then
			return fail("Llegaste al máximo de " .. Catalog.RULES.maxDesigns .. " diseños y plantillas.")
		end
		d.id = GameState.uid(g, "d")
		d.template = true
		d.version = 1
		d.name = Util.truncateChars(d.name, 13) .. " (plantilla)"
		d.createdDay = g.time.day
		table.insert(g.designs, d)
		return { ok = true, msg = "Plantilla guardada: «" .. d.name .. "». No se cobra desarrollo hasta usarla en un diseño.", designId = d.id, version = 1 }
	end
	local source = nil
	if payload.sourceId ~= nil then
		source = findById(g.designs, payload.sourceId)
		if not source or source.template then
			return fail("El diseño que estabas editando ya no existe. Guardalo como proyecto nuevo.")
		end
		if DesignCalc.sameSpec(source, d) then
			return fail("No hay cambios para guardar.")
		end
	elseif #g.designs >= Catalog.RULES.maxDesigns then
		return fail("Llegaste al máximo de " .. Catalog.RULES.maxDesigns .. " diseños.")
	end
	if nameTaken(g, d.name, source and source.id or nil) then
		return fail("Ya tenés otro diseño llamado «" .. d.name .. "». Elegí un nombre distinto.")
	end

	local items = DesignCalc.devItems(g, d)
	local cash = 0
	for _, it in items do
		if not it.paid and not it.stock then
			cash += it.cost
		end
	end
	if g.money < cash then
		return fail("Fondos insuficientes: el desarrollo cuesta " .. money(cash) .. " y tenés " .. money(g.money) .. ".")
	end
	for _, it in items do
		if not it.paid then
			if it.stock then
				for i, p in g.parts do
					if p.cat == it.cat and p.id == it.part then
						p.qty -= 1
						if p.qty <= 0 then
							table.remove(g.parts, i)
						end
						break
					end
				end
			else
				Simulation.spend(g, it.cost, "desarrollo", it.label)
			end
			table.insert(g.devPaid, it.key)
		end
	end

	if source == nil then
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
	d.template = nil
	d.updatedDay = g.time.day
	return {
		ok = true,
		msg = "Diseño guardado: «" .. d.name .. "» v" .. d.version .. (cash > 0 and (" · desarrollo pagado " .. money(cash)) or " · sin costo de desarrollo pendiente"),
		designId = d.id,
		version = d.version,
		paid = cash,
	}
end

function Actions.dupDesign(g: any, _ctx: any, payload: any): any
	local d = findById(g.designs, arg(payload, "designId"))
	if not d then
		return fail("El diseño ya no existe.")
	end
	if #g.designs >= Catalog.RULES.maxDesigns then
		return fail("Llegaste al máximo de " .. Catalog.RULES.maxDesigns .. " diseños.")
	end
	local base = Util.truncateChars(d.name, 18) .. " copia"
	local name = base
	local n = 2
	while nameTaken(g, name, nil) do
		name = Util.truncateChars(d.name, 16) .. " copia " .. n
		n += 1
	end
	local copy = Util.deepCopy(d)
	copy.id = GameState.uid(g, "d")
	copy.name = name
	copy.version = 1
	copy.createdDay = g.time.day
	table.insert(g.designs, copy)
	return { ok = true, msg = "Duplicado: «" .. name .. "». No se cobra desarrollo (ya estaba pagado).", designId = copy.id }
end

-- Eliminar un proyecto no toca unidades fabricadas ni órdenes: cada una tiene su copia.
function Actions.delDesign(g: any, _ctx: any, payload: any): any
	local d, i = findById(g.designs, arg(payload, "designId"))
	if not d then
		return fail("El diseño ya no existe.")
	end
	table.remove(g.designs, i :: number)
	local active = 0
	for _, o in g.production.orders do
		if o.designId == d.id then
			active += 1
		end
	end
	return { ok = true, msg = "Diseño eliminado." .. (active > 0 and (" Sus " .. active .. " orden(es) siguen con su propia copia.") or "") }
end

-- Producción ----------------------------------------------------------------------------

local function bestLine(g: any): number
	local lines = Rules.caps(g).lines
	local best, bn = 1, math.huge
	for l = 1, lines do
		local n = 0
		for _, o in g.production.orders do
			if o.line == l then
				n += 1
			end
		end
		if n < bn then
			best, bn = l, n
		end
	end
	return best
end

local function validLinePrio(g: any, line: any, priority: any): (number?, string?, string?)
	local lines = Rules.caps(g).lines
	local l = line
	if l == nil then
		l = bestLine(g)
	end
	if not isInt(l, 1, lines) then
		return nil, nil, "Línea inválida (tenés " .. lines .. ")."
	end
	local p = priority or "media"
	if GameState.PRIORITIES[p] == nil then
		return nil, nil, "Prioridad inválida."
	end
	return l, p, nil
end

-- payload = { designId, qty, line?, priority? }
function Actions.createOrder(g: any, _ctx: any, payload: any): any
	local d = findById(g.designs, arg(payload, "designId"))
	if not d then
		return fail("El diseño no existe.")
	end
	if d.template then
		return fail("Las plantillas no se fabrican: usala para crear un diseño.")
	end
	local qty = arg(payload, "qty")
	if not isInt(qty, 1, Catalog.RULES.maxQty) then
		return fail("La cantidad debe estar entre 1 y " .. Catalog.RULES.maxQty .. ".")
	end
	local line, prio, err = validLinePrio(g, arg(payload, "line"), arg(payload, "priority"))
	if err then
		return fail(err)
	end
	if #g.production.orders >= Catalog.RULES.maxOrders then
		return fail("La cola ya tiene " .. Catalog.RULES.maxOrders .. " órdenes. Esperá a que avance o cancelá alguna.")
	end
	local snap = Simulation.designSnapshot(g, d)
	local order = Simulation.makeOrder(g, snap, qty, line :: number, prio :: string)
	table.insert(g.production.orders, order)
	Simulation.sortOrders(g)
	g.counters.ordersCreated = (g.counters.ordersCreated or 0) + 1
	return {
		ok = true,
		msg = "Orden creada: " .. qty .. " × " .. d.name .. " v" .. snap.version .. " en la línea " .. line .. ". Queda fijada a esa versión y a " .. money(snap.calc.unitCost) .. " por unidad.",
		orderId = order.id,
	}
end

-- Repite una orden terminada: «same» = la misma versión guardada en el historial; «latest» = la última
-- versión guardada del proyecto (si todavía existe).
function Actions.repeatOrder(g: any, _ctx: any, payload: any): any
	local h = findById(g.production.history, arg(payload, "historyId"))
	if not h or not h.design then
		return fail("Esa orden no se puede repetir (no tiene la copia del diseño).")
	end
	local mode = arg(payload, "mode")
	local snap
	if mode == "latest" then
		local d = findById(g.designs, h.design.id)
		if not d or d.template then
			return fail("El proyecto ya no existe: repetí la misma versión.")
		end
		snap = Simulation.designSnapshot(g, d)
	elseif mode == "same" then
		snap = Util.deepCopy(h.design)
	else
		return fail("Modo de repetición inválido.")
	end
	if #g.production.orders >= Catalog.RULES.maxOrders then
		return fail("La cola está llena.")
	end
	local lines = Rules.caps(g).lines
	local o = Simulation.makeOrder(g, snap, h.qty, math.clamp(h.line or 1, 1, lines), h.priority or "media")
	table.insert(g.production.orders, o)
	Simulation.sortOrders(g)
	g.counters.ordersCreated = (g.counters.ordersCreated or 0) + 1
	return { ok = true, msg = "Orden repetida: " .. h.qty .. " × «" .. snap.name .. "» v" .. snap.version .. (mode == "latest" and " (última versión guardada)." or " (misma versión que la original)."), orderId = o.id }
end

-- Cancela una orden. La unidad en curso devuelve exactamente lo cobrado y consumido al empezarla.
function Actions.cancelOrder(g: any, _ctx: any, payload: any): any
	local o, i = findById(g.production.orders, arg(payload, "orderId"))
	if not o then
		return fail("La orden ya no existe.")
	end
	local refund = 0
	if o.unitStarted and o.cur then
		-- El depósito ya contaba estos materiales como «en fabricación»: vuelven sin exceder la capacidad.
		for k, n in o.cur.mats do
			g.materials[k] = (g.materials[k] or 0) + n
		end
		refund = o.cur.charged
		Simulation.earn(g, refund, "reintegro", "Reintegro por cancelar " .. o.design.name .. " v" .. o.design.version)
	end
	table.remove(g.production.orders, i :: number)
	return { ok = true, msg = "Orden cancelada" .. (refund > 0 and (": se reintegraron " .. money(refund) .. " y los materiales de la unidad en curso.") or ".") }
end

function Actions.togglePause(g: any, _ctx: any, payload: any): any
	local o = findById(g.production.orders, arg(payload, "orderId"))
	if not o then
		return fail("La orden ya no existe.")
	end
	o.paused = not o.paused
	o.status = o.paused and "pausada" or "en cola"
	o.reason = ""
	o.missing = nil
	return { ok = true, msg = o.paused and "Orden pausada." or "Orden reanudada.", quiet = true }
end

function Actions.setPriority(g: any, _ctx: any, payload: any): any
	local o = findById(g.production.orders, arg(payload, "orderId"))
	local p = arg(payload, "priority")
	if not o then
		return fail("La orden ya no existe.")
	end
	if GameState.PRIORITIES[p] == nil then
		return fail("Prioridad inválida.")
	end
	o.priority = p
	Simulation.sortOrders(g)
	return { ok = true, quiet = true }
end

function Actions.setLine(g: any, _ctx: any, payload: any): any
	local o = findById(g.production.orders, arg(payload, "orderId"))
	local line = arg(payload, "line")
	if not o then
		return fail("La orden ya no existe.")
	end
	if o.unitStarted then
		return fail("La unidad en curso no puede cambiar de línea.")
	end
	if not isInt(line, 1, Rules.caps(g).lines) then
		return fail("Línea inválida.")
	end
	o.line = line
	o.pos = Rules.absMinute(g) + #g.production.orders / 100
	Simulation.sortOrders(g)
	return { ok = true, quiet = true }
end

-- Reordena dentro de la misma línea respetando la prioridad (regla de la V3). delta = -n / +n.
function Actions.moveOrder(g: any, _ctx: any, payload: any): any
	local o = findById(g.production.orders, arg(payload, "orderId"))
	local delta = arg(payload, "delta")
	if not o then
		return fail("La orden ya no existe.")
	end
	if not isInt(delta, -Catalog.RULES.maxOrders, Catalog.RULES.maxOrders) or delta == 0 then
		return fail("Movimiento inválido.")
	end
	Simulation.sortOrders(g)
	local list = {}
	for _, x in g.production.orders do
		if x.line == o.line then
			table.insert(list, x)
		end
	end
	local i = table.find(list, o) :: number
	local j = math.clamp(i + delta, 1, #list)
	if j == i then
		return { ok = true, quiet = true }
	end
	local step = j > i and 1 or -1
	for k = i + step, j, step do
		local t = list[k]
		if t.priority ~= o.priority then
			return fail("La cola respeta la prioridad: para pasar " .. (step < 0 and "delante" or "detrás") .. " de una orden de prioridad " .. t.priority .. ", cambiá la prioridad.")
		end
	end
	-- Intercambios sucesivos de posición.
	local cur = i
	while cur ~= j do
		local nxt = cur + step
		local a, b = list[cur], list[nxt]
		a.pos, b.pos = b.pos, a.pos
		list[cur], list[nxt] = b, a
		cur = nxt
	end
	Simulation.sortOrders(g)
	return { ok = true, quiet = true }
end

function Actions.toggleBoost(g: any, _ctx: any, _payload: any): any
	g.production.boost = not g.production.boost
	return { ok = true, msg = g.production.boost and ("Producción acelerada: ×2 de velocidad y +" .. round((Catalog.RULES.boostCostFactor - 1) * 100) .. " % de costo en las unidades que empiecen desde ahora. Las que ya empezaron mantienen lo cobrado.") or "Producción a velocidad normal. Las unidades ya empezadas mantienen lo cobrado." }
end

function Actions.toggleAuto(g: any, _ctx: any, _payload: any): any
	if not Rules.has(g, "p3") then
		return fail("Requiere investigar «" .. Catalog.researchNode("p3").name .. "».")
	end
	g.production.auto = not g.production.auto
	return { ok = true, msg = g.production.auto and "Producción automática activada: cuando una línea queda libre, repite el último modelo fabricado." or "Producción automática desactivada." }
end

function Actions.repairStation(g: any, _ctx: any, payload: any): any
	local id = arg(payload, "station")
	local st = Catalog.station(id)
	if not st then
		return fail("Estación desconocida.")
	end
	local s = g.stations[id]
	local cost = Rules.maintCost(s)
	if cost <= 0 then
		return fail("La estación está en perfecto estado.")
	end
	if not Simulation.spend(g, cost, "mantenimiento", (s.broken and "Reparación" or "Mantenimiento") .. " de " .. st[2]) then
		return fail("Fondos insuficientes.")
	end
	local was = s.broken
	s.broken = false
	s.condition = 100
	return { ok = true, msg = (was and "Estación reparada" or "Mantenimiento hecho") .. " por " .. money(cost) .. "." }
end

function Actions.upgradeStation(g: any, ctx: any, payload: any): any
	local id = arg(payload, "station")
	local st = Catalog.station(id)
	if not st then
		return fail("Estación desconocida.")
	end
	local s = g.stations[id]
	if s.level >= Rules.maxStationLevel(g) then
		return fail("Nivel máximo para esta sede (" .. Rules.maxStationLevel(g) .. "). Ampliá la sede para seguir mejorando.")
	end
	local cost = Rules.upgradeCost(s)
	if not Simulation.spend(g, cost, "mejora", "Mejora de " .. st[2]) then
		return fail("Fondos insuficientes: la mejora cuesta " .. money(cost) .. ".")
	end
	s.level += 1
	s.condition = 100
	s.broken = false
	Simulation.addXp(g, ctx, 60)
	return { ok = true, msg = st[2] .. " mejorada a nivel " .. s.level .. "." }
end

-- Compra de materiales al proveedor (precio + impuesto), con tope del depósito (incluye lo que está en fabricación).
function Actions.buyMaterial(g: any, _ctx: any, payload: any): any
	local mat, qty = arg(payload, "mat"), arg(payload, "qty")
	if not Catalog.material(mat) then
		return fail("Material desconocido.")
	end
	if not Util.contains(Catalog.SUPPLIER_PACKS, qty) then
		return fail("Cantidad no disponible en el proveedor.")
	end
	local caps = Rules.caps(g)
	local used = Rules.matsUsed(g)
	if used + qty > caps.mats then
		return fail("No hay lugar en el depósito (" .. used .. "/" .. caps.mats .. ", incluye lo que está en fabricación).")
	end
	local p = Rules.supplierPrice(g, mat, qty)
	if g.money < p.total then
		return fail("Fondos insuficientes: necesitás " .. money(p.total) .. ".")
	end
	local label = string.lower(Catalog.matLabel(mat))
	Simulation.spend(g, p.base, "materiales", "Compra de " .. qty .. " de " .. label)
	Simulation.spend(g, p.tax, "impuesto", "Impuesto por " .. qty .. " de " .. label)
	g.materials[mat] = (g.materials[mat] or 0) + qty
	-- Las órdenes detenidas por materiales se reevalúan en el próximo paso.
	for _, o in g.production.orders do
		if o.status == "detenida" and o.missing then
			o.status = "en cola"
			o.reason = ""
			o.missing = nil
		end
	end
	return { ok = true, msg = "Compraste " .. qty .. " de " .. label .. " por " .. money(p.total) .. " (incluye impuesto)." }
end

-- Inventario ----------------------------------------------------------------------------

local function unitIn(g: any, payload: any, statuses: { string }): (any, string?)
	local u = findById(g.units, arg(payload, "unitId"))
	if not u then
		return nil, "La unidad no existe."
	end
	if not Util.contains(statuses, u.status) then
		return nil, "La unidad no está disponible para esa acción (" .. u.status .. ")."
	end
	return u, nil
end

local function bumpCustomers(g: any, u: any)
	for _, c in g.customers do
		if c.unitId == u.id then
			if c.state == "mirando" then
				c.interest = Simulation.interest(g, u, c)
			end
			c.rev += 1
		end
	end
end

function Actions.sendToShowroom(g: any, _ctx: any, payload: any): any
	local u, err = unitIn(g, payload, { "almacen", "reservado" })
	if not u then
		return fail(err :: string)
	end
	local caps = Rules.caps(g)
	if Rules.showroomUsed(g) >= caps.showroom then
		return fail("Salón lleno (" .. Rules.showroomUsed(g) .. "/" .. caps.showroom .. ").")
	end
	u.status = "salon"
	g.counters.sentToShowroom += 1
	return { ok = true, msg = u.name .. " (" .. u.serial .. ") está en el salón. Los clientes empezarán a llegar." }
end

function Actions.returnToWarehouse(g: any, _ctx: any, payload: any): any
	local u, err = unitIn(g, payload, { "salon" })
	if not u then
		return fail(err :: string)
	end
	local caps = Rules.caps(g)
	if Rules.warehouseUsed(g) >= caps.warehouse then
		return fail("Almacén lleno (" .. Rules.warehouseUsed(g) .. "/" .. caps.warehouse .. ").")
	end
	u.status = "almacen"
	bumpCustomers(g, u)
	return { ok = true, msg = u.name .. " volvió al almacén." }
end

function Actions.reserve(g: any, _ctx: any, payload: any): any
	local u, err = unitIn(g, payload, { "almacen", "salon" })
	if not u then
		return fail(err :: string)
	end
	if u.status == "salon" and Rules.warehouseUsed(g) >= Rules.caps(g).warehouse then
		return fail("Las reservadas usan lugar del almacén y está lleno.")
	end
	u.status = "reservado"
	bumpCustomers(g, u)
	return { ok = true, msg = u.serial .. " reservada: no se ofrece a clientes ni al mercado." }
end

function Actions.unreserve(g: any, _ctx: any, payload: any): any
	local u, err = unitIn(g, payload, { "reservado" })
	if not u then
		return fail(err :: string)
	end
	u.status = "almacen"
	return { ok = true, msg = "Reserva liberada." }
end

function Actions.setPrice(g: any, _ctx: any, payload: any): any
	local u, err = unitIn(g, payload, { "almacen", "salon", "reservado" })
	if not u then
		return fail(err :: string)
	end
	local price = arg(payload, "price")
	if not Util.isFiniteNumber(price) then
		return fail("Precio inválido.")
	end
	local p = round(price / 100) * 100
	if p < 100 or p > u.stats.price * 3 then
		return fail("Precio inválido: usá entre $100 y " .. money(u.stats.price * 3) .. ".")
	end
	u.price = p
	bumpCustomers(g, u)
	return { ok = true, msg = "Precio de lista de " .. u.serial .. ": " .. money(p) .. " (final " .. money(Rules.finalPrice(u)) .. ")." }
end

function Actions.setDiscount(g: any, _ctx: any, payload: any): any
	local u, err = unitIn(g, payload, { "almacen", "salon", "reservado" })
	if not u then
		return fail(err :: string)
	end
	local disc = arg(payload, "discount")
	if not isInt(disc, 0, Catalog.RULES.maxDiscount) then
		return fail("Descuento inválido (0 a " .. Catalog.RULES.maxDiscount .. " %).")
	end
	u.discount = disc
	bumpCustomers(g, u)
	return { ok = true, msg = "Descuento de " .. disc .. " % en " .. u.serial .. ": precio final " .. money(Rules.finalPrice(u)) .. "." }
end

function Actions.wholesale(g: any, ctx: any, payload: any): any
	local u, err = unitIn(g, payload, { "almacen", "salon" })
	if not u then
		return fail(err :: string)
	end
	return Simulation.sellUnit(g, ctx, u.id, Rules.wholesale(u), "mayorista", "Mayorista", { listPrice = u.price })
end

function Actions.recycle(g: any, _ctx: any, payload: any): any
	local u, err = unitIn(g, payload, { "almacen" })
	if not u then
		return fail(err :: string)
	end
	local _, i = findById(g.units, u.id)
	table.remove(g.units, i :: number)
	local lost = 0
	local caps = Rules.caps(g)
	for _, k in Util.keys(u.stats.mats) do
		local back = math.floor(u.stats.mats[k] / 2)
		local room = math.max(0, caps.mats - Rules.matsUsed(g))
		local add = math.min(back, room)
		g.materials[k] = (g.materials[k] or 0) + add
		lost += back - add
	end
	return { ok = true, msg = "Unidad reciclada." .. (lost > 0 and (" Se perdieron " .. lost .. " materiales por falta de lugar.") or "") }
end

-- Concesionario ---------------------------------------------------------------------------

local function offerContext(g: any, payload: any): (any, any, string?)
	local c = findById(g.customers, arg(payload, "customerId"))
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
	local r = Simulation.sellUnit(g, ctx, u.id, c.offer, "concesionario", c.name, { listPrice = u.price, offer = c.offer })
	if r.ok then
		c.state = "compró"
		c.rev += 1
	end
	return r
end

-- Consulta sin efectos: probabilidad exacta para ese monto en el estado actual de la negociación.
function Actions.quoteCounter(g: any, _ctx: any, payload: any): any
	local c, _, err = offerContext(g, payload)
	if err then
		return fail(err)
	end
	local amount = arg(payload, "amount")
	if not Util.isFiniteNumber(amount) then
		return fail("Ingresá un monto válido.")
	end
	local a = Simulation.roundAmount(amount)
	return { ok = true, quiet = true, amount = a, chance = a > c.offer and Simulation.counterChance(c, a) or nil, rev = c.rev, offer = c.offer }
end

-- payload = { customerId, amount, rev }. rev debe coincidir con la consulta mostrada al jugador.
function Actions.counterOffer(g: any, ctx: any, payload: any): any
	local c, u, err = offerContext(g, payload)
	if err then
		return fail(err)
	end
	if arg(payload, "rev") ~= c.rev then
		return fail("La negociación cambió desde que viste la probabilidad. Revisá la nueva antes de contraofertar.")
	end
	local amount = arg(payload, "amount")
	if not Util.isFiniteNumber(amount) then
		return fail("Ingresá un monto válido.")
	end
	amount = Simulation.roundAmount(amount)
	if amount <= c.offer then
		return fail("Tu contraoferta tiene que superar su oferta; si te sirve, aceptala directamente.")
	end
	local chance = Simulation.counterChance(c, amount)
	local roll = math.floor(ctx.rng() * 100)
	local debug = { chance = chance, roll = roll }
	if roll < chance then
		local r = Simulation.sellUnit(g, ctx, u.id, amount, "concesionario", c.name, { listPrice = u.price, offer = c.offer })
		if r.ok then
			c.state = "compró"
			c.rev += 1
			r.msg = c.name .. " aceptó tu contraoferta de " .. money(amount) .. ". " .. r.msg
			r.sold = true
		end
		r.debug = debug
		return r
	end
	c.rounds += 1
	c.waited += 45
	c.rev += 1
	if c.rounds >= 3 or c.waited >= c.patience then
		c.state = "se fue"
		c.leftAt = Rules.absMinute(g)
		return { ok = true, sold = false, left = true, debug = debug, msg = c.name .. " rechazó " .. money(amount) .. " y se fue. No se vendió nada." }
	end
	local newOffer = math.min(c.budget, round((c.offer * 0.6 + amount * 0.4) / 100) * 100)
	c.offer = math.max(c.offer, newOffer)
	return { ok = true, sold = false, debug = debug, msg = c.name .. " rechazó " .. money(amount) .. ". Nueva oferta: " .. money(c.offer) .. "." }
end

function Actions.rejectCustomer(g: any, _ctx: any, payload: any): any
	local c = findById(g.customers, arg(payload, "customerId"))
	if not c or c.state == "se fue" or c.state == "compró" then
		return fail("El cliente ya no está.")
	end
	c.state = "se fue"
	c.leftAt = Rules.absMinute(g)
	c.rev += 1
	return { ok = true, msg = c.name .. " se fue. No se vendió nada." }
end

function Actions.togglePromo(g: any, _ctx: any, _payload: any): any
	if not g.promo and not Rules.has(g, "mk2") then
		return fail("Requiere investigar «" .. Catalog.researchNode("mk2").name .. "».")
	end
	if not g.promo and g.money < Catalog.RULES.promoCostPerDay then
		return fail("Necesitás al menos " .. money(Catalog.RULES.promoCostPerDay) .. " para pagar el primer día.")
	end
	g.promo = not g.promo
	return { ok = true, msg = g.promo and ("Promoción activada: +" .. round((Catalog.RULES.promoBoost - 1) * 100) .. " % de clientes, " .. money(Catalog.RULES.promoCostPerDay) .. " al empezar cada día de juego hasta que la apagues.") or "Promoción desactivada." }
end

-- Investigación ------------------------------------------------------------------------------

function Actions.startResearch(g: any, _ctx: any, payload: any): any
	local n = Catalog.researchNode(arg(payload, "id"))
	if not n then
		return fail("Investigación desconocida.")
	end
	local st = Rules.researchState(g, n)
	if st ~= "disponible" then
		local miss = Rules.researchMissing(g, n)
		return fail(#miss > 0 and table.concat(miss, " · ") or (st == "hecha" and "Ya está investigada." or "Ya está en curso."))
	end
	if g.research.active then
		return fail("El laboratorio está ocupado.")
	end
	if g.rp < n.rp then
		return fail("Faltan puntos de investigación (" .. math.floor(g.rp) .. "/" .. n.rp .. ").")
	end
	if not Simulation.spend(g, n.cost, "investigacion", "Investigación: " .. n.name) then
		return fail("Fondos insuficientes: cuesta " .. money(n.cost) .. ".")
	end
	g.rp -= n.rp
	g.research.active = { id = n.id, progress = 0, paid = n.cost, rp = n.rp }
	return { ok = true, msg = "Investigando «" .. n.name .. "»: " .. Util.gameDuration(n.minutes) .. " de juego." }
end

function Actions.cancelResearch(g: any, _ctx: any, _payload: any): any
	local a = g.research.active
	if not a then
		return fail("No hay investigación en curso.")
	end
	local n = Catalog.researchNode(a.id)
	Simulation.earn(g, a.paid, "reintegro", "Reintegro: " .. n.name)
	g.rp += a.rp
	g.research.active = nil
	return { ok = true, msg = "Investigación cancelada: se devolvieron " .. money(a.paid) .. " y " .. a.rp .. " PI." }
end

-- Personal ------------------------------------------------------------------------------------

function Actions.hire(g: any, ctx: any, payload: any): any
	local c, i = findById(g.candidates, arg(payload, "candidateId"))
	if not c then
		return fail("Ese candidato ya no está disponible.")
	end
	if #g.employees >= Rules.caps(g).staff then
		return fail("La sede está completa (" .. Rules.caps(g).staff .. " empleados). Ampliá la sede para contratar más.")
	end
	if not Simulation.spend(g, c.fee, "contratacion", "Contratación de " .. c.name) then
		return fail("Fondos insuficientes: la contratación cuesta " .. money(c.fee) .. ".")
	end
	table.remove(g.candidates, i :: number)
	table.insert(g.employees, { id = GameState.uid(g, "e"), name = c.name, role = c.role, level = c.level, skill = c.skill, salary = c.salary, energy = 100, status = "activo", assign = nil })
	g.counters.hires += 1
	Simulation.addXp(g, ctx, 40)
	return { ok = true, msg = c.name .. " se sumó al equipo. Asignale un puesto." }
end

function Actions.moreCandidates(g: any, ctx: any, _payload: any): any
	if not Simulation.spend(g, Catalog.RULES.moreCandidatesCost, "contratacion", "Búsqueda de candidatos") then
		return fail("Fondos insuficientes.")
	end
	for _, c in Simulation.makeCandidates(g, ctx, 3) do
		table.insert(g.candidates, c)
	end
	while #g.candidates > 12 do
		table.remove(g.candidates, 1)
	end
	return { ok = true, msg = "Aparecieron 3 candidatos nuevos." }
end

function Actions.fire(g: any, _ctx: any, payload: any): any
	local e, i = findById(g.employees, arg(payload, "employeeId"))
	if not e then
		return fail("El empleado ya no está.")
	end
	table.remove(g.employees, i :: number)
	return { ok = true, msg = e.name .. " dejó la empresa. El costo de contratación no se recupera." }
end

function Actions.toggleRest(g: any, _ctx: any, payload: any): any
	local e = findById(g.employees, arg(payload, "employeeId"))
	if not e then
		return fail("El empleado ya no está.")
	end
	if e.status == "descanso" then
		e.status = "activo"
		return { ok = true, msg = e.name .. " volvió al trabajo con " .. math.floor(e.energy) .. " % de energía." }
	end
	if e.energy >= 100 then
		return fail(e.name .. " tiene la energía completa.")
	end
	e.status = "descanso"
	return { ok = true, msg = e.name .. " descansa: no aporta a su puesto hasta recuperar la energía." }
end

function Actions.assign(g: any, _ctx: any, payload: any): any
	local e = findById(g.employees, arg(payload, "employeeId"))
	local area = arg(payload, "area")
	if not e then
		return fail("El empleado ya no está.")
	end
	if e.status == "descanso" then
		return fail(e.name .. " está descansando.")
	end
	if area == "" then
		area = nil
	end
	if area ~= nil then
		local isStation = Catalog.station(area) ~= nil
		if not isStation and not Catalog.department(area) then
			return fail("Puesto desconocido.")
		end
		local max = isStation and Catalog.RULES.assignMax.station or Catalog.RULES.assignMax.dept
		if Rules.assignedCount(g, area, e.id) >= max then
			return fail("Ese puesto está completo (" .. max .. ").")
		end
	end
	e.assign = area
	local label = area and ((Catalog.station(area) or Catalog.department(area))[2]) or nil
	return { ok = true, msg = e.name .. (label and (" asignado/a a " .. label) or " quedó sin puesto") .. "." }
end

-- Misiones y recompensas ---------------------------------------------------------------------

-- Una recompensa se cobra una sola vez: la clave queda registrada en g.claimed antes de pagar.
function Actions.claimMission(g: any, ctx: any, payload: any): any
	local m = Catalog.mission(arg(payload, "id"))
	if not m then
		return fail("Misión desconocida.")
	end
	local key = Rules.missionKey(g, m)
	if g.claimed[key] then
		return fail("Esa recompensa ya fue reclamada.")
	end
	if Rules.missionValue(g, m) < m.goal then
		return fail("Todavía no completaste la misión.")
	end
	g.claimed[key] = true
	if m.reward.money then
		Simulation.earn(g, m.reward.money, "recompensa", "Misión: " .. m.title)
	end
	if m.reward.gems then
		g.gems += m.reward.gems
	end
	if m.reward.xp then
		Simulation.addXp(g, ctx, m.reward.xp)
	end
	return { ok = true, msg = "Recompensa reclamada: " .. Rules.rewardText(m.reward) }
end

-- Recompensa diaria por fecha real (UTC del servidor) con racha de días consecutivos.
function Actions.claimDaily(g: any, ctx: any, _payload: any): any
	local today, yesterday = ctx.today, ctx.yesterday
	if type(today) ~= "string" then
		return fail("No se pudo leer la fecha.")
	end
	if g.daily.last == today then
		return fail("Ya reclamaste la recompensa de hoy.")
	end
	g.daily.streak = (g.daily.last == yesterday) and (g.daily.streak + 1) or 1
	g.daily.last = today
	local r = Catalog.DAILY_REWARDS[math.min(g.daily.streak, #Catalog.DAILY_REWARDS)]
	if r.money then
		Simulation.earn(g, r.money, "recompensa", "Recompensa diaria")
	end
	if r.gems then
		g.gems += r.gems
	end
	return { ok = true, msg = "Recompensa diaria: " .. Rules.rewardText(r) .. " · racha " .. g.daily.streak }
end

function Actions.setTutorial(g: any, _ctx: any, payload: any): any
	g.tutorial.skipped = arg(payload, "skipped") == true
	return { ok = true, msg = g.tutorial.skipped and "Guías ocultas. Las misiones siguen activas en Misiones." or "Guías del tutorial activadas." }
end

function Actions.markRead(g: any, _ctx: any, payload: any): any
	local id = arg(payload, "id")
	for _, n in g.notifications do
		if id == nil or n.id == id then
			n.read = true
		end
	end
	return { ok = true, quiet = true }
end

-- Mercado ----------------------------------------------------------------------------------

function Actions.marketOpen(g: any, ctx: any, _payload: any): any
	Market.refresh(g, ctx)
	return { ok = true, quiet = true }
end
function Actions.marketBuy(g: any, ctx: any, payload: any): any
	return Market.buy(g, ctx, arg(payload, "listingId"), false)
end
function Actions.marketBid(g: any, _ctx: any, payload: any): any
	return Market.bid(g, arg(payload, "listingId"), arg(payload, "amount"))
end
function Actions.marketPublish(g: any, _ctx: any, payload: any): any
	return Market.publish(g, arg(payload, "unitId"), arg(payload, "price"), arg(payload, "mode"), arg(payload, "hours"))
end
function Actions.marketUnpublish(g: any, _ctx: any, payload: any): any
	return Market.unpublish(g, arg(payload, "unitId"))
end
function Actions.marketAcceptOffer(g: any, ctx: any, payload: any): any
	return Market.acceptOffer(g, ctx, arg(payload, "offerId"))
end
function Actions.marketRejectOffer(g: any, _ctx: any, payload: any): any
	return Market.rejectOffer(g, arg(payload, "offerId"))
end
function Actions.marketFavorite(g: any, _ctx: any, payload: any): any
	return Market.toggleFavorite(g, arg(payload, "listingId"))
end

function Actions.setSpeed(g: any, _ctx: any, payload: any): any
	local v = arg(payload, "speed")
	if not Util.contains(Catalog.RULES.speeds, v) then
		return fail("Velocidad inválida.")
	end
	g.time.speed = v
	return { ok = true, msg = v == 0 and "Simulación en pausa." or ("Velocidad " .. v .. "×."), quiet = true }
end

Actions.handlers = {
	setIdentity = Actions.setIdentity, expandSede = Actions.expandSede,
	saveDesign = Actions.saveDesign, dupDesign = Actions.dupDesign, delDesign = Actions.delDesign,
	createOrder = Actions.createOrder, repeatOrder = Actions.repeatOrder, cancelOrder = Actions.cancelOrder,
	togglePause = Actions.togglePause, setPriority = Actions.setPriority, setLine = Actions.setLine, moveOrder = Actions.moveOrder,
	toggleBoost = Actions.toggleBoost, toggleAuto = Actions.toggleAuto, repairStation = Actions.repairStation, upgradeStation = Actions.upgradeStation,
	buyMaterial = Actions.buyMaterial,
	sendToShowroom = Actions.sendToShowroom, returnToWarehouse = Actions.returnToWarehouse, reserve = Actions.reserve, unreserve = Actions.unreserve,
	setPrice = Actions.setPrice, setDiscount = Actions.setDiscount, wholesale = Actions.wholesale, recycle = Actions.recycle,
	acceptOffer = Actions.acceptOffer, quoteCounter = Actions.quoteCounter, counterOffer = Actions.counterOffer, rejectCustomer = Actions.rejectCustomer,
	togglePromo = Actions.togglePromo,
	startResearch = Actions.startResearch, cancelResearch = Actions.cancelResearch,
	hire = Actions.hire, moreCandidates = Actions.moreCandidates, fire = Actions.fire, toggleRest = Actions.toggleRest, assign = Actions.assign,
	claimMission = Actions.claimMission, claimDaily = Actions.claimDaily, setTutorial = Actions.setTutorial, markRead = Actions.markRead,
	marketOpen = Actions.marketOpen, marketBuy = Actions.marketBuy, marketBid = Actions.marketBid, marketPublish = Actions.marketPublish,
	marketUnpublish = Actions.marketUnpublish, marketAcceptOffer = Actions.marketAcceptOffer, marketRejectOffer = Actions.marketRejectOffer,
	marketFavorite = Actions.marketFavorite,
	setSpeed = Actions.setSpeed,
}

-- Consultas sin efectos: no marcan la partida como modificada ni requieren identificador único.
Actions.readOnly = { quoteCounter = true, marketOpen = false }

-- Acciones económicas: llevan un identificador de solicitud para que un reenvío no se aplique dos veces.
Actions.economic = {
	saveDesign = true, dupDesign = true, delDesign = true, createOrder = true, repeatOrder = true, cancelOrder = true,
	repairStation = true, upgradeStation = true, buyMaterial = true, wholesale = true, recycle = true, acceptOffer = true,
	counterOffer = true, startResearch = true, cancelResearch = true, hire = true, moreCandidates = true, fire = true,
	claimMission = true, claimDaily = true, expandSede = true, marketBuy = true, marketBid = true, marketPublish = true,
	marketAcceptOffer = true,
}

-- Acciones que justifican guardar enseguida (además del autoguardado periódico).
Actions.important = Actions.economic

return Actions
