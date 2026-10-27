--[[
	Carga un modelo real de Roblox (.rbxm, por ejemplo assets/vehicles/Pioneer70_World.rbxm) con
	@lune/roblox y lo copia en instancias del entorno simulado (tests/mock.luau): misma jerarquía,
	nombres, clases, tamaños, posiciones, colores, materiales, transparencias, atributos y scripts.
	Así las pruebas usan las 37 piezas reales del Pioneer 70 y no un modelo inventado.
]]
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local Loader = {}

local PROPS = { "Anchored", "CanCollide", "CanTouch", "CanQuery", "Transparency", "Reflectance", "CastShadow" }

local function convert(M: any, src: any): any
	local inst = M.Instance.new(src.ClassName)
	inst.Name = src.Name
	if src:IsA("BasePart") then
		local cf = src.CFrame
		inst.CFrame = M.CFrame.new(cf:GetComponents())
		inst.PivotOffset = M.CFrame.new(src.PivotOffset:GetComponents())
		inst.Size = M.Vector3.new(src.Size.X, src.Size.Y, src.Size.Z)
		inst.Color = M.Color3.new(src.Color.R, src.Color.G, src.Color.B)
		inst.Material = M.Enum.Material[src.Material.Name]
		for _, k in PROPS do
			local ok, v = pcall(function()
				return src[k]
			end)
			if ok then
				inst[k] = v
			end
		end
	elseif src:IsA("LuaSourceContainer") then
		local ok, source = pcall(function()
			return src.Source
		end)
		inst.Source = ok and source or ""
	end
	for k, v in src:GetAttributes() do
		if type(v) ~= "userdata" then
			inst:SetAttribute(k, v)
		end
	end
	for _, c in src:GetChildren() do
		convert(M, c).Parent = inst
	end
	return inst
end

-- Devuelve el primer Model del archivo convertido al entorno simulado.
function Loader.load(M: any, path: string): any
	local roots = roblox.deserializeModel(fs.readFile(path))
	return convert(M, roots[1])
end

return Loader
