--!strict
--[[ Pantalla del editor de oficinas (Compañía › Instalaciones › Oficinas centrales › Personalizar oficina).
	Barra superior (volver, nombre y nivel de la oficina, dinero), panel lateral (habitaciones, catálogo por
	categorías e inventario) y barra contextual abajo (colocar, mover, girar, guardar, confirmar, cancelar).
	El centro queda libre para la vista 3D (OfficeScene + OfficeCamera). El estado vive en OfficeEditor:
	reconstruir esta pantalla no toca la escena. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Office = require(Shared.Office)
local OfficeCatalog = require(Shared.OfficeCatalog)
local Rules = require(Shared.Rules)
local Util = require(Shared.Util)
local Catalog = require(Shared.Catalog)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local Editor = require(script.Parent.OfficeEditor)
local Camera = require(script.Parent.OfficeCamera)
local T = Ui.T
local W = Ui.W

local Screen = {}

local ui = { tab = "catalogo", cat = "todas" }
local bar: Frame? = nil

local function itemName(id: string?): string
	local it = id and OfficeCatalog.item(id)
	return it and it.name or "Mueble"
end

-- Barra contextual (se rearma sola cuando cambia el modo, la posición o la respuesta del servidor).
function Screen.updateBar()
	local b = bar
	if not b or not b.Parent then
		return
	end
	for _, c in b:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local st = Editor.state()
	local o = Editor.office()
	local rows: { Instance? } = {}
	local actions: { Instance? } = {}
	if st.mode == "place" or st.mode == "move" then
		local n = o and Office.count(o, st.item) or 0
		local item = OfficeCatalog.item(st.item)
		local cost = st.mode == "move" and "Mover es gratis" or (n > 0 and ("Gratis · en inventario: " .. n) or ("Se compra al confirmar · " .. Util.money(item and item.price or 0)))
		table.insert(rows, Ui.row({
			Ui.grow(Ui.text((st.mode == "move" and "Mover · " or "Colocar · ") .. itemName(st.item) .. " · " .. st.rot .. "°", { size = Ui.S.base, weight = W.bold, name = "ModoOficina" })),
			Ui.chip(cost, (st.mode == "move" or n > 0) and "cg" or "cb", { name = "CostoColocacion" }),
		}, 8))
		local h = st.hover
		local valid = h and h.valid
		table.insert(rows, Ui.text(st.busy and "Enviando al servidor…" or (not h and "Fuera de las habitaciones: mové el cursor sobre una habitación para ubicarlo.") or (valid and "Ubicación válida: hacé clic o Enter para confirmar.") or (h.reason or "Ubicación inválida."), { size = Ui.S.sm, color = st.busy and T.mut or (valid and T.gr or T.re2), name = "EstadoColocacion" }))
		table.insert(actions, Ui.button("Girar", "default", function()
			Editor.rotate(-1)
		end, { small = true, icon = "undo", name = "GirarIzq", kbd = "⇧R" }))
		table.insert(actions, Ui.button("Girar", "default", function()
			Editor.rotate(1)
		end, { small = true, icon = "redo", name = "GirarDer", kbd = "R" }))
		table.insert(actions, Ui.button("Confirmar", "p", function()
			task.spawn(Editor.confirm)
		end, { small = true, name = "ConfirmarColocacion", disabled = st.busy or not valid, why = h and h.reason or "Elegí una ubicación" }))
		table.insert(actions, Ui.button("Cancelar", "q", function()
			Editor.cancel()
		end, { small = true, name = "CancelarColocacion", kbd = "Esc" }))
	elseif st.instance and o then
		local p = Office.find(o, st.instance)
		local r = p and OfficeCatalog.room(o.level, p.room)
		table.insert(rows, Ui.text(itemName(p and p.item) .. (r and (" · " .. r.name) or "") .. (p and (" · " .. p.rot .. "°") or ""), { size = Ui.S.base, weight = W.bold, name = "MuebleElegido" }))
		table.insert(rows, Ui.text("Mover y girar es gratis. Guardarlo lo devuelve al inventario (sin reembolso) para volver a colocarlo gratis.", { size = Ui.S.sm, color = T.mut }))
		table.insert(actions, Ui.button("Mover", "p", function()
			Editor.startMove()
		end, { small = true, name = "MoverMueble", kbd = "M" }))
		table.insert(actions, Ui.button("Girar 45°", "default", function()
			task.spawn(Editor.rotateSelected, 1)
		end, { small = true, name = "GirarMueble", kbd = "R" }))
		table.insert(actions, Ui.button("Guardar en inventario", "default", function()
			task.spawn(Editor.removeSelected)
		end, { small = true, name = "GuardarMueble", kbd = "Supr" }))
		table.insert(actions, Ui.button("Cerrar", "q", function()
			Editor.cancel()
		end, { small = true, name = "Deseleccionar", kbd = "Esc" }))
	else
		table.insert(rows, Ui.text("Elegí un mueble del catálogo o del inventario para colocarlo, o hacé clic en un mueble de la oficina para moverlo, girarlo o guardarlo.", { size = Ui.S.sm, color = T.tx2, name = "AyudaOficina" }))
	end
	if st.message then
		table.insert(rows, Ui.note("r", st.message))
	end
	if st.pending then
		-- Operación sin respuesta: se reintenta con el mismo identificador (sin cobro doble).
		table.insert(rows, Ui.row({
			Ui.button("Reintentar", "p", function()
				task.spawn(Editor.retry)
			end, { small = true, name = "ReintentarOperacion", disabled = st.busy, why = "Esperá la respuesta" }),
			Ui.button("Actualizar estado", "default", function()
				task.spawn(Editor.dropPending)
			end, { small = true, name = "DescartarReintento", disabled = st.busy, why = "Esperá la respuesta" }),
		}, 8))
		actions = {}
	end
	if #actions > 0 then
		table.insert(rows, Ui.row(actions, 8, { wrap = true }))
	end
	for i, r in rows do
		if r then
			(r :: any).LayoutOrder = i;
			(r :: any).Parent = b
		end
	end
end

-- Nombre de la habilidad de una bonificación (sin conectar todavía a la simulación).
local function skillName(skill: string): string
	local sk = Catalog.STAFF.skills[skill]
	return sk and (sk.name .. " (" .. sk.effect .. ")") or skill
end

local function itemCard(g: any, o: any, item: any, year: number): Frame
	local st = Editor.state()
	local n = Office.count(o, item.id)
	local placedN = Office.placedCount(o, item.id)
	local open = n > 0 or Office.available(item, year)
	local on = st.mode == "place" and st.item == item.id
	local cat = "Mueble"
	for _, c in OfficeCatalog.CATEGORIES do
		if c.id == item.category then
			cat = c.name
		end
	end
	local price = n > 0 and Ui.chip("En inventario: " .. n .. " · gratis", "cg", { name = "Inventario_" .. item.id }) or Ui.chip(Util.money(item.price), g.money >= item.price and "cb" or "cr", { name = "Precio_" .. item.id })
	return Ui.card({
		Ui.row({
			Ui.grow(Ui.col({
				Ui.text(item.name, { size = Ui.S.base, weight = W.bold }),
				Ui.text(cat .. " · desde " .. item.year .. (placedN > 0 and (" · colocados: " .. placedN) or ""), { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			price,
		}, 8, { v = "T" }),
		item.bonus and Ui.text("Beneficio futuro: " .. skillName(item.bonus.skill), { size = Ui.S.xs, color = T.tx2 }) or nil,
		Ui.button(on and "Colocando…" or (n > 0 and "Colocar gratis" or ("Comprar y colocar · " .. Util.money(item.price))), on and "default" or "p", function()
			Editor.startPlace(item.id)
		end, { small = true, fill = true, name = "Colocar_" .. item.id, disabled = not open, why = "Disponible desde " .. item.year }),
	}, { gap = 6, pad = 12, name = "Mueble_" .. item.id, stroke = on and { T.vi, 2 } or nil })
end

local function sidePanel(g: any, o: any): Frame
	local year = Rules.year(g)
	local st = Editor.state()
	local items: { Instance? } = {}
	-- Habitaciones del plano actual.
	local rooms = {}
	for _, r in OfficeCatalog.plan(o.level).rooms do
		table.insert(rooms, Ui.opt(r.name .. " · " .. r.w .. "×" .. r.d, st.room == r.id, function()
			Editor.setRoom(r.id)
			App.forceRender()
		end, { name = "Habitacion_" .. r.id, fill = true, height = 34, align = "L" }))
	end
	table.insert(items, Ui.col({ Ui.lbl("Habitaciones"), Ui.col(rooms, 6) }, 6))
	-- Catálogo / Inventario.
	local stored = 0
	for _, n in o.inventory do
		stored += n
	end
	table.insert(items, Ui.row({
		Ui.opt("Catálogo", ui.tab == "catalogo", function()
			ui.tab = "catalogo"
			App.forceRender()
		end, { name = "TabCatalogo", height = 34 }),
		Ui.opt("Inventario · " .. stored, ui.tab == "inventario", function()
			ui.tab = "inventario"
			App.forceRender()
		end, { name = "TabInventario", height = 34 }),
	}, 6))
	local list = {}
	if ui.tab == "catalogo" then
		local cats = { Ui.opt("Todas", ui.cat == "todas", function()
			ui.cat = "todas"
			App.forceRender()
		end, { height = 28, size = Ui.S.sm, name = "Cat_todas" }) }
		for _, c in OfficeCatalog.CATEGORIES do
			table.insert(cats, Ui.opt(c.name, ui.cat == c.id, function()
				ui.cat = c.id
				App.forceRender()
			end, { height = 28, size = Ui.S.sm, name = "Cat_" .. c.id }))
		end
		table.insert(items, Ui.row(cats, 6, { wrap = true }))
		-- Todo el catálogo: lo disponible desde su año (nunca desaparece); lo futuro, bloqueado.
		local all = {}
		for _, f in OfficeCatalog.FURNITURE do
			table.insert(all, f)
		end
		table.sort(all, function(a: any, b: any): boolean
			if a.year ~= b.year then
				return a.year < b.year
			end
			return a.name < b.name
		end)
		for _, f in all do
			if ui.cat == "todas" or f.category == ui.cat then
				table.insert(list, itemCard(g, o, f, year))
			end
		end
	else
		-- Todo lo guardado, sin filtrar por año: lo propio siempre se puede colocar gratis.
		for _, e in Office.inventoryList(o) do
			table.insert(list, itemCard(g, o, e.item, year))
		end
		table.insert(items, Ui.text("Los muebles guardados se colocan gratis. Al retirar uno de la oficina vuelve acá.", { size = Ui.S.xs, color = T.mut }))
		if #list == 0 then
			table.insert(list, Ui.empty("box", "No tenés muebles guardados."))
		end
	end
	for _, c in list do
		table.insert(items, c)
	end
	local scroll = Ui.scroll(items, { name = "PanelOficina", gap = 10, pad = { 12, 12, 12, 12 } })
	App.keepScroll(scroll, "oficina:" .. ui.tab .. ":" .. ui.cat)
	local panel = Ui.new("Frame", {
		Name = "LateralOficina",
		Active = true, -- los clics sobre el panel no llegan a la vista 3D
		BackgroundColor3 = T.panel,
		BackgroundTransparency = 0.05,
		Corner = 12,
		Stroke = T.line,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 84),
		Size = UDim2.new(0, App.isPhone() and math.min(320, App.vw - 32) or 360, 1, -100),
	}, { scroll })
	return panel
end

function Screen.build(content: Frame)
	local g = App.g
	local o = g and g.office
	if not g or not o then
		return
	end
	if not Editor.isActive() then
		Editor.enter()
	else
		Editor.sync()
	end
	local sede = Rules.sede(g)
	local root = Ui.new("Frame", { Name = "PantallaOficina", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = content })
	-- Barra superior.
	local money = Ui.chip(Util.money(g.money), "cg", { icon = "money", name = "DineroOficina" })
	App.live(function(gg: any)
		local lbl = money:FindFirstChildOfClass("TextLabel")
		if lbl then
			lbl.Text = Util.money(gg.money)
		end
	end)
	Ui.new("Frame", {
		Name = "BarraOficina",
		Active = true,
		BackgroundColor3 = T.panel,
		BackgroundTransparency = 0.05,
		Corner = 12,
		Stroke = T.line,
		Position = UDim2.fromOffset(16, 12),
		Size = UDim2.new(1, -32, 0, 60),
		Pad = { 0, 14 },
		List = { dir = "H", gap = 12, v = "C" },
		Parent = root,
	}, {
		Ui.button("Instalaciones", "default", function()
			App.ui.facSel = "offices"
			App.go("compania")
		end, { small = true, icon = "left", name = "VolverInstalaciones", kbd = "Esc" }),
		Ui.grow(Ui.col({
			Ui.text("Oficinas centrales · " .. sede.office, { size = Ui.S.h3, weight = W.bold, name = "TituloOficina" }),
			Ui.text("Nivel " .. o.level .. " · " .. #OfficeCatalog.plan(o.level).rooms .. " habitaciones · " .. #o.placed .. " muebles colocados", { size = Ui.S.xs, color = T.mut }),
		}, 2)),
		money,
		Ui.button("Encuadrar", "default", function()
			Camera.frame(Editor.state().room)
		end, { small = true, name = "Encuadrar" }),
	})
	sidePanel(g, o).Parent = root
	-- Barra contextual abajo, sobre la vista 3D.
	local phone = App.isPhone()
	bar = Ui.new("Frame", {
		Name = "AccionesOficina",
		Active = true,
		BackgroundColor3 = T.panel,
		BackgroundTransparency = 0.05,
		Corner = 12,
		Stroke = T.line,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -16),
		Size = UDim2.new(0, math.max(280, App.vw - (phone and 32 or 360 + 48)), 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Pad = { 12, 14 },
		List = { dir = "V", gap = 8 },
		Parent = root,
	})
	Ui.text("Cámara: clic derecho + arrastrar para girar · Q / E giran 45° · rueda para el zoom · W A S D o clic de la rueda para desplazarte", { size = Ui.S.xs, color = T.mut, name = "AyudaCamara" }).Parent = root
	local help = root:FindFirstChild("AyudaCamara") :: TextLabel
	help.AnchorPoint = Vector2.new(0, 0)
	help.Position = UDim2.fromOffset(20, 80)
	help.Size = UDim2.new(0, math.max(240, App.vw - 420), 0, 0)
	Editor.onChange = Screen.updateBar
	Screen.updateBar()
end

function Screen.leave()
	Editor.leave()
	Editor.onChange = nil
	bar = nil
end

function Screen.isActive(): boolean
	return Editor.isActive()
end

return Screen
