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

-- Atajos de teclado como en la V3 (handleKey): Esc cierra lo que esté arriba, 0 sede, 1–8 secciones,
-- Enter juega/crea/ejecuta la próxima acción, Tab oculta los paneles y, en el editor, [ ] pasos, H oculta
-- la interfaz, 1–7 cámaras y Ctrl+Z/Ctrl+Y deshacer/rehacer.
local NUMBER_KEYS = {
	Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four,
	Enum.KeyCode.Five, Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight,
}
local function numberOf(key: Enum.KeyCode): number?
	for i, k in NUMBER_KEYS do
		if k == key then
			return i
		end
	end
	return nil
end
UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed or UserInputService:GetFocusedTextBox() then
		return
	end
	local p = App.payload
	if not p or p.status ~= "ready" then
		return
	end
	local key = input.KeyCode
	local route = App.ui.route
	if #App.ui.dialogs > 0 then
		if key == Enum.KeyCode.Escape then
			App.closeDialog()
		end
		return
	end
	if key == Enum.KeyCode.Escape then
		if App.ui.pop then
			App.ui.pop = nil
			App.forceRender()
		elseif route == "menu" and App.screens.menu.isRenaming() then
			App.screens.menu.cancelRename()
		elseif route == "editor" then
			local e = App.ui.editor
			if e and e.hideUI then
				App.screens.editor.toggleHide()
			else
				App.go("juego")
			end
		elseif route == "nueva" then
			App.go("menu")
		elseif App.g and route ~= "juego" and route ~= "menu" then
			App.go("juego")
		elseif route == "juego" and App.ui.sidePanel then
			App.ui.sidePanel = nil
			App.forceRender()
		end
		return
	end
	if route == "menu" then
		if key == Enum.KeyCode.Return and not App.screens.menu.isRenaming() then
			local slot = App.screens.menu.firstSlot()
			if slot then
				App.screens.menu.play(slot)
			end
		end
		return
	end
	if route == "nueva" then
		if key == Enum.KeyCode.Return then
			App.screens.company.create(nil)
		end
		return
	end
	if not App.g then
		return
	end
	local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	if ctrl then
		if route == "editor" then
			if key == Enum.KeyCode.Z then
				if shift then
					App.screens.editor.redo()
				else
					App.screens.editor.undo()
				end
			elseif key == Enum.KeyCode.Y then
				App.screens.editor.redo()
			end
		end
		return
	end
	if route == "editor" then
		local ed = App.screens.editor
		local e = App.ui.editor
		if not e then
			return
		end
		if key == Enum.KeyCode.LeftBracket then
			if e.step > 1 then
				ed.goStep(e.step - 1)
			end
		elseif key == Enum.KeyCode.RightBracket then
			if e.step < 4 then
				ed.goStep(e.step + 1)
			end
		elseif key == Enum.KeyCode.H then
			ed.toggleHide()
		else
			local n = numberOf(key)
			if n and n <= 7 then
				ed.setCam(ed.CAMS[n][1])
			end
		end
		return
	end
	if key == Enum.KeyCode.Zero then
		App.go("juego")
		return
	end
	local n = numberOf(key)
	if n then
		local nav = App.screens.hud.NAV[n]
		if nav then
			App.go(nav[1])
		end
		return
	end
	if route == "juego" then
		if key == Enum.KeyCode.Tab then
			App.ui.panelsHidden = not App.ui.panelsHidden
			App.forceRender()
		elseif key == Enum.KeyCode.Return then
			App.screens.hud.runNext(App.g)
		end
	end
end)

App.render()
-- Pide el estado actual por si el primer envío llegó antes de conectar el evento.
task.spawn(function()
	App.request("sync")
end)
