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
	pruebas; está pensada para poder agregar controles táctiles después.

	Secciones: «mobiliario» (lo anterior) y «remodelacion». En Remodelación se elige una habitación y se
	prueban acabados: st.drafts[habitación] = { floor?, wall?, covering?, lighting? } es una vista previa
	temporal (nunca toca g.office.finishes, no cobra ni envía nada). Confirmar manda officeRemodel con los ids
	elegidos, la revisión de la oficina y el total que se vio; el servidor recalcula todo. Al salir del editor
	o cambiar de empresa los borradores se descartan.

	Operaciones sin respuesta: quedan pendientes por empresa (pendingByCompany) con su requestId y su
	companyId, sobreviven a salir del editor y a cambiar de empresa, y solo se resuelven con una respuesta real
	del servidor a ese mismo requestId (actualizar la vista no las descarta). ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Office = require(Shared.Office)
local OfficeCatalog = require(Shared.OfficeCatalog)

local Rules = require(Shared.Rules)
local Util = require(Shared.Util)

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
	-- Operación sin respuesta del servidor { action, payload, requestId }: puede haberse aplicado o no. Se
	-- reintenta tal cual (mismo requestId: el servidor no la aplica dos veces) antes de enviar otra.
	pending = nil :: any,
	section = "mobiliario", -- "mobiliario" | "remodelacion"
	kind = "floor", -- categoría de acabados visible en Remodelación
	drafts = {} :: { [string]: any }, -- vista previa de acabados por habitación (no persistida)
	gridHidden = false,
}
Editor._state = st
-- Operaciones inciertas de cada empresa (por id de empresa): no se pierden al cambiar de empresa.
local pendingByCompany: { [string]: any } = {}
Editor._pendingByCompany = pendingByCompany

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
		-- Otra empresa: nada del estado anterior pasa a esta. Su operación incierta (si hay) se guarda aparte
		-- y vuelve cuando se abra de nuevo esa empresa.
		if st.company then
			pendingByCompany[st.company] = st.pending
		end
		st.mode, st.item, st.instance, st.rot, st.room, st.hover, st.message = "idle", nil, nil, 0, nil, nil, nil
		st.pending = pendingByCompany[company]
		st.section, st.kind = "mobiliario", "floor"
		st.company = company
	end
	st.drafts = {}
	st.active = true
	Scene.buildRooms(o)
	Scene.syncFurniture(o)
	Scene.setGrid(st.section == "remodelacion" and (st.gridHidden and "oculta" or "tenue") or "normal")
	Scene.show(true)
	local plan = OfficeCatalog.plan(o.level)
	if not st.room or not OfficeCatalog.room(o.level, st.room) then
		st.room = plan.rooms[1].id
	end
	if st.pending then
		st.message = "Hay una operación de esta empresa sin confirmar por el servidor. «Reintentar» la reenvía con el mismo identificador."
	end
	if st.section == "remodelacion" then
		Scene.highlightRoom(st.room)
		Camera.frame(st.room, true)
	else
		Camera.frame(nil, true)
	end
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
	Editor.applyDrafts()
	Editor.refreshPreview()
end

function Editor.leave()
	if not st.active then
		return
	end
	st.active = false
	-- La remodelación sin confirmar se descarta; la operación incierta (si hay) se conserva para su empresa.
	st.mode, st.item, st.instance, st.hover, st.busy, st.message = "idle", nil, nil, nil, false, nil
	st.drafts = {}
	if st.company then
		pendingByCompany[st.company] = st.pending
	end
	Scene.destroy()
	Camera.release()
end

-- Remodelación ----------------------------------------------------------------------------------------------

function Editor.setSection(section: string)
	if not st.active or (section ~= "mobiliario" and section ~= "remodelacion") then
		return
	end
	if section == "remodelacion" then
		-- Sin vistas previas de muebles mientras se remodela (no se cobra ni se coloca nada).
		st.mode, st.item, st.hover = "idle", nil, nil
		st.instance = nil
		Scene.preview(nil)
		Scene.select(nil)
		Scene.setGrid(st.gridHidden and "oculta" or "tenue")
		Scene.highlightRoom(st.room)
		if st.room then
			Camera.frame(st.room)
		end
	else
		Scene.setGrid("normal")
		Scene.highlightRoom(nil)
	end
	st.section = section
	st.message = nil
	changed()
end

function Editor.setKind(kind: string)
	if OfficeCatalog.FINISHES[kind] then
		st.kind = kind
		changed()
	end
end

function Editor.toggleGrid()
	st.gridHidden = not st.gridHidden
	if st.section == "remodelacion" then
		Scene.setGrid(st.gridHidden and "oculta" or "tenue")
	end
	changed()
end

-- Acabados instalados (persistidos) de una habitación.
function Editor.installed(roomId: string): any
	local o = Editor.office()
	return (o and o.finishes and o.finishes[roomId]) or OfficeCatalog.DEFAULT_FINISH
end

-- Lo que se ve: instalado + vista previa.
function Editor.look(roomId: string): any
	local look = table.clone(Editor.installed(roomId))
	for k, v in st.drafts[roomId] or {} do
		look[k] = v
	end
	return look
end

-- Cambios efectivos de la vista previa (solo lo que difiere de lo instalado).
function Editor.changes(roomId: string): any
	local out = {}
	local inst = Editor.installed(roomId)
	for k, v in st.drafts[roomId] or {} do
		if inst[k] ~= v then
			out[k] = v
		end
	end
	return out
end

function Editor.hasDraft(roomId: string): boolean
	return next(Editor.changes(roomId)) ~= nil
end

-- Muestra en la escena la vista previa de cada habitación (y limpia lo que ya quedó instalado).
function Editor.applyDrafts()
	local o = Editor.office()
	if not o then
		return
	end
	for _, r in OfficeCatalog.plan(o.level).rooms do
		local ch = Editor.changes(r.id)
		st.drafts[r.id] = next(ch) and ch or nil
		Scene.applyLook(r.id, Editor.look(r.id))
	end
	for id in st.drafts do
		if not OfficeCatalog.room(o.level, id) then
			st.drafts[id] = nil
		end
	end
end

-- Prueba un acabado en la habitación elegida (gratis: solo vista previa). Elegir lo instalado lo quita del
-- borrador.
function Editor.choose(kind: string, id: string): boolean
	local o = Editor.office()
	local f = OfficeCatalog.finish(kind, id)
	if not st.active or not o or not st.room or not f then
		return false
	end
	if not Office.available(f, Rules.year(App.g)) then
		st.message = f.name .. " estará disponible desde " .. f.year .. "."
		changed()
		return false
	end
	local d = st.drafts[st.room] or {}
	if Editor.installed(st.room)[kind] == id then
		d[kind] = nil
	else
		d[kind] = id
	end
	st.drafts[st.room] = next(d) and d or nil
	st.message = nil
	Scene.applyLook(st.room, Editor.look(st.room))
	changed()
	return true
end

-- Presupuesto de la habitación elegida con la misma función que usa el servidor: (total, líneas) o (nil, motivo).
function Editor.quote(roomId: string?): (number?, any)
	local o = Editor.office()
	local room = roomId or st.room
	if not o or not room then
		return nil, "Elegí una habitación."
	end
	return Office.remodelQuote(o, room, Editor.changes(room), Rules.year(App.g))
end

-- Restaurar selección: la habitación elegida vuelve a verse como está instalada.
function Editor.restoreRoom()
	if st.room then
		st.drafts[st.room] = nil
		Scene.applyLook(st.room, Editor.look(st.room))
		st.message = nil
		changed()
	end
end

-- Cancelar cambios: todas las habitaciones vuelven a lo instalado (no se cobra nada).
function Editor.cancelRemodel()
	st.drafts = {}
	Editor.applyDrafts()
	st.message = nil
	changed()
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
		if st.section == "remodelacion" then
			Scene.highlightRoom(roomId)
		end
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
		-- Fuera de las habitaciones: se olvida la posición anterior (confirmar no puede usarla) y la vista
		-- previa desaparece hasta que el cursor vuelva a una habitación.
		if st.hover ~= nil then
			st.hover = nil
			Scene.preview(nil)
			changed()
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

-- Pide al servidor la partida actual (reconciliar después de una operación sin respuesta).
local function resync()
	task.spawn(function()
		App.request("sync")
	end)
end

--[[ Envía una operación económica. Cada operación lleva su requestId (lo genera el editor): si no hay
	respuesta, queda en st.pending con ese mismo id para reintentarla sin riesgo de cobrar dos veces, y se
	pide el estado al servidor. Con cualquier respuesta real del servidor la operación queda resuelta. ]]
local function send(action: string, payload: any, requestId: string?): any
	local id = requestId or HttpService:GenerateGUID(false)
	-- Cada operación queda asociada a su empresa: el servidor la rechaza si llega con otra empresa activa.
	local company = st.company
	local body = table.clone(payload)
	body.companyId = company
	st.busy = true
	changed()
	local r = App.request(action, body, { key = "oficina", requestId = id })
	st.busy = false
	if r.pending then
		-- Otra operación del editor sigue en curso: no se envió nada.
		changed()
		return r
	end
	local uncertain = r.noResponse or r.retry
	local record = uncertain and { action = action, payload = payload, requestId = id, company = company } or nil
	if st.company ~= company then
		-- Respuesta tardía de otra empresa: se guarda para esa empresa y no toca la que está abierta.
		pendingByCompany[company :: string] = record
		changed()
		return r
	end
	if uncertain then
		-- Sin respuesta (no se sabe si se aplicó) o el servidor no la procesó todavía: se conserva el id.
		st.pending = record
		pendingByCompany[company :: string] = record
		st.message = r.retry and (tostring(r.msg) .. " «Reintentar» la reenvía con el mismo identificador.") or "Sin respuesta del servidor. «Reintentar» la reenvía igual: si ya se había aplicado, no se cobra dos veces."
		changed()
		resync()
		return r
	end
	-- Respuesta real del servidor: la operación quedó resuelta (aplicada, repetida o rechazada).
	st.pending = nil
	pendingByCompany[company :: string] = nil
	if r.duplicate then
		-- Ya se había aplicado (reenvío): vale lo que diga el estado del servidor.
		st.message = nil
		resync()
	elseif not r.ok then
		st.message = r.msg
	else
		st.message = nil
	end
	changed()
	return r
end

-- Reintenta la operación que quedó sin respuesta, con su mismo requestId.
function Editor.retry(): any
	local p = st.pending
	if not p or st.busy then
		return nil
	end
	local r = send(p.action, p.payload, p.requestId)
	Editor.sync()
	return r
end

-- Actualiza la vista con el estado del servidor. NO resuelve la operación incierta: solo una respuesta del
-- servidor a su mismo requestId (Reintentar) dice si se aplicó.
function Editor.refreshState(): boolean
	if st.busy then
		return false
	end
	local r = App.request("sync")
	Editor.sync()
	changed()
	return r.ok == true
end

-- Confirmar remodelación de la habitación elegida (cobra en el servidor el total recalculado).
function Editor.confirmRemodel(requestId: string?): any
	if st.active and st.pending then
		return Editor.retry() -- primero se resuelve la operación que quedó sin respuesta
	end
	local o = Editor.office()
	if not st.active or st.busy or not o or not st.room then
		return nil
	end
	local changes = Editor.changes(st.room)
	if next(changes) == nil then
		st.message = "No hay cambios para confirmar en esta habitación."
		changed()
		return { ok = false, msg = st.message }
	end
	local cost, why = Editor.quote(st.room)
	if not cost then
		st.message = tostring(why)
		changed()
		return { ok = false, msg = st.message }
	end
	if App.g.money < cost then
		st.message = "Fondos insuficientes: la remodelación cuesta " .. Util.money(cost) .. "."
		changed()
		return { ok = false, msg = st.message }
	end
	local room = st.room
	local r = send("officeRemodel", { room = room, changes = changes, rev = o.rev or 0, quote = cost }, requestId)
	if r.ok or r.duplicate then
		st.drafts[room] = nil
	end
	Editor.sync()
	return r
end

-- Confirma la vista previa en la posición actual. Devuelve la respuesta del servidor (o nil si no se envió).
function Editor.confirm(requestId: string?): any
	if st.active and st.pending then
		return Editor.retry() -- primero se resuelve la operación que quedó sin respuesta
	end
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
	if st.pending then
		return Editor.retry()
	end
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
	if st.pending then
		return Editor.retry()
	end
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
		if st.section == "remodelacion" then
			local room = Editor.pointerRoom()
			if room then
				Editor.setRoom(room)
			end
		elseif st.mode == "idle" then
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
	if st.section == "remodelacion" then
		return false -- en Remodelación los atajos de muebles no hacen nada
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
