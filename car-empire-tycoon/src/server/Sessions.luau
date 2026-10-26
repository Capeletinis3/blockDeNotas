--!strict
--[[
	Sesiones de jugadores: carga, empresa activa, solicitudes, simulación, guardado y candado.
	No usa servicios de Roblox directamente: Main.server inyecta las dependencias (y las pruebas, sus dobles).

	deps = {
	  data      = DataService,
	  filter    = (texto, userId) -> (texto | nil, error | nil)   -- filtro de texto de Roblox
	  push      = (player, payload) -> ()                          -- envía el estado al cliente
	  notice    = (player, kind, texto) -> ()                      -- aviso puntual
	  garage    = { assign, release, teleport, update } | nil
	  newRng    = () -> (() -> número)
	  now       = () -> segundos UNIX         clock = () -> segundos monótonos
	  wait      = (s) -> ()                   spawn = (fn, ...) -> ()
	  log       = (texto) -> ()               debug = boolean (muestra datos de diagnóstico en el registro)
	  saveMode  = "datastore" | "memory"
	}

	Estados de una sesión: "loading" → "ready" (o "failed") ; "lost" si otro servidor tomó la partida.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)

local GameState = require(script.Parent.GameState)
local Simulation = require(script.Parent.Simulation)
local Actions = require(script.Parent.Actions)
local DataService = require(script.Parent.DataService)
local Demo = require(script.Parent.Demo)

local Sessions = {}
Sessions.__index = Sessions

Sessions.AUTOSAVE_SECONDS = 45
Sessions.MIN_SAVE_GAP = 7 -- límite de escritura por clave del DataStore
Sessions.RATE_WINDOW = 2
Sessions.RATE_MAX = 14
Sessions.PROCESSED_KEPT = 60

-- Opciones de Configuración (las de la V3). camSpeed va de 0,4 a 2 en pasos de 0,1.
local CAM_SPEEDS = {}
for i = 4, 20 do
	table.insert(CAM_SPEEDS, i / 10)
end
local SETTINGS_ALLOWED: { [string]: { any } } = {
	sound = { true, false },
	reduceMotion = { true, false },
	keyHints = { true, false },
	tips = { true, false },
	shadows = { true, false },
	textScale = { 1, 1.12, 1.25 },
	camSpeed = CAM_SPEEDS,
}
Sessions.SETTINGS_ALLOWED = SETTINGS_ALLOWED

function Sessions.new(deps: any)
	local self = setmetatable({}, Sessions)
	self.deps = deps
	self.list = {} -- player → sesión
	self.finalPending = 0
	self.closing = false
	Sessions.instance = self -- lo usan las escenas de la vista previa para preparar estados
	return self
end

local function utcDate(t: number): string
	return os.date("!%Y-%m-%d", t) :: string
end

-- Estado que se envía al cliente -----------------------------------------------------------
function Sessions:payload(s: any): any
	local slots = {}
	if s.profile then
		for _, key in GameState.slotKeys() do
			local g = s.profile.slots[key]
			if s.damaged[key] then
				slots[key] = { damaged = true, reason = s.damaged[key] }
			elseif g then
				slots[key] = GameState.summary(g)
			end
		end
	end
	return {
		status = s.status,
		saveMode = self.deps.saveMode,
		saveWarning = s.saveWarning,
		blocked = s.blocked,
		loadError = s.loadError,
		loadCode = s.loadCode,
		lastSaved = s.lastSavedAt,
		today = utcDate(self.deps.now()),
		yesterday = utcDate(self.deps.now() - 86400),
		dirty = s.dirty,
		profile = s.profile and { slots = slots, active = s.activeKey, last = s.profile.active, settings = s.profile.settings } or nil,
		demo = s.demo,
		game = s.game and GameState.view(s.game) or nil,
	}
end

function Sessions:push(s: any)
	if s.leaving then
		return
	end
	s.sentKey = s.game and GameState.structKey(s.game) or nil
	s.fullAt = self.deps.clock()
	self.deps.push(s.player, self:payload(s))
end

--[[ Envío del segundo a segundo: si la estructura de la partida no cambió (mismos lotes y estados, mismo
	mes, mismas notificaciones…) se manda solo lo que cambia (GameState.live, ~2 KB) en lugar de la partida
	completa. Cada 30 s se manda igual la partida completa como resguardo. ]]
function Sessions:pushTick(s: any)
	if s.leaving then
		return
	end
	local g = s.game
	if not g or s.sentKey ~= GameState.structKey(g) or self.deps.clock() - (s.fullAt or 0) >= 30 then
		self:push(s)
		return
	end
	self.deps.push(s.player, { tick = true, live = GameState.live(g) })
end

-- Guardado -------------------------------------------------------------------------------------
function Sessions:save(s: any, release: boolean?)
	local data = self.deps.data
	if not s.canSave or not s.profile then
		if release and s.ownsLock then
			data:release(s.player.UserId)
			s.ownsLock = false
		end
		return
	end
	while s.saving do
		if not release then
			s.pendingSave = true
			return
		end
		self.deps.wait(0.2)
	end
	s.saving = true
	s.pendingSave = false
	local wasDirty = s.dirty
	s.dirty = false
	if s.game then
		s.game.lastPlayed = self.deps.now()
	end
	local ok, msg, code = data:save(s.player.UserId, s.profile, s.damaged, { release = release })
	s.saving = false
	s.lastSave = self.deps.clock()
	if ok then
		s.lastSavedAt = self.deps.now()
		s.lockConfirmed = self.deps.now()
		if s.status == "ready" then
			s.blocked = nil
		end
		if release then
			s.ownsLock = false
		end
		if s.saveWarning then
			s.saveWarning = nil
		end
		self:push(s)
	else
		s.dirty = s.dirty or wasDirty
		s.saveWarning = msg
		if code == "lost_lock" then
			self:lose(s)
		elseif code == "invalid" then
			s.canSave = false
		end
		self:push(s)
	end
end

-- Otro servidor tiene la partida: se detienen la simulación, las acciones y el guardado.
function Sessions:lose(s: any)
	s.status = "lost"
	s.canSave = false
	s.ownsLock = false
	s.blocked = "Tu partida se abrió en otro servidor. Esta sesión dejó de guardar y de aceptar acciones para no pisar datos. Salí del juego y volvé a entrar."
	self:push(s)
end

function Sessions:renew(s: any)
	if s.renewing or not s.canSave or s.status ~= "ready" then
		return
	end
	s.renewing = true
	local ok, code = self.deps.data:renew(s.player.UserId)
	s.renewing = false
	s.lastRenew = self.deps.clock()
	if ok then
		s.lockConfirmed = self.deps.now()
		if s.blocked and s.status == "ready" then
			s.blocked = nil
			self:push(s)
		end
	elseif code == "lost_lock" then
		self:lose(s)
	else
		-- Sin confirmar el candado por casi todo su plazo, no se puede asegurar que el guardado sea nuestro.
		if self.deps.now() - (s.lockConfirmed or 0) > DataService.LOCK_TIMEOUT - 90 then
			s.blocked = "No se puede confirmar el guardado con Roblox. Las acciones quedan en espera hasta que el servicio responda."
			self:push(s)
		end
	end
end

-- Carga -----------------------------------------------------------------------------------------
function Sessions:load(s: any)
	if s.loading then
		return
	end
	s.loading = true
	s.status = "loading"
	s.loadError = nil
	s.loadCode = nil
	self:push(s)
	local ok, profile, damaged, err, code = self.deps.data:load(s.player.UserId)
	s.loading = false
	if self.list[s.player] ~= s or s.leaving then
		-- El jugador salió durante la carga: liberar el candado sin escribir la partida.
		if ok then
			self.deps.data:release(s.player.UserId)
		end
		return
	end
	if ok then
		s.profile = profile
		s.damaged = damaged or {}
		s.status = "ready"
		s.canSave = true
		s.ownsLock = true
		s.lockConfirmed = self.deps.now()
		s.lastRenew = self.deps.clock()
		s.blocked = nil
		for _, id in profile.processed do
			s.processed[id] = { ok = false, msg = "Esa operación ya se procesó.", duplicate = true }
		end
		-- Como en la V3, siempre se empieza en el menú de empresas; profile.active queda como «última jugada».
	else
		s.status = "failed"
		s.canSave = false
		s.loadError = err
		s.loadCode = code
	end
	self:push(s)
end

function Sessions:activate(s: any, key: string, demoGame: any?)
	s.activeKey = key
	if demoGame then
		-- Las demostraciones viven solo en memoria: no se registran como empresa activa ni se guardan.
		s.game = demoGame
	else
		s.profile.active = key
		s.game = s.profile.slots[key]
	end
	if #s.game.candidates == 0 then
		s.game.candidates = Simulation.makeCandidates(s.game, s.ctx, 5)
	end
	local garage = self.deps.garage
	if garage then
		local plot = garage.assign(s.player, s.game)
		s.hasPlot = plot ~= nil
		if plot then
			garage.teleport(s.player)
			garage.update(s.player, s.game)
		else
			self.deps.notice(s.player, "aviso", "No hay garajes libres en este servidor. Podés jugar con los paneles; tu garaje aparece cuando se libere uno.")
		end
	end
end

function Sessions:deactivate(s: any)
	s.game = nil
	s.activeKey = nil
	s.demo = nil
	if self.deps.garage and s.hasPlot then
		self.deps.garage.release(s.player)
		s.hasPlot = false
		self:assignWaiting()
	end
end

-- Si se liberó una parcela, se la da a quien juega sin garaje.
function Sessions:assignWaiting()
	local garage = self.deps.garage
	if not garage then
		return
	end
	for _, s in self.list do
		if s.game and not s.hasPlot and not s.leaving then
			local plot = garage.assign(s.player, s.game)
			if plot then
				s.hasPlot = true
				garage.teleport(s.player)
				garage.update(s.player, s.game)
				self.deps.notice(s.player, "ok", "Se liberó un garaje: ya tenés el tuyo.")
			end
		end
	end
end

-- Jugadores ----------------------------------------------------------------------------------------
function Sessions:add(player: any)
	local rng = self.deps.newRng()
	local s
	s = {
		player = player, status = "loading", profile = nil, damaged = {}, game = nil, activeKey = nil,
		canSave = false, ownsLock = false, dirty = false, saving = false, pendingSave = false, loading = false,
		lastSave = 0, lastAutosave = self.deps.clock(), lastRenew = self.deps.clock(), lockConfirmed = 0,
		saveWarning = nil, blocked = nil, busy = false, requests = {}, processed = {}, leaving = false, hasPlot = false,
	}
	s.ctx = {
		rng = rng,
		notify = function(kind: string, text: string)
			if not s.leaving then
				self.deps.notice(player, kind, text)
			end
		end,
	}
	self.list[player] = s
	self.deps.spawn(function()
		self:load(s)
	end)
	return s
end

function Sessions:remove(player: any)
	local s = self.list[player]
	if not s or s.leaving then
		return
	end
	s.leaving = true
	if self.deps.garage and s.hasPlot then
		self.deps.garage.release(player)
		s.hasPlot = false
	end
	self.finalPending += 1
	self:save(s, true)
	self.finalPending -= 1
	if self.list[player] == s then
		self.list[player] = nil
	end
	self:assignWaiting()
end

-- Cierre del servidor: guarda todo lo pendiente y espera las salidas en curso.
function Sessions:closeAll(timeout: number)
	self.closing = true
	local pending = 0
	for player, s in self.list do
		if not s.leaving then
			pending += 1
			self.deps.spawn(function()
				self:remove(player)
				pending -= 1
			end)
		end
	end
	local t = self.deps.clock()
	while (pending > 0 or self.finalPending > 0) and self.deps.clock() - t < timeout do
		self.deps.wait(0.2)
	end
end

-- Solicitudes --------------------------------------------------------------------------------------
local function rateLimited(self: any, s: any): boolean
	local now = self.deps.clock()
	local keep = {}
	for _, t in s.requests do
		if now - t < Sessions.RATE_WINDOW then
			table.insert(keep, t)
		end
	end
	s.requests = keep
	if #keep >= Sessions.RATE_MAX then
		return true
	end
	table.insert(s.requests, now)
	return false
end

function Sessions:createCompany(s: any, payload: any): any
	local key = type(payload) == "table" and payload.slot or nil
	if type(key) ~= "string" or not Util.contains(GameState.slotKeys(), key) then
		return { ok = false, msg = "Ranura inválida." }
	end
	if s.profile.slots[key] ~= nil then
		return { ok = false, msg = "Esa ranura ya está ocupada." }
	end
	local clean, err = Actions.validateCompany(payload)
	if not clean then
		return { ok = false, msg = err }
	end
	for k, g in s.profile.slots do
		if not s.damaged[k] and string.lower(g.company.name) == string.lower(clean.name) then
			return { ok = false, msg = "Ya tenés una empresa con ese nombre." }
		end
	end
	local name, ferr = self.deps.filter(clean.name, s.player.UserId)
	if not name then
		return { ok = false, msg = ferr }
	end
	if self.list[s.player] ~= s or s.leaving or s.status ~= "ready" or s.profile.slots[key] ~= nil then
		return { ok = false, msg = "La sesión cambió; volvé a intentar." }
	end
	if s.game then
		self:deactivate(s)
	end
	local g = GameState.newGame({ name = name, color = clean.color, logo = clean.logo, difficulty = clean.difficulty, now = self.deps.now() })
	s.profile.slots[key] = g
	Simulation.notify(g, nil, "ok", "¡" .. name .. " fue fundada!", "juego")
	self:activate(s, key)
	return { ok = true, msg = "¡" .. name .. " fue fundada! Tu garaje te espera." }
end

function Sessions:menuAction(s: any, action: string, payload: any): any?
	local key = type(payload) == "table" and payload.slot or nil
	if action == "createCompany" then
		return self:createCompany(s, payload)
	elseif action == "selectSlot" then
		if type(key) ~= "string" or not s.profile.slots[key] then
			return { ok = false, msg = "Esa ranura está vacía." }
		end
		if s.damaged[key] then
			return { ok = false, msg = "Esa empresa tiene datos dañados y no se puede abrir. No se modificaron." }
		end
		if s.activeKey ~= key then
			if s.game then
				self:deactivate(s)
			end
			self:activate(s, key)
		end
		return { ok = true, quiet = true }
	elseif action == "playDemo" then
		local kind = type(payload) == "table" and payload.kind or nil
		if type(kind) ~= "string" or not Demo.KINDS[kind] then
			return { ok = false, msg = "Demostración desconocida." }
		end
		if s.game then
			self:deactivate(s)
		end
		local g = Demo.make(kind, s.ctx, self.deps.now())
		s.demo = kind
		self:activate(s, "demo", g)
		return { ok = true, msg = "Demostración: los cambios no se guardan y no afectan tus empresas." }
	elseif action == "leaveCompany" then
		if s.game then
			self:deactivate(s)
		end
		return { ok = true, quiet = true }
	elseif action == "renameCompany" then
		local g = type(key) == "string" and s.profile.slots[key] or nil
		if not g or s.damaged[key] then
			return { ok = false, msg = "Esa ranura no tiene una empresa válida." }
		end
		local name, err = Actions.validateName(payload.name, 3)
		if not name then
			return { ok = false, msg = err }
		end
		for k, other in s.profile.slots do
			if k ~= key and not s.damaged[k] and string.lower(other.company.name) == string.lower(name) then
				return { ok = false, msg = "Ya existe otra empresa con ese nombre." }
			end
		end
		local filtered, ferr = self.deps.filter(name, s.player.UserId)
		if not filtered then
			return { ok = false, msg = ferr }
		end
		if s.profile.slots[key] ~= g then
			return { ok = false, msg = "La sesión cambió; volvé a intentar." }
		end
		g.company.name = filtered
		if s.game == g and self.deps.garage and s.hasPlot then
			self.deps.garage.update(s.player, g, true)
		end
		return { ok = true, msg = "Empresa renombrada: " .. filtered }
	elseif action == "deleteCompany" then
		if type(key) ~= "string" or s.profile.slots[key] == nil then
			return { ok = false, msg = "Esa ranura ya está vacía." }
		end
		local g = s.profile.slots[key]
		local expected = s.damaged[key] and "BORRAR" or g.company.name
		if type(payload.confirm) ~= "string" or Util.trim(payload.confirm) ~= expected then
			return { ok = false, msg = "Para confirmar, escribí exactamente «" .. expected .. "»." }
		end
		if s.activeKey == key then
			self:deactivate(s)
		end
		s.profile.slots[key] = nil
		s.damaged[key] = nil
		return { ok = true, msg = "Ranura " .. key .. " eliminada. Las otras empresas no se tocaron." }
	elseif action == "setSetting" then
		local k, v = payload and payload.key, payload and payload.value
		local allowed = type(k) == "string" and SETTINGS_ALLOWED[k] or nil
		if not allowed or not Util.contains(allowed, v) then
			return { ok = false, msg = "Opción inválida." }
		end
		s.profile.settings[k] = v
		return { ok = true, quiet = true }
	elseif action == "wipeAll" then
		-- «Borrar todos los datos» de la V3: elimina todas las ranuras de la cuenta (no la configuración del juego).
		if type(payload) ~= "table" or payload.confirm ~= "BORRAR" then
			return { ok = false, msg = "Confirmación inválida." }
		end
		if s.game then
			self:deactivate(s)
		end
		for _, key in GameState.slotKeys() do
			s.profile.slots[key] = nil
			s.damaged[key] = nil
		end
		s.profile.active = nil
		return { ok = true, msg = "Datos borrados." }
	end
	return nil
end

function Sessions:request(player: any, action: any, payload: any): any
	local s = self.list[player]
	if not s or type(action) ~= "string" then
		return { ok = false, msg = "Sesión no disponible." }
	end
	if rateLimited(self, s) then
		return { ok = false, msg = "Demasiadas acciones seguidas. Esperá un momento." }
	end
	if action == "sync" then
		self:push(s)
		return { ok = true, quiet = true }
	end
	if action == "retryLoad" then
		if s.status == "failed" and not s.loading then
			self.deps.spawn(function()
				self:load(s)
			end)
			return { ok = true, msg = "Reintentando la carga…" }
		end
		return { ok = false, msg = s.loading and "La carga ya está en curso." or "La partida ya está cargada." }
	end
	if s.status == "lost" then
		return { ok = false, msg = s.blocked }
	end
	if s.status ~= "ready" then
		return { ok = false, msg = "Tu partida todavía no está cargada." }
	end
	if s.blocked then
		return { ok = false, msg = s.blocked }
	end
	if s.leaving or self.closing then
		return { ok = false, msg = "El servidor se está cerrando; tu partida se está guardando." }
	end

	-- Identificador de solicitud: un reenvío de la misma operación devuelve el resultado anterior.
	local requestId = type(payload) == "table" and payload.requestId or nil
	if Actions.economic[action] then
		if type(requestId) ~= "string" or #requestId < 8 or #requestId > 64 then
			return { ok = false, msg = "Solicitud sin identificador." }
		end
		local prev = s.processed[requestId]
		if prev then
			local copy = table.clone(prev)
			copy.duplicate = true
			return copy
		end
	end

	if s.busy then
		return { ok = false, msg = "Esperá a que termine la acción anterior." }
	end
	s.busy = true
	local ok, result = pcall(function(): any
		local menu = self:menuAction(s, action, payload)
		if menu then
			return menu
		end
		local g = s.game
		if not g then
			return { ok = false, msg = "Primero elegí o creá una empresa." }
		end
		if action == "saveDesign" then
			local draft = type(payload) == "table" and payload.draft or nil
			if type(draft) ~= "table" or type(draft.name) ~= "string" then
				return { ok = false, msg = "El diseño no es válido." }
			end
			local name, nerr = Actions.validateName(draft.name, 2)
			if not name then
				return { ok = false, msg = nerr }
			end
			local filtered, ferr = self.deps.filter(name, s.player.UserId)
			if not filtered then
				return { ok = false, msg = ferr }
			end
			if self.list[player] ~= s or s.game ~= g then
				return { ok = false, msg = "La sesión cambió; volvé a intentar." }
			end
			draft.name = filtered
		end
		local handler = Actions.handlers[action]
		if not handler then
			return { ok = false, msg = "Acción desconocida." }
		end
		s.ctx.today = utcDate(self.deps.now())
		s.ctx.yesterday = utcDate(self.deps.now() - 86400)
		return handler(g, s.ctx, payload)
	end)
	s.busy = false
	if not ok then
		self.deps.log("Error en la acción " .. action .. ": " .. tostring(result))
		return { ok = false, msg = "Error interno del servidor. No se aplicó la acción." }
	end
	if Actions.economic[action] and requestId then
		local stored = { ok = result.ok, msg = result.msg, lotId = result.lotId, designId = result.designId }
		s.processed[requestId] = stored
		if result.ok then
			table.insert(s.profile.processed, requestId)
			while #s.profile.processed > Sessions.PROCESSED_KEPT do
				table.remove(s.profile.processed, 1)
			end
		end
	end
	if result.ok and not Actions.readOnly[action] then
		s.dirty = true
		if Actions.important[action] or action == "createCompany" or action == "deleteCompany" or action == "renameCompany" or action == "wipeAll" then
			s.pendingSave = true
		end
		if s.game and self.deps.garage and s.hasPlot then
			self.deps.garage.update(player, s.game)
		end
		self:push(s)
	end
	return {
		ok = result.ok, msg = result.msg, quiet = result.quiet, duplicate = result.duplicate,
		designId = result.designId, version = result.version, lotId = result.lotId, paid = result.paid,
	}
end

-- Reloj del servidor (1 s) ------------------------------------------------------------------------
function Sessions:tick()
	local clock = self.deps.clock()
	for player, s in self.list do
		if s.status == "ready" and not s.leaving then
			local g = s.game
			if g and not g.demo then
				g.playedSeconds = (g.playedSeconds or 0) + 1
			end
			if g and not s.blocked and g.time.speed > 0 then
				local ok, err = pcall(Simulation.simulate, g, s.ctx, Catalog.RULES.minutesPerRealSecond * g.time.speed)
				if not ok then
					self.deps.log("Error de simulación: " .. tostring(err))
				end
				s.dirty = true
				if self.deps.garage and s.hasPlot then
					self.deps.garage.update(player, g)
				end
				self:pushTick(s)
			end
			if s.canSave and not s.saving then
				local due = s.pendingSave and clock - s.lastSave >= Sessions.MIN_SAVE_GAP
				local auto = s.dirty and clock - s.lastAutosave >= Sessions.AUTOSAVE_SECONDS
				if due or auto then
					s.lastAutosave = clock
					s.lastRenew = clock
					self.deps.spawn(function()
						self:save(s)
					end)
				elseif clock - s.lastRenew >= DataService.RENEW_EVERY then
					-- Renovación del candado aunque la partida esté en pausa y sin cambios.
					s.lastRenew = clock
					self.deps.spawn(function()
						self:renew(s)
					end)
				end
			end
		end
	end
end

return Sessions
