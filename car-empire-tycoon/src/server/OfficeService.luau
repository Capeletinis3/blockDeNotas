--!strict
--[[ Oficinas centrales: operaciones económicas del mobiliario y de la remodelación (servidor). Las usan las
	acciones officePlace, officeMove, officeRemove y officeRemodel (Actions), que el editor de oficinas del
	cliente pide por Sessions.

	Seguridad:
	- El precio sale siempre de OfficeCatalog (nunca del cliente).
	- Cada operación valida todo antes de cambiar nada; si algo falla no se descuenta dinero ni se toca el
	  inventario. Validación y aplicación corren sin pausas (sin yields): dos solicitudes no se intercalan.
	- opId (= requestId de Sessions) hace idempotente una solicitud repetida también dentro de la partida
	  guardada (g.office.ops): aunque el servidor cambie, la misma solicitud no se aplica dos veces.
	- Cada cambio sube g.office.rev: así la estructura de la partida cambia y el cliente recibe la oficina nueva.
	- Previsualizar y cancelar no pasan por acá (son del cliente): son gratis. ]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("CarEmpireShared")
local Rules = require(Shared.Rules)
local Util = require(Shared.Util)
local Office = require(Shared.Office)
local OfficeCatalog = require(Shared.OfficeCatalog)
local Simulation = require(script.Parent.Simulation)

local OfficeService = {}

local function fail(msg: string): any
	return { ok = false, msg = msg }
end

local function office(g: any): any
	if type(g.office) ~= "table" then
		Office.sanitize(g)
	end
	return g.office
end

local function spot(req: any): any
	return { room = req.room, x = tonumber(req.x), y = tonumber(req.y), rot = tonumber(req.rot) }
end

--[[ Colocar un mueble: req = { item, room, x, y, rot, opId? }.
	Si hay una unidad guardada en el inventario se usa esa (gratis); si no, es una compra: se cobra el precio
	del catálogo solo si el mueble está disponible en el año de la empresa, la ubicación es válida y alcanza el
	dinero. Orden: operación repetida → mueble → propiedad o precio → año → ubicación → fondos → aplicar. ]]
function OfficeService.place(g: any, req: any): any
	if type(req) ~= "table" then
		return fail("Solicitud inválida.")
	end
	local o = office(g)
	if Office.seenOp(o, req.opId) then
		return { ok = true, repeated = true, msg = "Ya estaba aplicado." }
	end
	local item = OfficeCatalog.item(req.item)
	if not item then
		return fail("Mueble desconocido.")
	end
	local fromInventory = Office.count(o, item.id) > 0
	if not fromInventory and not Office.available(item, Rules.year(g)) then
		return fail(item.name .. " todavía no está a la venta (desde " .. item.year .. ").")
	end
	local where = spot(req)
	local ok, why = Office.validatePlacement(o, item, where)
	if not ok then
		return fail(why or "Ubicación inválida.")
	end
	local price = fromInventory and 0 or item.price
	if not fromInventory and not Simulation.canAfford(g, price) then
		return fail("Fondos insuficientes.")
	end
	-- Aplicar (nada de lo anterior cambió el estado).
	if fromInventory then
		Office.takeFromInventory(o, item.id)
	elseif not Simulation.spend(g, price, "sede", "Mueble: " .. item.name) then
		return fail("Fondos insuficientes.")
	end
	local p = { id = Office.newInstanceId(o), item = item.id, room = where.room, x = where.x, y = where.y, rot = where.rot }
	table.insert(o.placed, p)
	o.rev = (o.rev or 0) + 1
	Office.rememberOp(o, req.opId)
	return { ok = true, instance = p.id, item = item.id, paid = price, fromInventory = fromInventory, msg = fromInventory and (item.name .. " colocado.") or (item.name .. " comprado y colocado (" .. Util.money(price) .. ").") }
end

-- Mover o girar un mueble colocado (gratis): req = { instance, room, x, y, rot, opId? }.
function OfficeService.move(g: any, req: any): any
	if type(req) ~= "table" then
		return fail("Solicitud inválida.")
	end
	local o = office(g)
	if Office.seenOp(o, req.opId) then
		return { ok = true, repeated = true, msg = "Ya estaba aplicado." }
	end
	local p = Office.find(o, req.instance)
	if not p then
		return fail("Ese mueble no está colocado.")
	end
	local item = OfficeCatalog.item(p.item)
	local where = spot(req)
	local ok, why = Office.validatePlacement(o, item, where, p.id)
	if not ok then
		return fail(why or "Ubicación inválida.")
	end
	p.room, p.x, p.y, p.rot = where.room, where.x, where.y, where.rot
	o.rev = (o.rev or 0) + 1
	Office.rememberOp(o, req.opId)
	return { ok = true, instance = p.id, paid = 0, msg = "Mueble movido." }
end

-- Retirar un mueble colocado: vuelve al inventario, sin reembolso. req = { instance, opId? }.
function OfficeService.remove(g: any, req: any): any
	if type(req) ~= "table" then
		return fail("Solicitud inválida.")
	end
	local o = office(g)
	if Office.seenOp(o, req.opId) then
		return { ok = true, repeated = true, msg = "Ya estaba aplicado." }
	end
	local p = Office.find(o, req.instance)
	if not p or not Office.removePlaced(o, req.instance) then
		return fail("Ese mueble no está colocado.")
	end
	o.rev = (o.rev or 0) + 1
	Office.rememberOp(o, req.opId)
	return { ok = true, instance = p.id, item = p.item, paid = 0, msg = "Mueble guardado en el inventario." }
end

--[[ Remodelar una habitación completa: req = { room, changes = { floor?, wall?, covering?, lighting? } (ids de
	acabado), rev (office.rev que vio el cliente), quote (total que vio el cliente), opId }.
	El cliente no manda precios ni cantidades: el servidor recalcula la cotización (Office.remodelQuote, con
	el plano real del nivel y el año de la empresa). Se rechaza sin cambiar nada si: la habitación no es del
	nivel actual, hay categorías o ids desconocidos, un acabado es de un año futuro, no hay cambios efectivos,
	la oficina cambió desde que se armó el presupuesto (rev) o el total no coincide (quote), o no alcanza el
	dinero. Lo ya instalado no se cobra; volver a un acabado gratis cuesta 0 y no reembolsa nada. ]]
function OfficeService.remodel(g: any, req: any): any
	if type(req) ~= "table" then
		return fail("Solicitud inválida.")
	end
	local o = office(g)
	if Office.seenOp(o, req.opId) then
		return { ok = true, repeated = true, msg = "Ya estaba aplicado." }
	end
	local roomId = req.room
	if type(roomId) ~= "string" or not OfficeCatalog.room(o.level, roomId) then
		return fail("Esa habitación no existe en estas oficinas.")
	end
	local changes = req.changes
	if type(changes) ~= "table" then
		return fail("Elegí al menos un acabado.")
	end
	local clean = {}
	for kind, id in changes do
		if type(kind) ~= "string" or OfficeCatalog.DEFAULT_FINISH[kind] == nil then
			return fail("Categoría de acabado desconocida.")
		end
		if type(id) ~= "string" or not OfficeCatalog.finish(kind, id) then
			return fail("Acabado desconocido.")
		end
		clean[kind] = id
	end
	local cost, lines = Office.remodelQuote(o, roomId, clean, Rules.year(g))
	if not cost then
		return fail(tostring(lines))
	end
	if #lines == 0 then
		return fail("La habitación ya tiene esos acabados: no hay nada que cobrar.")
	end
	if type(req.rev) ~= "number" or req.rev ~= (o.rev or 0) then
		return fail("La oficina cambió mientras armabas el presupuesto. Revisá el presupuesto actualizado y confirmá de nuevo.")
	end
	if type(req.quote) ~= "number" or req.quote ~= cost then
		return fail("El presupuesto cambió (ahora " .. Util.money(cost) .. "). Revisalo y confirmá de nuevo.")
	end
	if not Simulation.canAfford(g, cost) then
		return fail("Fondos insuficientes para la remodelación (" .. Util.money(cost) .. ").")
	end
	-- Aplicar (nada de lo anterior cambió el estado).
	if not Simulation.spend(g, cost, "sede", "Remodelación: " .. OfficeCatalog.room(o.level, roomId).name) then
		return fail("Fondos insuficientes para la remodelación.")
	end
	local f = o.finishes[roomId]
	if type(f) ~= "table" then
		f = table.clone(OfficeCatalog.DEFAULT_FINISH)
		o.finishes[roomId] = f
	end
	for _, l in lines do
		f[l.kind] = l.id
	end
	o.rev = (o.rev or 0) + 1
	Office.rememberOp(o, req.opId)
	return { ok = true, paid = cost, room = roomId, msg = cost > 0 and ("Remodelación confirmada (" .. Util.money(cost) .. ").") or "Remodelación confirmada (sin costo)." }
end

return OfficeService
