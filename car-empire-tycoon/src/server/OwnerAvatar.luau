--!strict
--[[ Avatar autónomo del dueño: el avatar real del jugador (su apariencia de Roblox) camina solo por la
	oficina de su parcela. NO es el personaje del jugador (Players.CharacterAutoLoads sigue en false):
	no se controla con el teclado, no mueve la cámara de gestión y no toca la partida.

	- Apariencia: Players:GetHumanoidDescriptionFromUserId(UserId) → CreateHumanoidModelFromDescription (R15).
	  Si falla (sin conexión, usuario de prueba con UserId ≤ 0, etc.) usa un avatar genérico.
	- Puntos: los entrega Garage:avatarSpots(i). Si el edificio de la sede trae una carpeta «PuntosAvatar»
	  (partes = lugares por donde camina; un Seat = silla del escritorio; «FrenteEscritorio» = dónde se para
	  para trabajar) se usan esos; si no, los puntos provisionales de la oficina del garaje.
	- Conducta: camina entre puntos con Humanoid:MoveTo (en línea recta, sin pathfinding continuo), se detiene
	  unos segundos, va al escritorio, se sienta si hay silla (si no, trabaja de pie) y vuelve a caminar.
	- Rendimiento: un solo avatar por parcela, un solo hilo por avatar que comprueba la llegada 4 veces por
	  segundo mientras camina, sin conexiones a eventos; todo se limpia en destroy(). ]]

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
OwnerAvatar.MOVE_TIMEOUT = 10
OwnerAvatar.START_DELAY = { 1, 3 }

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
	task.spawn(function()
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
			if name == "walk" then
				track:AdjustSpeed(0.8)
			end
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
				t:AdjustSpeed(0.8)
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

-- Camina en línea recta hasta `pos`. Si en MOVE_TIMEOUT no llega (algo en el camino), aparece ahí.
function OwnerAvatar:walkTo(pos: Vector3): boolean
	if not self.alive then
		return false
	end
	self:play("walk")
	pcall(function()
		self.hum:MoveTo(pos)
	end)
	local t = 0
	while self.alive and t < OwnerAvatar.MOVE_TIMEOUT do
		task.wait(0.25)
		t += 0.25
		local p = self.root.CFrame.Position
		if Vector3.new(p.X - pos.X, 0, p.Z - pos.Z).Magnitude < 1.6 then
			break
		end
	end
	if not self.alive then
		return false
	end
	local p = self.root.CFrame.Position
	if Vector3.new(p.X - pos.X, 0, p.Z - pos.Z).Magnitude > 4 then
		self:place(pos)
	end
	self:play("idle")
	return true
end

function OwnerAvatar:face(target: Vector3)
	pcall(function()
		local p = self.root.CFrame.Position
		self.root.CFrame = CFrame.lookAt(p, Vector3.new(target.X, p.Y, target.Z))
	end)
end

-- Rato de trabajo: se sienta en la silla del escritorio si hay; si no, trabaja de pie frente al escritorio.
function OwnerAvatar:work()
	local s = self.spots
	local seat = s.seat
	if seat and seat.Parent and not seat.Occupant then
		local behind = (seat.CFrame * CFrame.new(0, 0, 3)).Position
		if not self:walkTo(Vector3.new(behind.X, s.points[1].Y, behind.Z)) then
			return
		end
		local sat = pcall(function()
			seat.Disabled = false
			seat:Sit(self.hum)
		end)
		task.wait(0.3)
		if sat and self.alive and self.hum.SeatPart == seat then
			self:play("sit")
			task.wait(rand(self.rng, OwnerAvatar.WORK))
			if not self.alive then
				return
			end
			pcall(function()
				self.hum.Sit = false
			end)
			task.wait(0.3)
			pcall(function()
				seat.Disabled = true
			end)
			self:place(Vector3.new(behind.X, s.points[1].Y, behind.Z), seat.CFrame.Position)
			self:play("idle")
			return
		end
		pcall(function()
			seat.Disabled = true
		end)
	end
	if s.desk then
		local d = s.desk.Position
		if self:walkTo(Vector3.new(d.X, s.points[1].Y, d.Z)) then
			self:face((s.desk * CFrame.new(0, 0, -3)).Position)
			task.wait(rand(self.rng, OwnerAvatar.WORK) * 0.6)
		end
	end
end

-- Rutina: caminar, pausar, a veces ir al escritorio. Termina sola cuando el avatar se destruye.
function OwnerAvatar:run()
	task.wait(rand(self.rng, OwnerAvatar.START_DELAY))
	while self.alive do
		local s = self.spots
		if (s.seat or s.desk) and self.rng:NextNumber() < OwnerAvatar.DESK_CHANCE then
			self:work()
		else
			local n = #s.points
			local i = self.rng:NextInteger(1, n)
			if n > 1 and i == self.last then
				i = i % n + 1
			end
			self.last = i
			self:walkTo(s.points[i])
		end
		if self.alive then
			task.wait(rand(self.rng, OwnerAvatar.PAUSE))
		end
	end
end

-- Cambian los puntos (el edificio u oficina mejoró): se levanta si estaba sentado y aparece en un punto válido.
function OwnerAvatar:setSpots(spots: Spots)
	local old = self.spots
	self.spots = spots
	if old.seat == spots.seat and #old.points == #spots.points and old.points[1] == spots.points[1] then
		return -- mismos lugares (por ejemplo, oficinas mejoradas sin edificio propio): sigue donde está
	end
	pcall(function()
		if self.hum.SeatPart then
			self.hum.Sit = false
		end
		if old.seat and old.seat ~= spots.seat then
			old.seat.Disabled = true
		end
	end)
	self.last = 0
	self:place(spots.points[1])
	self:play("idle")
end

function OwnerAvatar:destroy()
	if not self.alive then
		return
	end
	self.alive = false
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
	if self.rig then
		self.rig:Destroy()
	end
end

return OwnerAvatar
