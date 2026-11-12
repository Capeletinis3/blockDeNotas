--!strict
--[[ Mapa mundial interactivo (cliente, solo visual): continentes, marcadores de los países, zoom, desplazamiento,
	encuadre completo e información al pasar el cursor. No conoce la economía: quien lo usa le pasa el estado
	de cada marcador ("disponible" | "bloqueado" | "abierto") y recibe la selección por `onSelect`.

	Representación provisional y reemplazable:
	  - Proyección equirectangular recortada: longitud −180…180 → x 0…1; latitud LAT_TOP…LAT_BOTTOM → y 0…1.
	  - Continentes: CONTINENTS son rectángulos redondeados en grados (silueta estilizada reconocible). Para usar
	    una textura definitiva, poner su id en WorldMap.TEXTURE (con la misma proyección y recorte): se dibuja
	    una ImageLabel en lugar de los rectángulos y los marcadores siguen en su lugar.
	  - Marcadores en COUNTRY_GEO (latitud y longitud aproximadas del centro del país).

	Vista: { zoom (1…MAX_ZOOM), cx, cy (centro visible, en fracción del lienzo) }. La guarda quien lo usa (por
	ejemplo App.ui.expMap) para que sobreviva a las reconstrucciones de la pantalla; no se guarda en la partida.

	Controles: clic en un marcador (selecciona), rueda del mouse (zoom hacia el cursor), arrastre (desplaza),
	botones + / − / «Ver todo». Táctil: arrastre y los mismos botones. Una sola conexión de entrada global
	(arrastre) que se desconecta al destruir el mapa. ]]

local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Ui = require(script.Parent.Ui)
local T = Ui.T
local W = Ui.W

local WorldMap = {}

WorldMap.TEXTURE = nil :: string? -- id de una textura definitiva del mapa (misma proyección), o nil
WorldMap.LAT_TOP, WorldMap.LAT_BOTTOM = 82, -58
WorldMap.MIN_ZOOM, WorldMap.MAX_ZOOM = 1, 4
WorldMap.ZOOM_STEP = 1.35

WorldMap.COLORS = {
	ocean = Color3.fromHex("#081A33"),
	ocean2 = Color3.fromHex("#0D2A52"),
	land = Color3.fromHex("#1F4B86"),
	landEdge = Color3.fromHex("#3B8BFF"),
	grid = Color3.fromHex("#2B5FA8"),
	available = Color3.fromHex("#3B8BFF"),
	locked = Color3.fromHex("#5D6371"),
	selected = Color3.fromHex("#FFFFFF"),
}

-- Posición aproximada (latitud, longitud) de cada país del catálogo.
WorldMap.COUNTRY_GEO = {
	BR = { -10, -52 }, US = { 39, -98 }, DE = { 51, 10 }, PL = { 52, 20 }, JP = { 36, 138 },
	TH = { 15, 101 }, IN = { 21, 78 }, AU = { -25, 134 }, AE = { 24, 54 }, ZA = { -30, 25 },
}

-- Siluetas estilizadas: { lon0, lon1, lat0, lat1 } (grados). Provisional: se reemplaza con TEXTURE.
WorldMap.CONTINENTS = {
	-- América del Norte
	{ -168, -140, 54, 71 }, { -140, -60, 48, 70 }, { -80, -56, 45, 60 }, { -128, -66, 30, 49 },
	{ -118, -97, 16, 31 }, { -105, -86, 14, 22 }, { -92, -77, 7, 17 }, { -55, -20, 60, 82 },
	-- América del Sur
	{ -80, -50, -5, 12 }, { -75, -35, -20, -2 }, { -72, -48, -35, -18 }, { -74, -63, -55, -35 },
	-- Europa
	{ -10, 3, 36, 44 }, { -5, 30, 43, 55 }, { 5, 30, 55, 71 }, { -8, 2, 50, 59 }, { 20, 45, 44, 60 }, { 12, 19, 38, 46 },
	-- África
	{ -17, 35, 10, 37 }, { -10, 51, -5, 12 }, { 10, 40, -35, -5 }, { 43, 50, -25, -12 },
	-- Asia
	{ 45, 180, 50, 75 }, { 35, 60, 12, 32 }, { 45, 90, 30, 50 }, { 68, 90, 8, 30 }, { 90, 122, 20, 45 },
	{ 98, 110, 0, 22 }, { 126, 130, 34, 43 }, { 130, 146, 31, 45 }, { 95, 141, -9, 6 }, { 117, 127, 5, 19 },
	-- Oceanía
	{ 113, 154, -39, -12 }, { 166, 178, -47, -34 },
}

-- Proyección: (latitud, longitud) → (x, y) en fracción del lienzo.
function WorldMap.project(lat: number, lon: number): (number, number)
	local x = (lon + 180) / 360
	local y = (WorldMap.LAT_TOP - lat) / (WorldMap.LAT_TOP - WorldMap.LAT_BOTTOM)
	return math.clamp(x, 0, 1), math.clamp(y, 0, 1)
end

-- Vista por defecto (todo el mapa) y vista acotada a los límites.
function WorldMap.defaultView(): any
	return { zoom = 1, cx = 0.5, cy = 0.5 }
end

function WorldMap.clampView(v: any): any
	local z = math.clamp(tonumber(v.zoom) or 1, WorldMap.MIN_ZOOM, WorldMap.MAX_ZOOM)
	local half = 0.5 / z
	v.zoom = z
	v.cx = math.clamp(tonumber(v.cx) or 0.5, half, 1 - half)
	v.cy = math.clamp(tonumber(v.cy) or 0.5, half, 1 - half)
	return v
end

-- Zoom manteniendo fijo el punto del lienzo que está bajo (fx, fy) (fracción del recuadro visible).
function WorldMap.zoomAt(v: any, factor: number, fx: number?, fy: number?): any
	local x, y = fx or 0.5, fy or 0.5
	local px, py = v.cx + (x - 0.5) / v.zoom, v.cy + (y - 0.5) / v.zoom
	v.zoom = math.clamp(v.zoom * factor, WorldMap.MIN_ZOOM, WorldMap.MAX_ZOOM)
	v.cx, v.cy = px - (x - 0.5) / v.zoom, py - (y - 0.5) / v.zoom
	return WorldMap.clampView(v)
end

-- Desplazamiento en fracción del recuadro visible (arrastrar a la derecha mueve el mapa a la derecha).
function WorldMap.panBy(v: any, dx: number, dy: number): any
	v.cx -= dx / v.zoom
	v.cy -= dy / v.zoom
	return WorldMap.clampView(v)
end

-- Posición de un punto del lienzo dentro del recuadro visible (fracción; fuera de 0…1 = no se ve).
function WorldMap.toView(v: any, x: number, y: number): (number, number)
	return 0.5 + (x - v.cx) * v.zoom, 0.5 + (y - v.cy) * v.zoom
end

local STATE_TEXT = { disponible = "Disponible", bloqueado = "Bloqueado", abierto = "Abierto" }
WorldMap.STATE_TEXT = STATE_TEXT

--[[ Arma el mapa dentro de `parent`. opts = {
	  countries = { { id, name } }, states = { [id] = estado }, brand = Color3 (color de los abiertos),
	  selected = id?, view = tabla de vista (se modifica en el lugar), onSelect = function(id) }.
	Devuelve el controlador: { frame, markers, setSelected(id), setStates(states), zoomBy(f), panBy(dx, dy),
	  reset(), flash(id), view, destroy() }. ]]
function WorldMap.build(parent: Instance, opts: any): any
	local C = WorldMap.COLORS
	local view = WorldMap.clampView(opts.view or WorldMap.defaultView())
	local conns: { RBXScriptConnection } = {}
	local tweens: { Tween } = {}
	local ctl: any = { view = view, markers = {}, states = opts.states or {}, selected = opts.selected }

	local frame = Ui.new("Frame", {
		Name = "MapaMundial", Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.ocean, BackgroundTransparency = 0,
		ClipsDescendants = true, Active = true, Corner = 14, Stroke = { C.grid, 1, 0.4 }, Parent = parent,
	})
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(C.ocean2, C.ocean)
	grad.Rotation = 90
	grad.Parent = frame
	ctl.frame = frame

	local canvas = Ui.new("Frame", { Name = "Lienzo", BackgroundTransparency = 1, Parent = frame })
	ctl.canvas = canvas

	-- Cuadrícula de paralelos y meridianos (cada 30°).
	for lon = -150, 150, 30 do
		local x = (lon + 180) / 360
		Ui.new("Frame", { Name = "Meridiano", BackgroundColor3 = C.grid, BackgroundTransparency = 0.8, Position = UDim2.fromScale(x, 0), Size = UDim2.new(0, 1, 1, 0), Parent = canvas })
	end
	for lat = -30, 60, 30 do
		local _, y = WorldMap.project(lat, 0)
		Ui.new("Frame", { Name = "Paralelo", BackgroundColor3 = C.grid, BackgroundTransparency = lat == 0 and 0.6 or 0.8, Position = UDim2.fromScale(0, y), Size = UDim2.new(1, 0, 0, 1), Parent = canvas })
	end
	-- Continentes: textura definitiva si existe; si no, las siluetas provisionales.
	if WorldMap.TEXTURE then
		Ui.new("ImageLabel", { Name = "Textura", Image = WorldMap.TEXTURE, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ScaleType = Enum.ScaleType.Stretch, Parent = canvas })
	else
		local land = Ui.new("Frame", { Name = "Continentes", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = canvas })
		for i, b in WorldMap.CONTINENTS do
			local x0, y0 = WorldMap.project(b[4], b[1])
			local x1, y1 = WorldMap.project(b[3], b[2])
			local piece = Ui.new("Frame", {
				Name = "Tierra" .. i, BackgroundColor3 = C.land, BackgroundTransparency = 0.15,
				Position = UDim2.fromScale(x0, y0), Size = UDim2.fromScale(x1 - x0, y1 - y0),
				Stroke = { C.landEdge, 1, 0.75 }, Parent = land,
			})
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0.35, 0)
			corner.Parent = piece
		end
	end

	-- Tooltip compartido (información al pasar el cursor).
	local tip = Ui.new("TextLabel", {
		Name = "InfoPais", Visible = false, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), BackgroundColor3 = Color3.fromHex("#0B1220"),
		BackgroundTransparency = 0.05, TextSize = Ui.S.xs, ZIndex = 20, Corner = 8, Pad = { 5, 9 }, Stroke = { C.landEdge, 1, 0.3 }, Parent = frame,
	})
	ctl.tip = tip

	local function stateColor(id: string): Color3
		local st = ctl.states[id]
		if st == "abierto" then
			return opts.brand or C.available
		elseif st == "disponible" then
			return C.available
		end
		return C.locked
	end

	local function paint(id: string)
		local m = ctl.markers[id]
		if not m then
			return
		end
		local st = ctl.states[id] or "bloqueado"
		local sel = ctl.selected == id
		local col = stateColor(id)
		m.dot.BackgroundColor3 = col
		m.glow.BackgroundColor3 = col
		m.glow.BackgroundTransparency = st == "bloqueado" and 0.9 or (st == "abierto" and 0.55 or 0.65)
		m.ring.Color = sel and C.selected or col
		m.ring.Thickness = sel and 3 or 1.5
		m.ring.Transparency = sel and 0 or 0.25
		m.scale.Scale = sel and 1.3 or 1
		m.label.Visible = sel or view.zoom >= 1.8
		m.label.TextColor3 = sel and C.selected or (st == "bloqueado" and T.mut or T.tx)
		m.button:SetAttribute("estado", st)
		m.button:SetAttribute("seleccionado", sel)
	end
	ctl.paint = paint

	for _, c in opts.countries do
		local geo = WorldMap.COUNTRY_GEO[c.id]
		if geo then
			local x, y = WorldMap.project(geo[1], geo[2])
			local b = Ui.new("TextButton", {
				Name = "Marcador_" .. c.id, Text = "", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(x, y), Size = UDim2.fromOffset(30, 30), ZIndex = 5, Parent = canvas,
			})
			b:SetAttribute("x", x)
			b:SetAttribute("y", y)
			local scale = Instance.new("UIScale")
			scale.Parent = b
			local glow = Ui.new("Frame", { Name = "Brillo", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0.6, Corner = 999, ZIndex = 5, Parent = b })
			local dot = Ui.new("Frame", { Name = "Punto", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(12, 12), BackgroundTransparency = 0, Corner = 999, ZIndex = 6, Parent = b })
			local ring = Instance.new("UIStroke")
			ring.Parent = dot
			local label = Ui.new("TextLabel", {
				Name = "Nombre", Text = c.name, TextSize = Ui.S.xs, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 1, 2),
				Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, TextXAlignment = Enum.TextXAlignment.Center, Weight = W.semi, ZIndex = 7, Parent = b,
			})
			local m = { button = b, dot = dot, glow = glow, ring = ring, scale = scale, label = label, x = x, y = y, name = c.name }
			ctl.markers[c.id] = m
			table.insert(conns, b.MouseButton1Click:Connect(function()
				ctl.setSelected(c.id)
				if opts.onSelect then
					opts.onSelect(c.id)
				end
			end))
			table.insert(conns, b.MouseEnter:Connect(function()
				tip.Text = "<b>" .. c.name .. "</b> · " .. (STATE_TEXT[ctl.states[c.id] or "bloqueado"] or "")
				tip.Visible = true
				local vx, vy = WorldMap.toView(view, x, y)
				tip.Position = UDim2.new(vx, 18, vy, -12)
			end))
			table.insert(conns, b.MouseLeave:Connect(function()
				tip.Visible = false
			end))
			-- Pulso suave de los disponibles (sin cálculos económicos: solo transparencia).
			if not Ui.reduceMotion and ctl.states[c.id] == "disponible" then
				local tw = TweenService:Create(glow, TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Size = UDim2.fromScale(1.6, 1.6), BackgroundTransparency = 0.9 })
				tw:Play()
				table.insert(tweens, tw)
			end
		end
	end

	local function apply()
		WorldMap.clampView(view)
		canvas.Size = UDim2.fromScale(view.zoom, view.zoom)
		canvas.Position = UDim2.fromScale(0.5 - view.cx * view.zoom, 0.5 - view.cy * view.zoom)
		for id in ctl.markers do
			paint(id)
		end
		frame:SetAttribute("zoom", view.zoom)
	end
	ctl.apply = apply

	function ctl.setSelected(id: string?)
		local prev = ctl.selected
		ctl.selected = id
		if prev then
			paint(prev)
		end
		if id then
			paint(id)
		end
	end
	function ctl.setStates(states: any)
		ctl.states = states
		for id in ctl.markers do
			paint(id)
		end
	end
	function ctl.zoomBy(f: number, fx: number?, fy: number?)
		WorldMap.zoomAt(view, f, fx, fy)
		apply()
	end
	function ctl.panBy(dx: number, dy: number)
		WorldMap.panBy(view, dx, dy)
		apply()
	end
	function ctl.reset()
		view.zoom, view.cx, view.cy = 1, 0.5, 0.5
		apply()
	end
	-- Destello breve del marcador (por ejemplo, al abrir un país).
	function ctl.flash(id: string)
		local m = ctl.markers[id]
		if not m or Ui.reduceMotion then
			return
		end
		m.glow.Size = UDim2.fromScale(3, 3)
		m.glow.BackgroundTransparency = 0.2
		TweenService:Create(m.glow, TweenInfo.new(1.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 0.55 }):Play()
	end

	-- Rueda del mouse: zoom hacia el cursor.
	local function focus(px: number, py: number): (number, number)
		local abs, pos = frame.AbsoluteSize, frame.AbsolutePosition
		if abs.X <= 0 or abs.Y <= 0 then
			return 0.5, 0.5
		end
		return (px - pos.X) / abs.X, (py - pos.Y) / abs.Y
	end
	table.insert(conns, frame.MouseWheelForward:Connect(function(px: number, py: number)
		local fx, fy = focus(px, py)
		ctl.zoomBy(WorldMap.ZOOM_STEP, fx, fy)
	end))
	table.insert(conns, frame.MouseWheelBackward:Connect(function(px: number, py: number)
		local fx, fy = focus(px, py)
		ctl.zoomBy(1 / WorldMap.ZOOM_STEP, fx, fy)
	end))
	-- Arrastre (mouse o táctil) para desplazar.
	local dragging: any = nil
	table.insert(conns, frame.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = { last = input.Position }
		end
	end))
	table.insert(conns, UserInputService.InputChanged:Connect(function(input: InputObject)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local abs = frame.AbsoluteSize
			local d = input.Position - dragging.last
			dragging.last = input.Position
			if abs.X > 0 and abs.Y > 0 then
				ctl.panBy(d.X / abs.X, d.Y / abs.Y)
			end
		end
	end))
	table.insert(conns, UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = nil
		end
	end))

	-- Controles de zoom y encuadre.
	local controls = Ui.col({
		Ui.button("", "default", function()
			ctl.zoomBy(WorldMap.ZOOM_STEP)
		end, { small = true, icon = "plus", iconSize = 14, name = "AcercarMapa" }),
		Ui.button("", "default", function()
			ctl.zoomBy(1 / WorldMap.ZOOM_STEP)
		end, { small = true, icon = "minus", iconSize = 14, name = "AlejarMapa" }),
		Ui.button("Ver todo", "default", function()
			ctl.reset()
		end, { small = true, name = "EncuadreCompleto" }),
	}, 6, { Name = "ControlesMapa", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, ZIndex = 10 })
	controls.Parent = frame
	-- Leyenda de estados.
	local function legend(color: Color3, text: string): Frame
		return Ui.row({ Ui.new("Frame", { Size = UDim2.fromOffset(10, 10), BackgroundColor3 = color, BackgroundTransparency = 0, Corner = 999 }), Ui.inline(text, { size = Ui.S.xs, color = T.tx2 }) }, 5)
	end
	local leg = Ui.row({
		legend(C.available, "Disponible"), legend(C.locked, "Bloqueado"), legend(opts.brand or C.available, "Abierto"),
		Ui.row({ Ui.new("Frame", { Size = UDim2.fromOffset(10, 10), BackgroundTransparency = 1, Corner = 999, Stroke = { C.selected, 2 } }), Ui.inline("Seleccionado", { size = Ui.S.xs, color = T.tx2 }) }, 5),
	}, 12, { Name = "Leyenda", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 12, 1, -10), Size = UDim2.new(), AutomaticSize = Enum.AutomaticSize.XY, wrap = true, ZIndex = 10 })
	leg.Parent = frame

	function ctl.destroy()
		for _, c in conns do
			c:Disconnect()
		end
		table.clear(conns)
		for _, tw in tweens do
			tw:Cancel()
		end
		table.clear(tweens)
		if frame.Parent then
			frame:Destroy()
		end
	end
	-- Si la pantalla se reconstruye, el mapa viejo libera sus conexiones (también la global de arrastre).
	table.insert(conns, frame.AncestryChanged:Connect(function(_, newParent)
		if newParent == nil then
			ctl.destroy()
		end
	end))
	ctl.conns = conns
	apply()
	return ctl
end

return WorldMap
