--!strict
--[[ Personal: cuatro departamentos (Producción, Investigación, Marketing y Administración).
	- Inicio: una tarjeta por departamento con empleados, salarios, rendimiento y bonificaciones.
	- Departamento: lista de empleados a la izquierda y detalle del elegido a la derecha (habilidades con su
	  potencial, productividad, cambio de departamento, capacitación e indemnización).
	- Mercado laboral: los 8 candidatos del mes con la mejora real que aportarían (con los topes) y las
	  búsquedas pagas. Todo lo valida el servidor (Actions.hire / setDept / fire / searchCandidates). ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Catalog = require(Shared.Catalog)
local Util = require(Shared.Util)
local Rules = require(Shared.Rules)
local Staff = require(Shared.Staff)

local Ui = require(script.Parent.Ui)
local App = require(script.Parent.App)
local T = Ui.T
local W = Ui.W

local Screen = {
	title = "Personal",
	icon = "users",
	color = Color3.fromHex("#FF9DC1"),
	bg = Color3.fromHex("#33182A"),
}

local function st(): any
	App.ui.staff = App.ui.staff or { view = "inicio", dept = "produccion", sel = nil, hireDept = {} }
	return App.ui.staff
end

local function go(view: string, dept: string?)
	local s = st()
	s.view = view
	if dept then
		s.dept = dept
		s.sel = nil
	end
	App.forceRender()
end

function Screen.head(g: any): { Instance }
	local out = { Ui.chip(#g.employees .. "/" .. g.derived.caps.staff .. " empleados", "cn"), Ui.chip("Salarios " .. Util.money(Rules.salaries(g)) .. "/mes", "cy") }
	if g.payroll and g.payroll.debt > 0 then
		table.insert(out, Ui.chip("Deuda salarial " .. Util.money(g.payroll.debt), "cr"))
	end
	return out
end

-- Color de un departamento (para íconos, chips y barras).
local function deptColor(deptId: string): Color3
	return Color3.fromHex(Staff.dept(deptId).color)
end

-- Dato chico: etiqueta arriba y valor grande abajo (tarjetas de departamento y candidatos).
local function stat(label: string, value: string, color: Color3?, name: string?): Frame
	return Ui.col({
		Ui.inline(label, { size = Ui.S.xs, color = T.mut, weight = W.semi }),
		Ui.inline(value, { size = 17, weight = W.bold, color = color or T.tx, name = name or "Valor" }),
	}, 2, { Name = name and ("Dato_" .. name) or "Dato" })
end

-- Barra de una bonificación: actual / máxima, con aviso al llegar al tope.
local function bonusRow(b: any, color: Color3?): Frame
	local sk = Staff.skill(b.skill)
	local pct = b.cap > 0 and b.value / b.cap * 100 or 0
	local bar = Ui.bar(pct, b.full and T.gr or (color or T.vi), 8)
	return Ui.col({
		Ui.row({
			Ui.grow(Ui.text(sk.name, { size = Ui.S.sm, weight = W.semi })),
			b.full and Ui.chip("Tope", "cg", { height = 20 }) or nil,
			Ui.inline(Staff.format(b.skill, b.value) .. " <font color=\"#8C95A7\">/ " .. Staff.format(b.skill, b.cap) .. "</font>", { size = Ui.S.sm, weight = W.bold, color = b.value > 0 and T.tx or T.mut }),
		}, 8, { v = "C" }),
		bar,
		-- Personal y mobiliario comparten el tope de la habilidad.
		Ui.text("Personal " .. Staff.formatFine(b.skill, b.staff or b.raw) .. " · Mobiliario " .. Staff.formatFine(b.skill, b.furniture or 0) .. ((b.wasted or 0) > 1e-9 and (" · se desperdicia " .. Staff.formatFine(b.skill, b.wasted)) or ""), { size = Ui.S.xs, color = T.tx2, name = "Desglose_" .. b.skill }),
		Ui.text(b.full and "Límite alcanzado entre personal y mobiliario: más personal o muebles en esta habilidad no suman." or sk.effect, { size = Ui.S.xs, color = b.full and T.gr or T.mut }),
	}, 4, { Name = "Bono_" .. b.skill })
end

local function deptCard(g: any, deptId: string): Frame
	local sum = Staff.deptSummary(g, deptId)
	local d = sum.dept
	local col = deptColor(deptId)
	local rows: { Instance? } = {
		Ui.row({
			Ui.ico(d.icon, col, col, 38, { alpha = 0.16, iconSize = 19 }),
			Ui.grow(Ui.col({
				Ui.text(d.name, { size = Ui.S.h3, weight = W.bold }),
				Ui.text(#d.skills .. " habilidades · cada una con su propio límite", { size = Ui.S.xs, color = T.mut }),
			}, 2)),
		}, 10, { v = "C" }),
		Ui.grid({
			stat("Empleados", tostring(sum.count), nil, "Empleados_" .. deptId),
			stat("Salarios/mes", Util.money(sum.salaries)),
			stat("Rendimiento", sum.count > 0 and (Util.round(sum.performance * 100) .. " %") or "—", sum.count > 0 and sum.performance < 0.99 and T.ye or nil),
		}, 3, nil, 8),
		Ui.hr(),
	}
	for _, b in sum.bonuses do
		table.insert(rows, bonusRow(b, col))
	end
	table.insert(rows, Ui.button("Ver departamento", "default", function()
		go("depto", deptId)
	end, { small = true, fill = true, name = "Depto_" .. deptId }))
	return Ui.card(rows, { gap = 10, name = "Tarjeta_" .. deptId })
end

-- Límite global de empleados: ocupación y lo que suma el próximo nivel de oficinas.
local function staffCapCard(g: any): Frame
	local cap = g.derived.caps.staff
	local n = #g.employees
	local office = Rules.officeLevel(g)
	local nextSede = Catalog.SEDES[office + 1]
	local color = n >= cap and T.ye or T.vi
	return Ui.card({
		Ui.row({
			Ui.grow(Ui.col({
				Ui.lbl("Límite global de empleados"),
				Ui.inline(n .. " <font color=\"#8C95A7\">/ " .. cap .. "</font>", { size = 24, weight = W.bold, name = "OcupacionPersonal" }),
			}, 4)),
			Ui.col({
				Ui.inline("Oficinas centrales · nivel " .. office, { size = Ui.S.sm, weight = W.semi, align = "R" }),
				Ui.inline(nextSede and ("Nivel " .. nextSede.level .. ": hasta " .. nextSede.staff .. " empleados") or "Nivel máximo", { size = Ui.S.xs, color = nextSede and T.gr or T.mut, align = "R" }),
			}, 3, { h = "R", Size = UDim2.new(0, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.XY }),
		}, 12, { v = "C" }),
		(Ui.bar(cap > 0 and n / cap * 100 or 0, color, 8)),
		Ui.row({
			Ui.inline(Util.money(Rules.salaries(g)) .. "/mes en salarios", { size = Ui.S.xs, color = T.mut }),
			Ui.spacer(),
			Ui.inline((cap - n > 0) and ((cap - n) .. " puestos libres") or "Sin puestos libres", { size = Ui.S.xs, weight = W.bold, color = cap - n > 0 and T.tx2 or T.ye }),
		}, 8),
	}, { gap = 8, name = "LimitePersonal" })
end

local function skillLines(e: any, deptId: string): { Instance }
	local out = {}
	for _, k in Staff.dept(deptId).skills do
		local v, pot = e.skills[k] or 0, e.potential[k] or 0
		table.insert(out, Ui.row({
			Ui.grow(Ui.text(Staff.skill(k).name, { size = Ui.S.sm })),
			Ui.inline(v .. " / " .. pot, { size = Ui.S.xs, weight = W.bold, color = v >= pot and T.ye or T.tx }),
		}, 8, { Name = "Hab_" .. k }))
	end
	return out
end

-- Habilidad con barra: valor actual (relleno) sobre el potencial (marca) y "actual / potencial".
local function skillBar(name: string, v: number, pot: number, color: Color3, rowName: string?): Frame
	local bar = Ui.bar(v, color, 6)
	local mark = Ui.new("Frame", {
		Name = "Potencial",
		BackgroundColor3 = T.tx2,
		BackgroundTransparency = 0.35,
		Size = UDim2.new(0, 2, 1, 0),
		Position = UDim2.new(math.clamp(pot, 0, 100) / 100, -1, 0, 0),
	})
	mark.Parent = bar
	return Ui.col({
		Ui.row({
			Ui.grow(Ui.text(name, { size = Ui.S.sm })),
			Ui.inline(v .. " <font color=\"#8C95A7\">/ " .. pot .. "</font>", { size = Ui.S.sm, weight = W.bold, color = v >= pot and T.ye or T.tx }),
		}, 8),
		bar,
	}, 4, { Name = rowName })
end

-- Foto del avatar del amigo (miniatura oficial de Roblox: no hace falta pedirla, el motor la carga y la guarda).
local function headshot(userId: number, size: number): ImageLabel
	return Ui.new("ImageLabel", {
		Name = "FotoAmigo",
		BackgroundColor3 = T.p2,
		Size = UDim2.fromOffset(size, size),
		Image = "rbxthumb://type=AvatarHeadShot&id=" .. userId .. "&w=150&h=150",
		Corner = size // 2,
	})
end

-- Identidad del empleado: el amigo de Roblox que es (o el aviso de puesto sin amigo).
local function identityLine(e: any): TextLabel
	if e.friend then
		return Ui.text("@" .. tostring(e.friend.username) .. " · amigo de Roblox", { size = Ui.S.xs, color = T.tx2, name = "UsuarioAmigo" })
	end
	return Ui.text("Sin amigo de Roblox libre: el puesto trabaja igual, no aparece en la oficina y recibirá un amigo cuando haya uno.", { size = Ui.S.xs, color = T.ye, name = "SinAmigo" })
end

-- A quién se incorporaría la próxima contratación (lo decide el servidor; no se elige).
function Screen.nextFriendNote(): Instance
	local f = App.payload and App.payload.friends
	if not f or f.status == "loading" then
		return Ui.note("b", "Cargando tu lista de amigos de Roblox… Si contratás ahora, el puesto recibe su amigo apenas llegue la lista.")
	elseif f.status == "failed" then
		return Ui.note("y", "No se pudo leer tu lista de amigos de Roblox (se reintenta sola). Tus empleados conservan su identidad; quien contrates ahora recibe su amigo después.")
	elseif f.next then
		return Ui.note("g", "Cada empleado es uno de tus amigos de Roblox, asignado solo al contratar. La próxima contratación se incorpora como " .. tostring(f.next.displayName) .. " (@" .. tostring(f.next.username) .. "). Amigos libres: " .. f.available .. " de " .. f.total .. ".")
	end
	if (f.total or 0) == 0 then
		return Ui.note("y", "Tu lista de amigos de Roblox está vacía. Podés contratar igual: cada puesto trabaja, pero no tiene identidad ni aparece en la oficina hasta que agregues amigos (se asignan solos).")
	end
	return Ui.note("y", "Todos tus amigos de Roblox ya trabajan en esta empresa (" .. f.total .. "). Podés contratar igual: el puesto trabaja, pero no tiene identidad ni aparece en la oficina hasta que haya un amigo libre.")
end

local function employeeDetail(g: any, e: any): Frame
	local today = Rules.absDay(g)
	local prod = Staff.productivity(g, e)
	local col = deptColor(e.dept)
	local rows: { Instance? } = {
		Ui.row({
			e.friend and headshot(e.friend.userId, 44) or Ui.ico(Staff.dept(e.dept).icon, col, col, 36, { alpha = 0.16, iconSize = 18 }),
			Ui.grow(Ui.col({
				Ui.text(e.name, { size = 19, weight = W.bold, name = "NombreEmpleado" }),
				identityLine(e),
				Ui.text("Especialidad: " .. Staff.dept(e.spec).name .. " · trabaja en " .. Staff.dept(e.dept).name, { size = Ui.S.xs, color = T.mut }),
			}, 2)),
			e.training and Ui.chip("Capacitándose", "cb") or nil,
		}, 10, { v = "C" }),
		Ui.grid({
			stat("Salario", Util.money(e.salary) .. "/mes"),
			stat("Experiencia", e.months .. (e.months == 1 and " mes" or " meses")),
			stat("Productividad", Util.round(prod * 100) .. " %", prod < 0.99 and T.ye or T.gr),
		}, App.isPhone() and 2 or 3, nil, 8),
		e.dept ~= e.spec and Ui.text("Adaptación a " .. Staff.dept(e.dept).name .. ": " .. Util.round(Staff.adaptation(e) * 100) .. " %.", { size = Ui.S.xs, color = T.ye }) or nil,
	}
	-- Aporte individual a cada beneficio de su departamento actual.
	table.insert(rows, Ui.lbl("Aporte a " .. Staff.dept(e.dept).name))
	for _, k in Staff.dept(e.dept).skills do
		local v = Staff.contribution(g, e, k)
		table.insert(rows, Ui.row({ Ui.grow(Ui.text(Staff.skill(k).name, { size = Ui.S.sm })), Ui.inline(Staff.format(k, v), { size = Ui.S.sm, weight = W.bold, color = v > 0 and T.gr or T.mut }) }, 8))
	end
	table.insert(rows, Ui.lbl("Habilidades de " .. Staff.dept(e.dept).name))
	for _, k in Staff.dept(e.dept).skills do
		table.insert(rows, skillBar(Staff.skill(k).name, e.skills[k] or 0, e.potential[k] or 0, col, "Hab_" .. k))
	end
	-- Las habilidades de los otros departamentos se ven a pedido (útil antes de cambiarlo de departamento).
	local s = st()
	local more = s.moreEmp == e.id
	if more then
		local extra: { Instance? } = { Ui.lbl("Otros departamentos (actual / potencial)") }
		for _, id in Staff.DEPT_ORDER do
			if id ~= e.dept then
				table.insert(extra, Ui.text(Staff.dept(id).name, { size = Ui.S.xs, weight = W.bold, color = T.mut }))
				for _, line in skillLines(e, id) do
					table.insert(extra, line)
				end
			end
		end
		table.insert(rows, Ui.col(extra, 4, { Name = "OtrasHabilidades" }))
	end
	table.insert(rows, Ui.button(more and "Ocultar otras habilidades" or "Ver habilidades en otros departamentos", "q", function()
		s.moreEmp = if more then nil else e.id
		App.forceRender()
	end, { small = true, fill = true, name = "OtrasHab_" .. e.id }))
	table.insert(rows, Ui.hr())
	local options = {}
	for _, id in Staff.DEPT_ORDER do
		table.insert(options, { id, Staff.dept(id).name .. (id == e.spec and " ★" or "") })
	end
	local total, sev, unpaid = Staff.dismissalCost(g, e, today)
	table.insert(rows, Ui.selectF("Departamento", e.dept, options, function(v: any)
		App.request("setDept", { employeeId = e.id, dept = v })
	end, { height = 34, name = "Departamento_" .. e.id }))
	table.insert(rows, Ui.button("Capacitar", "default", function()
		App.openDialog("training", { scope = "individual", employeeId = e.id, dept = e.dept })
	end, { small = true, fill = true, disabled = e.training ~= nil, why = "Ya está en una capacitación", name = "Capacitar_" .. e.id }))
	table.insert(rows, Ui.button("Despedir · " .. Util.money(total), "q", function()
		App.openDialog("confirm", {
			title = "¿Despedir a " .. e.name .. "?",
			body = "Se paga la indemnización: " .. Util.money(e.salary) .. " por año trabajado (proporcional) = " .. Util.money(sev) .. "." .. (unpaid > 0 and (" Además, el sueldo de los días trabajados desde que entró: " .. Util.money(unpaid) .. ".") or "") .. " No se puede deshacer.",
			okLabel = "Despedir",
			danger = true,
			onOk = function()
				App.request("fire", { employeeId = e.id })
			end,
		})
	end, { small = true, fill = true, disabled = g.money < total, why = "No alcanza para la indemnización", name = "Despedir_" .. e.id }))
	return Ui.card(rows, { gap = 6, name = "Detalle_" .. e.id })
end

-- Potencial promedio en las habilidades de su especialidad (solo para mostrar).
local function potentialAvg(c: any): number
	local sum, n = 0, 0
	for _, k in Staff.dept(c.spec).skills do
		sum += c.potential[k] or 0
		n += 1
	end
	return n > 0 and Util.round(sum / n) or 0
end

local function candidateCard(g: any, c: any, full: boolean): Frame
	local s = st()
	s.open = s.open or {}
	local dept = s.hireDept[c.id] or c.spec
	local spec = Staff.dept(c.spec)
	local col = deptColor(c.spec)
	local options = {}
	for _, id in Staff.DEPT_ORDER do
		table.insert(options, { id, Staff.dept(id).name .. (id == c.spec and " ★" or "") })
	end
	local b
	b = Ui.button("Contratar", "p", function()
		App.request("hire", { candidateId = c.id, dept = dept }, { button = b })
	end, { small = true, fill = true, disabled = full, why = "Límite de empleados", name = "Contratar_" .. c.id })
	local rows: { Instance? } = {
		Ui.row({
			Ui.ico(spec.icon, col, col, 34, { alpha = 0.16, iconSize = 17 }),
			Ui.grow(Ui.col({
				-- El candidato es solo un perfil laboral: la persona que se incorpora es un amigo de Roblox.
				Ui.text("Perfil de " .. string.lower(spec.name), { size = 17, weight = W.bold, name = "PerfilCandidato" }),
				Ui.inline(spec.name, { size = Ui.S.sm, weight = W.semi, color = col, name = "Especialidad" }),
			}, 2)),
			c.exceptional and Ui.chip("Extraordinario", "cg") or nil,
		}, 10, { v = "C" }),
		Ui.grid({
			stat("Salario mensual", Util.money(c.salary), nil, "Salario_" .. c.id),
			stat("Potencial", tostring(potentialAvg(c)), T.vi2, "Potencial_" .. c.id),
		}, 2, nil, 8),
	}
	for _, k in spec.skills do
		table.insert(rows, skillBar(Staff.skill(k).name, c.skills[k] or 0, c.potential[k] or 0, col, "Hab_" .. k))
	end
	-- Aporte real al departamento elegido (con los topes de la empresa).
	local gains: { Instance? } = {}
	local total = 0
	for _, p in Staff.previewHire(g, c, dept) do
		total += p.gain
		table.insert(gains, Ui.row({
			Ui.grow(Ui.text(Staff.skill(p.skill).name, { size = Ui.S.xs, color = T.tx2 })),
			Ui.inline(Staff.format(p.skill, p.gain) .. (p.capped and " · tope" or ""), { size = Ui.S.xs, weight = W.bold, color = p.gain > 0 and T.gr or T.mut }),
		}, 6))
	end
	table.insert(rows, Ui.hr())
	table.insert(rows, Ui.selectF("Asignar a", dept, options, function(v: any)
		s.hireDept[c.id] = v
		App.forceRender()
	end, { height = 34, name = "AsignarA_" .. c.id }))
	table.insert(rows, Ui.col({
		Ui.lbl("Aporte real a " .. Staff.dept(dept).name, total > 0 and T.gr or T.mut),
		Ui.col(gains, 3),
	}, 5, { Name = "Aporte_" .. c.id }))
	if dept ~= c.spec then
		table.insert(rows, Ui.text("Fuera de su especialidad empieza al " .. Util.round(Catalog.STAFF.adaptStart * 100) .. " % y se adapta con el tiempo.", { size = Ui.S.xs, color = T.ye }))
	end
	-- Detalle opcional: todas las habilidades, para no cargar cada tarjeta.
	local open = s.open[c.id] == true
	if open then
		local extra: { Instance? } = { Ui.lbl("Todas las habilidades (actual / potencial)") }
		for _, id in Staff.DEPT_ORDER do
			if id ~= c.spec then
				table.insert(extra, Ui.text(Staff.dept(id).name, { size = Ui.S.xs, weight = W.bold, color = T.mut }))
				for _, line in skillLines(c, id) do
					table.insert(extra, line)
				end
			end
		end
		table.insert(extra, Ui.text("Contratar no tiene costo: solo se paga el salario mensual.", { size = Ui.S.xs, color = T.mut }))
		table.insert(rows, Ui.col(extra, 4, { Name = "MasDatos_" .. c.id }))
	end
	table.insert(rows, Ui.row({
		Ui.button(open and "Menos datos" or "Más datos", "q", function()
			s.open[c.id] = not open or nil
			App.forceRender()
		end, { small = true, name = "VerMas_" .. c.id }),
		Ui.grow(b),
	}, 8))
	return Ui.card(rows, { gap = 8, name = "Candidato_" .. c.id })
end

local function searchButton(g: any, special: boolean): Frame
	local s = st()
	local cost = Staff.searchCost(g, special, Rules.year(g))
	return Ui.button((special and ("Búsqueda especializada · " .. Staff.dept(s.dept).name) or "Búsqueda general") .. " · " .. Util.money(cost), special and "default" or "p", function()
		App.openDialog("confirm", {
			title = special and "¿Búsqueda especializada?" or "¿Búsqueda general?",
			body = "Los " .. #g.candidates .. " candidatos actuales que no contrataste se reemplazan por 8 nuevos" .. (special and (" (cada uno con 50 % de chance de ser de " .. Staff.dept(s.dept).name .. ", sin mínimo garantizado)") or " de cualquier departamento") .. ". Cuesta " .. Util.money(cost) .. "; la siguiente del mes costará 50 % más.",
			okLabel = "Buscar",
			onOk = function()
				App.request("searchCandidates", { kind = special and "especializada" or "general", dept = s.dept })
			end,
		})
	end, { small = true, fill = true, disabled = g.money < cost, why = "Fondos insuficientes", name = special and "BusquedaEspecial" or "BusquedaGeneral" })
end

-- Costo por persona de un nivel (mismo redondeo que Staff.trainingPlan con un participante).
local function levelCost(g: any, l: any): number
	return Util.round(l.cost * Staff.eraMult(Rules.year(g)) / 10) * 10
end

-- Tarjeta de un nivel de capacitación: mejora, costo, duración y requisito de oficinas.
local function levelCard(g: any, l: any, office: number): Frame
	local open = office >= l.office
	return Ui.card({
		Ui.row({
			Ui.grow(Ui.text(l.name, { size = Ui.S.h3, weight = W.bold })),
			Ui.chip(open and "Disponible" or "Bloqueado", open and "cg" or "cy"),
		}, 8),
		Ui.inline("+" .. l.gain .. " puntos", { size = 22, weight = W.bold, color = open and T.gr or T.mut, name = "Mejora_" .. l.id }),
		Ui.text("en la habilidad elegida, hasta el potencial de cada persona", { size = Ui.S.xs, color = T.mut }),
		Ui.hr(),
		Ui.line("Costo por persona", Util.money(levelCost(g, l)), { size = Ui.S.sm, padY = 4 }),
		Ui.line("Duración", l.days .. " días de juego", { size = Ui.S.sm, padY = 4 }),
		Ui.line("Requisito", "Oficinas nivel " .. l.office, { size = Ui.S.sm, padY = 4, border = false, color = open and T.gr or T.ye }),
		not open and Ui.text("Tenés oficinas de nivel " .. office .. ". Mejoralas en Compañía › Instalaciones.", { size = Ui.S.xs, color = T.ye }) or nil,
	}, { gap = 6, name = "NivelCap_" .. l.id })
end

-- Capacitaciones en curso y acceso a una capacitación general.
function Screen.trainings(g: any, main: Frame, side: Frame)
	local list = g.trainings or {}
	local office = Rules.officeLevel(g)
	local levels = {}
	for _, l in Catalog.TRAINING.levels do
		table.insert(levels, levelCard(g, l, office))
	end
	Ui.col({ Ui.lbl("Niveles de capacitación"), Ui.grid(levels, App.isPhone() and 1 or 3, nil, 10) }, 8, { Name = "NivelesCapacitacion" }).Parent = main
	Ui.lbl("En curso · " .. #list).Parent = main
	if #list == 0 then
		Ui.empty("flask", "No hay capacitaciones en curso. Podés capacitar a una persona (desde su detalle), a un departamento o a toda la empresa.").Parent = main
	end
	for _, t in list do
		local lvl = Staff.trainingLevel(t.level)
		local people: { Instance? } = {}
		for _, id in t.members do
			for _, e in g.employees do
				if e.id == id then
					table.insert(people, Ui.row({
						Ui.grow(Ui.text(e.name, { size = Ui.S.sm })),
						Ui.inline((e.skills[t.skill] or 0) .. " → " .. (t.results[id] or 0), { size = Ui.S.sm, weight = W.bold, color = T.gr }),
					}, 8))
				end
			end
		end
		local left = math.max(0, t.days - math.floor(t.progress))
		local bar = Ui.bar(t.progress / t.days * 100, T.vi, 8)
		Ui.card({
			Ui.row({
				Ui.grow(Ui.col({
					Ui.text(Staff.skill(t.skill).name .. " · nivel " .. lvl.name, { size = Ui.S.base, weight = W.bold }),
					Ui.text(#t.members .. (#t.members == 1 and " participante" or " participantes") .. " · +" .. lvl.gain .. " puntos", { size = Ui.S.xs, color = T.mut }),
				}, 2)),
				Ui.chip(left .. (left == 1 and " día restante" or " días restantes"), "cb"),
			}, 8),
			bar,
			Ui.inline(math.floor(t.progress) .. " de " .. t.days .. " días", { size = Ui.S.xs, color = T.mut }),
			Ui.col(people, 3),
		}, { gap = 8, name = "Capacitacion_" .. t.id }).Parent = main
	end
	Ui.card({
		Ui.lbl("Nueva capacitación"),
		Ui.text("General: toda la empresa a la vez. También podés capacitar a un departamento (desde su vista) o a una persona (desde su detalle).", { size = Ui.S.sm, color = T.tx2, lineHeight = 1.3 }),
		Ui.button("Capacitación general", "p", function()
			App.openDialog("training", { scope = "general" })
		end, { small = true, fill = true, disabled = #g.employees == 0, why = "Sin empleados", name = "CapacitacionGeneral" }),
		Ui.text("Mientras se capacitan siguen trabajando al " .. Util.round(Catalog.STAFF.trainingProductivity * 100) .. " %. Cada empleado hace una capacitación a la vez. El costo final se ve antes de pagar.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.3 }),
	}, { gap = 8 }).Parent = side
end

function Screen.build(main: Frame, side: Frame)
	local g = App.g
	local s = st()
	local full = #g.employees >= g.derived.caps.staff
	local nav = Ui.row({
		Ui.opt("Departamentos", s.view == "inicio" or s.view == "depto", function()
			go(s.view == "depto" and "depto" or "inicio")
		end, { name = "VerDepartamentos", height = 36 }),
		Ui.opt("Mercado laboral · " .. #g.candidates, s.view == "mercado", function()
			go("mercado")
		end, { name = "MercadoLaboral", height = 36 }),
		Ui.opt("Capacitaciones · " .. #(g.trainings or {}), s.view == "capacitaciones", function()
			go("capacitaciones")
		end, { name = "Capacitaciones", height = 36 }),
	}, 8, { wrap = true })
	nav.Parent = main
	if g.payroll and g.payroll.debt > 0 then
		Ui.note("r", "Deuda salarial: " .. Util.money(g.payroll.debt) .. ". El " .. Util.round(Catalog.STAFF.debtRecoveryShare * 100) .. " % de cada venta se destina a pagarla. Con deuda, la productividad baja " .. Util.round(Catalog.STAFF.debtProductivityPerMonth * 100) .. " % por mes (los empleados no renuncian).").Parent = main
	end
	if full then
		Ui.note("y", "Llegaste al límite de " .. g.derived.caps.staff .. " empleados. Mejorá las oficinas centrales (Compañía › Instalaciones) para contratar más.").Parent = main
	end

	if s.view == "mercado" then
		Ui.text("Cada mes llegan " .. Catalog.STAFF.candidatesPerMonth .. " candidatos nuevos y los que no contrataste se van. Contratar no tiene costo: se paga el salario mensual.", { size = Ui.S.xs, color = T.mut }).Parent = main
		Screen.nextFriendNote().Parent = main
		local cards = {}
		for _, c in g.candidates do
			table.insert(cards, candidateCard(g, c, full))
		end
		if #cards > 0 then
			Ui.grid(cards, App.isPhone() and 1 or 2, nil, 10).Parent = main
		else
			Ui.empty("users", "No quedan candidatos este mes. Llegan 8 nuevos al empezar el próximo, o hacé una búsqueda.").Parent = main
		end
		local options = {}
		for _, id in Staff.DEPT_ORDER do
			table.insert(options, { id, Staff.dept(id).name })
		end
		staffCapCard(g).Parent = side
		Ui.card({
			Ui.lbl("Búsquedas pagas"),
			searchButton(g, false),
			Ui.selectF("Especialidad buscada", s.dept, options, function(v: any)
				s.dept = v
				App.forceRender()
			end, { height = 32, name = "DeptoBusqueda" }),
			searchButton(g, true),
			Ui.text("Búsquedas este mes: " .. ((g.market and g.market.searches) or 0) .. ". Cada una cuesta 50 % más que la anterior; el contador vuelve a cero cada mes.", { size = Ui.S.xs, color = T.mut }),
		}, { gap = 8, name = "Busquedas" }).Parent = side
		return
	end
	if s.view == "capacitaciones" and Screen.trainings then
		Screen.trainings(g, main, side)
		return
	end
	if s.view == "depto" then
		local sum = Staff.deptSummary(g, s.dept)
		local back = Ui.button("‹ Departamentos", "default", function()
			go("inicio")
		end, { small = true, name = "VolverDeptos" })
		local trainDept = Ui.button("Capacitar al departamento", "default", function()
			App.openDialog("training", { scope = "departamento", dept = s.dept })
		end, { small = true, disabled = sum.count == 0, why = "Sin empleados", name = "CapacitarDepto" })
		if App.isPhone() then
			-- En celular el título va en su propia línea (en la fila quedaba en un hueco mínimo y se partía).
			Ui.col({ Ui.text(sum.dept.name, { size = 19, weight = W.bold }), Ui.row({ back, trainDept }, 8, { wrap = true }) }, 8).Parent = main
		else
			Ui.row({ back, Ui.grow(Ui.text(sum.dept.name, { size = 19, weight = W.bold })), trainDept }, 10, { wrap = true }).Parent = main
		end
		local list = {}
		for _, e in sum.members do
			local on = s.sel == e.id
			table.insert(list, Ui.opt((e.friend and e.name or "Sin amigo asignado") .. " · " .. Util.round(Staff.productivity(g, e) * 100) .. " %" .. (e.dept ~= e.spec and " · adaptándose" or "") .. (e.training and " · en capacitación" or ""), on, function()
				s.sel = e.id
				App.forceRender()
			end, { name = "Empleado_" .. e.id, fill = true, height = 36 }))
		end
		if #list == 0 then
			Ui.empty("users", "No hay nadie en " .. sum.dept.name .. ". El juego funciona sin personal; contratar mejora las operaciones.", Ui.button("Abrir el mercado laboral", "p", function()
				go("mercado")
			end, { small = true })).Parent = main
		else
			local sel
			for _, e in sum.members do
				if e.id == s.sel then
					sel = e
				end
			end
			sel = sel or sum.members[1]
			s.sel = sel.id
			local cols = App.isPhone() and 1 or 2
			Ui.grid({ Ui.col(list, 6, { Name = "ListaEmpleados" }), employeeDetail(g, sel) }, cols, nil, 12).Parent = main
		end
		local rows: { Instance? } = { Ui.lbl("Bonificaciones de " .. sum.dept.name) }
		for _, b in sum.bonuses do
			table.insert(rows, bonusRow(b, deptColor(s.dept)))
		end
		Ui.card(rows, { gap = 8, name = "BonosDepto" }).Parent = side
		return
	end
	-- Inicio: límite global y las cuatro tarjetas.
	staffCapCard(g).Parent = main
	local cards = {}
	for _, id in Staff.DEPT_ORDER do
		table.insert(cards, deptCard(g, id))
	end
	Ui.grid(cards, App.isPhone() and 1 or 2, nil, 12).Parent = main
	Ui.card({
		Ui.lbl("Mercado laboral"),
		Ui.text(#g.candidates .. " candidatos este mes.", { size = Ui.S.sm }),
		Ui.button("Abrir el mercado laboral", "p", function()
			go("mercado")
		end, { small = true, fill = true, name = "AbrirMercado" }),
		Ui.text("Las bonificaciones se suman, pero cada beneficio tiene su propio límite. Se aplican enseguida también a lo que ya está en curso, sin devolver gastos ya pagados.", { size = Ui.S.xs, color = T.mut, lineHeight = 1.4 }),
	}, { gap = 8 }).Parent = side
end

return Screen
