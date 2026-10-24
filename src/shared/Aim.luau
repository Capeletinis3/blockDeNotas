local Config = require(script.Parent.Config)

local Aim = {}

-- El jugador mira hacia +Z. Ángulo positivo = derecha del jugador (-X).
function Aim.direction(angleDeg: number): Vector3
	local yaw = math.rad(math.clamp(angleDeg, -Config.MaxAimAngle, Config.MaxAimAngle))
	local pitch = math.rad(Config.KickElevation)
	return Vector3.new(-math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch))
end

return Aim
