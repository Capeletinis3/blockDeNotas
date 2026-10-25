--!strict
--[[
	Guardado por jugador con protección contra pérdidas.

	Registro en el DataStore (clave "player_<UserId>"):
	  { schema = 2, profile = { slots, active, settings, processed }, savedAt, saveCount, lock = { jobId, time } | nil }
	(El formato de la etapa 1, { schema = 1, game = … }, se migra al cargar.)

	Reglas:
	  • Cada jugador tiene su propia clave; nunca se lee ni escribe la de otro.
	  • Carga con UpdateAsync tomando un «candado de sesión». Si otro servidor lo tiene vigente, no se carga.
	  • El candado se renueva cada minuto con renew(), aunque la partida esté en pausa y sin cambios.
	  • Una ranura que no pasa la validación queda marcada como dañada: se vuelve a escribir tal cual,
	    nunca se reemplaza, y no se puede jugar. Si el registro entero no es reconocible, no se escribe nada.
	  • Antes de guardar se valida cada ranura jugable; si alguna es inválida no se escribe.
	  • Si otro servidor tomó el candado, el guardado y la renovación se cancelan (sesión perdida).
	  • Reintentos con espera creciente ante errores del servicio.

	store: objeto con UpdateAsync(key, transform) (DataStore real o MemoryStore de pruebas).
	opts: { jobId, now, wait, log, loadProfile(record, now) -> (perfil?, dañadas|motivo), validate(partida) }
]]

local DataService = {}
DataService.__index = DataService

DataService.LOCK_TIMEOUT = 300 -- s sin renovar el candado para considerarlo abandonado
DataService.RENEW_EVERY = 60 -- s entre renovaciones
DataService.LOAD_ATTEMPTS = 5
DataService.SAVE_ATTEMPTS = 4

function DataService.new(store: any, opts: any)
	local self = setmetatable({}, DataService)
	self.store = store
	self.jobId = opts.jobId
	self.now = opts.now
	self.wait = opts.wait
	self.log = opts.log or function(_: string) end
	self.loadProfile = opts.loadProfile
	self.validate = opts.validate
	self.copy = opts.copy or function(v: any)
		return v
	end
	return self
end

function DataService.key(userId: number): string
	return "player_" .. tostring(userId)
end

function DataService:lockIsForeign(rec: any): boolean
	local lock = type(rec) == "table" and rec.lock or nil
	if type(lock) ~= "table" or lock.jobId == self.jobId then
		return false
	end
	local t = tonumber(lock.time) or 0
	return self.now() - t < DataService.LOCK_TIMEOUT
end

--[[
	Devuelve (true, perfil, dañadas) o (false, nil, nil, motivo, código).
	Códigos: "locked", "corrupt", "service".
]]
function DataService:load(userId: number): (boolean, any?, any?, string?, string?)
	local key = DataService.key(userId)
	local lastErr, lastCode = "desconocido", "service"
	for attempt = 1, DataService.LOAD_ATTEMPTS do
		local outcome, profile, damaged, reason = nil, nil, nil, nil
		local ok, err = pcall(function()
			self.store:UpdateAsync(key, function(old: any)
				outcome, profile, damaged, reason = nil, nil, nil, nil
				if old ~= nil and type(old) ~= "table" then
					outcome, reason = "corrupt", "El registro guardado no tiene el formato esperado."
					return nil -- cancelar: no se escribe nada
				end
				if old and self:lockIsForeign(old) then
					outcome = "locked"
					return nil
				end
				local p, d = self.loadProfile(old ~= nil and self.copy(old) or nil, self.now())
				if not p then
					outcome, reason = "corrupt", d
					return nil
				end
				profile, damaged = p, d
				-- Solo se agrega el candado: el contenido guardado no cambia.
				local rec = old or { schema = 2, saveCount = 0 }
				rec.lock = { jobId = self.jobId, time = self.now() }
				outcome = "ok"
				return rec
			end)
		end)
		if ok and outcome == "ok" then
			return true, profile, damaged, nil, nil
		elseif ok and outcome == "corrupt" then
			self.log("Carga cancelada para " .. key .. ": " .. tostring(reason))
			return false, nil, nil, "Tus datos guardados parecen dañados (" .. tostring(reason) .. "). No se modificó nada.", "corrupt"
		elseif ok and outcome == "locked" then
			lastErr, lastCode = "Tu partida sigue abierta en otro servidor.", "locked"
		else
			lastErr, lastCode = tostring(err), "service"
		end
		self.log(string.format("Carga de %s falló (intento %d): %s", key, attempt, lastErr))
		if attempt < DataService.LOAD_ATTEMPTS then
			self.wait(math.min(2 ^ attempt, 15))
		end
	end
	return false, nil, nil, lastErr, lastCode
end

-- Valida las ranuras jugables. Las dañadas se escriben sin cambios.
function DataService:checkProfile(profile: any, damaged: any): (boolean, string?)
	if type(profile) ~= "table" or type(profile.slots) ~= "table" then
		return false, "Perfil inválido."
	end
	for k, g in profile.slots do
		if not (damaged and damaged[k]) then
			local ok, why = self.validate(g)
			if not ok then
				return false, "Ranura " .. tostring(k) .. ": " .. tostring(why)
			end
		end
	end
	return true, nil
end

--[[
	Guarda el perfil. opts.release = true libera el candado (al salir del juego).
	Devuelve (true) o (false, motivo, código). Códigos: "invalid", "lost_lock", "service".
]]
function DataService:save(userId: number, profile: any, damaged: any, opts: any?): (boolean, string?, string?)
	local release = opts and opts.release or false
	local valid, why = self:checkProfile(profile, damaged)
	if not valid then
		self.log("Guardado cancelado: " .. tostring(why))
		return false, "La partida en memoria no pasó la validación (" .. tostring(why) .. "); no se guardó para proteger tus datos.", "invalid"
	end
	local key = DataService.key(userId)
	local snapshot = self.copy(profile)
	local lastErr = "desconocido"
	for attempt = 1, DataService.SAVE_ATTEMPTS do
		local outcome: string? = nil
		local ok, err = pcall(function()
			self.store:UpdateAsync(key, function(old: any)
				outcome = nil
				if old and self:lockIsForeign(old) then
					outcome = "lost_lock"
					return nil
				end
				outcome = "ok"
				return {
					schema = 2,
					profile = snapshot,
					savedAt = self.now(),
					saveCount = ((type(old) == "table" and tonumber(old.saveCount)) or 0) + 1,
					lock = (not release) and { jobId = self.jobId, time = self.now() } or nil,
				}
			end)
		end)
		if ok and outcome == "ok" then
			return true, nil, nil
		elseif ok and outcome == "lost_lock" then
			self.log("Guardado cancelado para " .. key .. ": otro servidor tiene la partida abierta.")
			return false, "Otro servidor abrió tu partida; esta sesión dejó de guardar para no pisar datos.", "lost_lock"
		end
		lastErr = tostring(err)
		self.log(string.format("Guardado de %s falló (intento %d): %s", key, attempt, lastErr))
		if attempt < DataService.SAVE_ATTEMPTS then
			self.wait(math.min(2 ^ attempt, 10))
		end
	end
	return false, "El servicio de guardado no respondió (" .. lastErr .. "). Se reintentará.", "service"
end

-- Renueva el candado sin tocar el perfil. Devuelve (true) o (false, código) con "lost_lock" o "service".
function DataService:renew(userId: number): (boolean, string?)
	local key = DataService.key(userId)
	local outcome: string? = nil
	local ok = pcall(function()
		self.store:UpdateAsync(key, function(old: any)
			outcome = nil
			if old and self:lockIsForeign(old) then
				outcome = "lost_lock"
				return nil
			end
			if type(old) ~= "table" then
				-- Jugador nuevo que todavía no guardó nada: registro mínimo con el candado.
				outcome = "ok"
				return { schema = 2, saveCount = 0, lock = { jobId = self.jobId, time = self.now() } }
			end
			old.lock = { jobId = self.jobId, time = self.now() }
			outcome = "ok"
			return old
		end)
	end)
	if ok and outcome == "ok" then
		return true, nil
	end
	return false, (ok and outcome == "lost_lock") and "lost_lock" or "service"
end

-- Libera el candado sin tocar la partida (jugador que salió sin poder o sin necesidad de guardar).
function DataService:release(userId: number): boolean
	local key = DataService.key(userId)
	local ok = pcall(function()
		self.store:UpdateAsync(key, function(old: any)
			if type(old) ~= "table" or type(old.lock) ~= "table" or old.lock.jobId ~= self.jobId then
				return nil
			end
			old.lock = nil
			return old
		end)
	end)
	return ok
end

-- Almacén en memoria con la misma interfaz que un DataStore (pruebas y Studio sin acceso a la API).
local MemoryStore = {}
MemoryStore.__index = MemoryStore

function MemoryStore.new(deepCopy: (any) -> any)
	return setmetatable({ data = {}, copy = deepCopy, failNext = 0, writes = 0, delay = 0, wait = nil }, MemoryStore)
end

function MemoryStore:UpdateAsync(key: string, transform: (any) -> any): any
	if self.delay > 0 and self.wait then
		self.wait(self.delay)
	end
	if self.failNext > 0 then
		self.failNext -= 1
		error("Fallo simulado del servicio")
	end
	-- Como el DataStore real: el transform recibe una copia y el valor se serializa.
	local current = self.data[key]
	local result = transform(current ~= nil and self.copy(current) or nil)
	if result == nil then
		return current
	end
	self.data[key] = self.copy(result)
	self.writes += 1
	return result
end

DataService.MemoryStore = MemoryStore

return DataService
