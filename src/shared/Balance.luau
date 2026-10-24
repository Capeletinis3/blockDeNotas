-- Valores de progresión. No usa tipos de Roblox para poder testearse con luau.
-- Son de prueba: se ajustan jugando.
local Balance = {}

-- Plata por pieza rota
Balance.MoneyDirect = 10 -- rota por la pelota
Balance.MoneyChain = 25 -- rota por otra pieza del escenario

-- Niveles de la pelota. Price es lo que cuesta pasar a ese nivel.
-- BreakMultiplier multiplica el impulso de los impactos directos de la pelota.
-- AbsorbMultiplier reduce la velocidad que pierde al atravesar lo que rompe.
Balance.BallLevels = {
	{ Price = 0, BreakMultiplier = 1, AbsorbMultiplier = 1 },
	{ Price = 60, BreakMultiplier = 1.5, AbsorbMultiplier = 0.75 },
	{ Price = 150, BreakMultiplier = 2, AbsorbMultiplier = 0.5 },
}

-- Zapatillas: multiplican la fuerza entrenada.
Balance.Shoes = {
	{ Name = "Zapatillas comunes", Price = 0, Multiplier = 1 },
	{ Name = "Deportivas", Price = 120, Multiplier = 1.5 },
	{ Name = "Botines pro", Price = 350, Multiplier = 2 },
}

-- Entrenamiento
Balance.StartStrength = 10
Balance.StrengthPerRep = 1
Balance.TrainCooldown = 0.5 -- segundos mínimos entre repeticiones (lo controla el servidor)

-- Potencia de patada = fuerza × multiplicador de zapatillas.
-- Velocidad de la pelota = BaseKickSpeed + potencia × SpeedPerPower, hasta MaxKickSpeed.
-- Con la fuerza inicial (10) y zapatillas comunes da 110.
Balance.BaseKickSpeed = 70
Balance.SpeedPerPower = 4
Balance.MaxKickSpeed = 220

return Balance
