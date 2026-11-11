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

-- Creación, verificación y reparación ------------------------------------------------------------

local function defaultFinish(): any
	return table.clone(OfficeCatalog.DEFAULT_FINISH)
end

function Office.new(level: number?): any
	local lvl = math.clamp(math.floor(level or 1), 1, #OfficeCatalog.PLANS)
	local o = { version = OfficeCatalog.VERSION, level = lvl, seq = 0, rev = 0, inventory = {}, placed = {}, finishes = {}, starter = false, ops = {} }
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
	if o.rev ~= nil and not isInt(o.rev, 0) then
		return false, "La revisión de la oficina está dañada."
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
		local n = tonumber(string.match(p.id, "^m(%d+)$"))
		if n and n > o.seq then
			return false, "El contador de muebles está atrasado."
		end
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
	Office.syncSeq(o)
	if not isInt(o.rev, 0) then
		o.rev = 0
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

-- Muebles guardados en el inventario, sin importar su año (lo propio siempre se puede colocar):
-- { { item, count } } ordenados por categoría, año y nombre.
function Office.inventoryList(o: any): { any }
	local out = {}
	for id, n in (o and o.inventory) or {} do
		local item = OfficeCatalog.item(id)
		if item and type(n) == "number" and n > 0 then
			table.insert(out, { item = item, count = n })
		end
	end
	table.sort(out, function(a: any, b: any): boolean
		local x, y = a.item, b.item
		if x.category ~= y.category then
			return x.category < y.category
		end
		if x.year ~= y.year then
			return x.year < y.year
		end
		return x.name < y.name
	end)
	return out
end

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

-- Número del id de instancia («m12» → 12) o nil.
local function idNumber(id: any): number?
	return type(id) == "string" and tonumber(string.match(id, "^m(%d+)$")) or nil
end

-- seq nunca queda por debajo de un id existente (tras migrar o reparar datos no se reutilizan ids).
function Office.syncSeq(o: any)
	local top = isInt(o.seq, 0) and o.seq or 0
	for _, p in o.placed or {} do
		local n = idNumber(p.id)
		if n and n > top then
			top = n
		end
	end
	o.seq = top
end

function Office.newInstanceId(o: any): string
	Office.syncSeq(o)
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

-- Geometría ----------------------------------------------------------------------------------------------
-- Cada mueble es un rectángulo girado (centro x, y; lados w × d en casillas; giro rot). Las colisiones se
-- calculan con la intersección real de polígonos convexos (teorema del eje separador), no con muestras.

local GEO_EPS = 1e-4 -- tolerancia: tocarse por un borde no es superponerse

-- Esquinas del rectángulo de un mueble, en casillas de la habitación.
function Office.corners(item: any, x: number, y: number, rot: number): { { number } }
	local hw, hd = item.cells[1] / 2, item.cells[2] / 2
	local a = math.rad(rot)
	local c, s = math.cos(a), math.sin(a)
	local out = {}
	for _, k in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local u, v = k[1] * hw, k[2] * hd
		table.insert(out, { x + u * c - v * s, y + u * s + v * c })
	end
	return out
end

local function square(cx: number, cy: number): { { number } }
	return { { cx, cy }, { cx + 1, cy }, { cx + 1, cy + 1 }, { cx, cy + 1 } }
end
Office.cellPolygon = square

local function project(poly: { { number } }, ax: number, ay: number): (number, number)
	local lo, hi = math.huge, -math.huge
	for _, p in poly do
		local d = p[1] * ax + p[2] * ay
		lo, hi = math.min(lo, d), math.max(hi, d)
	end
	return lo, hi
end

-- ¿Se superponen dos polígonos convexos con área (más que tocarse)?
function Office.overlaps(a: { { number } }, b: { { number } }): boolean
	for _, poly in { a, b } do
		local n = #poly
		for i = 1, n do
			local p, q = poly[i], poly[i % n + 1]
			local ax, ay = q[2] - p[2], p[1] - q[1]
			local len = math.sqrt(ax * ax + ay * ay)
			if len > 0 then
				ax, ay = ax / len, ay / len
				local a1, a2 = project(a, ax, ay)
				local b1, b2 = project(b, ax, ay)
				if a2 <= b1 + GEO_EPS or b2 <= a1 + GEO_EPS then
					return false -- eje separador
				end
			end
		end
	end
	return true
end

-- ¿El polígono queda dentro de la habitación (0..w × 0..d)?
function Office.insideRoom(poly: { { number } }, r: any): boolean
	for _, p in poly do
		if p[1] < -GEO_EPS or p[2] < -GEO_EPS or p[1] > r.w + GEO_EPS or p[2] > r.d + GEO_EPS then
			return false
		end
	end
	return true
end

--[[ Casillas que toca un mueble (con área en común, también en diagonal): para la cuadrícula del editor y
	para mostrar qué ocupa. Devuelve { { cx, cy } }. ]]
function Office.footprint(item: any, x: number, y: number, rot: number): { { number } }
	local poly = Office.corners(item, x, y, rot)
	local lx, ly, hx, hy = math.huge, math.huge, -math.huge, -math.huge
	for _, p in poly do
		lx, ly, hx, hy = math.min(lx, p[1]), math.min(ly, p[2]), math.max(hx, p[1]), math.max(hy, p[2])
	end
	local out = {}
	for cx = math.floor(lx), math.ceil(hx) - 1 do
		for cy = math.floor(ly), math.ceil(hy) - 1 do
			if Office.overlaps(poly, square(cx, cy)) then
				table.insert(out, { cx, cy })
			end
		end
	end
	return out
end

-- ¿El punto (x, y) de la habitación cae sobre este mueble colocado? (selección en el editor)
function Office.hits(p: any, x: number, y: number): boolean
	local item = OfficeCatalog.item(p.item)
	if not item then
		return false
	end
	local a = math.rad(p.rot)
	local c, s = math.cos(a), math.sin(a)
	local dx, dy = x - p.x, y - p.y
	local u, v = dx * c + dy * s, -dx * s + dy * c
	return math.abs(u) <= item.cells[1] / 2 and math.abs(v) <= item.cells[2] / 2
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
	la habitación (todas sus esquinas), sin superponerse con accesos obligatorios ni con otros muebles (intersección
	real de los rectángulos girados). Devuelve (ok, motivo, casillas que toca). ]]
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
	local poly = Office.corners(item, req.x, req.y, req.rot)
	local cells = Office.footprint(item, req.x, req.y, req.rot)
	if not Office.insideRoom(poly, r) then
		return false, "El mueble se sale de la habitación.", cells
	end
	for _, a in r.access do
		if Office.overlaps(poly, square(a[1], a[2])) then
			return false, "Bloquearía un acceso (puerta o paso).", cells
		end
	end
	for _, p in o.placed do
		if p.room == r.id and p.id ~= ignoreId then
			local other = OfficeCatalog.item(p.item)
			if other and Office.overlaps(poly, Office.corners(other, p.x, p.y, p.rot)) then
				return false, "Ese lugar ya está ocupado.", cells
			end
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

-- Escritorio y silla iniciales: se entregan una sola vez por empresa (marca `starter`) y quedan GUARDADOS en
-- el inventario, como muebles propios que el jugador coloca gratis donde quiera. Idempotente.
function Office.grantStarter(o: any): number
	if o.starter then
		return 0
	end
	o.starter = true
	for _, s in OfficeCatalog.STARTER do
		Office.addToInventory(o, s.item, 1)
	end
	o.rev = (o.rev or 0) + 1
	return #OfficeCatalog.STARTER
end

--[[ Partidas de la versión anterior (esquema 18): el escritorio y la silla iniciales se colocaban solos. Si
	siguen exactamente en su lugar inicial (el jugador no podía moverlos: no había editor), vuelven al
	inventario. No crea ni borra muebles: cada uno pasa de colocado a guardado una sola vez. ]]
function Office.unplaceStarter(o: any): number
	local moved = 0
	for _, s in OfficeCatalog.STARTER do
		for _, p in o.placed do
			if p.item == s.item and p.room == s.room and p.x == s.x and p.y == s.y and p.rot == s.rot then
				Office.removePlaced(o, p.id)
				moved += 1
				break
			end
		end
	end
	if moved > 0 then
		o.rev = (o.rev or 0) + 1
	end
	return moved
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

-- Bonificaciones del mobiliario ----------------------------------------------------------------------------
--[[ Solo los muebles COLOCADOS (en una habitación del plano actual) aportan; lo guardado no. Cada tipo de mueble
	aporta value × (1 + d + d² + … + d^(n−1)) = value × (1 − dⁿ) / (1 − d) con n copias colocadas y
	d = BONUS_DECAY: depende solo de cuántas copias hay, no del orden de las instancias ni de su posición o giro.
	Los tipos se suman en orden alfabético (resultado determinista). El aporte se combina con el del personal
	en Staff.bonusDetail con un único tope por habilidad (Office.sharedBonus); la economía lo lee siempre por
	Rules.staff. Nada de esto se guarda: se calcula de g.office.placed. ]]

-- Aporte total de n copias de un mueble.
function Office.itemBonus(item: any, n: number): number
	if not item or not item.bonus or n <= 0 then
		return 0
	end
	local d = OfficeCatalog.BONUS_DECAY
	if d == 1 then
		return item.bonus.value * n
	end
	return item.bonus.value * (1 - d ^ n) / (1 - d)
end

-- Lo que sumaría la copia n+1 de un mueble (antes del tope).
function Office.nextBonus(item: any, n: number): number
	if not item or not item.bonus then
		return 0
	end
	return item.bonus.value * OfficeCatalog.BONUS_DECAY ^ math.max(0, n)
end

-- Copias colocadas válidas por tipo (datos dañados o habitaciones de otro nivel no cuentan).
local function placedCounts(o: any): { [string]: number }
	local counts = {}
	if type(o) ~= "table" or type(o.placed) ~= "table" then
		return counts
	end
	local level = tonumber(o.level) or 1
	local seen, n = {}, 0
	for _, p in o.placed do
		n += 1
		if n > MAX_PLACED then
			break
		end
		if type(p) == "table" and type(p.id) == "string" and not seen[p.id] and OfficeCatalog.item(p.item) and type(p.room) == "string" and OfficeCatalog.room(level, p.room) then
			seen[p.id] = true
			counts[p.item] = (counts[p.item] or 0) + 1
		end
	end
	return counts
end

-- Caché por oficina (tabla débil): se invalida sola cuando cambian la revisión, el nivel o la cantidad de muebles
-- colocados (toda operación de OfficeService sube rev). Las copias de la partida del cliente son tablas nuevas.
local cache = setmetatable({}, { __mode = "k" }) :: { [any]: any }

local function bonusTable(o: any): any
	local key = tostring(o.rev) .. ":" .. tostring(o.level) .. ":" .. tostring(#o.placed)
	local c = cache[o]
	if c and c.key == key then
		return c
	end
	local counts = placedCounts(o)
	local ids = {}
	for id in counts do
		table.insert(ids, id)
	end
	table.sort(ids)
	local raw, byItem = {}, {}
	for _, id in ids do
		local item = OfficeCatalog.item(id)
		if item and item.bonus then
			local v = Office.itemBonus(item, counts[id])
			raw[item.bonus.skill] = (raw[item.bonus.skill] or 0) + v
			byItem[id] = v
		end
	end
	c = { key = key, raw = raw, counts = counts, byItem = byItem }
	cache[o] = c
	return c
end

-- Aporte del mobiliario colocado a una habilidad (misma unidad que Staff.contribution, antes del tope).
function Office.furnitureRaw(o: any, skillId: string): number
	if type(o) ~= "table" or type(o.placed) ~= "table" then
		return 0
	end
	return bonusTable(o).raw[skillId] or 0
end

-- Copias colocadas válidas de un mueble y su aporte total (para la interfaz).
function Office.furnitureOf(o: any, itemId: string): (number, number)
	if type(o) ~= "table" or type(o.placed) ~= "table" then
		return 0, 0
	end
	local t = bonusTable(o)
	return t.counts[itemId] or 0, t.byItem[itemId] or 0
end

--[[ Bonificación combinada personal + mobiliario con el tope único de la habilidad:
	min(tope, aporte del personal + aporte de los muebles). La usa Staff.bonusDetail (y por ella Rules.staff):
	hay una sola aplicación de cada bonificación. ]]
function Office.sharedBonus(staffRaw: number, furnitureRaw: number, cap: number): number
	return math.min(cap, math.max(0, staffRaw) + math.max(0, furnitureRaw))
end

-- Acabados y remodelaciones (cotización; el cobro llega con el editor) ---------------------------------------

function Office.roomArea(r: any): number
	return r.w * r.d
end
--[[ Tramos de pared realmente construidos: por cada lado de la habitación, los tramos continuos (en casillas)
	que quedan después de abrir una puerta en cada casilla de acceso pegada a ese borde. Es la única regla:
	la usan el presupuesto (Office.wallLength, cliente y servidor) y la escena (OfficeScene arma las paredes
	con estos mismos tramos).
	Devuelve { left = { { desde, hasta } }, right, front, back }: left/right recorren y (0..d) sobre x = 0 y
	x = w; front/back recorren x (0..w) sobre y = 0 e y = d. ]]
function Office.wallRuns(r: any): any
	local open = { left = {}, right = {}, front = {}, back = {} }
	for _, a in r.access or {} do
		if a[1] == 0 then
			open.left[a[2]] = true
		end
		if a[1] == r.w - 1 then
			open.right[a[2]] = true
		end
		if a[2] == 0 then
			open.front[a[1]] = true
		end
		if a[2] == r.d - 1 then
			open.back[a[1]] = true
		end
	end
	local function runs(length: number, openAt: { [number]: boolean }): { { number } }
		local out = {}
		local start = nil
		for i = 0, length do
			local isOpen = i == length or openAt[i]
			if not isOpen and start == nil then
				start = i
			elseif isOpen and start ~= nil then
				table.insert(out, { start, i })
				start = nil
			end
		end
		return out
	end
	return { left = runs(r.d, open.left), right = runs(r.d, open.right), front = runs(r.w, open.front), back = runs(r.w, open.back) }
end

-- Largo de pared construida en tramos (1 tramo = 1 casilla de largo): perímetro menos las aberturas.
function Office.wallLength(r: any): number
	local n = 0
	for _, side in Office.wallRuns(r) do
		for _, run in side do
			n += run[2] - run[1]
		end
	end
	return n
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
				local ok, why, approach = Office.interactionAccess(o, p, pt)
				pt.accessible, pt.reason, pt.approach = ok, why, approach
				table.insert(out, pt)
			end
		end
	end
	return out
end

-- Tipos de interacción: "work" y "browse" se usan de pie frente al mueble; "sit" y "rest" sobre el mueble.
Office.INTERACTION_KINDS = { work = "stand", browse = "stand", sit = "seat", rest = "seat" }

-- ¿El punto (x, y) de la habitación está libre (dentro de la habitación y sin otro mueble encima)?
local function freeSpot(o: any, r: any, x: number, y: number, ignore: string?): (boolean, string?)
	if x < 0.25 or y < 0.25 or x > r.w - 0.25 or y > r.d - 0.25 then
		return false, "fuera de la habitación"
	end
	for _, q in o.placed do
		if q.room == r.id and q.id ~= ignore and Office.hits(q, x, y) then
			return false, "tapado por otro mueble"
		end
	end
	return true, nil
end

--[[ ¿Se puede usar el punto de un mueble colocado? Devuelve (accesible, motivo, punto de llegada {x, y}).
	- De pie ("work", "browse"): el punto mismo debe estar libre (dentro de la habitación y sin otro mueble,
	  tampoco el propio).
	- Sentado ("sit", "rest"): el punto está sobre el mueble; hace falta un lugar libre al lado para llegar
	  (adelante, a los costados o atrás, a media casilla del borde).
	Solo informa: un punto inaccesible no cambia la bonificación pasiva del mueble. ]]
function Office.interactionAccess(o: any, p: any, pt: any): (boolean, string?, any)
	local r = OfficeCatalog.room(o.level, p.room)
	local item = OfficeCatalog.item(p.item)
	if not r or not item or not pt then
		return false, "mueble fuera del plano", nil
	end
	local mode = Office.INTERACTION_KINDS[pt.kind]
	if mode == "stand" then
		local ok, why = freeSpot(o, r, pt.x, pt.y, nil)
		return ok, why, ok and { x = pt.x, y = pt.y } or nil
	end
	-- Lugar de llegada: a media casilla del borde del mueble, empezando por el frente (hacia donde mira).
	local f = math.rad(pt.facing)
	local fx, fy = math.cos(f), math.sin(f)
	local reach = math.max(item.cells[1], item.cells[2]) / 2 + 0.5
	for _, turn in { 0, 90, -90, 180 } do
		local a = math.rad(turn)
		local dx, dy = fx * math.cos(a) - fy * math.sin(a), fx * math.sin(a) + fy * math.cos(a)
		local x, y = pt.x + dx * reach, pt.y + dy * reach
		if freeSpot(o, r, x, y, nil) then
			return true, nil, { x = x, y = y }
		end
	end
	return false, "sin lugar libre para llegar", nil
end

--[[ Posición en el mundo de un punto de la habitación: anchor = { x, y, z } esquina (0, 0) de la habitación
	en studs (y = altura del piso), con la habitación alineada a los ejes del mundo (x de la habitación → X,
	y → Z, como OfficeScene). Devuelve (X, Y, Z, giro en grados alrededor de Y para CFrame.Angles(0, −rad, 0)).
	Admite cualquier giro (también de 45°): facing viene ya girado con el mueble. ]]
function Office.toWorld(anchor: any, x: number, y: number, facing: number?): (number, number, number, number)
	local cell = OfficeCatalog.CELL
	return anchor.x + x * cell, anchor.y, anchor.z + y * cell, facing or 0
end

-- Valida los puntos de interacción del catálogo (lo usan las pruebas y una futura carga de assets).
function Office.checkInteraction(item: any): (boolean, string?)
	local it = item.interaction
	if it == nil then
		return true, nil
	end
	local mode = Office.INTERACTION_KINDS[it.kind]
	if not mode then
		return false, "tipo de interacción desconocido"
	end
	if type(it.dx) ~= "number" or type(it.dy) ~= "number" or type(it.facing) ~= "number" or it.facing % 45 ~= 0 or it.facing < 0 or it.facing >= 360 then
		return false, "punto o dirección inválidos"
	end
	local inside = math.abs(it.dx) < item.cells[1] / 2 and math.abs(it.dy) < item.cells[2] / 2
	if mode == "seat" and not inside then
		return false, "el asiento debe estar sobre el mueble"
	elseif mode == "stand" and inside then
		return false, "el lugar de trabajo debe estar fuera del mueble"
	end
	return true, nil
end

return Office
