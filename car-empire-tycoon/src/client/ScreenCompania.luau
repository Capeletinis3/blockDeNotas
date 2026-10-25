--!strict
-- Compañía (SCREENS.compania de la V3): identidad de la marca, sede y capacidades, ampliación y resumen.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Factory = require(script.Parent.ScreenFactory)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Compañía",
	icon = "building",
	color = Color3.fromHex("#C9CED8"),
	bg = Color3.fromHex("#22252D"),
}

function Screen.head(g: any): { Instance }
	return { Ui.chip("Sede " .. g.sede .. " · " .. g.derived.sedeName, "cy") }
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local draft = App.ui.coName
	if draft == nil then
		draft = g.company.name
	end
	local nameBox = Ui.input(draft, "Nombre de la empresa", function(text: string)
		App.ui.coName = text
	end, { onChange = function(text: string)
		App.ui.coName = text
	end })
	local saveName
	saveName = Ui.button("Guardar nombre", "p", function()
		local r = App.request("renameCompany", { slot = App.profile.active, name = App.ui.coName or g.company.name }, { button = saveName })
		if r.ok then
			App.ui.coName = nil
		end
	end, { small = true })
	local logos = {}
	for _, l in Catalog.LOGOS do
		local sel = g.company.logo == l[1]
		local b = Ui.new("TextButton", {
			Name = "Logo_" .. l[1], Text = "", BackgroundColor3 = sel and Color3.fromHex("#1E1B3D") or T.input, BackgroundTransparency = 0,
			Size = UDim2.fromOffset(46, 46), Corner = 9, Stroke = sel and { T.vi, 2 } or T.line,
		}, { Ui.icon("logo_" .. l[1], 24, sel and T.tx or T.tx2) })
		local ic = b:FindFirstChild("Icono") :: Frame
		ic.AnchorPoint = Vector2.new(0.5, 0.5)
		ic.Position = UDim2.fromScale(0.5, 0.5)
		b.Activated:Connect(function()
			App.request("setIdentity", { logo = l[1] })
		end)
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
		Ui.row({ Ui.logo(g.company, 72), Ui.grow(Ui.col({ Ui.text("Nombre de la empresa", { size = Ui.S.sm, color = T.tx2, weight = W.semi }), Ui.row({ Ui.grow(nameBox), saveName }, 8) }, 6)) }, 16),
		Ui.text("Logotipo", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
		Ui.row(logos, 8, { wrap = true }),
		Ui.text("Color de marca", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
		Ui.row(colors, 8, { wrap = true }),
		Ui.text("El nombre pasa por el filtro de Roblox y cambia en el cartel del garaje, el HUD y las unidades nuevas.", { size = Ui.S.xs, color = T.mut }),
	}, { gap = 10, pad = 18 }).Parent = main

	local caps = g.derived.caps
	local next = Rules.nextSede(g)
	local sedeRows: { Instance? } = {
		Ui.row({ Ui.lbl("Sede y capacidad"), Ui.spacer(), Ui.chip("Nivel " .. g.sede .. " · " .. g.derived.sedeName, "cy") }, 8),
		Ui.grid({
			(Ui.kv("Líneas de producción", tostring(caps.lines))),
			(Ui.kv("Almacén", g.derived.warehouseUsed .. "/" .. caps.warehouse)),
			(Ui.kv("Salón", g.derived.showroomUsed .. "/" .. caps.showroom)),
			(Ui.kv("Personal", #g.employees .. "/" .. caps.staff)),
			(Ui.kv("Depósito", g.derived.matsUsed .. "/" .. caps.mats)),
			(Ui.kv("Estaciones (nivel máx.)", tostring(Rules.maxStationLevel(g)))),
		}, App.isPhone() and 2 or 3, 64),
		Ui.text("Almacén: " .. Factory.warehouseText(g) .. ".", { size = Ui.S.xs, color = T.mut }),
	}
	if next then
		local checks = Rules.expandChecks(g)
		local ok = true
		local lines: { Instance? } = {}
		for _, c in checks do
			ok = ok and c[1]
			table.insert(lines, Ui.text((c[1] and "✓ " or "✕ ") .. c[2], { size = Ui.S.sm, color = c[1] and T.gr or T.re2 }))
		end
		local expand
		expand = Ui.button("Ampliar a «" .. next.name .. "» · " .. Util.money(next.cost), "p", function()
			App.openDialog("confirm", {
				title = "¿Ampliar a «" .. next.name .. "»?",
				body = "Cuesta " .. Util.money(next.cost) .. ". Obtenés " .. next.lines .. " líneas, almacén " .. next.warehouse .. ", salón " .. next.showroom .. ", depósito " .. next.mats .. " y lugar para " .. next.staff .. " empleados. Tu partida se conserva: el garaje crece con las nuevas líneas.",
				okLabel = "Ampliar",
				onOk = function()
					App.request("expandSede")
				end,
			})
		end, { disabled = not ok, why = "Faltan requisitos" })
		table.insert(sedeRows, Ui.card({
			Ui.text("Próxima sede: " .. next.name, { size = 15, weight = W.bold }),
			Ui.text(next.lines .. " líneas · almacén " .. next.warehouse .. " · salón " .. next.showroom .. " · " .. next.staff .. " empleados · depósito " .. next.mats, { size = Ui.S.xs, color = T.mut }),
			Ui.col(lines, 2),
			expand,
		}, { gap = 6, bg = T.p2 }))
	else
		table.insert(sedeRows, Ui.note("g", "Tenés la sede máxima."))
	end
	Ui.card(sedeRows, { gap = 10, pad = 18 }).Parent = main

	local dif = Catalog.DIFFICULTIES[g.company.difficulty]
	local summary: { Instance? } = { Ui.lbl("Resumen de la empresa") }
	for _, r in {
		{ "Dificultad", dif.label },
		{ "Fecha", Util.gameDate(g.time.day) },
		{ "Nivel", g.level .. " (" .. g.xp .. "/" .. g.derived.xpNext .. " XP)" },
		{ "Reputación", Util.num(g.reputation, 2) .. " / 5" },
		{ "Gemas", tostring(g.gems) },
		{ "Diseños", tostring(#g.designs) },
		{ "Unidades fabricadas", tostring(g.counters.unitsProduced) },
		{ "Autos vendidos", tostring(g.counters.unitsSold) },
		{ "Ingresos totales", Util.money(g.counters.revenueTotal or 0) },
		{ "Investigaciones", tostring(#g.research.done) },
	} do
		table.insert(summary, Ui.line(r[1], r[2], { leftColor = T.mut }))
	end
	Ui.card(summary, { gap = 0 }).Parent = side
	Ui.card({
		Ui.lbl("Empresas"),
		Ui.text("Cada empresa tiene su propio dinero, diseños, fábrica e historial. Volver al menú guarda esta empresa y te deja elegir otra.", { size = Ui.S.xs, color = T.mut }),
		Ui.button("Volver al menú de empresas", "default", function()
			App.guardEditor(function()
				App.request("leaveCompany")
				App.go("menu")
			end)
		end, { small = true, icon = "left" }),
	}, { gap = 8 }).Parent = side
end

return Screen
