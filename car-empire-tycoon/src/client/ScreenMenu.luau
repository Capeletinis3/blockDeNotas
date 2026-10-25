--!strict
--[[
	Menú de empresas (renderMenu de la V3): marca, titular, novedades con el próximo evento,
	demostraciones, ranuras (ocupadas, libres y bloqueadas) y configuración.
	Adaptaciones: no hay exportar/importar (el guardado es de la cuenta de Roblox).
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

Screen.NEWS = {
	version = "Actualización 1.3 · «Línea de montaje»",
	title = "Fábrica conectada y mercado simulado",
	body = "Ahora tus diseños se fabrican de verdad: las órdenes consumen materiales, ocupan el almacén y las unidades llegan al concesionario. También se sumaron catálogos de piezas por categoría y un mercado con subastas simuladas.",
	event = "Semana de los eléctricos (evento de demostración)",
	when = "Comienza el día 30 de cada partida",
}

local rename = { slot = nil :: string?, draft = "", err = "" }
function Screen.startRename(key: string)
	local s = App.profile and App.profile.slots[key]
	rename.slot, rename.draft, rename.err = key, s and s.name or "", ""
	App.forceRender()
end
function Screen.cancelRename()
	rename.slot = nil
	App.forceRender()
end

local function firstSlot(): string?
	local slots = App.profile and App.profile.slots or {}
	for i = 1, Catalog.RULES.slots do
		local s = slots[tostring(i)]
		if s and not s.damaged then
			return tostring(i)
		end
	end
	return nil
end
Screen.firstSlot = firstSlot

function Screen.play(key: string, btn: any?)
	local r = App.request("selectSlot", { slot = key }, { button = btn })
	if r.ok then
		App.ui.enteringGame = true
		App.go("juego")
	end
end

function Screen.newCompany(key: string)
	local nc = App.ui.newCompany
	nc.name, nc.color, nc.logo, nc.difficulty, nc.slot = "", "#7667FF", "pico", "normal", key
	App.go("nueva")
end

local function playedText(sec: number): string
	local m = math.floor(sec / 60 + 0.5)
	return (m >= 60 and (math.floor(m / 60) .. " h ") or "") .. (m % 60) .. " min"
end
local function lastText(t: number?): string
	if not t or t <= 0 then
		return "—"
	end
	-- os.date en el cliente usa la zona horaria del dispositivo, como la V3.
	local d = os.date("*t", t) :: any
	local h = d.hour % 12
	return string.format("%02d/%02d/%04d %d:%02d %s", d.day, d.month, d.year, h == 0 and 12 or h, d.min, d.hour < 12 and "a. m." or "p. m.")
end

local function slotCard(key: string, s: any): Frame
	if s.damaged then
		return Ui.card({
			Ui.row({ Ui.ico("warn", T.re2, T.re, 56, { alpha = 0.14, radius = 14, iconSize = 24 }), Ui.grow(Ui.col({ Ui.text("Ranura " .. key .. " · datos dañados", { size = 19, weight = W.bold, color = T.re2 }), Ui.text(tostring(s.reason), { size = Ui.S.sm, color = T.mut }) }, 4)) }, 16),
			Ui.text("Se conserva tal como estaba guardada y no se puede abrir. Si querés liberar la ranura, eliminala.", { size = Ui.S.xs, color = T.mut }),
			Ui.row({ Ui.button("Eliminar", "q", function()
				App.openDialog("deleteCompany", { slot = key, expected = "BORRAR", name = "la ranura dañada", damaged = true })
			end, { small = true, icon = "trash", fg = T.re2 }) }, 8),
		}, { bg = Ui.hex("#0E1016"), transparency = 0.08, radius = 16, stroke = Ui.hex("#663036"), pad = 18, gap = 14, name = "Ranura_" .. key })
	end
	local t = s.tutorialDone or 0
	local tut = s.tutorialSkipped and "Tutorial omitido" or (t >= 5 and "✓ Tutorial completo" or ("Tutorial · paso " .. (t + 1) .. " de 5"))
	local nameNode: Instance
	if rename.slot == key then
		local save
		local box = Ui.input(rename.draft, "Nuevo nombre", function(text: string, enter: boolean?)
			rename.draft = text
			if enter and save then
				save:SetAttribute("_enter", true)
			end
		end, { onChange = function(text: string)
			rename.draft = text
		end, name = "NombreRanura", flex = true })
		save = Ui.button("Guardar", "p", function()
			local r = App.request("renameCompany", { slot = key, name = rename.draft }, { button = save })
			if r.ok then
				rename.slot = nil
				App.forceRender()
			else
				rename.err = r.msg or ""
				App.forceRender()
			end
		end, { small = true, name = "GuardarNombre" })
		nameNode = Ui.col({
			Ui.row({ box, save, Ui.button("Cancelar", "default", Screen.cancelRename, { small = true }) }, 10),
			rename.err ~= "" and Ui.text(rename.err, { size = Ui.S.xs, color = T.re2 }) or nil,
		}, 4)
	else
		nameNode = Ui.text(s.name, { size = 19, weight = W.bold, name = "NombreEmpresa" })
	end
	local first = firstSlot() == key
	local play
	play = Ui.button("Continuar", "p", function()
		Screen.play(key, play)
	end, { name = "Continuar_" .. key, kbd = first and "Enter" or nil })
	local function stat(label: string, value: string, color: Color3?)
		return Ui.col({ Ui.text(label, { size = Ui.S.xs, color = T.mut }), Ui.text(value, { size = Ui.S.sm, weight = W.bold, color = color }) }, 2)
	end
	return Ui.card({
		Ui.row({
			Ui.logo(s, 56),
			Ui.grow(Ui.col({ nameNode, Ui.text(tostring(s.sede) .. " · Ranura " .. key .. " · Nivel " .. s.level, { size = Ui.S.sm, color = T.mut }) }, 4)),
			Ui.chip(tut, t >= 5 and "cg" or "cy"),
		}, 16),
		Ui.card({
			Ui.grid({
				stat("Fecha en la partida", Util.gameDate(s.day)),
				stat("Dinero", Util.money(s.money), T.gr),
				stat("Tiempo jugado", playedText(s.playedSeconds or 0)),
				stat("Última sesión", lastText(s.lastPlayed)),
			}, App.isPhone() and 2 or 4, nil, 10),
		}, { bg = T.bg, transparency = 0.4, stroke = T.sep, pad = { 12, 14 }, gap = 0 }),
		Ui.row({
			Ui.button("Renombrar", "q", function()
				Screen.startRename(key)
			end, { small = true, icon = "pen" }),
			Ui.button("Eliminar", "q", function()
				App.openDialog("confirm", {
					title = "¿Eliminar «" .. s.name .. "»?",
					body = "Se borra solo la <b>ranura " .. key .. "</b> (nivel " .. s.level .. ", " .. Util.money(s.money) .. "). Las otras empresas no se tocan. No se puede deshacer.",
					okLabel = "Eliminar definitivamente",
					danger = true,
					onOk = function()
						App.request("deleteCompany", { slot = key, confirm = s.name })
					end,
				})
			end, { small = true, icon = "trash", fg = T.re2, name = "Eliminar_" .. key }),
			Ui.spacer(),
			play,
		}, 10, { wrap = App.isPhone() }),
	}, { bg = Ui.hex("#0E1016"), transparency = 0.08, radius = 16, stroke = Ui.hex("#2A2E39"), pad = 18, gap = 14, name = "Ranura_" .. key })
end

local function emptySlot(key: string): Frame
	local plus = Ui.new("Frame", { Name = "Mas", Size = UDim2.fromOffset(56, 56), BackgroundTransparency = 1, Corner = 14, Stroke = { Ui.hex("#4A4F5C"), 2 } }, {
		(function()
			local ic = Ui.icon("plus", 24, Ui.hex("#B4BAC6"))
			ic.AnchorPoint = Vector2.new(0.5, 0.5)
			ic.Position = UDim2.fromScale(0.5, 0.5)
			return ic
		end)(),
	})
	return Ui.card({
		plus,
		Ui.grow(Ui.col({
			Ui.text("Nueva empresa", { size = 17, weight = W.bold, align = "C", color = T.mut }),
			Ui.text("Ranura " .. key .. " libre. Empezás con un garaje, dinero inicial según la dificultad y una idea.", { size = Ui.S.sm, color = T.mut, align = "C" }),
		}, 4)),
		Ui.button("Crear", "p", function()
			Screen.newCompany(key)
		end, { name = "Crear_" .. key }),
	}, { dir = "H", v = "C", gap = 16, bg = Ui.hex("#0E1016"), transparency = 0.25, radius = 16, stroke = Ui.hex("#3A3F4D"), pad = 18, name = "Ranura_" .. key })
end

local function lockedSlot(n: number, anyLevel10: boolean): Frame
	return Ui.card({
		Ui.ico("lock", T.ye, T.ye, 32, { alpha = 0.12, iconSize = 17 }),
		Ui.grow(Ui.col({
			Ui.text("Ranura " .. n .. (anyLevel10 and " · próximamente" or " bloqueada"), { size = Ui.S.sm, weight = W.bold }),
			Ui.text(Catalog.RULES.slotUnlock or "Se habilitan al llegar al nivel 10 con cualquier empresa. No hay compras con dinero real.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }),
		}, 2)),
	}, { dir = "H", v = "C", gap = 10, bg = Ui.hex("#0E1016"), transparency = 0.08, radius = 16, stroke = { T.ye, 1, 0.65 }, pad = { 14, 16 }, name = "Bloqueada_" .. n })
end

function Screen.build(parent: Instance)
	local phone = App.isPhone()
	local vw, vh = App.vw, App.vh
	local slots = App.profile and App.profile.slots or {}
	local used, anyLevel10 = 0, false
	for _, s in slots do
		used += 1
		if not s.damaged and (s.level or 0) >= 10 then
			anyLevel10 = true
		end
	end

	-- .menu-wrap: degradado horizontal sobre la escena 3D
	local wrap = Ui.new("ScrollingFrame", {
		Name = "MenuWrap",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Ui.hex("#06070B"),
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
	App.keepScroll(wrap, "menu")

	-- Columna izquierda: marca, titular, novedades y demostraciones.
	local brand = Ui.row({
		Ui.new("Frame", { Name = "LogoJuego", Size = UDim2.fromOffset(42, 42), BackgroundColor3 = T.p1, BackgroundTransparency = 0, Corner = 9, Stroke = T.vi }, {
			(function()
				local ic = Ui.icon("car", 22, T.tx)
				ic.AnchorPoint = Vector2.new(0.5, 0.5)
				ic.Position = UDim2.fromScale(0.5, 0.5)
				return ic
			end)(),
		}),
		Ui.col({
			Ui.inline("C A R   E M P I R E", { size = 15, weight = W.bold }),
			Ui.inline("T  Y  C  O  O  N", { size = 11, weight = W.bold, color = T.vi2 }),
		}, 0, { Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.XY }),
	}, 10)
	local N = Screen.NEWS
	local news = Ui.card1({
		Ui.col({
			Ui.chip(N.version, "cv"),
			Ui.text(N.title, { size = 17, weight = W.bold }),
			Ui.text(N.body, { size = Ui.S.sm, color = T.tx2, lineHeight = 1.45 }),
			Ui.button("Ver novedades", "default", function()
				App.openDialog("news", {})
			end, { small = true, icon = "right", iconAfter = true }),
		}, 10, { Pad = 18 }),
		Ui.new("Frame", { Name = "Separador", Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = T.line2, BackgroundTransparency = 0 }),
		Ui.new("Frame", { Name = "Evento", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = T.vi, Alpha = 0.07, Pad = 14, List = { dir = "H", gap = 10, v = "C" } }, {
			Ui.ico("cal", T.ye, T.ye, 32, { alpha = 0.14, iconSize = 17 }),
			Ui.grow(Ui.col({ Ui.lbl("Próximo evento", nil, 10), Ui.text(N.event, { size = Ui.S.sm, weight = W.bold }) }, 2)),
			Ui.inline(N.when, { size = Ui.S.sm, color = T.ye, weight = W.bold }),
		}),
	}, { bg = Ui.hex("#0E1016"), transparency = 0.1, pad = 0, gap = 0, clip = true, name = "Novedades" })
	local demos = Ui.col({
		Ui.lbl("Demostraciones (no modifican tus partidas)"),
		Ui.row({
			Ui.button("Tutorial", "default", function()
				App.request("playDemo", { kind = "tutorial" })
				App.ui.enteringGame = true
			end, { small = true, name = "Demo_tutorial" }),
			Ui.button("Empresa en funcionamiento", "default", function()
				App.request("playDemo", { kind = "operacion" })
				App.ui.enteringGame = true
			end, { small = true, name = "Demo_operacion" }),
			Ui.button("Fábrica avanzada", "default", function()
				App.request("playDemo", { kind = "avanzada" })
				App.ui.enteringGame = true
			end, { small = true, name = "Demo_avanzada" }),
		}, 10, { wrap = true }),
	}, 8)
	local leftW = phone and (vw - 28) or 0
	local left = Ui.col({
		brand,
		Ui.text("Construí tu imperio automotor", { size = phone and 30 or 51, weight = W.heavy, lineHeight = 1.04, name = "Titular" }),
		Ui.text("Desde tu primer garaje hasta una marca de autos reconocida en todo el mundo.", { size = 18, color = T.tx2, lineHeight = 1.45 }),
		news,
		demos,
	}, 20, { Name = "Presentacion", v = "C" })

	-- Columna derecha: ranuras.
	local cards: { Instance? } = {
		Ui.row({
			Ui.grow(Ui.text("Tus empresas", { size = 20, weight = W.bold })),
			Ui.inline(used .. " de " .. Catalog.RULES.slots .. " ranuras en uso", { size = Ui.S.sm, color = T.mut }),
		}, 10),
	}
	if App.payload and App.payload.saveMode == "memory" then
		table.insert(cards, Ui.note("y", "Studio sin acceso a la API de DataStore: las empresas se guardan solo mientras dure esta prueba."))
	end
	for i = 1, Catalog.RULES.slots do
		local key = tostring(i)
		table.insert(cards, slots[key] and slotCard(key, slots[key]) or emptySlot(key))
	end
	local locked = {}
	for i = 1, Catalog.RULES.slotsLocked do
		table.insert(locked, lockedSlot(Catalog.RULES.slots + i, anyLevel10))
	end
	table.insert(cards, Ui.grid(locked, phone and 1 or 2, nil, 10))
	table.insert(cards, Ui.text("Tus empresas se guardan en tu cuenta de Roblox y se validan al cargarse.", { size = Ui.S.xs, color = T.mut }))
	local right = Ui.col(cards, 12, { Name = "Empresas", v = "C" })

	if phone then
		Ui.new("UIPadding", { PaddingTop = UDim.new(0, 70), PaddingBottom = UDim.new(0, 80), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), Parent = wrap })
		Ui.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 22), Parent = wrap })
		left.Size = UDim2.new(1, 0, 0, 0)
		right.Size = UDim2.new(1, 0, 0, 0)
		left.Parent = wrap
		right.Parent = wrap
		local _ = leftW
	else
		-- Grilla de la V3: minmax(0,1fr) y minmax(0,800px), separación 40, márgenes 110/80/90.
		local avail = vw - 160 - 40
		local rightW = math.min(800, math.max(0, avail))
		local lw = math.max(0, avail - rightW)
		local h = math.max(0, vh - 200)
		left.Position = UDim2.fromOffset(80, 110)
		left.Size = UDim2.fromOffset(math.min(640, lw), h)
		right.Position = UDim2.fromOffset(80 + lw + 40, 110)
		right.Size = UDim2.fromOffset(rightW, h)
		left.Parent = wrap
		right.Parent = wrap
		Ui.new("Frame", { Name = "Margen", Size = UDim2.fromOffset(1, 90), Position = UDim2.fromOffset(0, 110 + h), BackgroundTransparency = 1, Parent = wrap })
	end

	local cfg = Ui.button("Configuración", "default", function()
		App.openDialog("settings", { wide = true })
	end, { icon = "gear", name = "Configuracion" })
	if phone then
		cfg.AnchorPoint = Vector2.new(1, 0)
		cfg.Position = UDim2.new(1, -12, 0, 12)
	else
		cfg.AnchorPoint = Vector2.new(0, 1)
		cfg.Position = UDim2.new(0, 24, 1, -24)
	end
	cfg.ZIndex = 3
	cfg.Parent = parent
	if not phone then
		local foot = Ui.inline("Guardado en tu cuenta de Roblox · sin pagos reales", { size = Ui.S.xs, color = T.mut })
		foot.AnchorPoint = Vector2.new(1, 1)
		foot.Position = UDim2.new(1, -24, 1, -30)
		foot.Parent = parent
	end
end

return Screen
