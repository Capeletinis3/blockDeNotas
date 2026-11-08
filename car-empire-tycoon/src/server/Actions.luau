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
local Staff = require(Shared.Staff)
local GameState = require(script.Parent.GameState)
local Simulation = require(script.Parent.Simulation)

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
	-- Nombre, símbolo y color son obligatorios (la pantalla de creación propone valores editables). No hay
	-- dificultades: todas las empresas empiezan con las mismas condiciones.
	if not Catalog.isBrandColor(payload.color) then
		return nil, "Elegí un color corporativo de la lista."
	end
	if not Catalog.isLogo(payload.logo) then
		return nil, "Elegí un símbolo corporativo."
	end
	return { name = name, color = payload.color, logo = payload.logo }, nil
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
	return { ok = true, msg = "Ampliaste a «" .. next.name .. "»: " .. next.lines .. " líneas, alcance comercial ×" .. Util.num(next.reach, 1) .. " y " .. next.pi .. " PI por minuto." }
end

-- Expansión global: después del Imperio automotriz, cada región suma alcance y capacidad de las líneas.
function Actions.expandGlobal(g: any, ctx: any, _payload: any): any
	local nx = Rules.nextExpansion(g)
	if not nx then
		return fail(Rules.nextSede(g) and "La expansión global se abre con el Imperio automotriz." or "Ya abriste todas las regiones.")
	end
	for _, check in Rules.expansionChecks(g) do
		if not check[1] then
			return fail("Faltan requisitos para expandirte: " .. check[2] .. ".")
		end
	end
	if not Simulation.spend(g, nx.cost, "sede", "Expansión global: " .. nx.name) then
		return fail("Fondos insuficientes.")
	end
	g.expansion = nx.level
	Simulation.addXp(g, ctx, 1000)
	Simulation.notify(g, ctx, "ok", "¡Nueva región: " .. nx.name .. "!", "compania")
	return { ok = true, msg = "Abriste " .. nx.name .. ": la demanda de todos los tipos sube a ×" .. Util.num(Rules.marketFactor(g), 2) .. " y cada línea fabrica " .. Util.num(Rules.lineRate(g), 0) .. " autos/min." }
end

-- Diseños -------------------------------------------------------------------------------

-- Dos diseños distintos no pueden llamarse igual, salvo las generaciones de un mismo modelo.
local function nameTaken(g: any, name: string, exceptId: string?, lineage: string?): boolean
	local lower = string.lower(name)
	for _, d in g.designs do
		if d.id ~= exceptId and not d.template and string.lower(d.name) == lower and (lineage == nil or (d.lineage or d.id) ~= lineage) then
			return true
		end
	end
	return false
end

local function maxGen(g: any, lineage: string): number
	local n = 0
	for _, d in g.designs do
		if (d.lineage or d.id) == lineage then
			n = math.max(n, d.gen or 1)
		end
	end
	for _, l in g.lots do
		if l.design.lineage == lineage then
			n = math.max(n, l.design.gen or 1)
		end
	end
	for _, l in g.lotHistory do
		if l.design.lineage == lineage then
			n = math.max(n, l.design.gen or 1)
		end
	end
	return n
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
	local year = Rules.year(g)
	d.modelYear = year
	d.gen = 1
	d.lineage = nil
	-- Nueva generación: misma familia, número siguiente y año de modelo actual.
	local parent = nil
	if payload.newGenOf ~= nil then
		parent = findById(g.designs, payload.newGenOf)
		if not parent or parent.template then
			return fail("El modelo del que querías crear una nueva generación ya no existe.")
		end
		if not Rules.canNewGeneration(g, parent) then
			return fail("Una nueva generación necesita al menos un año desde la anterior (" .. tostring(parent.modelYear) .. "). Esperá al año próximo.")
		end
		d.lineage = parent.lineage or parent.id
		d.gen = maxGen(g, d.lineage) + 1
	end
	d.generation = DesignCalc.generationLabel(d.modelYear, d.gen)
	local source = nil
	if payload.sourceId ~= nil and parent == nil then
		source = findById(g.designs, payload.sourceId)
		if not source or source.template then
			return fail("El diseño que estabas editando ya no existe. Guardalo como proyecto nuevo.")
		end
		if DesignCalc.sameSpec(source, d) then
			return fail("No hay cambios para guardar.")
		end
		-- Una nueva versión del mismo diseño conserva su familia, generación y año de modelo.
		d.lineage, d.gen, d.modelYear = source.lineage, source.gen or 1, source.modelYear or year
		d.generation = DesignCalc.generationLabel(d.modelYear, d.gen)
	elseif #g.designs >= Catalog.RULES.maxDesigns then
		return fail("Llegaste al máximo de " .. Catalog.RULES.maxDesigns .. " diseños.")
	end
	if nameTaken(g, d.name, source and source.id or nil, d.lineage) then
		return fail("Ya tenés otro diseño llamado «" .. d.name .. "». Elegí un nombre distinto.")
	end

	local items = DesignCalc.devItems(g, d, DesignCalc.engineeringKind(source, d))
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
				Simulation.spend(g, it.cost, "desarrollo", it.label .. (it.engineering and (": " .. d.name) or ""))
			end
			if it.key then
				table.insert(g.devPaid, it.key)
			end
		end
	end

	if source == nil then
		d.id = GameState.uid(g, "d")
		d.version = 1
		d.createdDay = g.time.day
		table.insert(g.designs, d)
		g.counters.designsSaved += 1
		if parent then
			g.counters.generations = (g.counters.generations or 0) + 1
		end
		Simulation.addXp(g, ctx, 200)
	else
		d.id = source.id
		d.version = (source.version or 1) + 1
		-- Una versión sigue siendo el mismo modelo: si ya tuvo su lote, no puede fabricar otro.
		d.lotLaunched = source.lotLaunched
		d.createdDay = source.createdDay
		local _, i = findById(g.designs, source.id)
		g.designs[i :: number] = d
	end
	d.template = nil
	d.updatedDay = g.time.day
	return {
		ok = true,
		msg = "Diseño guardado: «" .. d.name .. "» " .. d.generation .. (cash > 0 and (" · desarrollo pagado " .. money(cash)) or " · sin costo de desarrollo pendiente"),
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
	-- Un duplicado es un modelo nuevo (año actual, 1.ª generación): paga la ingeniería como cualquier modelo
	-- nuevo; la licencia y los prototipos ya estaban pagados.
	local eng = d.template and 0 or DesignCalc.engineeringCost(g, d, "nuevo")
	if eng > 0 and not Simulation.spend(g, eng, "desarrollo", "Ingeniería del modelo: " .. name) then
		return fail("Fondos insuficientes: la ingeniería del modelo nuevo cuesta " .. money(eng) .. ".")
	end
	local copy = Util.deepCopy(d)
	copy.id = GameState.uid(g, "d")
	copy.name = name
	copy.version = 1
	copy.lineage = nil
	copy.gen = 1
	copy.modelYear = Rules.year(g)
	copy.generation = DesignCalc.generationLabel(copy.modelYear, 1)
	copy.createdDay = g.time.day
	copy.lotLaunched = nil -- un modelo nuevo puede tener su propio lote
	table.insert(g.designs, copy)
	return { ok = true, msg = "Duplicado: «" .. name .. "»" .. (eng > 0 and (" · ingeniería " .. money(eng)) or "") .. ". La licencia y los prototipos ya estaban pagados.", designId = copy.id }
end

-- Eliminar un proyecto no toca unidades fabricadas ni órdenes: cada una tiene su copia.
function Actions.delDesign(g: any, _ctx: any, payload: any): any
	local d, i = findById(g.designs, arg(payload, "designId"))
	if not d then
		return fail("El diseño ya no existe.")
	end
	table.remove(g.designs, i :: number)
	local active = 0
	for _, l in g.lots do
		if l.designId == d.id then
			active += 1
		end
	end
	return { ok = true, msg = "Diseño eliminado." .. (active > 0 and (" Sus " .. active .. " lote(s) siguen con su propia copia.") or "") }
end

-- Producción por lotes ---------------------------------------------------------------------

local function findLot(g: any, payload: any): any
	return (findById(g.lots, arg(payload, "lotId")))
end

local function priceRange(lot: any): (number, number)
	return Rules.priceRange(lot.unitCost, lot.refPrice)
end
Actions.priceRange = priceRange

--[[ Ordena el lote de un modelo: el jugador elige cuántas unidades fabricar (hasta Catalog.RULES.maxLotQty).
	Cada modelo tiene UN solo lote: para volver a fabricar hace falta un modelo nuevo (Duplicar) o una nueva
	generación. El lote se paga COMPLETO al ordenarlo (qty × costo por unidad; si no alcanza, no se ordena), así
	nunca queda un lote a medio fabricar por falta de dinero. El lote no se vende
	mientras se fabrica: al terminar llegan las reseñas y el jugador fija el precio (Actions.launchSale).
	payload = { designId, qty, price? } (price = precio previsto; se puede cambiar al lanzar) ]]
function Actions.createLot(g: any, ctx: any, payload: any): any
	local d = findById(g.designs, arg(payload, "designId"))
	if not d then
		return fail("El diseño no existe.")
	end
	if d.template then
		return fail("Las plantillas no se fabrican: usala para crear un diseño.")
	end
	if d.lotLaunched then
		return fail("«" .. d.name .. "» ya tuvo su lote: cada modelo se fabrica una sola vez. Para volver a producir, creá un modelo nuevo (Duplicar) o una nueva generación.")
	end
	local qty = arg(payload, "qty")
	if not isInt(qty, 1, Catalog.RULES.maxLotQty) then
		return fail("La cantidad debe ser un número entero entre 1 y " .. Util.num(Catalog.RULES.maxLotQty) .. ".")
	end
	if #g.lots >= Catalog.RULES.maxActiveLots then
		return fail("Ya tenés " .. Catalog.RULES.maxActiveLots .. " lotes activos. Esperá a que se agoten o cerrá la venta de alguno.")
	end
	local snap = Simulation.designSnapshot(g, d)
	local lot = Simulation.makeLot(g, snap, qty, snap.calc.price)
	local total = qty * lot.unitCost
	if not Simulation.canAfford(g, total) then
		return fail("Fondos insuficientes: el lote cuesta " .. money(total) .. " (" .. Util.num(qty) .. " × " .. money(lot.unitCost) .. ") y tenés " .. money(g.money) .. ".")
	end
	local price = arg(payload, "price")
	if price ~= nil then
		if not Util.isFiniteNumber(price) then
			return fail("Precio inválido.")
		end
		local lo, hi = priceRange(lot)
		local p = round(price / 10) * 10
		if p < lo or p > hi then
			return fail("El precio tiene que estar entre " .. money(lo) .. " y " .. money(hi) .. ".")
		end
		lot.price = p
	end
	Simulation.spend(g, total, "fabricacion", "Lote de " .. Util.num(qty) .. " × " .. d.name)
	lot.prepaid = true
	lot.costSpent = total
	table.insert(g.lots, lot)
	d.lotLaunched = true
	Simulation.registerModel(g, lot)
	g.counters.lotsLaunched = (g.counters.lotsLaunched or 0) + 1
	Simulation.addXp(g, ctx, 60)
	local lines = Rules.sede(g).lines
	local waiting = #Rules.producingLots(g) >= lines and not table.find(Rules.producingLots(g), lot)
	return {
		ok = true,
		lotId = lot.id,
		msg = "Lote ordenado: " .. Util.num(qty) .. " × «" .. d.name .. "» · pagaste " .. money(total) .. " (" .. money(lot.unitCost) .. " por unidad)." .. (waiting and " Espera una línea libre." or " Al terminar llegan las reseñas y lo ponés a la venta."),
	}
end

-- Pone a la venta un lote terminado y con reseñas, al precio elegido. payload = { lotId, price }
function Actions.launchSale(g: any, ctx: any, payload: any): any
	local lot = findLot(g, payload)
	if not lot then
		return fail("Ese lote ya no existe.")
	end
	if lot.saleState ~= "por lanzar" then
		return fail(lot.saleState == "produccion" and "El lote todavía se está fabricando." or "Ese lote ya está a la venta.")
	end
	local price = arg(payload, "price")
	if not Util.isFiniteNumber(price) then
		return fail("Precio inválido.")
	end
	local lo, hi = priceRange(lot)
	local p = round(price / 10) * 10
	if p < lo or p > hi then
		return fail("El precio tiene que estar entre " .. money(lo) .. " y " .. money(hi) .. ".")
	end
	lot.price = p
	lot.saleState = "en venta"
	lot.launchDay = g.time.day
	Simulation.addXp(g, ctx, 40)
	return { ok = true, msg = "«" .. lot.design.name .. "» salió a la venta a " .. money(p) .. ". Se vende solo según la demanda." .. (p < lot.unitCost and " Ojo: por debajo del costo, cada venta pierde dinero." or "") }
end

-- Cambia el precio de venta de un lote activo (afecta las ventas desde ese momento).
function Actions.setLotPrice(g: any, _ctx: any, payload: any): any
	local lot = findLot(g, payload)
	if not lot then
		return fail("El lote ya no está a la venta.")
	end
	local price = arg(payload, "price")
	if not Util.isFiniteNumber(price) then
		return fail("Precio inválido.")
	end
	local lo, hi = priceRange(lot)
	local p = round(price / 10) * 10
	if p < lo or p > hi then
		return fail("El precio tiene que estar entre " .. money(lo) .. " y " .. money(hi) .. ".")
	end
	lot.price = p
	return { ok = true, msg = "Nuevo precio de " .. lot.design.name .. ": " .. money(p) .. (p < lot.unitCost and " (por debajo del costo: cada venta pierde dinero)." or ".") }
end

-- Pausa o reanuda la producción de un lote (la venta sigue con lo ya fabricado).
function Actions.toggleLotPause(g: any, _ctx: any, payload: any): any
	local lot = findLot(g, payload)
	if not lot or not Rules.lotProducing(lot) then
		return fail("Ese lote no tiene producción pendiente.")
	end
	if lot.prodState == "pausado" then
		lot.prodState = "cola"
		return { ok = true, msg = "Producción de " .. lot.design.name .. " reanudada.", quiet = true }
	end
	lot.prodState = "pausado"
	return { ok = true, msg = "Producción de " .. lot.design.name .. " pausada.", quiet = true }
end

-- Mueve un lote en la cola de producción (las líneas toman los primeros lotes pendientes).
function Actions.moveLot(g: any, _ctx: any, payload: any): any
	local lot, i = findById(g.lots, arg(payload, "lotId"))
	local delta = arg(payload, "delta")
	if not lot then
		return fail("El lote ya no existe.")
	end
	if delta ~= -1 and delta ~= 1 then
		return fail("Movimiento inválido.")
	end
	local j = (i :: number) + delta
	if j < 1 or j > #g.lots then
		return { ok = true, quiet = true }
	end
	g.lots[i :: number], g.lots[j] = g.lots[j], g.lots[i :: number]
	return { ok = true, quiet = true }
end

--[[ Cerrar venta: descarta las unidades fabricadas que no se vendieron (sin devolución del costo), cancela
	la producción pendiente (que no se había cobrado) y deja el modelo como «retirado» en el historial con
	sus ventas, ingresos, gastos y beneficio. No se puede deshacer. ]]
function Actions.closeSale(g: any, ctx: any, payload: any): any
	local lot = findLot(g, payload)
	if not lot then
		return fail("Ese lote ya no está a la venta.")
	end
	local unsold = Rules.lotAvailable(lot)
	local pending = Rules.lotPending(lot)
	-- Lotes pagados por adelantado: las unidades que no se llegaron a fabricar se reintegran.
	local refund = (lot.prepaid and pending > 0) and pending * lot.unitCost or 0
	if refund > 0 then
		Simulation.earn(g, refund, "fabricacion", "Reintegro: " .. Util.num(pending) .. " × " .. lot.design.name .. " sin fabricar")
		lot.costSpent -= refund
	end
	lot.discarded += unsold
	lot.qty = lot.produced
	if pending > 0 then
		lot.prodState = "cancelado"
	end
	lot.prodProgress = 0
	lot.saleAcc = 0
	lot.saleState = "retirado"
	lot.lossDiscarded = unsold * lot.unitCost
	g.counters.lotsRetired = (g.counters.lotsRetired or 0) + 1
	g.counters.unitsDiscarded = (g.counters.unitsDiscarded or 0) + unsold
	if unsold > 0 then
		-- Registro sin movimiento de dinero: el costo ya se había pagado al fabricar.
		table.insert(g.ledger, { day = g.time.day, min = math.floor(g.time.minute), type = "descarte", amount = 0, note = "Venta cerrada: " .. Util.num(unsold) .. " × " .. lot.design.name .. " descartados (costo perdido " .. money(lot.lossDiscarded) .. ")" })
	end
	Simulation.archiveLot(g, lot)
	Simulation.notify(g, ctx, "info", "Venta cerrada de " .. lot.design.name .. ": " .. Util.num(lot.sold) .. " vendidos, " .. Util.num(unsold) .. " descartados" .. (pending > 0 and (", " .. Util.num(pending) .. " sin fabricar cancelados") or "") .. ".", "ventas")
	return {
		ok = true,
		msg = "Venta cerrada: " .. lot.design.name .. " quedó retirado. " .. Util.num(unsold) .. " unidades descartadas" .. (unsold > 0 and (" (costo perdido " .. money(lot.lossDiscarded) .. ")") or "") .. (pending > 0 and (" y " .. Util.num(pending) .. " sin fabricar canceladas" .. (refund > 0 and (" (se reintegraron " .. money(refund) .. ")") or " sin costo")) or "") .. ".",
	}
end

-- Fábrica: mejora de estaciones (más producción por línea).
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
	g.counters.stationUpgrades = (g.counters.stationUpgrades or 0) + 1
	Simulation.addXp(g, ctx, 60)
	return { ok = true, msg = st[2] .. " mejorada a nivel " .. s.level .. ": la fábrica produce " .. Util.num(Rules.lineRate(g), 1) .. " autos/min por línea." }
end

--[[ Campaña publicitaria: payload = { kind = "modelo" | "corporativa", designId?, budget (mensual), days }.
	Una sola activa por empresa; se paga completa al empezar (Rules.campaignPlan calcula costo y efecto en el
	servidor, sin confiar en montos del cliente). ]]
function Actions.startCampaign(g: any, _ctx: any, payload: any): any
	if Rules.campaign(g) then
		return fail("Ya hay una campaña activa. Cancelala para empezar otra.")
	end
	local plan, why = Rules.campaignPlan(g, { kind = arg(payload, "kind"), designId = arg(payload, "designId"), budget = arg(payload, "budget"), days = arg(payload, "days") })
	if not plan then
		return fail(why or "Campaña inválida.")
	end
	local kind = Catalog.MARKETING.kinds[plan.kind]
	if not Simulation.spend(g, plan.cost, "promocion", kind.name .. ": " .. plan.name) then
		return fail("Fondos insuficientes: la campaña cuesta " .. money(plan.cost) .. ".")
	end
	g.campaign = { id = GameState.uid(g, "m"), kind = plan.kind, designId = plan.designId, name = plan.name, budget = plan.budget, boost = plan.boost, days = plan.days, progress = 0, cost = plan.cost, startDay = Rules.absDay(g) }
	return { ok = true, msg = kind.name .. " «" .. plan.name .. "»: " .. money(plan.cost) .. ", " .. plan.days .. " días, +" .. round(Rules.campaignBoost(g) * 100) .. " % de demanda." }
end

-- Cancelar la campaña: termina enseguida y no devuelve dinero; se puede empezar otra inmediatamente.
function Actions.cancelCampaign(g: any, _ctx: any, _payload: any): any
	local c = Rules.campaign(g)
	if not c then
		return fail("No hay ninguna campaña activa.")
	end
	g.campaign = nil
	return { ok = true, msg = "Campaña cancelada. El dinero ya invertido no se devuelve." }
end

-- Investigación ------------------------------------------------------------------------------

--[[ Investigación: se pueden llevar varias a la vez (hasta RESEARCH_RULES.maxParallel). Para empezar hacen
	falta los PI y el dinero (se pagan AL EMPEZAR, una sola vez), los requisitos y que la tecnología no esté
	ya completada ni en curso; se puede adelantar hasta 5 años con recargo (Rules.researchCost). Avanza por
	días simulados y no se puede cancelar. ]]
function Actions.startResearch(g: any, _ctx: any, payload: any): any
	local n = Catalog.researchNode(arg(payload, "id"))
	if not n then
		return fail("Investigación desconocida.")
	end
	local st = Rules.researchState(g, n)
	if st == "hecha" then
		return fail("«" .. n.name .. "» ya está investigada.")
	elseif st == "activa" then
		return fail("«" .. n.name .. "» ya está en curso.")
	elseif st ~= "disponible" then
		return fail(table.concat(Rules.researchMissing(g, n), " · "))
	end
	if #g.research.projects >= Catalog.RESEARCH_RULES.maxParallel then
		return fail("Ya tenés " .. Catalog.RESEARCH_RULES.maxParallel .. " investigaciones en curso (el máximo). Esperá a que termine alguna.")
	end
	local pi, cost, days, info = Rules.researchCost(g, n)
	if g.rp < pi then
		return fail("Faltan PI: cuesta " .. Util.num(pi) .. " PI y tenés " .. Util.num(math.floor(g.rp)) .. ".")
	end
	if not Simulation.canAfford(g, cost) then
		return fail("Fondos insuficientes: cuesta " .. money(cost) .. ".")
	end
	Simulation.spend(g, cost, "investigacion", "Investigación: " .. n.name)
	g.rp -= pi
	table.insert(g.research.projects, { id = n.id, progress = 0, days = days, paidMoney = cost, paidPi = pi, ahead = info.ahead, startDay = Rules.absDay(g) })
	return {
		ok = true,
		msg = "Investigando «" .. n.name .. "»: " .. Util.num(pi) .. " PI y " .. money(cost) .. " pagados, " .. days .. " días"
			.. (info.ahead > 0 and (" (adelantada " .. info.ahead .. (info.ahead == 1 and " año" or " años") .. ": recargo incluido)") or "") .. ".",
	}
end

-- Las investigaciones no se cancelan (los costos ya se pagaron).
function Actions.cancelResearch(_g: any, _ctx: any, _payload: any): any
	return fail("Las investigaciones en curso no se pueden cancelar.")
end

-- Personal ------------------------------------------------------------------------------------

--[[ Contratar: sin costo de contratación (se paga el salario cada mes). payload = { candidateId, dept }: el
	jugador elige el departamento donde empieza (fuera de su especialidad arranca con adaptación). ]]
function Actions.hire(g: any, ctx: any, payload: any): any
	local c, i = findById(g.candidates, arg(payload, "candidateId"))
	if not c then
		return fail("Ese candidato ya no está disponible.")
	end
	local dept = arg(payload, "dept")
	if dept == nil then
		dept = c.spec
	end
	if not Staff.dept(dept) then
		return fail("Departamento desconocido.")
	end
	if #g.employees >= Rules.caps(g).staff then
		return fail("Llegaste al límite de " .. Rules.caps(g).staff .. " empleados. Mejorá las oficinas centrales para contratar más.")
	end
	table.remove(g.candidates, i :: number)
	local e = {
		id = GameState.uid(g, "e"), name = c.name, spec = c.spec, dept = dept, salary = c.salary,
		skills = Util.deepCopy(c.skills), potential = Util.deepCopy(c.potential), months = 0,
		hiredDay = Rules.absDay(g), adapt = {}, status = "activo", training = nil,
	}
	table.insert(g.employees, e)
	g.counters.hires += 1
	Simulation.addXp(g, ctx, 40)
	local where = Staff.dept(dept).name
	return { ok = true, msg = c.name .. " se sumó a " .. where .. " (" .. money(c.salary) .. " por mes)." .. (dept ~= c.spec and " Fuera de su especialidad empieza al " .. round(Catalog.STAFF.adaptStart * 100) .. " % y se adapta con el tiempo." or "") }
end

--[[ Búsqueda paga de candidatos: reemplaza a los 8 actuales que no se contrataron (no se acumulan).
	payload = { kind = "general" | "especializada", dept? }. Cada búsqueda del mes cuesta 50 % más que la
	anterior (contador compartido, vuelve a cero cada mes); la especializada parte de un costo 50 % mayor. ]]
function Actions.searchCandidates(g: any, ctx: any, payload: any): any
	local kind = arg(payload, "kind")
	local focus = nil
	if kind == "especializada" then
		focus = arg(payload, "dept")
		if not Staff.dept(focus) then
			return fail("Elegí el departamento de la búsqueda.")
		end
	elseif kind ~= "general" then
		return fail("Tipo de búsqueda desconocido.")
	end
	Simulation.ensureMarket(g, ctx)
	local cost = Staff.searchCost(g, focus ~= nil, Rules.year(g))
	if not Simulation.spend(g, cost, "contratacion", (focus and "Búsqueda especializada" or "Búsqueda general") .. " de candidatos") then
		return fail("Fondos insuficientes: la búsqueda cuesta " .. money(cost) .. ".")
	end
	g.market.searches += 1
	Simulation.refreshCandidates(g, ctx, focus)
	return { ok = true, msg = "Búsqueda " .. (focus and ("especializada en " .. Staff.dept(focus).name) or "general") .. ": " .. #g.candidates .. " candidatos nuevos (" .. money(cost) .. "). La próxima del mes cuesta " .. money(Staff.searchCost(g, focus ~= nil, Rules.year(g))) .. "." }
end

--[[ Capacitación: payload = { scope = "individual" | "departamento" | "general", level, skill, employeeId?, dept? }.
	El costo y el resultado de cada participante se calculan en el servidor (Staff.trainingPlan, el mismo cálculo
	que muestra la vista previa), se pagan al empezar y la mejora es la anunciada. ]]
function Actions.startTraining(g: any, _ctx: any, payload: any): any
	g.trainings = g.trainings or {}
	if #g.trainings >= Catalog.TRAINING.maxActive then
		return fail("Ya hay " .. Catalog.TRAINING.maxActive .. " capacitaciones en curso.")
	end
	local req = {
		scope = arg(payload, "scope"), level = arg(payload, "level"), skill = arg(payload, "skill"),
		employeeId = arg(payload, "employeeId"), dept = arg(payload, "dept"),
	}
	local plan, why = Staff.trainingPlan(g, req, Rules.officeLevel(g), Rules.year(g))
	if not plan then
		return fail(why or "No se puede capacitar.")
	end
	if not Simulation.spend(g, plan.cost, "capacitacion", "Capacitación " .. plan.level.name .. " en " .. Staff.skill(req.skill).name) then
		return fail("Fondos insuficientes: la capacitación cuesta " .. money(plan.cost) .. ".")
	end
	local t = { id = GameState.uid(g, "t"), level = plan.level.id, skill = req.skill, scope = req.scope, members = {}, results = {}, progress = 0, days = plan.days, cost = plan.cost }
	for _, m in plan.members do
		table.insert(t.members, m.id)
		t.results[m.id] = m.to
		local e = findById(g.employees, m.id)
		e.training = t.id
	end
	table.insert(g.trainings, t)
	return { ok = true, msg = "Capacitación " .. plan.level.name .. " en " .. Staff.skill(req.skill).name .. ": " .. #plan.members .. (#plan.members == 1 and " participante" or " participantes") .. ", " .. money(plan.cost) .. ", " .. plan.days .. " días. Mejora garantizada: +" .. plan.gain .. " (hasta el potencial de cada uno)." }
end

-- Despido: requiere pagar la indemnización (salario × años trabajados, proporcional). Nunca es automático.
function Actions.fire(g: any, _ctx: any, payload: any): any
	local e, i = findById(g.employees, arg(payload, "employeeId"))
	if not e then
		return fail("El empleado ya no está.")
	end
	local cost = Staff.severance(e, Rules.absDay(g))
	if not Simulation.canAfford(g, cost) then
		return fail("No alcanza para la indemnización de " .. e.name .. ": " .. money(cost) .. ".")
	end
	if cost > 0 then
		Simulation.spend(g, cost, "indemnizacion", "Indemnización de " .. e.name)
	end
	for _, t in g.trainings or {} do
		local k = table.find(t.members, e.id)
		if k then
			table.remove(t.members, k)
		end
	end
	table.remove(g.employees, i :: number)
	return { ok = true, msg = e.name .. " dejó la empresa. Indemnización: " .. money(cost) .. "." }
end

-- Cambio de departamento: conserva todas sus habilidades y la adaptación ganada en cada departamento.
function Actions.setDept(g: any, _ctx: any, payload: any): any
	local e = findById(g.employees, arg(payload, "employeeId"))
	local dept = arg(payload, "dept")
	if not e then
		return fail("El empleado ya no está.")
	end
	if not Staff.dept(dept) then
		return fail("Departamento desconocido.")
	end
	if e.dept == dept then
		return { ok = true, quiet = true }
	end
	e.dept = dept
	local adapt = Staff.adaptation(e)
	return { ok = true, msg = e.name .. " pasó a " .. Staff.dept(dept).name .. (dept == e.spec and " (su especialidad)." or (": rinde al " .. round(adapt * 100) .. " % mientras se adapta.")) }
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
	if Rules.missionValue(g, m) < Rules.missionGoal(g, m) then
		return fail("Todavía no completaste la misión.")
	end
	g.claimed[key] = true
	local reward = Rules.missionReward(g, m)
	if reward.money then
		Simulation.earn(g, reward.money, "recompensa", "Misión: " .. m.title)
	end
	if reward.pi then
		g.rp += reward.pi -- los PI de objetivos no tienen tope
	end
	if reward.xp then
		Simulation.addXp(g, ctx, reward.xp)
	end
	return { ok = true, msg = "Recompensa reclamada: " .. Rules.rewardText(reward) }
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
	if r.pi then
		g.rp += r.pi
	end
	return { ok = true, msg = "Recompensa diaria: " .. Rules.rewardText(r) .. " · racha " .. g.daily.streak }
end

-- payload = { skipped = bool } (saltar / reactivar guías) o { tips = false } («Entendido» del globo).
function Actions.setTutorial(g: any, _ctx: any, payload: any): any
	local tips = arg(payload, "tips")
	if tips ~= nil then
		g.tutorial.tips = tips == true
		return { ok = true, quiet = true }
	end
	g.tutorial.skipped = arg(payload, "skipped") == true
	if not g.tutorial.skipped then
		g.tutorial.tips = true
	end
	return { ok = true, quiet = not g.tutorial.skipped, msg = g.tutorial.skipped and "Guías ocultas. Las misiones siguen activas en Misiones." or "" }
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

function Actions.setSpeed(g: any, _ctx: any, payload: any): any
	local v = arg(payload, "speed")
	if not Util.contains(Catalog.RULES.speeds, v) then
		return fail("Velocidad inválida.")
	end
	g.time.speed = v
	return { ok = true, msg = v == 0 and "Simulación en pausa." or ("Velocidad " .. v .. "×."), quiet = true }
end

Actions.handlers = {
	setIdentity = Actions.setIdentity, expandSede = Actions.expandSede, expandGlobal = Actions.expandGlobal,
	saveDesign = Actions.saveDesign, dupDesign = Actions.dupDesign, delDesign = Actions.delDesign,
	createLot = Actions.createLot, launchSale = Actions.launchSale, setLotPrice = Actions.setLotPrice, toggleLotPause = Actions.toggleLotPause, moveLot = Actions.moveLot,
	closeSale = Actions.closeSale, upgradeStation = Actions.upgradeStation, startCampaign = Actions.startCampaign, cancelCampaign = Actions.cancelCampaign,
	startResearch = Actions.startResearch, cancelResearch = Actions.cancelResearch,
	hire = Actions.hire, searchCandidates = Actions.searchCandidates, fire = Actions.fire, setDept = Actions.setDept, startTraining = Actions.startTraining,
	claimMission = Actions.claimMission, claimDaily = Actions.claimDaily, setTutorial = Actions.setTutorial, markRead = Actions.markRead,
	setSpeed = Actions.setSpeed,
}

-- Consultas sin efectos: no marcan la partida como modificada ni requieren identificador único.
Actions.readOnly = { saveNow = true }

-- Acciones económicas: llevan un identificador de solicitud para que un reenvío no se aplique dos veces.
Actions.economic = {
	saveDesign = true, dupDesign = true, delDesign = true, createLot = true, launchSale = true, setLotPrice = true, closeSale = true,
	upgradeStation = true, startCampaign = true, cancelCampaign = true, moveLot = true, toggleLotPause = true, startResearch = true, cancelResearch = true, hire = true, searchCandidates = true, fire = true, setDept = true, startTraining = true,
	claimMission = true, claimDaily = true, expandSede = true, expandGlobal = true,
}

-- Acciones que justifican guardar enseguida (además del autoguardado periódico).
Actions.important = Actions.economic

return Actions
