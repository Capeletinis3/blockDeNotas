--!strict
--[[
	Menú principal: showroom 3D de fondo (Showroom.luau) con el auto exhibido y el color de la empresa elegida,
	y a la izquierda las cuatro tarjetas de empresas (dos gratuitas y dos que se desbloquean con Robux). La
	tarjeta elegida se expande con sus datos y acciones; las demás quedan compactas. Abajo: configuración,
	novedades y demostraciones. No hay exportar/importar (el guardado es de la cuenta de Roblox).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Showroom = require(script.Parent.Showroom)
local T = Ui.T
local W = Ui.W

local Screen = {}

Screen.NEWS = {
	version = "Actualización 2.0 · «Desde 1970»",
	title = "Lotes, ventas automáticas y 60 años de historia",
	body = "Tu empresa empieza en 1970. Diseñás un auto, elegís cuántas unidades fabricar y se venden solas según la demanda, el precio y la competencia. La sede genera puntos de investigación por minuto y las tecnologías llegan en su época, hasta los eléctricos.",
	event = "Eventos de temporada (función futura)",
	when = "Todavía no implementado",
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
function Screen.isRenaming(): boolean
	return rename.slot ~= nil
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
	nc.name, nc.color, nc.logo, nc.slot = "", "#7667FF", "pico", key
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
	local total = 0
	for _, m in Catalog.MISSIONS do
		if m.kind == "tutorial" then
			total += 1
		end
	end
	local tut = s.tutorialSkipped and "Tutorial omitido" or (t >= total and "✓ Tutorial completo" or ("Tutorial · paso " .. (t + 1) .. " de " .. total))
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
			Ui.text("Ranura " .. key .. " libre. Todas las empresas empiezan igual: un garaje, " .. Util.money(Catalog.START.money) .. " y una idea, el 1 de enero de 1970.", { size = Ui.S.sm, color = T.mut, align = "C" }),
		}, 4)),
		Ui.button("Crear", "p", function()
			Screen.newCompany(key)
		end, { name = "Crear_" .. key }),
	}, { dir = "H", v = "C", gap = 16, bg = Ui.hex("#0E1016"), transparency = 0.25, radius = 16, stroke = Ui.hex("#3A3F4D"), pad = 18, name = "Ranura_" .. key })
end

-- Ranuras 3 y 4: se compran por separado con Robux (Developer Product; Roblox muestra el precio). Si el
-- producto no está configurado (id 0), el botón queda deshabilitado: no se simula ninguna compra.
local function lockedSlot(n: number): Frame
	local product = Catalog.PRODUCTS["slot" .. n]
	local ready = product ~= nil and product.id ~= 0
	return Ui.card({
		Ui.ico("lock", T.ye, T.ye, 32, { alpha = 0.12, iconSize = 17 }),
		Ui.grow(Ui.col({
			Ui.text("Ranura " .. n .. " · bloqueada", { size = Ui.S.sm, weight = W.bold }),
			Ui.text(ready and "Ranura adicional permanente: se compra con Robux, por separado de la otra." or "Ranura adicional: la compra todavía no está configurada.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }),
		}, 2)),
		Ui.button("Desbloquear", "p", function()
			App.request("buyProduct", { product = "slot" .. n })
		end, { small = true, disabled = not ready, why = (not ready) and "Compra no configurada todavía" or nil, name = "Comprar_" .. n }),
	}, { dir = "H", v = "C", gap = 10, bg = Ui.hex("#0E1016"), transparency = 0.08, radius = 16, stroke = { T.ye, 1, 0.65 }, pad = { 14, 16 }, name = "Bloqueada_" .. n })
end

-- Ranura elegida en el menú (la expandida): la que eligió el jugador, la última jugada o la primera ocupada.
local function selectedSlot(): string
	local slots = App.profile and App.profile.slots or {}
	local sel = App.ui.menuSel
	if sel and (slots[sel] or tonumber(sel) <= Catalog.RULES.slots) then
		return sel
	end
	local active = App.profile and App.profile.active
	if active and slots[active] then
		return active
	end
	return firstSlot() or "1"
end

local function selectSlot(key: string)
	App.ui.menuSel = key
	App.forceRender()
end

-- Tarjeta compacta (no elegida): logo, nombre y fecha; un clic la expande.
local function compactCard(key: string, s: any?, locked: boolean): Frame
	local title, sub
	if locked then
		title, sub = "Ranura " .. key .. " · bloqueada", "Se desbloquea con Robux"
	elseif s and s.damaged then
		title, sub = "Ranura " .. key .. " · datos dañados", "Elegila para ver opciones"
	elseif s then
		title, sub = s.name, Util.gameDate(s.day) .. " · " .. Util.money(s.money)
	else
		title, sub = "Ranura " .. key .. " libre", "Nueva empresa"
	end
	local b = Ui.new("TextButton", { Name = locked and ("Bloqueada_" .. key) or ("Elegir_" .. key), Text = "", Size = UDim2.new(1, 0, 0, 64), BackgroundColor3 = Ui.hex("#0E1016"), BackgroundTransparency = 0.15, Corner = 14, Stroke = { s and Color3.fromHex(s.color or "#3A3F4D") or Ui.hex("#3A3F4D"), 1, 0.4 }, Pad = { 8, 14 } })
	Ui.row({
		(s and not s.damaged) and Ui.logo(s, 44) or Ui.ico(locked and "lock" or "plus", locked and T.ye or T.mut, locked and T.ye or T.mut, 44, { alpha = 0.12, iconSize = 18 }),
		Ui.grow(Ui.col({ Ui.text(title, { size = Ui.S.base, weight = W.bold }), Ui.text(sub, { size = Ui.S.xs, color = T.mut }) }, 2)),
		(not s and not locked) and Ui.button("Crear", "p", function()
			Screen.newCompany(key)
		end, { small = true, name = "Crear_" .. key }) or Ui.icon("right", 16, T.mut),
	}, 12, { Size = UDim2.fromScale(1, 1), Parent = b })
	b.Activated:Connect(function()
		selectSlot(key)
	end)
	return b
end

function Screen.build(parent: Instance)
	local phone = App.isPhone()
	local vw, vh = App.vw, App.vh
	local slots = App.profile and App.profile.slots or {}
	local usable = App.profile and App.profile.usable or {}
	local sel = selectedSlot()
	local selected = slots[sel]

	-- Fondo: showroom 3D con el auto y el color de la empresa elegida.
	Showroom.mount(parent, selected and not selected.damaged and selected.showcase or nil, selected and not selected.damaged and selected.color or nil, App.settings and App.settings.reduceMotion)
	local wrap = Ui.new("ScrollingFrame", {
		Name = "MenuWrap",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Ui.hex("#06070B"),
		BackgroundTransparency = 1,
		ScrollBarThickness = 4,
		ZIndex = 2,
		Parent = parent,
	})
	App.keepScroll(wrap, "menu")
	-- Velo lateral para que las tarjetas se lean sobre la escena.
	local veil = Ui.new("Frame", { Name = "Velo", Size = UDim2.new(0, phone and vw or math.min(620, vw * 0.48), 1, 0), BackgroundColor3 = Ui.hex("#06070B"), BackgroundTransparency = 0, ZIndex = 1, Parent = parent })
	local vg = Instance.new("UIGradient")
	vg.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.7, 0.45), NumberSequenceKeypoint.new(1, 1) })
	vg.Parent = veil

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

	local cards: { Instance? } = { brand, Ui.text("Tus empresas", { size = 20, weight = W.bold, name = "Titular" }) }
	if App.payload and App.payload.saveMode == "memory" then
		table.insert(cards, Ui.note("y", "Studio sin acceso a la API de DataStore: las empresas se guardan solo mientras dure esta prueba."))
	end
	for i = 1, Catalog.RULES.slots do
		local key = tostring(i)
		local open = slots[key] ~= nil or usable[key] or i <= Catalog.RULES.slotsFree
		if key ~= sel then
			table.insert(cards, compactCard(key, slots[key], not open))
		elseif slots[key] then
			table.insert(cards, slotCard(key, slots[key]))
		elseif open then
			table.insert(cards, emptySlot(key))
		else
			table.insert(cards, lockedSlot(i))
		end
	end
	local demos = Ui.row({
		Ui.button("Novedades", "default", function()
			App.openDialog("news", {})
		end, { small = true, name = "Novedades" }),
		Ui.button("Demo: garaje", "default", function()
			App.request("playDemo", { kind = "tutorial" })
			App.ui.enteringGame = true
		end, { small = true, name = "Demo_tutorial" }),
		Ui.button("Demo: fábrica avanzada", "default", function()
			App.request("playDemo", { kind = "avanzada" })
			App.ui.enteringGame = true
		end, { small = true, name = "Demo_avanzada" }),
		Ui.button("Demo: después de 2030", "default", function()
			App.request("playDemo", { kind = "imperio" })
			App.ui.enteringGame = true
		end, { small = true, name = "Demo_imperio" }),
	}, 8, { wrap = true })
	table.insert(cards, demos)
	table.insert(cards, Ui.text("Tus empresas se guardan en tu cuenta de Roblox y se validan al cargarse.", { size = Ui.S.xs, color = T.mut }))
	local left = Ui.col(cards, 10, { Name = "Empresas" })
	if phone then
		Ui.new("UIPadding", { PaddingTop = UDim.new(0, 60), PaddingBottom = UDim.new(0, 80), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), Parent = wrap })
		Ui.new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 16), Parent = wrap })
		left.Size = UDim2.new(1, 0, 0, 0)
		left.Parent = wrap
	else
		left.Position = UDim2.fromOffset(48, 40)
		left.Size = UDim2.fromOffset(math.min(540, vw * 0.42), math.max(0, vh - 80))
		left.Parent = wrap
		Ui.new("Frame", { Name = "Margen", Size = UDim2.fromOffset(1, 60), Position = UDim2.fromOffset(0, vh - 20), BackgroundTransparency = 1, Parent = wrap })
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
