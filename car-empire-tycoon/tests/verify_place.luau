--[[
	Comprueba que un archivo .rbxl contiene exactamente los scripts de src/ (mismo nombre, tipo y código).
	Uso (desde la carpeta car-empire-tycoon):  lune run tests/verify_place.luau CarEmpireTycoon.rbxl
]]
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local path = process.args[1] or "CarEmpireTycoon.rbxl"
local place = roblox.deserializePlace(fs.readFile(path))

local ROOTS = {
	{ "src/shared", place:GetService("ReplicatedStorage"):FindFirstChild("CarEmpireShared") },
	{ "src/server", place:GetService("ServerScriptService"):FindFirstChild("CarEmpireServer") },
	{ "src/client", place:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts") and place:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("CarEmpireClient") },
}

local ok, bad = 0, 0
for _, r in ROOTS do
	local dir, folder = r[1], r[2]
	if not folder then
		print("✗ falta la carpeta de " .. dir)
		bad += 1
		continue
	end
	local seen = {}
	for _, file in fs.readDir(dir) do
		local name, kind = file:match("^(.-)%.server%.luau$"), "Script"
		if not name then
			name, kind = file:match("^(.-)%.client%.luau$"), "LocalScript"
		end
		if not name then
			name, kind = file:match("^(.-)%.luau$"), "ModuleScript"
		end
		if name then
			seen[name] = true
			local inst = folder:FindFirstChild(name)
			-- Los scripts *.server/*.client con el nombre de la carpeta se convierten en la carpeta misma en Rojo.
			if not inst then
				print("✗ " .. dir .. "/" .. file .. ": no está en el place")
				bad += 1
			elseif inst.ClassName ~= kind then
				print("✗ " .. dir .. "/" .. file .. ": es " .. inst.ClassName .. ", se esperaba " .. kind)
				bad += 1
			elseif (inst :: any).Source ~= fs.readFile(dir .. "/" .. file) then
				print("✗ " .. dir .. "/" .. file .. ": el código del place es distinto")
				bad += 1
			else
				ok += 1
			end
		end
	end
	for _, child in folder:GetChildren() do
		if not seen[child.Name] then
			print("✗ " .. child:GetFullName() .. ": está en el place pero no en " .. dir)
			bad += 1
		end
	end
end
print(string.format("%d scripts coinciden, %d diferencias", ok, bad))
process.exit(bad == 0 and 0 or 1)
