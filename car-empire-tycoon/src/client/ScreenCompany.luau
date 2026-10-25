--!strict
--[[
	«Fundá tu empresa» (renderNueva de la V3): nombre, logotipo, color de marca y dificultad.
	Solo el nombre es obligatorio; el resto tiene valores por defecto. El botón cambia de estado
	mientras se escribe con Ui.setEnabled (la apariencia y el clic usan el mismo dato).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {}

-- Regla del formulario (la misma que valida el servidor). Expuesta para las pruebas.
function Screen.nameState(name: string): (boolean, string)
	local n = Util.charCount(Util.trim(name))
	if n < 3 or n > 24 then
		return false, "✕ Usá entre 3 y 24 caracteres"
	end
	if string.find(name, "[%c<>&]") then
		return false, "✕ Evitá los símbolos < > &"
	end
	if App.profile then
		for _, s in App.profile.slots do
			if not s.damaged and string.lower(s.name) == string.lower(Util.trim(name)) then
				return false, "✕ Ya tenés una empresa con ese nombre"
			end
		end
	end
	return true, "✓ Nombre válido"
end

function Screen.build(parent: Instance)
	local st = App.ui.newCompany
	local dif = Catalog.DIFFICULTIES[st.difficulty]
	local valid, hint = Screen.nameState(st.name)
	local narrow = App.isNarrow()

	local wrap = Ui.new("Frame", {
		Name = "MenuWrap",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromHex("#06070B"),
		BackgroundTransparency = 0,
		Parent = parent,
	})
	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.07),
		NumberSequenceKeypoint.new(0.4, 0.35),
		NumberSequenceKeypoint.new(0.55, 0.4),
		NumberSequenceKeypoint.new(1, 0.1),
	})
	grad.Parent = wrap

	local preview = { name = Util.trim(st.name) ~= "" and Util.trim(st.name) or "Tu empresa", color = st.color, logo = st.logo }
	local previewName = Ui.text(preview.name, { size = 24, weight = W.heavy })
	local left = Ui.col({
		Ui.button("Volver a mis empresas", "q", function()
			App.go("menu")
		end, { small = true, icon = "left" }),
		Ui.text("Fundá tu empresa", { size = narrow and 30 or 46, weight = W.heavy, lineHeight = 1.0 }),
		Ui.text("Arrancás con un garaje pequeño. El nombre, el logo y el color aparecen en el cartel del taller, en el HUD y en tus autos.", { size = 16, color = T.tx2, lineHeight = 1.3 }),
		Ui.card({
			Ui.logo(preview, 80),
			Ui.grow(Ui.col({
				Ui.lbl("Vista previa"),
				previewName,
				Ui.text("Garaje inicial · " .. dif.label .. " · " .. Util.money(dif.money) .. " iniciales", { size = Ui.S.sm, color = T.mut }),
			}, 6)),
		}, { dir = "H", gap = 18, pad = 18, bg = Color3.fromHex("#0E1016"), transparency = 0.1, v = "C", radius = 12, stroke = T.line }),
	}, 16)

	local hintLabel = Ui.text(hint, { size = Ui.S.xs, color = valid and T.gr or T.re2, weight = W.bold })
	local createBtn: TextButton
	local function refresh()
		local ok, h = Screen.nameState(st.name)
		hintLabel.Text = h
		hintLabel.TextColor3 = ok and T.gr or T.re2
		previewName.Text = Util.trim(st.name) ~= "" and Util.trim(st.name) or "Tu empresa"
		if createBtn then
			Ui.setEnabled(createBtn, ok, "Revisá el nombre: " .. string.gsub(h, "^✕ ", ""))
		end
	end
	local nameBox = Ui.input(st.name, "Por ejemplo: Ruta Norte Motors", function(text: string)
		st.name = text
		refresh()
	end, {
		size = 18,
		height = 52,
		onChange = function(text: string)
			st.name = text
			refresh()
		end,
	})

	local logos = {}
	for _, l in Catalog.LOGOS do
		local selected = st.logo == l[1]
		local b = Ui.new("TextButton", {
			Name = "Logo_" .. l[1],
			Text = "",
			BackgroundColor3 = selected and Color3.fromHex("#1E1B3D") or T.input,
			BackgroundTransparency = 0,
			Size = UDim2.fromOffset(48, 48),
			Corner = 9,
			Stroke = selected and { T.vi, 2 } or T.line,
		}, { Ui.icon("logo_" .. l[1], 26, selected and T.tx or T.tx2) })
		local ic = b:FindFirstChild("Icono") :: Frame
		ic.AnchorPoint = Vector2.new(0.5, 0.5)
		ic.Position = UDim2.fromScale(0.5, 0.5)
		b.Activated:Connect(function()
			st.logo = l[1]
			App.forceRender()
		end)
		table.insert(logos, b)
	end

	local swatches = {}
	for _, c in Catalog.BRAND_COLORS do
		table.insert(swatches, Ui.swatch(c[1], st.color == c[1], function()
			st.color = c[1]
			App.forceRender()
		end, 42))
	end
	table.insert(swatches, Ui.inline(Catalog.colorName(Catalog.BRAND_COLORS, st.color) or "", { size = Ui.S.sm, color = T.mut }))

	local difRow = Ui.new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, List = { dir = App.isPhone() and "V" or "H", gap = 10 } })
	for _, id in Catalog.DIFFICULTY_ORDER do
		local d = Catalog.DIFFICULTIES[id]
		local selected = st.difficulty == id
		local dotsColor = d.dots == 1 and T.gr or (d.dots == 2 and T.ye or T.re2)
		local b = Ui.new("TextButton", {
			Name = "Dificultad_" .. id,
			Text = "",
			BackgroundColor3 = selected and Color3.fromHex("#1E1B3D") or T.input,
			BackgroundTransparency = 0,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Corner = 9,
			Stroke = selected and { T.vi, 2 } or T.line,
			Pad = 12,
			List = { dir = "V", gap = 6 },
		}, {
			Ui.row({ Ui.grow(Ui.text(d.label, { size = 16, weight = W.bold })), Ui.inline(string.rep("●", d.dots), { size = Ui.S.xs, color = dotsColor }) }, 6),
			Ui.text(d.desc, { size = Ui.S.xs, color = T.mut, lineHeight = 1.2 }),
			Ui.text(Util.money(d.money) .. " iniciales", { size = Ui.S.sm, weight = W.bold, color = T.gr }),
		})
		b.Activated:Connect(function()
			st.difficulty = id
			App.forceRender()
		end)
		Ui.grow(b, { Size = UDim2.new(App.isPhone() and 1 or 0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }).Parent = difRow
	end

	createBtn = Ui.button("Comenzar mi empresa", "p", function()
		local ok, h = Screen.nameState(st.name)
		if not ok then
			App.toast("error", h)
			return
		end
		local r = App.request("createCompany", { slot = st.slot, name = Util.trim(st.name), color = st.color, logo = st.logo, difficulty = st.difficulty }, { button = createBtn })
		if r.ok then
			st.name = ""
			App.go("juego")
		end
	end, { name = "Comenzar" })
	refresh()

	local form = Ui.new("Frame", {
		Name = "NuevaEmpresa",
		BackgroundColor3 = Color3.fromHex("#0E1016"),
		BackgroundTransparency = 0.03,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Corner = 12,
		Stroke = T.line,
		List = { dir = "V", gap = 0 },
		ClipsDescendants = true,
	}, {
		Ui.row({ Ui.grow(Ui.text("Nueva empresa", { size = Ui.S.h1, weight = W.bold })), Ui.inline("Ranura " .. st.slot .. " de " .. Catalog.RULES.slots, { size = Ui.S.sm, color = T.mut }) }, 10, { Pad = { 18, 18, 6, 18 } }),
		Ui.col({
			Ui.col({ Ui.lbl("Nombre de la empresa"), nameBox, hintLabel }, 8),
			Ui.col({ Ui.lbl("Logotipo"), Ui.row(logos, 8, { wrap = true }) }, 10),
			Ui.col({ Ui.lbl("Color de marca"), Ui.row(swatches, 10, { wrap = true }) }, 10),
			Ui.col({ Ui.lbl("Dificultad"), difRow }, 10),
		}, 20, { Pad = 18 }),
		Ui.row({
			Ui.grow(Ui.text("Solo el nombre es obligatorio. Pasa por el filtro de texto de Roblox porque se ve en tu garaje.", { size = Ui.S.sm, color = T.mut })),
			createBtn,
		}, 10, { BackgroundColor3 = Color3.fromHex("#08090D"), BackgroundTransparency = 0.4, Pad = 18, wrap = App.isPhone() }),
	})

	-- En pantallas de poca altura todo va en una columna desplazable (el botón siempre es alcanzable).
	local scroller = Ui.scroll({}, { name = "Formulario", gap = 22, pad = { 18, narrow and 14 or 60, 24, narrow and 14 or 60 } })
	scroller.Parent = wrap
	App.keepScroll(scroller, "nueva")
	if narrow then
		left.Parent = scroller
		form.Parent = scroller
	else
		local cols = Ui.row({}, 40, { Name = "Columnas", v = "T" })
		cols.Parent = scroller
		local l = Ui.grow(left, { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
		l.Parent = cols
		local maxL = Instance.new("UISizeConstraint")
		maxL.MaxSize = Vector2.new(620, math.huge)
		maxL.Parent = left
		Ui.new("Frame", { Size = UDim2.new(0, math.min(760, App.vw * 0.5), 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, { form }).Parent = cols
	end
end

return Screen
