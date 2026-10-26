--!strict
--[[
	Reglas de diseño de vehículos (portadas de la V3: computeDesign, partBlock, devItems, newDraft…).
	El cliente las usa para la vista previa instantánea; el servidor las vuelve a ejecutar
	sobre una copia saneada del borrador antes de cobrar o guardar nada.
]]

local Catalog = require(script.Parent.Catalog)
local Util = require(script.Parent.Util)
local Rules = require(script.Parent.Rules)

local round = Util.round
local clamp = Util.clamp

local DesignCalc = {}

function DesignCalc.has(g: any, researchId: string?): boolean
	if not researchId then
		return true
	end
	return g ~= nil and g.research ~= nil and Util.contains(g.research.done, researchId)
end

function DesignCalc.researchName(id: string): string
	return Catalog.RESEARCH_NAMES[id] or id
end

-- nil si la base se puede usar, o el motivo si está bloqueada.
-- Año actual de la partida (sin partida: el inicial).
function DesignCalc.year(g: any): number
	if g and g.time then
		return Rules.year(g)
	end
	return Catalog.CALENDAR.startYear
end

function DesignCalc.baseAvailable(g: any, b: any): string?
	if (b.year or 1970) > DesignCalc.year(g) then
		return "Disponible desde " .. b.year
	end
	if b.research and not DesignCalc.has(g, b.research) then
		return "Requiere investigar «" .. DesignCalc.researchName(b.research) .. "»"
	end
	return nil
end

function DesignCalc.firstBase(g: any): any
	for _, b in Catalog.BASES do
		if DesignCalc.baseAvailable(g, b) == nil then
			return b
		end
	end
	return Catalog.BASES[1]
end

-- Compatibilidad: nil si la pieza se puede instalar o un motivo si no.
function DesignCalc.partBlock(g: any, d: any, p: any): string?
	local b = Catalog.base(d.baseId)
	if not b then
		return "Modelo base desconocido"
	end
	if p.need and not Util.contains(b.tags, p.need) then
		if p.need == "electrico" then
			return "Solo para vehículos eléctricos"
		elseif p.need == "offroad" then
			return "Solo para SUV y pickup"
		end
		return "Requiere motor a combustión"
	end
	if p.cat == "turbo" and p.id ~= "none" and Util.contains(b.tags, "electrico") then
		return "Los eléctricos no usan turbo"
	end
	if (p.year or 1970) > DesignCalc.year(g) then
		return "Disponible desde " .. p.year
	end
	if p.research and not DesignCalc.has(g, p.research) then
		return "Requiere investigar «" .. DesignCalc.researchName(p.research) .. "»"
	end
	return nil
end

-- Opciones de carrocería, interior y acabados: nil si se pueden elegir o el motivo si no.
function DesignCalc.optionBlock(g: any, opt: any): string?
	if not opt then
		return "Opción desconocida"
	end
	if (opt.year or 1970) > DesignCalc.year(g) then
		return "Disponible desde " .. opt.year
	end
	if opt.research and not DesignCalc.has(g, opt.research) then
		return "Requiere investigar «" .. DesignCalc.researchName(opt.research) .. "»"
	end
	return nil
end

function DesignCalc.finishBlock(g: any, finish: string): string?
	local f = Catalog.FINISHES[finish]
	if not f then
		return "Acabado desconocido"
	end
	return DesignCalc.optionBlock(g, { year = Catalog.FINISH_YEAR[finish] or 1970, research = f.research })
end

-- Rodado máximo del año (llantas grandes son de autos modernos).
function DesignCalc.maxWheel(g: any): number
	return math.floor(Catalog.interp(Catalog.WHEEL_SIZE.maxByYear, DesignCalc.year(g)))
end

-- Reemplaza piezas incompatibles al cambiar de base.
function DesignCalc.fixParts(d: any)
	local b = Catalog.base(d.baseId)
	for _, c in Catalog.CATS do
		local cat = c[1]
		local p = Catalog.part(cat, d.parts[cat])
		if not p or (p.need and not Util.contains(b.tags, p.need)) then
			d.parts[cat] = b.defaults[cat]
		end
	end
end

local function firstWord(s: string): string
	return string.match(s, "^(%S+)") or s
end

function DesignCalc.autoName(g: any, baseId: string): string
	local b = Catalog.base(baseId)
	local company = g and g.company and g.company.name or ""
	return Util.truncateChars(Util.trim(firstWord(b.name) .. " " .. firstWord(company)), 24)
end

function DesignCalc.generationLabel(modelYear: number, gen: number): string
	return modelYear .. " · " .. gen .. ".ª gen."
end

function DesignCalc.newDraft(g: any, baseId: string): any
	local b = Catalog.base(baseId)
	local year = DesignCalc.year(g)
	return {
		id = nil,
		name = DesignCalc.autoName(g, baseId),
		brand = g and g.company and g.company.name or b.brand,
		modelYear = year,
		gen = 1,
		lineage = nil,
		generation = DesignCalc.generationLabel(year, 1),
		chassis = "Monocasco",
		segment = "Masivo",
		objective = "Familiar",
		quality = 2,
		baseId = b.id,
		parts = Util.deepCopy(b.defaults),
		paint = { primary = b.type == "deportivo" and "#4F5BD5" or "#C0C6D0", secondary = "#15171C", finish = "Metálico", intensity = 100, gloss = 60 },
		wheels = { size = math.min(15, DesignCalc.maxWheel(g)), style = "radial5", rim = "#C9CED8" },
		caliper = "#5D6371",
		spoiler = false,
		body = Util.deepCopy(Catalog.BODY_DEFAULTS),
		interior = Util.deepCopy(Catalog.INTERIOR_DEFAULTS),
		version = 0,
	}
end

-- Cambia la base conservando las piezas elegidas que sigan siendo compatibles (regla de la V3).
function DesignCalc.changeBase(g: any, d: any, baseId: string)
	local old = Catalog.base(d.baseId)
	local b = Catalog.base(baseId)
	if d.name == DesignCalc.autoName(g, old.id) then
		d.name = DesignCalc.autoName(g, b.id)
	end
	for _, c in Catalog.CATS do
		local cat = c[1]
		if d.parts[cat] == old.defaults[cat] then
			d.parts[cat] = b.defaults[cat]
		end
	end
	d.baseId = b.id
	DesignCalc.fixParts(d)
	local ch = Catalog.CHASSIS[d.chassis]
	if ch and ch.need and not Util.contains(b.tags, ch.need) then
		d.chassis = "Monocasco"
	end
end

function DesignCalc.designParts(d: any): { any }
	local out = {}
	for _, c in Catalog.CATS do
		local p = Catalog.part(c[1], d.parts[c[1]])
		if p then
			table.insert(out, p)
		end
	end
	return out
end

local function optCost(group: string, id: string): number
	local o = Catalog.bodyOpt(group, id)
	return o and o.cost or 0
end

local function intOpt(group: string, id: string): any
	for _, o in Catalog.INTERIOR[group] do
		if o[1] == id then
			return o
		end
	end
	return Catalog.INTERIOR[group][1]
end

-- Ítems de desarrollo: licencia del modelo base + prototipo de cada pieza distinta de la de serie.
-- Cada ítem se paga una sola vez por empresa (claves en g.devPaid).
-- Descuento del estudio de diseño (V3): 10 % por diseñador activo asignado, hasta 30 %.
function DesignCalc.designDiscount(g: any): number
	if not g or type(g.employees) ~= "table" then
		return 0
	end
	local n = 0
	for _, e in g.employees do
		if e.assign == "diseno" and e.status == "activo" then
			n += 1
		end
	end
	return math.min(0.3, n * 0.1 + (g.research and -Rules.tech(g, "devCostPct") / 100 or 0))
end

-- ¿Hay una pieza suelta en el inventario que cubra el desarrollo de este prototipo?
function DesignCalc.partInStock(g: any, cat: string, id: string): boolean
	if not g or type(g.parts) ~= "table" then
		return false
	end
	for _, p in g.parts do
		if p.cat == cat and p.id == id and (p.qty or 0) > 0 then
			return true
		end
	end
	return false
end

-- Ítems de desarrollo: licencia del modelo base + prototipo de cada pieza distinta de la de serie.
-- Cada ítem se paga una sola vez por empresa (claves en g.devPaid). Una pieza suelta del
-- inventario cubre su prototipo (se consume al guardar).
function DesignCalc.devItems(g: any, d: any): { any }
	local b = Catalog.base(d.baseId)
	local items = { { key = "base:" .. b.id, label = "Licencia del modelo " .. b.name, cost = b.dev } }
	for _, p in DesignCalc.designParts(d) do
		if p.proto > 0 and b.defaults[p.cat] ~= p.id then
			table.insert(items, { key = p.cat .. ":" .. p.id, label = "Prototipo: " .. p.name, cost = p.proto, cat = p.cat, part = p.id })
		end
	end
	local disc = DesignCalc.designDiscount(g)
	for _, it in items do
		it.cost = round(it.cost * (1 - disc))
		it.paid = g ~= nil and Util.contains(g.devPaid, it.key)
		it.stock = false
	end
	return items
end

function DesignCalc.devPending(g: any, d: any): number
	local total = 0
	for _, it in DesignCalc.devItems(g, d) do
		if not it.paid and not it.stock then
			total += it.cost
		end
	end
	return total
end

--[[ Estadísticas, costo por unidad y precio de referencia de un diseño con las tecnologías de la empresa.
	Las tecnologías investigadas se aplican a los cálculos nuevos (un lote ya lanzado conserva su copia). ]]
function DesignCalc.computeDesign(g: any, d: any): any
	local b = Catalog.base(d.baseId)
	local parts = DesignCalc.designParts(d)
	local fx = { hp = 0, kg = 0, grip = 0, brake = 0, comfort = 0, dur = 0, eff = 0, q = 0, safety = 0 }
	local function tech(key: string): number
		return Rules.tech(g, key)
	end
	local function add(effects: { [string]: number })
		for k, v in effects do
			fx[k] = (fx[k] or 0) + v
		end
	end
	for _, p in parts do
		add(p.fx)
	end
	for group in Catalog.INTERIOR do
		add(intOpt(group, d.interior[group])[4])
	end
	if d.interior.seats == "lux" then
		fx.kg += 15
	end
	local ch = Catalog.CHASSIS[d.chassis] or Catalog.CHASSIS.Monocasco
	fx.kg += ch.kg
	fx.grip += ch.grip
	fx.dur += ch.dur
	if d.spoiler then
		fx.kg += 8
		fx.grip += 3 + tech("spoilerGrip")
	end
	if d.body.diffuser == "carbon" then
		fx.grip += 1
	end
	fx.kg += (d.wheels.size - 16) * 6
	fx.grip += (d.wheels.size - 16) * 0.8
	fx.comfort -= math.max(0, d.wheels.size - 19) * 1.5

	local ev = Util.contains(b.tags, "electrico")
	local hp = math.max(50, fx.hp) * (1 + (ev and 0 or tech("hpPct")) / 100)
	local kg = math.max(700, (b.weight + fx.kg) * (1 + tech("kgPct") / 100))
	local tractionBonus = (d.parts.traccion == "awd" and 0.35) or (d.parts.traccion == "rwd" and 0.12) or (d.parts.traccion == "x4" and 0.15) or 0
	local accel = clamp(2.3 + (kg / hp) * 0.95 - tractionBonus - (ev and 0.5 or 0), 2.2, 20)
	local top = (110 + hp * 0.36 * math.sqrt(0.32 / b.drag) - (d.spoiler and 4 or 0) - (Util.contains(b.tags, "offroad") and 15 or 0)) * (1 + tech("topPct") / 100)
	if ev then
		top = math.min(top, 250)
	end
	local handling = clamp(b.handling + fx.grip + tech("handling") - (kg - 1300) / 60, 5, 100)
	local brakeIdx = 50 + fx.brake + tech("brake") + (d.parts.neumaticos == "slick" and 3 or 0)
	local stop = clamp(46 - brakeIdx * 0.2 + (kg - 1300) / 120, 28, 60)
	local consumption
	if ev then
		consumption = clamp(12 + kg * 0.003 + hp * 0.006 - fx.eff * 0.15, 10, 30)
	else
		consumption = clamp((4 + hp * 0.014 + kg * 0.0015 - fx.eff * 0.12) * (1 + tech("consPct") / 100), 3.5, 25)
	end
	local comfort = clamp(b.comfort + fx.comfort + tech("comfort"), 0, 100)
	local durability = clamp(b.durability + fx.dur + tech("durability"), 0, 100)
	local safety = clamp((b.safety or 40) + fx.safety + tech("safety") + (d.chassis == "Escalera" and 2 or 0), 0, 100)
	local fin = Catalog.FINISHES[d.paint.finish] or Catalog.FINISHES["Metálico"]
	local finishQ = (d.paint.finish == "Perlado" and 2) or (d.paint.finish == "Cromado" and 3) or 0
	local quality = clamp(b.quality + fx.q + d.quality * 3 + finishQ + tech("quality"), 0, 100)

	-- Costo por unidad (escala del catálogo × ECON.unitCostScale) con las mejoras de producción.
	local unitCost = b.unit + fin.unit + d.quality * 700 + math.max(0, d.wheels.size - 15) * 150 + (d.spoiler and 600 or 0)
	for _, p in parts do
		unitCost += p.unit
	end
	for group in Catalog.BODY_OPTS do
		unitCost += optCost(group, d.body[group])
	end
	for group in Catalog.INTERIOR do
		unitCost += intOpt(group, d.interior[group])[3]
	end
	unitCost += ch.unit
	unitCost = unitCost * Catalog.ECON.unitCostScale * (1 + tech("unitCostPct") / 100)

	local seg = Catalog.SEGMENTS[d.segment] or Catalog.SEGMENTS.Masivo
	local mats = Util.deepCopy(b.mats)
	if d.parts.motor == "v8" then
		mats.acero = (mats.acero or 0) + 2
	end
	if d.interior.material == "cuero" then
		mats.cuero = (mats.cuero or 0) + 1
	end
	-- Precio de referencia: lo que el mercado considera justo pagar por este auto.
	local premium = math.max(0, quality - 45) * 12 + hp * 2.5 + safety * 4
	local price = round(((unitCost * Catalog.ECON.priceMarkup + premium) * seg.price) / 10) * 10

	return {
		hp = round(hp),
		kg = round(kg),
		top = round(top),
		accel = round(accel * 10) / 10,
		handling = round(handling),
		stop = round(stop),
		consumption = round(consumption * 10) / 10,
		consUnit = ev and "kWh/100 km" or "L/100 km",
		comfort = round(comfort),
		durability = round(durability),
		safety = round(safety),
		quality = round(quality),
		unitCost = round(unitCost),
		build = 0,
		mats = mats,
		price = price,
		ev = ev,
	}
end

-- Generaciones: cada diseño tiene año de modelo y número de generación (ver Actions.saveDesign).

local function inList(list: { any }, value: any, index: number?): boolean
	for _, item in list do
		local v = if index then item[index] else item
		if v == value then
			return true
		end
	end
	return false
end

local function intIn(v: any, lo: number, hi: number): number?
	if not Util.isFiniteNumber(v) or v ~= math.floor(v) or v < lo or v > hi then
		return nil
	end
	return v
end

--[[
	Construye un borrador limpio a partir de lo que mande el cliente.
	Solo se copian campos conocidos con valores válidos del catálogo; cualquier otro dato se descarta.
	Devuelve (borrador, nil) o (nil, motivo).
]]
function DesignCalc.sanitize(g: any, raw: any): (any?, string?)
	if type(raw) ~= "table" then
		return nil, "El diseño no es válido."
	end
	local b = Catalog.base(raw.baseId)
	if not b then
		return nil, "Modelo base desconocido."
	end
	local why = DesignCalc.baseAvailable(g, b)
	if why then
		return nil, b.name .. ": " .. why
	end
	local d = DesignCalc.newDraft(g, b.id)

	if type(raw.name) ~= "string" then
		return nil, "Poné un nombre al proyecto."
	end
	local name = Util.trim(raw.name)
	if Util.charCount(name) < 2 or Util.charCount(name) > 24 then
		return nil, "El nombre del proyecto debe tener entre 2 y 24 caracteres."
	end
	if string.find(name, "[%c<>&]") then
		return nil, "El nombre del proyecto tiene caracteres no permitidos."
	end
	d.name = name

	local company = g.company.name
	if raw.brand == company or raw.brand == company .. " Sport" or raw.brand == company .. " Lux" then
		d.brand = raw.brand
	end
	-- Año de modelo y generación los fija el servidor al guardar (ver Actions.saveDesign).
	if type(raw.lineage) == "string" then
		d.lineage = raw.lineage
	end
	if Catalog.SEGMENTS[raw.segment] then
		d.segment = raw.segment
	end
	if Catalog.OBJECTIVES[raw.objective] then
		d.objective = raw.objective
	end
	local q = intIn(raw.quality, 0, 5)
	if q == nil then
		return nil, "Calidad de terminación inválida."
	end
	d.quality = q
	local ch = Catalog.CHASSIS[raw.chassis]
	if ch then
		if ch.need and not Util.contains(b.tags, ch.need) then
			return nil, "El chasis " .. raw.chassis .. " es solo para SUV y pickup."
		end
		d.chassis = raw.chassis
	end

	-- Piezas: cada categoría debe ser una pieza real, compatible y desbloqueada.
	local parts = type(raw.parts) == "table" and raw.parts or {}
	for _, c in Catalog.CATS do
		local cat = c[1]
		local id = parts[cat]
		if id == nil then
			id = b.defaults[cat]
		end
		local p = Catalog.part(cat, id)
		if not p then
			return nil, "Pieza desconocida en " .. c[2] .. "."
		end
		local block = DesignCalc.partBlock(g, d, p)
		if block then
			return nil, p.name .. ": " .. block
		end
		d.parts[cat] = p.id
	end

	-- Pintura y apariencia
	local paint = type(raw.paint) == "table" and raw.paint or {}
	if not Util.isHexColor(paint.primary) or not Util.isHexColor(paint.secondary) then
		return nil, "Color de pintura inválido."
	end
	d.paint.primary = string.upper(paint.primary)
	d.paint.secondary = string.upper(paint.secondary)
	local fin = Catalog.FINISHES[paint.finish]
	if not fin then
		return nil, "Acabado de pintura desconocido."
	end
	local fb = DesignCalc.finishBlock(g, paint.finish)
	if fb then
		return nil, "El acabado " .. paint.finish .. ": " .. fb .. "."
	end
	d.paint.finish = paint.finish
	d.paint.intensity = intIn(paint.intensity, 50, 130) or 100
	d.paint.gloss = intIn(paint.gloss, 0, 100) or 60

	local wheels = type(raw.wheels) == "table" and raw.wheels or {}
	local maxW = DesignCalc.maxWheel(g)
	local size = intIn(wheels.size, Catalog.WHEEL_SIZE.min, maxW)
	if size == nil then
		return nil, "Tamaño de ruedas inválido (" .. Catalog.WHEEL_SIZE.min .. "″ a " .. maxW .. "″ en " .. DesignCalc.year(g) .. ")."
	end
	d.wheels.size = size
	if inList(Catalog.WHEEL_STYLES, wheels.style, 1) then
		d.wheels.style = wheels.style
	end
	if inList(Catalog.RIM_COLORS, wheels.rim, 1) then
		d.wheels.rim = wheels.rim
	end
	if inList(Catalog.CALIPER_COLORS, raw.caliper, 1) then
		d.caliper = raw.caliper
	end
	if type(raw.spoiler) ~= "boolean" then
		return nil, "Valor del alerón inválido."
	end
	d.spoiler = raw.spoiler

	local body = type(raw.body) == "table" and raw.body or {}
	for group, opts in Catalog.BODY_OPTS do
		if inList(opts, body[group], 1) then
			local why = DesignCalc.optionBlock(g, Catalog.bodyOpt(group, body[group]))
			if why then
				return nil, Catalog.bodyOpt(group, body[group]).name .. ": " .. why .. "."
			end
			d.body[group] = body[group]
		end
	end
	if type(body.plate) == "string" then
		local plate = string.upper(body.plate):gsub("[^A-Z0-9 %-]", "")
		d.body.plate = string.sub(plate, 1, 9)
	end
	local interior = type(raw.interior) == "table" and raw.interior or {}
	for group, opts in Catalog.INTERIOR do
		if inList(opts, interior[group], 1) then
			local why = DesignCalc.optionBlock(g, Catalog.interiorOpt(group, interior[group]))
			if why then
				return nil, Catalog.interiorOpt(group, interior[group]).name .. ": " .. why .. "."
			end
			d.interior[group] = interior[group]
		end
	end
	if Util.isHexColor(interior.color) then
		d.interior.color = string.upper(interior.color)
	end
	return d, nil
end

-- Compara dos diseños solo por los campos que el jugador puede cambiar.
function DesignCalc.sameSpec(a: any, b: any): boolean
	local fields = { "name", "brand", "chassis", "segment", "objective", "quality", "baseId", "caliper", "spoiler" }
	for _, f in fields do
		if a[f] ~= b[f] then
			return false
		end
	end
	for _, grp in { "parts", "paint", "wheels", "body", "interior" } do
		local x, y = a[grp] or {}, b[grp] or {}
		for k, v in x do
			if y[k] ~= v then
				return false
			end
		end
		for k, v in y do
			if x[k] ~= v then
				return false
			end
		end
	end
	return true
end

return DesignCalc
