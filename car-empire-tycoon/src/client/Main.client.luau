--!strict
-- Car Empire Tycoon — arranque del cliente: registra pantallas y diálogos y escucha al servidor.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local App = require(script.Parent.App)
App.screens.status = require(script.Parent.ScreenStatus)
App.screens.menu = require(script.Parent.ScreenMenu)
App.screens.company = require(script.Parent.ScreenCompany)
App.screens.hud = require(script.Parent.ScreenHud)
App.screens.sheet = require(script.Parent.ScreenSheet)
App.screens.editor = require(script.Parent.ScreenEditor)
App.screens.fabrica = require(script.Parent.ScreenFactory)
App.screens.autos = require(script.Parent.ScreenInventory)
App.screens.ventas = require(script.Parent.ScreenSales)
App.screens.mercado = require(script.Parent.ScreenMarket)
App.screens.investigacion = require(script.Parent.ScreenResearch)
App.screens.personal = require(script.Parent.ScreenStaff)
App.screens.compania = require(script.Parent.ScreenCompania)
App.screens.misiones = require(script.Parent.ScreenMissions)
App.screens.estadisticas = require(script.Parent.ScreenStats)

local Dialogs = require(script.Parent.Dialogs)
for kind, builder in Dialogs :: any do
	App.dialogBuilders[kind] = builder
end

local remotes = ReplicatedStorage:WaitForChild("CarEmpireRemotes")
local StateEvent = remotes:WaitForChild("State") :: RemoteEvent
local NoticeEvent = remotes:WaitForChild("Notice") :: RemoteEvent
local OpenEvent = remotes:WaitForChild("Open") :: RemoteEvent

StateEvent.OnClientEvent:Connect(function(payload: any)
	App.onState(payload)
end)

NoticeEvent.OnClientEvent:Connect(function(kind: string, text: string)
	App.toast(kind, text)
end)

-- Los ProximityPrompt del garaje abren la pantalla correspondiente (el servidor verifica que seas el dueño).
OpenEvent.OnClientEvent:Connect(function(screen: string)
	if App.g and (screen == "editor" or App.screens[screen]) and #App.ui.dialogs == 0 then
		App.go(screen)
	end
end)

-- Atajos de teclado como en la V3: 0 sede, 1–8 secciones, Esc cierra, Ctrl+Z/Ctrl+Y en el editor.
local NUMBER_KEYS = {
	Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four,
	Enum.KeyCode.Five, Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight,
}
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed or not App.g or UserInputService:GetFocusedTextBox() then
		return
	end
	local p = App.payload
	if not p or p.status ~= "ready" then
		return
	end
	if input.KeyCode == Enum.KeyCode.Escape then
		if #App.ui.dialogs > 0 then
			App.closeDialog()
		elseif App.ui.sidePanel then
			App.ui.sidePanel = nil
			App.forceRender()
		elseif App.ui.route ~= "juego" then
			App.go("juego")
		end
		return
	end
	local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	if ctrl and App.ui.route == "editor" and #App.ui.dialogs == 0 then
		if input.KeyCode == Enum.KeyCode.Z then
			App.screens.editor.undo()
		elseif input.KeyCode == Enum.KeyCode.Y then
			App.screens.editor.redo()
		end
		return
	end
	if #App.ui.dialogs > 0 then
		return
	end
	if input.KeyCode == Enum.KeyCode.Zero then
		App.go("juego")
		return
	end
	for i, key in NUMBER_KEYS do
		if input.KeyCode == key then
			local nav = App.screens.hud.NAV[i]
			if nav then
				App.go(nav[1])
			end
			return
		end
	end
end)

App.render()
-- Pide el estado actual por si el primer envío llegó antes de conectar el evento.
task.spawn(function()
	App.request("sync")
end)
