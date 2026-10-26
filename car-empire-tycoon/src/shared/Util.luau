--!strict
-- Utilidades puras compartidas por servidor, cliente y pruebas.

local Util = {}

-- Redondeo igual a Math.round de JavaScript (la V3 usa esa regla en todos los precios).
function Util.round(x: number): number
	return math.floor(x + 0.5)
end

function Util.clamp(v: number, a: number, b: number): number
	if v < a then
		return a
	elseif v > b then
		return b
	end
	return v
end

function Util.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value :: any do
		out[k] = Util.deepCopy(v)
	end
	return out :: any
end

function Util.contains(list: { any }?, value: any): boolean
	if not list then
		return false
	end
	for _, v in list do
		if v == value then
			return true
		end
	end
	return false
end

function Util.isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

function Util.isHexColor(v: any): boolean
	return type(v) == "string" and string.match(v, "^#%x%x%x%x%x%x$") ~= nil
end

function Util.trim(s: string): string
	return (string.gsub(s, "^%s+", ""):gsub("%s+$", ""))
end

-- Cantidad de caracteres (UTF-8) para validar nombres con tildes o eñes.
function Util.charCount(s: string): number
	local n = utf8.len(s)
	return n or #s
end

-- Recorta a n caracteres UTF-8 sin cortar una letra por la mitad.
function Util.truncateChars(s: string, n: number): string
	if Util.charCount(s) <= n then
		return s
	end
	local stop = utf8.offset(s, n + 1)
	return stop and string.sub(s, 1, stop - 1) or s
end

-- Miles con punto, como en es-AR: 28700 → "28.700".
function Util.thousands(n: number): string
	local s = tostring(math.floor(math.abs(n) + 0.5))
	local out = s:reverse():gsub("(%d%d%d)", "%1."):reverse()
	if string.sub(out, 1, 1) == "." then
		out = string.sub(out, 2)
	end
	return out
end

-- Dinero: "$28.700" y "−$1.200" (con el signo menos tipográfico de la V3).
function Util.money(n: number): string
	if n < 0 then
		return "−$" .. Util.thousands(-n)
	end
	return "$" .. Util.thousands(n)
end

function Util.num(n: number, decimals: number?): string
	local d = decimals or 0
	if d == 0 then
		local r = Util.round(n)
		return (r < 0 and "−" or "") .. Util.thousands(math.abs(r))
	end
	local s = string.format("%." .. d .. "f", n)
	return (string.gsub(s, "%.", ","))
end

function Util.gameDuration(min: number): string
	local m = math.max(0, Util.round(min))
	local h = math.floor(m / 60)
	local rest = m % 60
	return (h > 0 and (h .. " h ") or "") .. rest .. " min"
end

-- Tiempo real equivalente (realDur de la V3): «≈ 16 s reales», «≈ 3 min reales» o «en pausa».
function Util.realDur(min: number, speed: number): string
	if not speed or speed == 0 then
		return "en pausa"
	end
	local s = math.ceil(min / (10 * speed))
	return s < 60 and ("≈ " .. s .. " s reales") or ("≈ " .. math.ceil(s / 60) .. " min reales")
end

function Util.clock(minute: number): string
	local mm = math.floor(minute)
	return string.format("%02d:%02d", math.floor(mm / 60), mm % 60)
end

-- Calendario: g.time.day cuenta MESES desde enero del año inicial (1970); ver Catalog.CALENDAR.
local START_YEAR = 1970
local END_YEAR = 2030 -- último año histórico visible (Catalog.CALENDAR.endYear; ver Util.setCalendar)
Util.MONTHS = { "Ene", "Feb", "Mar", "Abr", "May", "Jun", "Jul", "Ago", "Sep", "Oct", "Nov", "Dic" }
function Util.setStartYear(y: number)
	START_YEAR = y
end
function Util.setCalendar(startYear: number, endYear: number)
	START_YEAR, END_YEAR = startYear, endYear
end
-- Año histórico visible: no pasa del último año con contenido.
function Util.yearOf(month: number): number
	return math.min(END_YEAR, START_YEAR + math.floor(month / 12))
end
-- Años comerciales jugados después del último año histórico (0 mientras dura la historia).
function Util.extraYears(month: number): number
	return math.max(0, START_YEAR + math.floor(month / 12) - END_YEAR)
end
function Util.gameDate(month: number): string
	return Util.MONTHS[(math.floor(month) % 12) + 1] .. " " .. Util.yearOf(month)
end
-- Duración en tiempo de juego expresada en meses y años (para textos como «≈ 3 meses»).
function Util.monthsText(months: number): string
	local m = math.max(0, Util.round(months))
	if m < 12 then
		return m .. (m == 1 and " mes" or " meses")
	end
	local y = math.floor(m / 12)
	local r = m % 12
	return y .. (y == 1 and " año" or " años") .. (r > 0 and (" y " .. r .. (r == 1 and " mes" or " meses")) or "")
end
-- Tiempo real («2 min 30 s», «1 h 5 min»), para progreso de producción e investigación.
function Util.realTime(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	if s < 60 then
		return s .. " s"
	end
	local m = math.floor(s / 60)
	if m < 60 then
		local r = s % 60
		return m .. " min" .. (r > 0 and m < 10 and (" " .. r .. " s") or "")
	end
	local h = math.floor(m / 60)
	return h .. " h " .. (m % 60) .. " min"
end
-- Números grandes compactos: 12.400 → «12,4 mil», 3.200.000 → «3,2 M».
function Util.compact(n: number): string
	local a = math.abs(n)
	if a >= 1e6 then
		return Util.num(n / 1e6, a >= 1e7 and 0 or 1) .. " M"
	elseif a >= 1e4 then
		return Util.num(n / 1e3, 0) .. " mil"
	end
	return Util.num(n)
end

function Util.keys(t: { [any]: any }): { any }
	local out = {}
	for k in t do
		table.insert(out, k)
	end
	table.sort(out, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return out
end

-- Aplica sobre la vista completa de la partida (cliente) los datos del segundo a segundo que manda el
-- servidor (GameState.live). Solo toca campos que existen en la vista: nunca agrega lotes ni diseños.
function Util.mergeLive(game: any, live: any)
	for _, k in { "money", "rp", "xp", "level", "reputation", "time", "counters", "derived" } do
		if live[k] ~= nil then
			game[k] = live[k]
		end
	end
	game.bankFull = live.bankFull
	if game.stats then
		game.stats.month = live.month or game.stats.month
		if live.dayKey and live.day then
			game.stats.days[live.dayKey] = live.day
		end
	end
	if game.research then
		game.research.active = live.research
	end
	local byId = {}
	for _, l in live.lots or {} do
		byId[l.id] = l
	end
	for _, l in game.lots or {} do
		local x = byId[l.id]
		if x then
			for k, v in x do
				l[k] = v
			end
		end
	end
end

return Util
