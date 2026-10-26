--!strict
--[[
	Car Empire Tycoon — catálogos y reglas (etapa 1).
	Portado de reference/Car-Empire-Tycoon-V3.html (bloque «catálogos y reglas del prototipo»).
	Los valores numéricos son los mismos que en la V3 para que precios y estadísticas coincidan.
	Este módulo es puro: no usa servicios de Roblox y se puede cargar desde las pruebas con Lune.
]]

local Catalog = {}

-- Calendario (parámetro central de equilibrio): un año de juego dura `realSecondsPerYear` segundos reales
-- a velocidad 1×. La simulación avanza en minutos de juego (10 por segundo real); un «período» interno
-- (g.time.day) es un MES del calendario.
Catalog.CALENDAR = { startYear = 1970, endYear = 2030, realSecondsPerYear = 660, months = 12 }

Catalog.RULES = {
	version = 3,
	minutesPerRealSecond = 10, -- a velocidad 1×, 1 s real = 10 min de juego
	-- Minutos de juego de un mes: 660 s/año × 10 min/s ÷ 12 = 550.
	dayMinutes = Catalog.CALENDAR.realSecondsPerYear * 10 / Catalog.CALENDAR.months,
	piBankMinutes = 3, -- PI que se acumulan sin investigación activa: hasta 3 minutos de generación
	maxLotQty = 1000000, -- tope técnico de un lote (la capacidad y el dinero son el límite real)
	maxActiveLots = 16, -- lotes produciendo o en venta a la vez
	maxLotHistory = 60, -- lotes agotados o retirados que se conservan con su resumen
	maxDesigns = 30,
	maxLedger = 200,
	statsDaysKept = 72, -- meses de agregados (6 años)
	slots = 3, -- empresas por cuenta
	slotsLocked = 2, -- ranuras visibles pero no habilitadas (función futura)
	moreCandidatesCost = 1000,
	assignMax = { station = 2, dept = 4 },
	speeds = { 0, 1, 2, 4 },
}

--[[ Economía (parámetros de equilibrio). Unidades: dinero en $, velocidades por MINUTO REAL a 1×.
	unitCostScale: los costos por unidad del catálogo (heredados de la V3) se multiplican por este factor
	para que fabricar cientos o miles de autos tenga sentido con el capital inicial. ]]
Catalog.ECON = {
	unitCostScale = 0.12,
	priceMarkup = 1.3, -- precio de referencia = costo × 1,3 + prima de calidad y prestaciones
	priceElasticity = 2.2, -- cuánto cambian las ventas con el precio respecto de la referencia
	appealScale = 12, -- puntos de atractivo que multiplican las ventas por e (≈ ×2,7)
	outsideWeight = 45, -- peso del «resto del mercado» (marcas chicas) en el reparto de la demanda
	eraBaseline = { [1970] = 50, [2030] = 75 }, -- atractivo medio que el mercado espera cada año
	priceMin = 0.5, -- precio mínimo = costo × 0,5 (vender a pérdida es posible pero se avisa)
	priceMax = 3, -- precio máximo = referencia × 3
	campaignBoost = 0.25, -- campaña publicitaria: +25 % de atractivo
	reputationStep = 0.08, -- cuánto se acerca la reputación cada mes al nivel que justifican tus ventas
	salesPiPer = 50, -- +1 PI por cada 50 autos vendidos…
	salesPiCapMinutes = 0.5, -- …con un tope de medio minuto de la generación de la sede por mes
	soldOutPiMinutes = 2, -- lote agotado con ganancia: +2 minutos de generación de PI
	researchMoneyPerPi = 600, -- costo en dinero de una investigación ($ por PI)
}

-- Investigación: duración objetivo por nivel de importancia (minutos reales con la sede esperada de la época).
Catalog.RESEARCH_TIERS = {
	s = { label = "Mejora pequeña", minutes = 1.5 },
	n = { label = "Mejora", minutes = 4 },
	i = { label = "Tecnología importante", minutes = 8 },
	b = { label = "Gran avance", minutes = 12.5 },
}
-- Generación de PI que se espera tener en cada época (para dimensionar los costos, no para dar PI).
Catalog.EXPECTED_PI = { { 1970, 3 }, { 1972, 8 }, { 1976, 20 }, { 1984, 45 }, { 1996, 90 }, { 2030, 90 } }

-- Las diferencias son solo las que la simulación aplica de verdad: dinero inicial,
-- paciencia de los clientes y frecuencia con que llegan al concesionario.
Catalog.DIFFICULTIES = {
	facil = { id = "facil", label = "Relajado", money = 150000, desc = "Más capital inicial y 15 % más de demanda.", demand = 1.15, dots = 1 },
	normal = { id = "normal", label = "Normal", money = 90000, desc = "Capital y demanda de referencia. La experiencia recomendada.", demand = 1, dots = 2 },
	dificil = { id = "dificil", label = "Magnate", money = 50000, desc = "Menos capital y 15 % menos de demanda. El primer lote tiene que ser chico.", demand = 0.85, dots = 3 },
}
Catalog.DIFFICULTY_ORDER = { "facil", "normal", "dificil" }

Catalog.BRAND_COLORS = {
	{ "#7667FF", "Violeta" },
	{ "#3B82F6", "Azul eléctrico" },
	{ "#42B8E5", "Celeste" },
	{ "#2E7D5B", "Verde bosque" },
	{ "#42E58D", "Verde neón" },
	{ "#F7C95C", "Oro" },
	{ "#FF8A3D", "Naranja" },
	{ "#FF5F68", "Rojo coral" },
	{ "#E8ECF2", "Blanco perla" },
}

Catalog.PAINTS = {
	{ "#4F5BD5", "Índigo" },
	{ "#E8ECF2", "Blanco perla" },
	{ "#15171C", "Negro carbón" },
	{ "#D6333F", "Rojo carrera" },
	{ "#F7C95C", "Amarillo" },
	{ "#42E58D", "Verde neón" },
	{ "#3B82F6", "Azul eléctrico" },
	{ "#8A5CF6", "Violeta" },
	{ "#C0C6D0", "Plata" },
	{ "#2E7D5B", "Verde bosque" },
	{ "#FF8A3D", "Naranja" },
	{ "#C9A86A", "Arena dorada" },
}

Catalog.FINISHES = {
	["Mate"] = { unit = 0, research = nil },
	["Metálico"] = { unit = 600, research = nil },
	["Perlado"] = { unit = 1400, research = "pr5" },
	["Cromado"] = { unit = 3200, research = "pr5" },
}
Catalog.FINISH_ORDER = { "Mate", "Metálico", "Perlado", "Cromado" }

Catalog.TYPES = {
	compacto = "Compacto",
	sedan = "Sedán",
	deportivo = "Deportivo",
	superdeportivo = "Superdeportivo",
	suv = "SUV",
	pickup = "Pickup",
	clasico = "Coupé",
	electrico = "Eléctrico",
}
Catalog.TYPE_ORDER = { "compacto", "sedan", "clasico", "pickup", "deportivo", "suv", "superdeportivo", "electrico" }

--[[ Demanda total del mercado por tipo (autos por minuto real a 1×), por año; se interpola entre años.
	El jugador se lleva una parte según el atractivo de sus autos frente a los rivales (Rules.marketShare). ]]
Catalog.DEMAND = {
	compacto = { { 1970, 189 }, { 1980, 216 }, { 1990, 234 }, { 2000, 252 }, { 2010, 252 }, { 2020, 234 }, { 2030, 216 } },
	sedan = { { 1970, 234 }, { 1980, 252 }, { 1990, 270 }, { 2000, 270 }, { 2010, 252 }, { 2020, 225 }, { 2030, 202 } },
	clasico = { { 1970, 81 }, { 1980, 68 }, { 1990, 54 }, { 2000, 43 }, { 2010, 34 }, { 2020, 27 }, { 2030, 22 } },
	pickup = { { 1970, 99 }, { 1980, 117 }, { 1990, 135 }, { 2000, 153 }, { 2010, 162 }, { 2020, 162 }, { 2030, 153 } },
	deportivo = { { 1970, 50 }, { 1980, 63 }, { 1990, 76 }, { 2000, 86 }, { 2010, 90 }, { 2020, 90 }, { 2030, 86 } },
	suv = { { 1970, 0 }, { 1982, 0 }, { 1983, 14 }, { 1990, 81 }, { 2000, 189 }, { 2010, 270 }, { 2020, 315 }, { 2030, 324 } },
	superdeportivo = { { 1970, 7 }, { 1980, 9 }, { 1990, 14 }, { 2000, 18 }, { 2010, 22 }, { 2020, 25 }, { 2030, 27 } },
	electrico = { { 1970, 0 }, { 2009, 0 }, { 2012, 18 }, { 2020, 135 }, { 2030, 292 } },
}

--[[ Vehículos base. year = año desde el que existe la plataforma; research = tecnología que la habilita.
	Costos por unidad en la escala del catálogo (se multiplican por ECON.unitCostScale). safety = seguridad de serie. ]]
Catalog.BASES = {
	{ id = "pixel", name = "Pixel C1", brand = "Nordia", type = "compacto", level = 1, year = 1970, research = nil, rarity = "Común",
		dev = 12000, unit = 7800, weight = 1080, handling = 58, comfort = 60, durability = 80, quality = 55, safety = 40, drag = 0.33, build = 150,
		tags = { "combustion" }, mats = { acero = 6, aluminio = 2, pintura = 1, electronica = 1 }, pop = 1.2,
		defaults = { motor = "i4", turbo = "none", transmision = "man4", traccion = "fwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none" } },
	{ id = "brisa", name = "Brisa Sedán", brand = "Vortex", type = "sedan", level = 1, year = 1970, research = nil, rarity = "Común",
		dev = 16000, unit = 10500, weight = 1350, handling = 60, comfort = 72, durability = 82, quality = 60, safety = 45, drag = 0.29, build = 180,
		tags = { "combustion" }, mats = { acero = 8, aluminio = 3, pintura = 1, electronica = 1 }, pop = 1.1,
		defaults = { motor = "i4", turbo = "none", transmision = "auto3", traccion = "fwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none" } },
	{ id = "toro", name = "Toro Pickup", brand = "Kodiak", type = "pickup", level = 1, year = 1970, research = nil, rarity = "Común",
		dev = 14000, unit = 9800, weight = 1750, handling = 46, comfort = 52, durability = 92, quality = 56, safety = 38, drag = 0.40, build = 230,
		tags = { "combustion", "offroad" }, mats = { acero = 13, aluminio = 2, pintura = 2, electronica = 1 }, pop = 0.95,
		defaults = { motor = "v6", turbo = "none", transmision = "man4", traccion = "x4", frenos = "std", suspension = "offroad", neumaticos = "at", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none" } },
	{ id = "duna", name = "Duna Coupé", brand = "Halcón", type = "clasico", level = 1, year = 1970, research = nil, rarity = "Rara",
		dev = 22000, unit = 12500, weight = 1320, handling = 62, comfort = 64, durability = 72, quality = 64, safety = 40, drag = 0.36, build = 260,
		tags = { "combustion" }, mats = { acero = 9, aluminio = 2, pintura = 2, electronica = 1, cuero = 2 }, pop = 0.9,
		defaults = { motor = "v6", turbo = "none", transmision = "man4", traccion = "rwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "sport", peso = "none" } },
	{ id = "aurora", name = "Aurora GT", brand = "Vortex", type = "deportivo", level = 1, year = 1975, research = "ca2", rarity = "Rara",
		dev = 30000, unit = 16500, weight = 1380, handling = 74, comfort = 55, durability = 74, quality = 66, safety = 42, drag = 0.30, build = 240,
		tags = { "combustion" }, mats = { acero = 7, aluminio = 5, pintura = 1, electronica = 2 }, pop = 1.0,
		defaults = { motor = "v6", turbo = "none", transmision = "man4", traccion = "rwd", frenos = "sport", suspension = "sport", neumaticos = "sport", bateria = "b12", refrigeracion = "std", escape = "sport", peso = "none" } },
	{ id = "titan", name = "Titán SUV", brand = "Kodiak", type = "suv", level = 1, year = 1983, research = "ca3", rarity = "Común",
		dev = 26000, unit = 15000, weight = 1850, handling = 52, comfort = 74, durability = 86, quality = 62, safety = 55, drag = 0.36, build = 230,
		tags = { "combustion", "offroad" }, mats = { acero = 11, aluminio = 3, pintura = 2, electronica = 2 }, pop = 1.05,
		defaults = { motor = "v6", turbo = "none", transmision = "auto3", traccion = "x4", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none" } },
	{ id = "vento", name = "Halcón Vento SS", brand = "Halcón", type = "superdeportivo", level = 1, year = 1986, research = "ca4", rarity = "Legendaria",
		dev = 90000, unit = 42000, weight = 1450, handling = 84, comfort = 44, durability = 66, quality = 80, safety = 50, drag = 0.27, build = 360,
		tags = { "combustion" }, mats = { acero = 5, aluminio = 9, pintura = 2, electronica = 3 }, pop = 0.7,
		defaults = { motor = "v8", turbo = "none", transmision = "man5", traccion = "rwd", frenos = "sport", suspension = "sport", neumaticos = "sport", bateria = "b12", refrigeracion = "pro", escape = "sport", peso = "none" } },
	{ id = "rayo", name = "Rayo E", brand = "Kairo", type = "electrico", level = 1, year = 2010, research = "el5", rarity = "Rara",
		dev = 38000, unit = 19000, weight = 1720, handling = 66, comfort = 76, durability = 84, quality = 70, safety = 70, drag = 0.24, build = 250,
		tags = { "electrico" }, mats = { acero = 6, aluminio = 5, pintura = 1, electronica = 4, baterias = 8 }, pop = 1.0,
		defaults = { motor = "em200", turbo = "none", transmision = "single", traccion = "rwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "ev60", refrigeracion = "std", escape = "none", peso = "none" } },
}

Catalog.CATS = {
	{ "motor", "Motor" },
	{ "turbo", "Sobrealimentación" },
	{ "transmision", "Transmisión" },
	{ "traccion", "Tracción" },
	{ "frenos", "Frenos" },
	{ "suspension", "Suspensión" },
	{ "neumaticos", "Neumáticos" },
	{ "bateria", "Batería" },
	{ "refrigeracion", "Refrigeración" },
	{ "escape", "Escape" },
	{ "peso", "Peso" },
}

--[[ Piezas por categoría
	year  = año en que la pieza existe en el mercado; research = tecnología que la habilita
	proto = costo único de desarrollo del prototipo (se paga una sola vez por empresa al guardar)
	unit  = costo agregado a la fabricación de cada unidad (escala del catálogo)
	fx    = efectos: hp, kg, grip, brake, comfort, dur, eff, q, safety
	need  = etiqueta requerida en la base ("combustion", "electrico", "offroad") ]]
local function P(id, cat, name, rarity, year, research, proto, unit, need, fx, desc)
	return { id = id, cat = cat, name = name, rarity = rarity, level = 1, year = year, research = research, proto = proto, unit = unit, need = need, fx = fx, desc = desc }
end

Catalog.PARTS = {
	-- Motor
	P("i4", "motor", "4 cilindros 1.6", "Común", 1970, nil, 0, 2200, "combustion", { hp = 95, kg = 0, eff = 4, dur = 4 }, "Económico y confiable."),
	P("v6", "motor", "V6 2.8", "Rara", 1970, nil, 6000, 4800, "combustion", { hp = 150, kg = 60, eff = -4, q = 2 }, "Más fuerza para sedanes y pickups."),
	P("v8", "motor", "V8 5.0", "Épica", 1970, "mo2", 18000, 9500, "combustion", { hp = 230, kg = 110, eff = -10, q = 4, dur = -3 }, "Gran cilindrada para deportivos."),
	P("em200", "motor", "Motor eléctrico 200 kW", "Rara", 2010, "el5", 8000, 6000, "electrico", { hp = 270, kg = 40, eff = 10, dur = 4 }, "Silencioso, par inmediato."),
	P("em350", "motor", "Motor eléctrico 350 kW", "Épica", 2016, "el6", 20000, 11000, "electrico", { hp = 470, kg = 70, eff = 4, q = 4 }, "Doble motor de alto rendimiento."),
	-- Sobrealimentación
	P("none", "turbo", "Aspiración natural", "Común", 1970, nil, 0, 0, nil, {}, "Sin turbo ni compresor."),
	P("t1", "turbo", "Turbocompresor simple", "Común", 1977, "mo3", 3000, 1400, "combustion", { hp = 30, eff = -2, dur = -1 }, "Más potencia con poco costo."),
	P("s3", "turbo", "Compresor volumétrico", "Épica", 1985, "mo5", 15000, 4200, "combustion", { hp = 60, eff = -6, dur = -3, q = 3 }, "Respuesta inmediata."),
	P("t2", "turbo", "Turbo twin-scroll", "Rara", 1996, "mo7", 7500, 2600, "combustion", { hp = 55, eff = -1, dur = -1, q = 2 }, "Doble entrada, menos retardo."),
	-- Transmisión
	P("man4", "transmision", "Manual 4 vel.", "Común", 1970, nil, 0, 700, "combustion", { eff = 1, comfort = -4 }, "La caja de la época."),
	P("auto3", "transmision", "Automática 3 vel.", "Común", 1970, nil, 2500, 1500, "combustion", { comfort = 4, eff = -3, kg = 20 }, "Cómoda pero gasta más."),
	P("man5", "transmision", "Manual 5 vel.", "Común", 1977, "tr1", 1500, 800, "combustion", { eff = 3, comfort = -3 }, "Una marcha más larga para la ruta."),
	P("auto4", "transmision", "Automática 4 vel. con overdrive", "Común", 1984, "tr3", 3000, 1700, "combustion", { comfort = 6, eff = 0, kg = 18 }, "Automática que ya no castiga el consumo."),
	P("dct7", "transmision", "Doble embrague 7", "Rara", 2003, "tr4", 6500, 2800, "combustion", { grip = 3, comfort = 2, q = 2, kg = 10, eff = 2 }, "Cambios instantáneos."),
	P("auto8", "transmision", "Automática 8 vel.", "Común", 2008, "tr5", 3500, 1900, "combustion", { comfort = 7, eff = 4, kg = 15 }, "Suave y eficiente."),
	P("single", "transmision", "Reducción única", "Común", 2010, "el5", 0, 900, "electrico", { comfort = 4 }, "Transmisión de los eléctricos."),
	-- Tracción
	P("fwd", "traccion", "Delantera", "Común", 1970, nil, 0, 0, nil, { eff = 2 }, "Ligera y económica."),
	P("rwd", "traccion", "Trasera", "Común", 1970, nil, 2000, 600, nil, { grip = 4 }, "Mejor reparto para deportivos."),
	P("x4", "traccion", "4x4 con reductora", "Rara", 1970, nil, 5500, 2000, "offroad", { grip = 3, kg = 90, dur = 6, eff = -3 }, "Solo para SUV y pickup."),
	P("awd", "traccion", "Integral permanente", "Rara", 1982, "tr2", 6000, 2200, nil, { grip = 8, kg = 70, eff = -2, safety = 3 }, "Agarre en cualquier clima."),
	-- Frenos
	P("std", "frenos", "Discos delanteros", "Común", 1970, nil, 0, 500, nil, { brake = 0 }, "Discos adelante y tambores atrás."),
	P("sport", "frenos", "Discos ventilados", "Rara", 1970, nil, 3500, 1300, nil, { brake = 6, q = 1 }, "Pinzas de 4 pistones."),
	P("abs", "frenos", "Frenos con ABS", "Rara", 1986, "se3", 5000, 1600, nil, { brake = 7, safety = 10, q = 1 }, "No se bloquean al frenar fuerte."),
	P("ceram", "frenos", "Carbono-cerámicos", "Épica", 2003, "ma6", 12000, 4200, nil, { brake = 12, kg = -12, q = 3, safety = 4 }, "No pierden eficacia al calentarse."),
	-- Suspensión
	P("confort", "suspension", "Confort", "Común", 1970, nil, 0, 600, nil, { comfort = 6, grip = -2 }, "Prioriza la marcha suave."),
	P("sport", "suspension", "Deportiva", "Rara", 1970, nil, 4000, 1400, nil, { grip = 7, comfort = -6 }, "Más firme y baja."),
	P("offroad", "suspension", "Todoterreno elevada", "Rara", 1970, nil, 5000, 1700, "offroad", { dur = 8, comfort = 2, grip = -3 }, "Más recorrido para caminos rotos."),
	P("air", "suspension", "Neumática", "Épica", 1994, "co5", 9000, 3200, nil, { comfort = 12, grip = 2, kg = 25, q = 3 }, "Altura y dureza ajustables."),
	-- Neumáticos
	P("touring", "neumaticos", "Radiales de calle", "Común", 1970, nil, 0, 400, nil, { comfort = 3, eff = 2 }, "Silenciosos y duraderos."),
	P("at", "neumaticos", "Todo terreno A/T", "Común", 1970, nil, 1500, 700, "offroad", { dur = 4, grip = -2 }, "Para barro y ripio."),
	P("sport", "neumaticos", "Deportivos", "Común", 1975, nil, 1500, 800, nil, { grip = 6, brake = 3, comfort = -2 }, "Más agarre en seco."),
	P("slick", "neumaticos", "Semi-slick", "Rara", 1990, nil, 4000, 1500, nil, { grip = 11, brake = 5, comfort = -8, dur = -4 }, "Casi de competición."),
	-- Batería
	P("b12", "bateria", "Batería 12 V", "Común", 1970, nil, 0, 150, "combustion", {}, "Arranque y accesorios."),
	P("mhev", "bateria", "Sistema híbrido", "Rara", 2006, "el4", 7000, 1800, "combustion", { eff = 10, hp = 15, kg = 40, q = 2 }, "Recupera energía al frenar."),
	P("ev60", "bateria", "Batería de litio 60 kWh", "Común", 2010, "el5", 0, 5200, "electrico", { kg = 380, eff = 4 }, "Autonomía urbana."),
	P("ev80", "bateria", "Batería de litio 80 kWh", "Rara", 2016, "el6", 10000, 7600, "electrico", { kg = 470, eff = 9, q = 2 }, "Más autonomía para rutas."),
	P("ssb", "bateria", "Estado sólido 90 kWh", "Épica", 2024, "el7", 24000, 11000, "electrico", { kg = 330, eff = 15, q = 5, safety = 3 }, "Más liviana y segura."),
	-- Refrigeración
	P("std", "refrigeracion", "Estándar", "Común", 1970, nil, 0, 300, nil, {}, "Suficiente para uso normal."),
	P("pro", "refrigeracion", "Radiador ampliado", "Rara", 1975, nil, 3000, 900, nil, { dur = 5, hp = 8 }, "Más margen para motores grandes."),
	P("race", "refrigeracion", "Competición", "Épica", 1978, "ma2", 8000, 1800, nil, { dur = 9, hp = 15, comfort = -2 }, "Intercoolers y tomas de aire."),
	-- Escape
	P("none", "escape", "Sin escape", "Común", 2010, nil, 0, 0, "electrico", {}, "Los eléctricos no usan escape."),
	P("std", "escape", "Escape estándar", "Común", 1970, nil, 0, 400, "combustion", { comfort = 2 }, "Silencioso."),
	P("sport", "escape", "Escape deportivo", "Común", 1970, nil, 2000, 900, "combustion", { hp = 10, comfort = -2 }, "Mejor sonido y flujo."),
	P("ti", "escape", "Escape de titanio", "Rara", 1997, "ma4", 6000, 2100, "combustion", { hp = 18, kg = -14, q = 2 }, "Liviano y resistente."),
	-- Peso
	P("none", "peso", "Sin reducción", "Común", 1970, nil, 0, 0, nil, {}, "Carrocería de serie."),
	P("lite", "peso", "Paneles de aluminio (−40 kg)", "Común", 1985, "ma3", 4000, 900, nil, { kg = -40, comfort = -1 }, "Capó y puertas de aluminio."),
	P("carbon", "peso", "Fibra de carbono (−90 kg)", "Épica", 2000, "ma5", 14000, 3800, nil, { kg = -90, q = 3 }, "Techo, capó y paneles de carbono."),
}

-- Nombres de investigaciones (se completan con el árbol al final del módulo; quedan los de versiones viejas).
Catalog.RESEARCH_NAMES = {}

--[[ Carrocería e interior: { id, nombre, costo por unidad, año, investigación } ]]
Catalog.BODY_OPTS = {
	bumper = { { "serie", "De serie", 0 }, { "sport", "Sport con labio", 900, 1975 }, { "offroad", "Todoterreno con defensa", 1100 } },
	hood = { { "serie", "De serie", 0 }, { "vent", "Con tomas de aire", 700 }, { "carbon", "Carbono a la vista", 1600, 2000, "ma5" } },
	diffuser = { { "none", "Sin difusor", 0 }, { "carbon", "Difusor de carbono", 1200, 2000, "ma5" } },
	skirts = { { "none", "Sin faldones", 0 }, { "low", "Faldones bajos", 600, 1980 } },
	lights = { { "amber", "Faros halógenos", 0 }, { "white", "Faros LED", 400, 2004, "el3" }, { "blue", "LED azul hielo", 600, 2004, "el3" } },
	tint = { { "clear", "Transparentes", 0 }, { "t30", "Polarizado 30%", 250, 1975 }, { "t70", "Polarizado 70%", 400, 1985 } },
	vinyl = { { "none", "Sin vinilos", 0 }, { "stripes", "Franjas dobles", 500 }, { "side", "Franja lateral", 400 } },
	number = { { "none", "Sin número", 0 }, { "27", "Número 27", 150 }, { "8", "Número 8", 150 } },
	logo = { { "on", "Emblema en el frente", 0 }, { "off", "Sin emblema", 0 } },
}
Catalog.BODY_DEFAULTS = { bumper = "serie", hood = "serie", diffuser = "none", skirts = "none", lights = "amber", tint = "clear", vinyl = "none", number = "none", logo = "on", plate = "CET 001" }

-- { id, nombre, costo por unidad, efectos, año, investigación }
Catalog.INTERIOR = {
	seats = { { "serie", "De serie", 0, {} }, { "sport", "Butacas deportivas", 1800, { comfort = -3, grip = 1, q = 1 }, 1976, "co2" }, { "lux", "Confort con masaje", 2600, { comfort = 7, q = 2 }, 2001, "co6" } },
	material = { { "tela", "Tela", 0, {} }, { "cuero", "Cuero", 1500, { comfort = 3, q = 3 } }, { "alcantara", "Alcántara", 1900, { q = 3 }, 1990, "co4" } },
	wheel = { { "serie", "Volante de serie", 0, {} }, { "flat", "Volante deportivo", 500, { q = 1 }, 1975 } },
	dash = { { "analog", "Analógico", 0, {} }, { "digital", "Tablero digital", 1400, { q = 2, comfort = 1 }, 2010, "co7" } },
	ambient = { { "off", "Sin luz ambiental", 0, {} }, { "violet", "Violeta", 350, { comfort = 1 }, 2010, "co7" }, { "white", "Blanca cálida", 350, { comfort = 1 }, 2010, "co7" }, { "cyan", "Cian", 350, { comfort = 1 }, 2010, "co7" } },
}
Catalog.INTERIOR_DEFAULTS = { seats = "serie", material = "tela", color = "#1A1B1F", wheel = "serie", dash = "analog", ambient = "off" }

Catalog.WHEEL_STYLES = { { "radial5", "Radial 5 rayos" }, { "mesh", "Malla 10 rayos" }, { "solid", "Aero cerrada" } }
Catalog.RIM_COLORS = { { "#C9CED8", "Plata" }, { "#2A2E38", "Grafito" }, { "#F5F7FA", "Cromo" }, { "#C9A86A", "Bronce" } }
Catalog.CALIPER_COLORS = { { "#F7C95C", "Amarillo" }, { "#D6333F", "Rojo" }, { "#42E58D", "Verde" }, { "#3B82F6", "Azul" }, { "#5D6371", "Gris" } }
-- Rodado: el máximo crece con los años (llantas grandes son de autos modernos).
Catalog.WHEEL_SIZE = { min = 13, max = 22, maxByYear = { { 1970, 15 }, { 1985, 16 }, { 1995, 17 }, { 2002, 19 }, { 2010, 21 }, { 2016, 22 } } }

Catalog.CHASSIS = {
	Monocasco = { kg = 0, grip = 0, dur = 0, unit = 0, need = nil },
	Tubular = { kg = -25, grip = 3, dur = -2, unit = 900, need = nil },
	Escalera = { kg = 70, grip = -3, dur = 7, unit = 400, need = "offroad" },
}
Catalog.CHASSIS_ORDER = { "Monocasco", "Tubular", "Escalera" }
Catalog.SEGMENTS = {
	Masivo = { price = 1, pop = 1 },
	Premium = { price = 1.12, pop = 0.6 },
	Lujo = { price = 1.28, pop = 0.35 },
}
Catalog.SEGMENT_ORDER = { "Masivo", "Premium", "Lujo" }
Catalog.OBJECTIVES = {
	["Económico"] = "economia",
	["Familiar"] = "comodidad",
	["Deportivo"] = "potencia",
	["Lujo"] = "estilo",
	["Todoterreno"] = "comodidad",
	["Competición"] = "potencia",
}
Catalog.OBJECTIVE_ORDER = { "Económico", "Familiar", "Deportivo", "Lujo", "Todoterreno", "Competición" }
-- Qué mira el comprador según el objetivo del auto (pesos de cada índice 0–100).
Catalog.OBJECTIVE_WEIGHTS = {
	["Económico"] = { eco = 0.6, dur = 0.2, safety = 0.2 },
	["Familiar"] = { comfort = 0.4, safety = 0.4, dur = 0.2 },
	["Deportivo"] = { power = 0.6, hand = 0.4 },
	["Lujo"] = { comfort = 0.5, quality = 0.3, safety = 0.2 },
	["Todoterreno"] = { dur = 0.6, comfort = 0.2, hand = 0.2 },
	["Competición"] = { power = 0.5, hand = 0.5 },
}
Catalog.QUALITY_TIERS = { "C", "C+", "B", "B+", "A", "S" } -- índice = calidad + 1

-- Materiales: ya no se compran por separado (su costo está incluido en el costo por unidad). Se
-- conservan los nombres para leer partidas viejas y mostrar la composición de cada auto.
Catalog.MATERIALS = {
	{ "acero", "Acero", 40 },
	{ "aluminio", "Aluminio", 95 },
	{ "pintura", "Pintura", 120 },
	{ "electronica", "Electrónica", 260 },
	{ "baterias", "Baterías", 420 },
	{ "cuero", "Cuero", 180 },
}

--[[ Sedes. La sede define la capacidad de la fábrica (líneas × autos por minuto de cada línea), el alcance
	comercial (cuántos concesionarios venden tus autos) y la generación de puntos de investigación (PI/min). ]]
Catalog.SEDES = {
	{ level = 1, name = "Garaje inicial", lines = 1, perLine = 15, reach = 1, pi = 3, staff = 3, campaign = 4000, cost = 0, req = { sold = 0, rep = 0 } },
	{ level = 2, name = "Empresa pequeña", lines = 2, perLine = 20, reach = 2.5, pi = 8, staff = 8, campaign = 12000, cost = 300000, req = { sold = 300, rep = 3.0 } },
	{ level = 3, name = "Sede empresarial", lines = 3, perLine = 35, reach = 6, pi = 20, staff = 16, campaign = 35000, cost = 2500000, req = { sold = 3000, rep = 3.4 } },
	{ level = 4, name = "Corporación automotriz", lines = 4, perLine = 60, reach = 14, pi = 45, staff = 30, campaign = 90000, cost = 18000000, req = { sold = 25000, rep = 3.9 } },
	{ level = 5, name = "Imperio automotriz", lines = 5, perLine = 100, reach = 30, pi = 90, staff = 50, campaign = 220000, cost = 100000000, req = { sold = 150000, rep = 4.3 } },
}

-- Estaciones de la fábrica (mejoras): cada nivel suma velocidad de producción. { id, nombre, rol ideal }
Catalog.STATIONS = {
	{ "chasis", "Chasis", "Mecánico" },
	{ "pintura", "Pintura", "Mecánico" },
	{ "motor", "Motor", "Ingeniero" },
	{ "interior", "Interior", "Diseñador" },
	{ "calidad", "Control de calidad", "Inspector" },
	{ "entrega", "Logística", "Mecánico" },
}
Catalog.STATION_SPEED = 0.06 -- +6 % de producción por nivel de cada estación por encima del 1
-- Departamentos: { id, nombre, rol ideal, efecto }. El personal es una ayuda secundaria: nunca obligatorio.
Catalog.ROLES = { "Mecánico", "Ingeniero", "Diseñador", "Inspector", "Vendedor", "Marketing", "Gerente" }
Catalog.FIRST = { "Sofía", "Mateo", "Lara", "Julián", "Carla", "Ramiro", "Elena", "Diego", "Ana", "Pablo", "Inés", "Tomás", "Valentina", "Bruno", "Camila", "Martina", "Lucía", "Joaquín", "Abril", "Nicolás" }
Catalog.LAST = { "Arce", "Ruiz", "Sosa", "Paz", "Vega", "Gil", "Bruno", "Mora", "Núñez", "Ortiz", "Ríos", "Pereyra", "Luna", "Ferrari", "Medina", "Romero" }

Catalog.DEPARTMENTS = {
	{ "laboratorio", "Laboratorio", "Ingeniero", "Suma PI por minuto (secundario: la sede es la fuente principal)" },
	{ "ventas", "Ventas", "Vendedor", "Más atractivo comercial" },
	{ "marketing", "Marketing", "Marketing", "Más demanda" },
	{ "diseno", "Estudio de diseño", "Diseñador", "Baja el costo de desarrollo" },
}

--[[ Árbol tecnológico 1970–2030. Cada nodo:
	year = primer año en que se puede investigar · tier = s/n/i/b (pequeña, normal, importante, gran avance)
	req = tecnologías previas · fx = efectos reales (se suman con Rules.tech):
	  hpPct, consPct, comfort, quality, safety, handling, durability, topPct, kgPct, brake,
	  prodSpeed (%), unitCostPct (%), demand (%), devCostPct (%), repGain (%), spoilerGrip, campaign (habilita)
	Las piezas, bases y opciones que nombran el id del nodo en `research` se desbloquean al completarlo.
	rp (PI) y cost ($) se calculan con el año y el nivel (ver al final del módulo). ]]
Catalog.RESEARCH_ORDER = { "motores", "carrocerias", "transmisiones", "seguridad", "confort", "produccion", "electronica", "materiales", "marketing" }
Catalog.RESEARCH = {
	motores = { label = "Motores", nodes = {
		{ id = "mo1", name = "Carburador de doble cuerpo", year = 1970, tier = "s", req = {}, fx = { hpPct = 5 }, gain = "+5 % de potencia en motores a combustión" },
		{ id = "mo2", name = "V8 de gran cilindrada", year = 1970, tier = "i", req = {}, fx = {}, gain = "Habilita el motor V8 5.0" },
		{ id = "mo3", name = "Turbocompresor", year = 1977, tier = "n", req = { "mo1" }, fx = {}, gain = "Habilita el turbocompresor simple" },
		{ id = "mo4", name = "Inyección electrónica", year = 1983, tier = "i", req = { "mo1" }, fx = { hpPct = 6, consPct = -8 }, gain = "+6 % de potencia y −8 % de consumo" },
		{ id = "mo5", name = "Compresor volumétrico", year = 1985, tier = "n", req = { "mo3" }, fx = {}, gain = "Habilita el compresor volumétrico" },
		{ id = "mo6", name = "Distribución variable", year = 1993, tier = "n", req = { "mo4" }, fx = { hpPct = 5, consPct = -5 }, gain = "+5 % de potencia y −5 % de consumo" },
		{ id = "mo7", name = "Turbo twin-scroll", year = 1996, tier = "n", req = { "mo3" }, fx = {}, gain = "Habilita el turbo twin-scroll" },
		{ id = "mo8", name = "Inyección directa", year = 2006, tier = "i", req = { "mo6" }, fx = { hpPct = 5, consPct = -8 }, gain = "+5 % de potencia y −8 % de consumo" },
	} },
	carrocerias = { label = "Carrocerías", nodes = {
		{ id = "ca1", name = "Carrocería reforzada", year = 1970, tier = "s", req = {}, fx = { durability = 4, safety = 2 }, gain = "+4 de durabilidad y +2 de seguridad" },
		{ id = "ca2", name = "Plataforma de coupé deportivo", year = 1975, tier = "n", req = {}, fx = {}, gain = "Habilita el Aurora GT (deportivo)" },
		{ id = "ca3", name = "Plataforma SUV", year = 1983, tier = "i", req = { "ca1" }, fx = {}, gain = "Habilita el Titán SUV" },
		{ id = "ca4", name = "Superdeportivo de motor central", year = 1986, tier = "b", req = { "mo2", "ca2" }, fx = {}, gain = "Habilita el Halcón Vento SS" },
		{ id = "ca5", name = "Plataforma modular", year = 2002, tier = "i", req = { "ca3" }, fx = { unitCostPct = -6, quality = 2 }, gain = "−6 % de costo por unidad y +2 de calidad" },
	} },
	transmisiones = { label = "Transmisiones y tracción", nodes = {
		{ id = "tr1", name = "Caja manual de 5 velocidades", year = 1977, tier = "s", req = {}, fx = {}, gain = "Habilita la caja manual de 5 velocidades" },
		{ id = "tr2", name = "Tracción integral permanente", year = 1982, tier = "i", req = {}, fx = {}, gain = "Habilita la tracción integral" },
		{ id = "tr3", name = "Automática con overdrive", year = 1984, tier = "n", req = { "tr1" }, fx = {}, gain = "Habilita la automática de 4 velocidades" },
		{ id = "tr4", name = "Doble embrague", year = 2003, tier = "i", req = { "tr3" }, fx = {}, gain = "Habilita la caja de doble embrague" },
		{ id = "tr5", name = "Automática de 8 velocidades", year = 2008, tier = "n", req = { "tr3" }, fx = {}, gain = "Habilita la automática de 8 velocidades" },
	} },
	seguridad = { label = "Seguridad", nodes = {
		{ id = "se1", name = "Cinturones de tres puntos", year = 1970, tier = "s", req = {}, fx = { safety = 8 }, gain = "+8 de seguridad en todos los autos" },
		{ id = "se2", name = "Zonas de deformación", year = 1977, tier = "n", req = { "se1" }, fx = { safety = 10 }, gain = "+10 de seguridad" },
		{ id = "se3", name = "Frenos ABS", year = 1986, tier = "i", req = { "se2" }, fx = {}, gain = "Habilita frenos con ABS" },
		{ id = "se4", name = "Bolsas de aire", year = 1989, tier = "i", req = { "se2" }, fx = { safety = 15 }, gain = "+15 de seguridad" },
		{ id = "se5", name = "Control de estabilidad", year = 1998, tier = "n", req = { "se3" }, fx = { safety = 8, handling = 4 }, gain = "+8 de seguridad y +4 de manejo" },
		{ id = "se6", name = "Asistentes de conducción", year = 2014, tier = "b", req = { "se5" }, fx = { safety = 14, quality = 3 }, gain = "+14 de seguridad y +3 de calidad" },
	} },
	confort = { label = "Comodidad e interiores", nodes = {
		{ id = "co1", name = "Aire acondicionado", year = 1972, tier = "s", req = {}, fx = { comfort = 6 }, gain = "+6 de comodidad" },
		{ id = "co2", name = "Butacas deportivas", year = 1976, tier = "s", req = {}, fx = {}, gain = "Habilita butacas deportivas" },
		{ id = "co3", name = "Dirección asistida", year = 1979, tier = "n", req = { "co1" }, fx = { comfort = 4, handling = 2 }, gain = "+4 de comodidad y +2 de manejo" },
		{ id = "co4", name = "Tapizados premium", year = 1990, tier = "n", req = { "co3" }, fx = { quality = 1 }, gain = "Habilita Alcántara y +1 de calidad" },
		{ id = "co5", name = "Suspensión neumática", year = 1994, tier = "i", req = { "co3" }, fx = {}, gain = "Habilita la suspensión neumática" },
		{ id = "co6", name = "Asientos con masaje", year = 2001, tier = "n", req = { "co4" }, fx = {}, gain = "Habilita asientos con masaje" },
		{ id = "co7", name = "Tablero digital", year = 2010, tier = "i", req = { "co6" }, fx = { quality = 2 }, gain = "Habilita tablero digital y luz ambiental; +2 de calidad" },
	} },
	produccion = { label = "Producción industrial", nodes = {
		{ id = "pr1", name = "Línea de montaje optimizada", year = 1970, tier = "s", req = {}, fx = { prodSpeed = 10 }, gain = "+10 % de velocidad de producción" },
		{ id = "pr2", name = "Control de calidad estadístico", year = 1974, tier = "n", req = { "pr1" }, fx = { quality = 3 }, gain = "+3 de calidad en los autos nuevos" },
		{ id = "pr3", name = "Robots de soldadura", year = 1982, tier = "i", req = { "pr1" }, fx = { prodSpeed = 20, unitCostPct = -4 }, gain = "+20 % de producción y −4 % de costo por unidad" },
		{ id = "pr4", name = "Producción justo a tiempo", year = 1990, tier = "i", req = { "pr3" }, fx = { unitCostPct = -6 }, gain = "−6 % de costo por unidad" },
		{ id = "pr5", name = "Pintura robotizada", year = 1993, tier = "n", req = { "pr3" }, fx = { quality = 1 }, gain = "Habilita acabados perlado y cromado; +1 de calidad" },
		{ id = "pr6", name = "Fábrica digital", year = 2012, tier = "b", req = { "pr4" }, fx = { prodSpeed = 30, unitCostPct = -5 }, gain = "+30 % de producción y −5 % de costo por unidad" },
	} },
	electronica = { label = "Electrónica y eléctricos", nodes = {
		{ id = "el1", name = "Encendido electrónico", year = 1975, tier = "s", req = {}, fx = { durability = 3, consPct = -3 }, gain = "+3 de durabilidad y −3 % de consumo" },
		{ id = "el2", name = "Computadora de a bordo", year = 1985, tier = "n", req = { "el1" }, fx = { quality = 2, consPct = -3 }, gain = "+2 de calidad y −3 % de consumo" },
		{ id = "el3", name = "Faros LED", year = 2004, tier = "n", req = { "el2" }, fx = {}, gain = "Habilita faros LED" },
		{ id = "el4", name = "Sistema híbrido", year = 2006, tier = "i", req = { "el2" }, fx = {}, gain = "Habilita el sistema híbrido" },
		{ id = "el5", name = "Baterías de iones de litio", year = 2010, tier = "b", req = { "el4" }, fx = {}, gain = "Habilita el Rayo E, el motor eléctrico y la batería de 60 kWh" },
		{ id = "el6", name = "Baterías de alta densidad", year = 2016, tier = "i", req = { "el5" }, fx = {}, gain = "Habilita la batería de 80 kWh y el motor de 350 kW" },
		{ id = "el7", name = "Baterías de estado sólido", year = 2024, tier = "b", req = { "el6" }, fx = {}, gain = "Habilita la batería de estado sólido" },
	} },
	materiales = { label = "Materiales y aerodinámica", nodes = {
		{ id = "ma1", name = "Túnel de viento", year = 1972, tier = "n", req = {}, fx = { topPct = 4, consPct = -3 }, gain = "+4 % de velocidad máxima y −3 % de consumo" },
		{ id = "ma2", name = "Refrigeración de competición", year = 1978, tier = "n", req = { "ma1" }, fx = {}, gain = "Habilita la refrigeración de competición" },
		{ id = "ma3", name = "Paneles de aluminio", year = 1985, tier = "n", req = {}, fx = {}, gain = "Habilita paneles de aluminio (−40 kg)" },
		{ id = "ma4", name = "Escape de titanio", year = 1997, tier = "n", req = { "ma3" }, fx = {}, gain = "Habilita el escape de titanio" },
		{ id = "ma5", name = "Fibra de carbono", year = 2000, tier = "i", req = { "ma3" }, fx = {}, gain = "Habilita fibra de carbono, capó y difusor de carbono" },
		{ id = "ma6", name = "Frenos carbono-cerámicos", year = 2003, tier = "i", req = { "ma5" }, fx = {}, gain = "Habilita frenos carbono-cerámicos" },
		{ id = "ma7", name = "Aerodinámica activa", year = 2012, tier = "n", req = { "ma1" }, fx = { spoilerGrip = 4 }, gain = "+4 de manejo con alerón instalado" },
	} },
	marketing = { label = "Marketing", nodes = {
		{ id = "mk1", name = "Publicidad en radio y TV", year = 1970, tier = "s", req = {}, fx = { demand = 5, campaign = 1 }, gain = "+5 % de demanda y habilita campañas publicitarias" },
		{ id = "mk2", name = "Red de concesionarios", year = 1981, tier = "n", req = { "mk1" }, fx = { demand = 10 }, gain = "+10 % de demanda" },
		{ id = "mk3", name = "Garantía extendida", year = 1987, tier = "n", req = { "mk2" }, fx = { repGain = 50 }, gain = "La reputación sube 50 % más rápido" },
		{ id = "mk4", name = "Marketing por internet", year = 1998, tier = "n", req = { "mk2" }, fx = { demand = 10 }, gain = "+10 % de demanda" },
		{ id = "mk5", name = "Redes sociales", year = 2009, tier = "i", req = { "mk4" }, fx = { demand = 15 }, gain = "+15 % de demanda" },
	} },
}

--[[ Marcas rivales controladas por el juego. Cada una vende en ciertos tipos desde cierto año. offset =
	atractivo respecto de lo que espera el mercado (puede cambiar con los años: { año, valor }). ]]
-- Precio típico de cada tipo de vehículo (referencia para los modelos rivales, en dólares del juego).
Catalog.RIVAL_PRICE = { compacto = 2900, sedan = 3500, clasico = 4500, pickup = 4300, deportivo = 5500, suv = 5200, superdeportivo = 10800, electrico = 8200 }

Catalog.RIVALS = {
	{ id = "kodiak", name = "Kodiak Motors", color = "#8D6E4F", types = { pickup = 1970, suv = 1984, sedan = 1970 }, offset = { { 1970, 2 }, { 2030, 2 } },
		models = { pickup = "Grizzly", suv = "Yukon", sedan = "Marshal" } },
	{ id = "nordia", name = "Nordia", color = "#3B82F6", types = { compacto = 1970, sedan = 1970, electrico = 2014 }, offset = { { 1970, 1 }, { 2030, 2 } },
		models = { compacto = "Fjord", sedan = "Polar", electrico = "Aurora-e" } },
	{ id = "halcon", name = "Halcón", color = "#D6333F", types = { deportivo = 1970, clasico = 1970, superdeportivo = 1974 }, offset = { { 1970, 4 }, { 2030, 4 } },
		models = { deportivo = "Rapaz", clasico = "Cóndor", superdeportivo = "Furia" } },
	{ id = "kairo", name = "Kairo Cars", color = "#42E58D", types = { compacto = 1972, sedan = 1975, suv = 1990, electrico = 2011 }, offset = { { 1970, -3 }, { 1990, 3 }, { 2030, 5 } },
		models = { compacto = "Mika", sedan = "Sora", suv = "Taiga", electrico = "Volt" } },
	{ id = "velox", name = "Velox Auto", color = "#F7C95C", types = { compacto = 1970, deportivo = 1978, clasico = 1970 }, offset = { { 1970, 0 }, { 2030, 1 } },
		models = { compacto = "Chispa", deportivo = "Saeta", clasico = "Ronda" } },
	{ id = "imperial", name = "Imperial", color = "#B3AAFF", types = { sedan = 1970, suv = 1995, superdeportivo = 1990 }, offset = { { 1970, 3 }, { 2030, 4 } },
		models = { sedan = "Regente", suv = "Monarca", superdeportivo = "Corona" } },
}

-- Misiones. go = pantalla a la que lleva el botón «Ir». kind = tutorial | historia | anual (se reinicia cada año).
-- goalScale = "reach": la meta se multiplica por el alcance de la sede (crece con la empresa).
-- reward.pi = puntos de investigación.
Catalog.MISSIONS = {
	{ id = "t1", kind = "tutorial", title = "Diseñá y guardá tu primer auto", desc = "Abrí Diseño, elegí una base y guardá el proyecto en Revisión.", counter = "designsSaved", goal = 1, reward = { money = 15000, pi = 2, xp = 200 }, go = "editor" },
	{ id = "t2", kind = "tutorial", title = "Lanzá tu primer lote", desc = "En Producción, elegí el diseño y cuántas unidades fabricar.", counter = "lotsLaunched", goal = 1, reward = { money = 10000, xp = 150 }, go = "fabrica" },
	{ id = "t3", kind = "tutorial", title = "Vendé tus primeros 25 autos", desc = "Los autos terminados se venden solos. Mirá el ritmo en Ventas.", counter = "unitsSold", goal = 25, reward = { money = 20000, pi = 3, xp = 300 }, go = "ventas" },
	{ id = "t4", kind = "tutorial", title = "Mejorá la fábrica", desc = "Subí de nivel una estación en Producción › Estaciones.", counter = "stationUpgrades", goal = 1, reward = { money = 8000, xp = 120 }, go = "fabrica" },
	{ id = "t5", kind = "tutorial", title = "Investigá una tecnología", desc = "Elegí una tecnología disponible de tu época en Investigación.", counter = "researchDone", goal = 1, reward = { money = 10000, pi = 3, xp = 200 }, go = "investigacion" },
	{ id = "t6", kind = "tutorial", title = "Diseñá un segundo modelo", desc = "Un segundo auto de otro tipo vende en otro segmento sin competir con el primero.", counter = "designsSaved", goal = 2, reward = { money = 20000, pi = 3, xp = 300 }, go = "editor" },
	{ id = "s1", kind = "historia", title = "Vendé 300 autos", desc = "Requisito para ampliar a Empresa pequeña.", counter = "unitsSold", goal = 300, reward = { money = 30000, pi = 8, xp = 500 }, go = "ventas" },
	{ id = "s2", kind = "historia", title = "Ampliá a Empresa pequeña", desc = "Desde Compañía › Sede.", counter = "sedeLevel", goal = 2, reward = { money = 50000, pi = 15, xp = 600 }, go = "compania" },
	{ id = "s3", kind = "historia", title = "Completá 5 investigaciones", desc = "Cada tecnología cambia estadísticas, costos u opciones del editor.", counter = "researchDone", goal = 5, reward = { money = 40000, pi = 10, xp = 400 }, go = "investigacion" },
	{ id = "s4", kind = "historia", title = "Agotá un lote completo", desc = "Vendé todas las unidades de un lote.", counter = "lotsSoldOut", goal = 1, reward = { money = 25000, pi = 6, xp = 350 }, go = "ventas" },
	{ id = "s5", kind = "historia", title = "Lanzá una nueva generación", desc = "Desde Catálogo, creá la 2.ª generación de un modelo.", counter = "generations", goal = 1, reward = { money = 30000, pi = 8, xp = 400 }, go = "autos" },
	{ id = "s6", kind = "historia", title = "Llegá a la Sede empresarial", desc = "Más líneas, más alcance y 20 PI por minuto.", counter = "sedeLevel", goal = 3, reward = { money = 150000, pi = 40, xp = 1200 }, go = "compania" },
	{ id = "s7", kind = "historia", title = "Vendé 10.000 autos", desc = "Una marca reconocida en todo el país.", counter = "unitsSold", goal = 10000, reward = { money = 400000, pi = 80, xp = 2000 }, go = "ventas" },
	{ id = "y1", kind = "anual", title = "Vendé autos este año", desc = "Se reinicia cada año. La meta crece con tu sede.", counter = "soldYear", goal = 120, goalScale = "reach", reward = { money = 12000, pi = 3, xp = 150 }, go = "ventas" },
	{ id = "y2", kind = "anual", title = "Producí autos este año", desc = "Se reinicia cada año. La meta crece con tu sede.", counter = "producedYear", goal = 150, goalScale = "reach", reward = { money = 10000, pi = 3, xp = 120 }, go = "fabrica" },
	{ id = "y3", kind = "anual", title = "Ganancia del año", desc = "Ingresos por ventas − costo de fabricación de lo vendido este año.", counter = "marginYear", goal = 90000, goalScale = "reach", reward = { money = 15000, pi = 4, xp = 150 }, go = "estadisticas" },
}

-- Recompensa diaria por días reales consecutivos (fecha UTC del servidor).
Catalog.DAILY_REWARDS = {
	{ money = 5000 }, { money = 8000 }, { money = 10000, pi = 2 }, { money = 15000 }, { money = 20000, pi = 3 }, { money = 25000 }, { money = 40000, pi = 6 },
}

Catalog.LOGOS = {
	{ "pico", "Pico" }, { "rayo", "Rayo" }, { "escudo", "Escudo" }, { "corona", "Corona" },
	{ "pinon", "Piñón" }, { "ala", "Ala" }, { "estrella", "Estrella" }, { "ruta", "Ruta" },
}

-- Noticias del sector por época (la cinta del HUD muestra las del año en curso y las anteriores cercanas).
Catalog.NEWS = {
	{ 1970, "DEMANDA", "#42E58D", "Los sedanes familiares son los autos más vendidos del país." },
	{ 1970, "TECNOLOGÍA", "#6FE3F0", "Los cinturones de tres puntos se vuelven obligatorios en varios mercados." },
	{ 1973, "MERCADO", "#F7C95C", "La suba del petróleo hace que el consumo pese más en la decisión de compra." },
	{ 1977, "TECNOLOGÍA", "#6FE3F0", "Los primeros turbos llegan a los autos de calle." },
	{ 1983, "DEMANDA", "#42E58D", "Aparece una nueva clase de vehículo: los todoterreno familiares." },
	{ 1986, "TECNOLOGÍA", "#6FE3F0", "El ABS empieza a ofrecerse en autos de serie." },
	{ 1990, "MERCADO", "#F7C95C", "Los SUV crecen año tras año en las ventas." },
	{ 1998, "TECNOLOGÍA", "#6FE3F0", "Internet cambia la forma en que se publicitan los autos." },
	{ 2006, "TECNOLOGÍA", "#6FE3F0", "Los híbridos ganan lugar entre los conductores urbanos." },
	{ 2012, "DEMANDA", "#42E58D", "Los autos eléctricos empiezan a venderse en serio." },
	{ 2020, "MERCADO", "#F7C95C", "Los eléctricos ya son una parte grande del mercado." },
	{ 1970, "COMPETENCIA", "#FF8A91", "Kodiak Motors domina las pickups del país." },
	{ 1975, "COMPETENCIA", "#FF8A91", "Kairo Cars llega con compactos baratos y confiables." },
}

-- Estadísticas visibles del editor: { clave, etiqueta, unidad, ayuda, dirección (+1 más es mejor), máximo de la barra }
Catalog.STAT_DEFS = {
	{ "hp", "Potencia", "hp", "Fuerza del motor. Más es más rápido.", 1, 800 },
	{ "top", "Velocidad máxima", "km/h", "Velocidad tope en recta.", 1, 400 },
	{ "accel", "0 a 100 km/h", "s", "Segundos para llegar a 100 km/h. Menos es mejor.", -1, 16 },
	{ "handling", "Manejo", "índice 0–100", "Agarre y estabilidad en curvas. Más es mejor.", 1, 100 },
	{ "stop", "Frenado 100→0", "m", "Metros para detenerse desde 100 km/h. Menos es mejor.", -1, 60 },
	{ "durability", "Durabilidad", "índice 0–100", "Resistencia al desgaste. Más es mejor.", 1, 100 },
	{ "consumption", "Consumo", "", "Combustible o energía cada 100 km. Menos es mejor.", -1, 25 },
	{ "comfort", "Comodidad", "índice 0–100", "Confort de marcha. Más es mejor.", 1, 100 },
	{ "safety", "Seguridad", "índice 0–100", "Protección de los ocupantes. Pesa mucho en autos familiares.", 1, 100 },
	{ "quality", "Calidad", "índice 0–100", "Terminación general; sube el precio recomendado.", 1, 100 },
	{ "kg", "Peso", "kg", "Menos peso mejora aceleración, frenado y consumo.", -1, 2600 },
}

-- Índices auxiliares ---------------------------------------------------------
local baseIndex: { [string]: any } = {}
for _, b in Catalog.BASES do
	baseIndex[b.id] = b
end
local partIndex: { [string]: any } = {}
for _, p in Catalog.PARTS do
	partIndex[p.cat .. ":" .. p.id] = p
end
local matIndex: { [string]: any } = {}
for _, m in Catalog.MATERIALS do
	matIndex[m[1]] = m
end

function Catalog.base(id: any): any
	if type(id) ~= "string" then
		return nil
	end
	return baseIndex[id]
end

function Catalog.part(cat: any, id: any): any
	if type(cat) ~= "string" or type(id) ~= "string" then
		return nil
	end
	return partIndex[cat .. ":" .. id]
end

function Catalog.partsOf(cat: string): { any }
	local out = {}
	for _, p in Catalog.PARTS do
		if p.cat == cat then
			table.insert(out, p)
		end
	end
	return out
end

function Catalog.material(id: any): any
	if type(id) ~= "string" then
		return nil
	end
	return matIndex[id]
end

function Catalog.matLabel(id: string): string
	local m = matIndex[id]
	return m and m[2] or id
end

function Catalog.catLabel(cat: string): string
	for _, c in Catalog.CATS do
		if c[1] == cat then
			return c[2]
		end
	end
	return cat
end

function Catalog.isBrandColor(hex: any): boolean
	for _, c in Catalog.BRAND_COLORS do
		if c[1] == hex then
			return true
		end
	end
	return false
end

function Catalog.colorName(list: { any }, hex: string): string?
	for _, c in list do
		if string.upper(c[1]) == string.upper(hex) then
			return c[2]
		end
	end
	return nil
end

-- Interpolación lineal en una tabla { { año, valor }, … } (se usa para demanda, rodado, PI esperado…).
function Catalog.interp(points: { any }, year: number): number
	if year <= points[1][1] then
		return points[1][2]
	end
	for i = 2, #points do
		local a, b = points[i - 1], points[i]
		if year <= b[1] then
			return a[2] + (b[2] - a[2]) * (year - a[1]) / (b[1] - a[1])
		end
	end
	return points[#points][2]
end

local researchIndex: { [string]: any } = {}
for _, key in Catalog.RESEARCH_ORDER do
	for _, n in Catalog.RESEARCH[key].nodes do
		n.cat = key
		local tier = Catalog.RESEARCH_TIERS[n.tier]
		-- PI = minutos objetivo × PI/min que se espera tener en ese año (más importante = más largo;
		-- una sede más grande lo termina más rápido). El dinero acompaña al PI.
		n.rp = math.max(3, math.floor(tier.minutes * Catalog.interp(Catalog.EXPECTED_PI, n.year) + 0.5))
		n.cost = math.floor(n.rp * Catalog.ECON.researchMoneyPerPi / 100 + 0.5) * 100
		n.lab = 1
		researchIndex[n.id] = n
		Catalog.RESEARCH_NAMES[n.id] = n.name
	end
end
function Catalog.researchNode(id: any): any
	return type(id) == "string" and researchIndex[id] or nil
end

-- Opción de carrocería o interior: { id, nombre, costo, (efectos), año, investigación }.
function Catalog.bodyOpt(group: string, id: any): any
	for _, o in Catalog.BODY_OPTS[group] or {} do
		if o[1] == id then
			return { id = o[1], name = o[2], cost = o[3], year = o[4] or 1970, research = o[5] }
		end
	end
	return nil
end
function Catalog.interiorOpt(group: string, id: any): any
	for _, o in Catalog.INTERIOR[group] or {} do
		if o[1] == id then
			return { id = o[1], name = o[2], cost = o[3], fx = o[4], year = o[5] or 1970, research = o[6] }
		end
	end
	return nil
end

-- Acabados por época: el perlado y el cromado necesitan pintura robotizada.
Catalog.FINISH_YEAR = { ["Mate"] = 1970, ["Metálico"] = 1970, ["Perlado"] = 1993, ["Cromado"] = 1993 }

local missionIndex: { [string]: any } = {}
for _, m in Catalog.MISSIONS do
	missionIndex[m.id] = m
end
function Catalog.mission(id: any): any
	return type(id) == "string" and missionIndex[id] or nil
end

function Catalog.station(id: any): any
	for _, s in Catalog.STATIONS do
		if s[1] == id then
			return s
		end
	end
	return nil
end

function Catalog.department(id: any): any
	for _, d in Catalog.DEPARTMENTS do
		if d[1] == id then
			return d
		end
	end
	return nil
end

function Catalog.isLogo(id: any): boolean
	for _, l in Catalog.LOGOS do
		if l[1] == id then
			return true
		end
	end
	return false
end

return Catalog
