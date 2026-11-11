--!strict
-- Compañía (SCREENS.compania de la V3): instalaciones (lista + detalle), expansión, identidad de la marca y resumen.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local FacilitiesView = require(script.Parent.FacilitiesView)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Compañía",
	icon = "building",
	color = Color3.fromHex("#C9CED8"),
	bg = Color3.fromHex("#22252D"),
}

function Screen.head(_g: any): { Instance }
	return {}
end

local function nameValid(text: string): boolean
	local n = utf8.len(Util.trim(text)) or 0
	return n >= 3 and n <= 24
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local phone = App.isPhone()
	local draft = App.ui.coName
	if draft == nil then
		draft = g.company.name
	end
	local saveName: TextButton
	local nameBox = Ui.input(draft, "Nombre de la empresa", function(text: string)
		App.ui.coName = text
	end, {
		name = "NombreEmpresa",
		invalid = not nameValid(draft),
		onChange = function(text: string)
			App.ui.coName = text
			local ok = nameValid(text) and Util.trim(text) ~= g.company.name
			Ui.setEnabled(saveName, ok, not nameValid(text) and "Entre 3 y 24 caracteres" or "Sin cambios")
		end,
	})
	saveName = Ui.button("Guardar nombre", "p", function()
		local r = App.request("renameCompany", { slot = App.profile.active, name = App.ui.coName or g.company.name }, { button = saveName })
		if r.ok then
			App.ui.coName = nil
		end
	end, {
		small = true,
		name = "GuardarNombre",
		disabled = not nameValid(draft) or Util.trim(draft) == g.company.name,
		why = not nameValid(draft) and "Entre 3 y 24 caracteres" or "Sin cambios",
	})
	local logos = {}
	for _, l in Catalog.LOGOS do
		local sel = g.company.logo == l[1]
		local b = Ui.opt("", sel, function()
			App.request("setIdentity", { logo = l[1] })
		end, { width = 46, height = 46, pad = { 0, 0 }, name = "Logo_" .. l[1] })
		local ic = Ui.icon("logo_" .. l[1], 22, sel and T.tx or T.tx2)
		ic.AnchorPoint = Vector2.new(0.5, 0.5)
		ic.Position = UDim2.fromScale(0.5, 0.5)
		local pad = b:FindFirstChildOfClass("UIPadding")
		if pad then
			pad:Destroy()
		end
		ic.Parent = b
		table.insert(logos, b)
	end
	local colors = {}
	for _, c in Catalog.BRAND_COLORS do
		table.insert(colors, Ui.swatch(c[1], g.company.color == c[1], function()
			App.request("setIdentity", { color = c[1] })
		end))
	end
	local marca = Ui.card({
		Ui.lbl("Marca"),
		Ui.row({
			Ui.logo(g.company, 72),
			Ui.grow(Ui.col({
				Ui.fl("Nombre de la empresa"),
				Ui.row({ Ui.grow(nameBox), saveName }, 10),
				Ui.text("El nombre aparece en el HUD, el cartel del taller, el menú y los números de serie nuevos.", { size = Ui.S.xs, color = T.mut }),
			}, 6)),
		}, 16, { wrap = phone }),
		Ui.col({ Ui.fl("Símbolo corporativo"), Ui.row(logos, 10, { wrap = true }) }, 6),
		Ui.col({ Ui.fl("Color corporativo"), Ui.row(colors, 10, { wrap = true }) }, 6),
		(function(): Instance?
			local opts = {}
			for _, d in g.designs do
				if not d.template then
					table.insert(opts, { d.id, d.name })
				end
			end
			if #opts == 0 then
				return Ui.text("Auto exhibido en el menú: el sedán de 1970 hasta que guardes un diseño.", { size = Ui.S.xs, color = T.mut })
			end
			return Ui.selectF("Auto exhibido en el menú principal", g.showcase or opts[#opts][1], opts, function(v: any)
				App.request("setShowcase", { designId = v })
			end, { height = 34, name = "AutoExhibido" })
		end)(),
	}, { gap = 14, pad = 18, name = "Marca" })
	marca.Parent = main
	marca.LayoutOrder = 1e7 -- la identidad de la marca va al final; primero las instalaciones

	-- Instalaciones: lista + detalle con la comparación antes → después (FacilitiesView).
	FacilitiesView.build(g, phone).Parent = main

	-- Expansión global: metas grandes después del Imperio automotriz.
	local E = Catalog.EXPANSION
	local lvl = Rules.expansion(g)
	local exRows: { Instance? } = {
		Ui.row({ Ui.grow(Ui.lbl("Expansión internacional")), Ui.chip(lvl .. "/" .. #E.regions .. " países", lvl > 0 and "cg" or "cn") }, 10),
		Ui.text("Cada país abre mercados nuevos: <b>+" .. Util.round(E.demand * 100) .. " % de demanda</b> en todos los tipos (repartida con las mismas reglas entre vos y los rivales) y <b>+" .. Util.round(E.line * 100) .. " % de autos por minuto</b> en cada línea (capacidad global de la empresa). Las campañas corporativas cuestan más con cada país. El mapa mundial llegará en una etapa visual posterior.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.45 }),
		lvl > 0 and Ui.between("Mercado mundial", "×" .. Util.num(Rules.marketFactor(g), 2), { size = Ui.S.xs }) or nil,
	}
	local nx = Rules.nextExpansion(g)
	local opened = Rules.openedCountries(g)
	local ok = nx ~= nil
	if nx then
		table.insert(exRows, Ui.text("Próximo país (el que elijas): " .. Util.money(nx.cost), { size = Ui.S.sm, weight = W.bold }))
		for _, c in Rules.expansionChecks(g) do
			ok = ok and c[1]
			table.insert(exRows, Ui.text((c[1] and "✓ " or "✕ ") .. c[2], { size = Ui.S.sm, color = c[1] and T.gr or T.re2 }))
		end
	end
	if nx or lvl > 0 then
		local tiles = {}
		for _, c in E.countries do
			local isOpen = table.find(opened, c.id) ~= nil
			table.insert(tiles, Ui.card({
				Ui.row({ Ui.grow(Ui.text(c.name, { size = Ui.S.sm, weight = W.bold })), isOpen and Ui.chip("Presente", "cg") or nil }, 6),
				(not isOpen and nx) and Ui.button("Abrir", "p", function()
					App.openDialog("confirm", {
						title = "¿Expandirte a " .. c.name .. "?",
						body = "Cuesta " .. Util.money(nx.cost) .. " (no se devuelve). La demanda de todos los tipos pasa a ×" .. Util.num(1 + E.demand * nx.level, 2) .. " y cada línea fabrica " .. Util.round(E.line * 100) .. " % más. Las campañas corporativas cuestan más.",
						okLabel = "Expandirme",
						onOk = function()
							App.request("expandGlobal", { country = c.id })
						end,
					})
				end, { small = true, fill = true, disabled = not ok, why = "Faltan requisitos", name = "Pais_" .. c.id }) or nil,
			}, { gap = 6, name = "Pais_" .. c.id .. "_tarjeta" }))
		end
		table.insert(exRows, Ui.grid(tiles, phone and 2 or 5, nil, 8))
	end
	if not nx and lvl >= #E.regions then
		table.insert(exRows, Ui.note("g", "Tu marca está en todo el mundo."))
	elseif not nx then
		table.insert(exRows, Ui.text("Se abre con las oficinas centrales de nivel 5 (Imperio automotriz).", { size = Ui.S.sm, color = T.mut }))
	end
	Ui.card(exRows, { gap = 8, pad = 18, name = "Expansion" }).Parent = main

	local tot = Rules.finance(g, 100000)
	local summary: { Instance? } = { Ui.lbl("Resumen de la empresa") }
	for _, r in {
		{ "Fecha", Util.fullDate(g.time.day, g.time.minute) .. (Rules.extraYears(g) > 0 and (" · año comercial extra " .. Rules.extraYears(g)) or "") },
		{ "Nivel", g.level .. " (" .. g.xp .. "/" .. g.derived.xpNext .. " XP)" },
		{ "Reputación", Util.num(g.reputation, 2) .. " / 5" },
		{ "Diseños", tostring(#g.designs) },
		{ "Unidades fabricadas", Util.num(g.counters.unitsProduced) },
		{ "Unidades vendidas", Util.num(g.counters.unitsSold) },
		{ "Lotes agotados / retirados", Util.num(g.counters.lotsSoldOut or 0) .. " / " .. Util.num(g.counters.lotsRetired or 0) },
		{ "Investigaciones", tostring(#g.research.done) },
		{ "Ingresos por ventas (total)", Util.money(g.counters.revenueTotal or tot.revenue) },
		{ "Margen de lo vendido (total)", Util.money(g.counters.marginTotal or tot.margin) },
		{ "Deudas", Util.money(Rules.debt(g)) },
	} do
		table.insert(summary, Ui.between(r[1], r[2]))
	end
	Ui.card(summary, { gap = 6 }).Parent = side
	local saveBtn: TextButton
	saveBtn = Ui.button("Guardar ahora", "default", function()
		App.request("saveNow", nil, { button = saveBtn })
	end, { small = true, fill = true, name = "GuardarAhora" })
	Ui.card({
		Ui.lbl("Datos"),
		g.demo and Ui.text("Demostración: no se guarda ni se exporta.", { size = Ui.S.xs, color = T.ye })
			or Ui.text("Se guarda automáticamente en tu cuenta de Roblox (cada 45 s, al salir y al volver al menú)." .. (App.payload and App.payload.lastSaved and (" Último guardado: hace " .. math.max(0, os.time() - App.payload.lastSaved) .. " s.") or ""), { size = Ui.S.xs, color = T.mut }),
		(not g.demo) and saveBtn or nil,
		Ui.button(g.demo and "Volver al menú de empresas" or "Guardar y volver al menú", "default", function()
			App.leaveToMenu()
		end, { small = true, fill = true, name = "VolverMenu" }),
	}, { gap = 8 }).Parent = side
end

return Screen
