--!strict
--[[ Cámara del escenario: no hay personaje caminando (la gestión se hace desde los menús). Mientras hay una
	empresa abierta, la cámara orbita sobre su garaje (Player:GetAttribute("PlotCenter"), lo fija el servidor):
	arrastrar con el mouse o el dedo rota, la rueda o el gesto de pellizcar acercan y alejan. ]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local App = require(script.Parent.App)

local SceneCamera = {}

local view = { yaw = 30, pitch = 28, dist = 70, minDist = 25, maxDist = 160, dragging = false, last = nil :: Vector3? }

function SceneCamera.zoom(factor: number)
	view.dist = math.clamp(view.dist * factor, view.minDist, view.maxDist)
end

function SceneCamera.rotate(dx: number, dy: number)
	view.yaw = (view.yaw - dx * 0.3) % 360
	view.pitch = math.clamp(view.pitch + dy * 0.2, 8, 75)
end

function SceneCamera.state(): any
	return view
end

local function active(): boolean
	return App.g ~= nil and App.ui.route == "juego" and #App.ui.dialogs == 0
end

function SceneCamera.start()
	local player = Players.LocalPlayer
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or not active() then
			return
		end
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.Touch then
			view.dragging = true
			view.last = input.Position
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.MouseButton2 or t == Enum.UserInputType.Touch then
			view.dragging = false
			view.last = nil
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
		if not active() then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel and not processed then
			SceneCamera.zoom(input.Position.Z > 0 and 0.88 or 1.14)
		elseif view.dragging and view.last and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - view.last
			view.last = input.Position
			SceneCamera.rotate(d.X, d.Y)
		end
	end)
	UserInputService.TouchPinch:Connect(function(_, scale: number, _, state: Enum.UserInputState)
		if active() and state == Enum.UserInputState.Change and scale > 0 then
			SceneCamera.zoom(1 / math.clamp(scale, 0.9, 1.1))
		end
	end)
	RunService.RenderStepped:Connect(function()
		local cam = workspace.CurrentCamera
		local center = player:GetAttribute("PlotCenter")
		if not cam or typeof(center) ~= "Vector3" or App.g == nil then
			return
		end
		cam.CameraType = Enum.CameraType.Scriptable
		local yaw, pitch = math.rad(view.yaw), math.rad(view.pitch)
		local offset = Vector3.new(math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)) * view.dist
		cam.CFrame = CFrame.lookAt(center + offset, center)
	end)
end

return SceneCamera
