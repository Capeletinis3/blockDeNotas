--!strict
--[[ Ciclo de vida de los empleados visibles del editor de oficinas (cliente, solo local).

	Une las piezas sin mezclarlas:
	  OfficeActivities  → qué hace cada uno, rutas y reservas (lógica pura)
	  OfficeNavigation  → zonas transitables y rutas (compartido)
	  OfficeNPC         → personaje provisional o definitivo de cada empleado
	  OfficeAnimations  → poses y transiciones
	  OfficeScene       → posición en el mundo de cada habitación (los empleados viven dentro de la carpeta
	                      de la escena del editor: no existen fuera de él)

	Lo maneja OfficeEditor: open al entrar (después de armar habitaciones y muebles), sync con cada partida
	nueva del servidor y close al salir (antes de destruir la escena). Una sola conexión a Heartbeat mientras el
	editor está abierto, que se desconecta al cerrar: abrir y cerrar muchas veces no acumula conexiones.

	Identidad: solo se representan empleados con un amigo de Roblox asignado (e.friend, lo decide el servidor
	al contratar). El personaje es el avatar real de ese amigo: se pide al servidor (evento Avatares, en lotes,
	a lo sumo cada REQUEST_GAP segundos y reintentando cada RETRY segundos) y se dibuja cuando llega. Mientras
	no llegó, el empleado no se ve (nunca un personaje genérico).

	Separado de la economía: solo lee App.g (copia sincronizada por el servidor). No envía solicitudes que
	cambien la partida y no avanza g.time (la empresa sigue en pausa con setUiPause mientras el editor está
	abierto); su reloj es propio. ]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local OfficeCatalog = require(Shared.OfficeCatalog)
local Catalog = require(Shared.Catalog)

local Act = require(script.Parent.OfficeActivities)
local NPC = require(script.Parent.OfficeNPC)
local Anim = require(script.Parent.OfficeAnimations)
local Scene = require(script.Parent.OfficeScene)

local Manager = {}

Manager.UPDATE_HZ = 30 -- pasos por segundo de movimiento y animación (no se calculan rutas por cuadro)
Manager.REQUEST_GAP = 1 -- segundos entre pedidos de avatares al servidor
Manager.RETRY = 20 -- segundos antes de volver a pedir un avatar que no llegó
Manager.REFRESH_AFTER = 1800 -- un avatar más viejo que esto se pide de nuevo al abrir el editor (actualizado)

local st = {
	open = false,
	company = nil :: string?,
	world = nil :: any,
	rigs = {} :: { [string]: any },
	folder = nil :: Folder?,
	conn = nil :: RBXScriptConnection?,
	acc = 0,
	officeRef = nil :: any,
	empSig = "",
	selected = nil :: string?,
	lastText = "",
	shown = true, -- «Mostrar empleados» (empieza activada; es una preferencia de esta sesión, no se guarda)
	opens = 0,
	friendOf = {} :: { [string]: number }, -- id de empleado → userId de su amigo
	requested = {} :: { [number]: number }, -- userId → cuándo se pidió
	badTemplate = setmetatable({}, { __mode = "v" }) :: { [number]: any }, -- userId → plantilla que no sirvió
	queue = {} :: { string },
	lastRequest = -math.huge,
	clock = 0,
	requests = 0,
}
Manager._state = st

-- Avisos a la pantalla: "texto" (cambió la actividad del elegido) o "estructura" (selección, cantidad).
Manager.onChange = nil :: ((string) -> ())?
local function notify(kind: string)
	if Manager.onChange then
		Manager.onChange(kind)
	end
end

local function companyOf(g: any): string
	return (g and g.company and g.company.id) and tostring(g.company.id) or "?"
end

local function employeesSig(list: { any }?): string
	local parts = {}
	for _, e in list or {} do
		table.insert(parts, tostring(e.id) .. "=" .. tostring(e.name) .. "@" .. tostring(e.dept) .. "#" .. tostring(e.friend and e.friend.userId))
	end
	return table.concat(parts, ";")
end

-- Solo los empleados que son un amigo de Roblox (los puestos sin amigo no tienen personaje).
local function withFriend(list: { any }?): { any }
	local out = {}
	table.clear(st.friendOf)
	for _, e in list or {} do
		if type(e) == "table" and type(e.friend) == "table" and type(e.friend.userId) == "number" then
			table.insert(out, e)
			st.friendOf[tostring(e.id)] = e.friend.userId
		end
	end
	return out
end

-- Carpeta donde el servidor deja los avatares de este jugador (solo la ve él).
local function templates(): Instance?
	local lp = Players.LocalPlayer
	local gui = lp and lp:FindFirstChild("PlayerGui")
	return gui and gui:FindFirstChild("AvataresEmpleados") or nil
end
Manager.templates = templates

local function templateFor(userId: number?): Model?
	local f = userId and templates()
	local m = f and f:FindFirstChild("Avatar_" .. userId)
	return (m and m:IsA("Model")) and m or nil
end

-- Pide al servidor los avatares en cola (un evento por lote, como mucho cada REQUEST_GAP segundos).
local function flushRequests()
	if #st.queue == 0 or st.clock - st.lastRequest < Manager.REQUEST_GAP then
		return
	end
	local remotes = ReplicatedStorage:FindFirstChild("CarEmpireRemotes")
	local ev = remotes and remotes:FindFirstChild("Avatares")
	local ids = table.clone(st.queue)
	table.clear(st.queue)
	st.lastRequest = st.clock
	if ev then
		st.requests += 1
		pcall(function()
			(ev :: any):FireServer(ids)
		end)
	end
end

local function want(employeeId: string, force: boolean?)
	local userId = st.friendOf[employeeId]
	if not userId then
		return
	end
	local at = st.requested[userId]
	if force or not at or st.clock - at >= Manager.RETRY then
		st.requested[userId] = st.clock
		if not table.find(st.queue, employeeId) then
			table.insert(st.queue, employeeId)
		end
	end
end

-- Orientación en el mundo: el frente del personaje (−Z) mira hacia `heading` del plano (0 = +x, 90 = +y).
function Manager.rootCFrame(npc: any): CFrame?
	local p = Scene.roomToWorld(npc.room, npc.x, npc.y)
	if not p then
		return nil
	end
	return CFrame.new(p) * CFrame.Angles(0, -math.rad(npc.heading - 270), 0)
end

local function ensureFolder()
	if st.folder and st.folder.Parent ~= nil then
		return
	end
	local f = st.folder or Instance.new("Folder")
	f.Name = "Empleados"
	st.folder = f
	local scene = Scene.folder()
	f.Parent = st.shown and scene or nil
end

-- Crea los personajes que faltan, quita los que ya no se ven y actualiza nombres y departamentos.
local function reconcile()
	local world = st.world
	if not world then
		return
	end
	local changed = false
	for _, id in world.gone do
		local rig = st.rigs[id]
		if rig then
			NPC.destroy(rig)
			st.rigs[id] = nil
			changed = true
		end
		if st.selected == id then
			st.selected = nil
		end
	end
	table.clear(world.gone)
	ensureFolder()
	for _, id in world.order do
		local npc = world.npcs[id]
		local rig = st.rigs[id]
		local userId = st.friendOf[id]
		if rig and rig.userId ~= userId then
			-- El puesto cambió de amigo (reasignación, amistad terminada): el avatar anterior se va YA, aunque el
			-- nuevo todavía no haya llegado. Nunca se muestra el avatar de otro con el nombre del nuevo.
			NPC.destroy(rig)
			st.rigs[id] = nil
			rig = nil
			if st.selected == id then
				st.lastText = ""
			end
			want(id, true)
			changed = true
		end
		local template = templateFor(userId)
		if template and st.badTemplate[userId] == template then
			template = nil -- plantilla que no se pudo armar: se espera una nueva (sin reintentar cada paso)
		end
		if rig and template and rig.builtAt ~= template:GetAttribute("builtAt") then
			-- Llegó el avatar actualizado del amigo: se rearma solo el personaje (la actividad sigue igual).
			NPC.destroy(rig)
			st.rigs[id] = nil
			rig = nil
			changed = true
		end
		if not rig then
			if template then
				local ok, built = pcall(NPC.build, id, npc.name, npc.dept, template)
				rig = ok and built or nil
				if rig and rig.userId == userId then
					rig.model.Parent = st.folder
					st.rigs[id] = rig
					changed = true
				else
					if rig then
						NPC.destroy(rig) -- plantilla de otro amigo: no se usa
					end
					rig = nil
					st.badTemplate[userId :: number] = template
					want(id, true)
				end
			else
				want(id) -- todavía no llegó: se pide (y se reintenta), sin personaje genérico mientras tanto
			end
		elseif rig.name ~= npc.name or rig.dept ~= npc.dept then
			NPC.setInfo(rig, npc.name, npc.dept) -- sin rearmar el personaje
			changed = true
		end
	end
	flushRequests()
	for id, rig in st.rigs do
		if not world.npcs[id] then
			NPC.destroy(rig)
			st.rigs[id] = nil
			changed = true
		end
	end
	if changed then
		notify("estructura")
	end
end

local function render(dt: number)
	local world = st.world
	for _, id in world.order do
		local npc = world.npcs[id]
		local rig = st.rigs[id]
		local cf = rig and Manager.rootCFrame(npc)
		if cf then
			Anim.update(rig, npc, cf, world.t, dt)
		end
	end
end

-- Un paso de simulación visual + animación (lo llama Heartbeat; las pruebas lo llaman directo).
function Manager.step(dt: number)
	if not st.open or not st.shown or not st.world then
		return -- ocultos: actividades suspendidas
	end
	st.clock += dt
	Act.step(st.world, dt)
	reconcile()
	render(dt)
	if st.selected then
		local npc = st.world.npcs[st.selected]
		if npc then
			local a, n = Act.describe(npc)
			local text = a .. "|" .. n
			if text ~= st.lastText then
				st.lastText = text
				notify("texto")
			end
		end
	end
end

local function onHeartbeat(dt: number)
	st.acc += dt
	if st.acc >= 1 / Manager.UPDATE_HZ then
		local step = st.acc
		st.acc = 0
		Manager.step(step)
	end
end

--[[ Abre (o sincroniza si ya está abierto): construye la navegación y los empleados visibles de la empresa
	activa. Sin empleados contratados la oficina queda vacía. ]]
function Manager.open(g: any)
	if st.open then
		Manager.sync(g)
		return
	end
	if not g or not g.office then
		return
	end
	st.open = true
	st.opens += 1
	st.company = companyOf(g)
	Anim.SIT_TIME = Act.SIT_TIME
	st.world = Act.new(g.office, { seed = st.company })
	st.officeRef = g.office
	st.empSig = employeesSig(g.employees)
	Act.setEmployees(st.world, withFriend(g.employees), true)
	-- Avatares viejos: se piden de nuevo (el servidor los rearma con la apariencia actual del amigo).
	for _, id in st.world.order do
		local tpl = templateFor(st.friendOf[id])
		local at = tpl and tpl:GetAttribute("builtAt")
		if type(at) == "number" and os.time() - at >= Manager.REFRESH_AFTER then
			want(id, true)
		end
	end
	st.acc = 0
	st.selected, st.lastText = nil, ""
	reconcile()
	render(0)
	st.conn = RunService.Heartbeat:Connect(onHeartbeat)
	notify("estructura")
end

-- Partida nueva del servidor: otra empresa → todo nuevo; oficina u otros empleados → solo lo que cambió.
function Manager.sync(g: any)
	if not st.open then
		return
	end
	if not g or not g.office then
		Manager.close()
		return
	end
	if companyOf(g) ~= st.company then
		Manager.close()
		Manager.open(g)
		return
	end
	local world = st.world
	if g.office ~= st.officeRef then
		st.officeRef = g.office
		Act.setOffice(world, g.office) -- solo la oficina confirmada (las vistas previas nunca llegan acá)
	end
	local sig = employeesSig(g.employees)
	if sig ~= st.empSig then
		st.empSig = sig
		Act.setEmployees(world, withFriend(g.employees), false)
	end
	reconcile()
	render(0)
end

-- Cierra: sin conexiones, reservas, rutas ni personajes.
function Manager.close()
	if st.conn then
		st.conn:Disconnect()
		st.conn = nil
	end
	if st.world then
		Act.clear(st.world)
	end
	for _, rig in st.rigs do
		NPC.destroy(rig)
	end
	table.clear(st.rigs)
	if st.folder then
		st.folder:Destroy()
		st.folder = nil
	end
	st.world, st.officeRef, st.company = nil, nil, nil
	st.empSig, st.selected, st.lastText, st.acc = "", nil, "", 0
	table.clear(st.queue)
	table.clear(st.friendOf)
	local was = st.open
	st.open = false
	if was then
		notify("estructura")
	end
end

function Manager.isOpen(): boolean
	return st.open
end

-- «Mostrar empleados»: ocultos = sin personajes en la escena y actividades suspendidas. No cambia nada más.
function Manager.setShown(on: boolean)
	st.shown = on
	if st.folder then
		st.folder.Parent = on and Scene.folder() or nil
	end
	if not on then
		st.selected = nil
	end
	notify("estructura")
end

function Manager.shown(): boolean
	return st.shown
end

--[[ Cantidades reales: (visibles ahora con su avatar, contratados en g.employees, avatares que todavía no
	llegaron, puestos sin amigo asignado). ]]
function Manager.counts(g: any?): (number, number, number, number)
	local hired = g and g.employees and #g.employees or 0
	local vacant = 0
	for _, e in (g and g.employees) or {} do
		if type(e.friend) ~= "table" then
			vacant += 1
		end
	end
	local visible, loading = 0, 0
	if st.open and st.shown and st.world then
		for _, id in st.world.order do
			if st.rigs[id] then
				visible += 1
			else
				loading += 1
			end
		end
	end
	return visible, hired, loading, vacant
end

function Manager.world(): any
	return st.world
end

function Manager.rig(employeeId: string): any
	return st.rigs[employeeId]
end

function Manager.npc(employeeId: string): any
	return st.world and st.world.npcs[employeeId] or nil
end

-- Selección de un empleado (panel compacto). nil = ninguno.
function Manager.select(employeeId: string?)
	if employeeId and not Manager.npc(employeeId) then
		employeeId = nil
	end
	st.selected = employeeId
	st.lastText = ""
	notify("estructura")
end

function Manager.selected(): string?
	return st.selected
end

--[[ Empleado bajo un rayo de la cámara: se corta el rayo con dos planos horizontales (a la altura del torso y
	de la cadera) y se elige el más cercano a esos puntos (sin raycast físico: las piezas no tienen colisión). ]]
function Manager.pickRay(origin: Vector3, dir: Vector3): string?
	local world = st.world
	if not world or not st.shown or math.abs(dir.Y) < 1e-4 then
		return nil
	end
	local best, bestD = nil, 0.7 -- casillas
	for _, h in { 3.3, 2.0 } do
		local t = (Scene.ORIGIN.Y + h - origin.Y) / dir.Y
		if t > 0 then
			local p = origin + dir * t
			for _, id in world.order do
				local npc = world.npcs[id]
				local c = st.rigs[id] and Scene.roomToWorld(npc.room, npc.x, npc.y)
				if c then
					local d = math.sqrt((p.X - c.X) ^ 2 + (p.Z - c.Z) ^ 2) / OfficeCatalog.CELL
					if d < bestD then
						best, bestD = id, d
					end
				end
			end
		end
	end
	return best
end

-- Datos del panel del empleado elegido: nombre, departamento, actividad y navegación.
function Manager.info(employeeId: string?): any
	local npc = employeeId and Manager.npc(employeeId)
	if not npc then
		return nil
	end
	local d = Catalog.department(npc.dept)
	local room = OfficeCatalog.room(st.world.level, npc.room)
	local activity, nav = Act.describe(npc)
	local userId = st.friendOf[npc.id]
	local friend
	for _, e in (st.world.employees or {}) do
		if tostring(e.id) == npc.id then
			friend = e.friend
		end
	end
	return { id = npc.id, name = npc.name, username = friend and friend.username, userId = userId, dept = d and d.name or tostring(npc.dept), room = room and room.name or npc.room, activity = activity, nav = nav, state = npc.state, avatar = st.rigs[npc.id] ~= nil }
end

-- Posición en el mundo del empleado (para enfocar la cámara).
function Manager.position(employeeId: string): Vector3?
	local npc = Manager.npc(employeeId)
	return npc and Scene.roomToWorld(npc.room, npc.x, npc.y) or nil
end

-- Conexiones activas (para las pruebas: nunca más de una).
function Manager.connections(): number
	return st.conn and 1 or 0
end

return Manager
