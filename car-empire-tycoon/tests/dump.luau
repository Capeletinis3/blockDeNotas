--[[
	Vuelca el árbol de instancias del entorno simulado (tests/mock.luau) a una tabla serializable en JSON,
	para que tools/preview lo dibuje con una emulación del diseño de Roblox y se pueda comparar con la V3.
]]
local M = require("./mock")

local Dump = {}

local SKIP = { Parent = true, Archivable = true, AbsoluteSize = true, AbsolutePosition = true, AbsoluteCanvasSize = true, AbsoluteWindowSize = true, OnServerInvoke = true }

local function value(v: any): any
	local t = M.typeof(v)
	if t == "Color3" then
		return { _t = "c", h = "#" .. v:ToHex() }
	elseif t == "UDim2" then
		return { _t = "u2", v = { v._X._Scale, v._X._Offset, v._Y._Scale, v._Y._Offset } }
	elseif t == "UDim" then
		return { _t = "u", v = { v._Scale, v._Offset } }
	elseif t == "Vector2" then
		return { _t = "v2", v = { v._X, v._Y } }
	elseif t == "Vector3" then
		return { _t = "v3", v = { v._X, v._Y, v._Z } }
	elseif t == "CFrame" then
		return { _t = "cf", v = { v:GetComponents() } }
	elseif t == "EnumItem" then
		return { _t = "e", v = v.Name }
	elseif t == "Font" then
		return { _t = "f", family = v.Family, weight = v.Weight and v.Weight.Name or "Regular", style = v.Style and v.Style.Name or "Normal" }
	elseif t == "ColorSequence" or t == "NumberSequence" then
		local keys = {}
		local a = v.args[1]
		if type(a) == "table" and a[1] ~= nil then
			for _, k in a do
				local kv = k.args
				table.insert(keys, { kv[1], value(kv[2]) })
			end
		else
			-- Forma corta: ColorSequence.new(c) o NumberSequence.new(n) / (n0, n1)
			table.insert(keys, { 0, value(a) })
			table.insert(keys, { 1, value(v.args[2] ~= nil and v.args[2] or a) })
		end
		return { _t = t == "ColorSequence" and "cs" or "ns", k = keys }
	elseif t == "Instance" then
		return { _t = "i", n = v.Name }
	elseif type(v) == "number" or type(v) == "string" or type(v) == "boolean" then
		return v
	end
	return nil
end

function Dump.tree(inst: any): any
	local props = {}
	for k, v in rawget(inst, "__props") do
		if not SKIP[k] and type(k) == "string" and string.sub(k, 1, 2) ~= "__" and type(v) ~= "function" then
			local sv = value(v)
			if sv ~= nil then
				props[k] = sv
			end
		end
	end
	local pivot = rawget(inst, "__props").__pivot
	if pivot then
		props.__pivot = value(pivot)
	end
	local attrs = {}
	for k, v in rawget(inst, "__attrs") do
		local sv = value(v)
		if sv ~= nil then
			attrs[k] = sv
		end
	end
	local kids = {}
	for _, c in rawget(inst, "__children") do
		table.insert(kids, Dump.tree(c))
	end
	return { c = inst.ClassName, p = props, a = attrs, k = kids }
end

return Dump
