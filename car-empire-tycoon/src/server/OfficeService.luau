--!strict
--[[ Oficinas centrales: operaciones económicas del mobiliario (servidor). Etapa 1: preparadas y probadas,
	pero NO registradas como solicitudes del cliente (Sessions no las expone): todavía no hay editor, así
	que ninguna acción real cobra muebles. La etapa 2 las agrega a la lista de acciones de Sessions.

	Seguridad:
	- El precio sale siempre de OfficeCatalog (nunca del cliente).
	- Cada operación valida todo antes de cambiar nada; si algo falla no se descuenta dinero ni se toca el
	  inventario. Validación y aplicación corren sin pausas (sin yields): dos solicitudes no se intercalan.
	- opId (opcional, texto del cliente) hace idempotente una solicitud repetida: se aplica una sola vez.
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
	Office.rememberOp(o, req.opId)
	return { ok = true, instance = p.id, paid = price, fromInventory = fromInventory, msg = fromInventory and (item.name .. " colocado.") or (item.name .. " comprado y colocado (" .. Util.money(price) .. ").") }
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
	Office.rememberOp(o, req.opId)
	return { ok = true, msg = "Mueble movido." }
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
	if not Office.removePlaced(o, req.instance) then
		return fail("Ese mueble no está colocado.")
	end
	Office.rememberOp(o, req.opId)
	return { ok = true, msg = "Mueble guardado en el inventario." }
end

return OfficeService
