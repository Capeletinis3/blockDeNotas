--!strict
--[[
	Editor de vehículos (V3: Vehículo base → Rendimiento → Diseño → Revisión).
	El borrador vive en el cliente; al guardar, el servidor lo sanea, recalcula y cobra el desarrollo.
	Vista 3D: ViewportFrame con el modelo provisional (CarModel) en una ScreenGui propia, debajo de los paneles.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local DesignCalc = require(Shared.DesignCalc)
local CarModel = require(Shared.CarModel)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {}

local STEPS = { { 1, "Vehículo base" }, { 2, "Rendimiento" }, { 3, "Diseño" }, { 4, "Revisión" } }
local RAR = { ["Común"] = "cn", ["Rara"] = "cb", ["Épica"] = "cv", ["Legendaria"] = "cy" }

-- Vista 3D persistente ------------------------------------------------------------------
local view3d = Instance.new("ScreenGui")
view3d.Name = "CarEmpireEditor3D"
view3d.IgnoreGuiInset = true
view3d.ResetOnSpawn = false
view3d.DisplayOrder = 4
view3d.Enabled = false
view3d.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

local backdrop = Instance.new("Frame")
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.fromHex("#0B0E18")
backdrop.BorderSizePixel = 0
backdrop.Parent = view3d
local grad = Instance.new("UIGradient")
grad.Color = ColorSequence.new(Color3.fromHex("#1A1F2E"), Color3.fromHex("#07080C"))
grad.Rotation = 90
grad.Parent = backdrop

local viewport = Instance.new("ViewportFrame")
viewport.BackgroundTransparency = 1
viewport.Ambient = Color3.fromHex("#8C93A8")
viewport.LightColor = Color3.fromHex("#FFF1DC")
viewport.LightDirection = Vector3.new(-0.6, -1, -0.4)
viewport.Parent = view3d
local vpCamera = Instance.new("Camera")
vpCamera.FieldOfView = 40
vpCamera.Parent = viewport
viewport.CurrentCamera = vpCamera
local world = Instance.new("WorldModel")
world.Parent = viewport
local floor = Instance.new("Part")
floor.Anchored = true
floor.Size = Vector3.new(30, 0.2, 30)
floor.Shape = Enum.PartType.Cylinder
floor.CFrame = CFrame.new(0, -0.1, 0) * CFrame.Angles(0, 0, math.pi / 2)
floor.Size = Vector3.new(0.2, 26, 26)
floor.Color = Color3.fromHex("#1D2029")
floor.Material = Enum.Material.SmoothPlastic
floor.Parent = world

local currentModel: Model? = nil
local modelSig = ""
local angle = math.rad(35)
local autoRotate = true
local extent = 8

RunService.RenderStepped:Connect(function(dt: number)
	if not view3d.Enabled then
		return
	end
	if autoRotate then
		angle += dt * 0.35
	end
	local dist = extent * 2.6
	local pos = Vector3.new(math.sin(angle) * dist, extent * 0.75, math.cos(angle) * dist)
	vpCamera.CFrame = CFrame.lookAt(pos, Vector3.new(0, 1.6, 0))
end)

local function visualSig(d: any): string
	return table.concat({ d.baseId, d.paint.primary, d.paint.secondary, d.paint.finish, tostring(d.paint.intensity), tostring(d.wheels.size), d.wheels.rim, d.caliper, tostring(d.spoiler) }, "|")
end

local function updateModel(d: any)
	local sig = visualSig(d)
	if sig == modelSig and currentModel then
		return
	end
	modelSig = sig
	if currentModel then
		currentModel:Destroy()
	end
	local m = CarModel.build(d)
	m.Parent = world
	currentModel = m
	extent = CarModel.extent(d)
end

-- Estado del editor ----------------------------------------------------------------------
local function ed(): any
	return App.ui.editor
end

local function recomputeDirty()
	local e = ed()
	if e.saved then
		e.dirty = not DesignCalc.sameSpec(e.saved, e.draft)
	else
		e.dirty = true
	end
end

local function change(fn: (any) -> ())
	fn(ed().draft)
	recomputeDirty()
	App.forceRender()
end

function Screen.enter(params: any)
	local g = App.g
	local e = App.ui.editor
	if params and params.designId then
		for _, d in g.designs do
			if d.id == params.designId then
				e = { draft = Util.deepCopy(d), sourceId = d.id, saved = Util.deepCopy(d), step = 1, cat = "motor", colorTarget = "primary", dirty = false }
			end
		end
	elseif (params and params.new) or not e then
		local b = DesignCalc.firstBase(g)
		e = { draft = DesignCalc.newDraft(g, b.id), sourceId = nil, saved = nil, step = 1, cat = "motor", colorTarget = "primary", dirty = true }
	end
	e.sel = nil
	App.ui.editor = e
	view3d.Enabled = true
end

function Screen.leave()
	view3d.Enabled = false
end

-- Componentes ---------------------------------------------------------------------------------
local function fmtStat(k: string, v: number): string
	if k == "accel" or k == "consumption" then
		return Util.num(v, 1)
	end
	return Util.num(v)
end

local function statsCard(g: any, d: any, parent: Instance)
	local e = ed()
	local cur = DesignCalc.computeDesign(g, d)
	local prev = nil
	if e.step == 2 and e.sel and e.sel ~= d.parts[e.cat] then
		local t = Util.deepCopy(d)
		t.parts[e.cat] = e.sel
		prev = DesignCalc.computeDesign(g, t)
	end
	local rows: { Instance? } = {
		Ui.row({ Ui.lbl("Estadísticas"), Ui.spacer(), Ui.inline(prev and "vista previa de la pieza elegida" or "diseño actual", { size = Ui.S.xs, color = T.mut }) }, 8),
	}
	for _, s in Catalog.STAT_DEFS do
		local k, label, unit, dir, max = s[1], s[2], s[3], s[5], s[6]
		local v = cur[k]
		local nv = prev and prev[k] or v
		local dlt = Util.round((nv - v) * 10) / 10
		local good = (dir > 0 and dlt > 0) or (dir < 0 and dlt < 0)
		local pct = math.clamp((dir > 0 and nv / max or 1 - nv / max) * 100, 2, 100)
		local u = k == "consumption" and cur.consUnit or unit
		local bar = Ui.bar(pct, dlt ~= 0 and (good and T.gr or T.re) or nil)
		table.insert(rows, Ui.col({
			Ui.row({
				Ui.grow(Ui.text(label .. "  <font color=\"#6C7382\">" .. u .. "</font>", { size = Ui.S.sm, color = T.mut })),
				Ui.inline(fmtStat(k, nv), { size = 14, weight = W.bold }),
				dlt ~= 0 and Ui.inline((good and "▲ " or "▼ ") .. (dlt > 0 and "+" or "") .. fmtStat(k, dlt), { size = Ui.S.xs, weight = W.bold, color = good and T.gr or T.re2 }) or nil,
			}, 6),
			bar,
		}, 4))
	end
	table.insert(rows, Ui.text("Barras: más llena = mejor. En aceleración, frenado, consumo y peso, un número menor es mejor.", { size = Ui.S.xs, color = T.mut }))
	local card = Ui.card(rows, { bg = Color3.fromHex("#0E1016"), transparency = 0.08, radius = 14, stroke = Color3.fromHex("#2A2E39"), gap = 6, pad = { 12, 14 } })
	card.Name = "Estadisticas"
	card.Position = UDim2.fromOffset(14, 78)
	card.Size = UDim2.fromOffset(300, 0)
	card.Parent = parent
end

local function section(title: string, children: { Instance? }, gap: number?): Frame
	local list: { Instance? } = { Ui.lbl(title) }
	for _, c in children do
		table.insert(list, c)
	end
	return Ui.col(list, gap or 8)
end

local function optRow(options: { any }, current: any, onPick: (any) -> (), opts: { [string]: any }?): Frame
	local items = {}
	for _, o in options do
		local value, label, extra = o[1], o[2], o[3]
		table.insert(items, Ui.opt(label, current == value, function()
			onPick(value)
		end, { height = 36, disabled = extra and extra.disabled ~= nil, why = extra and extra.disabled }))
	end
	if opts and opts.columns then
		return Ui.grid(items, opts.columns, opts.height or 36)
	end
	return Ui.row(items, 6, { wrap = true })
end

-- Paso 1: vehículo base ------------------------------------------------------------------------
local function panelBase(g: any, d: any, body: Instance)
	local nameBox = Ui.input(d.name, "Nombre del proyecto", function(text: string)
		local t = Util.trim(text)
		if t ~= d.name then
			change(function(dd)
				dd.name = Util.truncateChars(t, 24)
			end)
		end
	end)
	section("Nombre del proyecto", { nameBox }).Parent = body
	local company = g.company.name
	section("Marca", { optRow({ { company, company }, { company .. " Sport", company .. " Sport" }, { company .. " Lux", company .. " Lux" } }, d.brand, function(v)
		change(function(dd)
			dd.brand = v
		end)
	end) }).Parent = body
	local b = Catalog.base(d.baseId)
	local chassis = {}
	for _, k in Catalog.CHASSIS_ORDER do
		local ch = Catalog.CHASSIS[k]
		local blocked = ch.need and not Util.contains(b.tags, ch.need)
		table.insert(chassis, { k, k .. (ch.unit > 0 and (" (+" .. Util.money(ch.unit) .. "/u)") or ""), blocked and { disabled = "Solo para SUV y pickup" } or nil })
	end
	section("Chasis", { optRow(chassis, d.chassis, function(v)
		change(function(dd)
			dd.chassis = v
		end)
	end) }).Parent = body
	local segs = {}
	for _, k in Catalog.SEGMENT_ORDER do
		table.insert(segs, { k, k .. " · precio ×" .. Util.num(Catalog.SEGMENTS[k].price, 2) })
	end
	section("Segmento de mercado", { optRow(segs, d.segment, function(v)
		change(function(dd)
			dd.segment = v
		end)
	end) }).Parent = body
	local objs = {}
	for _, k in Catalog.OBJECTIVE_ORDER do
		table.insert(objs, { k, k })
	end
	section("Objetivo del vehículo (atrae a clientes con esa preferencia)", { optRow(objs, d.objective, function(v)
		change(function(dd)
			dd.objective = v
		end)
	end, { columns = 3 }) }).Parent = body
	local q = {}
	for i, tier in Catalog.QUALITY_TIERS do
		table.insert(q, { i - 1, tier })
	end
	section("Calidad de terminación · " .. Catalog.QUALITY_TIERS[d.quality + 1] .. " · +" .. Util.money(d.quality * 700) .. "/u · +" .. d.quality * 3 .. " calidad", { optRow(q, d.quality, function(v)
		change(function(dd)
			dd.quality = v
		end)
	end, { columns = 6 }) }).Parent = body

	-- Modelos base
	local available = 0
	for _, x in Catalog.BASES do
		if DesignCalc.baseAvailable(g, x) == nil then
			available += 1
		end
	end
	local cards: { Instance? } = { Ui.row({ Ui.lbl("Modelo base"), Ui.spacer(), Ui.inline(available .. " de " .. #Catalog.BASES .. " disponibles", { size = Ui.S.xs, color = T.mut }) }, 8) }
	for _, x in Catalog.BASES do
		local block = DesignCalc.baseAvailable(g, x)
		local on = d.baseId == x.id
		local t = DesignCalc.newDraft(g, x.id)
		local st = DesignCalc.computeDesign(g, t)
		local paid = Util.contains(g.devPaid, "base:" .. x.id)
		local card = Ui.new("TextButton", {
			Name = "Base_" .. x.id,
			Text = "",
			BackgroundColor3 = on and Color3.fromHex("#1A1833") or T.p2,
			BackgroundTransparency = 0,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Corner = 12,
			Stroke = on and { T.vi, 2 } or T.line2,
			Pad = 12,
			List = { dir = "H", gap = 12, v = "T" },
		}, {
			Ui.ico(block and "🔒" or "🚗", block and T.mut2 or T.tx, block and Color3.fromHex("#22252E") or Color3.fromHex(t.paint.primary), 40),
			Ui.grow(Ui.col({
				Ui.row({ Ui.grow(Ui.text(x.name, { size = 15, weight = W.bold })), Ui.chip(x.rarity, RAR[x.rarity]) }, 6),
				Ui.text(Catalog.TYPES[x.type] .. " · Nv. " .. x.level .. " · " .. st.hp .. " hp · " .. Util.money(st.unitCost) .. "/u · precio " .. Util.money(st.price), { size = Ui.S.xs, color = T.mut }),
				block and Ui.chip("🔒 " .. block, "cy") or Ui.chip(paid and "Licencia pagada" or ("Licencia " .. Util.money(x.dev) .. " (una vez)"), paid and "cg" or "co"),
			}, 5)),
		})
		if block then
			card.BackgroundTransparency = 0.25
		end
		card.Activated:Connect(function()
			if block then
				App.toast("aviso", x.name .. ": " .. block)
				return
			end
			if d.baseId ~= x.id then
				change(function(dd)
					DesignCalc.changeBase(g, dd, x.id)
				end)
			end
		end)
		table.insert(cards, card)
	end
	Ui.col(cards, 8).Parent = body
end

-- Paso 2: rendimiento -----------------------------------------------------------------------------
local function panelPerf(g: any, d: any, body: Instance): TextButton?
	local e = ed()
	local cat = e.cat
	local cats = {}
	for _, c in Catalog.CATS do
		table.insert(cats, Ui.opt(c[2], cat == c[1], function()
			e.cat = c[1]
			e.sel = nil
			App.forceRender()
		end, { height = 34, size = 12 }))
	end
	section("Categoría", { Ui.grid(cats, 4, 34, 6) }).Parent = body
	local list = Catalog.partsOf(cat)
	local current = Catalog.part(cat, d.parts[cat])
	local selId = e.sel or d.parts[cat]
	local selP = Catalog.part(cat, selId)
	local b = Catalog.base(d.baseId)
	local cards: { Instance? } = {
		Ui.row({ Ui.lbl(Catalog.catLabel(cat) .. " · " .. #list .. " opciones"), Ui.spacer(), Ui.inline("Instalada: " .. (current and current.name or "—"), { size = Ui.S.xs, color = T.mut }) }, 8),
	}
	for _, p in list do
		local bl = DesignCalc.partBlock(g, d, p)
		local on = p.id == selId
		local eq = p.id == d.parts[cat]
		local paid = Util.contains(g.devPaid, cat .. ":" .. p.id)
		local isDefault = b.defaults[cat] == p.id
		local costChips: { Instance? } = {}
		if eq then
			table.insert(costChips, Ui.chip("✓ Equipada", "cb"))
		elseif bl then
			table.insert(costChips, Ui.chip("🔒 Bloqueada", "cy"))
		else
			table.insert(costChips, Ui.chip("● Disponible", "cg"))
		end
		if p.proto > 0 and not isDefault then
			table.insert(costChips, Ui.chip(paid and "Desarrollo pagado" or ("Desarrollo " .. Util.money(p.proto)), paid and "cg" or "co"))
		end
		if p.unit > 0 then
			table.insert(costChips, Ui.chip("+" .. Util.money(p.unit) .. "/u", "cn"))
		end
		local card = Ui.new("TextButton", {
			Name = "Pieza_" .. p.id,
			Text = "",
			BackgroundColor3 = on and Color3.fromHex("#1A1833") or T.p2,
			BackgroundTransparency = bl and 0.25 or 0,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Corner = 12,
			Stroke = on and { T.vi, 2 } or T.line2,
			Pad = 12,
			List = { dir = "H", gap = 12, v = "T" },
		}, {
			Ui.ico(bl and "🔒" or "🔧", bl and T.mut2 or T.vi2, T.input, 40),
			Ui.grow(Ui.col({
				Ui.row({ Ui.grow(Ui.text(p.name, { size = 14, weight = W.bold })), Ui.chip(p.rarity, RAR[p.rarity]) }, 6),
				Ui.row(costChips, 5, { wrap = true }),
				Ui.text(bl and bl or p.desc, { size = Ui.S.xs, color = bl and T.ye or T.mut }),
			}, 5)),
		})
		card.Activated:Connect(function()
			e.sel = p.id
			App.forceRender()
		end)
		table.insert(cards, card)
	end
	Ui.col(cards, 8).Parent = body

	if selP and selP.id ~= d.parts[cat] then
		local t = Util.deepCopy(d)
		t.parts[cat] = selP.id
		local a, n = DesignCalc.computeDesign(g, d), DesignCalc.computeDesign(g, t)
		local chips = {}
		for _, s in Catalog.STAT_DEFS do
			local k, label, unit, dir = s[1], s[2], s[3], s[5]
			local dl = Util.round((n[k] - a[k]) * 10) / 10
			if dl ~= 0 then
				local good = (dir > 0 and dl > 0) or (dir < 0 and dl < 0)
				table.insert(chips, Ui.chip((dl > 0 and "+" or "") .. fmtStat(k, dl) .. " " .. (k == "consumption" and "" or unit:gsub("0–100", "")) .. " " .. string.lower(label), good and "cg" or "cr"))
			end
		end
		local du = n.unitCost - a.unitCost
		table.insert(chips, Ui.chip((du >= 0 and "+" or "") .. Util.money(du) .. " por unidad", du > 0 and "cy" or "cg"))
		local block = DesignCalc.partBlock(g, d, selP)
		section("Comparación con la pieza instalada", {
			Ui.text((current and current.name or "—") .. "  →  <b>" .. selP.name .. "</b>", { size = Ui.S.sm }),
			Ui.row(chips, 6, { wrap = true }),
			block and Ui.note("y", block) or Ui.note("b", (Util.contains(g.devPaid, cat .. ":" .. selP.id) or selP.proto == 0 or b.defaults[cat] == selP.id) and "Sin costo de desarrollo." or ("El desarrollo de " .. Util.money(selP.proto) .. " se cobra una sola vez al guardar el diseño.")),
		}).Parent = body
		if block then
			return Ui.button("🔒 No se puede instalar", "default", nil, { disabled = true, why = block, flex = 2 })
		end
		return Ui.button("🔧 Instalar en el prototipo", "p", function()
			change(function(dd)
				dd.parts[cat] = selP.id
			end)
			e.sel = nil
			App.forceRender()
		end, { flex = 2 })
	end
	return nil
end

-- Paso 3: diseño ------------------------------------------------------------------------------------
local function panelDesign(g: any, d: any, body: Instance)
	local e = ed()
	local target = e.colorTarget
	local color = d.paint[target]
	local swatches = {}
	for _, p in Catalog.PAINTS do
		table.insert(swatches, Ui.swatch(p[1], string.upper(color) == string.upper(p[1]), function()
			change(function(dd)
				dd.paint[target] = string.upper(p[1])
			end)
		end))
	end
	local hexBox = Ui.input(color, "#D6333F", function(text: string)
		local v = string.upper(Util.trim(text))
		if string.sub(v, 1, 1) ~= "#" then
			v = "#" .. v
		end
		if Util.isHexColor(v) then
			if v ~= d.paint[target] then
				change(function(dd)
					dd.paint[target] = v
				end)
			end
		else
			App.toast("error", "Escribí un código como #D6333F.")
			App.forceRender()
		end
	end, { width = 140 })
	section("Pintura", {
		optRow({ { "primary", "Principal" }, { "secondary", "Secundario" } }, target, function(v)
			e.colorTarget = v
			App.forceRender()
		end),
		target == "secondary" and Ui.text("El color secundario pinta el techo, los pilares y el alerón.", { size = Ui.S.xs, color = T.mut }) or nil,
		Ui.row(swatches, 8, { wrap = true }),
		Ui.row({
			Ui.new("Frame", { Size = UDim2.fromOffset(44, 44), BackgroundColor3 = Color3.fromHex(color), BackgroundTransparency = 0, Corner = 10, Stroke = T.btnLine }),
			Ui.inline("HEX", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
			hexBox,
			Ui.text("Escribí un código y salí del campo.", { size = Ui.S.xs, color = T.mut, width = 150 }),
		}, 10),
	}, 10).Parent = body

	local finishes = {}
	for _, k in Catalog.FINISH_ORDER do
		local f = Catalog.FINISHES[k]
		local locked = f.research and not DesignCalc.has(g, f.research)
		table.insert(finishes, { k, k .. (f.unit > 0 and (" +" .. Util.money(f.unit) .. "/u") or ""), locked and { disabled = "Requiere investigar «" .. DesignCalc.researchName(f.research) .. "»" } or nil })
	end
	section("Acabado", { optRow(finishes, d.paint.finish, function(v)
		change(function(dd)
			dd.paint.finish = v
		end)
	end, { columns = 2 }) }).Parent = body

	-- Ruedas y frenos
	local sizes = {}
	for s = 16, 22 do
		table.insert(sizes, { s, s .. "″" })
	end
	local rims = {}
	for _, r in Catalog.RIM_COLORS do
		table.insert(rims, Ui.swatch(r[1], d.wheels.rim == r[1], function()
			change(function(dd)
				dd.wheels.rim = r[1]
			end)
		end))
	end
	local calipers = {}
	for _, cc in Catalog.CALIPER_COLORS do
		table.insert(calipers, Ui.swatch(cc[1], d.caliper == cc[1], function()
			change(function(dd)
				dd.caliper = cc[1]
			end)
		end))
	end
	section("Ruedas y frenos", {
		Ui.text("Tamaño · " .. d.wheels.size .. "″ · +" .. Util.money(math.max(0, d.wheels.size - 17) * 150) .. "/u", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
		optRow(sizes, d.wheels.size, function(v)
			change(function(dd)
				dd.wheels.size = v
			end)
		end, { columns = 7 }),
		Ui.text("Color de llantas", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
		Ui.row(rims, 8),
		Ui.text("Pinzas de freno", { size = Ui.S.sm, color = T.tx2, weight = W.semi }),
		Ui.row(calipers, 8),
	}, 8).Parent = body

	section("Carrocería y detalles", {
		Ui.card({
			Ui.grow(Ui.col({
				Ui.text("Alerón trasero", { size = Ui.S.sm, weight = W.bold }),
				Ui.text("+3 de manejo, −4 km/h de velocidad máxima, +" .. Util.money(600) .. "/u", { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			Ui.toggle(d.spoiler, function()
				change(function(dd)
					dd.spoiler = not dd.spoiler
				end)
			end),
		}, { dir = "H", v = "C", gap = 10 }),
		Ui.text("Paragolpes, vinilos, interior y demás detalles llegan en una etapa posterior (por ahora quedan de serie).", { size = Ui.S.xs, color = T.mut }),
	}).Parent = body
end

-- Paso 4: revisión ------------------------------------------------------------------------------------
local function panelReview(g: any, d: any, c: any, body: Instance)
	local e = ed()
	local b = Catalog.base(d.baseId)
	local items = DesignCalc.devItems(g, d)
	local pend = DesignCalc.devPending(g, d)
	local margin = c.price - c.unitCost
	local paintName = Catalog.colorName(Catalog.PAINTS, d.paint.primary) or d.paint.primary
	Ui.card({
		Ui.text(d.name, { size = 17, weight = W.bold }),
		Ui.text(d.brand .. " · " .. b.name .. " (" .. Catalog.TYPES[b.type] .. ") · " .. d.chassis .. " · " .. d.segment .. " · objetivo " .. string.lower(d.objective), { size = Ui.S.sm, color = T.mut }),
		Ui.text("Pintura " .. paintName .. " " .. string.lower(d.paint.finish) .. " · secundario " .. d.paint.secondary .. " · llantas " .. d.wheels.size .. "″ · " .. (d.spoiler and "con alerón" or "sin alerón") .. " · calidad " .. Catalog.QUALITY_TIERS[d.quality + 1], { size = Ui.S.sm, color = T.mut }),
	}, { gap = 4 }).Parent = body

	local mats = {}
	for _, k in Util.keys(c.mats) do
		table.insert(mats, c.mats[k] .. " " .. string.lower(Catalog.matLabel(k)))
	end
	section("Economía del modelo", {
		Ui.grid({
			(Ui.kv("Fabricación por unidad", Util.money(c.unitCost))),
			(Ui.kv("Precio recomendado", Util.money(c.price))),
			(Ui.kv("Margen por unidad", (margin >= 0 and "▲ " or "▼ ") .. Util.money(margin), { color = margin >= 0 and T.gr or T.re2 })),
			(Ui.kv("Producción", Util.gameDuration(c.build), { sub = "de juego por unidad (velocidad base)" })),
		}, 2, 78),
		(Ui.kv("Materiales por unidad", table.concat(mats, ", "), { valueSize = 13 })),
	}).Parent = body

	local devRows: { Instance? } = {}
	for _, it in items do
		table.insert(devRows, Ui.line(it.label, it.paid and "Pagado" or Util.money(it.cost), { color = it.paid and T.gr or T.tx }))
	end
	table.insert(devRows, Ui.hr())
	table.insert(devRows, Ui.line("Pendiente", Util.money(pend), { color = pend > 0 and T.or_ or T.gr, leftWeight = W.bold }))
	section("Desarrollo (pago único al guardar)", { Ui.card(devRows, { gap = 0, pad = { 4, 12 } }) }).Parent = body

	local statRows = {}
	for _, s in Catalog.STAT_DEFS do
		local k = s[1]
		local unit = k == "consumption" and c.consUnit or s[3]
		table.insert(statRows, Ui.line(s[2], fmtStat(k, c[k]) .. " " .. unit, { leftColor = T.mut, size = 12 }))
	end
	section("Estadísticas finales", { Ui.card({ Ui.grid(statRows, 2, 26, 4) }, { pad = { 6, 12 } }) }).Parent = body

	local partRows = {}
	for _, cat in Catalog.CATS do
		local p = Catalog.part(cat[1], d.parts[cat[1]])
		table.insert(partRows, Ui.line(cat[2], p and p.name or "—", { leftColor = T.mut, weight = W.med }))
	end
	section("Piezas instaladas", { Ui.card(partRows, { gap = 0, pad = { 4, 12 } }) }).Parent = body

	local warns = {}
	if c.comfort < 50 and (d.objective == "Familiar" or d.objective == "Lujo") then
		table.insert(warns, "La comodidad (" .. c.comfort .. ") es baja para un objetivo " .. string.lower(d.objective) .. ".")
	end
	if c.hp < 200 and (d.objective == "Deportivo" or d.objective == "Competición") then
		table.insert(warns, "Con " .. c.hp .. " hp va a costar convencer a clientes que buscan potencia.")
	end
	if margin < 3000 then
		table.insert(warns, "El margen por unidad es bajo.")
	end
	local miss = {}
	for _, k in Util.keys(c.mats) do
		local have = g.materials[k] or 0
		if have < c.mats[k] then
			table.insert(miss, (c.mats[k] - have) .. " de " .. string.lower(Catalog.matLabel(k)))
		end
	end
	if #miss > 0 then
		table.insert(warns, "Hoy no tenés materiales para fabricar una unidad: faltan " .. table.concat(miss, ", ") .. ".")
	end
	if #warns > 0 then
		local nodes = {}
		for _, w in warns do
			table.insert(nodes, Ui.note("y", w))
		end
		section("Advertencias", nodes).Parent = body
	end

	local saved = e.sourceId ~= nil and not e.dirty
	section("Acciones", {
		Ui.row({
			Ui.button("Enviar a producción", "default", function()
				App.openDialog("order", { designId = e.sourceId })
			end, { small = true, disabled = not saved, why = "Guardá el diseño primero" }),
			Ui.button("Descartar cambios", "d", function()
				if e.saved then
					e.draft = Util.deepCopy(e.saved)
					e.dirty = false
					App.forceRender()
				end
			end, { small = true, disabled = not (e.dirty and e.saved), why = "No hay cambios para descartar" }),
			Ui.button("Nuevo proyecto", "q", function()
				Screen.enter({ new = true })
				App.forceRender()
			end, { small = true }),
		}, 8, { wrap = true }),
		not saved and Ui.text("Enviar a producción requiere el diseño guardado.", { size = Ui.S.xs, color = T.mut }) or nil,
	}).Parent = body
end

local function save()
	local e = ed()
	local r = App.request("saveDesign", { draft = e.draft, sourceId = e.sourceId })
	if r.ok then
		e.sourceId = r.designId
		e.draft.id = r.designId
		e.draft.version = r.version
		e.saved = Util.deepCopy(e.draft)
		e.dirty = false
		App.forceRender()
	end
end

-- Construcción --------------------------------------------------------------------------------------
function Screen.build(parent: Instance)
	local g = App.g
	if not ed() then
		Screen.enter({})
	end
	local e = ed()
	view3d.Enabled = true
	local d = e.draft
	local c = DesignCalc.computeDesign(g, d)
	updateModel(d)

	local panelW = math.min(440, App.vw * 0.36)
	local statsW = App.vw > 1100 and 300 or 0
	-- Área libre para el auto: entre las estadísticas y el panel.
	local vpLeft = (statsW > 0 and 14 + statsW + 10 or 0)
	viewport.Position = UDim2.fromOffset(vpLeft, 64)
	viewport.Size = UDim2.new(1, -(vpLeft + panelW + 28), 1, -150)
	-- La vista 3D está en otra ScreenGui sin UIScale: se convierten las medidas virtuales a píxeles.
	local uiScale = App.gui:FindFirstChildOfClass("UIScale")
	if uiScale then
		local k = uiScale.Scale
		viewport.Position = UDim2.fromOffset(vpLeft * k, 64 * k)
		viewport.Size = UDim2.new(1, -(vpLeft + panelW + 28) * k, 1, -150 * k)
	end

	-- Barra superior (.ed-top)
	local status = e.sourceId and (e.dirty and "Cambios sin guardar" or "Guardado") or "Borrador"
	local statusKind = status == "Guardado" and "cg" or (status == "Borrador" and "cn" or "cy")
	local moneyLabel = Ui.inline(Util.money(g.money), { size = 15, weight = W.bold })
	App.live(function(gg: any)
		moneyLabel.Text = Util.money(gg.money)
	end)
	Ui.row({
		Ui.ico("✎", T.vi2, Color3.fromHex("#211D45"), 32),
		Ui.inline("Diseño", { size = Ui.S.h2, weight = W.bold }),
		Ui.inline(d.name .. (e.sourceId and (" · v" .. tostring(d.version or 1)) or ""), { size = Ui.S.sm, color = T.mut }),
		Ui.chip("● " .. status, statusKind),
		Ui.spacer(),
		Ui.inline("Dinero", { size = Ui.S.xs, color = T.mut, weight = W.bold }),
		moneyLabel,
		Ui.button("Salir", "default", function()
			App.go("juego")
		end, { small = true }),
	}, 12, {
		Name = "BarraEditor",
		Size = UDim2.new(1, 0, 0, 64),
		AutomaticSize = Enum.AutomaticSize.None,
		BackgroundColor3 = T.bg,
		BackgroundTransparency = 0.25,
		Pad = { 0, 16, 0, 150 },
		Parent = parent,
	})

	if statsW > 0 then
		statsCard(g, d, parent)
	end

	-- Panel derecho (.ed-panel)
	local panel = Ui.new("Frame", {
		Name = "PanelEditor",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 78),
		Size = UDim2.new(0, panelW, 1, -92),
		BackgroundColor3 = Color3.fromHex("#0E1016"),
		BackgroundTransparency = 0.04,
		Corner = 16,
		Stroke = Color3.fromHex("#2A2E39"),
		ClipsDescendants = true,
		Parent = parent,
	})
	local stepTitle = STEPS[e.step][2]
	local progress = {}
	for n = 1, 4 do
		table.insert(progress, Ui.grow(Ui.new("Frame", {
			Size = UDim2.new(1, 0, 0, 3),
			BackgroundColor3 = n <= e.step and T.vi or T.p3,
			BackgroundTransparency = 0,
			Corner = 2,
		}), { Size = UDim2.new(0, 0, 0, 3) }))
	end
	local head = Ui.col({
		Ui.row({ Ui.lbl("Diseñar · Paso " .. e.step .. " de 4"), Ui.spacer(), Ui.button("✕", "default", function()
			App.go("juego")
		end, { small = true, width = 36 }) }, 8),
		Ui.row({ Ui.grow(Ui.text(stepTitle, { size = Ui.S.h2, weight = W.bold })), Ui.chip("● " .. status, statusKind) }, 8),
		Ui.row(progress, 4),
	}, 10, { Name = "Cabecera", Pad = { 14, 18, 12, 18 }, Size = UDim2.new(1, 0, 0, 0) })
	head.Parent = panel

	-- Pie (.ed-pf)
	local pend = DesignCalc.devPending(g, d)
	local footMoney = Ui.inline(Util.money(g.money), { size = Ui.S.sm, weight = W.bold })
	App.live(function(gg: any)
		footMoney.Text = Util.money(gg.money)
	end)
	local nextBtn: Instance? = nil
	local body = Ui.scroll({}, { name = "CuerpoPaso", gap = 18, pad = { 14, 18, 16, 18 } })
	if e.step == 1 then
		panelBase(g, d, body)
	elseif e.step == 2 then
		nextBtn = panelPerf(g, d, body)
	elseif e.step == 3 then
		panelDesign(g, d, body)
	else
		panelReview(g, d, c, body)
		local saved = e.sourceId ~= nil and not e.dirty
		nextBtn = Ui.button("✓ " .. (e.sourceId and "Guardar cambios" or "Guardar diseño") .. (pend > 0 and (" · " .. Util.money(pend)) or ""), "p", save, {
			flex = 2,
			disabled = saved or pend > g.money,
			why = saved and "No hay cambios para guardar" or ("Fondos insuficientes: el desarrollo cuesta " .. Util.money(pend)),
		})
	end
	if not nextBtn then
		nextBtn = Ui.button("Siguiente", "p", function()
			e.step = math.min(4, e.step + 1)
			e.sel = nil
			App.forceRender()
		end, { flex = 2 })
	end
	local back = e.step > 1 and Ui.button("Volver", "default", function()
		e.step -= 1
		e.sel = nil
		App.forceRender()
	end, { flex = 1 }) or Ui.button("Salir", "default", function()
		App.go("juego")
	end, { flex = 1 })
	local foot = Ui.col({
		Ui.line("Desarrollo pendiente <font color=\"#7D8493\">(se paga una vez al guardar)</font>", pend > 0 and Util.money(pend) or "$0", { leftColor = T.mut, color = pend > 0 and T.or_ or T.gr }),
		Ui.line("Fabricación por unidad <font color=\"#7D8493\">(se paga al fabricar)</font>", Util.money(c.unitCost), { leftColor = T.mut }),
		Ui.row({ Ui.grow(Ui.text("Dinero disponible", { size = Ui.S.sm, color = T.mut })), footMoney }, 8),
		pend > g.money and Ui.note("y", "No alcanza el dinero para pagar el desarrollo al guardar. Elegí piezas más simples o conseguí fondos.") or nil,
		Ui.row({ back, nextBtn }, 8),
	}, 6, {
		Name = "Pie",
		BackgroundColor3 = Color3.fromHex("#0D0F14"),
		BackgroundTransparency = 0,
		Pad = { 12, 18, 14, 18 },
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
	})
	foot.Parent = panel
	body.Parent = panel
	App.keepScroll(body, "editor:" .. e.step .. ":" .. tostring(e.cat))
	-- El cuerpo ocupa el espacio entre la cabecera y el pie (se ajusta cuando se conocen sus alturas).
	local function fit()
		local top = head.AbsoluteSize.Y
		local bottom = foot.AbsoluteSize.Y
		local k = uiScale and uiScale.Scale or 1
		body.Position = UDim2.fromOffset(0, top / k)
		body.Size = UDim2.new(1, 0, 1, -(top + bottom) / k)
	end
	head:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	foot:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	task.defer(fit)

	-- Pasos (.steps) y controles de cámara
	local stepButtons = {}
	for _, st in STEPS do
		local n = st[1]
		local current = e.step == n
		local done = n < e.step
		local btn = Ui.new("TextButton", {
			Text = "",
			BackgroundColor3 = current and Color3.fromHex("#1E1B3D") or Color3.fromHex("#111319"),
			BackgroundTransparency = 0.05,
			Size = UDim2.fromOffset(0, 44),
			AutomaticSize = Enum.AutomaticSize.X,
			Corner = 22,
			Stroke = current and T.vi or Color3.fromHex("#2A2E39"),
			Pad = { 0, 14, 0, 6 },
			List = { dir = "H", gap = 8, v = "C" },
		}, {
			Ui.new("TextLabel", {
				Text = done and "✓" or tostring(n),
				TextSize = 13,
				Weight = W.heavy,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = done and Color3.fromHex("#05230F") or T.tx,
				BackgroundColor3 = current and T.vi or (done and T.gr or T.p3),
				BackgroundTransparency = 0,
				Size = UDim2.fromOffset(30, 30),
				Corner = 15,
			}),
			App.vw > 1200 and Ui.inline(st[2], { size = 14, weight = W.semi, color = current and T.tx or Color3.fromHex("#B4BAC6") }) or nil,
		})
		btn.Activated:Connect(function()
			e.step = n
			e.sel = nil
			App.forceRender()
		end)
		table.insert(stepButtons, btn)
	end
	local rotate = Ui.button(autoRotate and "❚❚ Giro" or "▶ Giro", "default", function()
		autoRotate = not autoRotate
		App.forceRender()
	end, { small = true })
	local left = Ui.button("⟲", "default", function()
		angle -= math.rad(30)
	end, { small = true, width = 36 })
	local right = Ui.button("⟳", "default", function()
		angle += math.rad(30)
	end, { small = true, width = 36 })
	Ui.col({
		Ui.row({ left, rotate, right }, 4, { h = "C", AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new() }),
		Ui.row(stepButtons, 6, { h = "C", AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new() }),
	}, 10, {
		Name = "Pasos",
		h = "C",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0, vpLeft + (App.vw - vpLeft - panelW - 28) / 2, 1, -16),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		Parent = parent,
	})
end

return Screen
