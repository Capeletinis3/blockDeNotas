--!strict
--[[
	Inicio y empresas guardadas (renderMenu de la V3): escenario de fondo, tarjetas por ranura,
	continuar, crear, renombrar, eliminar con confirmación y configuración.
	Cada ranura es una empresa con datos independientes; la activa se marca.
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

local renaming: { [string]: string } = {} -- ranura → borrador del nombre

local function slotCard(key: string, s: any): Frame
	local active = App.profile and App.profile.active == key
	if s == nil then
		return Ui.card({
			Ui.row({ Ui.ico("plus", T.mut, T.p3, 40), Ui.grow(Ui.col({ Ui.text("Ranura " .. key .. " · libre", { size = 16, weight = W.bold }), Ui.text("Empezá una empresa nueva desde un garaje inicial.", { size = Ui.S.sm, color = T.mut }) }, 2)) }, 12),
			Ui.row({ Ui.spacer(), Ui.button("Crear empresa", "p", function()
				local nc = App.ui.newCompany
				nc.name, nc.color, nc.logo, nc.difficulty, nc.slot = "", "#7667FF", "pico", "normal", key
				App.go("nueva")
			end, { icon = "plus" }) }),
		}, { bg = Color3.fromHex("#0E1016"), transparency = 0.2, radius = 16, stroke = Color3.fromHex("#3A3F4D"), pad = 18, gap = 12 })
	end
	if s.damaged then
		return Ui.card({
			Ui.row({ Ui.ico("warn", T.re2, Color3.fromHex("#33171A"), 40), Ui.grow(Ui.col({ Ui.text("Ranura " .. key .. " · datos dañados", { size = 16, weight = W.bold, color = T.re2 }), Ui.text(tostring(s.reason), { size = Ui.S.xs, color = T.mut }) }, 2)) }, 12),
			Ui.text("Se conserva tal como estaba guardada; no se puede abrir. Si querés liberar la ranura, eliminala.", { size = Ui.S.xs, color = T.mut }),
			Ui.row({ Ui.spacer(), Ui.button("Eliminar", "d", function()
				App.openDialog("deleteCompany", { slot = key, expected = "BORRAR", name = "la ranura dañada" })
			end, { small = true, icon = "trash" }) }),
		}, { bg = Color3.fromHex("#120D10"), radius = 16, stroke = Color3.fromHex("#663036"), pad = 18, gap = 10 })
	end
	local dif = Catalog.DIFFICULTIES[s.difficulty] or Catalog.DIFFICULTIES.normal
	local nameRow
	if renaming[key] then
		local box = Ui.input(renaming[key], "Nombre de la empresa", function(text: string)
			renaming[key] = text
		end, { onChange = function(text: string)
			renaming[key] = text
		end })
		local save
		save = Ui.button("Guardar nombre", "p", function()
			local r = App.request("renameCompany", { slot = key, name = renaming[key] }, { button = save })
			if r.ok then
				renaming[key] = nil
				App.forceRender()
			end
		end, { small = true })
		nameRow = Ui.col({ box, Ui.row({ save, Ui.button("Cancelar", "q", function()
			renaming[key] = nil
			App.forceRender()
		end, { small = true }) }, 8) }, 8)
	else
		nameRow = Ui.text(s.name, { size = 22, weight = W.heavy })
	end
	local playBtn
	playBtn = Ui.button(active and "Continuar" or "Jugar", "p", function()
		App.ui.route = "juego"
		local r = App.request("selectSlot", { slot = key }, { button = playBtn })
		if r.ok then
			App.go("juego")
		end
	end, { icon = "play" })
	return Ui.card({
		Ui.row({
			Ui.logo(s, 56),
			Ui.grow(Ui.col({
				nameRow,
				Ui.row({ Ui.chip(dif.label, "cn"), Ui.chip(s.sede, "cy"), Ui.chip("Nivel " .. s.level, "cv"), active and Ui.chip("Activa", "cg") or nil }, 6, { wrap = true }),
			}, 6)),
		}, 14),
		Ui.grid({
			(Ui.kv("Dinero", Util.money(s.money))),
			(Ui.kv("Fecha", Util.gameDate(s.day))),
			(Ui.kv("Autos vendidos", tostring(s.sold))),
		}, App.isPhone() and 2 or 3, 64),
		Ui.row({
			playBtn,
			Ui.spacer(),
			Ui.button("Renombrar", "default", function()
				renaming[key] = s.name
				App.forceRender()
			end, { small = true, icon = "pen" }),
			Ui.button("Eliminar", "q", function()
				App.openDialog("deleteCompany", { slot = key, expected = s.name, name = "«" .. s.name .. "»", level = s.level, money = s.money })
			end, { small = true, icon = "trash" }),
		}, 8, { wrap = true }),
	}, { bg = Color3.fromHex("#0E1016"), transparency = 0.05, radius = 16, stroke = active and T.vi or Color3.fromHex("#2A2E39"), pad = 18, gap = 14 })
end

function Screen.build(parent: Instance)
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
		NumberSequenceKeypoint.new(0.75, 0.1),
		NumberSequenceKeypoint.new(1, 0.1),
	})
	grad.Parent = wrap

	local hero = Ui.col({
		Ui.row({ Ui.ico("car", T.tx, T.vi, 44), Ui.lbl("Car Empire Tycoon", T.vi2) }, 12),
		Ui.text("Construí tu imperio automotor", { size = narrow and 28 or 44, weight = W.heavy, lineHeight = 1.0 }),
		Ui.text("Diseñá autos, fabricalos en tu garaje y vendelos en el concesionario. Cada empresa guarda su propio dinero, diseños, fábrica e historial.", { size = 16, color = T.tx2, lineHeight = 1.3 }),
		Ui.card({
			Ui.lbl("Novedades de esta versión", T.ye),
			Ui.text("Investigación, personal, ampliaciones de sede, misiones con recompensa, mercado simulado, estadísticas y varias empresas por cuenta.", { size = Ui.S.sm, color = T.tx2 }),
		}, { bg = Color3.fromHex("#0E1016"), transparency = 0.15, gap = 6 }),
		Ui.row({
			Ui.button("Configuración", "default", function()
				App.openDialog("settings", {})
			end, { small = true, icon = "gear" }),
			Ui.button("Ayuda y controles", "default", function()
				App.openDialog("help", {})
			end, { small = true, icon = "help" }),
		}, 8, { wrap = true }),
	}, 16)

	local cards: { Instance? } = { Ui.row({ Ui.text("Tus empresas", { size = Ui.S.h1, weight = W.bold }), Ui.spacer(), Ui.inline(Catalog.RULES.slots .. " ranuras", { size = Ui.S.sm, color = T.mut }) }, 8) }
	local slots = App.profile and App.profile.slots or {}
	for i = 1, Catalog.RULES.slots do
		local key = tostring(i)
		table.insert(cards, slotCard(key, slots[key]))
	end
	for i = 1, Catalog.RULES.slotsLocked do
		table.insert(cards, Ui.card({
			Ui.row({ Ui.ico("lock", T.ye, Color3.fromHex("#322A14"), 32), Ui.grow(Ui.text("Ranura " .. (Catalog.RULES.slots + i) .. " · función futura", { size = 14, weight = W.bold })) }, 10),
			Ui.text("Ranuras adicionales todavía no están disponibles. No hay compras con dinero real.", { size = Ui.S.xs, color = T.mut }),
		}, { bg = Color3.fromHex("#0E1016"), transparency = 0.3, radius = 16, stroke = Color3.fromHex("#5E4E26"), pad = 14, gap = 6 }))
	end
	local list = Ui.scroll(cards, { name = "Ranuras", gap = 12, pad = { 4, 8, 16, 4 } })
	App.keepScroll(list, "menu")

	if narrow then
		local all = Ui.scroll({ hero, Ui.col(cards, 12) }, { name = "Inicio", gap = 20, pad = { 16, 14, 24, 14 } })
		all.Parent = wrap
		list:Destroy()
		App.keepScroll(all, "menu-narrow")
	else
		hero.AnchorPoint = Vector2.new(0, 0.5)
		hero.Position = UDim2.new(0, 70, 0.5, 0)
		hero.Size = UDim2.new(0.4, -70, 0, 0)
		hero.Parent = wrap
		list.AnchorPoint = Vector2.new(1, 0)
		list.Position = UDim2.new(1, -60, 0, 70)
		list.Size = UDim2.new(0.5, -40, 1, -110)
		list.Parent = wrap
	end
end

return Screen
