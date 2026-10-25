-- Mini marco de pruebas compartido por run.luau y ui.luau.
local T = { passed = 0, failed = 0, current = "" }

function T.check(cond: any, what: string)
	if cond then
		T.passed += 1
	else
		T.failed += 1
		print("  ✗ [" .. T.current .. "] " .. what)
	end
end

function T.eq(a: any, b: any, what: string)
	T.check(a == b, what .. " (esperado " .. tostring(b) .. ", obtenido " .. tostring(a) .. ")")
end

function T.test(name: string, fn: () -> ())
	T.current = name
	local before = T.failed
	local ok, err = pcall(fn)
	if not ok then
		T.failed += 1
		print("  ✗ [" .. name .. "] error: " .. tostring(err))
	end
	print((T.failed == before and "✓ " or "✗ ") .. name)
end

function T.finish()
	print(string.format("\n%d comprobaciones correctas, %d fallidas", T.passed, T.failed))
end

return T
