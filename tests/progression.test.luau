-- Tests de plata, compras y entrenamiento. Correr con: luau tests/progression.test.luau
local Balance = require("../src/shared/Balance")
local Progression = require("../src/shared/Progression")

local passed, failed = 0, 0

local function check(name: string, condition: boolean)
	if condition then
		passed += 1
	else
		failed += 1
		print("FALLÓ: " .. name)
	end
end

local function setup(money: number?)
	local progression = Progression.new(Balance)
	local player = progression:newPlayer()
	player.money = money or 0
	return progression, player
end

-- Plata ------------------------------------------------------------------------

do
	local progression = Progression.new(Balance)
	check("una directa y dos en cadena pagan $60", progression:payout(1, 2) == 60)
	check("sin roturas paga $0", progression:payout(0, 0) == 0)

	local attempt = progression:newAttempt("jugador")
	attempt:recordBreak(1, true)
	attempt:recordBreak(2, false)
	attempt:recordBreak(3, false)
	check("la misma pieza no se cuenta dos veces", attempt:recordBreak(2, false) == false)
	check("intento paga $60", attempt:settle() == 60)
	check("el segundo cobro del mismo intento da $0", attempt:settle() == 0)
	check("después de cobrar no se registran roturas", attempt:recordBreak(4, true) == false)
	check("el intento recuerda quién pateó", attempt.kicker == "jugador")

	local empty = progression:newAttempt("jugador")
	check("intento sin roturas paga $0", empty:settle() == 0)
end

-- Mejoras de pelota ---------------------------------------------------------------

do
	local progression, player = setup(59)
	local ok, reason = progression:buyBallLevel(player)
	check("sin fondos se rechaza la mejora", not ok and reason == "funds")
	check("sin fondos no descuenta", player.money == 59 and player.ballLevel == 1)
end

do
	local progression, player = setup(100)
	check("con $100 compra el nivel 2", progression:buyBallLevel(player))
	check("el nivel 2 descuenta $60", player.money == 40)
	check("queda en nivel 2", player.ballLevel == 2)
	check("nivel 2 rompe x1,5", progression:ballStats(player).BreakMultiplier == 1.5)

	local ok, reason = progression:buyBallLevel(player)
	check("nivel 3 sin fondos se rechaza", not ok and reason == "funds" and player.money == 40)

	player.money = 150
	check("con $150 compra el nivel 3", progression:buyBallLevel(player))
	check("el nivel 3 descuenta $150", player.money == 0 and player.ballLevel == 3)

	player.money = 1000
	ok, reason = progression:buyBallLevel(player)
	check("no hay nivel 4", not ok and reason == "max" and player.money == 1000)
end

do
	local progression, player = setup()
	check("la mejora reduce la pérdida de velocidad", progression:ballStats(player).AbsorbMultiplier == 1)
	player.ballLevel = 3
	check("nivel 3 pierde la mitad", progression:ballStats(player).AbsorbMultiplier == 0.5)
end

-- Entrenamiento --------------------------------------------------------------------

do
	local progression, player = setup()
	check("fuerza inicial", player.strength == Balance.StartStrength)
	check("primera repetición suma", progression:train(player, 100))
	check("suma la fuerza por repetición", player.strength == Balance.StartStrength + Balance.StrengthPerRep)

	local ok, reason = progression:train(player, 100.1)
	check("pulsar rápido no suma", not ok and reason == "cooldown")
	check("la fuerza no cambió por pulsar rápido", player.strength == Balance.StartStrength + Balance.StrengthPerRep)

	-- 20 pulsaciones en 1 segundo solo valen lo que permite el límite.
	local before = player.strength
	for i = 1, 20 do
		progression:train(player, 101 + i * 0.05)
	end
	check("el ritmo de entrenamiento está limitado", player.strength - before == 2)
end

do
	local progression, player = setup()
	local speedBefore = progression:kickSpeed(player)
	player.strength += 5
	check("entrenar aumenta la velocidad de patada", progression:kickSpeed(player) > speedBefore)
	check("la velocidad inicial es 110", speedBefore == 110)
end

-- Zapatillas --------------------------------------------------------------------------

do
	local progression, player = setup(100)
	local ok, reason = progression:buyShoe(player, 2)
	check("zapatillas sin fondos se rechazan", not ok and reason == "funds" and player.money == 100)

	ok, reason = progression:equipShoe(player, 2)
	check("no se equipa lo que no compraste", not ok and reason == "notOwned" and player.shoeEquipped == 1)

	player.money = 200
	check("compra las deportivas", progression:buyShoe(player, 2))
	check("descuenta $120", player.money == 80)
	check("las equipa al comprarlas", player.shoeEquipped == 2)

	ok, reason = progression:buyShoe(player, 2)
	check("no se compra dos veces", not ok and reason == "owned" and player.money == 80)

	ok, reason = progression:buyShoe(player, 99)
	check("modelo inexistente se rechaza", not ok and reason == "invalid")

	check("puede volver a las comunes", progression:equipShoe(player, 1) and player.shoeEquipped == 1)
	check("y re-equipar las compradas gratis", progression:equipShoe(player, 2) and player.money == 80)
end

do
	local progression, player = setup()
	player.strength = 20
	check("potencia sin zapatillas = fuerza", progression:kickPower(player) == 20)
	player.shoesOwned[2] = true
	player.shoeEquipped = 2
	check("multiplicador x1,5 aplicado una sola vez", progression:kickPower(player) == 30)
	check("velocidad con potencia 30", progression:kickSpeed(player) == 70 + 30 * 4)
	player.strength = 1000
	check("la velocidad tiene tope", progression:kickSpeed(player) == Balance.MaxKickSpeed)
end

print(string.format("%d comprobaciones pasaron, %d fallaron", passed, failed))
if failed > 0 then
	error("hay tests que fallaron")
end
