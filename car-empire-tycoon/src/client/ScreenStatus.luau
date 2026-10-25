--!strict
-- Pantallas de carga, error de carga y avisos de guardado.

local Ui = require(script.Parent.Ui)
local T = Ui.T
local W = Ui.W

local Screen = {}

local function centerCard(parent: Instance, children: { Instance? })
	local bg = Ui.new("Frame", {
		Name = "Fondo",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = T.bg,
		BackgroundTransparency = 0.08,
		Parent = parent,
	})
	local card = Ui.card(children, { bg = T.p1, pad = 22, gap = 14, radius = 16, stroke = T.line })
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromOffset(520, 0)
	card.Parent = bg
	return card
end

function Screen.loading(parent: Instance)
	centerCard(parent, {
		Ui.lbl("Car Empire Tycoon"),
		Ui.text("Cargando tu partida…", { size = Ui.S.h1, weight = W.bold }),
		Ui.text("Estamos recuperando tu empresa del servidor. Si es tu primera vez, vas a poder fundar una.", { size = Ui.S.sm, color = T.mut }),
	})
end

function Screen.failed(parent: Instance, p: any)
	local App = require(script.Parent.App) :: any
	local locked = p.loadCode == "locked"
	local corrupt = p.loadCode == "corrupt"
	centerCard(parent, {
		Ui.lbl("Car Empire Tycoon", T.re2),
		Ui.text("No se pudo cargar tu partida", { size = Ui.S.h1, weight = W.bold }),
		Ui.note("r", tostring(p.loadError or "Error desconocido.")),
		Ui.text(
			locked and "Tu partida sigue abierta en otro servidor (por ejemplo, si saliste hace instantes). Esperá unos segundos y reintentá."
				or corrupt and "Para no perder nada, el juego no tocó tus datos guardados. Avisá al equipo del juego."
				or "El servicio de guardado de Roblox no respondió. Tus datos guardados no se modificaron.",
			{ size = Ui.S.sm, color = T.mut }
		),
		Ui.note("y", "Mientras la carga no funcione, esta sesión no guarda nada para no sobrescribir tu partida."),
		Ui.row({
			Ui.spacer(),
			Ui.button("Reintentar la carga", "p", function()
				App.request("retryLoad")
			end),
		}),
	})
end

-- Banda de avisos de guardado (estilo .demo-band de la V3).
function Screen.banners(parent: Instance, p: any)
	local text = nil
	local danger = false
	if p.saveWarning then
		text = p.saveWarning
		danger = true
	elseif p.saveMode == "memory" then
		text = "Modo Studio: el guardado es temporal porque «Enable Studio Access to API Services» está desactivado. Activalo en Game Settings › Security para probar el guardado real."
	end
	if not text then
		return
	end
	local band = Ui.new("TextLabel", {
		Name = "BandaGuardado",
		Text = text,
		TextWrapped = true,
		TextSize = Ui.S.xs,
		Weight = W.bold,
		TextColor3 = danger and T.re2 or T.ye,
		BackgroundColor3 = danger and Color3.fromHex("#2A1215") or Color3.fromHex("#2A2412"),
		BackgroundTransparency = 0.05,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.fromOffset(640, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextXAlignment = Enum.TextXAlignment.Center,
		Corner = 10,
		Stroke = danger and T.re or T.ye,
		Pad = { 6, 14 },
		ZIndex = 20,
		Parent = parent,
	})
	return band
end

return Screen
