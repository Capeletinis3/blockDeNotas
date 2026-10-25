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

function Util.clock(minute: number): string
	local mm = math.floor(minute)
	return string.format("%02d:%02d", math.floor(mm / 60), mm % 60)
end

local MONTHS = { "Ene", "Feb", "Mar", "Abr", "May", "Jun", "Jul", "Ago", "Sep", "Oct", "Nov", "Dic" }
function Util.gameDate(day: number): string
	local m = MONTHS[(math.floor(day / 30) % 12) + 1]
	local y = 2026 + math.floor(day / 360)
	return m .. " " .. y .. " · Día " .. (day + 1)
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

return Util
