--!strict
--[[ Oficinas centrales: catálogo de mobiliario, acabados y planos (etapa 1: solo datos).

	Cuadrícula: cada casilla mide CELL studs. Las coordenadas de los muebles son relativas a su habitación
	(no al mundo), así un mueble conserva su lugar aunque el edificio cambie de posición.

	Mueble (FURNITURE[id]):
	  id, name, category (CATEGORIES), desc, year (disponible desde; nunca desaparece), price (dinero del juego),
	  size = studs (ancho, alto, largo) del futuro modelo, cells = { w, d } casillas que ocupa sin girar,
	  rotations = giros permitidos en grados (múltiplos de 45; hoy todos admiten los 8), interaction = punto de uso del avatar o nil
	  ({ kind = "work" | "sit" | "rest" | "browse", dx, dy, facing } relativo al centro del mueble, en casillas),
	  bonus = { skill = id de Catalog.STAFF.skills, value } o nil (comparte el tope de esa habilidad con el
	  personal), model = nombre del futuro modelo en ServerStorage.CarEmpireAssets.Muebles (aún no existe).

	Acabado (FINISHES[tipo][id]): id, name, year, price por unidad, unit ("casilla" | "tramo" | "unidad"),
	  material = referencia al material visual futuro.

	Plano (PLANS[nivel de oficinas]): habitaciones con id estable, tamaño en casillas, accesos obligatorios
	  (casillas que deben quedar libres: puertas y paso) y largo de pared en tramos. ]]

local OfficeCatalog = {}

OfficeCatalog.CELL = 2 -- studs por casilla
OfficeCatalog.VERSION = 1 -- versión de los datos de g.office

OfficeCatalog.CATEGORIES = {
	{ id = "escritorios", name = "Escritorios" },
	{ id = "asientos", name = "Sillas y sofás" },
	{ id = "tecnologia", name = "Tecnología" },
	{ id = "almacenamiento", name = "Almacenamiento" },
	{ id = "reuniones", name = "Mesas de reuniones" },
	{ id = "iluminacion", name = "Iluminación" },
	{ id = "decoracion", name = "Decoración" },
}

local ALL = { 0, 45, 90, 135, 180, 225, 270, 315 }

-- Registros de prueba representativos de 1970 (uno o dos por categoría). Las bonificaciones son moderadas
-- frente a los topes de Catalog.STAFF.skills (p. ej. organización: tope 0,40).
OfficeCatalog.FURNITURE = {
	escritorio_metal_1970 = {
		name = "Escritorio de chapa", category = "escritorios", year = 1970, price = 1200,
		desc = "Escritorio metálico con cajonera, típico de las oficinas de los setenta.",
		size = { 4, 2.6, 2 }, cells = { 2, 1 }, rotations = ALL,
		interaction = { kind = "work", dx = 0, dy = 1, facing = 180 },
		bonus = { skill = "organizacion", value = 0.01 }, model = "EscritorioMetal1970",
	},
	silla_oficina_1970 = {
		name = "Silla de oficina tapizada", category = "asientos", year = 1970, price = 300,
		desc = "Silla giratoria con tapizado de vinilo.",
		size = { 2, 3, 2 }, cells = { 1, 1 }, rotations = ALL,
		interaction = { kind = "sit", dx = 0, dy = 0, facing = 0 }, model = "SillaOficina1970",
	},
	sofa_cuero_1970 = {
		name = "Sofá de cuero", category = "asientos", year = 1970, price = 2200,
		desc = "Sofá de tres cuerpos para la recepción o la dirección.",
		size = { 6, 2.8, 2.4 }, cells = { 3, 1 }, rotations = ALL,
		interaction = { kind = "rest", dx = 0, dy = 0, facing = 0 }, model = "SofaCuero1970",
	},
	maquina_escribir_1970 = {
		name = "Máquina de escribir eléctrica", category = "tecnologia", year = 1970, price = 900,
		desc = "Agiliza la correspondencia y los informes.",
		size = { 1.6, 1, 1.4 }, cells = { 1, 1 }, rotations = ALL,
		bonus = { skill = "finanzas", value = 0.01 }, model = "MaquinaEscribir1970",
	},
	estanteria_madera_1970 = {
		name = "Estantería de madera", category = "almacenamiento", year = 1970, price = 700,
		desc = "Archivo de catálogos, planos y documentación técnica.",
		size = { 4, 6, 1.4 }, cells = { 2, 1 }, rotations = ALL,
		interaction = { kind = "browse", dx = 0, dy = 1, facing = 180 },
		bonus = { skill = "conocimiento", value = 0.008 }, model = "EstanteriaMadera1970",
	},
	mesa_reuniones_1970 = {
		name = "Mesa de reuniones", category = "reuniones", year = 1970, price = 2600,
		desc = "Mesa rectangular para seis personas.",
		size = { 6, 2.6, 4 }, cells = { 3, 2 }, rotations = ALL,
		bonus = { skill = "gestion", value = 0.008 }, model = "MesaReuniones1970",
	},
	lampara_pie_1970 = {
		name = "Lámpara de pie", category = "iluminacion", year = 1970, price = 250,
		desc = "Luz cálida de apoyo.", size = { 1.2, 5, 1.2 }, cells = { 1, 1 }, rotations = ALL, model = "LamparaPie1970",
	},
	planta_interior_1970 = {
		name = "Planta en maceta", category = "decoracion", year = 1970, price = 150,
		desc = "Decoración sin beneficios.", size = { 1.4, 3, 1.4 }, cells = { 1, 1 }, rotations = ALL, model = "PlantaInterior1970",
	},
}
for id, f in OfficeCatalog.FURNITURE do
	(f :: any).id = id
end

-- Rendimientos decrecientes: la n-ésima copia de un mismo mueble aporta value × DECAY^(n−1).
OfficeCatalog.BONUS_DECAY = 0.5

--[[ Acabados. Unidades: piso por casilla de superficie, paredes y revestimientos por tramo de pared
	(1 tramo = 1 casilla de largo), iluminación por luminaria (una cada LIGHT_AREA casillas). ]]
OfficeCatalog.LIGHT_AREA = 12
OfficeCatalog.FINISHES = {
	floor = {
		piso_cemento = { name = "Cemento alisado", year = 1970, price = 0, unit = "casilla", material = "Concrete" },
		piso_parquet_1970 = { name = "Parquet de roble", year = 1970, price = 40, unit = "casilla", material = "WoodPlanks" },
		piso_alfombra_1970 = { name = "Alfombra", year = 1970, price = 30, unit = "casilla", material = "Fabric" },
	},
	wall = {
		pared_blanca = { name = "Pintura blanca", year = 1970, price = 0, unit = "tramo", material = "SmoothPlastic", color = "#E8E6E1" },
		pared_beige_1970 = { name = "Pintura beige", year = 1970, price = 15, unit = "tramo", material = "SmoothPlastic", color = "#D9C8A6" },
	},
	covering = {
		sin_revestimiento = { name = "Sin revestimiento", year = 1970, price = 0, unit = "tramo", material = "" },
		madera_1970 = { name = "Revestimiento de madera", year = 1970, price = 60, unit = "tramo", material = "Wood" },
	},
	lighting = {
		luz_fluorescente = { name = "Tubos fluorescentes", year = 1970, price = 0, unit = "unidad", material = "Fluorescente" },
		luz_calida_1970 = { name = "Plafones cálidos", year = 1970, price = 120, unit = "unidad", material = "Calida" },
	},
}
for _, group in OfficeCatalog.FINISHES do
	for id, f in group do
		(f :: any).id = id
	end
end
-- Acabados básicos de una habitación nueva (gratis).
OfficeCatalog.DEFAULT_FINISH = { floor = "piso_cemento", wall = "pared_blanca", covering = "sin_revestimiento", lighting = "luz_fluorescente" }

--[[ Planos: uno por nivel de oficinas (Catalog.SEDES). Los ids de habitación son estables entre niveles: la
	«oficina_principal» del nivel 1 es la misma habitación (más grande) en el nivel 2. access = casillas que
	deben quedar libres (puerta y paso). Al ampliar, ROOM_MAP indica a qué habitación pasa una que cambia de
	nombre (vacío por ahora: todas conservan su id). ]]
local function room(id: string, name: string, w: number, d: number, access: { { number } }): any
	return { id = id, name = name, w = w, d = d, access = access }
end
OfficeCatalog.PLANS = {
	[1] = { rooms = { room("oficina_principal", "Oficina principal", 10, 8, { { 0, 3 }, { 0, 4 }, { 1, 3 }, { 1, 4 } }) } },
	[2] = { rooms = {
		room("oficina_principal", "Oficina principal", 12, 9, { { 0, 4 }, { 0, 5 }, { 1, 4 }, { 1, 5 } }),
		room("sala_reuniones", "Sala de reuniones", 8, 6, { { 0, 2 }, { 0, 3 } }),
	} },
	[3] = { rooms = {
		room("recepcion", "Recepción", 8, 6, { { 3, 0 }, { 4, 0 }, { 3, 5 }, { 4, 5 } }),
		room("oficina_principal", "Oficina principal", 14, 10, { { 0, 4 }, { 0, 5 }, { 1, 4 }, { 1, 5 } }),
		room("sala_reuniones", "Sala de reuniones", 9, 7, { { 0, 3 }, { 0, 4 } }),
	} },
	[4] = { rooms = {
		room("recepcion", "Recepción", 10, 7, { { 4, 0 }, { 5, 0 }, { 4, 6 }, { 5, 6 } }),
		room("oficina_principal", "Oficina principal", 16, 12, { { 0, 5 }, { 0, 6 }, { 1, 5 }, { 1, 6 } }),
		room("sala_reuniones", "Sala de reuniones", 10, 8, { { 0, 3 }, { 0, 4 } }),
		room("direccion", "Dirección", 8, 7, { { 0, 3 }, { 0, 4 } }),
	} },
	[5] = { rooms = {
		room("recepcion", "Recepción", 12, 8, { { 5, 0 }, { 6, 0 }, { 5, 7 }, { 6, 7 } }),
		room("oficina_principal", "Oficina principal", 18, 14, { { 0, 6 }, { 0, 7 }, { 1, 6 }, { 1, 7 } }),
		room("sala_reuniones", "Sala de reuniones", 12, 9, { { 0, 4 }, { 0, 5 } }),
		room("direccion", "Dirección", 9, 8, { { 0, 3 }, { 0, 4 } }),
		room("sala_descanso", "Sala de descanso", 8, 7, { { 0, 3 }, { 0, 4 } }),
	} },
}
OfficeCatalog.ROOM_MAP = {} :: { [string]: string } -- habitación vieja → equivalente nueva (si cambia de id)

-- Mobiliario inicial de toda empresa (se entrega una sola vez, guardado en el inventario). x, y, rot son el
-- lugar donde la versión anterior (esquema 18) los colocaba solos: sirven para devolverlos al inventario.
OfficeCatalog.STARTER = {
	{ item = "escritorio_metal_1970", room = "oficina_principal", x = 5, y = 2.5, rot = 0 },
	{ item = "silla_oficina_1970", room = "oficina_principal", x = 5.5, y = 3.5, rot = 0 },
}

function OfficeCatalog.item(id: any): any
	return type(id) == "string" and OfficeCatalog.FURNITURE[id] or nil
end

function OfficeCatalog.finish(kind: string, id: any): any
	local group = OfficeCatalog.FINISHES[kind]
	return group and type(id) == "string" and group[id] or nil
end

function OfficeCatalog.plan(level: number): any
	return OfficeCatalog.PLANS[math.clamp(math.floor(level), 1, #OfficeCatalog.PLANS)]
end

function OfficeCatalog.room(level: number, roomId: string): any
	for _, r in OfficeCatalog.plan(level).rooms do
		if r.id == roomId then
			return r
		end
	end
	return nil
end

return OfficeCatalog
