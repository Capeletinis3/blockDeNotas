--!strict
--[[ Cámara del editor de oficinas: isométrica elevada que orbita alrededor de un foco.
	- Solo mueve Workspace.CurrentCamera cuando App.cameraOwner == "office" (lo decide App.render): mientras el
	  editor está abierto ni la cámara de gestión (SceneCamera) ni el showroom la tocan, y al salir la toman de
	  vuelta ellos.
	- Clic derecho + arrastrar: girar. Q / E: girar 45°. Rueda: zoom suave con límites. Clic de la rueda +
	  arrastrar, o W A S D / flechas: desplazar. El clic izquierdo queda libre para colocar y elegir muebles.
	- El estado se puede mover sin mouse (Camera.rotate, zoom, pan, frame): preparado para controles táctiles. ]]

local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local App = require(script.Parent.App)
local Scene = require(script.Parent.OfficeScene)

local Camera = {}

Camera.PITCH = 52 -- grados sobre el horizonte (vista isométrica elevada)
Camera.FOV = 40
Camera.MIN_DIST, Camera.MAX_DIST = 18, 170
Camera.SMOOTH = 9
Camera.PAN_SPEED = 0.9 -- studs por cuadro a la distancia media, con teclado

local view = {
	yaw = 45, tYaw = 45,
	dist = 80, tDist = 80,
	focus = Scene.ORIGIN, tFocus = Scene.ORIGIN,
	rotating = false, panning = false, last = nil :: Vector3?,
}

function Camera.state(): any
	return view
end

function Camera.owns(): boolean
	return App.cameraOwner == "office"
end

function Camera.rotate(deg: number)
	view.tYaw += deg
end

function Camera.zoom(factor: number)
	view.tDist = math.clamp(view.tDist * factor, Camera.MIN_DIST, Camera.MAX_DIST)
end

-- Desplaza el foco en el plano del piso, relativo a hacia dónde mira la cámara.
function Camera.pan(right: number, forward: number)
	local a = math.rad(view.tYaw)
	local fwd = Vector3.new(-math.sin(a), 0, -math.cos(a))
	local rgt = Vector3.new(math.cos(a), 0, -math.sin(a))
	local k = view.tDist / 80
	local c, size = Scene.bounds()
	local nf = view.tFocus + (rgt * right + fwd * forward) * k
	-- Sin perder la oficina de vista: el foco no se aleja más que el tamaño de la oficina.
	local off = nf - c
	local lim = size / 2 + 10
	view.tFocus = Vector3.new(c.X + math.clamp(off.X, -lim, lim), c.Y, c.Z + math.clamp(off.Z, -lim, lim))
end

-- Encuadra una habitación (o toda la oficina si roomId es nil). instant = sin transición (al entrar).
function Camera.frame(roomId: string?, instant: boolean?)
	local c, size
	if roomId then
		c, size = Scene.roomBounds(roomId)
	end
	if not c then
		c, size = Scene.bounds()
	end
	view.tFocus = c :: Vector3
	view.tDist = math.clamp((size :: number) * 1.25 + 12, Camera.MIN_DIST, Camera.MAX_DIST)
	if instant then
		view.focus, view.dist, view.yaw = view.tFocus, view.tDist, view.tYaw
	end
end

local function damp(a: any, b: any, k: number, dt: number): any
	local t = 1 - math.exp(-k * dt)
	return a + (b - a) * t
end

-- Un paso (RenderStepped; las pruebas lo llaman directamente).
function Camera.update(dt: number)
	if not Camera.owns() then
		return
	end
	if not UserInputService:GetFocusedTextBox() then
		local r, f = 0, 0
		local function down(k: Enum.KeyCode): boolean
			local ok, v = pcall(function()
				return UserInputService:IsKeyDown(k)
			end)
			return ok and v == true
		end
		if down(Enum.KeyCode.D) or down(Enum.KeyCode.Right) then
			r += 1
		end
		if down(Enum.KeyCode.A) or down(Enum.KeyCode.Left) then
			r -= 1
		end
		if down(Enum.KeyCode.W) or down(Enum.KeyCode.Up) then
			f += 1
		end
		if down(Enum.KeyCode.S) or down(Enum.KeyCode.Down) then
			f -= 1
		end
		if r ~= 0 or f ~= 0 then
			Camera.pan(r * Camera.PAN_SPEED, f * Camera.PAN_SPEED)
		end
	end
	view.yaw = damp(view.yaw, view.tYaw, Camera.SMOOTH, dt)
	view.dist = damp(view.dist, view.tDist, Camera.SMOOTH, dt)
	view.focus = damp(view.focus, view.tFocus, Camera.SMOOTH, dt)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = Camera.FOV
	local yaw, pitch = math.rad(view.yaw), math.rad(Camera.PITCH)
	local offset = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)) * view.dist
	cam.CFrame = CFrame.lookAt(view.focus + offset, view.focus)
	Scene.fadeWalls(view.yaw)
end

-- Al salir del editor: vuelve el campo de visión normal (la cámara de gestión no lo cambia).
function Camera.release()
	view.rotating, view.panning, view.last = false, false, nil
	local cam = Workspace.CurrentCamera
	if cam then
		cam.FieldOfView = 70
	end
end

local started = false
function Camera.start()
	if started then
		return -- una sola vez: sin conexiones duplicadas al entrar y salir
	end
	started = true
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or not Camera.owns() then
			return
		end
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton2 then
			view.rotating, view.last = true, input.Position
		elseif t == Enum.UserInputType.MouseButton3 then
			view.panning, view.last = true, input.Position
		elseif input.KeyCode == Enum.KeyCode.Q and not UserInputService:GetFocusedTextBox() then
			Camera.rotate(-45)
		elseif input.KeyCode == Enum.KeyCode.E and not UserInputService:GetFocusedTextBox() then
			Camera.rotate(45)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton2 then
			view.rotating = false
		elseif t == Enum.UserInputType.MouseButton3 then
			view.panning = false
		end
		if not view.rotating and not view.panning then
			view.last = nil
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
		if not Camera.owns() then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel and not processed then
			Camera.zoom(input.Position.Z > 0 and 0.87 or 1.15)
		elseif input.UserInputType == Enum.UserInputType.MouseMovement and view.last then
			local d = input.Position - view.last
			view.last = input.Position
			if view.rotating then
				Camera.rotate(-d.X * 0.35)
			elseif view.panning then
				Camera.pan(-d.X * 0.12, d.Y * 0.12)
			end
		end
	end)
	RunService.RenderStepped:Connect(Camera.update)
end

return Camera
