--!strict
-- «Fundá tu empresa» (renderNueva de la V3): nombre, color de marca y dificultad.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {}

local function nameState(name: string): (boolean, string)
	local n = Util.charCount(Util.trim(name))
	if n < 3 or n > 24 then
		return false, "✕ Usá entre 3 y 24 caracteres"
	end
	if string.find(name, "[%c<>&]") then
		return false, "✕ Evitá los símbolos < > &"
	end
	return true, "✓ Nombre válido"
end

function Screen.build(parent: Instance)
	local st = App.ui.newCompany
	local dif = Catalog.DIFFICULTIES[st.difficulty]
	local valid, hint = nameState(st.name)

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
		NumberSequenceKeypoint.new(0.75, 0.1),
		NumberSequenceKeypoint.new(1, 0.1),
	})
	grad.Parent = wrap

	local narrow = App.vw < 1100
	local preview = { name = Util.trim(st.name) ~= "" and Util.trim(st.name) or "Tu empresa", color = st.color }

	-- Columna izquierda (hero)
	local left = Ui.col({
		Ui.text("Fundá tu empresa", { size = narrow and 30 or 46, weight = W.heavy, lineHeight = 1.0 }),
		Ui.text("Arrancás con un garaje pequeño. El nombre y el color aparecen en el cartel del taller, en el HUD y en tus autos.", { size = 17, color = T.tx2, lineHeight = 1.3 }),
		Ui.card({
			Ui.logo(preview, 80),
			Ui.grow(Ui.col({
				Ui.lbl("Vista previa"),
				Ui.text(preview.name, { size = 24, weight = W.heavy }),
				Ui.text("Garaje inicial · " .. dif.label .. " · " .. Util.money(dif.money) .. " iniciales", { size = Ui.S.sm, color = T.mut }),
			}, 6)),
		}, { dir = "H", gap = 18, pad = 18, bg = Color3.fromHex("#0E1016"), transparency = 0.1, v = "C", radius = 12, stroke = T.line }),
	}, 18)

	-- Formulario
	local nameBox
	local hintLabel = Ui.text(hint, { size = Ui.S.xs, color = valid and T.gr or T.re2, weight = W.bold })
	local createBtn: TextButton
	local function paintButton(ok: boolean)
		if not createBtn then
			return
		end
		createBtn:SetAttribute("disabled", not ok)
		createBtn.BackgroundColor3 = ok and T.tx or T.disabledBg
		createBtn.TextColor3 = ok and T.dark or T.disabledTx;
		(createBtn:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = ok and T.tx or Color3.fromHex("#22252E")
	end
	nameBox = Ui.input(st.name, "Por ejemplo: Ruta Norte Motors", function(text: string)
		st.name = text
	end, {
		size = 18,
		height = 52,
		onChange = function(text: string)
			st.name = text
			local ok, h = nameState(text)
			hintLabel.Text = h
			hintLabel.TextColor3 = ok and T.gr or T.re2
			paintButton(ok)
		end,
	})

	local swatches = {}
	for _, c in Catalog.BRAND_COLORS do
		table.insert(swatches, Ui.swatch(c[1], st.color == c[1], function()
			st.color = c[1]
			App.render()
		end, 42))
	end
	table.insert(swatches, Ui.inline(Catalog.colorName(Catalog.BRAND_COLORS, st.color) or "", { size = Ui.S.sm, color = T.mut }))

	local difs = {}
	for _, id in Catalog.DIFFICULTY_ORDER do
		local d = Catalog.DIFFICULTIES[id]
		local selected = st.difficulty == id
		local dotsColor = d.dots == 1 and T.gr or (d.dots == 2 and T.ye or T.re2)
		local b = Ui.new("TextButton", {
			Name = "Dificultad",
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
			App.render()
		end)
		table.insert(difs, b)
	end

	-- El botón valida al hacer clic y cambia de aspecto mientras se escribe (sin reconstruir la pantalla).
	createBtn = Ui.button("Comenzar mi empresa", "p", function()
		local ok = nameState(st.name)
		if not ok then
			App.toast("error", "El nombre debe tener entre 3 y 24 caracteres.")
			return
		end
		App.request("createCompany", { name = Util.trim(st.name), color = st.color, difficulty = st.difficulty })
	end)
	paintButton(valid)

	local difRow = Ui.new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, List = { dir = "H", gap = 10 } })
	for _, b in difs do
		local holder = Ui.grow(b, { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
		holder.Parent = difRow
	end

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
		Ui.row({ Ui.grow(Ui.text("Nueva empresa", { size = Ui.S.h1, weight = W.bold })), Ui.inline("Una empresa por cuenta en esta etapa", { size = Ui.S.sm, color = T.mut }) }, 10, { Pad = { 18, 18, 6, 18 } }),
		Ui.col({
			Ui.col({ Ui.lbl("Nombre de la empresa"), nameBox, hintLabel }, 8),
			Ui.col({ Ui.lbl("Color de marca"), Ui.row(swatches, 10, { wrap = true }) }, 10),
			Ui.col({ Ui.lbl("Dificultad"), difRow }, 10),
		}, 22, { Pad = 18 }),
		Ui.row({
			Ui.grow(Ui.text("El nombre pasa por el filtro de texto de Roblox y se muestra en el cartel de tu garaje.", { size = Ui.S.sm, color = T.mut })),
			createBtn,
		}, 10, { BackgroundColor3 = Color3.fromHex("#08090D"), BackgroundTransparency = 0.4, Pad = 18 }),
	})

	local container = Ui.new("Frame", {
		Name = "Columnas",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, narrow and -28 or -160, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		List = { dir = narrow and "V" or "H", gap = narrow and 22 or 40, v = "C" },
		Parent = wrap,
	})
	local leftHolder = Ui.grow(left, { Size = UDim2.new(narrow and 1 or 0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y })
	leftHolder.Parent = container
	local maxL = Instance.new("UISizeConstraint")
	maxL.MaxSize = Vector2.new(620, math.huge)
	maxL.Parent = left
	local formHolder = Ui.new("Frame", { Size = UDim2.new(narrow and 1 or 0, narrow and 0 or math.min(760, App.vw * 0.5), 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, { form })
	formHolder.Parent = container
end

return Screen
