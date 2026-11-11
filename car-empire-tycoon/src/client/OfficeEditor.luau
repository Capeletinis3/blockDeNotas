--!strict
--[[ Editor de oficinas: estado y colocación (cliente). La pantalla es ScreenOffice; la escena, OfficeScene; la
	cámara, OfficeCamera.
	Modos:
	  "idle"  → clic sobre un mueble colocado lo elige (mover, girar o guardar en el inventario).
	  "place" → un mueble del catálogo o del inventario sigue al cursor; clic = confirmar. Se pueden colocar
	            varias unidades seguidas sin cerrar el catálogo.
	  "move"  → el mueble elegido sigue al cursor; clic = confirmar la nueva posición.
	La vista previa se valida con Office.validatePlacement sobre la copia de la partida del cliente: las mismas
	reglas que aplica el servidor. Nada cambia en la oficina hasta que el servidor responde que sí (el cliente
	nunca toca dinero, inventario ni muebles: solo pide officePlace / officeMove / officeRemove).
	La API pública (startPlace, hover, confirm, rotate, selectAt…) es la que usa el mouse y la que usan las
	pruebas; está pensada para poder agregar controles táctiles después. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Office = require(Shared.Office)
local OfficeCatalog = require(Shared.OfficeCatalog)

local App = require(script.Parent.App)
local Scene = require(script.Parent.OfficeScene)
local Camera = require(script.Parent.OfficeCamera)

local Editor = {}

local st = {
	active = false,
	mode = "idle", -- "idle" | "place" | "move"
	item = nil :: string?, -- mueble a colocar (modo place)
	instance = nil :: string?, -- mueble elegido (idle con selección, o move)
	rot = 0,
	room = nil :: string?, -- habitación elegida en el panel (encuadre)
	hover = nil :: any, -- { room, x, y, valid, reason }
	busy = false,
	message = nil :: string?, -- último motivo de rechazo del servidor
	company = nil :: string?,
}
Editor._state = st

-- Avisa a la pantalla que cambió el estado (barra contextual). Lo asigna ScreenOffice.
Editor.onChange = nil :: (() -> ())?
local function changed()
	if Editor.onChange then
		Editor.onChange()
	end
end

function Editor.state(): any
	return st
end

function Editor.office(): any
	return App.g and App.g.office or nil
end

function Editor.isActive(): boolean
	return st.active
end

-- Entrar / salir ------------------------------------------------------------------------------------------

function Editor.enter()
	local o = Editor.office()
	if not o then
		return
	end
	local company = App.g.company and App.g.company.id or "?"
	if st.company ~= company then
		-- Otra empresa: nada del estado anterior pasa a esta.
		st.mode, st.item, st.instance, st.rot, st.room, st.hover, st.message = "idle", nil, nil, 0, nil, nil, nil
		st.company = company
	end
	st.active = true
	Scene.buildRooms(o)
	Scene.syncFurniture(o)
	Scene.show(true)
	local plan = OfficeCatalog.plan(o.level)
	if not st.room or not OfficeCatalog.room(o.level, st.room) then
		st.room = plan.rooms[1].id
	end
	Camera.frame(nil, true)
	Editor.refreshPreview()
end

-- Al recibir la partida nueva (después de una operación o de una ampliación): solo lo que cambió.
function Editor.sync()
	if not st.active then
		return
	end
	local o = Editor.office()
	if not o then
		return
	end
	Scene.buildRooms(o)
	Scene.syncFurniture(o)
	if st.instance and not Office.find(o, st.instance) then
		st.instance = nil
		if st.mode == "move" then
			st.mode = "idle"
		end
	end
	if st.room and not OfficeCatalog.room(o.level, st.room) then
		st.room = OfficeCatalog.plan(o.level).rooms[1].id
	end
	Scene.select(st.mode ~= "move" and st.instance or nil)
	Editor.refreshPreview()
end

function Editor.leave()
	if not st.active then
		return
	end
	st.active = false
	st.mode, st.item, st.instance, st.hover, st.busy, st.message = "idle", nil, nil, nil, false, nil
	Scene.destroy()
	Camera.release()
end

-- Modos ---------------------------------------------------------------------------------------------------

function Editor.startPlace(itemId: string)
	local item = OfficeCatalog.item(itemId)
	if not item or not st.active then
		return
	end
	st.mode, st.item, st.instance, st.message = "place", itemId, nil, nil
	if not Office.validRotation(item, st.rot) then
		st.rot = 0
	end
	Scene.select(nil)
	Editor.refreshPreview()
	changed()
end

function Editor.startMove()
	local o = Editor.office()
	local p = o and st.instance and Office.find(o, st.instance)
	if not p then
		return
	end
	st.mode, st.item, st.rot, st.message = "move", p.item, p.rot, nil
	st.hover = { room = p.room, x = p.x, y = p.y }
	Scene.select(nil)
	Editor.refreshPreview()
	changed()
end

-- Cancela la vista previa (gratis) o deselecciona. Devuelve true si había algo que cancelar.
function Editor.cancel(): boolean
	if st.mode ~= "idle" then
		st.mode, st.item, st.message = "idle", nil, nil
		Scene.preview(nil)
		Scene.select(st.instance)
		changed()
		return true
	elseif st.instance then
		st.instance = nil
		Scene.select(nil)
		changed()
		return true
	end
	return false
end

function Editor.setRoom(roomId: string)
	local o = Editor.office()
	if o and OfficeCatalog.room(o.level, roomId) then
		st.room = roomId
		Camera.frame(roomId)
		changed()
	end
end

-- Posición y validación -------------------------------------------------------------------------------------

-- Ajusta un punto continuo de la habitación a la cuadrícula según el mueble y el giro (mismas reglas que
-- Office.aligned: con giros rectos, lado par sobre una línea e impar al medio de una casilla).
function Editor.snap(item: any, x: number, y: number, rot: number): (number, number)
	if Office.isDiagonal(rot) then
		return math.floor(x * 2 + 0.5) / 2, math.floor(y * 2 + 0.5) / 2
	end
	local w, d = item.cells[1], item.cells[2]
	if rot % 180 == 90 then
		w, d = d, w
	end
	local ox, oy = (w % 2) / 2, (d % 2) / 2
	return math.floor(x - ox + 0.5) + ox, math.floor(y - oy + 0.5) + oy
end

-- Recalcula validez y vista previa con la posición actual.
function Editor.refreshPreview()
	if not st.active or st.mode == "idle" or not st.item or not st.hover then
		Scene.preview(nil)
		return
	end
	local o = Editor.office()
	local item = OfficeCatalog.item(st.item)
	if not o or not item then
		return
	end
	local h = st.hover
	local req = { room = h.room, x = h.x, y = h.y, rot = st.rot }
	local ok, why = Office.validatePlacement(o, item, req, st.mode == "move" and st.instance or nil)
	h.valid, h.reason = ok, why
	Scene.preview(st.item, h.room, h.x, h.y, st.rot, ok)
end

-- El cursor está sobre (x, y) continuos de la habitación roomId (nil = fuera de las habitaciones).
function Editor.hover(roomId: string?, x: number?, y: number?)
	if not st.active or st.mode == "idle" then
		return
	end
	local item = st.item and OfficeCatalog.item(st.item)
	if not item or not roomId or not x or not y then
		if st.hover then
			st.hover.valid, st.hover.reason = false, "Fuera de las habitaciones."
		end
		return
	end
	local sx, sy = Editor.snap(item, x, y, st.rot)
	local h = st.hover
	if h and h.room == roomId and h.x == sx and h.y == sy then
		return -- misma casilla: nada que recalcular
	end
	st.hover = { room = roomId, x = sx, y = sy }
	Editor.refreshPreview()
	changed()
end

-- Gira la vista previa (o el mueble elegido, en su lugar) de a 45°.
function Editor.rotate(dir: number)
	if not st.active then
		return
	end
	if st.mode == "idle" then
		if st.instance then
			Editor.rotateSelected(dir)
		end
		return
	end
	st.rot = (st.rot + (dir >= 0 and 45 or -45)) % 360
	local item = st.item and OfficeCatalog.item(st.item)
	if item and st.hover then
		-- Al girar cambia la paridad del lado: se reajusta a la cuadrícula.
		st.hover.x, st.hover.y = Editor.snap(item, st.hover.x, st.hover.y, st.rot)
	end
	Editor.refreshPreview()
	changed()
end

-- Operaciones con el servidor ---------------------------------------------------------------------------------

local function send(action: string, payload: any, requestId: string?): any
	st.busy = true
	changed()
	local r = App.request(action, payload, { key = "oficina", requestId = requestId })
	st.busy = false
	if not r.ok and not r.pending then
		st.message = r.msg
	else
		st.message = nil
	end
	changed()
	return r
end

-- Confirma la vista previa en la posición actual. Devuelve la respuesta del servidor (o nil si no se envió).
function Editor.confirm(requestId: string?): any
	if not st.active or st.busy or st.mode == "idle" or not st.hover or not st.item then
		return nil
	end
	local h = st.hover
	Editor.refreshPreview()
	if not h.valid then
		st.message = h.reason
		changed()
		return { ok = false, msg = h.reason }
	end
	if st.mode == "place" then
		local r = send("officePlace", { item = st.item, room = h.room, x = h.x, y = h.y, rot = st.rot }, requestId)
		-- Sigue en modo colocar: se pueden poner varias unidades seguidas.
		Editor.sync()
		return r
	end
	local r = send("officeMove", { instance = st.instance, room = h.room, x = h.x, y = h.y, rot = st.rot }, requestId)
	if r.ok then
		st.mode, st.item = "idle", nil
		Scene.preview(nil)
	end
	Editor.sync()
	return r
end

-- Gira el mueble elegido en su lugar (si el giro nuevo entra).
function Editor.rotateSelected(dir: number): any
	local o = Editor.office()
	local p = o and st.instance and Office.find(o, st.instance)
	if not p or st.busy then
		return nil
	end
	local rot = (p.rot + (dir >= 0 and 45 or -45)) % 360
	local item = OfficeCatalog.item(p.item)
	local x, y = Editor.snap(item, p.x, p.y, rot)
	local ok, why = Office.validatePlacement(o, item, { room = p.room, x = x, y = y, rot = rot }, p.id)
	if not ok then
		st.message = why
		changed()
		return { ok = false, msg = why }
	end
	local r = send("officeMove", { instance = p.id, room = p.room, x = x, y = y, rot = rot })
	Editor.sync()
	return r
end

-- Guarda el mueble elegido en el inventario (sin reembolso).
function Editor.removeSelected(): any
	if not st.instance or st.busy then
		return nil
	end
	local id = st.instance
	local r = send("officeRemove", { instance = id })
	if r.ok then
		st.instance = nil
		if st.mode == "move" then
			st.mode, st.item = "idle", nil
		end
		Scene.preview(nil)
	end
	Editor.sync()
	return r
end

-- Elige el mueble colocado bajo (x, y) de la habitación, o nada.
function Editor.selectAt(roomId: string?, x: number?, y: number?): string?
	local o = Editor.office()
	if not o or st.mode ~= "idle" then
		return nil
	end
	local pick = nil
	if roomId and x and y then
		for i = #o.placed, 1, -1 do
			local p = o.placed[i]
			if p.room == roomId and Office.hits(p, x, y) then
				pick = p.id
				break
			end
		end
	end
	st.instance = pick
	st.message = nil
	Scene.select(pick)
	changed()
	return pick
end

-- Entrada del mouse (PC) ----------------------------------------------------------------------------------------

-- Punto del piso bajo el cursor → (habitación, x, y). Intersección del rayo con el plano del piso (sin
-- raycast físico, así no lo tapan los muebles ni las paredes).
function Editor.pointerRoom(): (string?, number?, number?)
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil, nil, nil
	end
	local ok, ray = pcall(function()
		local m = UserInputService:GetMouseLocation()
		return cam:ViewportPointToRay(m.X, m.Y)
	end)
	if not ok or not ray or math.abs(ray.Direction.Y) < 1e-4 then
		return nil, nil, nil
	end
	local t = (Scene.ORIGIN.Y - ray.Origin.Y) / ray.Direction.Y
	if t <= 0 then
		return nil, nil, nil
	end
	return Scene.worldToRoom(ray.Origin + ray.Direction * t)
end

local started = false
function Editor.start()
	if started then
		return -- una sola vez: entrar y salir del editor no duplica conexiones
	end
	started = true
	Camera.start()
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if st.active and st.mode ~= "idle" and input.UserInputType == Enum.UserInputType.MouseMovement then
			Editor.hover(Editor.pointerRoom())
		end
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or not st.active or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		if st.mode == "idle" then
			Editor.selectAt(Editor.pointerRoom())
		else
			Editor.hover(Editor.pointerRoom())
			task.spawn(Editor.confirm)
		end
	end)
end

-- Teclas dentro del editor (las llama Main.client). Devuelve true si la usó.
function Editor.key(key: Enum.KeyCode, shift: boolean): boolean
	if not st.active then
		return false
	end
	if key == Enum.KeyCode.R then
		Editor.rotate(shift and -1 or 1)
		return true
	elseif key == Enum.KeyCode.Delete or key == Enum.KeyCode.Backspace then
		if st.instance and st.mode == "idle" then
			task.spawn(Editor.removeSelected)
		end
		return true
	elseif key == Enum.KeyCode.M then
		if st.instance and st.mode == "idle" then
			Editor.startMove()
		end
		return true
	elseif key == Enum.KeyCode.Return then
		task.spawn(Editor.confirm)
		return true
	end
	return false
end

return Editor
