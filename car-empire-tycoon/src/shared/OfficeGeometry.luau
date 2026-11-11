--!strict
--[[ Geometría del plano de oficinas (pura, sin servicios de Roblox). La usan Office (colocación y validación),
	OfficeNavigation (zonas transitables y rutas de los empleados) y el editor. Antes vivía dentro de Office:
	Office reexporta las mismas funciones con los mismos nombres (Office.corners, Office.overlaps…), así nada
	cambia para quien ya las usaba. Separarla evita una dependencia circular Office ↔ OfficeNavigation. ]]

local OfficeCatalog = require(script.Parent.OfficeCatalog)

local Geometry = {}

-- Geometría ----------------------------------------------------------------------------------------------
-- Cada mueble es un rectángulo girado (centro x, y; lados w × d en casillas; giro rot). Las colisiones se
-- calculan con la intersección real de polígonos convexos (teorema del eje separador), no con muestras.

local GEO_EPS = 1e-4 -- tolerancia: tocarse por un borde no es superponerse

-- Esquinas del rectángulo de un mueble, en casillas de la habitación.
function Geometry.corners(item: any, x: number, y: number, rot: number): { { number } }
	local hw, hd = item.cells[1] / 2, item.cells[2] / 2
	local a = math.rad(rot)
	local c, s = math.cos(a), math.sin(a)
	local out = {}
	for _, k in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local u, v = k[1] * hw, k[2] * hd
		table.insert(out, { x + u * c - v * s, y + u * s + v * c })
	end
	return out
end

local function square(cx: number, cy: number): { { number } }
	return { { cx, cy }, { cx + 1, cy }, { cx + 1, cy + 1 }, { cx, cy + 1 } }
end
Geometry.cellPolygon = square

local function project(poly: { { number } }, ax: number, ay: number): (number, number)
	local lo, hi = math.huge, -math.huge
	for _, p in poly do
		local d = p[1] * ax + p[2] * ay
		lo, hi = math.min(lo, d), math.max(hi, d)
	end
	return lo, hi
end

-- ¿Se superponen dos polígonos convexos con área (más que tocarse)?
function Geometry.overlaps(a: { { number } }, b: { { number } }): boolean
	for _, poly in { a, b } do
		local n = #poly
		for i = 1, n do
			local p, q = poly[i], poly[i % n + 1]
			local ax, ay = q[2] - p[2], p[1] - q[1]
			local len = math.sqrt(ax * ax + ay * ay)
			if len > 0 then
				ax, ay = ax / len, ay / len
				local a1, a2 = project(a, ax, ay)
				local b1, b2 = project(b, ax, ay)
				if a2 <= b1 + GEO_EPS or b2 <= a1 + GEO_EPS then
					return false -- eje separador
				end
			end
		end
	end
	return true
end

-- ¿El polígono queda dentro de la habitación (0..w × 0..d)?
function Geometry.insideRoom(poly: { { number } }, r: any): boolean
	for _, p in poly do
		if p[1] < -GEO_EPS or p[2] < -GEO_EPS or p[1] > r.w + GEO_EPS or p[2] > r.d + GEO_EPS then
			return false
		end
	end
	return true
end

--[[ Casillas que toca un mueble (con área en común, también en diagonal): para la cuadrícula del editor y
	para mostrar qué ocupa. Devuelve { { cx, cy } }. ]]
function Geometry.footprint(item: any, x: number, y: number, rot: number): { { number } }
	local poly = Geometry.corners(item, x, y, rot)
	local lx, ly, hx, hy = math.huge, math.huge, -math.huge, -math.huge
	for _, p in poly do
		lx, ly, hx, hy = math.min(lx, p[1]), math.min(ly, p[2]), math.max(hx, p[1]), math.max(hy, p[2])
	end
	local out = {}
	for cx = math.floor(lx), math.ceil(hx) - 1 do
		for cy = math.floor(ly), math.ceil(hy) - 1 do
			if Geometry.overlaps(poly, square(cx, cy)) then
				table.insert(out, { cx, cy })
			end
		end
	end
	return out
end

-- ¿El punto (x, y) de la habitación cae sobre este mueble colocado? (selección en el editor)
function Geometry.hits(p: any, x: number, y: number): boolean
	local item = OfficeCatalog.item(p.item)
	if not item then
		return false
	end
	local a = math.rad(p.rot)
	local c, s = math.cos(a), math.sin(a)
	local dx, dy = x - p.x, y - p.y
	local u, v = dx * c + dy * s, -dx * s + dy * c
	return math.abs(u) <= item.cells[1] / 2 and math.abs(v) <= item.cells[2] / 2
end

Geometry.EPS = GEO_EPS

-- ¿El punto (x, y) está dentro del polígono convexo (o sobre su borde)?
function Geometry.pointIn(poly: { { number } }, x: number, y: number): boolean
	local n = #poly
	local sign = 0
	for i = 1, n do
		local p, q = poly[i], poly[i % n + 1]
		local cross = (q[1] - p[1]) * (y - p[2]) - (q[2] - p[2]) * (x - p[1])
		if math.abs(cross) > GEO_EPS then
			local s = cross > 0 and 1 or -1
			if sign == 0 then
				sign = s
			elseif s ~= sign then
				return false
			end
		end
	end
	return true
end

-- Distancia del punto (x, y) al polígono convexo: 0 si está dentro o sobre el borde.
function Geometry.distance(poly: { { number } }, x: number, y: number): number
	if Geometry.pointIn(poly, x, y) then
		return 0
	end
	local best = math.huge
	local n = #poly
	for i = 1, n do
		local p, q = poly[i], poly[i % n + 1]
		local ex, ey = q[1] - p[1], q[2] - p[2]
		local len2 = ex * ex + ey * ey
		local t = len2 > 0 and math.clamp(((x - p[1]) * ex + (y - p[2]) * ey) / len2, 0, 1) or 0
		local cx, cy = p[1] + ex * t - x, p[2] + ey * t - y
		best = math.min(best, math.sqrt(cx * cx + cy * cy))
	end
	return best
end

return Geometry
