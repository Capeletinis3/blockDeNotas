--!strict
-- Car Empire Tycoon — arranque del cliente: registra pantallas y escucha al servidor.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local App = require(script.Parent.App)
App.screens.status = require(script.Parent.ScreenStatus)
App.screens.company = require(script.Parent.ScreenCompany)
App.screens.hud = require(script.Parent.ScreenHud)
App.screens.sheet = require(script.Parent.ScreenSheet)
App.screens.editor = require(script.Parent.ScreenEditor)
App.screens.fabrica = require(script.Parent.ScreenFactory)
App.screens.autos = require(script.Parent.ScreenInventory)
App.screens.ventas = require(script.Parent.ScreenSales)

local Dialogs = require(script.Parent.Dialogs)
App.dialogs.order = Dialogs.order
App.dialogs.counter = Dialogs.counter
App.dialogs.confirm = Dialogs.confirm

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
	if App.g and (screen == "editor" or App.screens[screen]) then
		App.go(screen)
	end
end)

-- Atajos de teclado como en la V3: 0 sede, 1–4 secciones, Esc cierra.
local KEYS = {
	[Enum.KeyCode.Zero] = "juego",
	[Enum.KeyCode.One] = "editor",
	[Enum.KeyCode.Two] = "autos",
	[Enum.KeyCode.Three] = "fabrica",
	[Enum.KeyCode.Four] = "ventas",
}
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed or not App.g or UserInputService:GetFocusedTextBox() then
		return
	end
	if input.KeyCode == Enum.KeyCode.Escape then
		if App.ui.dialog then
			App.closeDialog()
		elseif App.ui.route ~= "juego" then
			App.go("juego")
		end
		return
	end
	local route = KEYS[input.KeyCode]
	if route then
		App.go(route)
	end
end)

App.render()
-- Pide el estado actual por si el primer envío llegó antes de conectar el evento.
task.spawn(function()
	App.request("sync")
end)
