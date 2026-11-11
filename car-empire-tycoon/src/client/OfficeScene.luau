--!strict
--[[ Escena 3D del editor de oficinas (solo en este cliente: nadie más la ve y no toca el mapa).
	- Se arma lejos del garaje y del showroom (ORIGIN) con Parts provisionales: por cada habitación del plano
	  del nivel de oficinas (OfficeCatalog.PLANS) un piso con su cuadrícula de casillas de CELL studs, los
	  accesos obligatorios marcados y paredes bajas semitransparentes. Sin techo.
	- Las habitaciones van una al lado de la otra sobre X; la casilla (x, y) de una habitación queda en
	  X = esquina + x·CELL y Z = esquina + y·CELL (y de la habitación → Z del mundo).
	- Los muebles se sincronizan con g.office.placed por diferencias (solo se rearma lo que cambió).
	- La vista previa y la selección usan Highlight (verde = válida, rojo = inválida, azul = elegida). ]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local OfficeCatalog = require(Shared.OfficeCatalog)
local Office = require(Shared.Office)

local OfficeModels = require(script.Parent.OfficeModels)

local Scene = {}

local CELL = OfficeCatalog.CELL
Scene.ORIGIN = Vector3.new(0, 1500, 3000) -- lejos del garaje (y ≈ 0) y del showroom (0, 1200, −3000)
Scene.GAP = 3 -- casillas entre habitaciones
Scene.WALL_H = 6
Scene.WALL_ALPHA = 0.45 -- paredes normales
Scene.WALL_FADED = 0.88 -- paredes entre la cámara y la habitación

local VALID, INVALID, SELECTED = Color3.fromHex("#42E58D"), Color3.fromHex("#FF5A64"), Color3.fromHex("#3B8BFF")

local state = {
	folder = nil :: Folder?,
	level = 0,
	sig = "",
	rooms = {} :: { [string]: any }, -- id → { room, ox, oz }
	order = {} :: { string },
	walls = {} :: { any }, -- { part, normal }
	furniture = {} :: { [string]: { model: Model, sig: string } },
	preview = nil :: Model?,
	previewSig = "",
	highlight = nil :: Highlight?,
	selectHl = nil :: Highlight?,
	fade = nil :: number?,
	lastYaw = nil :: number?,
	roomParts = {} :: { [string]: any }, -- por habitación: piso, líneas, paredes, revestimiento, luminarias
	grid = "normal",
	roomBox = nil :: SelectionBox?,
	highlighted = nil :: string?,
}

local function part(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props then
		for k, v in props do
			(p :: any)[k] = v
		end
	end
	p.Parent = parent
	return p
end

-- Disposición de las habitaciones de un nivel: { [id] = { room, ox, oz } } y orden.
function Scene.layout(level: number): ({ [string]: any }, { string })
	local out, order = {}, {}
	local x = 0
	for _, r in OfficeCatalog.plan(level).rooms do
		out[r.id] = { room = r, ox = Scene.ORIGIN.X + x * CELL, oz = Scene.ORIGIN.Z }
		table.insert(order, r.id)
		x += r.w + Scene.GAP
	end
	return out, order
end

-- Punto del piso de una habitación (x, y en casillas) en el mundo.
function Scene.roomToWorld(roomId: string, x: number, y: number): Vector3?
	local L = state.rooms[roomId]
	if not L then
		return nil
	end
	return Vector3.new(L.ox + x * CELL, Scene.ORIGIN.Y, L.oz + y * CELL)
end

-- Habitación y coordenadas (casillas, continuas) de un punto del mundo sobre el piso, o nil.
function Scene.worldToRoom(p: Vector3): (string?, number?, number?)
	for _, id in state.order do
		local L = state.rooms[id]
		local x, y = (p.X - L.ox) / CELL, (p.Z - L.oz) / CELL
		if x >= 0 and y >= 0 and x <= L.room.w and y <= L.room.d then
			return id, x, y
		end
	end
	return nil, nil, nil
end

-- Centro y tamaño (studs) de una habitación, para encuadrar la cámara.
function Scene.roomBounds(roomId: string): (Vector3?, number)
	local L = state.rooms[roomId]
	if not L then
		return nil, 0
	end
	local r = L.room
	return Vector3.new(L.ox + r.w * CELL / 2, Scene.ORIGIN.Y, L.oz + r.d * CELL / 2), math.max(r.w, r.d) * CELL
end

-- Centro y tamaño de toda la oficina.
function Scene.bounds(): (Vector3, number)
	local lx, lz, hx, hz = math.huge, math.huge, -math.huge, -math.huge
	for _, id in state.order do
		local L = state.rooms[id]
		lx, lz = math.min(lx, L.ox), math.min(lz, L.oz)
		hx, hz = math.max(hx, L.ox + L.room.w * CELL), math.max(hz, L.oz + L.room.d * CELL)
	end
	if lx == math.huge then
		return Scene.ORIGIN, 40
	end
	return Vector3.new((lx + hx) / 2, Scene.ORIGIN.Y, (lz + hz) / 2), math.max(hx - lx, hz - lz)
end

-- Rotación del mueble en el mundo: el giro de la habitación (de x hacia y) es un giro de −rot sobre Y.
function Scene.furnitureCFrame(roomId: string, x: number, y: number, rot: number): CFrame?
	local p = Scene.roomToWorld(roomId, x, y)
	if not p then
		return nil
	end
	return CFrame.new(p) * CFrame.Angles(0, -math.rad(rot), 0)
end

-- Tramos de pared de un borde, cortados donde hay accesos pegados a ese borde (puertas).
local function wallRuns(length: number, openAt: { [number]: boolean }): { { number } }
	local runs = {}
	local start = nil
	for i = 0, length do
		local open = i == length or openAt[i]
		if not open and start == nil then
			start = i
		elseif open and start ~= nil then
			table.insert(runs, { start, i })
			start = nil
		end
	end
	return runs
end

local function material(name: any): Enum.Material
	local ok, m = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return (ok and m) or Enum.Material.SmoothPlastic
end

-- MaterialVariant definitivo (si existe en MaterialService con ese nombre); si no, el material provisional.
local function applySurface(p: BasePart, f: any, fallbackColor: string)
	p.Material = material(f and f.material)
	p.Color = Color3.fromHex((f and f.color) or fallbackColor)
	if f and f.variant then
		pcall(function()
			local ms = game:GetService("MaterialService")
			if ms:FindFirstChild(f.variant) then
				(p :: any).MaterialVariant = f.variant
			end
		end)
	end
end

local GRID_ALPHA = { normal = 0.55, tenue = 0.85, oculta = 1 }

-- Geometría fija de una habitación (piso, cuadrícula, accesos, paredes y rótulo). Los acabados se aplican
-- aparte (Scene.applyLook), sin rearmar nada de esto.
local function buildRoom(folder: Folder, id: string, L: any)
	local r = L.room
	local model = Instance.new("Model")
	model.Name = "Habitacion_" .. id
	model.Parent = folder
	local W, D = r.w * CELL, r.d * CELL
	local y0 = Scene.ORIGIN.Y
	local center = Vector3.new(L.ox + W / 2, y0, L.oz + D / 2)
	local rec = { model = model, floor = nil :: any, lines = {}, walls = {}, cover = {}, lights = nil :: any, look = "", room = r, L = L }
	rec.floor = part(model, "Piso", Vector3.new(W, 0.4, D), CFrame.new(center - Vector3.new(0, 0.2, 0)), Color3.fromHex("#8E8C88"), { Material = Enum.Material.Concrete })
	-- Cuadrícula de casillas.
	local lineColor = Color3.fromHex("#DDE6F5")
	local alpha = GRID_ALPHA[state.grid] or GRID_ALPHA.normal
	for i = 0, r.w do
		table.insert(rec.lines, part(model, "Linea", Vector3.new(0.06, 0.02, D), CFrame.new(L.ox + i * CELL, y0 + 0.01, L.oz + D / 2), lineColor, { Transparency = alpha, CastShadow = false }))
	end
	for j = 0, r.d do
		table.insert(rec.lines, part(model, "Linea", Vector3.new(W, 0.02, 0.06), CFrame.new(L.ox + W / 2, y0 + 0.01, L.oz + j * CELL), lineColor, { Transparency = alpha, CastShadow = false }))
	end
	-- Accesos obligatorios (puertas y paso): siempre libres.
	local openLeft, openRight, openFront, openBack = {}, {}, {}, {}
	for _, a in r.access do
		local p = part(model, "Acceso", Vector3.new(CELL - 0.1, 0.04, CELL - 0.1), CFrame.new(L.ox + (a[1] + 0.5) * CELL, y0 + 0.03, L.oz + (a[2] + 0.5) * CELL), Color3.fromHex("#3B8BFF"), { Transparency = 0.45, CastShadow = false, Material = Enum.Material.Neon })
		p:SetAttribute("acceso", true)
		if a[1] == 0 then
			openLeft[a[2]] = true
		end
		if a[1] == r.w - 1 then
			openRight[a[2]] = true
		end
		if a[2] == 0 then
			openFront[a[1]] = true
		end
		if a[2] == r.d - 1 then
			openBack[a[1]] = true
		end
	end
	-- Paredes bajas (sin techo), con una abertura donde hay un acceso pegado al borde. Cada tramo guarda su
	-- cara interior para apoyar el revestimiento sin superponer superficies.
	local H, T = Scene.WALL_H, 0.3
	local function wall(size: Vector3, pos: Vector3, normal: Vector3, len: number)
		local p = part(model, "Pared", size, CFrame.new(pos), Color3.fromHex("#E8E6E1"), { Transparency = Scene.WALL_ALPHA, CastShadow = false })
		local w = { part = p, normal = normal, len = len, inner = pos - normal * (T / 2), cover = nil :: any }
		table.insert(state.walls, w)
		table.insert(rec.walls, w)
	end
	for _, run in wallRuns(r.d, openLeft) do
		local len = (run[2] - run[1]) * CELL
		wall(Vector3.new(T, H, len), Vector3.new(L.ox - T / 2, y0 + H / 2, L.oz + run[1] * CELL + len / 2), Vector3.new(-1, 0, 0), len)
	end
	for _, run in wallRuns(r.d, openRight) do
		local len = (run[2] - run[1]) * CELL
		wall(Vector3.new(T, H, len), Vector3.new(L.ox + W + T / 2, y0 + H / 2, L.oz + run[1] * CELL + len / 2), Vector3.new(1, 0, 0), len)
	end
	for _, run in wallRuns(r.w, openFront) do
		local len = (run[2] - run[1]) * CELL
		wall(Vector3.new(len, H, T), Vector3.new(L.ox + run[1] * CELL + len / 2, y0 + H / 2, L.oz - T / 2), Vector3.new(0, 0, -1), len)
	end
	for _, run in wallRuns(r.w, openBack) do
		local len = (run[2] - run[1]) * CELL
		wall(Vector3.new(len, H, T), Vector3.new(L.ox + run[1] * CELL + len / 2, y0 + H / 2, L.oz + D + T / 2), Vector3.new(0, 0, 1), len)
	end
	-- Nombre de la habitación.
	local anchor = part(model, "Rotulo", Vector3.new(0.2, 0.2, 0.2), CFrame.new(center + Vector3.new(0, H + 1.5, 0)), Color3.new(0, 0, 0), { Transparency = 1, CastShadow = false })
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(220, 32)
	bb.LightInfluence = 0
	bb.MaxDistance = 400
	bb.Parent = anchor
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = r.name .. " · " .. r.w .. "×" .. r.d
	t.TextColor3 = Color3.fromHex("#F5F7FA")
	t.TextStrokeTransparency = 0.4
	t.TextSize = 16
	t.Font = Enum.Font.GothamBold
	t.Parent = bb
	state.roomParts[id] = rec
end

Scene.MAX_LIGHTS = 4 -- luces locales por habitación (las demás luminarias son solo visuales)
Scene.COVER_ALPHA = 0.1

-- Posiciones de n luminarias repartidas en la habitación (centros de una grilla regular).
local function fixtureSpots(r: any, n: number): { { number } }
	local cols = math.max(1, math.min(n, math.ceil(math.sqrt(n * r.w / r.d))))
	local rows = math.ceil(n / cols)
	local out = {}
	for i = 0, n - 1 do
		local cx, cy = i % cols, i // cols
		table.insert(out, { (cx + 0.5) * r.w / cols, (cy + 0.5) * r.d / rows })
	end
	return out
end

--[[ Aplica los acabados visibles de una habitación (instalados o en vista previa). Solo cambia lo que difiere
	del aspecto actual de esa habitación: piso (material y color), pintura, revestimiento (bandas apoyadas en
	la cara interior de cada pared) y luminarias con sus luces locales. No toca los muebles ni otras
	habitaciones. ]]
function Scene.applyLook(roomId: string, finish: any)
	local rec = state.roomParts[roomId]
	if not rec or type(finish) ~= "table" then
		return
	end
	local fl = OfficeCatalog.finish("floor", finish.floor)
	local wl = OfficeCatalog.finish("wall", finish.wall)
	local cv = OfficeCatalog.finish("covering", finish.covering)
	local lt = OfficeCatalog.finish("lighting", finish.lighting)
	local sig = table.concat({ tostring(finish.floor), tostring(finish.wall), tostring(finish.covering), tostring(finish.lighting) }, "|")
	if rec.look == sig then
		return
	end
	local old = string.split(rec.look, "|")
	rec.look = sig
	if old[1] ~= tostring(finish.floor) then
		applySurface(rec.floor, fl, "#8E8C88")
	end
	if old[2] ~= tostring(finish.wall) then
		for _, w in rec.walls do
			local tr = w.part.Transparency
			applySurface(w.part, wl, "#E8E6E1")
			w.part.Transparency = tr
		end
	end
	if old[3] ~= tostring(finish.covering) then
		for _, w in rec.walls do
			if w.cover then
				w.cover:Destroy()
				w.cover = nil
			end
		end
		if cv and cv.material ~= "" and cv.height then
			local t = 0.12
			for _, w in rec.walls do
				local n = w.normal
				local along = math.abs(n.X) > 0.5 and Vector3.new(t, cv.height, w.len) or Vector3.new(w.len, cv.height, t)
				local pos = Vector3.new(w.inner.X, Scene.ORIGIN.Y + cv.height / 2, w.inner.Z) - n * (t / 2 + 0.01)
				local c = part(rec.model, "Revestimiento", along, CFrame.new(pos), Color3.new(1, 1, 1), { CastShadow = false })
				applySurface(c, cv, "#7A4E2D")
				w.cover = c
			end
		end
		state.fade = nil
		Scene.fadeWalls(state.lastYaw or 45)
	end
	if old[4] ~= tostring(finish.lighting) then
		if rec.lights then
			rec.lights:Destroy()
			rec.lights = nil
		end
		if lt then
			local holder = Instance.new("Model")
			holder.Name = "Luminarias"
			holder.Parent = rec.model
			rec.lights = holder
			local r, L = rec.room, rec.L
			local n = Office.finishQuantity(r, lt)
			local spots = fixtureSpots(r, n)
			local step = math.max(1, math.ceil(n / Scene.MAX_LIGHTS))
			local y = Scene.ORIGIN.Y + Scene.WALL_H - 0.3
			for i, sp in spots do
				local pos = Vector3.new(L.ox + sp[1] * CELL, y, L.oz + sp[2] * CELL)
				local fx
				if lt.fixture == "plafon" then
					fx = part(holder, "Plafon", Vector3.new(0.18, 1.3, 1.3), CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromHex(lt.color or "#FFD7A0"), { Shape = Enum.PartType.Cylinder, Material = Enum.Material.Neon, CastShadow = false })
				else
					fx = part(holder, "Tubo", Vector3.new(1.8, 0.14, 0.35), CFrame.new(pos), Color3.fromHex(lt.color or "#EAF2FF"), { Material = Enum.Material.Neon, CastShadow = false })
				end
				if (i - 1) % step == 0 and lt.light then
					local pl = Instance.new("PointLight")
					pl.Color = Color3.fromHex(lt.light.color)
					pl.Brightness = lt.light.brightness
					-- Alcance suficiente para que pocas luces cubran la habitación.
					pl.Range = math.min(60, math.max(lt.light.range, math.sqrt(r.w * r.d / math.min(n, Scene.MAX_LIGHTS)) * CELL))
					pl.Shadows = false
					pl.Parent = fx
				end
			end
		end
	end
end

-- Aspecto aplicado ahora a una habitación (ids de acabado), para verificar.
function Scene.lookOf(roomId: string): string?
	local rec = state.roomParts[roomId]
	return rec and rec.look or nil
end

function Scene.roomParts(roomId: string): any
	return state.roomParts[roomId]
end

-- Cuadrícula: "normal" (colocar muebles), "tenue" (remodelación) u "oculta".
function Scene.setGrid(mode: string)
	if state.grid == mode then
		return
	end
	state.grid = mode
	local alpha = GRID_ALPHA[mode] or GRID_ALPHA.normal
	for _, rec in state.roomParts do
		for _, l in rec.lines do
			l.Transparency = alpha
		end
	end
end

-- Resalta una habitación (borde azul alrededor del piso). nil = ninguna.
function Scene.highlightRoom(roomId: string?)
	local rec = roomId and state.roomParts[roomId]
	if not rec then
		if state.roomBox then
			state.roomBox.Adornee = nil
		end
		state.highlighted = nil
		return
	end
	local box = state.roomBox
	if not box then
		local b = Instance.new("SelectionBox")
		b.Name = "HabitacionElegida"
		b.Color3 = Color3.fromHex("#3B8BFF")
		b.LineThickness = 0.18
		b.SurfaceTransparency = 0.85
		b.SurfaceColor3 = Color3.fromHex("#3B8BFF")
		state.roomBox = b
		box = b
	end
	box.Parent = state.folder
	box.Adornee = rec.floor
	state.highlighted = roomId
end

-- (Re)arma la geometría de las habitaciones solo si cambió el nivel; los acabados se aplican con applyLook.
function Scene.buildRooms(office: any)
	if not state.folder then
		local f = Instance.new("Folder")
		f.Name = "EditorOficina"
		state.folder = f
	end
	local folder = state.folder :: Folder
	local level = office.level or 1
	if level ~= state.level then
		state.rooms, state.order = Scene.layout(level)
		state.level = level
		local old = folder:FindFirstChild("Habitaciones")
		if old then
			old:Destroy()
		end
		table.clear(state.walls)
		table.clear(state.roomParts)
		state.fade = nil
		state.highlighted = nil
		if state.roomBox then
			state.roomBox.Adornee = nil
		end
		local holder = Instance.new("Folder")
		holder.Name = "Habitaciones"
		holder.Parent = folder
		for _, id in state.order do
			buildRoom(holder, id, state.rooms[id])
		end
		-- Luz de relleno tenue, para que la oficina se vea a cualquier hora (las de cada habitación marcan el
		-- ambiente).
		local c = Scene.bounds()
		local lamp = part(holder, "LuzGeneral", Vector3.new(0.2, 0.2, 0.2), CFrame.new(c + Vector3.new(0, 30, 0)), Color3.new(0, 0, 0), { Transparency = 1, CastShadow = false })
		local light = Instance.new("PointLight")
		light.Range = 60
		light.Brightness = 0.5
		light.Shadows = false
		light.Parent = lamp
	end
	-- Acabados instalados (el editor aplica encima los de la vista previa).
	for _, id in state.order do
		Scene.applyLook(id, (office.finishes and office.finishes[id]) or OfficeCatalog.DEFAULT_FINISH)
	end
end

-- Incluye el nivel: al ampliar, las habitaciones cambian de lugar y los muebles se reubican.
local function placeSig(p: any): string
	return state.level .. "|" .. p.item .. "|" .. p.room .. "|" .. p.x .. "|" .. p.y .. "|" .. p.rot
end

-- Muebles colocados: crea, mueve o quita solo lo que cambió.
function Scene.syncFurniture(office: any)
	local folder = state.folder
	if not folder then
		return
	end
	local holder = folder:FindFirstChild("Muebles") :: Folder?
	if not holder then
		local f = Instance.new("Folder")
		f.Name = "Muebles"
		f.Parent = folder
		holder = f
	end
	local seen = {}
	for _, p in office.placed or {} do
		seen[p.id] = true
		local item = OfficeCatalog.item(p.item)
		local cf = item and Scene.furnitureCFrame(p.room, p.x, p.y, p.rot)
		local cur = state.furniture[p.id]
		local sig = placeSig(p)
		if item and cf then
			if not cur or cur.model.Name ~= p.item then
				if cur then
					cur.model:Destroy()
				end
				local m = OfficeModels.build(item)
				m:SetAttribute("instance", p.id)
				m:PivotTo(cf)
				m.Parent = holder
				state.furniture[p.id] = { model = m, sig = sig }
			elseif cur.sig ~= sig then
				cur.model:PivotTo(cf)
				cur.sig = sig
			end
		elseif cur then
			cur.model:Destroy()
			state.furniture[p.id] = nil
		end
	end
	for id, cur in state.furniture do
		if not seen[id] then
			cur.model:Destroy()
			state.furniture[id] = nil
		end
	end
end

function Scene.furnitureModel(instanceId: string): Model?
	local cur = state.furniture[instanceId]
	return cur and cur.model or nil
end

-- Vista previa: modelo semitransparente con borde verde (válida) o rojo (inválida). nil la oculta.
function Scene.preview(itemId: string?, roomId: string?, x: number?, y: number?, rot: number?, valid: boolean?)
	local folder = state.folder
	if not folder or not itemId or not roomId or not x or not y or not rot then
		if state.preview then
			state.preview:Destroy()
			state.preview = nil
			state.previewSig = ""
		end
		return
	end
	local item = OfficeCatalog.item(itemId)
	if not item then
		return
	end
	if not state.preview or state.previewSig ~= itemId then
		if state.preview then
			state.preview:Destroy()
		end
		local m = OfficeModels.build(item)
		m.Name = "VistaPrevia"
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") and d.Transparency < 1 then
				d.Transparency = 0.35
				d.CastShadow = false
			end
		end
		m.Parent = folder
		state.preview = m
		state.previewSig = itemId
		local hl = state.highlight or Instance.new("Highlight")
		hl.Name = "ResaltadoVistaPrevia"
		hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		hl.FillTransparency = 0.55
		hl.OutlineTransparency = 0
		hl.Parent = folder
		state.highlight = hl
		hl.Adornee = m
	end
	local cf = Scene.furnitureCFrame(roomId, x, y, rot)
	if cf and state.preview then
		state.preview:PivotTo(cf)
	end
	local hl = state.highlight
	if hl then
		hl.FillColor = valid and VALID or INVALID
		hl.OutlineColor = valid and VALID or INVALID
	end
end

-- Resalta el mueble elegido (nil = ninguno).
function Scene.select(instanceId: string?)
	local folder = state.folder
	local m = instanceId and Scene.furnitureModel(instanceId) or nil
	if not folder or not m then
		if state.selectHl then
			state.selectHl.Adornee = nil
		end
		return
	end
	local hl = state.selectHl or Instance.new("Highlight")
	hl.Name = "ResaltadoSeleccion"
	hl.FillColor = SELECTED
	hl.OutlineColor = SELECTED
	hl.FillTransparency = 0.7
	hl.Parent = folder
	hl.Adornee = m
	state.selectHl = hl
end

--[[ Paredes que tapan la vista: las que miran hacia la cámara se vuelven casi transparentes. yaw = ángulo de
	la cámara en grados (la cámara está en dirección (sin yaw, cos yaw) desde el centro). Solo recalcula si el
	ángulo cambió de verdad. ]]
function Scene.fadeWalls(yaw: number)
	state.lastYaw = yaw
	local key = math.floor(yaw / 5 + 0.5)
	if state.fade == key then
		return
	end
	state.fade = key
	local a = math.rad(yaw)
	local toCam = Vector3.new(math.sin(a), 0, math.cos(a))
	for _, w in state.walls do
		local facing = w.normal:Dot(toCam) > 0.25
		w.part.Transparency = facing and Scene.WALL_FADED or Scene.WALL_ALPHA
		if w.cover then
			-- El revestimiento acompaña a su pared: no tapa la vista cuando la pared se aclara.
			w.cover.Transparency = facing and Scene.WALL_FADED or Scene.COVER_ALPHA
		end
	end
end

function Scene.wallParts(): { any }
	return state.walls
end

function Scene.show(on: boolean)
	if state.folder then
		state.folder.Parent = on and Workspace or nil
	end
end

function Scene.isBuilt(): boolean
	return state.folder ~= nil
end

-- Libera todo (al salir del editor): no queda nada en el Workspace ni en memoria.
function Scene.destroy()
	if state.folder then
		state.folder:Destroy()
	end
	state.folder = nil
	state.level, state.sig = 0, ""
	table.clear(state.rooms)
	table.clear(state.order)
	table.clear(state.walls)
	table.clear(state.furniture)
	table.clear(state.roomParts)
	state.preview, state.previewSig, state.highlight, state.selectHl, state.fade = nil, "", nil, nil, nil
	state.roomBox, state.highlighted, state.grid, state.lastYaw = nil, nil, "normal", nil
end

Scene._state = state

return Scene
