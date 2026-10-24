-- Valores ajustables del prototipo. Son de prueba: se calibran jugando.
local Config = {}

-- Patada (potencia fija por ahora; más adelante saldrá de fuerza × zapatillas)
Config.KickSpeed = 110 -- velocidad inicial de la pelota (studs/s)
Config.KickElevation = 3 -- grados hacia arriba
Config.MaxAimAngle = 30 -- grados a cada lado del centro
Config.AimSpeed = 30 -- grados por segundo al mantener apretado
Config.KickRange = 14 -- distancia máxima entre el jugador y la pelota

Config.Ball = {
	Diameter = 3,
	Density = 1.5,
	Friction = 0.3,
	Elasticity = 0.4,
}

-- Intento
Config.SettleSpeed = 1.5 -- debajo de esta velocidad una pieza se considera quieta
Config.SettleTime = 1 -- segundos con todo quieto para cerrar el intento
Config.MaxAttemptTime = 10
Config.ResetDelay = 3 -- segundos mostrando el resultado antes de reiniciar
Config.ResetCooldown = 0.5

-- Plata por pieza rota
Config.MoneyDirect = 10 -- rota por la pelota
Config.MoneyChain = 25 -- rota por otra pieza del escenario

-- Niveles de la pelota. BreakMultiplier multiplica el impulso de sus impactos
-- directos al decidir si una pieza se rompe. Price es lo que cuesta pasar a ese nivel.
Config.BallLevels = {
	{ Price = 0, BreakMultiplier = 1, Color = Color3.fromRGB(245, 245, 245) },
	{ Price = 60, BreakMultiplier = 1.5, Color = Color3.fromRGB(90, 160, 255) },
	{ Price = 150, BreakMultiplier = 2, Color = Color3.fromRGB(255, 200, 50) },
}

-- La estructura cuenta como derribada si la plataforma se movió más que esto
Config.ToppleDistance = 3

-- Fragmentos
Config.FragmentsPerBreak = 6
Config.FragmentSpeed = 18
Config.FragmentLifetime = 2.5

-- Materiales. Strength es el impulso mínimo para romper la pieza:
-- masa reducida de las dos piezas × velocidad relativa al chocar.
-- Sin Strength, la pieza no se rompe (solo se mueve por física).
Config.Materials = {
	Madera = {
		Label = "El soporte de madera",
		Strength = 500,
		Absorb = 0.3, -- fracción de velocidad que pierde la pelota al atravesarla
		Density = 0.6,
		Friction = 0.5,
		Elasticity = 0.2,
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(120, 80, 45),
	},
	Caja = {
		Label = "La caja",
		Strength = 300,
		Absorb = 0.15,
		Density = 0.4,
		Friction = 0.5,
		Elasticity = 0.2,
		Material = Enum.Material.WoodPlanks,
		Color = Color3.fromRGB(196, 148, 90),
	},
	Reforzado = {
		Label = "El panel reforzado",
		Strength = 2600, -- pensado para resistir la pelota nivel 1 y ceder con la nivel 2
		Absorb = 0.5,
		Density = 1.5,
		Friction = 0.5,
		Elasticity = 0.1,
		Material = Enum.Material.DiamondPlate,
		Color = Color3.fromRGB(150, 160, 175),
	},
	Plataforma = {
		Density = 0.6,
		Friction = 0.5,
		Elasticity = 0.1,
		Material = Enum.Material.WoodPlanks,
		Color = Color3.fromRGB(150, 100, 60),
	},
	Pared = {
		Density = 2.4,
		Friction = 0.6,
		Elasticity = 0.1,
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(110, 110, 115),
	},
}

return Config
