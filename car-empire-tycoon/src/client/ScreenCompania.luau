--!strict
-- Compañía (SCREENS.compania de la V3): identidad de la marca, sede (PI/min, producción y alcance), ampliación y resumen.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
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
	Ui.card({
		Ui.lbl("Marca"),
		Ui.row({
			Ui.logo(g.company, 72),
			Ui.grow(Ui.col({
				Ui.fl("Nombre de la empresa"),
				Ui.row({ Ui.grow(nameBox), saveName }, 10),
				Ui.text("El nombre aparece en el HUD, el cartel del taller, el menú y los números de serie nuevos.", { size = Ui.S.xs, color = T.mut }),
			}, 6)),
		}, 16, { wrap = phone }),
		Ui.col({ Ui.fl("Logotipo"), Ui.row(logos, 10, { wrap = true }) }, 6),
		Ui.col({ Ui.fl("Color de marca"), Ui.row(colors, 10, { wrap = true }) }, 6),
	}, { gap = 14, pad = 18, name = "Marca" }).Parent = main

	local caps = g.derived.caps
	local next = Rules.nextSede(g)
	local sedeRows: { Instance? } = {
		Ui.row({ Ui.grow(Ui.lbl("Sede")), Ui.chip("Nivel " .. g.sede .. " · " .. g.derived.sedeName, "cy") }, 10),
		Ui.grid({
			(Ui.kv("Investigación", Util.num(g.derived.piPerMinute, 1) .. " PI/min")),
			(Ui.kv("Producción", caps.lines .. " × " .. Util.num(caps.perLine, 1) .. " autos/min")),
			(Ui.kv("Alcance comercial", "×" .. Util.num(caps.reach, 1))),
			(Ui.kv("Personal", #g.employees .. "/" .. caps.staff)),
		}, phone and 2 or 4),
	}
	if next then
		local checks = Rules.expandChecks(g)
		local ok = true
		local lines: { Instance? } = {}
		for _, c in checks do
			ok = ok and c[1]
			table.insert(lines, Ui.text((c[1] and "✓ " or "✕ ") .. c[2], { size = Ui.S.sm, color = c[1] and T.gr or T.re2 }))
		end
		local expand = Ui.button("Ampliar sede · " .. Util.money(next.cost), "p", function()
			App.openDialog("confirm", {
				title = "¿Ampliar a «" .. next.name .. "»?",
				body = "Cuesta " .. Util.money(next.cost) .. ". La investigación pasa a " .. next.pi .. " PI por minuto, la fábrica a " .. next.lines .. " líneas de " .. next.perLine .. " autos/min de base, el alcance comercial a ×" .. Util.num(next.reach, 1) .. " y el lugar para " .. next.staff .. " empleados. La escena 3D cambia.",
				okLabel = "Ampliar",
				onOk = function()
					App.request("expandSede")
				end,
			})
		end, { disabled = not ok, why = "Faltan requisitos", name = "AmpliarSede" })
		local items: { Instance? } = {
			Ui.text("Próxima sede: " .. next.name, { size = Ui.S.base, weight = W.bold }),
			Ui.text(next.pi .. " PI/min · " .. next.lines .. " líneas × " .. next.perLine .. " autos/min · alcance ×" .. Util.num(next.reach, 1) .. " · " .. next.staff .. " empleados", { size = Ui.S.xs, color = T.mut }),
		}
		for _, l in lines do
			table.insert(items, l)
		end
		table.insert(items, expand)
		table.insert(sedeRows, Ui.card(items, { gap = 6, bg = T.p2, name = "ProximaSede" }))
	else
		table.insert(sedeRows, Ui.note("g", "Tenés la sede máxima: Imperio automotriz."))
	end
	-- Todas las sedes (para planificar)
	local ladder: { Instance? } = { Ui.lbl("Las cinco sedes") }
	for _, s in Catalog.SEDES do
		local cur = s.level == g.sede
		table.insert(ladder, Ui.between((cur and "▶ " or (s.level < g.sede and "✓ " or "")) .. s.name, s.pi .. " PI/min · " .. s.lines .. "×" .. s.perLine .. "/min · ×" .. Util.num(s.reach, 1) .. (s.cost > 0 and (" · " .. Util.money(s.cost)) or ""), { size = Ui.S.xs, color = cur and T.ye or T.mut, leftColor = cur and T.tx or T.mut }))
	end
	table.insert(sedeRows, Ui.col(ladder, 4))
	Ui.card(sedeRows, { gap = 12, pad = 18, name = "Sede" }).Parent = main

	local dif = Catalog.DIFFICULTIES[g.company.difficulty]
	local tot = Rules.finance(g, 100000)
	local summary: { Instance? } = { Ui.lbl("Resumen de la empresa") }
	for _, r in {
		{ "Dificultad", dif.label },
		{ "Fecha", Util.gameDate(g.time.day) },
		{ "Nivel", g.level .. " (" .. g.xp .. "/" .. g.derived.xpNext .. " XP)" },
		{ "Reputación", Util.num(g.reputation, 2) .. " / 5" },
		{ "Diseños", tostring(#g.designs) },
		{ "Unidades fabricadas", Util.num(g.counters.unitsProduced) },
		{ "Unidades vendidas", Util.num(g.counters.unitsSold) },
		{ "Lotes agotados / retirados", Util.num(g.counters.lotsSoldOut or 0) .. " / " .. Util.num(g.counters.lotsRetired or 0) },
		{ "Investigaciones", tostring(#g.research.done) },
		{ "Ingresos por ventas (total)", Util.money(g.counters.revenueTotal or tot.revenue) },
		{ "Margen de lo vendido (total)", Util.money(g.counters.marginTotal or tot.margin) },
	} do
		table.insert(summary, Ui.between(r[1], r[2]))
	end
	Ui.card(summary, { gap = 6 }).Parent = side
	Ui.card({
		Ui.lbl("Datos"),
		g.demo and Ui.text("Demostración: no se guarda ni se exporta.", { size = Ui.S.xs, color = T.ye })
			or Ui.text("Se guarda automáticamente en tu cuenta de Roblox.", { size = Ui.S.xs, color = T.mut }),
		Ui.button("Volver al menú de empresas", "default", function()
			App.leaveToMenu()
		end, { small = true, fill = true, name = "VolverMenu" }),
	}, { gap = 8 }).Parent = side
end

return Screen
