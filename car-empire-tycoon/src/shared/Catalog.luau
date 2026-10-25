--!strict
--[[
	Car Empire Tycoon — catálogos y reglas (etapa 1).
	Portado de reference/Car-Empire-Tycoon-V3.html (bloque «catálogos y reglas del prototipo»).
	Los valores numéricos son los mismos que en la V3 para que precios y estadísticas coincidan.
	Este módulo es puro: no usa servicios de Roblox y se puede cargar desde las pruebas con Lune.
]]

local Catalog = {}

Catalog.RULES = {
	version = 1,
	minutesPerRealSecond = 10, -- a velocidad 1×, 1 s real = 10 min de juego
	dayMinutes = 1440,
	taxRate = 0.05, -- impuesto sobre compras al proveedor
	maxDiscount = 30,
	noStaffSpeed = 0.5, -- sin personal en la línea: 50 % de velocidad (etapa 1 no tiene personal)
	maxQty = 50,
	maxDesigns = 30,
	maxLedger = 300,
	maxSales = 200,
	maxSoldUnitsKept = 60,
	maxCustomers = 6,
	speeds = { 0, 1, 2, 4 },
}

Catalog.DIFFICULTIES = {
	facil = { id = "facil", label = "Relajado", money = 100000, desc = "Demanda estable y clientes pacientes. Ideal para aprender.", patience = 1.4, demand = 1.15, dots = 1 },
	normal = { id = "normal", label = "Normal", money = 50000, desc = "La experiencia recomendada: crisis ocasionales y rivales activos.", patience = 1, demand = 1, dots = 2 },
	dificil = { id = "dificil", label = "Magnate", money = 20000, desc = "Clientes exigentes, materiales caros y poco margen de error.", patience = 0.75, demand = 0.85, dots = 3 },
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
	["Perlado"] = { unit = 1400, research = "q3" },
	["Cromado"] = { unit = 3200, research = "q3" },
}
Catalog.FINISH_ORDER = { "Mate", "Metálico", "Perlado", "Cromado" }

Catalog.TYPES = {
	compacto = "Compacto",
	sedan = "Sedán",
	deportivo = "Deportivo",
	superdeportivo = "Superdeportivo",
	suv = "SUV",
	pickup = "Pickup",
	clasico = "Clásico",
	electrico = "Eléctrico",
}

-- Vehículos base. En la etapa 1 están disponibles Pixel C1 y Brisa Sedán (nivel 1);
-- el resto se muestra bloqueado por nivel o investigación, igual que en la V3.
Catalog.BASES = {
	{ id = "pixel", name = "Pixel C1", brand = "Nordia", type = "compacto", level = 1, research = nil, rarity = "Común",
		dev = 12000, unit = 7800, weight = 1080, handling = 58, comfort = 60, durability = 80, quality = 55, drag = 0.33, build = 150,
		tags = { "combustion" }, mats = { acero = 6, aluminio = 2, pintura = 1, electronica = 1 }, pop = 1.2,
		defaults = { motor = "i4", turbo = "none", transmision = "man5", traccion = "fwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none" } },
	{ id = "brisa", name = "Brisa Sedán", brand = "Vortex", type = "sedan", level = 1, research = nil, rarity = "Común",
		dev = 16000, unit = 10500, weight = 1350, handling = 60, comfort = 72, durability = 82, quality = 60, drag = 0.29, build = 180,
		tags = { "combustion" }, mats = { acero = 8, aluminio = 3, pintura = 1, electronica = 1 }, pop = 1.1,
		defaults = { motor = "i4", turbo = "none", transmision = "auto8", traccion = "fwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none" } },
	{ id = "aurora", name = "Aurora GT", brand = "Vortex", type = "deportivo", level = 2, research = nil, rarity = "Rara",
		dev = 30000, unit = 16500, weight = 1380, handling = 74, comfort = 55, durability = 74, quality = 66, drag = 0.30, build = 240,
		tags = { "combustion" }, mats = { acero = 7, aluminio = 5, pintura = 1, electronica = 2 }, pop = 1.0,
		defaults = { motor = "v6", turbo = "none", transmision = "dct7", traccion = "rwd", frenos = "sport", suspension = "sport", neumaticos = "sport", bateria = "b12", refrigeracion = "std", escape = "sport", peso = "none" } },
	{ id = "titan", name = "Titán SUV", brand = "Kodiak", type = "suv", level = 3, research = nil, rarity = "Común",
		dev = 26000, unit = 15000, weight = 1850, handling = 52, comfort = 74, durability = 86, quality = 62, drag = 0.36, build = 230,
		tags = { "combustion", "offroad" }, mats = { acero = 11, aluminio = 3, pintura = 2, electronica = 2 }, pop = 1.05,
		defaults = { motor = "v6", turbo = "none", transmision = "auto8", traccion = "awd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none" } },
	{ id = "toro", name = "Toro Pickup", brand = "Kodiak", type = "pickup", level = 4, research = nil, rarity = "Común",
		dev = 24000, unit = 14200, weight = 2050, handling = 48, comfort = 58, durability = 92, quality = 58, drag = 0.40, build = 230,
		tags = { "combustion", "offroad" }, mats = { acero = 13, aluminio = 2, pintura = 2, electronica = 1 }, pop = 0.95,
		defaults = { motor = "v6", turbo = "none", transmision = "man5", traccion = "x4", frenos = "std", suspension = "offroad", neumaticos = "at", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none" } },
	{ id = "duna", name = "Duna Clásico", brand = "Halcón", type = "clasico", level = 5, research = nil, rarity = "Épica",
		dev = 34000, unit = 17500, weight = 1420, handling = 56, comfort = 66, durability = 70, quality = 72, drag = 0.38, build = 260,
		tags = { "combustion" }, mats = { acero = 9, aluminio = 2, pintura = 2, electronica = 1, cuero = 2 }, pop = 0.8,
		defaults = { motor = "v6", turbo = "none", transmision = "man5", traccion = "rwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "sport", peso = "none" } },
	{ id = "rayo", name = "Rayo E", brand = "Kairo", type = "electrico", level = 4, research = "e1", rarity = "Rara",
		dev = 38000, unit = 19000, weight = 1720, handling = 66, comfort = 76, durability = 84, quality = 70, drag = 0.24, build = 250,
		tags = { "electrico" }, mats = { acero = 6, aluminio = 5, pintura = 1, electronica = 4, baterias = 8 }, pop = 1.0,
		defaults = { motor = "em200", turbo = "none", transmision = "single", traccion = "rwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "ev60", refrigeracion = "std", escape = "none", peso = "none" } },
	{ id = "vento", name = "Halcón Vento SS", brand = "Halcón", type = "superdeportivo", level = 8, research = "m3", rarity = "Legendaria",
		dev = 90000, unit = 42000, weight = 1450, handling = 84, comfort = 44, durability = 66, quality = 80, drag = 0.27, build = 360,
		tags = { "combustion" }, mats = { acero = 5, aluminio = 9, pintura = 2, electronica = 3 }, pop = 0.7,
		defaults = { motor = "v8", turbo = "none", transmision = "dct7", traccion = "rwd", frenos = "sport", suspension = "sport", neumaticos = "sport", bateria = "b12", refrigeracion = "pro", escape = "sport", peso = "none" } },
}

Catalog.CATS = {
	{ "motor", "Motor" },
	{ "turbo", "Turbo" },
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
	proto = costo único de desarrollo del prototipo (se paga una sola vez por empresa al guardar)
	unit  = costo agregado a la fabricación de cada unidad
	fx    = efectos: hp, kg, grip, brake, comfort, dur, eff, q
	need  = etiqueta requerida en la base ("combustion", "electrico", "offroad") ]]
local function P(id, cat, name, rarity, level, research, proto, unit, need, fx, desc)
	return { id = id, cat = cat, name = name, rarity = rarity, level = level, research = research, proto = proto, unit = unit, need = need, fx = fx, desc = desc }
end

Catalog.PARTS = {
	-- Motor
	P("i4", "motor", "Motor 4 cil. 1.6", "Común", 1, nil, 0, 2200, "combustion", { hp = 130, kg = 0, eff = 4, dur = 4 }, "Económico y confiable."),
	P("v6", "motor", "Motor V6 3.0", "Rara", 1, nil, 6000, 4800, "combustion", { hp = 290, kg = 60, eff = -4, q = 2 }, "Equilibrio entre potencia y consumo."),
	P("v8", "motor", "Motor V8 4.0", "Épica", 5, "m3", 18000, 9500, "combustion", { hp = 470, kg = 110, eff = -10, q = 4, dur = -3 }, "Ocho cilindros para deportivos."),
	P("em200", "motor", "Motor eléctrico 200 kW", "Rara", 1, "e1", 8000, 6000, "electrico", { hp = 270, kg = 40, eff = 10, dur = 4 }, "Silencioso, par inmediato."),
	P("em350", "motor", "Motor eléctrico 350 kW", "Épica", 6, "e2", 20000, 11000, "electrico", { hp = 470, kg = 70, eff = 4, q = 4 }, "Doble motor de alto rendimiento."),
	-- Turbo
	P("none", "turbo", "Sin turbo", "Común", 1, nil, 0, 0, nil, {}, "Aspiración natural."),
	P("t1", "turbo", "Turbo simple T1", "Común", 1, nil, 3000, 1400, "combustion", { hp = 35, eff = -2, dur = -1 }, "Más potencia con poco costo."),
	P("t2", "turbo", "Turbo twin-scroll T2", "Rara", 2, "m2", 7500, 2600, "combustion", { hp = 70, eff = -3, dur = -2, q = 2 }, "Doble entrada, menos retardo."),
	P("s3", "turbo", "Supercargador S3", "Épica", 4, "m4", 15000, 4200, "combustion", { hp = 110, eff = -6, dur = -3, q = 3 }, "Respuesta inmediata del compresor."),
	-- Transmisión
	P("man5", "transmision", "Manual 5 vel.", "Común", 1, nil, 0, 800, "combustion", { eff = 2, comfort = -3 }, "Simple y barata."),
	P("auto8", "transmision", "Automática 8 vel.", "Común", 1, nil, 3500, 1900, "combustion", { comfort = 6, eff = 1, kg = 15 }, "Cambios suaves para el día a día."),
	P("dct7", "transmision", "Doble embrague 7", "Rara", 2, nil, 6500, 2800, "combustion", { grip = 3, comfort = 2, q = 2, kg = 10 }, "Cambios instantáneos."),
	P("single", "transmision", "Reducción única", "Común", 1, nil, 0, 900, "electrico", { comfort = 4 }, "Transmisión de los eléctricos."),
	-- Tracción
	P("fwd", "traccion", "Delantera", "Común", 1, nil, 0, 0, nil, { eff = 2 }, "Ligera y económica."),
	P("rwd", "traccion", "Trasera", "Común", 1, nil, 2000, 600, nil, { grip = 4 }, "Mejor reparto para deportivos."),
	P("awd", "traccion", "Integral AWD", "Rara", 2, nil, 6000, 2200, nil, { grip = 8, kg = 70, eff = -2 }, "Agarre en cualquier clima."),
	P("x4", "traccion", "4x4 con reductora", "Rara", 2, nil, 5500, 2000, "offroad", { grip = 3, kg = 90, dur = 6, eff = -3 }, "Solo para SUV y pickup."),
	-- Frenos
	P("std", "frenos", "Frenos estándar", "Común", 1, nil, 0, 500, nil, { brake = 0 }, "Discos ventilados delanteros."),
	P("sport", "frenos", "Frenos deportivos", "Rara", 1, nil, 3500, 1300, nil, { brake = 6, q = 1 }, "Pinzas de 4 pistones."),
	P("ceram", "frenos", "Carbono-cerámicos", "Épica", 4, "mt3", 12000, 4200, nil, { brake = 12, kg = -12, q = 3 }, "No pierden eficacia al calentarse."),
	-- Suspensión
	P("confort", "suspension", "Confort", "Común", 1, nil, 0, 600, nil, { comfort = 6, grip = -2 }, "Prioriza la marcha suave."),
	P("sport", "suspension", "Deportiva", "Rara", 1, nil, 4000, 1400, nil, { grip = 7, comfort = -6 }, "Más firme y baja."),
	P("air", "suspension", "Neumática", "Épica", 3, nil, 9000, 3200, nil, { comfort = 12, grip = 2, kg = 25, q = 3 }, "Altura y dureza ajustables."),
	P("offroad", "suspension", "Todoterreno elevada", "Rara", 2, nil, 5000, 1700, "offroad", { dur = 8, comfort = 2, grip = -3 }, "Más recorrido para caminos rotos."),
	-- Neumáticos
	P("touring", "neumaticos", "Touring", "Común", 1, nil, 0, 400, nil, { comfort = 3, eff = 2 }, "Silenciosos y duraderos."),
	P("sport", "neumaticos", "Deportivos", "Común", 1, nil, 1500, 800, nil, { grip = 6, brake = 3, comfort = -2 }, "Más agarre en seco."),
	P("slick", "neumaticos", "Semi-slick", "Rara", 3, nil, 4000, 1500, nil, { grip = 11, brake = 5, comfort = -8, dur = -4 }, "Casi de competición."),
	P("at", "neumaticos", "Todo terreno A/T", "Común", 1, nil, 1500, 700, "offroad", { dur = 4, grip = -2 }, "Para barro y ripio."),
	-- Batería
	P("b12", "bateria", "Batería 12 V", "Común", 1, nil, 0, 150, "combustion", {}, "Arranque y accesorios."),
	P("mhev", "bateria", "Híbrido ligero 48 V", "Rara", 3, "e4", 7000, 1800, "combustion", { eff = 8, hp = 15, kg = 25 }, "Recupera energía al frenar."),
	P("ev60", "bateria", "Batería 60 kWh", "Común", 1, "e1", 0, 5200, "electrico", { kg = 380, eff = 4 }, "Autonomía urbana."),
	P("ev80", "bateria", "Batería 80 kWh", "Rara", 4, "e2", 10000, 7600, "electrico", { kg = 470, eff = 9, q = 2 }, "Más autonomía para rutas."),
	P("ssb", "bateria", "Estado sólido 90 kWh", "Épica", 6, "e3", 24000, 11000, "electrico", { kg = 330, eff = 15, q = 5 }, "Más liviana y segura."),
	-- Refrigeración
	P("std", "refrigeracion", "Estándar", "Común", 1, nil, 0, 300, nil, {}, "Suficiente para uso normal."),
	P("pro", "refrigeracion", "Pro", "Rara", 2, nil, 3000, 900, nil, { dur = 5, hp = 10 }, "Radiadores ampliados."),
	P("race", "refrigeracion", "Competición", "Épica", 4, "a2", 8000, 1800, nil, { dur = 9, hp = 18, comfort = -2 }, "Intercoolers y tomas de aire."),
	-- Escape
	P("none", "escape", "Sin escape", "Común", 1, nil, 0, 0, "electrico", {}, "Los eléctricos no usan escape."),
	P("std", "escape", "Escape estándar", "Común", 1, nil, 0, 400, "combustion", { comfort = 2 }, "Silencioso."),
	P("sport", "escape", "Escape deportivo", "Común", 1, nil, 2000, 900, "combustion", { hp = 12, comfort = -2 }, "Mejor sonido y flujo."),
	P("ti", "escape", "Escape de titanio", "Rara", 3, "mt2", 6000, 2100, "combustion", { hp = 20, kg = -14, q = 2 }, "Liviano y resistente."),
	-- Peso
	P("none", "peso", "Sin reducción", "Común", 1, nil, 0, 0, nil, {}, "Carrocería de serie."),
	P("lite", "peso", "Aligerado (−40 kg)", "Común", 1, "mt1", 4000, 900, nil, { kg = -40, comfort = -1 }, "Paneles de aluminio."),
	P("carbon", "peso", "Fibra de carbono (−90 kg)", "Épica", 4, "mt2", 14000, 3800, nil, { kg = -90, q = 3 }, "Techo, capó y paneles de carbono."),
}

-- Nombres de las investigaciones que bloquean piezas (el árbol de investigación llega en una etapa posterior).
Catalog.RESEARCH_NAMES = {
	m2 = "Inducción forzada I", m3 = "Motores V8", m4 = "Inducción forzada II",
	e1 = "Baterías de 60 kWh", e2 = "Baterías de 80 kWh", e3 = "Estado sólido", e4 = "Híbrido ligero",
	a1 = "Túnel de viento", a2 = "Refrigeración de competición", a3 = "Carga aerodinámica activa",
	mt1 = "Aluminio estructural", mt2 = "Fibra de carbono", mt3 = "Cerámica de frenos",
	q1 = "Control de calidad", q2 = "Garantía extendida", q3 = "Pintura premium",
	m1 = "Inyección directa",
}

-- Carrocería e interior: la etapa 1 usa los valores de serie de la V3 (sus costos entran en el precio).
Catalog.BODY_OPTS = {
	bumper = { { "serie", "De serie", 0 }, { "sport", "Sport con labio", 900 }, { "offroad", "Todoterreno con defensa", 1100 } },
	hood = { { "serie", "De serie", 0 }, { "vent", "Con tomas de aire", 700 }, { "carbon", "Carbono a la vista", 1600 } },
	diffuser = { { "none", "Sin difusor", 0 }, { "carbon", "Difusor de carbono", 1200 } },
	skirts = { { "none", "Sin faldones", 0 }, { "low", "Faldones bajos", 600 } },
	lights = { { "white", "LED blanco", 0 }, { "amber", "Halógeno cálido", 0 }, { "blue", "LED azul hielo", 400 } },
	tint = { { "clear", "Transparentes", 0 }, { "t30", "Polarizado 30%", 250 }, { "t70", "Polarizado 70%", 400 } },
	vinyl = { { "none", "Sin vinilos", 0 }, { "stripes", "Franjas dobles", 500 }, { "side", "Franja lateral", 400 } },
	number = { { "none", "Sin número", 0 }, { "27", "Número 27", 150 }, { "8", "Número 8", 150 } },
	logo = { { "on", "Emblema en el frente", 0 }, { "off", "Sin emblema", 0 } },
}
Catalog.BODY_DEFAULTS = { bumper = "serie", hood = "serie", diffuser = "none", skirts = "none", lights = "white", tint = "t30", vinyl = "none", number = "none", logo = "on" }

Catalog.INTERIOR = {
	seats = { { "serie", "De serie", 0, {} }, { "sport", "Baquet deportivos", 1800, { comfort = -3, grip = 1, q = 1 } }, { "lux", "Confort con masaje", 2600, { comfort = 7, q = 2 } } },
	material = { { "tela", "Tela técnica", 0, {} }, { "cuero", "Cuero", 1500, { comfort = 3, q = 3 } }, { "alcantara", "Alcántara", 1900, { q = 3 } } },
	wheel = { { "serie", "Redondo de serie", 0, {} }, { "flat", "Achatado deportivo", 500, { q = 1 } } },
	dash = { { "analog", "Analógico", 0, {} }, { "digital", "Digital de 12″", 1400, { q = 2, comfort = 1 } } },
	ambient = { { "off", "Apagada", 0, {} }, { "violet", "Violeta", 350, { comfort = 1 } }, { "white", "Blanca cálida", 350, { comfort = 1 } }, { "cyan", "Cian", 350, { comfort = 1 } } },
}
Catalog.INTERIOR_DEFAULTS = { seats = "serie", material = "tela", color = "#1A1B1F", wheel = "serie", dash = "analog", ambient = "off" }

Catalog.WHEEL_STYLES = { { "radial5", "Radial 5 rayos" }, { "mesh", "Malla 10 rayos" }, { "solid", "Aero cerrada" } }
Catalog.RIM_COLORS = { { "#C9CED8", "Plata" }, { "#2A2E38", "Grafito" }, { "#F5F7FA", "Cromo" }, { "#C9A86A", "Bronce" } }
Catalog.CALIPER_COLORS = { { "#F7C95C", "Amarillo" }, { "#D6333F", "Rojo" }, { "#42E58D", "Verde" }, { "#3B82F6", "Azul" }, { "#5D6371", "Gris" } }

Catalog.CHASSIS = {
	Monocasco = { kg = 0, grip = 0, dur = 0, unit = 0, need = nil },
	Tubular = { kg = -25, grip = 3, dur = -2, unit = 900, need = nil },
	Escalera = { kg = 70, grip = -3, dur = 7, unit = 400, need = "offroad" },
}
Catalog.CHASSIS_ORDER = { "Monocasco", "Tubular", "Escalera" }
Catalog.SEGMENTS = {
	Masivo = { price = 1, pop = 1 },
	Premium = { price = 1.12, pop = 0.85 },
	Lujo = { price = 1.28, pop = 0.65 },
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
Catalog.QUALITY_TIERS = { "C", "C+", "B", "B+", "A", "S" } -- índice = calidad + 1

Catalog.MATERIALS = {
	{ "acero", "Acero", 40 },
	{ "aluminio", "Aluminio", 95 },
	{ "pintura", "Pintura", 120 },
	{ "electronica", "Electrónica", 260 },
	{ "baterias", "Baterías", 420 },
	{ "cuero", "Cuero", 180 },
}
Catalog.SUPPLIER_PACKS = { 10, 50 }

-- Etapa 1: solo la primera sede (garaje inicial).
Catalog.SEDES = {
	{ level = 1, name = "Garaje inicial", lines = 1, warehouse = 6, showroom = 2, mats = 400 },
}

Catalog.CUSTOMER_NAMES = { "Martina R.", "Tomás P.", "Lucía G.", "Diego B.", "Valentina S.", "Bruno L.", "Camila F.", "Julián M.", "Sofía K.", "Agustín V.", "Renata O.", "Facundo T.", "Milagros D.", "Lautaro C." }
Catalog.PREFS = { "potencia", "economia", "comodidad", "estilo" }
Catalog.PREF_LABEL = { potencia = "potencia", economia = "bajo consumo", comodidad = "comodidad", estilo = "estilo" }

-- Estadísticas visibles del editor: { clave, etiqueta, unidad, ayuda, dirección (+1 más es mejor), máximo de la barra }
Catalog.STAT_DEFS = {
	{ "hp", "Potencia", "hp", "Fuerza del motor. Más es más rápido.", 1, 800 },
	{ "top", "Velocidad máxima", "km/h", "Velocidad tope en recta.", 1, 400 },
	{ "accel", "0 a 100 km/h", "s", "Segundos para llegar a 100 km/h. Menos es mejor.", -1, 16 },
	{ "handling", "Manejo", "0–100", "Agarre y estabilidad en curvas.", 1, 100 },
	{ "stop", "Frenado 100→0", "m", "Metros para detenerse. Menos es mejor.", -1, 60 },
	{ "durability", "Durabilidad", "0–100", "Resistencia al desgaste.", 1, 100 },
	{ "consumption", "Consumo", "", "Combustible o energía cada 100 km. Menos es mejor.", -1, 25 },
	{ "comfort", "Comodidad", "0–100", "Confort de marcha.", 1, 100 },
	{ "quality", "Calidad", "0–100", "Terminación general; sube el precio recomendado.", 1, 100 },
	{ "kg", "Peso", "kg", "Menos peso mejora aceleración, frenado y consumo.", -1, 2600 },
}

-- Recorrido guiado de la etapa 1 (sin recompensas: el sistema de misiones llega después).
Catalog.TUTORIAL = {
	{ id = "t0", title = "Fundá tu empresa", counter = "companyCreated" },
	{ id = "t1", title = "Diseñá y guardá tu primer auto", counter = "designsSaved" },
	{ id = "t2", title = "Creá una orden de producción", counter = "ordersCreated" },
	{ id = "t3", title = "Fabricá una unidad", counter = "unitsProduced" },
	{ id = "t4", title = "Colocá un auto en el concesionario", counter = "sentToShowroom" },
	{ id = "t5", title = "Completá tu primera venta", counter = "unitsSold" },
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

return Catalog
