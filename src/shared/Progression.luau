-- Reglas de progresión y pagos. No usa APIs de Roblox para poder testearse con luau
-- (ver tests/progression.test.luau).
local Progression = {}
Progression.__index = Progression

function Progression.new(balance)
	return setmetatable({ balance = balance }, Progression)
end

function Progression:newPlayer()
	return {
		money = 0,
		strength = self.balance.StartStrength,
		ballLevel = 1,
		shoesOwned = { [1] = true },
		shoeEquipped = 1,
		lastTrain = -math.huge,
	}
end

function Progression:payout(direct: number, chain: number): number
	return direct * self.balance.MoneyDirect + chain * self.balance.MoneyChain
end

function Progression:kickPower(player): number
	return player.strength * self.balance.Shoes[player.shoeEquipped].Multiplier
end

function Progression:kickSpeed(player): number
	local balance = self.balance
	return math.min(balance.BaseKickSpeed + self:kickPower(player) * balance.SpeedPerPower, balance.MaxKickSpeed)
end

function Progression:ballStats(player)
	return self.balance.BallLevels[player.ballLevel]
end

-- Las acciones devuelven ok y, si falla, el motivo.

function Progression:buyBallLevel(player): (boolean, string?)
	local nextLevel = self.balance.BallLevels[player.ballLevel + 1]
	if not nextLevel then
		return false, "max"
	end
	if player.money < nextLevel.Price then
		return false, "funds"
	end
	player.money -= nextLevel.Price
	player.ballLevel += 1
	return true
end

function Progression:buyShoe(player, id: number): (boolean, string?)
	local shoe = self.balance.Shoes[id]
	if not shoe then
		return false, "invalid"
	end
	if player.shoesOwned[id] then
		return false, "owned"
	end
	if player.money < shoe.Price then
		return false, "funds"
	end
	player.money -= shoe.Price
	player.shoesOwned[id] = true
	player.shoeEquipped = id
	return true
end

function Progression:equipShoe(player, id: number): (boolean, string?)
	if not player.shoesOwned[id] then
		return false, "notOwned"
	end
	player.shoeEquipped = id
	return true
end

function Progression:train(player, now: number): (boolean, string?)
	if now - player.lastTrain < self.balance.TrainCooldown then
		return false, "cooldown"
	end
	player.lastTrain = now
	player.strength += self.balance.StrengthPerRep
	return true
end

-- Registro de un intento: cada pieza cuenta una vez y el pago se entrega una sola vez.
local Attempt = {}
Attempt.__index = Attempt

function Progression:newAttempt(kicker)
	return setmetatable({
		progression = self,
		kicker = kicker,
		pieces = {},
		direct = 0,
		chain = 0,
		paid = false,
	}, Attempt)
end

function Attempt:recordBreak(pieceId, direct: boolean): boolean
	if self.paid or self.pieces[pieceId] then
		return false
	end
	self.pieces[pieceId] = true
	if direct then
		self.direct += 1
	else
		self.chain += 1
	end
	return true
end

-- Devuelve lo ganado la primera vez y 0 en las siguientes.
function Attempt:settle(): number
	if self.paid then
		return 0
	end
	self.paid = true
	return self.progression:payout(self.direct, self.chain)
end

return Progression
