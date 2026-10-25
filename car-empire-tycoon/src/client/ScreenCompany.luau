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
	local phone = App.isPhone()
	local vw, vh = App.vw, App.vh
	local dif = Catalog.DIFFICULTIES[st.difficulty] or Catalog.DIFFICULTIES.normal

	local wrap = Ui.new("ScrollingFrame", {
		Name = "NuevaWrap",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromHex("#06070B"),
		BackgroundTransparency = 0,
		ScrollBarThickness = 4,
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
	App.keepScroll(wrap, "nueva")

	-- Vista previa de la marca (se actualiza mientras se escribe).
	local previewName = Ui.inline(Util.trim(st.name) ~= "" and Util.trim(st.name) or "Tu empresa", { size = 24, weight = W.bold, truncate = true })
	local left = Ui.col({
		Ui.button("Volver a mis empresas", "q", function()
			App.go("menu")
		end, { icon = "left", name = "VolverEmpresas" }),
		Ui.text("Fundá tu empresa", { size = phone and 30 or 43, weight = W.heavy, lineHeight = 1.05 }),
		Ui.text("Arrancás con un garaje pequeño. El nombre y el logo aparecen en el cartel del taller, en el HUD, en tus autos y en la clasificación del servidor.", { size = 16, color = T.tx2, lineHeight = 1.45 }),
		Ui.card1({
			Ui.logo({ color = st.color, logo = st.logo }, 80),
			Ui.grow(Ui.col({
				Ui.lbl("Vista previa"),
				previewName,
				Ui.text("Garaje inicial · " .. dif.label .. " · " .. Util.money(dif.money) .. " iniciales", { size = Ui.S.sm, color = T.mut }),
			}, 6)),
		}, { dir = "H", v = "C", gap = 18, pad = 18, bg = Color3.fromHex("#0E1016"), transparency = 0.12, name = "VistaPrevia" }),
	}, 18, { Name = "Presentacion", v = "C" })

	local createBtn: any = nil
	local hintLabel = Ui.text("", { size = Ui.S.xs, weight = W.bold })
	local function refresh()
		local ok, h = Screen.nameState(st.name)
		hintLabel.Text = h
		hintLabel.TextColor3 = ok and T.gr or T.re2
		previewName.Text = Util.trim(st.name) ~= "" and Util.trim(st.name) or "Tu empresa"
		if createBtn then
			Ui.setEnabled(createBtn, ok, string.gsub(h, "^✕ ", ""))
		end
	end
	local nameBox = Ui.input(st.name, "Por ejemplo: Ruta Norte Motors", function(text: string, enter: boolean?)
		st.name = text
		refresh()
		if enter and createBtn and Ui.isEnabled(createBtn) then
			Screen.create(createBtn)
		end
	end, {
		size = 17,
		height = 52,
		name = "NombreEmpresa",
		onChange = function(text: string)
			st.name = text
			refresh()
		end,
	})

	local logos = {}
	for _, l in Catalog.LOGOS do
		local selected = st.logo == l[1]
		local b = Ui.opt("", selected, function()
			st.logo = l[1]
			App.forceRender()
		end, { name = "Logo_" .. l[1], fill = true, height = phone and 40 or 88 })
		local ic = Ui.icon("logo_" .. l[1], 26, selected and T.tx or T.tx2)
		ic.AnchorPoint = Vector2.new(0.5, 0.5)
		ic.Position = UDim2.fromScale(0.5, 0.5)
		ic.Parent = b
		local pad = b:FindFirstChildOfClass("UIPadding")
		if pad then
			pad:Destroy()
		end
		table.insert(logos, b)
	end

	local swatches: { Instance? } = {}
	for _, c in Catalog.BRAND_COLORS do
		table.insert(swatches, Ui.swatch(c[1], st.color == c[1], function()
			st.color = c[1]
			App.forceRender()
		end, 42))
	end
	table.insert(swatches, Ui.inline(Catalog.colorName(Catalog.BRAND_COLORS, st.color) or "", { size = Ui.S.sm, color = T.mut }))

	local difs = {}
	for _, id in Catalog.DIFFICULTY_ORDER do
		local d = Catalog.DIFFICULTIES[id]
		local selected = st.difficulty == id
		local dotsColor = d.dots == 1 and T.gr or (d.dots == 2 and T.ye or T.re2)
		local b = Ui.opt("", selected, function()
			st.difficulty = id
			App.forceRender()
		end, { name = "Dificultad_" .. id, fill = true, autoY = true, height = 0, pad = 12 })
		Ui.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6), Parent = b })
		Ui.row({ Ui.grow(Ui.text(d.label, { size = 15, weight = W.bold })), Ui.inline(string.rep("●", d.dots) .. string.rep("○", 3 - d.dots), { size = Ui.S.xs, color = dotsColor }) }, 6).Parent = b
		Ui.text(d.desc, { size = Ui.S.xs, color = T.mut, lineHeight = 1.35, weight = W.med }).Parent = b
		Ui.text(Util.money(d.money) .. " iniciales", { size = Ui.S.sm, weight = W.bold, color = T.gr }).Parent = b
		table.insert(difs, b)
	end

	createBtn = Ui.button("Comenzar mi empresa", "p", function()
		Screen.create(createBtn)
	end, { name = "Comenzar", kbd = "Enter" })
	refresh()

	local form = Ui.card1({
		Ui.row({ Ui.grow(Ui.text("Nueva empresa", { size = 21, weight = W.bold })), Ui.inline("Ranura " .. st.slot .. " de " .. Catalog.RULES.slots, { size = Ui.S.sm, color = T.mut }) }, 10, { Pad = { 18, 18, 6, 18 } }),
		Ui.col({
			Ui.col({ Ui.lbl("Nombre de la empresa"), nameBox, hintLabel }, 8),
			Ui.col({ Ui.lbl("Logotipo"), Ui.grid(logos, phone and 4 or 8, nil, 10) }, 10),
			Ui.col({ Ui.lbl("Color de marca"), Ui.row(swatches, 10, { wrap = true }) }, 10),
			Ui.col({ Ui.lbl("Dificultad"), Ui.grid(difs, phone and 1 or 3, nil, 10) }, 10),
		}, 22, { Pad = 18 }),
		Ui.new("Frame", { Name = "Borde", Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = T.line3, BackgroundTransparency = 0 }),
		Ui.row({
			Ui.grow(Ui.text("Podés renombrarla más adelante.", { size = Ui.S.sm, color = T.mut })),
			Ui.button("Cancelar", "default", function()
				App.go("menu")
			end),
			createBtn,
		}, 10, { BackgroundColor3 = Color3.fromHex("#080A0F"), BackgroundTransparency = 0.4, Pad = 18, wrap = phone }),
	}, { bg = Color3.fromHex("#0E1016"), transparency = 0.05, pad = 0, gap = 0, clip = true, name = "NuevaEmpresa" })

	if phone then
		Ui.new("UIPadding", { PaddingTop = UDim.new(0, 70), PaddingBottom = UDim.new(0, 80), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), Parent = wrap })
		Ui.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 22), Parent = wrap })
		left.Parent = wrap
		form.Parent = wrap
	else
		local avail = vw - 160 - 40
		local rightW = math.min(820, math.max(0, avail))
		local lw = math.max(0, avail - rightW)
		local h = math.max(0, vh - 200)
		left.Position = UDim2.fromOffset(80, 110)
		left.Size = UDim2.fromOffset(math.min(620, lw), h)
		left.Parent = wrap
		local holder = Ui.col({ form }, 0, { Name = "Formulario", v = "C" })
		holder.Position = UDim2.fromOffset(80 + lw + 40, 110)
		holder.Size = UDim2.fromOffset(rightW, h)
		holder.Parent = wrap
	end
end

function Screen.create(btn: any)
	local st = App.ui.newCompany
	local ok, h = Screen.nameState(st.name)
	if not ok then
		App.toast("error", (string.gsub(h, "^✕ ", "")))
		return
	end
	local r = App.request("createCompany", { slot = st.slot, name = Util.trim(st.name), color = st.color, logo = st.logo, difficulty = st.difficulty }, { button = btn })
	if r.ok then
		st.name = ""
		App.ui.enteringGame = true
		App.go("juego")
	end
end

return Screen
