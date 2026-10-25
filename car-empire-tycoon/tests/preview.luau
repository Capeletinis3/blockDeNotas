--[[
	Genera los árboles de interfaz de cada escena para la vista previa (tools/preview).
	Ejecuta el servidor y el cliente reales sobre el entorno simulado, lleva la partida a cada estado
	y vuelca la interfaz a JSON. No dibuja nada: eso lo hace tools/preview/render.js.

	Uso (desde car-empire-tycoon):  lune run tests/preview.luau <carpeta-salida> [ancho] [alto] [filtro]
]]

local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")

local Build = require("./build")
Build.prepare({ mock = true })

local M = require("./mock")
local Dump = require("./dump")

local out = process.args[1] or "tests/.preview"
local W = tonumber(process.args[2]) or 1600
local H = tonumber(process.args[3]) or 900
local filter = process.args[4]
if not fs.isDir(out) then
	fs.writeDir(out)
end

M.services.Workspace.CurrentCamera.ViewportSize = M.Vector2.new(W, H)

local shared = M.Instance.new("Folder")
shared.Name = "CarEmpireShared"
shared.Parent = M.services.ReplicatedStorage

require("./.build-ui/server/Main")
local Sessions = require("./.build-ui/server/Sessions")
Sessions.RATE_MAX = 100000
local player = M.newPlayer(1001, "Ana")
M.addPlayer(player, true)
local App = require("./.build-ui/client/App")
require("./.build-ui/client/Main")
local Scenes = require("./scenes")

local function waitFor(cond: () -> boolean, frames: number?): boolean
	for _ = 1, frames or 300 do
		if cond() then
			return true
		end
		M.task.wait()
	end
	return cond()
end
waitFor(function()
	return App.payload ~= nil and App.payload.status == "ready"
end)

local ctx = { M = M, App = App, waitFor = waitFor, Sessions = Sessions, player = player }
local index = {}
for _, scene in Scenes.list(ctx) do
	if not filter or string.find(scene.name, filter, 1, true) then
		table.clear(M.log)
		local ok, err = pcall(scene.run, ctx)
		M.task.wait()
		M.task.wait()
		if not ok then
			print("✗ " .. scene.name .. ": " .. tostring(err))
		end
		-- Los avisos flotantes no se comparan (la V3 se captura sin ellos).
		for _, d in App.toastLayer:GetDescendants() do
			if d.Name == "Aviso" then
				d:Destroy()
			end
		end
		local tree = Dump.tree(App.gui.Parent)
		fs.writeFile(out .. "/" .. scene.name .. ".json", serde.encode("json", { viewport = { W, H }, scene = scene.name, title = scene.title, tree = tree, errors = M.log }))
		table.insert(index, { name = scene.name, title = scene.title, ok = ok })
		print((ok and "✓ " or "✗ ") .. scene.name .. (#M.log > 0 and ("  (registro: " .. M.log[1] .. ")") or ""))
	end
end
fs.writeFile(out .. "/index.json", serde.encode("json", index))
Build.clean()
process.exit(0)
