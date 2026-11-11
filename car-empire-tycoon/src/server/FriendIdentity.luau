--!strict
--[[ Identidad de los empleados: cada empleado contratado ES un amigo de Roblox del jugador (reglas puras, sin
	servicios de Roblox; la lista la consulta server/Friends y la inyecta Sessions).

	Datos guardados por empleado (opcional, aditivo; las partidas viejas no lo tienen):
	  e.friend = { userId, username, displayName, since (día absoluto del juego), missingSince? (segundos UNIX) }
	  e.name   = displayName del amigo (lo que muestra todo el juego), o VACANT si el puesto no tiene amigo.
	Por empresa: g.identity = { lastCount } (tamaño de la última lista completa, para detectar listas sospechosas).

	Lista de amigos (roster) que llega de Sessions:
	  { status = "loading" | "ok" | "failed", complete = boolean (se leyeron todas las páginas), list = { { userId,
	    username, displayName } }, fetchedAt }

	Reglas:
	  - Al contratar se asigna solo, sin elegir: el primer amigo libre en un orden estable por empresa.
	  - Un amigo representa como máximo a un empleado por empresa (nunca dos empleados con el mismo amigo).
	  - Sin amigos libres (o sin lista todavía): el puesto económico se crea igual, sin identidad (no aparece en la
	    oficina) y recibe un amigo apenas haya uno libre.
	  - Despedir libera al amigo (el empleado deja de existir).
	  - Habilidades, especialidad, salario, antigüedad y productividad NUNCA cambian por la identidad.

	Política de reasignación segura (un empleado guardado cuyo amigo ya no está en la lista):
	  1. Solo cuenta una lista "confiable": consulta exitosa, todas las páginas leídas y sin una caída brusca
	     (menos de DROP_GUARD de la última lista completa, que suele ser una falla de la API y no amistades
	     terminadas). Con una lista fallida, incompleta o sospechosa no se quita ni reemplaza a nadie.
	  2. La primera vez que falta se anota missingSince. Si vuelve a aparecer, se borra la marca.
	  3. Recién cuando sigue faltando en una lista confiable al menos MISSING_CONFIRM segundos después (otra
	     consulta, en esta sesión o en otra), su puesto pasa al próximo amigo libre conservando todas las
	     estadísticas laborales; si no hay amigos libres, el puesto queda sin identidad hasta que haya uno. ]]

local FI = {}

FI.MISSING_CONFIRM = 600 -- segundos entre dos listas confiables que confirman que ya no es amigo
FI.DROP_GUARD = 0.5 -- una lista con menos de la mitad que la última completa no se usa para quitar a nadie
FI.MAX_FRIENDS = 1000
FI.VACANT = "Puesto sin amigo asignado"

local function hash(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 2147483647
	end
	return h
end

local function cleanText(v: any, max: number): string?
	if type(v) ~= "string" or v == "" then
		return nil
	end
	return string.sub(v, 1, max)
end

local function validId(v: any): boolean
	return type(v) == "number" and v > 0 and v == math.floor(v) and v < 2 ^ 53
end

-- Amigo guardado válido (o nil).
function FI.cleanFriend(f: any): any
	if type(f) ~= "table" or not validId(f.userId) then
		return nil
	end
	local username = cleanText(f.username, 40)
	if not username then
		return nil
	end
	return {
		userId = f.userId,
		username = username,
		displayName = cleanText(f.displayName, 40) or username,
		since = type(f.since) == "number" and f.since or 0,
		missingSince = type(f.missingSince) == "number" and f.missingSince or nil,
	}
end

-- Repara lo guardado: amigos inválidos o repetidos dentro de la misma empresa quedan sin identidad (sus
-- estadísticas no se tocan). Idempotente; lo usa la carga de partidas.
function FI.sanitize(g: any)
	local seen = {}
	for _, e in (type(g.employees) == "table" and g.employees or {}) do
		if type(e) == "table" then
			local f = FI.cleanFriend(e.friend)
			if f and seen[f.userId] then
				f = nil
			end
			e.friend = f
			if f then
				seen[f.userId] = true
				e.name = f.displayName
			end
		end
	end
	if type(g.identity) ~= "table" or (g.identity.lastCount ~= nil and type(g.identity.lastCount) ~= "number") then
		g.identity = {}
	end
end

-- Lista normalizada: sin repetidos ni datos inválidos, con índice por userId.
function FI.roster(raw: any): any
	local out = { status = "loading", complete = false, list = {}, byId = {}, fetchedAt = 0 }
	if type(raw) ~= "table" then
		return out
	end
	out.status = raw.status == "ok" and "ok" or raw.status == "failed" and "failed" or "loading"
	out.complete = raw.complete == true
	out.fetchedAt = type(raw.fetchedAt) == "number" and raw.fetchedAt or 0
	for _, f in (type(raw.list) == "table" and raw.list or {}) do
		local c = FI.cleanFriend(f)
		if c and not out.byId[c.userId] and #out.list < FI.MAX_FRIENDS then
			c.since, c.missingSince = nil, nil
			table.insert(out.list, c)
			out.byId[c.userId] = c
		end
	end
	return out
end

local function ensureRoster(r: any): any
	if type(r) == "table" and r.byId then
		return r
	end
	return FI.roster(r)
end

function FI.assignedIds(g: any): { [number]: any }
	local out = {}
	for _, e in g.employees or {} do
		if e.friend then
			out[e.friend.userId] = e
		end
	end
	return out
end

-- Amigos libres en el orden estable de esta empresa (distinto en cada empresa, siempre el mismo en una).
function FI.available(g: any, roster: any): { any }
	roster = ensureRoster(roster)
	local used = FI.assignedIds(g)
	local salt = tostring(g.company and g.company.id or g.company and g.company.name or "empresa")
	local out = {}
	for _, f in roster.list do
		if not used[f.userId] then
			table.insert(out, f)
		end
	end
	table.sort(out, function(a: any, b: any): boolean
		local ha, hb = hash(salt .. ":" .. a.userId), hash(salt .. ":" .. b.userId)
		if ha ~= hb then
			return ha < hb
		end
		return a.userId < b.userId
	end)
	return out
end

-- El amigo que recibiría la próxima contratación (o nil).
function FI.nextFriend(g: any, roster: any): any
	if ensureRoster(roster).status ~= "ok" then
		return nil
	end
	return FI.available(g, roster)[1]
end

local function give(e: any, f: any, day: number)
	e.friend = { userId = f.userId, username = f.username, displayName = f.displayName, since = day }
	e.name = f.displayName
end

local function vacate(e: any)
	e.friend = nil
	e.name = FI.VACANT
end

--[[ Identidad de un empleado recién contratado: el próximo amigo libre. Sin lista disponible o sin amigos libres
	queda como puesto sin identidad (se le asigna uno después, en FI.reconcile). Devuelve el amigo o nil. ]]
function FI.assign(g: any, e: any, roster: any, day: number?): any
	local f = FI.nextFriend(g, roster)
	if f then
		give(e, f, day or 0)
		return f
	end
	vacate(e)
	return nil
end

--[[ Aplica la lista de amigos a una empresa (al cargarla y cada vez que llega una lista nueva). Devuelve
	{ assigned, renamed, marked, reassigned, released, messages } y cambia solo identidades. ]]
function FI.reconcile(g: any, rawRoster: any, now: number, day: number?): any
	local roster = ensureRoster(rawRoster)
	local res = { assigned = 0, renamed = 0, marked = 0, reassigned = 0, released = 0, messages = {} :: { string } }
	if roster.status ~= "ok" or type(g.employees) ~= "table" then
		return res -- sin lista: se conservan todas las asignaciones guardadas
	end
	g.identity = type(g.identity) == "table" and g.identity or {}
	local last = g.identity.lastCount
	local suspicious = type(last) == "number" and last >= 4 and #roster.list < last * FI.DROP_GUARD
	local reliable = roster.complete and not suspicious
	local stale = {}
	for _, e in g.employees do
		local f = e.friend
		if f then
			local cur = roster.byId[f.userId]
			if cur then
				f.missingSince = nil
				if cur.displayName ~= f.displayName or cur.username ~= f.username then
					f.displayName, f.username = cur.displayName, cur.username
					res.renamed += 1
				end
				e.name = f.displayName
			elseif reliable then
				if not f.missingSince then
					f.missingSince = now
					res.marked += 1
				elseif now - f.missingSince >= FI.MISSING_CONFIRM then
					table.insert(stale, e)
				end
			end
		end
	end
	for _, e in stale do
		local old: string = tostring(e.friend.displayName)
		vacate(e)
		e.staleFrom = old -- solo para el mensaje de abajo (no se guarda: se borra antes de terminar)
	end
	-- Puestos sin identidad (nuevos, viejos o liberados): reciben amigos libres en orden de antigüedad.
	local pending = {}
	for _, e in g.employees do
		if not e.friend then
			table.insert(pending, e)
		end
	end
	table.sort(pending, function(a: any, b: any): boolean
		if (a.hiredDay or 0) ~= (b.hiredDay or 0) then
			return (a.hiredDay or 0) < (b.hiredDay or 0)
		end
		return tostring(a.id) < tostring(b.id)
	end)
	local free = FI.available(g, roster)
	local k = 1
	for _, e in pending do
		local f = free[k]
		local old: string? = e.staleFrom
		e.staleFrom = nil
		if f then
			k += 1
			give(e, f, day or 0)
			if old then
				res.reassigned += 1
				table.insert(res.messages, old .. " ya no está entre tus amigos de Roblox: su puesto lo ocupa ahora " .. f.displayName .. ", con las mismas habilidades y antigüedad.")
			else
				res.assigned += 1
			end
		else
			e.name = FI.VACANT
			if old then
				res.released += 1
				table.insert(res.messages, old .. " ya no está entre tus amigos de Roblox: su puesto sigue (mismas habilidades) y recibirá un amigo cuando haya uno libre.")
			end
		end
	end
	if reliable then
		g.identity.lastCount = #roster.list
	end
	return res
end

-- Resumen para la interfaz (cuántos amigos, cuántos libres, a quién se contrataría ahora).
function FI.summary(g: any, rawRoster: any): any
	local roster = ensureRoster(rawRoster)
	local free = roster.status == "ok" and FI.available(g, roster) or {}
	local nx = free[1]
	local vacant = 0
	for _, e in (g and g.employees) or {} do
		if not e.friend then
			vacant += 1
		end
	end
	return {
		status = roster.status,
		complete = roster.complete,
		total = #roster.list,
		available = #free,
		vacant = vacant,
		next = nx and { userId = nx.userId, username = nx.username, displayName = nx.displayName } or nil,
	}
end

return FI
