-- Auditoría estática de arranque (etapa 11): grafo de require, ciclos, módulos faltantes,
-- esperas sin límite y remotos usados por el cliente frente a los que crea el servidor.
-- Uso: lune run tests/audit_static.luau
local fs = require("@lune/fs")

local dirs = { shared = "src/shared", server = "src/server", client = "src/client" }
local mods: { [string]: { dir: string, path: string, src: string } } = {}
local problems = {}

for dir, path in dirs do
	for _, f in fs.readDir(path) do
		if string.sub(f, -5) == ".luau" then
			local base = string.gsub(f, "%.luau$", "")
			local name = string.gsub(base, "%.(%a+)$", "")
			mods[dir .. "/" .. name] = { dir = dir, path = path .. "/" .. f, src = fs.readFile(path .. "/" .. f) }
		end
	end
end

local function stripComments(s: string): string
	s = string.gsub(s, "%-%-%[(=*)%[.-%]%1%]", "")
	s = string.gsub(s, "%-%-[^\n]*", "")
	return s
end

local edges: { [string]: { string } } = {}
local count = 0
for key, m in mods do
	count += 1
	edges[key] = {}
	local code = stripComments(m.src)
	for target in string.gmatch(code, "require%(([^%)]+)%)") do
		local dep: string? = nil
		local sharedName = string.match(target, "^Shared%.(%w+)$")
		local parentName = string.match(target, "^script%.Parent%.(%w+)$")
		if sharedName then
			dep = "shared/" .. sharedName
		elseif parentName then
			dep = m.dir .. "/" .. parentName
		elseif string.match(target, "^@") or string.match(target, "^\"") then
			dep = nil
		elseif key == "client/App" and target == "module :: any" then
			dep = nil -- PlayerModule de Roblox: se busca con FindFirstChild y se carga dentro de pcall
		else
			table.insert(problems, "require dinámico en " .. key .. ": " .. target)
		end
		if dep then
			if not mods[dep] then
				table.insert(problems, "módulo inexistente: " .. key .. " → " .. dep)
			elseif string.find(dep, "^server/") and m.dir ~= "server" then
				table.insert(problems, "el cliente o shared requiere un módulo del servidor: " .. key .. " → " .. dep)
			else
				table.insert(edges[key], dep)
			end
		end
	end
	-- Esperas sin límite: solo se aceptan objetos que existen siempre (Rojo, el servidor o PlayerGui).
	for obj, arg in string.gmatch(code, "([%w_%.]+):WaitForChild%(([^%)]*)%)") do
		if not string.find(arg, ",") then
			local okNames = { ['"CarEmpireShared"'] = true, ['"CarEmpireRemotes"'] = true, ['"PlayerGui"'] = true, ['"State"'] = true, ['"Notice"'] = true, ['"Open"'] = true, ['"Request"'] = true }
			if not okNames[arg] then
				table.insert(problems, "WaitForChild sin límite de tiempo en " .. key .. ": " .. obj .. ":WaitForChild(" .. arg .. ")")
			end
		end
	end
end

-- Ciclos (DFS)
local state: { [string]: number } = {}
local stack = {}
local cycles = {}
local function visit(n: string)
	state[n] = 1
	table.insert(stack, n)
	for _, d in edges[n] do
		if state[d] == 1 then
			local i = table.find(stack, d) :: number
			table.insert(cycles, table.concat(stack, " → ", i) .. " → " .. d)
		elseif not state[d] then
			visit(d)
		end
	end
	table.remove(stack)
	state[n] = 2
end
for n in edges do
	if not state[n] then
		visit(n)
	end
end
for _, c in cycles do
	table.insert(problems, "dependencia circular: " .. c)
end

-- Remotos: los que crea el servidor frente a los que busca el cliente.
local serverMain = mods["server/Main"].src
local created = {}
for name in string.gmatch(serverMain, "%.Name = \"(%w+)\"\n%s*[%w]+%.Parent = remotes") do
	created[name] = true
end
local used = {}
for key, m in mods do
	if m.dir == "client" then
		for name in string.gmatch(m.src, "remotes:WaitForChild%(\"(%w+)\"%)") do
			used[name] = key
		end
		for name in string.gmatch(m.src, "remotes and remotes:FindFirstChild%(\"(%w+)\"%)") do
			used[name] = key
		end
	end
end
local createdList, usedList = {}, {}
for n in created do
	table.insert(createdList, n)
end
for n, k in used do
	table.insert(usedList, n)
	if not created[n] then
		table.insert(problems, "el cliente usa un remoto que el servidor no crea: " .. n .. " (" .. k .. ")")
	end
end
table.sort(createdList)
table.sort(usedList)
-- Orden de arranque: la carpeta de remotos se publica después de crear todos sus hijos.
local folderAt = string.find(serverMain, "remotes.Parent = ReplicatedStorage", 1, true) or 0
local lastChild = 0
for pos in string.gmatch(serverMain, "()%.Parent = remotes\n") do
	lastChild = math.max(lastChild, pos)
end
if folderAt < lastChild then
	table.insert(problems, "la carpeta de remotos se publica antes de crear todos los remotos")
end

local edgesTotal = 0
for _, e in edges do
	edgesTotal += #e
end
print(string.format("módulos: %d · dependencias: %d · ciclos: %d", count, edgesTotal, #cycles))
print("remotos creados por el servidor: " .. table.concat(createdList, ", "))
print("remotos usados por el cliente: " .. table.concat(usedList, ", "))
if #problems == 0 then
	print("auditoría estática: sin problemas")
else
	for _, p in problems do
		print("  ✗ " .. p)
	end
	print(string.format("auditoría estática: %d problemas", #problems))
end
