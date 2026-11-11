--!strict
--[[ Oficinas centrales: reglas puras del sistema de decoración (etapa 1: datos y servicios, sin editor ni 3D).
	No usa servicios de Roblox: lo usan el servidor (OfficeService, migraciones, guardado) y, más adelante, el
	editor del cliente para previsualizar con las mismas reglas.

	Datos por empresa (g.office):
	  version   = OfficeCatalog.VERSION
	  level     = nivel de oficinas para el que está armada la distribución (sigue a g.sede)
	  seq       = contador de identificadores de instancia (propio: no toca g.nextId)
	  inventory = { [idMueble] = cantidad } muebles propios GUARDADOS (enteros ≥ 0; nunca negativos)
	  placed    = { { id, item, room, x, y, rot } } muebles propios COLOCADOS. x, y = centro del mueble en
	              casillas de la habitación (múltiplos de 0,5), rot = grados (múltiplo de 45)
	  finishes  = { [idHabitación] = { floor, wall, covering, lighting } }
	  starter   = true cuando ya se entregó el mobiliario inicial (idempotente)
	  ops       = últimos identificadores de operación aplicados (evita aplicar dos veces la misma solicitud)
	Un mueble propio está guardado (cuenta en inventory) o colocado (una entrada en placed), nunca en ambos. ]]

local OfficeCatalog = require(script.Parent.OfficeCatalog)

local Office = {}

local MAX_OPS = 32 -- operaciones recientes recordadas
local MAX_PLACED = 400 -- protección del guardado contra datos dañados
local EPS = 1e-6

-- Creación, verificación y reparación ------------------------------------------------------------

local function defaultFinish(): any
	return table.clone(OfficeCatalog.DEFAULT_FINISH)
end

function Office.new(level: number?): any
	local lvl = math.clamp(math.floor(level or 1), 1, #OfficeCatalog.PLANS)
	local o = { version = OfficeCatalog.VERSION, level = lvl, seq = 0, inventory = {}, placed = {}, finishes = {}, starter = false, ops = {} }
	for _, r in OfficeCatalog.plan(lvl).rooms do
		o.finishes[r.id] = defaultFinish()
	end
	return o
end

local function isInt(v: any, lo: number?): boolean
	return type(v) == "number" and v == v and v % 1 == 0 and (lo == nil or v >= lo)
end
local function isHalf(v: any): boolean
	return type(v) == "number" and v == v and math.abs(v) < 1e6 and (v * 2) % 1 == 0
end

-- Verificación estricta (la usa GameState.validate después de Office.sanitize). Devuelve (ok, motivo).
function Office.validate(o: any): (boolean, string?)
	if type(o) ~= "table" then
		return false, "Faltan los datos de la oficina."
	end
	if o.version ~= OfficeCatalog.VERSION or not isInt(o.level, 1) or o.level > #OfficeCatalog.PLANS or not isInt(o.seq, 0) then
		return false, "La versión o el nivel de la oficina están dañados."
	end
	if type(o.inventory) ~= "table" or type(o.placed) ~= "table" or type(o.finishes) ~= "table" or type(o.ops) ~= "table" or type(o.starter) ~= "boolean" or (o.storedFinishes ~= nil and type(o.storedFinishes) ~= "table") then
		return false, "La oficina está dañada."
	end
	for id, n in o.inventory do
		if not OfficeCatalog.item(id) or not isInt(n, 0) then
			return false, "El inventario de muebles está dañado."
		end
	end
	if #o.placed > MAX_PLACED then
		return false, "Demasiados muebles colocados."
	end
	local seen = {}
	for _, p in o.placed do
		if type(p) ~= "table" or type(p.id) ~= "string" or seen[p.id] or not OfficeCatalog.item(p.item) or type(p.room) ~= "string" then
			return false, "Un mueble colocado está dañado."
		end
		if not isHalf(p.x) or not isHalf(p.y) or not isInt(p.rot, 0) or p.rot % 45 ~= 0 or p.rot >= 360 then
			return false, "La posición de un mueble está dañada."
		end
		seen[p.id] = true
	end
	for roomId, f in o.finishes do
		if type(roomId) ~= "string" or type(f) ~= "table" then
			return false, "Los acabados están dañados."
		end
		for kind in OfficeCatalog.DEFAULT_FINISH do
			if not OfficeCatalog.finish(kind, f[kind]) then
				return false, "Un acabado es desconocido."
			end
		end
	end
	return true, nil
end

--[[ Repara sin perder objetos (al cargar): crea lo que falte, descarta cantidades inválidas y devuelve al
	inventario los muebles colocados en lugares que ya no son válidos. Solo elimina lo que no se puede
	recuperar (un tipo de mueble que no existe en el catálogo). Idempotente. ]]
function Office.sanitize(g: any)
	local level = math.clamp(math.floor(tonumber(g.sede) or 1), 1, #OfficeCatalog.PLANS)
	local o = g.office
	if type(o) ~= "table" then
		g.office = Office.new(level)
		return
	end
	o.version = OfficeCatalog.VERSION
	if not isInt(o.level, 1) or o.level > #OfficeCatalog.PLANS then
		o.level = level
	end
	if not isInt(o.seq, 0) then
		o.seq = 0
	end
	if type(o.inventory) ~= "table" then
		o.inventory = {}
	end
	for id, n in o.inventory do
		if not OfficeCatalog.item(id) or not isInt(n, 0) or n == 0 then
			o.inventory[id] = (OfficeCatalog.item(id) and isInt(n, 1)) and n or nil
		end
	end
	if type(o.placed) ~= "table" then
		o.placed = {}
	end
	local seen = {}
	local keep = {}
	for _, p in o.placed do
		if type(p) == "table" and OfficeCatalog.item(p.item) then
			if type(p.id) ~= "string" or seen[p.id] or not isHalf(p.x) or not isHalf(p.y) or not isInt(p.rot, 0) or p.rot % 45 ~= 0 or p.rot >= 360 or #keep >= MAX_PLACED then
				o.inventory[p.item] = (o.inventory[p.item] or 0) + 1 -- no se pierde: vuelve al inventario
			else
				seen[p.id] = true
				table.insert(keep, p)
			end
		end
	end
	o.placed = keep
	if type(o.finishes) ~= "table" then
		o.finishes = {}
	end
	for roomId, f in o.finishes do
		if type(roomId) ~= "string" or type(f) ~= "table" then
			o.finishes[roomId] = nil
		else
			for kind, def in OfficeCatalog.DEFAULT_FINISH do
				if not OfficeCatalog.finish(kind, f[kind]) then
					f[kind] = def
				end
			end
		end
	end
	for _, r in OfficeCatalog.plan(o.level).rooms do
		o.finishes[r.id] = o.finishes[r.id] or defaultFinish()
	end
	if type(o.starter) ~= "boolean" then
		o.starter = false
	end
	if type(o.ops) ~= "table" then
		o.ops = {}
	end
	if o.storedFinishes ~= nil and type(o.storedFinishes) ~= "table" then
		o.storedFinishes = nil
	end
	-- Lugares que dejaron de ser válidos (por ejemplo, un plano corregido): al inventario.
	Office.evictInvalid(o)
	-- La distribución sigue al nivel real de las oficinas (por ejemplo, si una ampliación terminó en una
	-- versión sin este sistema).
	if o.level ~= level then
		Office.remap(o, level)
	end
end

-- Catálogo histórico --------------------------------------------------------------------------------

-- ¿Está a la venta en ese año? Desde su año en adelante, para siempre (los antiguos nunca desaparecen).
function Office.available(item: any, year: number): boolean
	return item ~= nil and type(year) == "number" and year >= item.year
end

function Office.catalogFor(year: number): { any }
	local out = {}
	for _, f in OfficeCatalog.FURNITURE do
		if Office.available(f, year) then
			table.insert(out, f)
		end
	end
	table.sort(out, function(a: any, b: any): boolean
		if a.category ~= b.category then
			return a.category < b.category
		end
		if a.year ~= b.year then
			return a.year < b.year
		end
		return a.id < b.id
	end)
	return out
end

-- Inventario ------------------------------------------------------------------------------------------

function Office.count(o: any, itemId: string): number
	return (o.inventory and o.inventory[itemId]) or 0
end

function Office.placedCount(o: any, itemId: string): number
	local n = 0
	for _, p in o.placed do
		if p.item == itemId then
			n += 1
		end
	end
	return n
end

-- Total propio (guardados + colocados).
function Office.owned(o: any, itemId: string): number
	return Office.count(o, itemId) + Office.placedCount(o, itemId)
end

-- Agrega n unidades compradas o recuperadas al inventario (n entero ≥ 1).
function Office.addToInventory(o: any, itemId: string, n: number?): boolean
	local k = n or 1
	if not OfficeCatalog.item(itemId) or not isInt(k, 1) then
		return false
	end
	o.inventory[itemId] = Office.count(o, itemId) + k
	return true
end

-- Saca una unidad del inventario (para colocarla). Nunca deja cantidades negativas.
function Office.takeFromInventory(o: any, itemId: string): boolean
	local n = Office.count(o, itemId)
	if n < 1 then
		return false
	end
	o.inventory[itemId] = n > 1 and n - 1 or nil
	return true
end

function Office.find(o: any, instanceId: string): (any?, number?)
	for i, p in o.placed do
		if p.id == instanceId then
			return p, i
		end
	end
	return nil, nil
end

-- Retira un mueble colocado: deja la distribución y vuelve al inventario (sin reembolso ni copia nueva).
function Office.removePlaced(o: any, instanceId: string): boolean
	local p, i = Office.find(o, instanceId)
	if not p or not i then
		return false
	end
	table.remove(o.placed, i)
	Office.addToInventory(o, p.item, 1)
	return true
end

function Office.newInstanceId(o: any): string
	o.seq += 1
	return "m" .. o.seq
end

-- Operaciones repetidas: una misma solicitud (opId) se aplica una sola vez.
function Office.seenOp(o: any, opId: any): boolean
	return type(opId) == "string" and table.find(o.ops, opId) ~= nil
end
function Office.rememberOp(o: any, opId: any)
	if type(opId) ~= "string" or #opId == 0 or #opId > 64 then
		return
	end
	table.insert(o.ops, opId)
	while #o.ops > MAX_OPS do
		table.remove(o.ops, 1)
	end
end

-- Cuadrícula, rotaciones y validación ----------------------------------------------------------------

function Office.validRotation(item: any, rot: any): boolean
	return isInt(rot, 0) and rot < 360 and rot % 45 == 0 and table.find(item.rotations, rot) ~= nil
end

function Office.isDiagonal(rot: number): boolean
	return rot % 90 ~= 0
end

--[[ Casillas que ocupa un mueble con centro (x, y) y giro rot: las casillas cuyo centro cae dentro del
	rectángulo girado. Con giros de 90° es exactamente w × d (o d × w); en diagonal ocupa las casillas que
	realmente cubre. Devuelve { { cx, cy } }. ]]
function Office.footprint(item: any, x: number, y: number, rot: number): { { number } }
	local w, d = item.cells[1], item.cells[2]
	local a = math.rad(rot)
	local c, s = math.cos(a), math.sin(a)
	local hw, hd = w / 2, d / 2
	local reach = math.ceil(math.sqrt(hw * hw + hd * hd)) + 1
	local out = {}
	for cx = math.floor(x - reach), math.ceil(x + reach) do
		for cy = math.floor(y - reach), math.ceil(y + reach) do
			local px, py = cx + 0.5 - x, cy + 0.5 - y
			-- Al sistema del mueble (giro inverso).
			local u = px * c + py * s
			local v = -px * s + py * c
			if math.abs(u) < hw - EPS and math.abs(v) < hd - EPS then
				table.insert(out, { cx, cy })
			end
		end
	end
	if #out == 0 then
		table.insert(out, { math.floor(x), math.floor(y) })
	end
	return out
end

--[[ Alineación con la cuadrícula: con giros rectos el borde del mueble cae sobre líneas de la cuadrícula
	(un lado par se centra en una línea; uno impar, en el medio de una casilla). En diagonal basta con medias
	casillas. Sin esto, un mueble de 2 casillas centrado en media casilla ocuparía una sola. ]]
function Office.aligned(item: any, x: number, y: number, rot: number): boolean
	if Office.isDiagonal(rot) then
		return true
	end
	local w, d = item.cells[1], item.cells[2]
	if rot % 180 == 90 then
		w, d = d, w
	end
	return (x - w / 2) % 1 == 0 and (y - d / 2) % 1 == 0
end

-- Punto de uso del avatar en coordenadas de la habitación (gira con el mueble).
function Office.interactionPoint(item: any, p: any): any
	local it = item.interaction
	if not it then
		return nil
	end
	local a = math.rad(p.rot)
	local c, s = math.cos(a), math.sin(a)
	return {
		kind = it.kind,
		x = p.x + it.dx * c - it.dy * s,
		y = p.y + it.dx * s + it.dy * c,
		facing = (it.facing + p.rot) % 360,
	}
end

-- Validación adicional opcional (etapa 2: colisiones 3D con el modelo del edificio). fn(o, room, item,
-- placement, cells) -> (ok, motivo). Nil = solo cuadrícula.
Office.extraCheck = nil :: ((any, any, any, any, { { number } }) -> (boolean, string?))?

--[[ ¿Se puede ubicar `item` en { room, x, y, rot }? ignoreId = instancia que se está moviendo (no choca consigo
	misma). Comprueba: habitación del plano actual, giro permitido, coordenadas en medias casillas, dentro de
	la habitación, sin pisar accesos obligatorios ni casillas ocupadas. Devuelve (ok, motivo, casillas). ]]
function Office.validatePlacement(o: any, item: any, req: any, ignoreId: string?): (boolean, string?, { { number } }?)
	if not item then
		return false, "Mueble desconocido.", nil
	end
	if type(req) ~= "table" then
		return false, "Ubicación inválida.", nil
	end
	local r = type(req.room) == "string" and OfficeCatalog.room(o.level, req.room) or nil
	if not r then
		return false, "Esa habitación no existe en estas oficinas.", nil
	end
	if not Office.validRotation(item, req.rot) then
		return false, "Ese giro no está permitido para este mueble.", nil
	end
	if not isHalf(req.x) or not isHalf(req.y) then
		return false, "Ubicación inválida.", nil
	end
	if not Office.aligned(item, req.x, req.y, req.rot) then
		return false, "El mueble no está alineado con la cuadrícula.", nil
	end
	local cells = Office.footprint(item, req.x, req.y, req.rot)
	local blocked = {}
	for _, a in r.access do
		blocked[a[1] .. ":" .. a[2]] = "acceso"
	end
	for _, p in o.placed do
		if p.room == r.id and p.id ~= ignoreId then
			local other = OfficeCatalog.item(p.item)
			if other then
				for _, cell in Office.footprint(other, p.x, p.y, p.rot) do
					blocked[cell[1] .. ":" .. cell[2]] = "ocupada"
				end
			end
		end
	end
	for _, cell in cells do
		if cell[1] < 0 or cell[2] < 0 or cell[1] >= r.w or cell[2] >= r.d then
			return false, "El mueble se sale de la habitación.", cells
		end
		local b = blocked[cell[1] .. ":" .. cell[2]]
		if b == "acceso" then
			return false, "Bloquearía un acceso (puerta o paso).", cells
		elseif b == "ocupada" then
			return false, "Ese lugar ya está ocupado.", cells
		end
	end
	if Office.extraCheck then
		local ok, why = Office.extraCheck(o, r, item, req, cells)
		if not ok then
			return false, why or "No entra en ese lugar.", cells
		end
	end
	return true, nil, cells
end

-- Devuelve al inventario los muebles cuya ubicación ya no es válida en el plano actual. Devuelve cuántos.
function Office.evictInvalid(o: any): number
	local moved = 0
	local keep = {}
	local probe = { level = o.level, placed = keep }
	for _, p in o.placed do
		local item = OfficeCatalog.item(p.item)
		if item and Office.validatePlacement(probe, item, p, p.id) then
			table.insert(keep, p)
		elseif item then
			Office.addToInventory(o, p.item, 1)
			moved += 1
		end
	end
	o.placed = keep
	return moved
end

-- Mobiliario inicial ----------------------------------------------------------------------------------

-- Escritorio y silla iniciales, una sola vez por empresa (marca `starter`). Idempotente.
function Office.grantStarter(o: any): number
	if o.starter then
		return 0
	end
	o.starter = true
	local n = 0
	for _, s in OfficeCatalog.STARTER do
		local item = OfficeCatalog.item(s.item)
		local req = { room = s.room, x = s.x, y = s.y, rot = s.rot }
		if item and Office.validatePlacement(o, item, req) then
			table.insert(o.placed, { id = Office.newInstanceId(o), item = s.item, room = s.room, x = s.x, y = s.y, rot = s.rot })
		else
			Office.addToInventory(o, s.item, 1)
		end
		n += 1
	end
	return n
end

-- Ampliaciones ----------------------------------------------------------------------------------------

--[[ Pasa la distribución al plano de otro nivel de oficinas: conserva muebles y acabados de las habitaciones
	equivalentes (mismo id o OfficeCatalog.ROOM_MAP), manda al inventario lo que no tenga lugar válido y da
	acabados básicos a las habitaciones nuevas. No se pierde ningún objeto. Devuelve { kept, toInventory }. ]]
function Office.remap(o: any, newLevel: number): any
	local lvl = math.clamp(math.floor(newLevel), 1, #OfficeCatalog.PLANS)
	if lvl == o.level then
		return { kept = #o.placed, toInventory = 0 }
	end
	for _, p in o.placed do
		p.room = OfficeCatalog.ROOM_MAP[p.room] or p.room
	end
	local finishes = {}
	for roomId, f in o.finishes do
		local to = OfficeCatalog.ROOM_MAP[roomId] or roomId
		finishes[to] = finishes[to] or f
	end
	o.level = lvl
	local moved = Office.evictInvalid(o)
	o.finishes = {}
	for _, r in OfficeCatalog.plan(lvl).rooms do
		o.finishes[r.id] = finishes[r.id] or defaultFinish()
	end
	-- Los acabados de habitaciones que el plano nuevo no tiene se guardan aparte (por si vuelven a existir).
	o.storedFinishes = o.storedFinishes or {}
	for roomId, f in finishes do
		if not o.finishes[roomId] then
			o.storedFinishes[roomId] = f
		end
	end
	return { kept = #o.placed, toInventory = moved }
end

-- Bonificaciones (sin conectar a la simulación) ------------------------------------------------------------

--[[ Aporte del mobiliario COLOCADO a una habilidad (misma unidad que Staff.contribution): por cada tipo de
	mueble, la n-ésima copia suma value × BONUS_DECAY^(n−1). Lo guardado no suma. ]]
function Office.furnitureRaw(o: any, skillId: string): number
	local copies: { [string]: number } = {}
	local total = 0
	for _, p in (o and o.placed) or {} do
		local item = OfficeCatalog.item(p.item)
		if item and item.bonus and item.bonus.skill == skillId then
			local n = (copies[p.item] or 0) + 1
			copies[p.item] = n
			total += item.bonus.value * OfficeCatalog.BONUS_DECAY ^ (n - 1)
		end
	end
	return total
end

--[[ Bonificación combinada personal + mobiliario con el tope único de la habilidad:
	min(tope, aporte del personal + aporte de los muebles). staffRaw y cap salen de Staff.bonusDetail.
	Para conectarlo (etapa posterior) basta con que Rules.staff use esta función en lugar de Staff.bonus:
	así hay una sola aplicación de cada bonificación. ]]
function Office.sharedBonus(staffRaw: number, furnitureRaw: number, cap: number): number
	return math.min(cap, math.max(0, staffRaw) + math.max(0, furnitureRaw))
end

-- Acabados y remodelaciones (cotización; el cobro llega con el editor) ---------------------------------------

function Office.roomArea(r: any): number
	return r.w * r.d
end
function Office.wallLength(r: any): number
	return 2 * (r.w + r.d)
end

-- Cantidad de unidades de un acabado en una habitación según su unidad (superficie, largo o luminarias).
function Office.finishQuantity(r: any, finish: any): number
	if finish.unit == "casilla" then
		return Office.roomArea(r)
	elseif finish.unit == "tramo" then
		return Office.wallLength(r)
	end
	return math.max(1, math.ceil(Office.roomArea(r) / OfficeCatalog.LIGHT_AREA))
end

--[[ Cotización de una remodelación: changes = { floor?, wall?, covering?, lighting? } con ids de acabado.
	Previsualizar es gratis: esto solo calcula. Lo que ya tiene la habitación no se vuelve a cobrar.
	Devuelve (costo, detalle) o (nil, motivo). ]]
function Office.remodelQuote(o: any, roomId: string, changes: any, year: number): (number?, any)
	local r = OfficeCatalog.room(o.level, roomId)
	if not r then
		return nil, "Esa habitación no existe en estas oficinas."
	end
	if type(changes) ~= "table" then
		return nil, "Sin cambios."
	end
	local current = o.finishes[roomId] or OfficeCatalog.DEFAULT_FINISH
	local total, lines = 0, {}
	for kind in OfficeCatalog.DEFAULT_FINISH do
		local id = changes[kind]
		if id ~= nil and id ~= current[kind] then
			local f = OfficeCatalog.finish(kind, id)
			if not f then
				return nil, "Acabado desconocido."
			end
			if year < f.year then
				return nil, f.name .. " todavía no está disponible."
			end
			local qty = Office.finishQuantity(r, f)
			local cost = qty * f.price
			total += cost
			table.insert(lines, { kind = kind, id = id, qty = qty, unit = f.unit, cost = cost })
		end
	end
	return total, lines
end

-- Avatar autónomo (metadatos; OwnerAvatar los usará en una etapa posterior) ------------------------------

--[[ Puntos de interacción de los muebles colocados: { { instance, item, room, kind, x, y, facing } } en
	coordenadas de la habitación. kinds: "work" (escritorio), "sit" (silla), "rest" (sofá), "browse"
	(estantería). ]]
function Office.interactionSpots(o: any, roomId: string?): { any }
	local out = {}
	for _, p in (o and o.placed) or {} do
		if roomId == nil or p.room == roomId then
			local item = OfficeCatalog.item(p.item)
			local pt = item and Office.interactionPoint(item, p)
			if pt then
				pt.instance, pt.item, pt.room = p.id, p.item, p.room
				table.insert(out, pt)
			end
		end
	end
	return out
end

return Office
