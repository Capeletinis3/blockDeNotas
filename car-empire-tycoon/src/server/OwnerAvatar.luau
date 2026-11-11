--!strict
--[[ Avatar autónomo del dueño: el avatar real del jugador (su apariencia de Roblox) camina solo por la
	oficina de su parcela. NO es el personaje del jugador (Players.CharacterAutoLoads sigue en false):
	no se controla con el teclado, no mueve la cámara de gestión y no toca la partida.

	- Apariencia: Players:GetHumanoidDescriptionFromUserId(UserId) → CreateHumanoidModelFromDescription (R15).
	  Si falla (sin conexión, usuario de prueba con UserId ≤ 0, etc.) usa un avatar genérico.
	- Puntos: los entrega Garage:avatarSpots(i). Si el edificio de la sede trae una carpeta «PuntosAvatar»
	  (partes = lugares por donde camina; un Seat = silla del escritorio; «FrenteEscritorio» = dónde se para
	  para trabajar) se usan esos; si no, los puntos provisionales de la oficina del garaje.
	- Movimiento: una ruta por trayecto con PathfindingService (rodea escritorio, silla y muebles); la ruta se
	  calcula una sola vez al elegir el destino, nunca en bucle. Cada tramo usa Humanoid:MoveTo.
	- Recuperación: si no avanza durante STUCK_TIME o el destino es inaccesible, se detiene donde está, queda
	  quieto un momento y elige otro destino (sin teletransportarse). Solo si falla varias veces seguidas
	  vuelve caminando al último punto que alcanzó; aparecer en un punto válido es el último recurso.
	- Conducta: camina, hace pausas (a veces mira alrededor), va al escritorio, se sienta un rato si hay silla
	  (si no, trabaja de pie), se levanta y sigue. Nunca repite el mismo destino dos veces seguidas.
	- Rendimiento: un solo avatar por parcela y un solo hilo por avatar (cancelado en destroy()), que mira la
	  llegada 4 veces por segundo mientras camina; sin conexiones a eventos. ]]

local Players = game:GetService("Players")

local OwnerAvatar = {}
OwnerAvatar.__index = OwnerAvatar

OwnerAvatar.WALK_SPEED = 8
OwnerAvatar.NAME = "AvatarDueno"
-- Animaciones R15 predeterminadas de Roblox (públicas).
OwnerAvatar.ANIM = {
	idle = "rbxassetid://507766388",
	walk = "rbxassetid://507777826",
	sit = "rbxassetid://2506281703",
}
-- Tiempos (segundos reales): pausas al caminar y rato de trabajo en el escritorio.
OwnerAvatar.PAUSE = { 2, 5 }
OwnerAvatar.WORK = { 8, 16 }
OwnerAvatar.DESK_CHANCE = 0.4
OwnerAvatar.LOOK_CHANCE = 0.2 -- pausa mirando alrededor en lugar de caminar
OwnerAvatar.MOVE_TIMEOUT = 10 -- máximo por tramo de ruta
OwnerAvatar.STUCK_TIME = 1.5 -- segundos sin avanzar = bloqueado
OwnerAvatar.ARRIVE = 1.6 -- distancia (studs, en el plano) para dar por alcanzado un punto
OwnerAvatar.MAX_FAILS = 3 -- fallos seguidos antes de volver al último punto alcanzado
OwnerAvatar.START_DELAY = { 1, 3 }
-- Agente de la ruta: algo más ancho que un avatar R15 para no rozar muebles; no salta ni trepa.
OwnerAvatar.PATH = { AgentRadius = 1.2, AgentHeight = 5.5, AgentCanJump = false, AgentCanClimb = false, WaypointSpacing = 4 }

type Spots = { points: { Vector3 }, seat: Seat?, desk: CFrame?, source: string }

-- Lee los puntos de un edificio: carpeta «PuntosAvatar» (en cualquier nivel del modelo). Devuelve nil si no hay.
function OwnerAvatar.spotsFrom(model: Instance?): Spots?
	if not model then
		return nil
	end
	local folder = model:FindFirstChild("PuntosAvatar", true)
	if not folder then
		return nil
	end
	local points: { Vector3 } = {}
	local seat: Seat? = nil
	local desk: CFrame? = nil
	for _, d in folder:GetDescendants() do
		if d:IsA("Seat") then
			seat = d
		elseif d:IsA("BasePart") then
			-- Marcadores invisibles: no estorban ni se pueden clicar.
			d.Transparency = 1
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			if d.Name == "FrenteEscritorio" then
				desk = d.CFrame
			else
				table.insert(points, d.CFrame.Position)
			end
		end
	end
	if #points == 0 then
		return nil
	end
	return { points = points, seat = seat, desk = desk, source = "edificio" }
end

-- Modelo del avatar (se puede reemplazar en pruebas). Nunca usa Player.Character.
function OwnerAvatar.makeRig(userId: number): Model?
	local rig: any = nil
	if userId > 0 then
		local ok, desc = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(userId)
		end)
		if ok and desc then
			local ok2, m = pcall(function()
				return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
			end)
			if ok2 then
				rig = m
			end
		end
	end
	if not rig then
		local ok, m = pcall(function()
			return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
		end)
		if ok then
			rig = m
		end
	end
	return rig
end

local function rand(r: Random, range: { number }): number
	return range[1] + r:NextNumber() * (range[2] - range[1])
end

-- Crea el avatar de `owner` dentro de `parent` y empieza su rutina. Devuelve nil si no se pudo armar.
function OwnerAvatar.new(owner: Player, parent: Instance, spots: Spots): any
	local self = setmetatable({}, OwnerAvatar)
	self.owner = owner
	self.alive = true
	self.spots = spots
	self.rng = Random.new()
	self.tracks = {}
	self.current = nil :: string?
	self.last = 0
	self.epoch = 0 -- cambia cuando cambian los puntos: corta el trayecto en curso
	self.fails = 0 -- trayectos fallidos seguidos
	self.recovered = 0 -- veces que tuvo que aparecer en un punto (último recurso)
	self.lastGood = nil :: Vector3?
	self.seated = nil :: Seat?
	local rig = OwnerAvatar.makeRig(owner.UserId) -- puede demorar (pide la apariencia a Roblox)
	if not rig then
		return nil
	end
	if not parent.Parent then
		-- La parcela se reconstruyó o se liberó mientras se armaba el avatar.
		rig:Destroy()
		return nil
	end
	rig.Name = OwnerAvatar.NAME
	rig:SetAttribute("OwnerId", owner.UserId)
	-- Sin scripts del rig: las animaciones las maneja este módulo desde el servidor.
	for _, d in rig:GetDescendants() do
		if d:IsA("BaseScript") or d:IsA("LocalScript") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.CanTouch = false -- no activa sillas ni partes al pasar
		end
	end
	local hum = rig:FindFirstChildOfClass("Humanoid") :: any
	local root = rig:FindFirstChild("HumanoidRootPart") :: any
	if not hum or not root then
		rig:Destroy()
		return nil
	end
	self.rig, self.hum, self.root = rig, hum, root
	pcall(function()
		hum.WalkSpeed = OwnerAvatar.WALK_SPEED
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.BreakJointsOnDeath = false
		hum.RequiresNeck = false
		hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	end)
	rig.Parent = parent
	self:place(spots.points[1])
	pcall(function()
		root:SetNetworkOwner(nil) -- lo simula el servidor: ningún jugador lo controla
	end)
	self:loadAnimations()
	self:play("idle")
	self.thread = task.spawn(function()
		self:run()
	end)
	return self
end

function OwnerAvatar:loadAnimations()
	local animator = self.hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = self.hum
	end
	for name, id in OwnerAvatar.ANIM do
		pcall(function()
			local a = Instance.new("Animation")
			a.AnimationId = id
			local track = animator:LoadAnimation(a)
			track.Looped = true
			self.tracks[name] = track
		end)
	end
end

function OwnerAvatar:play(name: string)
	if self.current == name then
		return
	end
	for k, t in self.tracks do
		if k ~= name then
			pcall(function()
				t:Stop(0.25)
			end)
		end
	end
	local t = self.tracks[name]
	if t then
		pcall(function()
			t:Play(0.25)
			if name == "walk" then
				t:AdjustSpeed(OwnerAvatar.WALK_SPEED / 10) -- paso acorde a la velocidad (sin patinar)
			end
		end)
	end
	self.current = name
end

-- Ubica el avatar parado sobre un punto del piso.
function OwnerAvatar:place(pos: Vector3, look: Vector3?)
	local h = 3
	pcall(function()
		h = self.hum.HipHeight + self.root.Size.Y / 2
	end)
	local at = pos + Vector3.new(0, h + 0.05, 0)
	local target = look and Vector3.new(look.X, at.Y, look.Z) or (at + Vector3.new(0, 0, -1))
	if (target - at).Magnitude < 0.01 then
		target = at + Vector3.new(0, 0, -1)
	end
	self.rig:PivotTo(CFrame.lookAt(at, target))
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

--[[ Ruta de `from` a `to`: lista de puntos (sin el inicio, con el destino) o nil si no hay camino.
	Usa PathfindingService con un objeto Path por avatar (se reutiliza). Sin el servicio (entorno de pruebas)
	devuelve el tramo recto. Reemplazable en pruebas. ]]
function OwnerAvatar.findPath(av: any, from: Vector3, to: Vector3): { Vector3 }?
	local okSvc, svc = pcall(function()
		return game:GetService("PathfindingService")
	end)
	if not okSvc or not svc then
		return { to }
	end
	if not av.path then
		local okP, path = pcall(function()
			return (svc :: any):CreatePath(OwnerAvatar.PATH)
		end)
		if not okP or not path then
			return { to }
		end
		av.path = path
	end
	local path = av.path
	local ok = pcall(function()
		path:ComputeAsync(from, to)
	end)
	if not ok or path.Status ~= Enum.PathStatus.Success then
		return nil
	end
	local out: { Vector3 } = {}
	for i, w in path:GetWaypoints() do
		if i > 1 then
			table.insert(out, w.Position)
		end
	end
	if #out == 0 then
		table.insert(out, to)
	end
	return out
end

function OwnerAvatar:pos(): Vector3
	return self.root.CFrame.Position
end

-- Se detiene donde está (sin moverlo de lugar).
function OwnerAvatar:halt()
	pcall(function()
		self.hum:MoveTo(self:pos())
	end)
end

-- Un tramo: MoveTo y espera la llegada. Falla si deja de avanzar (algo en el camino), si se acaba el tiempo o
-- si cambió la oficina mientras caminaba (epoch).
function OwnerAvatar:stepTo(wp: Vector3, epoch: number): boolean
	pcall(function()
		self.hum:MoveTo(wp)
	end)
	local last = self:pos()
	local still, t = 0, 0
	while self.alive and self.epoch == epoch do
		task.wait(0.25)
		t += 0.25
		local p = self:pos()
		if flat(p, wp) < OwnerAvatar.ARRIVE then
			return true
		end
		if flat(p, last) < 0.3 then
			still += 0.25
		else
			still = 0
		end
		last = p
		if still >= OwnerAvatar.STUCK_TIME or t >= OwnerAvatar.MOVE_TIMEOUT then
			return false
		end
	end
	return false
end

--[[ Camina hasta `target` por una ruta que rodea los obstáculos. Si no hay ruta o se traba, se detiene donde
	está (sin teletransportarse) y devuelve false: la rutina elige otro destino. ]]
function OwnerAvatar:walkTo(target: Vector3): boolean
	if not self.alive then
		return false
	end
	local epoch = self.epoch
	if flat(self:pos(), target) < OwnerAvatar.ARRIVE then
		return true
	end
	local route = OwnerAvatar.findPath(self, self:pos(), target)
	if not self.alive or self.epoch ~= epoch then
		return false
	end
	if not route then
		self.fails += 1
		return false
	end
	self:play("walk")
	for _, wp in route do
		if not self:stepTo(wp, epoch) then
			if self.alive then
				self:halt()
				self:play("idle")
			end
			self.fails += 1
			return false
		end
	end
	self:play("idle")
	self.fails = 0
	self.lastGood = target
	return true
end

-- Gira de a poco hacia `target` (≈ 0,3 s), sin saltos de orientación.
function OwnerAvatar:face(target: Vector3)
	local ok, from = pcall(function()
		return self.root.CFrame
	end)
	if not ok then
		return
	end
	local p = from.Position
	local goal = CFrame.lookAt(p, Vector3.new(target.X, p.Y, target.Z))
	for i = 1, 5 do
		if not self.alive then
			return
		end
		pcall(function()
			self.root.CFrame = from:Lerp(goal, i / 5)
		end)
		task.wait(0.06)
	end
end

-- Lugar junto a la silla desde donde se sienta (un costado libre; si no, detrás).
function OwnerAvatar:seatApproach(seat: Seat): Vector3?
	local y = self.spots.points[1].Y
	for _, off in { CFrame.new(2.6, 0, 0), CFrame.new(-2.6, 0, 0), CFrame.new(0, 0, 3) } do
		local p = (seat.CFrame * off).Position
		local at = Vector3.new(p.X, y, p.Z)
		if OwnerAvatar.findPath(self, self:pos(), at) then
			return at
		end
	end
	return nil
end

-- Se levanta de la silla: suelta la soldadura del asiento y se aparta caminando.
function OwnerAvatar:standUp(seat: Seat?, stepTo: Vector3?)
	pcall(function()
		self.hum.Sit = false
		local weld = seat and seat:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
	end)
	task.wait(0.3)
	pcall(function()
		if seat then
			seat.Disabled = true
		end
	end)
	if stepTo and self.alive then
		self:play("walk")
		self:stepTo(stepTo, self.epoch)
		self:halt()
	end
	self:play("idle")
end

-- Rato de trabajo: se sienta en la silla del escritorio si hay; si no, trabaja de pie frente al escritorio.
function OwnerAvatar:work()
	local s = self.spots
	local seat = s.seat
	if seat and seat.Parent and not seat.Occupant then
		local approach = self:seatApproach(seat)
		if approach and self:walkTo(approach) then
			self:face(seat.CFrame.Position)
			local sat = pcall(function()
				seat.Disabled = false
				seat:Sit(self.hum)
			end)
			task.wait(0.3)
			if sat and self.alive and self.hum.SeatPart == seat then
				self:play("sit")
				self.seated = seat
				task.wait(rand(self.rng, OwnerAvatar.WORK))
				local still = self.seated == seat -- si cambió la oficina, setSpots ya lo levantó
				self.seated = nil
				if self.alive and still then
					self:standUp(seat, approach)
				end
				return
			end
			pcall(function()
				seat.Disabled = true
			end)
		end
	end
	if s.desk then
		local d = s.desk.Position
		if self:walkTo(Vector3.new(d.X, s.points[1].Y, d.Z)) then
			self:face((s.desk * CFrame.new(0, 0, -3)).Position)
			task.wait(rand(self.rng, OwnerAvatar.WORK) * 0.6)
		end
	end
end

-- Elige un punto distinto del último y de uno que acaba de fallar.
function OwnerAvatar:pickPoint(avoid: number?): number
	local n = #self.spots.points
	if n <= 1 then
		return 1
	end
	local i = self.rng:NextInteger(1, n)
	for _ = 1, n do
		if i ~= self.last and i ~= avoid then
			break
		end
		i = i % n + 1
	end
	return i
end

-- Recuperación tras varios fallos seguidos: vuelve caminando al último punto alcanzado; si tampoco puede
-- (quedó encerrado, por ejemplo tras un cambio de edificio), aparece en un punto válido como último recurso.
function OwnerAvatar:recover()
	local back = self.lastGood or self.spots.points[1]
	self.fails = 0
	if not self:walkTo(back) and self.alive then
		self.fails = 0
		self:place(self.spots.points[1])
		self.recovered += 1
	end
end

-- Rutina: caminar, pausar, mirar alrededor o ir al escritorio. Termina cuando el avatar se destruye.
function OwnerAvatar:run()
	task.wait(rand(self.rng, OwnerAvatar.START_DELAY))
	local failed: number? = nil
	while self.alive do
		local s = self.spots
		local roll = self.rng:NextNumber()
		if (s.seat or s.desk) and roll < OwnerAvatar.DESK_CHANCE and not failed then
			self:work()
		elseif roll < OwnerAvatar.DESK_CHANCE + OwnerAvatar.LOOK_CHANCE and not failed then
			local p = s.points[self:pickPoint()]
			self:face(p)
		else
			local i = self:pickPoint(failed)
			self.last = i
			failed = (not self:walkTo(s.points[i])) and i or nil
		end
		if self.alive and self.fails >= OwnerAvatar.MAX_FAILS then
			self:recover()
			failed = nil
		end
		if self.alive then
			task.wait(rand(self.rng, OwnerAvatar.PAUSE))
		end
	end
end

-- Cambian los puntos (el edificio u oficina mejoró): se levanta si estaba sentado, corta el trayecto en curso
-- y sigue su rutina con los puntos nuevos. Solo aparece en un punto nuevo si desde donde está no hay ruta.
function OwnerAvatar:setSpots(spots: Spots)
	local old = self.spots
	self.spots = spots
	if old.seat == spots.seat and #old.points == #spots.points and old.points[1] == spots.points[1] then
		return -- mismos lugares (por ejemplo, oficinas mejoradas sin edificio propio): sigue donde está
	end
	self.epoch += 1
	self.last, self.fails, self.lastGood = 0, 0, nil
	pcall(function()
		if old.seat and old.seat ~= spots.seat then
			old.seat.Disabled = true
		end
	end)
	-- Calcular la ruta puede demorar: no se hace dentro del paso de la simulación.
	local seated = self.seated
	self.seated = nil
	task.spawn(function()
		if seated or (self.hum and self.hum.SeatPart) then
			self:standUp(seated)
		end
		if self.alive and not OwnerAvatar.findPath(self, self:pos(), spots.points[1]) then
			self:place(spots.points[1])
			self.recovered += 1
		end
	end)
end

function OwnerAvatar:destroy()
	if not self.alive then
		return
	end
	self.alive = false
	if self.thread and coroutine.running() ~= self.thread then
		pcall(task.cancel, self.thread)
	end
	self.thread = nil
	pcall(function()
		if self.spots.seat then
			self.spots.seat.Disabled = true
		end
	end)
	for _, t in self.tracks do
		pcall(function()
			t:Stop(0)
		end)
	end
	self.tracks = {}
	if self.path then
		pcall(function()
			self.path:Destroy()
		end)
		self.path = nil
	end
	if self.rig then
		self.rig:Destroy()
	end
end

return OwnerAvatar
