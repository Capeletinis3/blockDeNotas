--!strict
--[[ Compañía › Instalaciones: lista compacta a la izquierda (oficinas, fábrica, centro de investigación,
	línea 2 y línea 3) y detalle a la derecha con nivel, estado, beneficios actuales, comparación
	antes → después con valores reales (Rules/Catalog), costo, duración, requisitos y el botón de mejora.
	Solo presenta datos: las obras las valida y cobra el servidor (upgradeFacility / buyProduct). ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local View = {}

View.ORDER = { "offices", "factory", "research", "line2", "line3" }

local INFO = {
	offices = { name = "Oficinas centrales", icon = "building", desc = "La sede de la empresa. Define el límite global de empleados, el alcance comercial y qué niveles de capacitación se pueden dar." },
	factory = { name = "Fábrica", icon = "factory", desc = "Donde se arman los autos. Cada nivel fabrica más autos por minuto en cada línea, mejora la calidad y baja el costo por unidad." },
	research = { name = "Centro de investigación", icon = "flask", desc = "Genera los puntos de investigación (PI) que usan las tecnologías del centro de I+D." },
	line2 = { name = "Línea de producción 2", icon = "factory", desc = "Una línea más para fabricar otro lote en paralelo. Compra permanente con dinero del juego." },
	line3 = { name = "Línea de producción 3", icon = "factory", desc = "Desbloqueo permanente con Robux para tu cuenta: vale en todas tus empresas, también en las que crees después. Independiente de la línea 2." },
}

-- Nivel de capacitación más alto que permiten unas oficinas de nivel n.
local function trainingFor(n: number): string
	local best = "—"
	for _, l in Catalog.TRAINING.levels do
		if n >= l.office then
			best = l.name
		end
	end
	return best
end

local function pct(v: number): string
	return (v > 0 and "+" or "") .. Util.num(v, 0) .. " %"
end

--[[ Estado y datos de una instalación: { level, levelText, state, stateKind, current = { {k, v} },
	compare = { {k, antes, después} }, next = Rules.nextFacility, build, checks, owned }.
	Todos los valores salen de las mismas funciones que usa la simulación. ]]
function View.info(g: any, kind: string): any
	local caps = g.derived.caps
	local out: any = { kind = kind, current = {}, compare = {}, checks = {} }
	out.next = (kind ~= "line3") and Rules.nextFacility(g, kind) or nil
	out.build = Rules.build(g, kind)
	if kind == "offices" then
		local n = Rules.officeLevel(g)
		local s = Rules.sede(g)
		out.level = n
		out.levelText = "Nivel " .. n .. " · " .. s.office
		out.current = {
			{ "Límite global de empleados", tostring(s.staff) },
			{ "Alcance comercial", "×" .. Util.num(s.reach, 1) },
			{ "Capacitaciones hasta", trainingFor(n) },
			{ "Etapa de la empresa", s.name },
		}
		local nx = out.next and out.next.def
		if nx then
			out.compare = {
				{ "Límite global de empleados", tostring(s.staff), tostring(nx.staff) },
				{ "Alcance comercial", "×" .. Util.num(s.reach, 1), "×" .. Util.num(nx.reach, 1) },
				{ "Capacitaciones hasta", trainingFor(n), trainingFor(nx.level) },
				{ "Etapa de la empresa", s.name, nx.name },
			}
		end
	elseif kind == "factory" then
		local n = Rules.facilityLevel(g, "factory")
		local f = Rules.factory(g)
		local fx = f.fx or {}
		out.level = n
		out.levelText = "Nivel " .. n .. " · " .. f.name
		out.current = {
			{ "Autos por minuto por línea", Util.num(caps.perLine, 1) },
			{ "Calidad de fábrica", "+" .. (fx.quality or 0) },
			{ "Costo por unidad", pct(fx.unitCostPct or 0) },
			{ "Estaciones hasta nivel", tostring(Rules.maxStationLevel(g)) },
		}
		local nx = out.next and out.next.def
		if nx then
			local nfx = nx.fx or {}
			-- La base por línea escala lineal: mismas mejoras de estaciones, tecnología y personal.
			local after = caps.perLine * nx.perLine / math.max(1, f.perLine)
			out.compare = {
				{ "Autos por minuto por línea", Util.num(caps.perLine, 1), Util.num(after, 1) },
				{ "Calidad de fábrica", "+" .. (fx.quality or 0), "+" .. (nfx.quality or 0) },
				{ "Costo por unidad", pct(fx.unitCostPct or 0), pct(nfx.unitCostPct or 0) },
				{ "Estaciones hasta nivel", tostring(Rules.maxStationLevel(g)), tostring(math.min(10, nx.level * 2)) },
			}
		end
	elseif kind == "research" then
		local n = Rules.facilityLevel(g, "research")
		local r = Rules.researchCenter(g)
		out.level = n
		out.levelText = "Nivel " .. n .. " · " .. r.name
		out.current = {
			{ "PI por minuto (centro)", tostring(r.pi) },
			{ "PI extra por línea fabricando", "+" .. Catalog.RESEARCH_RULES.linePi },
		}
		local nx = out.next and out.next.def
		if nx then
			out.compare = { { "PI por minuto (centro)", tostring(r.pi), tostring(nx.pi) } }
		end
	else
		local idx = kind == "line2" and 2 or 3
		local owned = Rules.ownsLine(g, idx)
		out.owned = owned
		out.level = owned and 1 or 0
		out.levelText = owned and (idx == 2 and "Comprada" or "Desbloqueada") or (idx == 2 and "Sin comprar" or "Bloqueada")
		out.current = {
			{ "Líneas de la empresa", tostring(caps.lines) },
			{ "Capacidad total", Util.num(caps.capacity, 1) .. " autos/min" },
		}
		if not owned then
			out.compare = {
				{ "Líneas de la empresa", tostring(caps.lines), tostring(caps.lines + 1) },
				{ "Capacidad total (autos/min)", Util.num(caps.capacity, 1), Util.num(caps.capacity + caps.perLine, 1) },
			}
		end
	end
	if kind ~= "line3" then
		out.checks = Rules.facilityChecks(g, kind)
	end
	-- Estado
	if out.build then
		out.state, out.stateKind = "En obra", "co"
	elseif kind == "line3" then
		out.state, out.stateKind = out.owned and "Activa" or "Robux", out.owned and "cg" or "cn"
	elseif kind == "line2" and out.owned then
		out.state, out.stateKind = "Activa", "cg"
	elseif not out.next then
		out.state, out.stateKind = "Nivel máximo", "cg"
	else
		local ok = true
		for _, c in out.checks do
			ok = ok and c[1]
		end
		out.ready = ok
		out.state, out.stateKind = ok and "Mejora disponible" or "Faltan requisitos", ok and "cb" or "cy"
	end
	return out
end

local STATE_COLOR = { cg = "#42E58D", cy = "#F7C95C", cb = "#8DB8FF", co = "#FFB36B", cn = "#A9B1C1" }

local function sel(): string
	local s = App.ui.facSel
	if not s or not table.find(View.ORDER, s) then
		s = "offices"
		App.ui.facSel = s
	end
	return s
end

-- Elemento de la lista: ícono, nombre, nivel y estado.
local function listItem(g: any, kind: string, on: boolean): TextButton
	local inf = View.info(g, kind)
	local b = Ui.opt("", on, function()
		App.ui.facSel = kind
		App.forceRender()
	end, { name = "Instalacion_" .. kind, fill = true, height = 60, pad = { 8, 10 } })
	local isLine = kind == "line2" or kind == "line3"
	local sub = isLine and inf.levelText or ("Nivel " .. inf.level)
	if inf.state ~= sub and not (isLine and inf.owned) then
		sub ..= " · <font color=\"" .. (STATE_COLOR[inf.stateKind] or "#A9B1C1") .. "\">" .. inf.state .. "</font>"
	elseif isLine and inf.owned then
		sub = "<font color=\"" .. STATE_COLOR.cg .. "\">" .. inf.levelText .. " · " .. inf.state .. "</font>"
	end
	local title = Ui.inline(INFO[kind].name, { size = Ui.S.sm, weight = W.bold, truncate = true })
	local state = Ui.inline(sub, { size = Ui.S.xs, color = T.mut, truncate = true, name = "EstadoLista" })
	for _, l in { title, state } do
		l.Size = UDim2.new(1, 0, 0, 0)
		l.AutomaticSize = Enum.AutomaticSize.Y
	end
	local row = Ui.row({
		Ui.ico(INFO[kind].icon, on and T.vi3 or T.tx2, T.vi, 34, { alpha = on and 0.3 or 0.12, iconSize = 17 }),
		Ui.grow(Ui.col({ title, state }, 3)),
	}, 10, { Size = UDim2.fromScale(1, 1), AutomaticSize = Enum.AutomaticSize.None })
	row.Parent = b
	return b
end

-- Fila de comparación: dato · antes → después (lo que mejora, en verde).
local function compareRow(k: string, before: string, after: string): Frame
	local changed = before ~= after
	return Ui.row({
		Ui.grow(Ui.text(k, { size = Ui.S.sm, color = T.tx2 })),
		Ui.inline(before, { size = Ui.S.sm, weight = W.semi, color = T.mut }),
		Ui.inline("→", { size = Ui.S.sm, color = T.mut }),
		Ui.inline(after, { size = Ui.S.base, weight = W.bold, color = changed and T.gr or T.tx }),
	}, 8, { Name = "Comparacion" })
end

local function confirmUpgrade(kind: string, nx: any)
	App.openDialog("confirm", {
		title = "¿" .. nx.name .. "?",
		body = "Se paga " .. Util.money(nx.cost) .. " al empezar y la obra dura " .. nx.days .. " días de juego (la organización del personal de Administración la acelera). El beneficio llega al terminarla. Suma " .. Util.round(Catalog.FACILITIES.maintenanceRate * 1000) / 10 .. " % de su costo al mantenimiento mensual.",
		okLabel = "Empezar la obra",
		onOk = function()
			App.request("upgradeFacility", { kind = kind })
		end,
	})
end

local function detail(g: any, kind: string): Frame
	local inf = View.info(g, kind)
	local meta = INFO[kind]
	local rows: { Instance? } = {
		Ui.row({
			Ui.ico(meta.icon, T.vi3, T.vi, 44, { alpha = 0.22, iconSize = 22 }),
			Ui.grow(Ui.col({
				Ui.text(meta.name, { size = Ui.S.h2, weight = W.bold }),
				Ui.text(inf.levelText, { size = Ui.S.sm, color = T.tx2, name = "NivelActual" }),
			}, 3)),
			Ui.chip(inf.state, inf.stateKind, { name = "EstadoInstalacion" }),
		}, 12, { v = "C" }),
		Ui.text(meta.desc, { size = Ui.S.sm, color = T.mut, lineHeight = 1.35 }),
	}
	local cur: { Instance? } = { Ui.lbl("Beneficios actuales") }
	for _, r in inf.current do
		table.insert(cur, Ui.between(r[1], r[2], { size = Ui.S.sm }))
	end
	table.insert(rows, Ui.card(cur, { gap = 6, bg = T.p1, name = "BeneficiosActuales" }))
	if inf.build then
		local b = inf.build
		local speed = Rules.buildSpeed(g)
		local left = math.max(0, math.ceil((b.days - b.progress) / speed))
		table.insert(rows, Ui.card({
			Ui.row({ Ui.grow(Ui.lbl("Obra en curso", T.ye)), Ui.chip("≈ " .. left .. (left == 1 and " día" or " días"), "cy") }, 8),
			(Ui.bar(b.progress / math.max(1, b.days) * 100, T.ye, 8)),
			Ui.text(math.floor(b.progress) .. " de " .. b.days .. " días de obra. El beneficio llega al terminarla.", { size = Ui.S.xs, color = T.mut }),
		}, { gap = 8, name = "ObraEnCurso" }))
	end
	if #inf.compare > 0 then
		local cmp: { Instance? } = { Ui.lbl(if kind == "line2" or kind == "line3" then "Al comprarla" else ("Próximo nivel" .. (inf.next and inf.next.def and (" · " .. inf.next.def.level) or "")), T.gr) }
		if inf.next and inf.next.def then
			table.insert(cmp, Ui.text(inf.next.name, { size = Ui.S.base, weight = W.bold }))
		end
		for _, r in inf.compare do
			table.insert(cmp, compareRow(r[1], r[2], r[3]))
		end
		table.insert(rows, Ui.card(cmp, { gap = 8, bg = T.p1, stroke = T.line, name = "ComparacionMejora" }))
	elseif kind ~= "line2" and kind ~= "line3" and not inf.next then
		table.insert(rows, Ui.note("g", "Nivel máximo: no hay más mejoras para esta instalación."))
	end
	-- Costo, duración, requisitos y botón.
	if kind == "line3" then
		local line3 = Catalog.PRODUCTS.line3
		local ready3 = line3.id ~= 0
		if not inf.owned then
			table.insert(rows, Ui.button("Desbloquear con Robux", "default", function()
				App.request("buyProduct", { product = "line3" })
			end, { fill = true, disabled = not ready3 or g.demo ~= nil, why = (not ready3) and "Compra no configurada todavía" or "No disponible en demostraciones", name = "ComprarLinea3" }))
			if not ready3 then
				table.insert(rows, Ui.text("La compra con Robux todavía no está configurada en esta versión.", { size = Ui.S.xs, color = T.mut }))
			end
		end
	elseif inf.next and not inf.build then
		local nx = inf.next
		local speed = Rules.buildSpeed(g)
		local realDays = math.ceil(nx.days / speed)
		table.insert(rows, Ui.grid({
			(Ui.kv("Costo", Util.money(nx.cost), { name = "CostoMejora", color = g.money >= nx.cost and T.tx or T.re2 })),
			(Ui.kv("Duración", nx.days .. " días", { name = "DuracionMejora", sub = realDays < nx.days and ("≈ " .. realDays .. " con tu personal") or "de juego" })),
		}, 2, nil, 8))
		local req: { Instance? } = { Ui.lbl("Requisitos") }
		local pending = 0
		for _, c in inf.checks do
			if not c[1] then
				pending += 1
			end
			table.insert(req, Ui.row({
				Ui.inline(c[1] and "✓" or "✕", { size = Ui.S.sm, weight = W.bold, color = c[1] and T.gr or T.re2 }),
				Ui.grow(Ui.text(c[2], { size = Ui.S.sm, color = c[1] and T.tx2 or T.re2, weight = c[1] and W.med or W.semi })),
				not c[1] and Ui.chip("Pendiente", "cr", { height = 20 }) or nil,
			}, 8, { Name = c[1] and "Requisito" or "RequisitoPendiente" }))
		end
		table.insert(rows, Ui.card(req, { gap = 6, bg = T.p1, name = "Requisitos" }))
		table.insert(rows, Ui.button((kind == "line2" and "Comprar · " or "Mejorar · ") .. Util.money(nx.cost), "p", function()
			confirmUpgrade(kind, nx)
		end, { fill = true, disabled = pending > 0, why = pending == 1 and "Falta 1 requisito" or ("Faltan " .. pending .. " requisitos"), name = "Mejorar_" .. kind }))
	end
	return Ui.card(rows, { gap = 12, pad = 18, name = "DetalleInstalacion" })
end

-- Sección completa (lista + detalle) para la pantalla Compañía.
function View.build(g: any, phone: boolean): Frame
	local k = sel()
	local items = {}
	for _, kind in View.ORDER do
		table.insert(items, listItem(g, kind, kind == k))
	end
	local caps = g.derived.caps
	local list = Ui.col({
		Ui.col(items, 6, { Name = "ListaInstalaciones" }),
		Ui.between("Capacidad total", caps.lines .. (caps.lines == 1 and " línea · " or " líneas · ") .. Util.num(caps.capacity, 1) .. " autos/min", { size = Ui.S.xs }),
		Ui.between("Mantenimiento mensual", Util.money(Rules.maintenance(g)), { size = Ui.S.xs }),
	}, 10)
	local body
	if phone then
		body = Ui.col({ list, detail(g, k) }, 12)
	else
		list.Size = UDim2.new(0.36, -6, 0, 0)
		local d = detail(g, k)
		d.Size = UDim2.new(0.64, -6, 0, 0)
		body = Ui.row({ list, d }, 12, { v = "T" })
	end
	return Ui.card({ Ui.lbl("Instalaciones"), body }, { gap = 12, pad = 18, name = "Sede" })
end

return View
