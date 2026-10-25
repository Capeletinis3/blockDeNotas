--!strict
--[[
	Íconos de línea dibujados con elementos nativos (Frames, bordes y rotación), en una grilla de 24×24
	como los íconos SVG de la V3. Reemplazan los emojis y no dependen de imágenes subidas.
	Formas: { "l", x1, y1, x2, y2 } línea · { "o", cx, cy, w, h, radio } contorno · { "r", cx, cy, w, h, radio, rot } relleno
	        { "c", cx, cy, d } círculo lleno · { "ring", cx, cy, d } aro · { "t", texto } texto centrado
]]

local Icons = {}

local SHAPES: { [string]: { any } } = {
	home = { { "l", 3, 11, 12, 4 }, { "l", 12, 4, 21, 11 }, { "o", 12, 15.5, 13, 9, 1 }, { "r", 12, 17.5, 3.4, 5, 0.5 } },
	pen = { { "l", 5, 19, 17, 7, 3 }, { "l", 15, 5, 19, 9, 2 }, { "r", 4.6, 19.4, 3, 3, 0.5, 45 } },
	car = { { "o", 12, 14.5, 19, 5.5, 2 }, { "o", 12, 9.8, 10, 4.4, 1.6 }, { "c", 7, 18.3, 4.2 }, { "c", 17, 18.3, 4.2 } },
	factory = { { "o", 12, 15, 18, 10, 1 }, { "r", 17.5, 7, 3, 8, 0.5 }, { "l", 3, 10, 8, 7 }, { "l", 8, 7, 8, 10 }, { "l", 8, 10, 13, 7 }, { "r", 8, 16, 2.5, 3, 0.4 }, { "r", 12.5, 16, 2.5, 3, 0.4 } },
	tag = { { "o", 13, 11, 11, 11, 2, 45 }, { "c", 15.5, 8.5, 2.6 } },
	globe = { { "ring", 12, 12, 18 }, { "o", 12, 12, 8, 18, 9 }, { "l", 3, 12, 21, 12 } },
	flask = { { "l", 9.5, 3, 14.5, 3 }, { "l", 10, 3, 10, 9 }, { "l", 14, 3, 14, 9 }, { "l", 10, 9, 5, 19 }, { "l", 14, 9, 19, 19 }, { "l", 5, 19.5, 19, 19.5 }, { "r", 12, 16.5, 9, 3, 1 } },
	users = { { "ring", 9, 8, 7 }, { "o", 9, 17.5, 13, 6.5, 3 }, { "ring", 17, 9, 5 }, { "l", 18, 15, 21, 18 } },
	user = { { "ring", 12, 8, 8 }, { "o", 12, 18, 15, 7, 3.5 } },
	building = { { "o", 12, 13, 15, 16, 1 }, { "r", 9, 9, 2.4, 2.4, 0.4 }, { "r", 15, 9, 2.4, 2.4, 0.4 }, { "r", 9, 14, 2.4, 2.4, 0.4 }, { "r", 15, 14, 2.4, 2.4, 0.4 }, { "r", 12, 19, 3, 4, 0.4 } },
	flag = { { "l", 5, 3, 5, 21 }, { "o", 11.5, 8, 12, 8, 1 } },
	chart = { { "l", 3, 20.5, 21, 20.5 }, { "r", 7, 16, 3, 7, 0.6 }, { "r", 12, 12.5, 3, 14, 0.6 }, { "r", 17, 10, 3, 19, 0.6 } },
	bell = { { "o", 12, 11, 12, 12, 6 }, { "l", 4.5, 17, 19.5, 17 }, { "c", 12, 20, 3.2 } },
	gear = { { "ring", 12, 12, 9 }, { "l", 12, 2.5, 12, 6 }, { "l", 12, 18, 12, 21.5 }, { "l", 2.5, 12, 6, 12 }, { "l", 18, 12, 21.5, 12 }, { "l", 5.3, 5.3, 7.8, 7.8 }, { "l", 16.2, 16.2, 18.7, 18.7 }, { "l", 5.3, 18.7, 7.8, 16.2 }, { "l", 16.2, 7.8, 18.7, 5.3 } },
	help = { { "ring", 12, 12, 18 }, { "t", "?" } },
	x = { { "l", 6, 6, 18, 18 }, { "l", 18, 6, 6, 18 } },
	check = { { "l", 5, 12.5, 10, 17.5 }, { "l", 10, 17.5, 19, 7 } },
	warn = { { "l", 12, 3.5, 21.5, 20 }, { "l", 21.5, 20, 2.5, 20 }, { "l", 2.5, 20, 12, 3.5 }, { "r", 12, 12, 2, 5, 1 }, { "c", 12, 16.8, 2.2 } },
	lock = { { "o", 12, 15.5, 14, 10, 2 }, { "o", 12, 8.5, 8, 9, 4 }, { "c", 12, 15.5, 2.6 } },
	plus = { { "l", 12, 5, 12, 19 }, { "l", 5, 12, 19, 12 } },
	minus = { { "l", 5, 12, 19, 12 } },
	money = { { "t", "$" } },
	star = { { "r", 12, 12.5, 11, 11, 1, 0 }, { "r", 12, 12.5, 11, 11, 1, 45 } },
	gem = { { "o", 12, 12, 12, 12, 1, 45 }, { "l", 7.8, 12, 16.2, 12 } },
	cal = { { "o", 12, 13.5, 16, 15, 2 }, { "l", 4, 9.5, 20, 9.5 }, { "l", 8, 3, 8, 7 }, { "l", 16, 3, 16, 7 } },
	box = { { "o", 12, 12.5, 16, 15, 1 }, { "l", 4, 9, 20, 9 }, { "l", 12, 9, 12, 20 } },
	wrench = { { "l", 5.5, 18.5, 14, 10, 3 }, { "ring", 16.5, 7.5, 7 } },
	play = { { "l", 8, 5, 8, 19 }, { "l", 8, 5, 18.5, 12 }, { "l", 8, 19, 18.5, 12 } },
	pause = { { "r", 8.5, 12, 3, 14, 1 }, { "r", 15.5, 12, 3, 14, 1 } },
	up = { { "l", 6, 15, 12, 9 }, { "l", 12, 9, 18, 15 } },
	down = { { "l", 6, 9, 12, 15 }, { "l", 12, 15, 18, 9 } },
	left = { { "l", 15, 6, 9, 12 }, { "l", 9, 12, 15, 18 } },
	right = { { "l", 9, 6, 15, 12 }, { "l", 15, 12, 9, 18 } },
	menu = { { "l", 4, 7, 20, 7 }, { "l", 4, 12, 20, 12 }, { "l", 4, 17, 20, 17 } },
	trash = { { "o", 12, 14.5, 12, 13, 1 }, { "l", 4, 6.5, 20, 6.5 }, { "l", 9.5, 3.5, 14.5, 3.5 }, { "l", 10, 11, 10, 18 }, { "l", 14, 11, 14, 18 } },
	copy = { { "o", 14, 14, 11, 11, 1.5 }, { "l", 4.5, 15, 4.5, 4.5 }, { "l", 4.5, 4.5, 15, 4.5 } },
	gift = { { "o", 12, 15, 16, 10, 1 }, { "o", 12, 8.5, 19, 4, 1 }, { "l", 12, 6.5, 12, 20 } },
	trophy = { { "o", 12, 8, 10, 9, 4 }, { "l", 12, 12.5, 12, 18 }, { "l", 7.5, 20, 16.5, 20 }, { "l", 7, 6, 4, 6 }, { "l", 17, 6, 20, 6 } },
	search = { { "ring", 10, 10, 12 }, { "l", 14.5, 14.5, 20.5, 20.5 } },
	heart = { { "c", 8.5, 9.5, 7.5 }, { "c", 15.5, 9.5, 7.5 }, { "r", 12, 13, 10, 10, 1, 45 } },
	cam = { { "o", 12, 13.5, 18, 12, 2 }, { "ring", 12, 13.5, 7 }, { "r", 9, 6.5, 6, 3, 0.8 } },
	undo = { { "l", 4, 9.5, 9, 4.5 }, { "l", 4, 9.5, 9, 14.5 }, { "l", 4, 9.5, 15, 9.5 }, { "o", 15, 14.5, 10, 10, 5 } },
	redo = { { "l", 20, 9.5, 15, 4.5 }, { "l", 20, 9.5, 15, 14.5 }, { "l", 20, 9.5, 9, 9.5 }, { "o", 9, 14.5, 10, 10, 5 } },
	compare = { { "l", 12, 3, 12, 21 }, { "l", 8, 8, 4, 12 }, { "l", 4, 12, 8, 16 }, { "l", 16, 8, 20, 12 }, { "l", 20, 12, 16, 16 } },
	reset = { { "ring", 12, 12, 15 }, { "l", 18, 4, 19, 9 }, { "l", 19, 9, 14, 9 } },
	grip = { { "c", 9, 6, 2.6 }, { "c", 15, 6, 2.6 }, { "c", 9, 12, 2.6 }, { "c", 15, 12, 2.6 }, { "c", 9, 18, 2.6 }, { "c", 15, 18, 2.6 } },
	eye = { { "o", 12, 12, 19, 10, 5 }, { "c", 12, 12, 4.5 } },
	zoomin = { { "ring", 10, 10, 12 }, { "l", 14.5, 14.5, 20.5, 20.5 }, { "l", 10, 7, 10, 13 }, { "l", 7, 10, 13, 10 } },
	zoomout = { { "ring", 10, 10, 12 }, { "l", 14.5, 14.5, 20.5, 20.5 }, { "l", 7, 10, 13, 10 } },
	rotate = { { "o", 12, 12, 16, 16, 8 }, { "l", 17, 3, 20, 7 }, { "l", 20, 7, 16, 9 } },
	sound = { { "o", 7, 12, 5, 7, 1 }, { "l", 9.5, 9, 14, 5 }, { "l", 9.5, 15, 14, 19 }, { "l", 14, 5, 14, 19 }, { "l", 17.5, 9, 17.5, 15 } },
	-- Logotipos de empresa (V3: LOGOS)
	logo_pico = { { "l", 4, 18, 12, 5 }, { "l", 12, 5, 20, 18 }, { "l", 8, 13, 16, 13 } },
	logo_rayo = { { "l", 14, 2.5, 6, 13.5 }, { "l", 6, 13.5, 12, 13.5 }, { "l", 12, 13.5, 10, 21.5 }, { "l", 10, 21.5, 18.5, 10 }, { "l", 18.5, 10, 12.5, 10 }, { "l", 12.5, 10, 14, 2.5 } },
	logo_escudo = { { "o", 12, 11.5, 15, 16, 5 }, { "l", 12, 6, 12, 17 } },
	logo_corona = { { "l", 4, 8, 7, 18 }, { "l", 4, 8, 9, 12 }, { "l", 9, 12, 12, 5 }, { "l", 12, 5, 15, 12 }, { "l", 15, 12, 20, 8 }, { "l", 20, 8, 17, 18 }, { "l", 7, 18.5, 17, 18.5 } },
	logo_pinon = { { "ring", 12, 12, 9 }, { "ring", 12, 12, 3.5 }, { "l", 12, 2.5, 12, 6 }, { "l", 12, 18, 12, 21.5 }, { "l", 2.5, 12, 6, 12 }, { "l", 18, 12, 21.5, 12 } },
	logo_ala = { { "l", 3, 15, 21, 6 }, { "l", 21, 6, 13, 17 }, { "l", 13, 17, 5, 17 }, { "l", 5, 17, 3, 15 } },
	logo_estrella = { { "r", 12, 12.5, 11, 11, 1, 0 }, { "r", 12, 12.5, 11, 11, 1, 45 } },
	logo_ruta = { { "l", 8, 21, 10, 3 }, { "l", 16, 21, 14, 3 }, { "l", 12, 6, 12, 8 }, { "l", 12, 11, 12, 13 }, { "l", 12, 16, 12, 18 } },
}
Icons.SHAPES = SHAPES

local function frame(parent: Instance, color: Color3): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Parent = parent
	return f
end

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(r, 0)
	c.Parent = parent
end

-- Dibuja el ícono `name` en un cuadrado de `size` píxeles del color indicado.
function Icons.make(name: string, size: number, color: Color3, strokeWidth: number?): Frame
	local root = Instance.new("Frame")
	root.Name = "Icono"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Size = UDim2.fromOffset(size, size)
	root:SetAttribute("icon", name)
	local k = size / 24
	local sw = math.max(1, math.floor((strokeWidth or 2) * k + 0.5))
	local shapes = SHAPES[name] or { { "t", "•" } }
	for _, s in shapes do
		local kind = s[1]
		if kind == "l" then
			local x1, y1, x2, y2 = s[2], s[3], s[4], s[5]
			local w = (s[6] or (strokeWidth or 2)) * k
			local dx, dy = x2 - x1, y2 - y1
			local len = math.sqrt(dx * dx + dy * dy) * k + w
			local f = frame(root, color)
			f.Name = "Linea"
			f.Size = UDim2.fromOffset(len, math.max(1, w))
			f.Position = UDim2.fromScale((x1 + x2) / 2 / 24, (y1 + y2) / 2 / 24)
			f.Rotation = math.deg(math.atan2(dy, dx))
			corner(f, 0.5)
		elseif kind == "o" or kind == "ring" then
			local w, h, r, rot
			if kind == "ring" then
				w, h, r, rot = s[4], s[4], s[4] / 2, 0
			else
				w, h, r, rot = s[4], s[5], s[6] or 0, s[7] or 0
			end
			local f = frame(root, color)
			f.Name = "Contorno"
			f.BackgroundTransparency = 1
			f.Size = UDim2.fromOffset(w * k, h * k)
			f.Position = UDim2.fromScale(s[2] / 24, s[3] / 24)
			f.Rotation = rot
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, r * k)
			c.Parent = f
			local st = Instance.new("UIStroke")
			st.Color = color
			st.Thickness = sw
			st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			st.Parent = f
		elseif kind == "r" then
			local f = frame(root, color)
			f.Name = "Relleno"
			f.Size = UDim2.fromOffset(s[4] * k, s[5] * k)
			f.Position = UDim2.fromScale(s[2] / 24, s[3] / 24)
			f.Rotation = s[7] or 0
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, (s[6] or 0) * k)
			c.Parent = f
		elseif kind == "c" then
			local f = frame(root, color)
			f.Name = "Circulo"
			f.Size = UDim2.fromOffset(s[4] * k, s[4] * k)
			f.Position = UDim2.fromScale(s[2] / 24, s[3] / 24)
			corner(f, 0.5)
		elseif kind == "t" then
			local t = Instance.new("TextLabel")
			t.Name = "Glifo"
			t.BackgroundTransparency = 1
			t.Size = UDim2.fromScale(1, 1)
			t.Text = s[2]
			t.TextColor3 = color
			t.TextSize = math.floor(size * 0.8)
			t.FontFace = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)
			t.Parent = root
		end
	end
	return root
end

function Icons.recolor(root: Instance, color: Color3)
	for _, d in root:GetDescendants() do
		if d:IsA("UIStroke") then
			d.Color = color
		elseif d:IsA("TextLabel") then
			d.TextColor3 = color
		elseif d:IsA("Frame") and d.BackgroundTransparency < 1 then
			d.BackgroundColor3 = color
		end
	end
end

function Icons.has(name: string): boolean
	return SHAPES[name] ~= nil
end

return Icons
