--!strict
--[[
	Car Empire Tycoon — catálogos y parámetros de equilibrio.
	Bases, piezas y opciones visuales vienen de reference/Car-Empire-Tycoon-V3.html; desde la auditoría
	(esquema 3) cada una tiene un año de aparición y, si corresponde, la investigación que la habilita.
	Acá están todos los números que se ajustan para equilibrar el juego: calendario (CALENDAR), economía
	(ECON), demanda por tipo y año (DEMAND), sedes (SEDES), investigación (RESEARCH_TIERS, EXPECTED_PI,
	RESEARCH), rivales (RIVALS) y misiones. tests/balance.luau muestra el ritmo resultante.
	Este módulo es puro: no usa servicios de Roblox y se puede cargar desde las pruebas con Lune.
]]

local Catalog = {}

-- Calendario (parámetro central de equilibrio): un DÍA de juego dura `realSecondsPerDay` segundos reales a
-- velocidad 1× (2 s: un año de 365 días ≈ 12 min reales). La simulación avanza en minutos de juego (10 por
-- segundo real, así que un día son 20). g.time.day cuenta MESES desde enero de 1970 y g.time.minute los
-- minutos de juego dentro del mes; cada mes dura sus días reales (28 a 31). Es la única referencia de tiempo:
-- fabricación, ventas, investigación, campañas y salarios avanzan desde Simulation.simulate.
-- endYear = último año con contenido histórico (tecnologías, demanda, rivales). Al llegar, el año visible
-- queda en endYear y el juego sigue en «años comerciales extra» (g.time.day sigue contando meses). Para
-- ampliar la historia basta con subir endYear y agregar contenido de esos años.
Catalog.CALENDAR = { startYear = 1970, endYear = 2030, realSecondsPerDay = 2, realSecondsPerYear = 730, months = 12 }

Catalog.RULES = {
	version = 6,
	minutesPerRealSecond = 10, -- a velocidad 1×, 1 s real = 10 min de juego
	-- Minutos de juego de un día: 2 s reales × 10 min/s = 20. Un mes dura sus días × 20 (Rules.monthMinutes).
	gameDayMinutes = Catalog.CALENDAR.realSecondsPerDay * 10,
	-- Partidas de versiones anteriores (esquema ≤ 5): todos los meses duraban 550 minutos de juego.
	legacyMonthMinutes = 550,
	-- Obsoletos (versiones anteriores al I+D por proyectos): ya no hay «banco» con tope ni aceleración por PI
	-- ahorrados. Los PI se acumulan sin límite en g.rp y solo sirven para pagar proyectos nuevos al empezarlos
	-- (Rules.piCap = infinito). Se conservan los valores por compatibilidad; ningún cálculo los usa.
	piBankMinutes = 20,
	bankSpeedup = 1,
	-- Difusión tecnológica: una tecnología de hace más de diffusionGrace años cuesta diffusionPerYear menos
	-- por año (PI y dinero), hasta diffusionFloor de su costo. Quien va atrasado se pone al día más rápido.
	diffusionGrace = 1,
	diffusionPerYear = 0.08,
	diffusionFloor = 0.4,
	maxLotQty = 1000000, -- tope técnico de un lote (la capacidad y el dinero son el límite real)
	maxActiveLots = 16, -- lotes produciendo o en venta a la vez
	maxLotHistory = 40, -- historial reciente: lotes agotados o retirados con su detalle (versión liviana)
	-- Historial permanente: un resumen por modelo y generación. Los maxModelDetail más importantes guardan
	-- configuración y estadísticas completas (≈ 1 KB); el resto, solo números y nombre (≈ 0,3 KB). Si se
	-- superan maxModelHistory, los modelos con menos ventas se suman a «Otros modelos» (los totales no se
	-- pierden). Con 3 empresas por cuenta, el peor caso queda muy por debajo del límite de 4 MB por clave.
	maxModelDetail = 150,
	maxModelHistory = 600,
	maxDesigns = 60,
	-- Borradores del editor por empresa: solo protege el tamaño del guardado (cada uno ≈ 1 KB).
	maxDrafts = 20,
	-- Fabricación avanzada (preparación de materiales, ensamblaje, componentes, control de calidad, maquinaria y
	-- trabajadores animados): etapa futura. Mientras sea false el lote avanza con un progreso general
	-- (Rules.lotProgress) y no hay fases que cambien la simulación.
	advancedManufacturing = false,
	maxLedger = 200,
	statsDaysKept = 72, -- meses de agregados (6 años)
	slots = 4, -- empresas por cuenta (ranuras "1".."4")
	slotsFree = 2, -- las dos primeras son gratuitas; la 3 y la 4 se compran por separado (Catalog.PRODUCTS)
	moreCandidatesCost = 1000,
	assignMax = { station = 2, dept = 4 },
	speeds = { 0, 1, 2, 3 }, -- 0 = pausa manual; 1×, 2× y 3× (sin avance instantáneo)
}

--[[ Economía (parámetros de equilibrio). Unidades: dinero en $, velocidades por MINUTO REAL a 1×.
	unitCostScale: los costos por unidad del catálogo (heredados de la V3) se multiplican por este factor
	para que fabricar cientos o miles de autos tenga sentido con el capital inicial. ]]
Catalog.ECON = {
	-- Reseñas: la nota media de los críticos multiplica la demanda del modelo por (nota / 6) ^ reviewElasticity
	-- (un 6 es neutro; un 9 vende ≈ 1,6 veces más y un 3, la mitad). reviewScale: cuántos puntos de índice
	-- (0–100) por encima de lo que espera la época valen un punto de nota.
	reviewElasticity = 1.2,
	reviewScale = 5.5, -- puntos de índice por encima de lo esperado en la época que valen un punto de nota
	unitCostScale = 0.12,
	priceMarkup = 1.3, -- precio de referencia = costo × 1,3 + prima de calidad y prestaciones
	priceElasticity = 2.8, -- cuánto cambian las ventas con el precio respecto de la referencia
	-- Sensibilidad al precio por tipo: los compradores de económicos comparan precios; los de deportivos,
	-- superdeportivos y clásicos pagan más por lo que quieren (menos volumen, más margen).
	typeElasticity = { compacto = 3.4, sedan = 2.9, pickup = 2.6, suv = 2.5, electrico = 2.7, deportivo = 2.1, clasico = 1.9, superdeportivo = 1.6 },
	appealScale = 12, -- puntos de atractivo que multiplican las ventas por e (≈ ×2,7)
	outsideWeight = 45, -- peso del «resto del mercado» (marcas chicas) en el reparto de la demanda
	eraBaseline = { [1970] = 50, [2030] = 75 }, -- atractivo medio que el mercado espera cada año
	priceMin = 0.5, -- (sin uso: el precio es libre; se conserva por compatibilidad)
	priceMax = 3, -- (sin uso: el precio es libre; se conserva por compatibilidad)
	priceCap = 1000000000, -- tope técnico del precio de venta (números seguros para guardar y mostrar)
	reputationStep = 0.08, -- cuánto se acerca la reputación cada mes al nivel que justifican tus ventas
	-- PI por jugar (bonificaciones). Todas comparten un tope mensual para que no se puedan farmear
	-- repitiendo acciones baratas (por ejemplo, lotes de una unidad).
	bonusPiEnabled = false, -- etapa 3: los PI salen del centro de investigación y de las líneas (no de las ventas)
	salesPiPer = 50, -- +1 PI por cada 50 autos vendidos en el mes
	soldOutPiMinutes = 1, -- lote agotado con ganancia (de al menos soldOutMinQty unidades): +1 min de generación
	soldOutMinQty = 100,
	launchSold = 100, -- lanzamiento exitoso: el diseño llega a 100 ventas (una vez por diseño): +1 min
	launchPiMinutes = 1,
	bonusPiCapMinutes = 0.6, -- tope de todas las bonificaciones: 0,6 min de generación por mes de juego
	-- Ingeniería de un modelo nuevo o de una generación nueva (crece con la época: desarrollar un auto
	-- moderno cuesta mucho más). Una versión con cambios mecánicos paga engineeringVersion; los cambios
	-- estéticos (pintura, llantas, interior, nombre) no pagan ingeniería.
	engineering = { { 1970, 3000 }, { 1980, 30000 }, { 1990, 300000 }, { 2000, 2000000 }, { 2010, 6000000 }, { 2030, 12000000 } },
	engineeringVersion = 0.25,
	engineeringCashShare = 0.25, -- con poco dinero, la ingeniería no supera este porcentaje del dinero disponible
	engineeringFloor = 0.1, -- … pero nunca baja del 10 % del costo normal
	-- Costo en dinero de una investigación: $ por PI según la época (los ingresos crecen con los años).
	researchMoneyPerPi = { { 1970, 600 }, { 1980, 1500 }, { 1990, 4000 }, { 2000, 8000 }, { 2010, 12000 }, { 2030, 16000 } },
}

--[[ Marketing (valores provisionales). Una campaña activa por empresa, pagada al empezar y cancelable sin
	reembolso. El jugador elige tipo, modelo (si corresponde), presupuesto MENSUAL y duración en días de juego.
	Costo = presupuesto × días / 30 (corporativa: × tamaño de la empresa y modelos en venta) × época de la
	economía − análisis de mercado. Efecto = maxBoost × (1 − e^(−presupuesto / referencia)): más presupuesto,
	más efecto, con rendimientos decrecientes. ]]
Catalog.MARKETING = {
	kinds = {
		modelo = { name = "Campaña de modelo", desc = "Más demanda para un auto específico.", maxBoost = 0.8 },
		corporativa = { name = "Campaña corporativa", desc = "Más demanda para todos los modelos en venta y reconocimiento de marca.", maxBoost = 0.35, sizeCost = 0.25, perModelCost = 0.15, repPerMonth = 0.06 },
	},
	order = { "modelo", "corporativa" },
	budgetMin = 1000, -- presupuesto mensual (× época)
	budgetMax = 200000,
	budgetRef = 12000, -- presupuesto con el que se logra ≈ 63 % del efecto máximo
	daysMin = 15,
	daysMax = 180,
	era = { { 1970, 1 }, { 1980, 2.5 }, { 1990, 6 }, { 2000, 12 }, { 2010, 20 }, { 2030, 28 } },
}

-- Investigación: duración objetivo por nivel de importancia (minutos reales con la sede esperada de la época).
Catalog.RESEARCH_TIERS = {
	s = { label = "Mejora pequeña", minutes = 2 },
	n = { label = "Mejora", minutes = 5 },
	i = { label = "Tecnología importante", minutes = 9.5 },
	b = { label = "Gran avance", minutes = 14 },
}
-- Generación de PI que se espera tener en cada época (para dimensionar los costos, no para dar PI).
Catalog.EXPECTED_PI = { { 1970, 3 }, { 1972, 8 }, { 1975, 20 }, { 1982, 45 }, { 1994, 90 }, { 2030, 90 } }

-- Condiciones iniciales: todas las empresas empiezan igual (no hay dificultades), el 1 de enero de 1970.
Catalog.START = { money = 90000, reputation = 3.0 }

--[[ Compras con Robux (Developer Products, compra permanente registrada por recibo). id = 0: el producto
	todavía no está configurado en el panel de Roblox y la compra queda deshabilitada (no se simula nada).
	- slot3 / slot4: habilitan esa ranura de empresa en la cuenta (cada una por separado).
	- line3: la línea de producción 3, permanente para la CUENTA (vale en todas sus empresas, también en las que
	  cree después) e independiente de la línea 2. Se guarda en el perfil (profile.owned.line3). ]]
Catalog.PRODUCTS = {
	slot3 = { id = 0, kind = "slot", slot = "3", name = "Ranura de empresa 3" },
	slot4 = { id = 0, kind = "slot", slot = "4", name = "Ranura de empresa 4" },
	line3 = { id = 0, kind = "line3", name = "Línea de producción 3" },
}

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
	["Perlado"] = { unit = 1400, factory = 3 }, -- requiere la fábrica de nivel 3 (pintura industrial)
	["Cromado"] = { unit = 3200, factory = 3 },
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
	{ id = "pixel", name = "Pixel C1", brand = "Nordia", type = "compacto", level = 1, year = 1972, research = "ch_compacto", rarity = "Común",
		dev = 12000, unit = 7800, weight = 1080, handling = 58, comfort = 60, durability = 80, quality = 55, safety = 40, drag = 0.33, build = 150,
		tags = { "combustion" }, mats = { acero = 6, aluminio = 2, pintura = 1, electronica = 1 }, pop = 1.2,
		defaults = { motor = "i4", turbo = "none", transmision = "man4", traccion = "fwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none", seguridad = "basica" } },
	{ id = "brisa", name = "Sedán básico 1970", brand = "Vortex", type = "sedan", level = 1, year = 1970, research = nil, rarity = "Común",
		dev = 16000, unit = 10500, weight = 1350, handling = 60, comfort = 72, durability = 82, quality = 60, safety = 45, drag = 0.29, build = 180,
		tags = { "combustion" }, mats = { acero = 8, aluminio = 3, pintura = 1, electronica = 1 }, pop = 1.1,
		defaults = { motor = "i4", turbo = "none", transmision = "auto3", traccion = "fwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none", seguridad = "basica" } },
	{ id = "toro", name = "Toro Pickup", brand = "Kodiak", type = "pickup", level = 1, year = 1973, research = "ch_pickup", rarity = "Común",
		dev = 14000, unit = 9800, weight = 1750, handling = 46, comfort = 52, durability = 92, quality = 56, safety = 38, drag = 0.40, build = 230,
		tags = { "combustion", "offroad" }, mats = { acero = 13, aluminio = 2, pintura = 2, electronica = 1 }, pop = 0.95,
		defaults = { motor = "i6", turbo = "none", transmision = "man4", traccion = "x4", frenos = "std", suspension = "offroad", neumaticos = "at", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none", seguridad = "basica" } },
	{ id = "duna", name = "Coupé básico 1970", brand = "Halcón", type = "clasico", level = 1, year = 1970, research = nil, rarity = "Rara",
		dev = 22000, unit = 12500, weight = 1320, handling = 62, comfort = 64, durability = 72, quality = 64, safety = 40, drag = 0.36, build = 260,
		tags = { "combustion" }, mats = { acero = 9, aluminio = 2, pintura = 2, electronica = 1, cuero = 2 }, pop = 0.9,
		defaults = { motor = "i6", turbo = "none", transmision = "man4", traccion = "rwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "sport", peso = "none", seguridad = "basica" } },
	{ id = "brisa2", name = "Sedán 1978", brand = "Vortex", type = "sedan", level = 1, year = 1978, research = "ch_sedan2", rarity = "Común",
		dev = 22000, unit = 11800, weight = 1280, handling = 64, comfort = 76, durability = 85, quality = 64, safety = 52, drag = 0.27, build = 180,
		tags = { "combustion" }, mats = { acero = 8, aluminio = 3, pintura = 1, electronica = 1 }, pop = 1.1,
		defaults = { motor = "i4", turbo = "none", transmision = "auto3", traccion = "fwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none", seguridad = "basica" } },
	{ id = "brisa3", name = "Sedán 1988", brand = "Vortex", type = "sedan", level = 1, year = 1988, research = "ch_sedan3", rarity = "Común",
		dev = 30000, unit = 13500, weight = 1240, handling = 68, comfort = 80, durability = 88, quality = 68, safety = 60, drag = 0.25, build = 180,
		tags = { "combustion" }, mats = { acero = 8, aluminio = 3, pintura = 1, electronica = 1 }, pop = 1.1,
		defaults = { motor = "i4", turbo = "none", transmision = "auto3", traccion = "fwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none", seguridad = "basica" } },
	{ id = "duna2", name = "Coupé 1978", brand = "Halcón", type = "clasico", level = 1, year = 1978, research = "ch_coupe2", rarity = "Rara",
		dev = 26000, unit = 13600, weight = 1290, handling = 68, comfort = 66, durability = 75, quality = 67, safety = 46, drag = 0.33, build = 260,
		tags = { "combustion" }, mats = { acero = 9, aluminio = 2, pintura = 2, electronica = 1, cuero = 2 }, pop = 0.9,
		defaults = { motor = "i6", turbo = "none", transmision = "man4", traccion = "rwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "sport", peso = "none", seguridad = "basica" } },
	{ id = "aurora", name = "Aurora GT", brand = "Vortex", type = "deportivo", level = 1, year = 1975, research = "ca2", rarity = "Rara",
		dev = 30000, unit = 16500, weight = 1380, handling = 74, comfort = 55, durability = 74, quality = 66, safety = 42, drag = 0.30, build = 240,
		tags = { "combustion" }, mats = { acero = 7, aluminio = 5, pintura = 1, electronica = 2 }, pop = 1.0,
		defaults = { motor = "v6", turbo = "none", transmision = "man4", traccion = "rwd", frenos = "sport", suspension = "sport", neumaticos = "sport", bateria = "b12", refrigeracion = "std", escape = "sport", peso = "none", seguridad = "basica" } },
	{ id = "titan", name = "Titán SUV", brand = "Kodiak", type = "suv", level = 1, year = 1983, research = "ca3", rarity = "Común",
		dev = 26000, unit = 15000, weight = 1850, handling = 52, comfort = 74, durability = 86, quality = 62, safety = 55, drag = 0.36, build = 230,
		tags = { "combustion", "offroad" }, mats = { acero = 11, aluminio = 3, pintura = 2, electronica = 2 }, pop = 1.05,
		defaults = { motor = "v6", turbo = "none", transmision = "auto3", traccion = "x4", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "b12", refrigeracion = "std", escape = "std", peso = "none", seguridad = "basica" } },
	{ id = "vento", name = "Halcón Vento SS", brand = "Halcón", type = "superdeportivo", level = 1, year = 1986, research = "ca4", rarity = "Legendaria",
		dev = 90000, unit = 42000, weight = 1450, handling = 84, comfort = 44, durability = 66, quality = 80, safety = 50, drag = 0.27, build = 360,
		tags = { "combustion" }, mats = { acero = 5, aluminio = 9, pintura = 2, electronica = 3 }, pop = 0.7,
		defaults = { motor = "v8", turbo = "none", transmision = "man5", traccion = "rwd", frenos = "sport", suspension = "sport", neumaticos = "sport", bateria = "b12", refrigeracion = "pro", escape = "sport", peso = "none", seguridad = "basica" } },
	{ id = "rayo", name = "Rayo E", brand = "Kairo", type = "electrico", level = 1, year = 2010, research = "el5", rarity = "Rara",
		dev = 38000, unit = 19000, weight = 1720, handling = 66, comfort = 76, durability = 84, quality = 70, safety = 70, drag = 0.24, build = 250,
		tags = { "electrico" }, mats = { acero = 6, aluminio = 5, pintura = 1, electronica = 4, baterias = 8 }, pop = 1.0,
		defaults = { motor = "em200", turbo = "none", transmision = "single", traccion = "rwd", frenos = "std", suspension = "confort", neumaticos = "touring", bateria = "ev60", refrigeracion = "std", escape = "none", peso = "none", seguridad = "basica" } },
}

--[[ Carrocerías 3D definitivas (modelos hechos en Studio). Un diseño guarda cuál usa en `vehicleModel`
	(nil = la predeterminada de su tipo y su año de modelo; "provisional" = el modelo genérico de piezas).
	- type: tipo de vehículo que la puede usar (la base del diseño debe ser de ese tipo).
	- year: desde ese año se puede elegir y queda disponible para siempre (también en décadas posteriores).
	- default: años en que es la carrocería predeterminada de su tipo (diseños nuevos y diseños sin elección).
	- asset: nombre del Model en ServerStorage.VehicleModels (el servidor publica una copia para el cliente en
	  ReplicatedStorage.CarEmpireAssets.VehicleModels). Si no existe, se usa el modelo provisional.
	- paintSuffix: las piezas cuyo nombre termina así toman el color principal del diseño.
	- front: hacia dónde mira el frente en el modelo original ("-Z" por defecto, "+Z" si viene al revés). La
	  plantilla lo gira para que en el juego el frente mire siempre hacia −Z (el original no se toca).
	Es puramente visual: no cambia costos, estadísticas ni ventas. Para sumar otro auto, agregar una entrada. ]]
Catalog.VEHICLE_MODELS = {
	{ id = "pioneer70", name = "Pioneer 70", type = "sedan", year = 1970, default = { 1970, 1979 }, asset = "Pioneer70_World", paintSuffix = "_Paint", front = "+Z", -- paragolpes y faros delanteros hacia +Z
		desc = "Sedán compacto familiar de cuatro puertas (1972)" },
}
Catalog.PROVISIONAL_MODEL = "provisional"

function Catalog.vehicleModel(id: any): any
	if type(id) ~= "string" then
		return nil
	end
	for _, m in Catalog.VEHICLE_MODELS do
		if m.id == id then
			return m
		end
	end
	return nil
end

-- Carrocerías 3D que puede usar un tipo de vehículo (en orden del catálogo).
function Catalog.vehicleModelsFor(typeId: string): { any }
	local out = {}
	for _, m in Catalog.VEHICLE_MODELS do
		if m.type == typeId then
			table.insert(out, m)
		end
	end
	return out
end

-- Carrocería predeterminada de un tipo en un año (nil = no hay modelo 3D: se usa el provisional).
function Catalog.defaultVehicleModel(typeId: string, year: number): any
	for _, m in Catalog.VEHICLE_MODELS do
		if m.type == typeId and m.default and year >= m.default[1] and year <= m.default[2] then
			return m
		end
	end
	return nil
end

-- Carrocería 3D que corresponde a un diseño (o nil si va el modelo provisional). Una elección que no
-- coincide con el tipo de la base (por ejemplo, después de cambiar la base) vuelve a la predeterminada.
function Catalog.resolveVehicleModel(spec: any): any
	local base = Catalog.base(spec and spec.baseId)
	if not base or spec.vehicleModel == Catalog.PROVISIONAL_MODEL then
		return nil
	end
	local m = Catalog.vehicleModel(spec.vehicleModel)
	if m and m.type == base.type then
		return m
	end
	return Catalog.defaultVehicleModel(base.type, tonumber(spec.modelYear) or Catalog.CALENDAR.startYear)
end

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
	{ "seguridad", "Seguridad" },
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
	P("i4e", "motor", "4 cilindros 1.3 económico", "Común", 1973, nil, 0, 1700, "combustion", { hp = 68, kg = -25, eff = 9, dur = 5 }, "El más económico: gasta poco y casi no se rompe."),
	P("i4", "motor", "I4 1.6 · nivel 1", "Común", 1970, nil, 0, 2200, "combustion", { hp = 95, kg = 0, eff = 4, dur = 4 }, "Cuatro cilindros en línea: económico y confiable."),
	P("i6", "motor", "I6 2.5 · nivel 1", "Común", 1970, nil, 2500, 3200, "combustion", { hp = 125, kg = 45, eff = -1, dur = 5, q = 1 }, "Seis cilindros en línea: suave, robusto y con más fuerza que el I4."),
	P("i4v", "motor", "4 cilindros 2.0 16V", "Rara", 1984, "mo4", 7000, 3300, "combustion", { hp = 140, kg = 10, eff = 5, dur = 3, q = 2 }, "Inyección electrónica y cuatro válvulas por cilindro."),
	P("i3t", "motor", "3 cilindros 1.0 turbo", "Rara", 2012, "mo8", 9000, 3000, "combustion", { hp = 120, kg = -30, eff = 13, dur = 2, q = 2 }, "Pequeño, con inyección directa y turbo integrado."),
	P("v6", "motor", "V6 2.8", "Rara", 1975, nil, 6000, 4800, "combustion", { hp = 150, kg = 60, eff = -4, q = 2 }, "Más fuerza para sedanes y pickups."),
	P("v6i", "motor", "V6 3.5 de distribución variable", "Rara", 1993, "mo6", 12000, 6200, "combustion", { hp = 235, kg = 55, eff = -1, q = 4, dur = 2 }, "Potente y eficiente a la vez."),
	P("v8", "motor", "V8 5.0", "Épica", 1970, "mo2", 18000, 9500, "combustion", { hp = 230, kg = 110, eff = -10, q = 4, dur = -3 }, "Gran cilindrada para deportivos."),
	P("v8d", "motor", "V8 6.2 de inyección directa", "Épica", 2006, "mo8", 26000, 12500, "combustion", { hp = 430, kg = 120, eff = -6, q = 6 }, "Mucha potencia con un consumo razonable."),
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
	-- Seguridad (paquetes: cada uno incluye lo del anterior)
	P("basica", "seguridad", "Seguridad básica", "Común", 1970, nil, 0, 0, nil, {}, "Cinturones abdominales: lo mínimo de la época."),
	P("cint3", "seguridad", "Cinturones de tres puntos", "Común", 1970, "se1", 1000, 300, nil, { safety = 8 }, "Cinturones de tres puntos y apoyacabezas."),
	P("airbag", "seguridad", "Bolsas de aire frontales", "Rara", 1989, "se4", 6000, 1100, nil, { safety = 18, kg = 8 }, "Cinturones y bolsas de aire para conductor y acompañante."),
	P("airbag6", "seguridad", "Seis bolsas de aire y control de estabilidad", "Rara", 1998, "se5", 9000, 1700, nil, { safety = 24, kg = 12, grip = 2, q = 1 }, "Bolsas frontales y laterales, y control electrónico de estabilidad."),
	P("adas", "seguridad", "Asistentes de conducción", "Épica", 2014, "se6", 15000, 2600, nil, { safety = 32, kg = 14, grip = 2, q = 3 }, "Frenado autónomo de emergencia, carril y punto ciego."),
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

--[[ Instalaciones (Compañía › Instalaciones). Valores provisionales. Cada mejora se paga al empezar y es una
	OBRA que dura `days` días de juego (la organización del personal de Administración la acelera; la gestión
	abarata el costo). Una obra por instalación a la vez.
	- Oficinas centrales (g.sede, 1–5): límite GLOBAL de empleados, alcance comercial, niveles de capacitación
	  (TRAINING.levels[i].office) y la expansión internacional. Piden ventas y reputación. Sus niveles conservan
	  los nombres de las etapas de la empresa (Garaje inicial … Imperio automotriz).
	- Fábrica (1–5): autos por minuto de cada línea, calidad y costo de fabricación (fx, como lo que antes eran
	  las investigaciones de producción), acabados perlado y cromado desde el nivel 3, y el edificio del garaje.
	  No da líneas.
	- Centro de investigación (1–5): PI por minuto.
	- Líneas: la 1 viene siempre; la 2 se compra con dinero (obra); la 3 es un desbloqueo permanente con Robux
	  (Catalog.PRODUCTS.line3) de la cuenta, independiente de la 2. Ninguna mejora da líneas sola.
	La fábrica y el centro no pueden superar el nivel de las oficinas. ]]
Catalog.SEDES = {
	{ level = 1, name = "Garaje inicial", office = "Oficinas básicas", reach = 1, staff = 3, cost = 0, days = 0, req = { sold = 0, rep = 0 } },
	{ level = 2, name = "Empresa pequeña", office = "Oficinas ampliadas", reach = 2.5, staff = 8, cost = 300000, days = 60, req = { sold = 300, rep = 3.0 } },
	{ level = 3, name = "Sede empresarial", office = "Sede corporativa", reach = 6, staff = 16, cost = 2500000, days = 120, req = { sold = 3000, rep = 3.4 } },
	{ level = 4, name = "Corporación automotriz", office = "Torre corporativa", reach = 11, staff = 30, cost = 60000000, days = 200, req = { sold = 20000, rep = 3.9 } },
	{ level = 5, name = "Imperio automotriz", office = "Casa matriz global", reach = 20, staff = 50, cost = 400000000, days = 300, req = { sold = 100000, rep = 4.3 } },
}
Catalog.FACILITIES = {
	order = { "offices", "factory", "research" },
	offices = { name = "Oficinas centrales", icon = "building" },
	factory = { name = "Fábrica", icon = "factory", levels = {
		{ level = 1, name = "Garaje pequeño", perLine = 15, cost = 0, days = 0, asset = "Sede1", fx = {} },
		{ level = 2, name = "Taller mecánico", perLine = 25, cost = 200000, days = 45, asset = "Sede2", fx = { quality = 1, unitCostPct = -3 } },
		{ level = 3, name = "Fábrica", perLine = 55, cost = 1500000, days = 90, asset = "Sede3", fx = { quality = 3, unitCostPct = -6 } },
		{ level = 4, name = "Planta industrial", perLine = 100, cost = 30000000, days = 150, asset = "Sede4", fx = { quality = 4, unitCostPct = -10 } },
		{ level = 5, name = "Complejo automotriz", perLine = 170, cost = 200000000, days = 240, asset = "Sede5", fx = { quality = 5, unitCostPct = -15 } },
	} },
	research = { name = "Centro de investigación", icon = "flask", levels = {
		{ level = 1, name = "Centro inicial", pi = 3, cost = 0, days = 0 },
		{ level = 2, name = "Laboratorio", pi = 8, cost = 150000, days = 45 },
		{ level = 3, name = "Centro de I+D", pi = 20, cost = 1200000, days = 90 },
		{ level = 4, name = "Instituto tecnológico", pi = 45, cost = 25000000, days = 150 },
		{ level = 5, name = "Campus de innovación", pi = 90, cost = 150000000, days = 240 },
	} },
	line2 = { name = "Línea de producción 2", cost = 150000, days = 30 },
	maxLines = 3,
	-- Mantenimiento mensual: este porcentaje de lo invertido en instalaciones (la eficiencia financiera lo baja),
	-- con un tope de maintenanceRevenueCap de las ventas del mes anterior: sin ventas no se cobra, así el
	-- mantenimiento nunca deja a una empresa sin poder fabricar.
	maintenanceRate = 0.003,
	maintenanceRevenueCap = 0.1,
}

-- Expansión global (después del Imperio automotriz): cada región abre mercados nuevos (+15 % de demanda
-- en todos los tipos, repartida con las mismas reglas entre vos y los rivales) y suma capacidad a las
-- líneas. Costo creciente (cost × growth^(n−1)) y ventas acumuladas mínimas. Las campañas cuestan más
-- con cada región (se anuncia en más mercados).
Catalog.EXPANSION = {
	cost = 80000000,
	growth = 1.4,
	demand = 0.15, -- +15 % de demanda por país
	line = 0.12, -- +12 % de autos por minuto en cada línea por país (capacidad global de la empresa)
	soldBase = 110000,
	soldStep = 35000,
	-- Países disponibles (ids y orden estables: las partidas viejas que solo guardaban la cantidad de regiones
	-- toman los primeros N de esta lista). Se abren en el orden que elija el jugador.
	--[[ prefs = perfil de preferencias del mercado de ese país por tipo de vehículo (Catalog.TYPE_ORDER).
		PARÁMETROS FICTICIOS DE EQUILIBRIO DEL JUEGO, no estadísticas de mercados reales. Solo reparten entre
		tipos el +15 % de demanda que aporta cada país (Rules.countryWeights): el volumen total es el mismo que con
		pesos iguales y un tipo sin demanda en su época sigue sin demanda. Un tipo que no figura pesa 1. ]]
	countries = {
		{ id = "BR", name = "Brasil", prefs = { compacto = 1.5, sedan = 1.1, clasico = 0.8, pickup = 1.3, deportivo = 0.7, suv = 0.9, superdeportivo = 0.6, electrico = 0.7 } },
		{ id = "US", name = "Estados Unidos", prefs = { compacto = 0.6, sedan = 1.1, clasico = 1.2, pickup = 1.6, deportivo = 1.2, suv = 1.5, superdeportivo = 1.1, electrico = 1.0 } },
		{ id = "DE", name = "Alemania", prefs = { compacto = 1.1, sedan = 1.4, clasico = 0.9, pickup = 0.6, deportivo = 1.4, suv = 1.0, superdeportivo = 1.3, electrico = 1.2 } },
		{ id = "PL", name = "Polonia", prefs = { compacto = 1.5, sedan = 1.2, clasico = 1.0, pickup = 0.8, deportivo = 0.7, suv = 1.0, superdeportivo = 0.6, electrico = 0.8 } },
		{ id = "JP", name = "Japón", prefs = { compacto = 1.6, sedan = 1.2, clasico = 0.7, pickup = 0.6, deportivo = 1.3, suv = 0.8, superdeportivo = 0.9, electrico = 1.4 } },
		{ id = "TH", name = "Tailandia", prefs = { compacto = 1.2, sedan = 1.0, clasico = 0.7, pickup = 1.6, deportivo = 0.7, suv = 1.1, superdeportivo = 0.6, electrico = 0.9 } },
		{ id = "IN", name = "India", prefs = { compacto = 1.6, sedan = 1.1, clasico = 0.7, pickup = 0.9, deportivo = 0.6, suv = 1.2, superdeportivo = 0.6, electrico = 1.0 } },
		{ id = "AU", name = "Australia", prefs = { compacto = 0.8, sedan = 1.0, clasico = 1.0, pickup = 1.5, deportivo = 1.1, suv = 1.5, superdeportivo = 0.9, electrico = 0.8 } },
		{ id = "AE", name = "Emiratos Árabes Unidos", prefs = { compacto = 0.6, sedan = 1.1, clasico = 0.9, pickup = 0.9, deportivo = 1.3, suv = 1.6, superdeportivo = 1.6, electrico = 0.8 } },
		{ id = "ZA", name = "Sudáfrica", prefs = { compacto = 1.3, sedan = 1.0, clasico = 0.8, pickup = 1.5, deportivo = 0.8, suv = 1.1, superdeportivo = 0.6, electrico = 0.7 } },
	},
	regions = {}, -- nombres (compatibilidad): se completa abajo con los de `countries`
}
for _, c in Catalog.EXPANSION.countries do
	table.insert(Catalog.EXPANSION.regions, c.name)
end

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
-- Roles de versiones anteriores (solo para migrar empleados viejos a los departamentos nuevos).
Catalog.LEGACY_ROLES = { ["Mecánico"] = "produccion", ["Inspector"] = "produccion", ["Diseñador"] = "produccion", ["Ingeniero"] = "investigacion", ["Vendedor"] = "marketing", ["Marketing"] = "marketing", ["Gerente"] = "administracion" }
--[[ Críticos especializados: cada uno pondera distintos aspectos del auto (índices 0–100 de Rules.indices más
	«tech», el nivel tecnológico frente a la época). La nota (1–10) compara eso con lo que espera el mercado
	ese año: un auto promedio de su época saca ≈ 5,5. Las reseñas se calculan UNA vez, al terminar el lote, y
	se guardan. ]]
Catalog.CRITICS = {
	{ id = "familia", name = "Marta Ríos", outlet = "Revista Ruta & Familia", style = "Piensa en la familia: comodidad, seguridad y que no se rompa.",
		weights = { comfort = 0.35, safety = 0.35, dur = 0.3 } },
	{ id = "pista", name = "Tomás Vega", outlet = "Pista Libre", style = "Fanático de las prestaciones: aceleración, velocidad y manejo.",
		weights = { power = 0.55, hand = 0.35, quality = 0.1 } },
	{ id = "bolsillo", name = "Elena Duarte", outlet = "El Bolsillo Motor", style = "Cuida cada peso: consumo, confiabilidad y lo que cuesta fabricarlo.",
		weights = { eco = 0.45, dur = 0.3, value = 0.25 } },
	{ id = "tendencias", name = "Héctor Lanz", outlet = "Clásicos y Tendencias", style = "Mira la terminación y si el auto está a la altura de su época.",
		weights = { quality = 0.5, tech = 0.5 } },
}
-- Lo que espera un crítico de un auto promedio de cada época (índices 0–100 de Rules.indices). Un auto justo
-- en lo esperado saca 6; cada `reviewScale` puntos de diferencia ponderada suman o restan uno.
Catalog.CRITIC_EXPECT = {
	power = { { 1970, 15 }, { 1990, 45 }, { 2010, 60 }, { 2030, 65 } },
	eco = { { 1970, 80 }, { 2030, 80 } },
	comfort = { { 1970, 78 }, { 1990, 80 }, { 2010, 85 }, { 2030, 88 } },
	safety = { { 1970, 50 }, { 1990, 70 }, { 2010, 75 }, { 2030, 80 } },
	dur = { { 1970, 85 }, { 1990, 90 }, { 2030, 93 } },
	hand = { { 1970, 60 }, { 1990, 70 }, { 2030, 75 } },
	quality = { { 1970, 70 }, { 1990, 78 }, { 2010, 85 }, { 2030, 88 } },
}
Catalog.CRITIC_ASPECTS = {
	comfort = "la comodidad", safety = "la seguridad", dur = "la confiabilidad", power = "las prestaciones", hand = "el manejo",
	eco = "el consumo", quality = "la terminación", tech = "la tecnología", value = "la relación entre lo que ofrece y lo que cuesta",
}

Catalog.FIRST = { "Sofía", "Mateo", "Lara", "Julián", "Carla", "Ramiro", "Elena", "Diego", "Ana", "Pablo", "Inés", "Tomás", "Valentina", "Bruno", "Camila", "Martina", "Lucía", "Joaquín", "Abril", "Nicolás" }
Catalog.LAST = { "Arce", "Ruiz", "Sosa", "Paz", "Vega", "Gil", "Bruno", "Mora", "Núñez", "Ortiz", "Ríos", "Pereyra", "Luna", "Ferrari", "Medina", "Romero" }

--[[ Personal (valores provisionales, centralizados acá para equilibrar).
	Cuatro departamentos con tres habilidades cada uno. Cada habilidad (0–100) da un beneficio propio con su
	LÍMITE propio: per = beneficio que aporta un empleado con 100 puntos y productividad plena; cap = máximo
	de la empresa (los aportes se suman hasta ese tope). unit "pct" = porcentaje (0,10 = 10 %), "pts" = puntos.
	Los empleados nunca suman PI por minuto: Investigación reduce PI, días y dinero de cada proyecto. ]]
Catalog.STAFF = {
	departments = {
		{ id = "produccion", name = "Producción", color = "#FFA050", icon = "factory", skills = { "velocidad", "calidad", "eficiencia" } },
		{ id = "investigacion", name = "Investigación", color = "#50D2E6", icon = "flask", skills = { "conocimiento", "creatividad", "precision" } },
		{ id = "marketing", name = "Marketing", color = "#FF78AA", icon = "tag", skills = { "mk_creatividad", "analisis", "comunicacion" } },
		{ id = "administracion", name = "Administración", color = "#C9CED8", icon = "building", skills = { "organizacion", "finanzas", "gestion" } },
	},
	skills = {
		velocidad = { dept = "produccion", name = "Velocidad", effect = "menos tiempo de fabricación", per = 0.10, cap = 0.30, unit = "pct" },
		calidad = { dept = "produccion", name = "Calidad", effect = "puntos de calidad en los autos que se terminan", per = 3, cap = 8, unit = "pts" },
		eficiencia = { dept = "produccion", name = "Eficiencia", effect = "menor costo de fabricación", per = 0.05, cap = 0.15, unit = "pct" },
		conocimiento = { dept = "investigacion", name = "Conocimiento", effect = "menos PI necesarios", per = 0.08, cap = 0.25, unit = "pct" },
		creatividad = { dept = "investigacion", name = "Creatividad", effect = "investigaciones más cortas", per = 0.08, cap = 0.30, unit = "pct" },
		precision = { dept = "investigacion", name = "Precisión", effect = "menor costo en dinero de investigar", per = 0.08, cap = 0.25, unit = "pct" },
		mk_creatividad = { dept = "marketing", name = "Creatividad", effect = "campañas más efectivas", per = 0.10, cap = 0.35, unit = "pct" },
		analisis = { dept = "marketing", name = "Análisis de mercado", effect = "campañas más baratas", per = 0.08, cap = 0.25, unit = "pct" },
		comunicacion = { dept = "marketing", name = "Comunicación", effect = "campañas que duran más", per = 0.10, cap = 0.40, unit = "pct" },
		organizacion = { dept = "administracion", name = "Organización", effect = "obras y mejoras más rápidas", per = 0.10, cap = 0.40, unit = "pct" },
		finanzas = { dept = "administracion", name = "Eficiencia financiera", effect = "menores gastos operativos y de mantenimiento", per = 0.08, cap = 0.25, unit = "pct" },
		gestion = { dept = "administracion", name = "Gestión", effect = "expansiones más baratas", per = 0.06, cap = 0.20, unit = "pct" },
	},
	-- Transferencias: fuera de su especialidad un empleado empieza al adaptStart de productividad y llega al
	-- 100 % en adaptDays días de juego (una capacitación en ese departamento suma trainingAdapt).
	adaptStart = 0.5,
	adaptDays = 180,
	trainingAdapt = 0.2,
	trainingProductivity = 0.8, -- productividad mientras se capacita (sigue trabajando)
	-- Deuda salarial: cada mes con sueldos atrasados baja la productividad (nunca renuncian).
	debtProductivityPerMonth = 0.1,
	debtProductivityFloor = 0.5,
	debtRecoveryShare = 0.3, -- parte de cada venta que se destina a pagar sueldos atrasados
	-- Experiencia: cada expEvery meses trabajados suma expGain a las habilidades de su departamento actual.
	expEvery = 6,
	expGain = 1,
	-- Salario mensual = (base + perPoint × promedio de las habilidades de su especialidad) × época.
	salaryBase = 700,
	salaryPerPoint = 35,
	salaryEra = { { 1970, 1 }, { 1980, 2.2 }, { 1990, 4 }, { 2000, 6 }, { 2010, 8 }, { 2030, 11 } },
	-- Mercado laboral: candidatos por mes (se reemplazan), búsquedas pagas y probabilidad de talentos.
	candidatesPerMonth = 8,
	searchBase = 1000, -- búsqueda general (× época)
	searchSpecialMult = 1.5, -- la especializada cuesta 50 % más
	searchGrowth = 1.5, -- cada búsqueda del mismo mes cuesta 50 % más que la anterior (contador compartido)
	searchFocus = 0.5, -- especializada: probabilidad de que cada candidato sea del departamento elegido
	exceptionalChance = 0.03, -- candidato extraordinario, posible aun con reputación baja
}

--[[ Capacitaciones (valores provisionales). costo = cost × participantes × época; días de juego; gain = puntos
	GARANTIZADOS (sin azar), que nunca superan el potencial de cada participante. office = nivel de oficinas
	centrales que la habilita (Compañía › Instalaciones). Un empleado hace una sola a la vez y sigue
	trabajando con menos productividad (STAFF.trainingProductivity). ]]
Catalog.TRAINING = {
	levels = {
		{ id = "basico", name = "Básico", cost = 800, days = 20, gain = 3, office = 1 },
		{ id = "intermedio", name = "Intermedio", cost = 2500, days = 45, gain = 7, office = 2 },
		{ id = "avanzado", name = "Avanzado", cost = 7000, days = 90, gain = 12, office = 3 },
	},
	scopes = { individual = "Individual", departamento = "Departamento", general = "General (toda la empresa)" },
	-- Sin tope propio de capacitaciones simultáneas: cada empleado hace una a la vez, así que nunca hay más que
	-- empleados. maxActive (= el límite global de empleados con las oficinas máximas) es solo una protección del
	-- guardado contra datos dañados; se completa debajo, cuando ya existen las oficinas.
	maxActive = 0,
}
Catalog.TRAINING.maxActive = Catalog.SEDES[#Catalog.SEDES].staff

--[[ Investigación y desarrollo (I+D). Cuatro categorías del departamento de I+D: Chasis, Motores,
	Seguridad y Tecnología (las mejoras de producción de versiones anteriores ahora son niveles de la fábrica y
	las de marketing, campañas y oficinas). Cada nodo:
	year = año en que aparece (se puede investigar hasta RESEARCH_RULES.aheadMaxYears antes, con recargo)
	tier = complejidad s/n/i/b (o `complexity` 1–5): define el costo base en PI, dinero y días
	req = tecnologías previas · fx = efectos automáticos de la empresa (fabricación, marketing, motores)
	Las piezas, bases, opciones y equipamiento que nombran el id del nodo en `research` se desbloquean al
	completarlo; el equipamiento NO se instala solo: se elige en cada diseño. Los niveles de motor
	(eng_<familia>_<n>) se generan al final del módulo. ]]
--[[ Reglas de I+D (valores provisionales, centralizados acá):
	- Costo base según la COMPLEJIDAD (1–5) de cada tecnología: PI, dinero y días. El año agrega un ajuste
	  menor a los PI (piEraGrowth) y el dinero sigue a la economía de la época (moneyEra).
	- Adelanto: se puede investigar hasta aheadMaxYears antes del año de la tecnología; cada año de adelanto
	  suma aheadMoney al dinero, aheadPi a los PI y aheadDays a la duración.
	- PI: el centro de investigación genera FACILITIES.research.levels[n].pi por minuto real a 1×; cada
	  línea que está fabricando suma linePi. Sin tope de acumulación.
	- maxParallel: investigaciones simultáneas como máximo. ]]
Catalog.RESEARCH_RULES = {
	complexityOfTier = { s = 1, n = 2, i = 3, b = 4 },
	complexityLabel = { "Mejora menor", "Mejora", "Tecnología importante", "Gran avance", "Hito tecnológico" },
	pi = { 10, 30, 80, 200, 450 },
	piEraGrowth = 0.03,
	money = { 5000, 15000, 45000, 120000, 300000 },
	moneyEra = { { 1970, 1 }, { 1980, 2.5 }, { 1990, 6.5 }, { 2000, 13 }, { 2010, 20 }, { 2030, 27 } },
	days = { 30, 60, 120, 200, 300 },
	aheadMaxYears = 5,
	aheadMoney = 0.15,
	aheadPi = 0.15,
	aheadDays = 0.10,
	linePi = 2,
	maxParallel = 6,
	engineMaxLevel = 10,
	advancedEngineTuning = false, -- modo avanzado de personalización de motores (etapa futura; no se muestra)
}

-- Familias de motores: cada una tiene 10 niveles (el 1 viene con el motor). first = año del nivel 1;
-- req = tecnología necesaria para empezar a mejorarla.
Catalog.ENGINE_FAMILIES = {
	{ id = "I4", name = "I4", first = 1970 },
	{ id = "I6", name = "I6", first = 1970 },
	{ id = "V6", name = "V6", first = 1975 },
	{ id = "V8", name = "V8", first = 1970, req = "mo2" },
	{ id = "I3", name = "I3 turbo", first = 2012, req = "mo8" },
	{ id = "EV", name = "Eléctrico", first = 2010, req = "el5" },
}
-- Efecto de cada nivel por encima del 1 (acumulativo): potencia, consumo, costo del motor y calidad.
Catalog.ENGINE_LEVEL_FX = { hp = 0.06, cons = -0.03, cost = 0.07, q = 0.4 }
-- Variantes: la equilibrada viene de fábrica; la económica y la deportiva se investigan una vez y sirven para
-- todos los motores a combustión.
Catalog.ENGINE_VARIANTS = {
	{ id = "balanced", name = "Equilibrada", hp = 1, cons = 1, cost = 1, q = 0 },
	{ id = "eco", name = "Económica", research = "var_eco", hp = 0.88, cons = 0.85, cost = 0.97, q = 0, need = "combustion" },
	{ id = "sport", name = "Deportiva", research = "var_sport", hp = 1.15, cons = 1.12, cost = 1.1, q = 1, need = "combustion" },
}
function Catalog.engineVariant(id: any): any
	for _, v in Catalog.ENGINE_VARIANTS do
		if v.id == id then
			return v
		end
	end
	return nil
end

--[[ Equipamiento (seguridad y tecnología/confort): cada elemento se investiga y después se ELIGE en cada
	diseño (no se instala solo). unit = costo por unidad (escala del catálogo); fx = efectos sobre el auto. ]]
Catalog.EQUIPMENT = {
	{ id = "crumple", name = "Estructura con zonas de deformación", group = "seguridad", research = "se2", unit = 300, fx = { safety = 10 } },
	{ id = "radio", name = "Radio AM/FM", group = "tecnologia", research = "te_radio", unit = 180, fx = { comfort = 3 } },
	{ id = "ac", name = "Aire acondicionado", group = "tecnologia", research = "co1", unit = 650, fx = { comfort = 7, kg = 15 } },
	{ id = "windows", name = "Ventanillas eléctricas", group = "tecnologia", research = "te_win", unit = 300, fx = { comfort = 3, q = 1 } },
	{ id = "steering", name = "Dirección asistida", group = "tecnologia", research = "co3", unit = 400, fx = { comfort = 4, grip = 2 } },
	{ id = "tripcomp", name = "Computadora de a bordo", group = "tecnologia", research = "el2", unit = 350, fx = { q = 2, eff = 2 } },
	{ id = "nav", name = "Navegador satelital", group = "tecnologia", research = "te_nav", unit = 900, fx = { comfort = 3, q = 2 } },
	{ id = "pdc", name = "Sensores de estacionamiento", group = "tecnologia", research = "te_pdc", unit = 250, fx = { safety = 2, comfort = 2 } },
	{ id = "camera", name = "Cámara de retroceso", group = "tecnologia", research = "te_cam", unit = 350, fx = { safety = 3, q = 1 } },
	{ id = "touch", name = "Pantalla táctil y conectividad", group = "tecnologia", research = "te_touch", unit = 600, fx = { comfort = 4, q = 2 } },
}
function Catalog.equipment(id: any): any
	for _, e in Catalog.EQUIPMENT do
		if e.id == id then
			return e
		end
	end
	return nil
end

Catalog.RESEARCH_ORDER = { "chasis", "motores", "seguridad", "tecnologia" }
Catalog.RESEARCH = {
	chasis = { label = "Chasis", nodes = {
		{ id = "ca1", name = "Carrocería reforzada", year = 1970, tier = "s", req = {}, fx = { durability = 4, safety = 2 }, gain = "+4 de durabilidad y +2 de seguridad" },
		{ id = "ca2", name = "Plataforma de coupé deportivo", year = 1975, tier = "n", req = {}, fx = {}, gain = "Habilita el Aurora GT (deportivo)" },
		{ id = "ca3", name = "Plataforma SUV", year = 1983, tier = "i", req = { "ca1" }, fx = {}, gain = "Habilita el Titán SUV" },
		{ id = "ca4", name = "Superdeportivo de motor central", year = 1986, tier = "b", req = { "mo2", "ca2" }, fx = {}, gain = "Habilita el Halcón Vento SS" },
		{ id = "ca5", name = "Plataforma modular", year = 2002, tier = "i", req = { "ca3" }, fx = { unitCostPct = -6, quality = 2 }, gain = "−6 % de costo por unidad y +2 de calidad" },
		{ id = "ma1", name = "Túnel de viento", year = 1972, tier = "n", req = {}, fx = { topPct = 4, consPct = -3 }, gain = "+4 % de velocidad máxima y −3 % de consumo" },
		{ id = "ma2", name = "Refrigeración de competición", year = 1978, tier = "n", req = { "ma1" }, fx = {}, gain = "Habilita la refrigeración de competición" },
		{ id = "ma3", name = "Paneles de aluminio", year = 1985, tier = "n", req = {}, fx = {}, gain = "Habilita paneles de aluminio (−40 kg)" },
		{ id = "ma4", name = "Escape de titanio", year = 1997, tier = "n", req = { "ma3" }, fx = {}, gain = "Habilita el escape de titanio" },
		{ id = "ma5", name = "Fibra de carbono", year = 2000, tier = "i", req = { "ma3" }, fx = {}, gain = "Habilita fibra de carbono, capó y difusor de carbono" },
		{ id = "ma6", name = "Frenos carbono-cerámicos", year = 2003, tier = "i", req = { "ma5" }, fx = {}, gain = "Habilita frenos carbono-cerámicos" },
		{ id = "ma7", name = "Aerodinámica activa", year = 2012, tier = "n", req = { "ma1" }, fx = { spoilerGrip = 4 }, gain = "+4 de manejo con alerón instalado" },
		{ id = "ch_compacto", name = "Plataforma compacta 1972", year = 1972, tier = "n", req = {}, fx = {}, gain = "Habilita el chasis compacto Pixel C1" },
		{ id = "ch_pickup", name = "Plataforma pickup 1973", year = 1973, tier = "n", req = {}, fx = {}, gain = "Habilita el chasis pickup Toro" },
		{ id = "ch_sedan2", name = "Sedán 2.ª generación (1978)", year = 1978, tier = "i", req = { "ca1" }, fx = {}, gain = "Habilita el chasis «Sedán 1978»: más liviano, cómodo y seguro que el de 1970" },
		{ id = "ch_coupe2", name = "Coupé 2.ª generación (1978)", year = 1978, tier = "i", req = { "ca1" }, fx = {}, gain = "Habilita el chasis «Coupé 1978»: mejor manejo y más prestaciones" },
		{ id = "ch_sedan3", name = "Sedán 3.ª generación (1988)", year = 1988, tier = "b", req = { "ch_sedan2" }, fx = {}, gain = "Habilita el chasis «Sedán 1988»: aerodinámico y con estructura moderna" },
	} },
	motores = { label = "Motores", nodes = {
		{ id = "mo1", name = "Carburador de doble cuerpo", year = 1970, tier = "s", req = {}, fx = { hpPct = 5 }, gain = "+5 % de potencia en motores a combustión" },
		{ id = "mo2", name = "V8 de gran cilindrada", year = 1970, tier = "i", req = {}, fx = {}, gain = "Habilita el motor V8 5.0" },
		{ id = "mo3", name = "Turbocompresor", year = 1977, tier = "n", req = { "mo1" }, fx = {}, gain = "Habilita el turbocompresor simple" },
		{ id = "mo4", name = "Inyección electrónica", year = 1983, tier = "i", req = { "mo1" }, fx = { hpPct = 6, consPct = -8 }, gain = "+6 % de potencia y −8 % de consumo" },
		{ id = "mo5", name = "Compresor volumétrico", year = 1985, tier = "n", req = { "mo3" }, fx = {}, gain = "Habilita el compresor volumétrico" },
		{ id = "mo6", name = "Distribución variable", year = 1993, tier = "n", req = { "mo4" }, fx = { hpPct = 5, consPct = -5 }, gain = "+5 % de potencia y −5 % de consumo" },
		{ id = "mo7", name = "Turbo twin-scroll", year = 1996, tier = "n", req = { "mo3" }, fx = {}, gain = "Habilita el turbo twin-scroll" },
		{ id = "mo8", name = "Inyección directa", year = 2006, tier = "i", req = { "mo6" }, fx = { hpPct = 5, consPct = -8 }, gain = "+5 % de potencia y −8 % de consumo" },
		{ id = "el1", name = "Encendido electrónico", year = 1975, tier = "s", req = {}, fx = { durability = 3, consPct = -3 }, gain = "+3 de durabilidad y −3 % de consumo" },
		{ id = "tr1", name = "Caja manual de 5 velocidades", year = 1977, tier = "s", req = {}, fx = {}, gain = "Habilita la caja manual de 5 velocidades" },
		{ id = "tr2", name = "Tracción integral permanente", year = 1982, tier = "i", req = {}, fx = {}, gain = "Habilita la tracción integral" },
		{ id = "tr3", name = "Automática con overdrive", year = 1984, tier = "n", req = { "tr1" }, fx = {}, gain = "Habilita la automática de 4 velocidades" },
		{ id = "tr4", name = "Doble embrague", year = 2003, tier = "i", req = { "tr3" }, fx = {}, gain = "Habilita la caja de doble embrague" },
		{ id = "tr5", name = "Automática de 8 velocidades", year = 2008, tier = "n", req = { "tr3" }, fx = {}, gain = "Habilita la automática de 8 velocidades" },
		{ id = "el4", name = "Sistema híbrido", year = 2006, tier = "i", req = { "el2" }, fx = {}, gain = "Habilita el sistema híbrido" },
		{ id = "el5", name = "Baterías de iones de litio", year = 2010, tier = "b", req = { "el4" }, fx = {}, gain = "Habilita el Rayo E, el motor eléctrico y la batería de 60 kWh" },
		{ id = "el6", name = "Baterías de alta densidad", year = 2016, tier = "i", req = { "el5" }, fx = {}, gain = "Habilita la batería de 80 kWh y el motor de 350 kW" },
		{ id = "el7", name = "Baterías de estado sólido", year = 2024, tier = "b", req = { "el6" }, fx = {}, gain = "Habilita la batería de estado sólido" },
		{ id = "var_eco", name = "Variante de motor económica", year = 1973, tier = "n", req = {}, fx = {}, gain = "Variante «Económica» para todos los motores a combustión: −15 % de consumo, −12 % de potencia y −3 % de costo del motor" },
		{ id = "var_sport", name = "Variante de motor deportiva", year = 1974, tier = "n", req = {}, fx = {}, gain = "Variante «Deportiva» para todos los motores a combustión: +15 % de potencia, +12 % de consumo, +1 de calidad y +10 % de costo del motor" },
	} },
	seguridad = { label = "Seguridad", nodes = {
		{ id = "se1", name = "Cinturones de tres puntos", year = 1970, tier = "s", req = {}, fx = {}, gain = "Habilita el paquete «Cinturones de tres puntos» (+8 de seguridad)" },
		{ id = "se2", name = "Zonas de deformación", year = 1977, tier = "n", req = { "se1" }, fx = {}, gain = "Habilita «Estructura con zonas de deformación» en el equipamiento de seguridad (+10 de seguridad)" },
		{ id = "se3", name = "Frenos ABS", year = 1986, tier = "i", req = { "se2" }, fx = {}, gain = "Habilita frenos con ABS" },
		{ id = "se4", name = "Bolsas de aire", year = 1989, tier = "i", req = { "se2" }, fx = {}, gain = "Habilita el paquete «Bolsas de aire frontales» (+18 de seguridad)" },
		{ id = "se5", name = "Control de estabilidad", year = 1998, tier = "n", req = { "se3", "se4" }, fx = {}, gain = "Habilita el paquete de seis bolsas de aire y control de estabilidad (+24 de seguridad, +4 de manejo)" },
		{ id = "se6", name = "Asistentes de conducción", year = 2014, tier = "b", req = { "se5" }, fx = {}, gain = "Habilita el paquete de asistentes de conducción (+32 de seguridad, +2 de calidad)" },
	} },
	tecnologia = { label = "Tecnología y confort", nodes = {
		{ id = "co1", name = "Aire acondicionado", year = 1972, tier = "s", req = {}, fx = {}, gain = "Habilita el «Aire acondicionado» en el equipamiento (+7 de comodidad)" },
		{ id = "co2", name = "Butacas deportivas", year = 1976, tier = "s", req = {}, fx = {}, gain = "Habilita butacas deportivas" },
		{ id = "co3", name = "Dirección asistida", year = 1979, tier = "n", req = { "co1" }, fx = {}, gain = "Habilita la «Dirección asistida» en el equipamiento (+4 de comodidad y +2 de manejo)" },
		{ id = "co4", name = "Tapizados premium", year = 1990, tier = "n", req = { "co3" }, fx = {}, gain = "Habilita el tapizado de Alcántara" },
		{ id = "co5", name = "Suspensión neumática", year = 1994, tier = "i", req = { "co3" }, fx = {}, gain = "Habilita la suspensión neumática" },
		{ id = "co6", name = "Asientos con masaje", year = 2001, tier = "n", req = { "co4" }, fx = {}, gain = "Habilita asientos con masaje" },
		{ id = "co7", name = "Tablero digital", year = 2010, tier = "i", req = { "co6" }, fx = {}, gain = "Habilita el tablero digital y la luz ambiental" },
		{ id = "el2", name = "Computadora de a bordo", year = 1985, tier = "n", req = { "el1" }, fx = {}, gain = "Habilita la «Computadora de a bordo» en el equipamiento (+2 de calidad, −3 % de consumo)" },
		{ id = "el3", name = "Faros LED", year = 2004, tier = "n", req = { "el2" }, fx = {}, gain = "Habilita faros LED" },
		{ id = "te_radio", name = "Radio AM/FM", year = 1970, tier = "s", req = {}, fx = {}, gain = "Habilita la «Radio AM/FM» en el equipamiento (+3 de comodidad)" },
		{ id = "te_win", name = "Ventanillas eléctricas", year = 1976, tier = "s", req = { "te_radio" }, fx = {}, gain = "Habilita las «Ventanillas eléctricas» en el equipamiento (+3 de comodidad, +1 de calidad)" },
		{ id = "te_nav", name = "Navegador satelital", year = 1995, tier = "i", req = { "el2" }, fx = {}, gain = "Habilita el «Navegador satelital» en el equipamiento (+3 de comodidad, +2 de calidad)" },
		{ id = "te_pdc", name = "Sensores de estacionamiento", year = 1998, tier = "n", req = { "el2" }, fx = {}, gain = "Habilita los «Sensores de estacionamiento» en el equipamiento (+2 de seguridad, +2 de comodidad)" },
		{ id = "te_cam", name = "Cámara de retroceso", year = 2005, tier = "n", req = { "te_pdc" }, fx = {}, gain = "Habilita la «Cámara de retroceso» en el equipamiento (+3 de seguridad, +1 de calidad)" },
		{ id = "te_touch", name = "Pantalla táctil y conectividad", year = 2012, tier = "i", req = { "te_nav" }, fx = {}, gain = "Habilita la «Pantalla táctil» en el equipamiento (+4 de comodidad, +2 de calidad)" },
	} },
}

-- Niveles de motor (2 a 10 por familia): se generan acá para no escribirlos a mano. Cada nivel pide el
-- anterior; el año se reparte entre el nivel 1 y 2030 (o 45 años) y la complejidad crece con el nivel.
do
	local R = Catalog.RESEARCH_RULES
	local F = Catalog.ENGINE_LEVEL_FX
	for _, fam in Catalog.ENGINE_FAMILIES do
		local span = math.min(45, 2030 - fam.first)
		for lvl = 2, R.engineMaxLevel do
			local req = {}
			if lvl == 2 then
				if fam.req then
					table.insert(req, fam.req)
				end
			else
				table.insert(req, "eng_" .. fam.id .. "_" .. (lvl - 1))
			end
			local k = lvl - 1
			table.insert(Catalog.RESEARCH.motores.nodes, {
				id = "eng_" .. fam.id .. "_" .. lvl,
				name = fam.name .. " · nivel " .. lvl,
				year = fam.first + math.floor(k * span / (R.engineMaxLevel - 1) + 0.5),
				complexity = math.min(5, 1 + math.floor((lvl - 2) / 2)),
				req = req,
				fx = {},
				family = fam.id,
				level = lvl,
				gain = string.format("Motores %s de nivel %d: +%d %% de potencia, %d %% de consumo, +%s de calidad y +%d %% de costo del motor frente al nivel 1 (se elige en cada diseño)", fam.name, lvl, math.floor(F.hp * k * 100 + 0.5), math.floor(F.cons * k * 100 - 0.5), (string.gsub(tostring(math.floor(F.q * k * 10 + 0.5) / 10), "%.", ",")), math.floor(F.cost * k * 100 + 0.5)),
			})
		end
	end
end

--[[ Marcas rivales controladas por el juego. Cada una vende en ciertos tipos desde cierto año. offset =
	atractivo respecto de lo que espera el mercado (puede cambiar con los años: { año, valor }). ]]
-- Precio típico de cada tipo de vehículo (referencia para los modelos rivales, en dólares del juego).
Catalog.RIVAL_PRICE = { compacto = 2900, sedan = 3500, clasico = 4500, pickup = 4300, deportivo = 5500, suv = 5200, superdeportivo = 10800, electrico = 8200 }

--[[ Rivales de la versión anterior (seis marcas). NO se ofrecen ni se muestran: quedan solo como REFERENCIA DE
	CALIBRACIÓN. Rules.rivalScale usa su peso comercial estructural por tipo y año para que las doce marcas
	actuales repartan una presión competitiva agregada comparable a la de antes (pasar de 6 a 12 no duplica la
	competencia). Formato antiguo: types = { tipo = año }, models = { tipo = nombre }. ]]
Catalog.RIVALS_V1 = {
	{ id = "kodiak", name = "Kodiak Motors", color = "#8D6E4F", strategy = "Volumen y robustez", cycle = 7,
		types = { pickup = 1970, suv = 1984, sedan = 1970 }, offset = { { 1970, 2 }, { 2030, 1 } }, price = 0.95, react = 0.5,
		reach = { { 1970, 1.2 }, { 2000, 2.2 }, { 2030, 2.5 } }, models = { pickup = "Grizzly", suv = "Yukon", sedan = "Marshal" } },
	{ id = "nordia", name = "Nordia", color = "#3B82F6", strategy = "Eficiencia y seguridad", cycle = 6,
		types = { compacto = 1970, sedan = 1970, electrico = 2014 }, offset = { { 1970, 1 }, { 1990, 2 }, { 2030, 3 } }, price = 1.0, react = 0.3,
		reach = { { 1970, 1.0 }, { 2030, 2.5 } }, models = { compacto = "Fjord", sedan = "Polar", electrico = "Aurora-e" } },
	{ id = "halcon", name = "Halcón", color = "#D6333F", strategy = "Deportivos premium", cycle = 5,
		types = { deportivo = 1970, clasico = 1970, superdeportivo = 1974 }, offset = { { 1970, 4 }, { 2030, 5 } }, price = 1.15, react = 0.1,
		reach = { { 1970, 0.8 }, { 2030, 1.4 } }, models = { deportivo = "Rapaz", clasico = "Cóndor", superdeportivo = "Furia" } },
	{ id = "kairo", name = "Kairo Cars", color = "#42E58D", strategy = "Precio bajo y ascenso tecnológico", cycle = 5,
		types = { compacto = 1972, sedan = 1975, suv = 1990, electrico = 2011 }, offset = { { 1970, -4 }, { 1990, 2 }, { 2030, 5 } }, price = 0.85, react = 0.7,
		reach = { { 1970, 0.4 }, { 1995, 2.0 }, { 2030, 3.2 } }, models = { compacto = "Mika", sedan = "Sora", suv = "Taiga", electrico = "Volt" } },
	{ id = "velox", name = "Velox Auto", color = "#F7C95C", strategy = "Autos económicos", cycle = 8,
		types = { compacto = 1970, deportivo = 1978, clasico = 1970 }, offset = { { 1970, 0 }, { 2000, -1 }, { 2030, -1 } }, price = 0.88, react = 0.6,
		reach = { { 1970, 1.0 }, { 2030, 1.3 } }, models = { compacto = "Chispa", deportivo = "Saeta", clasico = "Ronda" } },
	{ id = "imperial", name = "Imperial", color = "#B3AAFF", strategy = "Lujo", cycle = 7,
		types = { sedan = 1970, suv = 1995, superdeportivo = 1990 }, offset = { { 1970, 3 }, { 2030, 4 } }, price = 1.25, react = 0.1,
		reach = { { 1970, 0.9 }, { 2030, 1.6 } }, models = { sedan = "Regente", suv = "Monarca", superdeportivo = "Corona" } },
}

--[[ Reglas de la competencia (valores centralizados; ninguna fórmula tiene casos especiales por marca):
	maxCut       = baja de precio máxima de una reacción (25 %)
	sensitivity  = cuota del jugador desde la que una marca reacciona, si la marca no define la suya
	qualityCap   = mejora de atractivo máxima de una respuesta «calidad» (puntos)
	phaseAmp     = cuánto mejor sale una generación nueva y cuánto envejece (± puntos)
	noise        = variación determinista entre modelos (± puntos)
	repWeight    = peso de la reputación de la marca en su alcance (por punto sobre 3)
	focus[tipo]  = cuánto pesan las prestaciones (perf) y la calidad (qual) de la marca en el atractivo de ese tipo ]]
Catalog.RIVAL_RULES = {
	maxCut = 0.25,
	sensitivity = 0.15,
	qualityCap = 2,
	phaseAmp = 2,
	noise = 1.2,
	repWeight = 0.05,
	focus = {
		compacto = { perf = 0.2, qual = 0.8 }, sedan = { perf = 0.4, qual = 0.6 }, clasico = { perf = 0.5, qual = 0.5 },
		pickup = { perf = 0.3, qual = 0.7 }, deportivo = { perf = 0.8, qual = 0.2 }, suv = { perf = 0.3, qual = 0.7 },
		superdeportivo = { perf = 1.0, qual = 0.0 }, electrico = { perf = 0.4, qual = 0.6 },
	},
}

--[[ Doce fabricantes rivales FICTICIOS. Nombres, líneas de modelos y colores son originales y provisionales (no
	hay logotipos ni insignias; la marca se muestra con su nombre y un color). El id es estable: el nombre visible,
	el color o la descripción se pueden cambiar sin tocar la simulación. Todo lo que los diferencia es dato:
	  price        posicionamiento de precio frente al precio justo (<1 barato, >1 caro)
	  quality      calidad relativa (−3…+3) · performance = prestaciones (−3…+3): pesan según el tipo (focus)
	  tech         nivel tecnológico por año { año, puntos de atractivo }: su ritmo de modernización
	  reputation   1…5: suma al alcance (repWeight) · reach = alcance comercial por año
	  aggression   cuánto bajan el precio cuando les quitás mercado (react) · sensitivity = desde qué cuota
	  answer       cómo responden: "precio" (bajan precios), "calidad" (mejoran el atractivo, hasta qualityCap,
	               con qualityAnswer puntos por cada 100 % de cuota tuya sobre su sensibilidad) o "prestaciones"
	               (mantienen precios: compiten con sus prestaciones)
	  cycle        años entre generaciones (cada línea puede tener el suyo)
	  lines        { id, name, type, since, cycle?, offset? }: líneas de modelos y año de aparición. Respetan las
	               fechas del juego: SUV desde 1984, superdeportivos desde 1974, eléctricos desde 2011 (después de
	               «Baterías de iones de litio», 2010). ]]
Catalog.RIVALS = {
	{ id = "baviron", name = "Baviron Motors", country = "Alemania", color = "#2F6FDE",
		desc = "Sedanes deportivos prémium con motores potentes y comportamiento dinámico.",
		specialties = { "Sedanes deportivos", "Prémium", "Motores potentes", "Conducción dinámica" },
		segments = { primary = "Premium", secondary = "Deportivo" }, strategy = "Calidad y rendimiento, precio alto",
		price = 1.18, quality = 2, performance = 2.5, tech = { { 1970, 2 }, { 2000, 3 }, { 2030, 3.5 } }, reputation = 4.2,
		reach = { { 1970, 0.35 }, { 2000, 0.7 }, { 2030, 0.9 } }, aggression = 0.08, answer = "calidad", qualityAnswer = 4, cycle = 7,
		lines = {
			{ id = "vektor", name = "Vektor", type = "sedan", since = 1970 },
			{ id = "kardan", name = "Kardan", type = "deportivo", since = 1972 },
			{ id = "terraxa", name = "Terraxa", type = "suv", since = 1999 },
			{ id = "vektor_e", name = "Vektor-e", type = "electrico", since = 2014 },
		} },
	{ id = "mercenza", name = "Mercenza", country = "Alemania", color = "#A9B4C2",
		desc = "Lujo, seguridad, confort y equipamiento avanzado con mucho prestigio.",
		specialties = { "Sedanes de lujo", "Seguridad", "Comodidad", "Equipamiento avanzado" },
		segments = { primary = "Premium", secondary = "Lujo" }, strategy = "Prestigio y precio muy alto",
		price = 1.3, quality = 3, performance = 1, tech = { { 1970, 2.5 }, { 2000, 3 }, { 2030, 3.5 } }, reputation = 4.6,
		reach = { { 1970, 0.4 }, { 2000, 0.8 }, { 2030, 1.0 } }, aggression = 0.05, answer = "calidad", qualityAnswer = 4, cycle = 8,
		lines = {
			{ id = "aureo", name = "Aureo", type = "sedan", since = 1970 },
			{ id = "solenne", name = "Solenne", type = "clasico", since = 1970 },
			{ id = "fulgor", name = "Fulgor", type = "superdeportivo", since = 1990, offset = -1 },
			{ id = "montesoro", name = "Montesoro", type = "suv", since = 1997 },
			{ id = "aureo_volta", name = "Aureo Volta", type = "electrico", since = 2016 },
		} },
	{ id = "volkenwerk", name = "Volkenwerk", country = "Alemania", color = "#3FA7D6",
		desc = "Autos accesibles y eficientes fabricados en gran volumen.",
		specialties = { "Compactos", "Sedanes familiares", "Eficiencia", "Gran volumen" },
		segments = { primary = "Masivo", secondary = "Económico" }, strategy = "Precio competitivo y mucha cobertura",
		price = 0.92, quality = 1, performance = -1, tech = { { 1970, 0 }, { 1990, 1.5 }, { 2030, 2 } }, reputation = 3.6,
		reach = { { 1970, 1.2 }, { 2000, 2.0 }, { 2030, 2.4 } }, aggression = 0.5, answer = "precio", cycle = 7,
		lines = {
			{ id = "kiebitz", name = "Kiebitz", type = "compacto", since = 1970 },
			{ id = "vagant", name = "Vagant", type = "sedan", since = 1973 },
			{ id = "taluda", name = "Taluda", type = "suv", since = 2004 },
			{ id = "kiebitz_e", name = "Kiebitz-E", type = "electrico", since = 2019 },
		} },
	{ id = "stuttaro", name = "Stuttaro", country = "Alemania", color = "#C8102E",
		desc = "Coupés deportivos de ingeniería precisa y gran calidad de construcción.",
		specialties = { "Coupés deportivos", "Altas prestaciones", "Ingeniería de precisión" },
		segments = { primary = "Deportivo", secondary = "Premium" }, strategy = "Poco volumen, precio alto y rendimiento",
		price = 1.35, quality = 2.5, performance = 3, tech = { { 1970, 2.5 }, { 2000, 3 }, { 2030, 3.5 } }, reputation = 4.4,
		reach = { { 1970, 0.2 }, { 2030, 0.4 } }, aggression = 0.03, answer = "prestaciones", cycle = 8,
		lines = {
			{ id = "kessel", name = "Kessel GT", type = "deportivo", since = 1970 },
			{ id = "kessel_roadster", name = "Kessel Roadster", type = "clasico", since = 1974 },
			{ id = "vulkan", name = "Vulkan", type = "superdeportivo", since = 1985 },
			{ id = "sturmhoch", name = "Sturmhoch", type = "suv", since = 2003 },
			{ id = "kessel_eturismo", name = "Kessel E-Turismo", type = "electrico", since = 2020 },
		} },
	{ id = "ferovento", name = "Ferovento", country = "Italia", color = "#E63B2E",
		desc = "Superdeportivos exclusivos con ingeniería de competición.",
		specialties = { "Superdeportivos", "Potencia", "Exclusividad", "Competición" },
		segments = { primary = "Exclusivo", secondary = "Deportivo" }, strategy = "Precio muy alto y alcance reducido",
		price = 1.55, quality = 2, performance = 4, tech = { { 1970, 3 }, { 2030, 4 } }, reputation = 4.8,
		reach = { { 1970, 0.5 }, { 2030, 0.8 } }, aggression = 0.02, answer = "prestaciones", cycle = 6,
		lines = {
			{ id = "scintilla", name = "Scintilla", type = "deportivo", since = 1970 },
			{ id = "fiamma", name = "Fiamma", type = "superdeportivo", since = 1974 },
		} },
	{ id = "torvello", name = "Torvello", country = "Italia", color = "#F2B705",
		desc = "Superdeportivos extremos de diseño agresivo y prestaciones enormes.",
		specialties = { "Superdeportivos extremos", "Diseño agresivo", "Exclusividad" },
		segments = { primary = "Exclusivo", secondary = "Deportivo" }, strategy = "Compite con prestaciones, no con precio",
		price = 1.6, quality = 1.5, performance = 4.5, tech = { { 1970, 2.5 }, { 2000, 3.5 }, { 2030, 4 } }, reputation = 4.5,
		reach = { { 1970, 0.4 }, { 2030, 0.7 } }, aggression = 0.02, answer = "prestaciones", cycle = 7,
		lines = {
			{ id = "bravura", name = "Bravura", type = "superdeportivo", since = 1976 },
			{ id = "corrida", name = "Corrida", type = "deportivo", since = 1983 },
			{ id = "furente", name = "Furente", type = "superdeportivo", since = 1990, offset = 0.5 },
			{ id = "pradera", name = "Pradera", type = "suv", since = 2018 },
		} },
	{ id = "forlan", name = "Forlan Motors", country = "Estados Unidos", color = "#1F4E9A",
		desc = "Autos populares, pickups y deportivos accesibles a gran escala.",
		specialties = { "Autos populares", "Pickups", "Deportivos accesibles", "Gran escala" },
		segments = { primary = "Masivo", secondary = "Utilitario" }, strategy = "Mucha cobertura y precio competitivo",
		price = 0.9, quality = 0, performance = 0.5, tech = { { 1970, 0 }, { 2000, 1 }, { 2030, 1.5 } }, reputation = 3.5,
		reach = { { 1970, 1.6 }, { 2000, 2.0 }, { 2030, 2.2 } }, aggression = 0.55, answer = "precio", cycle = 6,
		lines = {
			{ id = "avenida", name = "Avenida", type = "sedan", since = 1970 },
			{ id = "bisonte", name = "Bisonte", type = "pickup", since = 1970 },
			{ id = "potro", name = "Potro", type = "deportivo", since = 1970 },
			{ id = "travesia", name = "Travesía", type = "suv", since = 1986 },
			{ id = "potro_e", name = "Potro-E", type = "electrico", since = 2021 },
		} },
	{ id = "chevona", name = "Chevona", country = "Estados Unidos", color = "#D4A017",
		desc = "Sedanes populares, pickups y deportivos de gran cilindrada al mejor precio por caballo.",
		specialties = { "Sedanes populares", "Pickups", "Gran cilindrada", "Potencia por precio" },
		segments = { primary = "Masivo", secondary = "Utilitario" }, strategy = "Potencia barata, compite con Forlan",
		price = 0.88, quality = -0.5, performance = 1, tech = { { 1970, 0 }, { 2000, 1 }, { 2030, 1.5 } }, reputation = 3.3,
		reach = { { 1970, 1.6 }, { 2000, 1.9 }, { 2030, 2.0 } }, aggression = 0.6, answer = "precio", cycle = 6,
		lines = {
			{ id = "comarca", name = "Comarca", type = "sedan", since = 1970 },
			{ id = "labrador", name = "Labrador", type = "pickup", since = 1970 },
			{ id = "tronador", name = "Tronador", type = "deportivo", since = 1970 },
			{ id = "bulevar", name = "Bulevar", type = "clasico", since = 1970 },
			{ id = "altiplano", name = "Altiplano", type = "suv", since = 1985 },
			{ id = "corriente", name = "Corriente", type = "electrico", since = 2012 },
		} },
	{ id = "tayora", name = "Tayora", country = "Japón", color = "#C4161C",
		desc = "Fiabilidad, bajo consumo y durabilidad con un gran equilibrio entre calidad y precio.",
		specialties = { "Fiabilidad", "Eficiencia", "Bajo consumo", "Compactos y sedanes" },
		segments = { primary = "Masivo", secondary = "Económico" }, strategy = "Equilibrio entre calidad, precio y consumo",
		price = 0.95, quality = 2, performance = -0.5, tech = { { 1970, 0 }, { 1985, 2 }, { 2030, 3 } }, reputation = 4.0,
		reach = { { 1970, 0.6 }, { 1990, 1.8 }, { 2030, 2.6 } }, aggression = 0.4, answer = "precio", cycle = 6,
		lines = {
			{ id = "kumo", name = "Kumo", type = "compacto", since = 1970 },
			{ id = "kazeno", name = "Kazeno", type = "sedan", since = 1972 },
			{ id = "iwa", name = "Iwa", type = "pickup", since = 1978 },
			{ id = "takai", name = "Takai", type = "suv", since = 1994 },
			{ id = "kumo_den", name = "Kumo Den", type = "electrico", since = 2015 },
		} },
	{ id = "honari", name = "Honari", country = "Japón", color = "#E5484D",
		desc = "Compactos de motores eficientes e ingeniosos y deportivos accesibles.",
		specialties = { "Compactos", "Motores eficientes", "Ingeniería", "Deportivos accesibles" },
		segments = { primary = "Masivo", secondary = "Deportivo" }, strategy = "Eficiencia, mecánica y buena relación calidad-precio",
		price = 0.97, quality = 1.5, performance = 1, tech = { { 1970, -0.5 }, { 1985, 2 }, { 2030, 2.5 } }, reputation = 3.9,
		reach = { { 1970, 0.4 }, { 1990, 1.3 }, { 2030, 1.8 } }, aggression = 0.35, answer = "precio", cycle = 5,
		lines = {
			{ id = "hikari", name = "Hikari", type = "compacto", since = 1972 },
			{ id = "kibo", name = "Kibo", type = "sedan", since = 1976 },
			{ id = "raiden", name = "Raiden", type = "deportivo", since = 1984 },
			{ id = "hikari_ion", name = "Hikari Ion", type = "electrico", since = 2019 },
		} },
	{ id = "nizora", name = "Nizora", country = "Japón", color = "#8E9AAF",
		desc = "Sedanes y deportivos con motores potentes, tecnología y eléctricos tempranos.",
		specialties = { "Sedanes", "Deportivos", "Tecnología", "Eléctricos" },
		segments = { primary = "Masivo", secondary = "Deportivo" }, strategy = "Precio competitivo con tecnología y prestaciones",
		price = 0.93, quality = 0.5, performance = 1.5, tech = { { 1970, -0.5 }, { 1990, 1.5 }, { 2030, 2.5 } }, reputation = 3.6,
		reach = { { 1970, 0.5 }, { 1990, 1.4 }, { 2030, 1.8 } }, aggression = 0.45, answer = "precio", cycle = 6,
		lines = {
			{ id = "senkai", name = "Senkai", type = "sedan", since = 1970 },
			{ id = "kaminari", name = "Kaminari", type = "deportivo", since = 1970 },
			{ id = "daichi", name = "Daichi", type = "pickup", since = 1980 },
			{ id = "hoshi", name = "Hoshi", type = "electrico", since = 2011 },
		} },
	{ id = "nordviken", name = "Nordviken", country = "Suecia", color = "#4A7FA7",
		desc = "Autos familiares seguros, confortables y bien construidos.",
		specialties = { "Seguridad", "Familiares", "Confort", "Asistencia a la conducción" },
		segments = { primary = "Premium", secondary = "Familiar" }, strategy = "Reputación de seguridad y precio medio-alto",
		price = 1.08, quality = 2, performance = 0, tech = { { 1970, 1 }, { 2000, 2.5 }, { 2030, 3 } }, reputation = 4.1,
		reach = { { 1970, 0.4 }, { 2000, 0.8 }, { 2030, 1.0 } }, aggression = 0.2, answer = "calidad", qualityAnswer = 3, cycle = 8,
		lines = {
			{ id = "fjallvik", name = "Fjällvik", type = "sedan", since = 1970 },
			{ id = "lilla", name = "Lilla", type = "compacto", since = 1976 },
			{ id = "skogsra", name = "Skogsrå", type = "suv", since = 1984 },
			{ id = "fjallvik_strom", name = "Fjällvik Ström", type = "electrico", since = 2019 },
		} },
}

-- Misiones. go = pantalla a la que lleva el botón «Ir». kind = tutorial | historia | anual (se reinicia cada año).
-- goalScale = "reach": la meta se multiplica por el alcance de la sede (crece con la empresa).
-- reward.pi = puntos de investigación.
Catalog.MISSIONS = {
	{ id = "t1", kind = "tutorial", title = "Diseñá y finalizá tu primer auto", desc = "Abrí Diseño, recorré las cinco etapas y tocá «Finalizar diseño» en Resumen.", counter = "designsSaved", goal = 1, reward = { money = 15000, pi = 2, xp = 200 }, go = "editor" },
	{ id = "t2", kind = "tutorial", title = "Ordená tu primer lote", desc = "En Producción, elegí el modelo y cuántas unidades fabricar (cada modelo tiene un solo lote).", counter = "lotsLaunched", goal = 1, reward = { money = 10000, xp = 150 }, go = "fabrica" },
	{ id = "t3", kind = "tutorial", title = "Vendé tus primeros 25 autos", desc = "Cuando termina el lote llegan las reseñas: elegí el precio y los autos se venden solos.", counter = "unitsSold", goal = 25, reward = { money = 20000, pi = 3, xp = 300 }, go = "ventas" },
	{ id = "t4", kind = "tutorial", title = "Mejorá la fábrica", desc = "Subí de nivel una estación en Producción › Estaciones.", counter = "stationUpgrades", goal = 1, reward = { money = 8000, xp = 120 }, go = "fabrica" },
	{ id = "t5", kind = "tutorial", title = "Investigá una tecnología", desc = "Elegí una tecnología disponible de tu época en Investigación.", counter = "researchDone", goal = 1, reward = { money = 10000, pi = 3, xp = 200 }, go = "investigacion" },
	{ id = "t6", kind = "tutorial", title = "Diseñá un segundo modelo", desc = "Un segundo auto de otro tipo vende en otro segmento sin competir con el primero.", counter = "designsSaved", goal = 2, reward = { money = 20000, pi = 3, xp = 300 }, go = "editor" },
	{ id = "s1", kind = "historia", title = "Vendé 300 autos", desc = "Requisito para ampliar a Empresa pequeña.", counter = "unitsSold", goal = 300, reward = { money = 30000, pi = 8, xp = 500 }, go = "ventas" },
	{ id = "s2", kind = "historia", title = "Ampliá a Empresa pequeña", desc = "Mejorá las oficinas centrales en Compañía › Instalaciones.", counter = "sedeLevel", goal = 2, reward = { money = 50000, pi = 15, xp = 600 }, go = "compania" },
	{ id = "s3", kind = "historia", title = "Completá 5 investigaciones", desc = "Cada tecnología cambia estadísticas, costos u opciones del editor.", counter = "researchDone", goal = 5, reward = { money = 40000, pi = 10, xp = 400 }, go = "investigacion" },
	{ id = "s4", kind = "historia", title = "Agotá un lote completo", desc = "Vendé todas las unidades de un lote.", counter = "lotsSoldOut", goal = 1, reward = { money = 25000, pi = 6, xp = 350 }, go = "ventas" },
	{ id = "s5", kind = "historia", title = "Lanzá una nueva generación", desc = "Desde Catálogo, creá la 2.ª generación de un modelo.", counter = "generations", goal = 1, reward = { money = 30000, pi = 8, xp = 400 }, go = "autos" },
	{ id = "s5a", kind = "historia", title = "Mejorá la fábrica 12 veces", desc = "Cada nivel de estación fabrica más rápido. Con la Empresa pequeña las estaciones llegan hasta nivel 4.", counter = "stationUpgrades", goal = 12, reward = { money = 40000, pi = 8, xp = 400 }, go = "fabrica" },
	{ id = "s5b", kind = "historia", title = "Vendé 3.000 autos", desc = "Requisito para ampliar a Sede empresarial (también pide $2,5 M y reputación 3,4).", counter = "unitsSold", goal = 3000, reward = { money = 120000, pi = 20, xp = 800 }, go = "ventas" },
	{ id = "s6", kind = "historia", title = "Llegá a la Sede empresarial", desc = "Oficinas centrales de nivel 3: 16 empleados y alcance ×6.", counter = "sedeLevel", goal = 3, reward = { money = 150000, pi = 40, xp = 1200 }, go = "compania" },
	{ id = "s7", kind = "historia", title = "Vendé 10.000 autos", desc = "Una marca reconocida en todo el país.", counter = "unitsSold", goal = 10000, reward = { money = 400000, pi = 80, xp = 2000 }, go = "ventas" },
	{ id = "s8", kind = "historia", title = "Llegá a la Corporación automotriz", desc = "Oficinas centrales de nivel 4: 30 empleados y alcance ×11.", counter = "sedeLevel", goal = 4, reward = { money = 3000000, pi = 150, xp = 3000 }, go = "compania" },
	{ id = "s9", kind = "historia", title = "Liderá un tipo de vehículo", desc = "Tené al menos 35 % de la cuota de mercado de un tipo (promedio de los últimos meses, en Mercado).", counter = "leaderTypes", goal = 1, reward = { money = 6000000, pi = 150, xp = 3000 }, go = "mercado" },
	{ id = "s10", kind = "historia", title = "Vendé 50.000 autos", desc = "Una de las marcas grandes del país.", counter = "unitsSold", goal = 50000, reward = { money = 10000000, pi = 200, xp = 4000 }, go = "ventas" },
	{ id = "s11", kind = "historia", title = "Llegá al Imperio automotriz", desc = "Oficinas centrales al máximo: abren la expansión internacional.", counter = "sedeLevel", goal = 5, reward = { money = 40000000, pi = 300, xp = 6000 }, go = "compania" },
	{ id = "s12", kind = "historia", title = "Completá todas las investigaciones", desc = "Todas las tecnologías del departamento de I+D.", counter = "researchTree", goal = 0, reward = { money = 50000000, xp = 8000 }, go = "investigacion" },
	{ id = "s13", kind = "historia", title = "Primera expansión internacional", desc = "Abrí tu primer país desde Compañía › Expansión internacional.", counter = "expansion", goal = 1, reward = { money = 30000000, xp = 6000 }, go = "expansion" },
	{ id = "s14", kind = "historia", title = "Vendé 250.000 autos", desc = "Una marca internacional.", counter = "unitsSold", goal = 250000, reward = { money = 60000000, xp = 8000 }, go = "ventas" },
	{ id = "s15", kind = "historia", title = "Liderá cuatro tipos de vehículo", desc = "Al menos 35 % de cuota en cuatro tipos a la vez.", counter = "leaderTypes", goal = 4, reward = { money = 80000000, xp = 10000 }, go = "mercado" },
	{ id = "s16", kind = "historia", title = "Abrí cinco países", desc = "Expansión internacional en cinco países.", counter = "expansion", goal = 5, reward = { money = 150000000, xp = 12000 }, go = "expansion" },
	{ id = "s17", kind = "historia", title = "Vendé 1.000.000 de autos", desc = "Una de las marcas más grandes del mundo.", counter = "unitsSold", goal = 1000000, reward = { money = 250000000, xp = 20000 }, go = "ventas" },
	{ id = "s18", kind = "historia", title = "Presencia en los diez mercados internacionales", desc = "Abrí los diez países disponibles de la expansión internacional.", counter = "expansion", goal = 10, reward = { money = 500000000, xp = 30000 }, go = "expansion" },
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

--[[ Demanda estimada en cinco niveles (Rules.demandInfo): relación entre el peso comercial del auto (precio,
	atractivo por calidad y prestaciones, reseñas, reputación y alcance, segmento y campaña) y el de los modelos
	rivales del mismo tipo ese año. 1 = igual que un rival promedio. ]]
Catalog.DEMAND_LEVELS = {
	thresholds = { 0.35, 0.75, 1.35, 2.2 },
	labels = { "Muy baja", "Baja", "Media", "Alta", "Muy alta" },
}

-- Estadísticas visibles del editor: { clave, etiqueta, unidad, ayuda, dirección (+1 más es mejor), máximo de la barra }
Catalog.STAT_DEFS = {
	{ "hp", "Potencia", "hp", "Fuerza del motor. Más es más rápido.", 1, 800 },
	{ "top", "Velocidad máxima", "km/h", "Velocidad tope en recta.", 1, 400 },
	{ "accel", "0 a 100 km/h", "s", "Segundos para llegar a 100 km/h. Menos es mejor.", -1, 16 },
	{ "handling", "Manejo", "índice 0–100", "Agarre y estabilidad en curvas. Más es mejor.", 1, 100 },
	{ "stop", "Frenado 100→0", "m", "Metros para detenerse desde 100 km/h. Menos es mejor.", -1, 60 },
	{ "durability", "Fiabilidad", "índice 0–100", "Resistencia al desgaste y a las fallas. Más es mejor.", 1, 100 },
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
-- Familia de cada motor (los niveles 1–10 se investigan por familia; ver Catalog.ENGINE_FAMILIES).
Catalog.ENGINE_FAMILY_OF = {
	i4e = "I4", i4 = "I4", i4v = "I4", i3t = "I3", i6 = "I6", v6 = "V6", v6i = "V6", v8 = "V8", v8d = "V8", em200 = "EV", em350 = "EV",
}
--[[ Chasis por familia y generación: cada base es un chasis de una época (gen 1 = el de 1970). Las
	generaciones siguientes se agregan como bases nuevas con la misma familia y gen + 1. ]]
Catalog.CHASSIS_GEN = {
	brisa = { "Sedán", 1 }, brisa2 = { "Sedán", 2 }, brisa3 = { "Sedán", 3 }, duna = { "Coupé", 1 }, duna2 = { "Coupé", 2 },
	pixel = { "Compacto", 1 }, toro = { "Pickup", 1 },
	aurora = { "Deportivo", 1 }, titan = { "SUV", 1 }, vento = { "Superdeportivo", 1 }, rayo = { "Eléctrico", 1 },
}
for _, p in Catalog.PARTS do
	partIndex[p.cat .. ":" .. p.id] = p
	if p.cat == "motor" then
		p.family = Catalog.ENGINE_FAMILY_OF[p.id]
	end
end
for _, b in Catalog.BASES do
	local c = Catalog.CHASSIS_GEN[b.id]
	if c then
		b.family, b.gen = c[1], c[2]
	end
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
		-- Costo base según la complejidad (Catalog.RESEARCH_RULES); el año ajusta un poco los PI y el dinero
		-- sigue a la economía de la época.
		local R = Catalog.RESEARCH_RULES
		local c = n.complexity or R.complexityOfTier[n.tier] or 2
		n.complexity = c
		n.category = key
		n.rp = math.max(1, math.floor(R.pi[c] * (1 + R.piEraGrowth * (n.year - 1970)) + 0.5))
		n.cost = math.floor(R.money[c] * Catalog.interp(R.moneyEra, n.year) / 100 + 0.5) * 100
		n.days = R.days[c]
		n.lab = 1
		researchIndex[n.id] = n
		Catalog.RESEARCH_NAMES[n.id] = n.name
	end
end
-- La misión «Completá todas las investigaciones» sigue al tamaño real del árbol: TODAS las tecnologías que se
-- pueden investigar (las normales y los niveles 2–10 de cada familia de motor). Lo que viene de serie (chasis
-- de 1970, nivel 1 de los motores, variante Equilibrada) no es una investigación y no cuenta. Su contador
-- («researchTree», Rules.missionValue) cuenta las tecnologías de este mismo catálogo que figuran en
-- g.research.done: meta y avance usan la misma definición, sin un número fijo.
do
	local total = 0
	for _, key in Catalog.RESEARCH_ORDER do
		total += #Catalog.RESEARCH[key].nodes
	end
	Catalog.RESEARCH_TOTAL = total
	for _, m in Catalog.MISSIONS do
		if m.id == "s12" then
			m.goal = total
			m.desc = "Las " .. total .. " tecnologías del departamento de I+D."
		end
	end
end
function Catalog.researchNode(id: any): any
	return type(id) == "string" and researchIndex[id] or nil
end

--[[ Lo que desbloquea cada tecnología para elegir en el editor: { [id] = { { kind, name } } }, con kind =
	"base" (chasis), "pieza", "equipamiento", "variante", "carroceria", "interior" o "familia" (habilita mejorar
	una familia de motores). Los niveles de motor desbloquean su nivel («nivel»). Las tecnologías con `fx` tienen
	además (o en lugar de esto) un efecto automático en la empresa (Rules.tech). Lo usan la pantalla de
	Investigación (tipo de efecto de cada tarjeta) y las pruebas de integridad del árbol. ]]
Catalog.RESEARCH_UNLOCKS = {} :: { [string]: { any } }
do
	local U = Catalog.RESEARCH_UNLOCKS
	local function add(id: any, kind: string, name: any)
		if type(id) == "string" then
			U[id] = U[id] or {}
			table.insert(U[id], { kind = kind, name = tostring(name) })
		end
	end
	for _, b: any in Catalog.BASES do
		add(b.research, "base", b.name)
	end
	for _, p: any in Catalog.PARTS do
		add(p.research, "pieza", p.name)
	end
	for _, e: any in Catalog.EQUIPMENT do
		add(e.research, "equipamiento", e.name)
	end
	for _, v: any in Catalog.ENGINE_VARIANTS do
		add(v.research, "variante", v.name)
	end
	for _, list in Catalog.BODY_OPTS do
		for _, o in list do
			add(o[5], "carroceria", o[2])
		end
	end
	for _, list in Catalog.INTERIOR do
		for _, o in list do
			add(o[6], "interior", o[2])
		end
	end
	for _, f: any in Catalog.ENGINE_FAMILIES do
		add(f.req, "familia", "Familia " .. f.name)
	end
	for _, key in Catalog.RESEARCH_ORDER do
		for _, n in Catalog.RESEARCH[key].nodes do
			if n.family then
				add(n.id, "nivel", n.name)
			end
		end
	end
end

-- Tipo de efecto de una tecnología: "auto" (solo efecto automático), "editor" (solo opciones que se eligen en
-- cada diseño) o "ambos".
function Catalog.researchEffectKind(n: any): string
	local auto = n ~= nil and n.fx ~= nil and next(n.fx) ~= nil
	local editor = n ~= nil and Catalog.RESEARCH_UNLOCKS[n.id] ~= nil
	return (auto and editor and "ambos") or (auto and "auto") or "editor"
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
	for _, d in Catalog.STAFF.departments do
		if d.id == id then
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
