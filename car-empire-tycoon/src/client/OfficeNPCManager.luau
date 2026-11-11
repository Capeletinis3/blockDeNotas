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

	Separado de la economía: solo lee App.g (copia sincronizada por el servidor). No envía solicitudes, no
	cambia la partida y no avanza g.time (la empresa sigue en pausa con setUiPause mientras el editor está
	abierto); su reloj es propio. ]]

local RunService = game:GetService("RunService")
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
		table.insert(parts, tostring(e.id) .. "=" .. tostring(e.name) .. "@" .. tostring(e.dept))
	end
	return table.concat(parts, ";")
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
		if not rig then
			rig = NPC.build(id, npc.name, npc.dept)
			rig.model.Parent = st.folder
			st.rigs[id] = rig
			changed = true
		elseif rig.name ~= npc.name or rig.dept ~= npc.dept then
			NPC.setInfo(rig, npc.name, npc.dept) -- sin rearmar el personaje
			changed = true
		end
	end
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
	Act.setEmployees(st.world, g.employees, true)
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
		Act.setEmployees(world, g.employees, false)
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

-- Cantidades reales: visibles ahora y contratados (g.employees).
function Manager.counts(g: any?): (number, number)
	local hired = g and g.employees and #g.employees or (st.world and st.world.hired) or 0
	local visible = (st.open and st.shown and st.world) and #st.world.order or 0
	return visible, hired
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
				local c = Scene.roomToWorld(npc.room, npc.x, npc.y)
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
	return { id = npc.id, name = npc.name, dept = d and d.name or tostring(npc.dept), room = room and room.name or npc.room, activity = activity, nav = nav, state = npc.state }
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
