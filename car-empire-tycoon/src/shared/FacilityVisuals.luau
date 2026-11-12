--!strict
--[[ Representación visual PROVISIONAL del crecimiento de las instalaciones en la parcela del jugador.

	Módulo puro (sin Instance): describe qué piezas provisionales van en la parcela según el nivel de cada
	instalación, y server/Garage las arma. Así se puede probar fuera de Roblox y reemplazar cada grupo por
	un modelo definitivo sin tocar la lógica:
	  - cada grupo tiene `asset` (por ejemplo "Oficinas3", "CentroInvestigacion2", "NaveFabrica4", "Linea2");
	  - si existe ServerStorage.CarEmpireAssets.Instalaciones.<asset> (un Model), Garage lo clona y lo ubica
	    con su pivote en `anchor` en lugar de las piezas provisionales.

	La gestión sigue siendo por menús: estos objetos no tienen interacción (no hay clic sobre edificios).

	Coordenadas: locales de la parcela (Garage: 90 × 70; el fondo es z = −35 y el frente con el concesionario
	z = +35). La oficina provisional del dueño ocupa el fondo izquierdo, la línea 1 el centro del fondo, el
	almacén la derecha y el concesionario el frente. Lo nuevo usa el resto del lugar:
	  - Líneas 2 y 3: entre la línea 1 y el concesionario (sin comprar: el lugar marcado en el piso).
	  - Nave de la fábrica: techo y estructura sobre las líneas; silos y chimeneas en los niveles altos.
	  - Centro de investigación: fondo derecho, un piso por nivel (cúpula y antena en los altos).
	  - Oficinas centrales: torre detrás de la pared del fondo, más alta con cada nivel (asoma desde el 2).
	  - Obra en curso: andamio amarillo alrededor de la instalación que se está ampliando. ]]

local FacilityVisuals = {}

FacilityVisuals.PLOT = { w = 90, d = 70, wall = 18 }
-- Zonas que ya ocupa el garaje base (para no superponer): { x0, x1, z0, z1 }.
FacilityVisuals.RESERVED = {
	{ name = "Oficina del dueño", x0 = -45, x1 = -17, z0 = -35, z1 = -8 },
	{ name = "Línea 1", x0 = -13, x1 = 17, z0 = -25, z1 = -15.5 },
	{ name = "Almacén", x0 = 17, x1 = 43, z0 = -14, z1 = 18 },
	{ name = "Concesionario", x0 = -32, x1 = 16, z0 = 11, z1 = 33 },
}
FacilityVisuals.LINE_Z = { [2] = -8, [3] = 2.5 } -- centro de cada línea extra (la 1 es del garaje base)

local COLORS = {
	belt = "#20242E", roller = "#3A4152", frame = "#FFB36B", mark = "#F7C95C", markOff = "#5D6371",
	roof = "#3B4150", steel = "#596273", glass = "#8DB8FF", silo = "#C9CED8", brick = "#5B4636",
	lab = "#1C3A44", labGlow = "#6FE3F0", office = "#2A2F3D", window = "#C2D8FF", scaffold = "#F7C95C",
}

local function part(name: string, size: { number }, pos: { number }, color: string, extra: any?): any
	local p = { name = name, size = size, pos = pos, color = color, material = "SmoothPlastic", transparency = 0 }
	for k, v in extra or {} do
		p[k] = v
	end
	return p
end

-- Estado visual de una partida (solo lo que se dibuja). Lo calcula el servidor desde el estado guardado.
function FacilityVisuals.state(g: any, Rules: any): any
	local building = {}
	for _, b in (type(g.facilities) == "table" and g.facilities.builds) or {} do
		building[b.kind] = true
	end
	return {
		factory = Rules.facilityLevel(g, "factory"),
		research = Rules.facilityLevel(g, "research"),
		offices = Rules.facilityLevel(g, "offices"),
		lines = { true, Rules.ownsLine(g, 2), Rules.ownsLine(g, 3) },
		building = building,
	}
end

-- Clave para reconstruir solo cuando algo visible cambió.
function FacilityVisuals.key(st: any): string
	local b = {}
	for _, k in { "offices", "factory", "research", "line2" } do
		table.insert(b, st.building[k] and "1" or "0")
	end
	return table.concat({ st.factory, st.research, st.offices, tostring(st.lines[2]), tostring(st.lines[3]), table.concat(b) }, "|")
end

-- Líneas 2 y 3: cinta con rodillos y pórtico si es propia; si no, el lugar marcado en el piso.
local function lineGroup(n: number, owned: boolean, premium: boolean): any
	local z = FacilityVisuals.LINE_Z[n]
	local parts = {}
	if owned then
		table.insert(parts, part("LineaProduccion" .. n, { 30, 1.2, 8 }, { 0, 1, z }, COLORS.belt))
		for k = -2, 2 do
			table.insert(parts, part("Rodillo", { 0.4, 0.2, 7.6 }, { k * 6, 1.7, z }, COLORS.roller))
		end
		table.insert(parts, part("Portico", { 1, 9, 1 }, { -14, 5, z - 4.5 }, COLORS.frame))
		table.insert(parts, part("Portico", { 1, 9, 1 }, { 14, 5, z - 4.5 }, COLORS.frame))
		table.insert(parts, part("Portico", { 29, 1, 1 }, { 0, 9.5, z - 4.5 }, COLORS.frame))
	else
		local c = premium and COLORS.mark or COLORS.markOff
		table.insert(parts, part("LugarLinea" .. n, { 30, 0.12, 0.3 }, { 0, 0.5, z - 4 }, c, { neon = premium }))
		table.insert(parts, part("LugarLinea" .. n, { 30, 0.12, 0.3 }, { 0, 0.5, z + 4 }, c, { neon = premium }))
		table.insert(parts, part("LugarLinea" .. n, { 0.3, 0.12, 8 }, { -15, 0.5, z }, c, { neon = premium }))
		table.insert(parts, part("LugarLinea" .. n, { 0.3, 0.12, 8 }, { 15, 0.5, z }, c, { neon = premium }))
	end
	local text = owned and ("🏭  Línea " .. n .. " · libre")
		or (premium and ("Línea " .. n .. " · prémium (Robux, para toda la cuenta)") or ("Línea " .. n .. " · se compra en Instalaciones"))
	return {
		id = "linea" .. n,
		kind = n == 2 and "line2" or "line3",
		asset = owned and ("Linea" .. n) or nil,
		anchor = { 0, 0, z },
		parts = parts,
		label = { text = text, pos = { 0, owned and 11 or 2, z }, color = owned and COLORS.frame or COLORS.markOff },
		line = n,
		owned = owned,
	}
end

-- Nave de la fábrica: del garaje (nivel 1, sin agregados) al complejo automotriz (nivel 5).
local function factoryGroup(level: number): any
	local parts = {}
	if level >= 2 then
		-- Taller: vigas de techo sobre las líneas.
		for k = -1, 1 do
			table.insert(parts, part("VigaTecho", { 34, 1, 1.2 }, { 0, 17.5, -14 + k * 9 }, COLORS.steel))
		end
		table.insert(parts, part("Columna", { 1.2, 17, 1.2 }, { -16, 8.9, -30 }, COLORS.steel))
		table.insert(parts, part("Columna", { 1.2, 17, 1.2 }, { 16, 8.9, -30 }, COLORS.steel))
	end
	if level >= 3 then
		-- Fábrica: techo completo con lucernarios.
		table.insert(parts, part("TechoNave", { 36, 0.6, 30 }, { 0, 18.4, -14 }, COLORS.roof, { transparency = 0.35 }))
		for k = -1, 1 do
			table.insert(parts, part("Lucernario", { 30, 0.3, 2 }, { 0, 18.8, -14 + k * 9 }, COLORS.glass, { neon = true, transparency = 0.4 }))
		end
	end
	if level >= 4 then
		-- Planta industrial: silos de pintura y materiales detrás de la pared del fondo (lado derecho).
		table.insert(parts, part("Silo", { 6, 22, 6 }, { 28, 11, -41 }, COLORS.silo))
		table.insert(parts, part("Silo", { 6, 22, 6 }, { 37, 11, -41 }, COLORS.silo))
		table.insert(parts, part("ParedAlta", { 90, 6, 1 }, { 0, 21, -35 }, COLORS.steel))
	end
	if level >= 5 then
		-- Complejo automotriz: chimeneas y puente grúa.
		table.insert(parts, part("Chimenea", { 3, 40, 3 }, { -8, 20.4, -38 }, COLORS.brick))
		table.insert(parts, part("Chimenea", { 3, 40, 3 }, { 10, 20.4, -38 }, COLORS.brick))
		table.insert(parts, part("PuenteGrua", { 38, 1.5, 2 }, { 0, 16, -11 }, COLORS.mark))
	end
	return {
		id = "fabrica",
		kind = "factory",
		asset = "NaveFabrica" .. level,
		anchor = { 0, 0, -14 },
		parts = parts,
		label = nil,
		level = level,
		-- Contorno de la nave (para el andamio cuando el garaje todavía no tiene agregados).
		footprint = { -17, 17, 12, -27, -3 },
	}
end

-- Centro de investigación: un piso por nivel en el fondo derecho; cúpula desde el 3, antena desde el 5.
local function researchGroup(level: number, name: string): any
	local parts = {}
	local floorH = 4
	local cx, cz = 32, -26
	for f = 1, level do
		table.insert(parts, part("PisoLaboratorio", { 18, floorH - 0.4, 14 }, { cx, 0.4 + (f - 0.5) * floorH, cz }, COLORS.lab))
		table.insert(parts, part("VentanasLaboratorio", { 18.2, 1, 14.2 }, { cx, 0.4 + (f - 0.5) * floorH, cz }, COLORS.labGlow, { neon = true, transparency = 0.3 }))
	end
	local top = 0.4 + level * floorH
	if level >= 3 then
		table.insert(parts, part("Cupula", { 8, 8, 8 }, { cx, top, cz }, COLORS.silo, { shape = "Ball" }))
	end
	if level >= 5 then
		table.insert(parts, part("Antena", { 0.6, 10, 0.6 }, { cx + 6, top + 5, cz + 4 }, COLORS.steel))
	end
	return {
		id = "investigacion",
		kind = "research",
		asset = "CentroInvestigacion" .. level,
		anchor = { cx, 0, cz },
		parts = parts,
		label = { text = "🔬  " .. name .. " · nivel " .. level, pos = { cx, top + (level >= 3 and 6 or 2), cz }, color = COLORS.labGlow },
		level = level,
		height = top,
	}
end

-- Oficinas centrales: torre detrás de la pared del fondo (la oficina del dueño sigue adentro, junto al escritorio).
local function officesGroup(level: number, name: string): any
	local parts = {}
	local cx, cz = -26, -45
	local h = 10 + 7 * (level - 1)
	local w = 24 + 2 * (level - 1)
	table.insert(parts, part("TorreOficinas", { w, h, 14 }, { cx, h / 2, cz }, COLORS.office))
	for y = 4, h - 2, 3.5 do
		table.insert(parts, part("VentanasOficinas", { w + 0.2, 1, 14.2 }, { cx, y, cz }, COLORS.window, { neon = true, transparency = 0.45 }))
	end
	if level >= 4 then
		table.insert(parts, part("AlaOficinas", { 12, h * 0.6, 12 }, { cx + w / 2 + 6, h * 0.3, cz }, COLORS.office))
	end
	return {
		id = "oficinas",
		kind = "offices",
		asset = "Oficinas" .. level,
		anchor = { cx, 0, cz },
		parts = parts,
		label = { text = "🏢  " .. name, pos = { cx, h + 3, cz }, color = COLORS.window },
		level = level,
		height = h,
	}
end

-- Andamio de obra alrededor de un grupo (caja de su contorno).
local function scaffold(group: any): any
	local x0, x1, y1, z0, z1 = FacilityVisuals.bounds(group)
	local parts = {}
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	local w, d, h = x1 - x0 + 2, z1 - z0 + 2, math.max(4, y1)
	for _, c in { { x0 - 1, z0 - 1 }, { x1 + 1, z0 - 1 }, { x0 - 1, z1 + 1 }, { x1 + 1, z1 + 1 } } do
		table.insert(parts, part("AndamioPoste", { 0.4, h, 0.4 }, { c[1], h / 2, c[2] }, COLORS.scaffold))
	end
	for y = 3, h, 4 do
		table.insert(parts, part("AndamioBarra", { w, 0.3, 0.3 }, { cx, y, z0 - 1 }, COLORS.scaffold))
		table.insert(parts, part("AndamioBarra", { w, 0.3, 0.3 }, { cx, y, z1 + 1 }, COLORS.scaffold))
		table.insert(parts, part("AndamioBarra", { 0.3, 0.3, d }, { x0 - 1, y, cz }, COLORS.scaffold))
		table.insert(parts, part("AndamioBarra", { 0.3, 0.3, d }, { x1 + 1, y, cz }, COLORS.scaffold))
	end
	return { id = "obra_" .. group.id, kind = group.kind, asset = nil, anchor = group.anchor, parts = parts, label = { text = "🚧  En obra", pos = { cx, h + 2, cz }, color = COLORS.scaffold } }
end

-- Contorno de un grupo: x0, x1, y1 (altura), z0, z1.
function FacilityVisuals.bounds(group: any): (number, number, number, number, number)
	local x0, x1, y1, z0, z1 = math.huge, -math.huge, 0, math.huge, -math.huge
	for _, p in group.parts do
		x0 = math.min(x0, p.pos[1] - p.size[1] / 2)
		x1 = math.max(x1, p.pos[1] + p.size[1] / 2)
		y1 = math.max(y1, p.pos[2] + p.size[2] / 2)
		z0 = math.min(z0, p.pos[3] - p.size[3] / 2)
		z1 = math.max(z1, p.pos[3] + p.size[3] / 2)
	end
	if x0 == math.huge then
		local f = group.footprint
		if f then
			return f[1], f[2], f[3], f[4], f[5]
		end
		local a = group.anchor
		return a[1], a[1], 0, a[3], a[3]
	end
	return x0, x1, y1, z0, z1
end

--[[ Grupos a dibujar para un estado. names = { research = nombre del nivel, offices = nombre } (lo pasa
	Garage desde el catálogo). Determinista: el mismo estado da siempre las mismas piezas. ]]
function FacilityVisuals.layout(st: any, names: any?): { any }
	local nm = names or {}
	local groups = {}
	table.insert(groups, factoryGroup(st.factory))
	table.insert(groups, lineGroup(2, st.lines[2] == true, false))
	table.insert(groups, lineGroup(3, st.lines[3] == true, true))
	table.insert(groups, researchGroup(st.research, nm.research or "Centro de investigación"))
	table.insert(groups, officesGroup(st.offices, nm.offices or "Oficinas centrales"))
	local byKind = {}
	for _, gr in groups do
		byKind[gr.kind] = byKind[gr.kind] or gr
	end
	for _, kind in { "offices", "factory", "research", "line2" } do
		if st.building[kind] and byKind[kind] then
			table.insert(groups, scaffold(byKind[kind]))
		end
	end
	return groups
end

return FacilityVisuals
