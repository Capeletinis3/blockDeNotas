--!strict
--[[
	Guardado por jugador con protección contra pérdidas.

	Registro en el DataStore (clave "player_<UserId>"):
	  { schema = 1, game = <partida o nil>, savedAt, saveCount, lock = { jobId, time } | nil }

	Reglas:
	  • Cada jugador tiene su propia clave; nunca se lee ni escribe la de otro.
	  • Carga con UpdateAsync tomando un «candado de sesión». Si otro servidor tiene el candado
	    vigente, se reintenta; si los datos guardados no pasan la validación, la carga falla
	    y NO se escribe nada (los datos originales quedan intactos).
	  • Si la carga falla, la sesión queda marcada y nunca se guarda encima.
	  • Antes de guardar se valida la partida; si es inválida no se escribe.
	  • Si el candado pertenece a otro servidor (sesión perdida), el guardado se cancela.
	  • Reintentos con espera creciente ante errores del servicio.

	store: objeto con UpdateAsync(key, transform) (DataStore real o MemoryStore de pruebas).
	opts: { jobId: string, now: () -> number, wait: (number) -> (), log: (string) -> (), validate, migrate }
]]

local DataService = {}
DataService.__index = DataService

DataService.LOCK_TIMEOUT = 300 -- s sin renovar el candado para considerarlo abandonado
DataService.LOAD_ATTEMPTS = 5
DataService.SAVE_ATTEMPTS = 4

function DataService.new(store: any, opts: any)
	local self = setmetatable({}, DataService)
	self.store = store
	self.jobId = opts.jobId
	self.now = opts.now
	self.wait = opts.wait
	self.log = opts.log or function(_: string) end
	self.validate = opts.validate
	self.migrate = opts.migrate
	return self
end

function DataService.key(userId: number): string
	return "player_" .. tostring(userId)
end

local function lockIsForeign(self: any, rec: any): boolean
	local lock = type(rec) == "table" and rec.lock or nil
	if type(lock) ~= "table" or lock.jobId == self.jobId then
		return false
	end
	local t = tonumber(lock.time) or 0
	return self.now() - t < DataService.LOCK_TIMEOUT
end

--[[
	Devuelve (true, partida | nil) si cargó (nil = jugador nuevo sin empresa),
	o (false, nil, motivo, código) si no se pudo cargar. Códigos: "locked", "corrupt", "service".
]]
function DataService:load(userId: number): (boolean, any?, string?, string?)
	local key = DataService.key(userId)
	local lastErr = "desconocido"
	local lastCode = "service"
	for attempt = 1, DataService.LOAD_ATTEMPTS do
		local outcome: string? = nil
		local loaded: any = nil
		local reason: string? = nil
		local ok, err = pcall(function()
			self.store:UpdateAsync(key, function(old: any)
				outcome, loaded, reason = nil, nil, nil
				if old ~= nil and type(old) ~= "table" then
					outcome, reason = "corrupt", "El registro guardado no tiene el formato esperado."
					return nil -- cancelar: no se escribe nada
				end
				if old and lockIsForeign(self, old) then
					outcome = "locked"
					return nil
				end
				if old and old.game ~= nil then
					local valid, why = self.validate(old.game)
					if not valid then
						outcome, reason = "corrupt", why
						return nil
					end
				end
				local rec = old or { schema = 1, saveCount = 0 }
				rec.lock = { jobId = self.jobId, time = self.now() }
				loaded = rec.game
				outcome = "ok"
				return rec
			end)
		end)
		if ok and outcome == "ok" then
			local game = loaded and self.migrate(loaded) or nil
			return true, game, nil, nil
		elseif ok and outcome == "corrupt" then
			-- No reintentar: los datos están dañados y no deben pisarse.
			self.log("Carga cancelada para " .. key .. ": " .. tostring(reason))
			return false, nil, "Tu partida guardada parece dañada (" .. tostring(reason) .. "). No se modificó nada.", "corrupt"
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
	return false, nil, lastErr, lastCode
end

--[[
	Guarda la partida. opts.release = true libera el candado (al salir del juego).
	Devuelve (true) o (false, motivo, código). Códigos: "invalid", "lost_lock", "service".
]]
function DataService:save(userId: number, game: any, opts: any?): (boolean, string?, string?)
	local release = opts and opts.release or false
	local valid, why = self.validate(game)
	if not valid then
		self.log("Guardado cancelado: partida inválida (" .. tostring(why) .. ")")
		return false, "La partida en memoria no pasó la validación; no se guardó para proteger tus datos.", "invalid"
	end
	local key = DataService.key(userId)
	local lastErr = "desconocido"
	for attempt = 1, DataService.SAVE_ATTEMPTS do
		local outcome: string? = nil
		local ok, err = pcall(function()
			self.store:UpdateAsync(key, function(old: any)
				outcome = nil
				if old and lockIsForeign(self, old) then
					outcome = "lost_lock"
					return nil
				end
				local rec = {
					schema = 1,
					game = game,
					savedAt = self.now(),
					saveCount = ((type(old) == "table" and tonumber(old.saveCount)) or 0) + 1,
					lock = (not release) and { jobId = self.jobId, time = self.now() } or nil,
				}
				outcome = "ok"
				return rec
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

-- Libera el candado sin tocar la partida (jugador que salió sin crear empresa).
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
	return setmetatable({ data = {}, copy = deepCopy, failNext = 0, writes = 0 }, MemoryStore)
end

function MemoryStore:UpdateAsync(key: string, transform: (any) -> any): any
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
