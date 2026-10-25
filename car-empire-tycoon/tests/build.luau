--[[
	Copia los módulos de src/ a una carpeta de pruebas reescribiendo los require de Roblox
	(script.Parent.X, Shared.X) a rutas de archivo. Con mock = true además inyecta al principio
	de cada archivo los dobles de Roblox de tests/mock.luau (game, Instance, Enum, Color3…).
]]
local fs = require("@lune/fs")

local Build = {}

local SERVER_PURE = { "GameState", "Simulation", "Actions", "Market", "DataService", "Sessions" }

local MOCK_HEADER = 'local __M = require("../../mock")\n'
	.. "local game, workspace, Instance, Enum, Color3, UDim, UDim2, Vector2, Vector3, CFrame, Font, Random, NumberSequence, NumberSequenceKeypoint, ColorSequence, ColorSequenceKeypoint, NumberRange, TweenInfo, typeof, warn, Rect, PhysicalProperties = "
	.. "__M.game, __M.workspace, __M.Instance, __M.Enum, __M.Color3, __M.UDim, __M.UDim2, __M.Vector2, __M.Vector3, __M.CFrame, __M.Font, __M.Random, __M.NumberSequence, __M.NumberSequenceKeypoint, __M.ColorSequence, __M.ColorSequenceKeypoint, __M.NumberRange, __M.TweenInfo, __M.typeof, __M.warn, __M.Rect, __M.PhysicalProperties\n"
	.. "local task = __M.task\n"

local function rewrite(src: string, mock: boolean): string
	if not mock then
		src = src:gsub('local ReplicatedStorage = game:GetService%("ReplicatedStorage"%)\n', "")
		src = src:gsub('local Shared = ReplicatedStorage:WaitForChild%("CarEmpireShared"%)\n', "")
	end
	src = src:gsub("require%(Shared%.(%w+)%)", 'require("../shared/%1")')
	src = src:gsub("require%(script%.Parent%.(%w+)%)", 'require("./%1")')
	-- --!strict se conserva al principio; el encabezado va después.
	if mock then
		local first, rest = src:match("^(%-%-!%w+\n)(.*)$")
		if first then
			src = first .. MOCK_HEADER .. rest
		else
			src = MOCK_HEADER .. src
		end
	end
	return src
end

function Build.prepare(opts: any?)
	local mock = opts and opts.mock or false
	local out = mock and "tests/.build-ui" or "tests/.build"
	if fs.isDir(out) then
		fs.removeDir(out)
	end
	fs.writeDir(out .. "/shared")
	fs.writeDir(out .. "/server")
	fs.writeDir(out .. "/client")
	for _, dir in { "shared", "server", "client" } do
		for _, name in fs.readDir("src/" .. dir) do
			local base = name:gsub("%.server%.luau$", ""):gsub("%.client%.luau$", ""):gsub("%.luau$", "")
			local include = mock or dir == "shared" or (dir == "server" and table.find(SERVER_PURE, base) ~= nil)
			if include and name:match("%.luau$") then
				local src = rewrite(fs.readFile("src/" .. dir .. "/" .. name), mock)
				if not mock and dir ~= "client" then
					assert(not src:find("game:GetService"), name .. " usa servicios de Roblox y no es puro")
				end
				fs.writeFile(out .. "/" .. dir .. "/" .. base .. ".luau", src)
			end
		end
	end
	Build.out = out
end

function Build.clean()
	if Build.out and fs.isDir(Build.out) then
		fs.removeDir(Build.out)
	end
end

return Build
