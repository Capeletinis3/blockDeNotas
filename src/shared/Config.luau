-- Valores de física, escenario y presentación. Son de prueba: se calibran jugando.
-- La economía y la progresión están en Balance.luau.
local Config = {}

-- Patada (la velocidad sale de la fuerza y las zapatillas, ver Balance)
Config.KickElevation = 3 -- grados hacia arriba
Config.MaxAimAngle = 30 -- grados a cada lado del centro
Config.AimSpeed = 30 -- grados por segundo al mantener apretado
Config.KickRange = 14 -- distancia máxima entre el jugador y la pelota
Config.KickWindup = 0.12 -- segundos entre el inicio de la animación y la salida de la pelota

Config.Ball = {
	Diameter = 3,
	Density = 1.5,
	Friction = 0.3,
	Elasticity = 0.4,
}

-- Color de la pelota según su nivel
Config.BallColors = {
	Color3.fromRGB(245, 245, 245),
	Color3.fromRGB(90, 160, 255),
	Color3.fromRGB(255, 200, 50),
}

-- Entrenamiento
Config.TrainRange = 7 -- distancia máxima al centro de la zona de entrenamiento

-- Intento
Config.SettleSpeed = 1.5 -- debajo de esta velocidad una pieza se considera quieta
Config.SettleTime = 0.8 -- segundos con todo quieto para cerrar el intento
Config.MaxAttemptTime = 8
Config.ResetDelay = 2.5 -- segundos mostrando el resultado antes de reiniciar
Config.ResetCooldown = 0.5

-- La estructura cuenta como derribada si la plataforma se movió más que esto
Config.ToppleDistance = 3

-- Fragmentos
Config.FragmentsPerBreak = 6
Config.FragmentSpeed = 18
Config.FragmentLifetime = 2.5
Config.MaxFragments = 120 -- tope de fragmentos a la vez, por rendimiento

-- Sonidos. Son sonidos que vienen con Roblox; se pueden reemplazar por rbxassetid://...
Config.Sounds = {
	Kick = "rbxasset://sounds/swoosh.wav",
	Impact = "rbxasset://sounds/collide.wav",
	Break = "rbxasset://sounds/collide.wav",
	Purchase = "rbxasset://sounds/electronicpingshort.wav",
	Train = "rbxasset://sounds/action_jump.mp3",
}

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
		Strength = 2600, -- pensado para resistir la pelota inicial y ceder con la nivel 2
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
