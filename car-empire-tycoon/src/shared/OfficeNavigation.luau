--!strict
--[[ Navegación de los empleados dentro de las oficinas (pura: sin servicios de Roblox).

	Por qué no PathfindingService: la escena del editor usa Parts provisionales sin colisión (CanCollide =
	false), así que el motor físico no «ve» muebles ni paredes. La navegación se calcula sobre el plano de la
	oficina (OfficeCatalog.PLANS + g.office.placed), con la misma geometría que valida la colocación.

	Zona transitable de una habitación:
	  - Nodos cada STEP casillas (0,5 = media casilla, 1 stud), desde STEP hasta el borde − STEP. Así un pasillo
	    de una casilla entre dos muebles tiene un nodo en su centro.
	  - Un nodo es transitable si un disco de radio RADIUS (el ancho del personaje) cabe ahí: no toca paredes y
	    queda a RADIUS o más de todo mueble (rectángulo girado real, también a 45°).
	  - Vecinos en 8 direcciones; en diagonal solo si los dos vecinos rectos también son transitables (no se
	    cortan esquinas ocupadas).
	  - Entradas = nodos transitables dentro de las casillas de acceso de la habitación (puertas y paso).
	    Componentes conexos: un destino es alcanzable solo si está en el mismo componente que una entrada.
	La grilla se guarda en caché por habitación y se rearma solo si cambian los muebles de esa habitación o el
	nivel (firma de los muebles colocados), nunca por cuadro.

	Rutas: A* (heurística octil) entre el nodo más cercano al origen y el más cercano al destino, y después
	«tirar del hilo»: se unen puntos con línea libre. Un tramo es libre si el disco cabe en TODO su recorrido
	(Nav.segmentClear: distancia exacta a muebles y paredes, partiendo el tramo hasta poder asegurarlo); lo
	mismo vale para cada paso entre nodos vecinos. Si el
	destino está en otro componente, se informa sin buscar (ruta imposible, sin bloquear nada).

	Habitaciones separadas: hoy cada habitación es independiente (OfficeScene las dibuja con un espacio entre
	ellas y no hay pasillos). LINKS queda preparado para una escena futura con pasillos y puertas reales: no se
	inventan conexiones. ]]

local OfficeCatalog = require(script.Parent.OfficeCatalog)
local Geometry = require(script.Parent.OfficeGeometry)

local Nav = {}

Nav.STEP = 0.5 -- separación de nodos (casillas)
Nav.RADIUS = 0.35 -- radio del cuerpo (casillas): 0,7 studs, hombros de ~1,4 studs
Nav.SAMPLE = 0.2 -- paso del muestreo de segmentos (casillas)
Nav.SNAP = 0.75 -- distancia máxima entre un punto pedido y su nodo transitable
Nav.SEAT_CLEAR = 0.2 -- al sentarse, el cuerpo puede rozar su propio mueble pero no otros (radio reducido)

-- Conexiones entre habitaciones por nivel: { { from = idHab, to = idHab, fromCell = { x, y }, toCell = { x, y } } }.
-- Vacío a propósito: la escena actual no tiene pasillos ni puertas entre habitaciones.
Nav.LINKS = {} :: { [number]: { any } }

function Nav.links(level: number, roomId: string): { any }
	local out = {}
	for _, l in Nav.LINKS[level] or {} do
		if l.from == roomId or l.to == roomId then
			table.insert(out, l)
		end
	end
	return out
end

-- Grilla ------------------------------------------------------------------------------------------------

-- Firma de los muebles de una habitación: si no cambia, la grilla sirve.
function Nav.roomSig(o: any, roomId: string): string
	local parts = {}
	for _, p in (o and o.placed) or {} do
		if p.room == roomId then
			table.insert(parts, tostring(p.id) .. ":" .. tostring(p.item) .. ":" .. tostring(p.x) .. ":" .. tostring(p.y) .. ":" .. tostring(p.rot))
		end
	end
	table.sort(parts)
	return tostring(o and o.level or 1) .. "|" .. roomId .. "|" .. table.concat(parts, ";")
end

local function obstacles(o: any, roomId: string): { any }
	local out = {}
	for _, p in o.placed or {} do
		local item = p.room == roomId and OfficeCatalog.item(p.item) or nil
		if item then
			local poly = Geometry.corners(item, p.x, p.y, p.rot)
			local lx, ly, hx, hy = math.huge, math.huge, -math.huge, -math.huge
			for _, c in poly do
				lx, ly, hx, hy = math.min(lx, c[1]), math.min(ly, c[2]), math.max(hx, c[1]), math.max(hy, c[2])
			end
			table.insert(out, { id = p.id, item = p.item, poly = poly, lx = lx, ly = ly, hx = hx, hy = hy })
		end
	end
	return out
end

--[[ ¿Cabe el cuerpo (disco de radio `radius`, por defecto RADIUS) en (x, y)? ignore = id de mueble que no
	cuenta. Devuelve (ok, motivo "pared" | "mueble", obstáculo). ]]
function Nav.clearAt(grid: any, x: number, y: number, ignore: string?, radius: number?): (boolean, string?, any)
	local r = grid.room
	local R = radius or Nav.RADIUS
	local e = 1e-6
	if x < R - e or y < R - e or x > r.w - R + e or y > r.d - R + e then
		return false, "pared", nil
	end
	for _, ob in grid.obstacles do
		if ob.id ~= ignore and x + R > ob.lx and x - R < ob.hx and y + R > ob.ly and y - R < ob.hy then
			if Geometry.distance(ob.poly, x, y) < R - e then
				return false, "mueble", ob
			end
		end
	end
	return true, nil, nil
end

-- Distancia libre en (x, y): a la pared más cercana y al borde del mueble más cercano (0 si está adentro).
function Nav.clearance(grid: any, x: number, y: number, ignore: string?): number
	local r = grid.room
	local c = math.min(x, y, r.w - x, r.d - y)
	for _, ob in grid.obstacles do
		if ob.id ~= ignore then
			local bx = math.max(ob.lx - x, 0, x - ob.hx)
			local by = math.max(ob.ly - y, 0, y - ob.hy)
			if bx * bx + by * by < c * c then
				c = math.min(c, Geometry.distance(ob.poly, x, y))
			end
		end
	end
	return c
end

--[[ Tramo libre entre dos puntos con su distancia libre ya calculada. La distancia libre cambia a lo sumo lo
	que uno se mueve (es 1-Lipschitz), así que en un tramo de largo L el mínimo es al menos (ca + cb − L) / 2:
	si eso ya alcanza para el cuerpo, el tramo entero es seguro; si no, se parte al medio y se mira cada mitad.
	Es una comprobación exacta (no muestras sueltas): ningún punto intermedio queda sin cubrir. ]]
local function intervalClear(grid: any, ax: number, ay: number, ca: number, bx: number, by: number, cb: number, R: number, ignore: string?, depth: number): boolean
	local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
	if (ca + cb - len) / 2 >= R - 1e-9 then
		return true
	end
	if depth >= 8 then
		return false -- prudente: un roce que no se puede descartar cuenta como bloqueo
	end
	local mx, my = (ax + bx) / 2, (ay + by) / 2
	local cm = Nav.clearance(grid, mx, my, ignore)
	if cm < R - 1e-6 then
		return false
	end
	return intervalClear(grid, ax, ay, ca, mx, my, cm, R, ignore, depth + 1) and intervalClear(grid, mx, my, cm, bx, by, cb, R, ignore, depth + 1)
end

-- ¿El segmento a → b está libre para el cuerpo en TODO su recorrido (no solo en algunos puntos)?
function Nav.segmentClear(grid: any, ax: number, ay: number, bx: number, by: number, ignore: string?, radius: number?): boolean
	local R = radius or Nav.RADIUS
	local dx, dy = bx - ax, by - ay
	local n = math.max(1, math.ceil(math.sqrt(dx * dx + dy * dy) / Nav.SAMPLE))
	local px, py = ax, ay
	local pc = Nav.clearance(grid, ax, ay, ignore)
	if pc < R - 1e-6 then
		return false
	end
	for k = 1, n do
		local t = k / n
		local x, y = ax + dx * t, ay + dy * t
		local c = Nav.clearance(grid, x, y, ignore)
		if c < R - 1e-6 or not intervalClear(grid, px, py, pc, x, y, c, R, ignore, 0) then
			return false
		end
		px, py, pc = x, y, c
	end
	return true
end

local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

local function index(grid: any, i: number, j: number): number
	return (j - 1) * grid.cols + i
end

function Nav.nodePos(grid: any, idx: number): (number, number)
	local i = (idx - 1) % grid.cols + 1
	local j = (idx - 1) // grid.cols + 1
	return i * Nav.STEP, j * Nav.STEP
end

-- Vecinos transitables de un nodo (sin cortar esquinas en diagonal).
function Nav.neighbors(grid: any, idx: number): { number }
	local i = (idx - 1) % grid.cols + 1
	local j = (idx - 1) // grid.cols + 1
	local out = {}
	for _, d in DIRS do
		local ni, nj = i + d[1], j + d[2]
		if ni >= 1 and nj >= 1 and ni <= grid.cols and nj <= grid.rows and grid.free[index(grid, ni, nj)] then
			if d[1] == 0 or d[2] == 0 or (grid.free[index(grid, ni, j)] and grid.free[index(grid, i, nj)]) then
				-- El paso entre los dos nodos también tiene que estar libre (un mueble a 45° puede asomar entre
				-- dos nodos libres). Se calcula una vez por paso y queda en la grilla.
				local n = index(grid, ni, nj)
				local key = idx < n and (idx * 65536 + n) or (n * 65536 + idx)
				local ok = grid.edges[key]
				if ok == nil then
					ok = Nav.segmentClear(grid, i * Nav.STEP, j * Nav.STEP, ni * Nav.STEP, nj * Nav.STEP)
					grid.edges[key] = ok
				end
				if ok then
					table.insert(out, n)
				end
			end
		end
	end
	return out
end

-- Arma la grilla de una habitación del plano actual (o nil si la habitación no existe en ese nivel).
function Nav.build(o: any, roomId: string): any
	local r = OfficeCatalog.room(o.level or 1, roomId)
	if not r then
		return nil
	end
	local grid = {
		room = r,
		roomId = roomId,
		level = o.level or 1,
		sig = Nav.roomSig(o, roomId),
		obstacles = obstacles(o, roomId),
		cols = math.floor(r.w / Nav.STEP + 1e-6) - 1,
		rows = math.floor(r.d / Nav.STEP + 1e-6) - 1,
		free = {} :: { [number]: boolean },
		comp = {} :: { [number]: number },
		entries = {} :: { number },
		reach = {} :: { [number]: boolean }, -- componentes que tocan una entrada
		edges = {} :: { [number]: boolean }, -- pasos entre nodos vecinos ya comprobados
		freeCount = 0,
	}
	for j = 1, grid.rows do
		for i = 1, grid.cols do
			local x, y = i * Nav.STEP, j * Nav.STEP
			local ok = Nav.clearAt(grid, x, y)
			local idx = index(grid, i, j)
			grid.free[idx] = ok
			if ok then
				grid.freeCount += 1
				for _, a in r.access do
					if x >= a[1] - 1e-6 and x <= a[1] + 1 + 1e-6 and y >= a[2] - 1e-6 and y <= a[2] + 1 + 1e-6 then
						table.insert(grid.entries, idx)
						break
					end
				end
			end
		end
	end
	-- Componentes conexos (relleno por anchura).
	local label = 0
	for idx = 1, grid.cols * grid.rows do
		if grid.free[idx] and not grid.comp[idx] then
			label += 1
			grid.comp[idx] = label
			local queue, head = { idx }, 1
			while head <= #queue do
				local cur = queue[head]
				head += 1
				for _, n in Nav.neighbors(grid, cur) do
					if not grid.comp[n] then
						grid.comp[n] = label
						table.insert(queue, n)
					end
				end
			end
		end
	end
	for _, e in grid.entries do
		grid.reach[grid.comp[e]] = true
	end
	return grid
end

local cache = setmetatable({}, { __mode = "k" }) :: { [any]: { [string]: any } }
-- Además, por firma: el cliente recibe una tabla g.office nueva con cada actualización del servidor; si los
-- muebles de la habitación son los mismos, la grilla anterior sirve igual (la grilla no se modifica nunca).
local bySig: { [string]: any } = {}
local bySigCount = 0
local BY_SIG_MAX = 32

-- Grilla en caché: se rearma solo si cambió la firma de los muebles de la habitación (o el nivel).
function Nav.grid(o: any, roomId: string): any
	if type(o) ~= "table" then
		return nil
	end
	local byRoom = cache[o]
	if not byRoom then
		byRoom = {}
		cache[o] = byRoom
	end
	local sig = Nav.roomSig(o, roomId)
	local g = byRoom[roomId]
	if not g or g.sig ~= sig then
		g = bySig[sig]
		if not g then
			g = Nav.build(o, roomId)
			Nav.builds += 1
			if bySigCount >= BY_SIG_MAX then
				table.clear(bySig)
				bySigCount = 0
			end
			if g then
				bySig[sig] = g
				bySigCount += 1
			end
		end
		byRoom[roomId] = g
	end
	return g
end
Nav.builds = 0 -- grillas armadas (las pruebas verifican que no se rearma sin cambios)

-- ¿El nodo está en una zona alcanzable desde una entrada?
function Nav.reachable(grid: any, idx: number?): boolean
	return idx ~= nil and grid.free[idx] == true and grid.reach[grid.comp[idx]] == true
end

--[[ Nodo transitable más cercano a (x, y) dentro de maxD casillas. opts: reach = solo zonas alcanzables
	desde una entrada, comp = solo ese componente, los = con línea libre desde (x, y) hasta el nodo. ]]
function Nav.nearest(grid: any, x: number, y: number, opts: any?): (number?, number)
	local maxD = (opts and opts.maxD) or Nav.SNAP
	local S = Nav.STEP
	local i0, i1 = math.max(1, math.floor((x - maxD) / S)), math.min(grid.cols, math.ceil((x + maxD) / S))
	local j0, j1 = math.max(1, math.floor((y - maxD) / S)), math.min(grid.rows, math.ceil((y + maxD) / S))
	local cands = {}
	for j = j0, j1 do
		for i = i0, i1 do
			local idx = index(grid, i, j)
			if grid.free[idx] then
				local nx, ny = i * S, j * S
				local d = math.sqrt((nx - x) ^ 2 + (ny - y) ^ 2)
				if d <= maxD + 1e-6 and (not (opts and opts.reach) or grid.reach[grid.comp[idx]]) and (not (opts and opts.comp) or grid.comp[idx] == opts.comp) then
					table.insert(cands, { idx = idx, d = d, x = nx, y = ny })
				end
			end
		end
	end
	table.sort(cands, function(a: any, b: any): boolean
		if a.d ~= b.d then
			return a.d < b.d
		end
		return a.idx < b.idx
	end)
	for _, c in cands do
		if not (opts and opts.los) or Nav.segmentClear(grid, x, y, c.x, c.y, opts and opts.ignore) then
			return c.idx, c.d
		end
	end
	return nil, math.huge
end

-- Cola de prioridad mínima (montículo binario) para A*.
local function push(heap: { any }, f: number, idx: number)
	table.insert(heap, { f, idx })
	local k = #heap
	while k > 1 do
		local p = k // 2
		if heap[p][1] <= heap[k][1] then
			break
		end
		heap[p], heap[k] = heap[k], heap[p]
		k = p
	end
end

local function pop(heap: { any }): any
	local top = heap[1]
	local last = table.remove(heap)
	if #heap > 0 then
		heap[1] = last
		local k = 1
		while true do
			local l, r = k * 2, k * 2 + 1
			local m = k
			if l <= #heap and heap[l][1] < heap[m][1] then
				m = l
			end
			if r <= #heap and heap[r][1] < heap[m][1] then
				m = r
			end
			if m == k then
				break
			end
			heap[m], heap[k] = heap[k], heap[m]
			k = m
		end
	end
	return top
end

local SQ2 = math.sqrt(2)

-- A* entre dos nodos del mismo componente. Devuelve la lista de nodos o nil.
-- ¿El punto (x, y) cae dentro de alguna zona a evitar { { x, y, r } } (personas detenidas)?
local function avoided(avoid: { any }?, x: number, y: number): boolean
	for _, a in avoid or {} do
		if (x - a[1]) ^ 2 + (y - a[2]) ^ 2 < a[3] * a[3] then
			return true
		end
	end
	return false
end

-- ¿El segmento pasa a menos de r de alguna zona a evitar?
local function segmentAvoids(avoid: { any }?, ax: number, ay: number, bx: number, by: number): boolean
	for _, a in avoid or {} do
		local dx, dy = bx - ax, by - ay
		local len2 = dx * dx + dy * dy
		local t = len2 > 0 and math.clamp(((a[1] - ax) * dx + (a[2] - ay) * dy) / len2, 0, 1) or 0
		local cx, cy = ax + dx * t - a[1], ay + dy * t - a[2]
		if cx * cx + cy * cy < a[3] * a[3] then
			return false
		end
	end
	return true
end

function Nav.astar(grid: any, s: number, t: number, avoid: { any }?): { number }?
	if grid.comp[s] ~= grid.comp[t] then
		return nil
	end
	local tx, ty = Nav.nodePos(grid, t)
	local function h(idx: number): number
		local x, y = Nav.nodePos(grid, idx)
		local dx, dy = math.abs(x - tx), math.abs(y - ty)
		return (math.max(dx, dy) - math.min(dx, dy)) + SQ2 * math.min(dx, dy)
	end
	local gScore = { [s] = 0 }
	local from = {}
	local closed = {}
	local heap = {}
	push(heap, h(s), s)
	local expanded = 0
	local limit = grid.cols * grid.rows + 1
	while #heap > 0 do
		local cur = pop(heap)[2]
		if cur == t then
			local path = { t }
			while from[path[1]] do
				table.insert(path, 1, from[path[1]])
			end
			Nav.lastExpanded = expanded
			return path
		end
		if not closed[cur] then
			closed[cur] = true
			expanded += 1
			if expanded > limit then
				break -- protección: nunca más que la cantidad de nodos
			end
			local cx, cy = Nav.nodePos(grid, cur)
			for _, n in Nav.neighbors(grid, cur) do
				local nx, ny = Nav.nodePos(grid, n)
				if not closed[n] and (n == t or not avoided(avoid, nx, ny)) then
					local step = (nx ~= cx and ny ~= cy) and SQ2 * Nav.STEP or Nav.STEP
					local cand = gScore[cur] + step
					if gScore[n] == nil or cand < gScore[n] then
						gScore[n] = cand
						from[n] = cur
						push(heap, cand + h(n), n)
					end
				end
			end
		end
	end
	Nav.lastExpanded = expanded
	return nil
end
Nav.lastExpanded = 0

--[[ Ruta de (fx, fy) a (tx, ty) dentro de una habitación. Devuelve (puntos { { x, y } } sin incluir el origen,
	motivo si no hay). El origen debe estar en un lugar libre (si el personaje quedó dentro de un mueble, antes
	se lo reubica con Nav.nearest). El destino se alcanza exacto si hay línea libre desde su nodo; si no, se
	termina en el nodo transitable más cercano. ]]
--[[ avoid (opcional) = { { x, y, r } } zonas a rodear si se puede (personas detenidas): si con ellas no hay
	ruta, se calcula sin ellas (nadie queda trabado por un personaje decorativo). ]]
function Nav.findPath(grid: any, fx: number, fy: number, tx: number, ty: number, avoid: { any }?): ({ { number } }?, string?)
	if not grid then
		return nil, "habitación inexistente"
	end
	local s = Nav.nearest(grid, fx, fy, { maxD = 1.5, los = true }) or Nav.nearest(grid, fx, fy, { maxD = 1.5 })
	if not s then
		return nil, "sin lugar libre donde está"
	end
	local t = Nav.nearest(grid, tx, ty, { los = true, comp = grid.comp[s] })
	if not t then
		if Nav.nearest(grid, tx, ty, { los = true }) then
			return nil, "sin recorrido hasta el destino"
		end
		return nil, "destino bloqueado"
	end
	-- No se evita a quien está parado justo en el origen o en el destino.
	local soft = {}
	for _, a in avoid or {} do
		if (fx - a[1]) ^ 2 + (fy - a[2]) ^ 2 >= a[3] * a[3] and (tx - a[1]) ^ 2 + (ty - a[2]) ^ 2 >= a[3] * a[3] then
			table.insert(soft, a)
		end
	end
	local nodes = #soft > 0 and Nav.astar(grid, s, t, soft) or nil
	if not nodes then
		soft = {}
		nodes = Nav.astar(grid, s, t)
	end
	if not nodes then
		return nil, "sin recorrido hasta el destino"
	end
	local pts = { { fx, fy } }
	for _, idx in nodes do
		local x, y = Nav.nodePos(grid, idx)
		table.insert(pts, { x, y })
	end
	local last = pts[#pts]
	if (math.abs(last[1] - tx) > 1e-6 or math.abs(last[2] - ty) > 1e-6) and Nav.segmentClear(grid, last[1], last[2], tx, ty) then
		table.insert(pts, { tx, ty })
	end
	-- Tirar del hilo: desde cada punto, saltar al más lejano con línea libre.
	local out = {}
	local anchor = 1
	if not Nav.clearAt(grid, fx, fy) then
		-- Origen apretado (por ejemplo, recién levantado de un asiento): primero ir a su nodo.
		table.insert(out, pts[2])
		anchor = 2
	end
	while anchor < #pts do
		local j = #pts
		while j > anchor + 1 and not (Nav.segmentClear(grid, pts[anchor][1], pts[anchor][2], pts[j][1], pts[j][2]) and segmentAvoids(soft, pts[anchor][1], pts[anchor][2], pts[j][1], pts[j][2])) do
			j -= 1
		end
		table.insert(out, pts[j])
		anchor = j
	end
	return out, nil
end

-- Largo total de una ruta desde (fx, fy).
function Nav.pathLength(fx: number, fy: number, path: { { number } }): number
	local total, px, py = 0, fx, fy
	for _, p in path do
		total += math.sqrt((p[1] - px) ^ 2 + (p[2] - py) ^ 2)
		px, py = p[1], p[2]
	end
	return total
end

--[[ Lugar de llegada para usar un punto de interacción (pt de Office.interactionPoints) del mueble p.
	Devuelve ({ x, y, node } o nil, motivo). Comprueba:
	  - De pie (trabajar, consultar, reunirse): el punto está dentro de la habitación, no queda sobre otro mueble,
	    el cuerpo cabe ahí (paredes y muebles cercanos) y hay un nodo transitable con línea libre hasta él.
	  - Sentado (silla, sofá): el punto está sobre el mueble; hace falta un lugar libre a su lado (adelante, a los
	    costados o atrás) desde donde el cuerpo llegue al asiento sin cruzar otro mueble.
	  - En ambos casos el lugar de llegada debe estar en una zona alcanzable desde una entrada (ruta completa
	    desde la puerta, no solo un punto libre). ]]
function Nav.approach(grid: any, item: any, p: any, pt: any, mode: string): (any, string?)
	local r = grid.room
	if pt.x < 0 or pt.y < 0 or pt.x > r.w or pt.y > r.d then
		return nil, "fuera de la habitación"
	end
	if mode == "stand" then
		for _, ob in grid.obstacles do
			if ob.id ~= p.id and Geometry.pointIn(ob.poly, pt.x, pt.y) then
				return nil, "tapado por otro mueble"
			end
		end
		local ok, why = Nav.clearAt(grid, pt.x, pt.y)
		if not ok then
			return nil, why == "pared" and "sin espacio junto a la pared" or "sin espacio para pararse (muebles muy cerca)"
		end
		local node = Nav.nearest(grid, pt.x, pt.y, { los = true })
		if not node then
			return nil, "sin espacio para pararse"
		end
		if not Nav.reachable(grid, node) then
			return nil, "sin recorrido desde la entrada"
		end
		return { x = pt.x, y = pt.y, node = node }, nil
	end
	-- Sentado: buscar, en cada dirección, el primer lugar libre junto al mueble.
	local f = math.rad(pt.facing)
	local fx, fy = math.cos(f), math.sin(f)
	local far = math.max(item.cells[1], item.cells[2]) / 2 + 1
	local sawFree = false
	for _, turn in { 0, 90, -90, 180 } do
		local a = math.rad(turn)
		local dx, dy = fx * math.cos(a) - fy * math.sin(a), fx * math.sin(a) + fy * math.cos(a)
		local d = 0.5
		while d <= far + 1e-6 do
			local x, y = pt.x + dx * d, pt.y + dy * d
			if Nav.clearAt(grid, x, y) then
				if Nav.segmentClear(grid, x, y, pt.x, pt.y, p.id, Nav.SEAT_CLEAR) then
					sawFree = true
					local node = Nav.nearest(grid, x, y, { los = true })
					if node and Nav.reachable(grid, node) then
						return { x = x, y = y, node = node }, nil
					end
				end
				break
			end
			d += 0.25
		end
	end
	return nil, sawFree and "sin recorrido desde la entrada" or "sin lugar libre para llegar"
end

return Nav
