--!strict
--[[ Comportamiento de los empleados visibles en el editor de oficinas (lógica pura: sin Parts ni conexiones).

	Los empleados visibles son REPRESENTACIONES de g.employees: este módulo nunca crea empleados, no toca dinero,
	habilidades, productividad, bonificaciones, tiempo de la empresa ni muebles, y no guarda nada. Todo vive en
	memoria del cliente mientras el editor está abierto (posiciones, rutas, reservas y actividades).

	Mundo (Act.new): { office, level, rooms, npcs, order, res, t, ... }
	  rooms[id]  = { room, grid (OfficeNavigation), spots, byKey, cap, sig }
	  npcs[id]   = NPC del empleado con ese id (nunca dos por empleado)
	  res[clave] = id del empleado que reservó ese punto de uso (clave = instancia#slot)
	  t          = reloj visual propio (segundos). No es g.time: la empresa sigue en pausa.

	NPC: { id, name, dept, room, x, y (casillas de su habitación), heading (grados del plano: 0 = +x, 90 = +y),
	  state (Act.STATES), activity { kind, spot, key, keys }, path { {x, y} }, pi, timer, phase ("down" | "up"),
	  pose (la lee OfficeAnimations), nav (texto de navegación), avoid { [clave] = hasta }, home (escritorio
	  preferido), interrupts }

	Ciclo: Idle (pausa) → elegir actividad (pesos por departamento, solo puntos accesibles y libres) → reservar →
	Walking por la ruta (A* de OfficeNavigation, calculada una vez) → actividad (Working, Sitting, Browsing,
	Resting, Meeting) durante un tiempo → liberar → Idle. Una ruta imposible se descarta enseguida (el punto se
	evita un rato) y el empleado se queda en reposo: nunca intenta caminar sin fin.

	Cambios de muebles (Act.setOffice, solo con la oficina confirmada por el servidor): se rearman las
	habitaciones que cambiaron; las reservas de puntos que ya no existen o se movieron se liberan, las rutas
	que quedaron tapadas se recalculan y nadie queda dentro de un mueble. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Office = require(Shared.Office)
local OfficeCatalog = require(Shared.OfficeCatalog)
local Nav = require(Shared.OfficeNavigation)

local Act = {}

-- Configuración (provisional: se puede ajustar sin tocar la lógica) -------------------------------------------
Act.MAX_VISIBLE_NPCS = 10 -- empleados reales representados a la vez
Act.ROTATE_EVERY = 150 -- segundos entre rotaciones de quién se ve (si hay más contratados que visibles)
Act.WALK_SPEED = 1.5 -- casillas por segundo (3 studs/s: paso tranquilo de oficina)
Act.TURN_SPEED = 300 -- grados por segundo
Act.SIT_TIME = 0.8 -- segundos para sentarse o levantarse
Act.AREA_PER_NPC = 10 -- casillas de piso por empleado visible en una habitación (no se amontonan)
Act.COMBO_DIST = 0.75 -- una silla a esta distancia de un escritorio o de la mesa se usa para sentarse ahí
Act.AVOID_TIME = 30 -- segundos que se evita un punto al que no se pudo llegar
Act.PERSONAL_SPACE = 0.9 -- separación mínima entre lugares ocupados (casillas)
Act.YIELD_DIST = 0.75 -- distancia a la que un empleado que camina cede el paso
Act.YIELD_MAX = 1.2 -- segundos máximos esperando (después sigue: sin bloqueos eternos)
Act.MAX_DT = 0.1 -- paso máximo de la simulación visual

-- Duraciones (segundos, mínimo y máximo) y pausas entre actividades.
Act.DURATIONS = {
	work = { 30, 70 },
	sit = { 15, 35 },
	browse = { 8, 18 },
	rest = { 20, 45 },
	meet = { 20, 40 },
	wander = { 4, 9 }, -- reposo después de un paseo corto
}
Act.PAUSE = { 1.5, 4.5 }
Act.FIRST_DELAY = { 0.5, 4 } -- al abrir el editor: no arrancan todos a la vez

-- Preferencias visuales por departamento (solo pesos de elección; no dan ninguna bonificación).
Act.PREFS = {
	administracion = { work = 3, meet = 1.2, sit = 1, browse = 0.8, rest = 0.6 },
	investigacion = { browse = 3, work = 1.5, meet = 1, sit = 0.8, rest = 0.6 },
	marketing = { meet = 2.5, work = 1.2, sit = 1, browse = 0.6, rest = 0.8 },
	produccion = { work = 1.4, rest = 1, browse = 1, meet = 1, sit = 1 },
}
Act.DEFAULT_PREF = { work = 1, browse = 1, meet = 1, sit = 1, rest = 0.7 }
Act.WANDER_WEIGHT = 0.45
Act.IDLE_WEIGHT = 0.5

Act.STATES = { "Idle", "Walking", "Working", "Sitting", "Browsing", "Resting", "Meeting" }
local STATE_OF = { work = "Working", sit = "Sitting", browse = "Browsing", rest = "Resting", meet = "Meeting" }
Act.STATE_TEXT = {
	Idle = "En reposo",
	Walking = "Caminando",
	Working = "Trabajando",
	Sitting = "Sentado",
	Browsing = "Consultando archivos",
	Resting = "Descansando",
	Meeting = "En reunión",
}

-- Azar determinista (Park–Miller): mismos empleados y misma oficina → mismo comportamiento (pruebas estables).
local function hash(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 2147483647
	end
	return math.max(1, h)
end
Act.hash = hash

local function rand(holder: any): number
	holder.seed = (holder.seed * 16807) % 2147483647
	return holder.seed / 2147483647
end

local function between(holder: any, range: { number }): number
	return range[1] + (range[2] - range[1]) * rand(holder)
end

local function dist(ax: number, ay: number, bx: number, by: number): number
	return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

local function angleDiff(a: number, b: number): number
	return (b - a + 540) % 360 - 180
end

local function idKey(id: any): string
	return tostring(id)
end

-- Habitaciones y puntos de uso -----------------------------------------------------------------------------

local function spotSig(sp: any): string
	local ap = sp.approach
	return string.format("%.3f:%.3f:%d:%s:%s", sp.x, sp.y, sp.facing, tostring(sp.seated), ap and string.format("%.3f:%.3f", ap.x, ap.y) or "-")
end

--[[ Puntos utilizables de una habitación. Escritorio o mesa con una silla al lado (a COMBO_DIST o menos de su
	punto de uso) = se trabaja o se reúne sentado en esa silla (reserva los dos puntos). ]]
local function buildSpots(o: any, roomId: string): ({ any }, { [string]: any })
	local raw = Office.interactionSpots(o, roomId)
	local chairs = {}
	for _, pt in raw do
		if pt.kind == "sit" and pt.accessible then
			table.insert(chairs, pt)
		end
	end
	local list, byKey = {}, {}
	for _, pt in raw do
		local key = tostring(pt.instance) .. "#" .. tostring(pt.slot)
		local seated = Office.INTERACTION_KINDS[pt.kind] == "seat"
		local sp = {
			key = key,
			keys = { key },
			kind = pt.kind,
			instance = pt.instance,
			item = pt.item,
			x = pt.x,
			y = pt.y,
			facing = pt.facing,
			seatH = pt.seatH,
			approach = pt.approach,
			usable = pt.accessible == true,
			seated = seated,
			reason = pt.reason,
			chair = nil :: string?,
		}
		if pt.kind == "work" or pt.kind == "meet" then
			local best, bestD = nil, Act.COMBO_DIST + 1e-6
			for _, c in chairs do
				local d = dist(c.x, c.y, pt.x, pt.y)
				if d <= bestD then
					best, bestD = c, d
				end
			end
			if best then
				sp.seated = true
				sp.x, sp.y, sp.seatH, sp.approach = best.x, best.y, best.seatH, best.approach
				sp.chair = tostring(best.instance) .. "#" .. tostring(best.slot)
				sp.keys = { key, sp.chair :: string }
				sp.usable = true
			end
		end
		sp.sig = spotSig(sp)
		table.insert(list, sp)
		byKey[key] = sp
	end
	return list, byKey
end

local function capacity(r: any, grid: any): number
	if not grid or #grid.entries == 0 then
		return 0 -- sin entrada transitable: nadie puede estar ahí
	end
	return math.max(1, math.floor(r.w * r.d / Act.AREA_PER_NPC))
end

local function buildRoom(world: any, r: any): any
	local o = world.office
	local grid = Nav.grid(o, r.id)
	local spots, byKey = buildSpots(o, r.id)
	return { id = r.id, room = r, grid = grid, spots = spots, byKey = byKey, cap = capacity(r, grid), sig = Nav.roomSig(o, r.id) }
end

-- Reservas ---------------------------------------------------------------------------------------------------

function Act.reservedBy(world: any, key: string): string?
	return world.res[key]
end

-- ¿Están libres todas las claves de un punto (o son de este mismo empleado) y no hay nadie parado ahí?
local function spotFree(world: any, sp: any, npcId: string): boolean
	for _, k in sp.keys do
		local who = world.res[k]
		if who and who ~= npcId then
			return false
		end
	end
	for id, other in world.npcs do
		if id ~= npcId and other.room ~= nil then
			local busy = other.activity and other.activity.spot
			if busy and dist(busy.x, busy.y, sp.x, sp.y) < Act.PERSONAL_SPACE then
				return false
			end
			if not other.activity and other.state ~= "Walking" and dist(other.x, other.y, sp.x, sp.y) < Act.PERSONAL_SPACE then
				return false
			end
		end
	end
	return true
end

local function reserve(world: any, npc: any, keys: { string }): boolean
	for _, k in keys do
		if world.res[k] and world.res[k] ~= npc.id then
			return false
		end
	end
	for _, k in keys do
		world.res[k] = npc.id
	end
	return true
end
Act._reserve = reserve

local function release(world: any, npc: any)
	for k, who in world.res do
		if who == npc.id then
			world.res[k] = nil
		end
	end
end

-- Mundo ------------------------------------------------------------------------------------------------------

function Act.new(office: any, opts: any?): any
	local world = {
		office = office,
		level = office and office.level or 1,
		rooms = {} :: { [string]: any },
		roomOrder = {} :: { string },
		npcs = {} :: { [string]: any },
		order = {} :: { string },
		res = {} :: { [string]: string },
		t = 0,
		seed = hash((opts and opts.seed) or "oficina"),
		max = (opts and opts.max) or Act.MAX_VISIBLE_NPCS,
		rotateEvery = (opts and opts.rotateEvery) or Act.ROTATE_EVERY,
		rotateAt = 0,
		rotations = 0,
		gone = {} :: { string }, -- empleados que dejaron de verse (el gestor destruye su modelo)
		nextUp = nil :: string?, -- empleado que entra en la próxima rotación
		justLeft = nil :: string?,
		hired = 0,
		employees = {} :: { any },
		spawned = 0,
		replans = 0,
		plans = 0,
	}
	world.rotateAt = world.rotateEvery
	if office then
		for _, r in OfficeCatalog.plan(world.level).rooms do
			world.rooms[r.id] = buildRoom(world, r)
			table.insert(world.roomOrder, r.id)
		end
	end
	return world
end

local function inRoom(world: any, roomId: string): number
	local n = 0
	for _, npc in world.npcs do
		if npc.room == roomId and not npc.leaving then
			n += 1
		end
	end
	return n
end

function Act.totalCapacity(world: any): number
	local n = 0
	for _, rd in world.rooms do
		n += rd.cap
	end
	return n
end

-- Habitación para un empleado nuevo: la menos ocupada en proporción a su tamaño (con lugar libre), con una
-- leve preferencia por la que tiene muebles que su departamento prefiere.
local function assignRoom(world: any, dept: string?): string?
	local prefs = (dept and Act.PREFS[dept]) or Act.DEFAULT_PREF
	local best, bestScore = nil, math.huge
	for _, id in world.roomOrder do
		local rd = world.rooms[id]
		local n = inRoom(world, id)
		if rd.cap > n then
			local liked = 0
			for _, sp in rd.spots do
				if sp.usable and (prefs[sp.kind] or 0) >= 2 then
					liked += 1
				end
			end
			local score = (n + 1) / rd.cap - math.min(liked, 3) * 0.05
			if score < bestScore - 1e-9 then
				best, bestScore = id, score
			end
		end
	end
	return best
end

-- Nodo libre y alcanzable de una habitación, lejos de los demás empleados.
local function freeSpotIn(world: any, npc: any, rd: any, entry: boolean): (number?, number?)
	local grid = rd.grid
	if not grid then
		return nil, nil
	end
	local function farFromOthers(x: number, y: number): boolean
		for id, other in world.npcs do
			if id ~= npc.id and other.room == rd.id then
				if dist(other.x, other.y, x, y) < Act.PERSONAL_SPACE then
					return false
				end
				local sp = other.activity and other.activity.spot
				if sp and dist(sp.x, sp.y, x, y) < Act.PERSONAL_SPACE then
					return false
				end
			end
		end
		return true
	end
	local cands = {}
	if entry then
		for _, idx in grid.entries do
			table.insert(cands, idx)
		end
	else
		for idx = 1, grid.cols * grid.rows do
			if Nav.reachable(grid, idx) then
				table.insert(cands, idx)
			end
		end
	end
	if #cands == 0 then
		return nil, nil
	end
	for _ = 1, 24 do
		local idx = cands[math.floor(rand(npc) * #cands) + 1]
		local x, y = Nav.nodePos(grid, idx)
		if farFromOthers(x, y) then
			return x, y
		end
	end
	local x, y = Nav.nodePos(grid, cands[1])
	return x, y
end

local function setIdle(_world: any, npc: any, range: { number }?)
	npc.state = "Idle"
	npc.activity = nil
	npc.path, npc.pi = nil, 1
	npc.phase = nil
	npc.pose = "idle"
	npc.timer = between(npc, range or Act.PAUSE) * npc.durK
	npc.wander = nil
end

local function spawn(world: any, e: any, initial: boolean): any?
	local id = idKey(e.id)
	local npc = {
		id = id,
		employee = e.id,
		name = tostring(e.name or "Empleado"),
		dept = e.dept,
		spec = e.spec,
		room = nil :: string?,
		x = 0,
		y = 0,
		heading = 90,
		state = "Idle",
		activity = nil :: any,
		path = nil :: any,
		pi = 1,
		timer = 0,
		phase = nil :: string?,
		phaseT = 0,
		pose = "idle",
		nav = "—",
		avoid = {} :: { [string]: number },
		home = nil :: string?,
		lastKey = nil :: string?,
		seed = hash(id .. "|" .. tostring(world.seed)),
		durK = 1,
		speedK = 1,
		interrupts = 0,
		blockT = 0,
		spawnT = world.t,
		leaving = false,
	}
	npc.durK = 0.85 + 0.35 * rand(npc)
	npc.speedK = 0.9 + 0.2 * rand(npc)
	local roomId = assignRoom(world, e.dept)
	if not roomId then
		return nil
	end
	npc.room = roomId
	world.npcs[id] = npc
	local x, y = freeSpotIn(world, npc, world.rooms[roomId], not initial)
	if not x then
		world.npcs[id] = nil
		return nil
	end
	npc.x, npc.y = x, y :: number
	npc.heading = initial and (math.floor(rand(npc) * 8) * 45) or 0
	table.insert(world.order, id)
	world.spawned += 1
	setIdle(world, npc, initial and Act.FIRST_DELAY or { 0.3, 1 })
	npc.nav = initial and "—" or "Entrando a la habitación"
	return npc
end

local function removeNpc(world: any, id: string)
	local npc = world.npcs[id]
	if not npc then
		return
	end
	release(world, npc)
	world.npcs[id] = nil
	local i = table.find(world.order, id)
	if i then
		table.remove(world.order, i)
	end
	table.insert(world.gone, id)
end
Act.remove = removeNpc

-- Orden estable de los contratados: el mismo siempre (por id), sin depender del orden de la lista.
local function stableOrder(world: any, list: { any }): { any }
	local out = table.clone(list)
	local salt = tostring(world.seed)
	table.sort(out, function(a: any, b: any): boolean
		local ha, hb = hash(idKey(a.id) .. salt), hash(idKey(b.id) .. salt)
		if ha ~= hb then
			return ha < hb
		end
		return idKey(a.id) < idKey(b.id)
	end)
	return out
end

-- Cuántos se ven: nunca más que los contratados, que el máximo ni que el lugar de las habitaciones.
function Act.targetVisible(world: any): number
	return math.min(world.max, world.hired, Act.totalCapacity(world))
end

--[[ Sincroniza con g.employees. initial = al abrir el editor (aparecen repartidos por la habitación; después
	los nuevos entran por la puerta). Devuelve (agregados, quitados, actualizados) como listas de ids. ]]
function Act.setEmployees(world: any, list: { any }?, initial: boolean?): ({ string }, { string }, { string })
	local byId, valid = {}, {}
	for _, e in list or {} do
		if type(e) == "table" and e.id ~= nil and byId[idKey(e.id)] == nil then
			byId[idKey(e.id)] = e
			table.insert(valid, e)
		end
	end
	world.employees = valid
	world.hired = #valid
	local removed, changed, added = {}, {}, {}
	for _, id in table.clone(world.order) do
		if not byId[id] then
			removeNpc(world, id)
			table.insert(removed, id)
		end
	end
	for id, npc in world.npcs do
		local e = byId[id]
		local name = tostring(e.name or "Empleado")
		if npc.name ~= name or npc.dept ~= e.dept then
			npc.name, npc.dept, npc.spec = name, e.dept, e.spec
			table.insert(changed, id)
		end
	end
	local target = Act.targetVisible(world)
	-- Si sobran (bajó el máximo o el lugar), salen los últimos en aparecer.
	while #world.order > target do
		local id = world.order[#world.order]
		removeNpc(world, id)
		table.insert(removed, id)
	end
	for _, id in Act.fill(world, initial == true) do
		table.insert(added, id)
	end
	return added, removed, changed
end

-- Completa hasta la cantidad visible: primero el que espera turno por la rotación, después en orden estable.
function Act.fill(world: any, initial: boolean?): { string }
	local added = {}
	local target = Act.targetVisible(world)
	local function try(e: any)
		if #world.order < target and not world.npcs[idKey(e.id)] then
			local npc = spawn(world, e, initial == true)
			if npc then
				table.insert(added, npc.id)
			end
		end
	end
	if world.nextUp then
		for _, e in world.employees do
			if idKey(e.id) == world.nextUp then
				try(e)
			end
		end
		world.nextUp = nil
	end
	for _, e in stableOrder(world, world.employees) do
		if #world.order >= target then
			break
		end
		if idKey(e.id) ~= world.justLeft then
			try(e)
		end
	end
	world.justLeft = nil
	return added
end

-- Actividades ------------------------------------------------------------------------------------------------

local function meetCount(world: any, instance: string, except: string): number
	local n = 0
	for id, npc in world.npcs do
		if id ~= except and npc.activity and npc.activity.kind == "meet" and npc.activity.spot.instance == instance then
			n += 1
		end
	end
	return n
end

local function startPath(world: any, npc: any, tx: number, ty: number): (boolean, string?)
	local rd = world.rooms[npc.room]
	world.plans += 1
	-- Quien está detenido en la habitación (de pie) se rodea si se puede: nadie atraviesa a otro empleado.
	local avoid = {}
	for id, other in world.npcs do
		if id ~= npc.id and other.room == npc.room and other.state ~= "Walking" and not Act.isSeated(other) then
			table.insert(avoid, { other.x, other.y, Act.PERSONAL_SPACE })
		end
	end
	local path, why = Nav.findPath(rd and rd.grid, npc.x, npc.y, tx, ty, avoid)
	if not path then
		return false, why
	end
	npc.path, npc.pi = path, 1
	npc.state = "Walking"
	npc.pose = "walk"
	npc.blockT = 0
	return true, nil
end

-- Lleva al empleado a un punto de uso (reserva primero; si no hay ruta, libera y evita ese punto un rato).
local function goToSpot(world: any, npc: any, sp: any): boolean
	if not reserve(world, npc, sp.keys) then
		return false
	end
	local ok, why = startPath(world, npc, sp.approach.x, sp.approach.y)
	if not ok then
		release(world, npc)
		npc.avoid[sp.key] = world.t + Act.AVOID_TIME
		npc.nav = "Sin recorrido: " .. tostring(why)
		setIdle(world, npc)
		return false
	end
	npc.activity = { kind = sp.kind, spot = sp, key = sp.key, keys = sp.keys }
	npc.nav = "En camino"
	return true
end

local function wander(world: any, npc: any): boolean
	local rd = world.rooms[npc.room]
	local grid = rd and rd.grid
	if not grid then
		return false
	end
	for _ = 1, 12 do
		local idx = math.floor(rand(npc) * grid.cols * grid.rows) + 1
		if Nav.reachable(grid, idx) then
			local x, y = Nav.nodePos(grid, idx)
			local d = dist(x, y, npc.x, npc.y)
			local ok = d >= 1.5 and d <= 4.5
			if ok then
				for id, other in world.npcs do
					if id ~= npc.id and other.room == npc.room then
						local sp = other.activity and other.activity.spot
						if dist(other.x, other.y, x, y) < Act.PERSONAL_SPACE or (sp and dist(sp.x, sp.y, x, y) < Act.PERSONAL_SPACE) or (other.wander and dist(other.wander[1], other.wander[2], x, y) < Act.PERSONAL_SPACE) then
							ok = false
							break
						end
					end
				end
			end
			if ok and startPath(world, npc, x, y) then
				npc.wander = { x, y }
				npc.nav = "Paseo corto"
				return true
			end
		end
	end
	return false
end

-- Elige qué hacer (pesos por departamento, solo puntos accesibles, libres y no evitados).
local function choose(world: any, npc: any)
	local rd = world.rooms[npc.room]
	if not rd then
		setIdle(world, npc)
		return
	end
	local prefs = Act.PREFS[npc.dept] or Act.DEFAULT_PREF
	local people = inRoom(world, npc.room)
	local cands, total = {}, 0
	for _, sp in rd.spots do
		local avoided = npc.avoid[sp.key] and npc.avoid[sp.key] > world.t
		if sp.usable and sp.approach and not avoided and not (npc.lastKey == sp.key and sp.kind ~= "work") and spotFree(world, sp, npc.id) then
			local w = prefs[sp.kind] or 0.5
			if sp.kind == "meet" then
				if people < 2 then
					w = 0 -- una reunión necesita al menos dos personas en la habitación
				elseif meetCount(world, sp.instance, npc.id) > 0 then
					w *= 3 -- se suman a la reunión que ya empezó
				end
			end
			if npc.home == sp.key then
				w *= 2.5 -- vuelve a su puesto de trabajo
			end
			if w > 0 then
				total += w
				table.insert(cands, { w = w, sp = sp })
			end
		end
	end
	total += Act.WANDER_WEIGHT + Act.IDLE_WEIGHT
	local pick = rand(npc) * total
	for _, c in cands do
		pick -= c.w
		if pick <= 0 then
			if goToSpot(world, npc, c.sp) then
				return
			end
			break
		end
	end
	if pick > 0 and pick <= Act.WANDER_WEIGHT and wander(world, npc) then
		return
	end
	setIdle(world, npc)
	if not string.find(npc.nav, "Sin recorrido", 1, true) then
		npc.nav = "—"
	end
end

local function finishActivity(world: any, npc: any)
	local a = npc.activity
	if a then
		npc.lastKey = a.key
	end
	release(world, npc)
	setIdle(world, npc)
	npc.nav = "—"
end

local function arrive(world: any, npc: any)
	npc.path, npc.pi = nil, 1
	local a = npc.activity
	if npc.leaving then
		removeNpc(world, npc.id)
		world.justLeft = npc.id
		Act.fill(world, false) -- recién ahora entra el reemplazo: nunca hay más visibles que el máximo
		return
	end
	if not a then
		setIdle(world, npc, Act.DURATIONS.wander)
		npc.nav = "—"
		return
	end
	local sp = a.spot
	npc.state = STATE_OF[a.kind] or "Idle"
	npc.timer = between(npc, Act.DURATIONS[a.kind] or Act.PAUSE) * npc.durK
	if a.kind == "work" then
		npc.home = a.key
	end
	if sp.seated then
		npc.phase = "down"
		npc.phaseT = 0
		npc.from = { npc.x, npc.y }
	else
		npc.x, npc.y = sp.x, sp.y
	end
	npc.pose = a.kind == "work" and (sp.seated and "sitwork" or "work") or a.kind == "meet" and (sp.seated and "sitmeet" or "meet") or a.kind == "sit" and "sit" or a.kind == "rest" and "rest" or a.kind == "browse" and "browse" or "idle"
	npc.nav = "En su lugar"
end

local function turnToward(npc: any, target: number, dt: number)
	local d = angleDiff(npc.heading, target)
	local step = Act.TURN_SPEED * dt
	if math.abs(d) <= step then
		npc.heading = target % 360
	else
		npc.heading = (npc.heading + (d > 0 and step or -step)) % 360
	end
end

local function stepWalk(world: any, npc: any, dt: number)
	local wp = npc.path and npc.path[npc.pi]
	if not wp then
		arrive(world, npc)
		return
	end
	local dx, dy = wp[1] - npc.x, wp[2] - npc.y
	local d = math.sqrt(dx * dx + dy * dy)
	if d < 1e-4 then
		npc.pi += 1
		return
	end
	local want = math.deg(math.atan2(dy, dx)) % 360
	turnToward(npc, want, dt)
	-- Ceder el paso a quien está adelante (un rato; después sigue).
	local hx, hy = math.cos(math.rad(npc.heading)), math.sin(math.rad(npc.heading))
	for id, other in world.npcs do
		if id ~= npc.id and other.room == npc.room then
			local ox, oy = other.x - npc.x, other.y - npc.y
			local od = math.sqrt(ox * ox + oy * oy)
			if od < Act.YIELD_DIST and od > 1e-6 and (ox * hx + oy * hy) / od > 0.5 and npc.blockT < Act.YIELD_MAX and id < npc.id then
				npc.blockT += dt
				return
			end
		end
	end
	-- Más lento mientras gira (no camina de costado).
	local align = math.max(0.25, math.cos(math.rad(angleDiff(npc.heading, want))))
	local move = math.min(d, Act.WALK_SPEED * npc.speedK * align * dt)
	npc.x += dx / d * move
	npc.y += dy / d * move
	if move >= d - 1e-6 then
		npc.pi += 1
		npc.blockT = 0
		if npc.pi > #npc.path then
			arrive(world, npc)
		end
	end
end

local function stepNpc(world: any, npc: any, dt: number)
	if npc.state == "Walking" then
		stepWalk(world, npc, dt)
		return
	end
	if npc.state == "Idle" then
		npc.timer -= dt
		if npc.timer <= 0 then
			choose(world, npc)
		end
		return
	end
	-- En una actividad.
	local a = npc.activity
	if not a then
		setIdle(world, npc)
		return
	end
	local sp = a.spot
	if npc.phase == "down" or npc.phase == "up" then
		npc.phaseT += dt
		local k = math.clamp(npc.phaseT / Act.SIT_TIME, 0, 1)
		local ax, ay = sp.approach.x, sp.approach.y
		if npc.phase == "down" then
			npc.x, npc.y = ax + (sp.x - ax) * k, ay + (sp.y - ay) * k
		else
			npc.x, npc.y = sp.x + (ax - sp.x) * k, sp.y + (ay - sp.y) * k
		end
		turnToward(npc, sp.facing, dt * 2)
		if k >= 1 then
			if npc.phase == "up" then
				npc.x, npc.y = ax, ay
				finishActivity(world, npc)
			else
				npc.phase = nil
			end
		end
		return
	end
	turnToward(npc, sp.facing, dt)
	npc.timer -= dt
	if npc.timer <= 0 then
		if sp.seated then
			npc.phase = "up"
			npc.phaseT = 0
		else
			finishActivity(world, npc)
		end
	end
end

-- ¿Está sentado (o sentándose / levantándose) sobre un mueble?
function Act.isSeated(npc: any): boolean
	local a = npc.activity
	return a ~= nil and a.spot.seated and npc.state ~= "Walking"
end

-- Rotación ocasional de quién se ve: uno por vez, solo alguien en reposo, y sale por la puerta.
local function rotate(world: any)
	world.rotateAt = world.t + world.rotateEvery
	if world.hired <= #world.order then
		return
	end
	local out = nil
	for _, id in world.order do
		local npc = world.npcs[id]
		if npc.state == "Idle" and not npc.leaving and (not out or npc.spawnT < out.spawnT) then
			out = npc
		end
	end
	if not out then
		world.rotateAt = world.t + 10 -- nadie libre ahora: probar en un rato
		return
	end
	local nextE = nil
	local ordered = stableOrder(world, world.employees)
	local start = (world.rotations % math.max(1, #ordered)) + 1
	for k = 0, #ordered - 1 do
		local e = ordered[(start + k - 1) % #ordered + 1]
		if not world.npcs[idKey(e.id)] then
			nextE = e
			break
		end
	end
	if not nextE then
		return
	end
	world.rotations += 1
	-- El que sale camina hasta la puerta (si no puede, desaparece ahí mismo); el reemplazo entra después.
	world.nextUp = idKey(nextE.id)
	out.leaving = true
	release(world, out)
	local rd = world.rooms[out.room]
	local ex, ey = freeSpotIn(world, out, rd, true)
	if ex and startPath(world, out, ex, ey :: number) then
		out.activity = nil
		out.nav = "Saliendo de la habitación"
	else
		removeNpc(world, out.id)
		world.justLeft = out.id
		Act.fill(world, false)
	end
end

-- Avanza la simulación visual dt segundos (en pasos de MAX_DT como máximo).
function Act.step(world: any, dt: number)
	dt = math.clamp(dt, 0, 2)
	while dt > 1e-9 do
		local h = math.min(dt, Act.MAX_DT)
		dt -= h
		world.t += h
		if world.t >= world.rotateAt then
			rotate(world)
		end
		for _, id in table.clone(world.order) do
			local npc = world.npcs[id]
			if npc then
				stepNpc(world, npc, h)
			end
		end
	end
end

-- Cambios de la oficina --------------------------------------------------------------------------------------

local function interrupt(world: any, npc: any, reason: string)
	release(world, npc)
	setIdle(world, npc, { 0.8, 2 })
	npc.interrupts += 1
	npc.nav = "Interrumpido: " .. reason
end
Act.interrupt = interrupt

-- Si el empleado quedó dentro de un mueble (o fuera de la zona alcanzable), pasa al lugar libre más cercano.
local function ensureFree(world: any, npc: any)
	local rd = world.rooms[npc.room]
	local grid = rd and rd.grid
	if not grid or Act.isSeated(npc) then
		return
	end
	if Nav.clearAt(grid, npc.x, npc.y) then
		local idx = Nav.nearest(grid, npc.x, npc.y, { maxD = 0.75 })
		if idx and Nav.reachable(grid, idx) then
			return
		end
	end
	local idx = Nav.nearest(grid, npc.x, npc.y, { maxD = 12, reach = true })
	if idx then
		npc.x, npc.y = Nav.nodePos(grid, idx)
	else
		local x, y = freeSpotIn(world, npc, rd, true)
		if x then
			npc.x, npc.y = x, y :: number
		end
	end
end
Act.ensureFree = ensureFree

local function pathStillClear(rd: any, npc: any): boolean
	if not npc.path then
		return true
	end
	local px, py = npc.x, npc.y
	for i = npc.pi, #npc.path do
		local wp = npc.path[i]
		if not Nav.segmentClear(rd.grid, px, py, wp[1], wp[2]) then
			return false
		end
		px, py = wp[1], wp[2]
	end
	return true
end

--[[ Nueva oficina confirmada por el servidor (nunca una vista previa). Rearma solo las habitaciones cuyos
	muebles cambiaron y corrige a quien quedó afectado. Devuelve la lista de habitaciones rearmadas. ]]
function Act.setOffice(world: any, office: any): { string }
	world.office = office
	local changedRooms = {}
	if (office.level or 1) ~= world.level then
		world.level = office.level or 1
		table.clear(world.rooms)
		table.clear(world.roomOrder)
		for _, r in OfficeCatalog.plan(world.level).rooms do
			world.rooms[r.id] = buildRoom(world, r)
			table.insert(world.roomOrder, r.id)
			table.insert(changedRooms, r.id)
		end
	else
		for _, id in world.roomOrder do
			local rd = world.rooms[id]
			if Nav.roomSig(office, id) ~= rd.sig then
				world.rooms[id] = buildRoom(world, rd.room)
				table.insert(changedRooms, id)
			end
		end
	end
	if #changedRooms == 0 then
		return changedRooms
	end
	for _, id in table.clone(world.order) do
		local npc = world.npcs[id]
		if npc and not world.rooms[npc.room] then
			-- Su habitación ya no existe (ampliación): pasa a otra y entra por la puerta.
			release(world, npc)
			local roomId = assignRoom(world, npc.dept)
			if not roomId then
				removeNpc(world, id)
			else
				npc.room = roomId
				local x, y = freeSpotIn(world, npc, world.rooms[roomId], true)
				npc.x, npc.y = x or 1, y or 1
				interrupt(world, npc, "cambió la oficina")
			end
		elseif npc and table.find(changedRooms, npc.room) then
			local rd = world.rooms[npc.room]
			local a = npc.activity
			if a then
				local now = rd.byKey[a.key]
				local same = now and now.usable and now.sig == a.spot.sig and table.concat(now.keys, ",") == table.concat(a.keys, ",")
				if not same then
					interrupt(world, npc, "el mueble cambió")
				else
					a.spot = now
				end
			end
			-- Primero, nadie dentro de un mueble; después, la ruta se valida desde donde quedó.
			ensureFree(world, npc)
			if npc.state == "Walking" and not pathStillClear(rd, npc) then
				world.replans += 1
				local tx, ty
				if npc.activity then
					tx, ty = npc.activity.spot.approach.x, npc.activity.spot.approach.y
				elseif npc.wander then
					tx, ty = npc.wander[1], npc.wander[2]
				elseif npc.path and #npc.path > 0 then
					tx, ty = npc.path[#npc.path][1], npc.path[#npc.path][2]
				end
				if not (tx and startPath(world, npc, tx, ty)) then
					if npc.leaving then
						removeNpc(world, npc.id)
						world.justLeft = npc.id
						Act.fill(world, false)
					elseif npc.activity then
						interrupt(world, npc, "la ruta quedó bloqueada")
					else
						setIdle(world, npc, { 0.5, 1.5 })
						npc.nav = "Ruta bloqueada: busca otro camino"
					end
				end
			end
		end
	end
	return changedRooms
end

-- Descripciones para el panel del empleado --------------------------------------------------------------------

local function itemLabel(itemId: string?): string
	local it = itemId and OfficeCatalog.item(itemId)
	return it and string.lower(it.name) or "el mueble"
end

function Act.describe(npc: any): (string, string)
	local a = npc.activity
	local text = Act.STATE_TEXT[npc.state] or npc.state
	if npc.leaving then
		text = "Saliendo de la habitación"
	elseif npc.state == "Walking" and a then
		text = "Caminando hacia: " .. itemLabel(a.spot.item)
	elseif npc.state == "Walking" then
		text = "Caminando (paseo corto)"
	elseif a and npc.phase == "down" then
		text = "Sentándose"
	elseif a and npc.phase == "up" then
		text = "Levantándose"
	elseif npc.state == "Working" then
		text = a.spot.seated and "Trabajando en el escritorio (sentado)" or "Trabajando en el escritorio (de pie)"
	elseif npc.state == "Meeting" then
		text = a.spot.seated and "En reunión (sentado)" or "En reunión (de pie)"
	elseif npc.state == "Resting" then
		text = "Descansando en: " .. itemLabel(a.spot.item)
	elseif npc.state == "Browsing" then
		text = "Consultando archivos en la estantería"
	end
	return text, npc.nav or "—"
end

-- Lista ordenada de los empleados visibles (para la interfaz y las pruebas).
function Act.list(world: any): { any }
	local out = {}
	for _, id in world.order do
		table.insert(out, world.npcs[id])
	end
	return out
end

-- Vacía todo (al cerrar el editor): sin reservas, sin empleados, sin rutas.
function Act.clear(world: any)
	for _, id in table.clone(world.order) do
		removeNpc(world, id)
	end
	table.clear(world.res)
	table.clear(world.gone)
end

return Act
