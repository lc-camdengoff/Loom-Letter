--[[
Loom Letter - .setting validator

Loads Fusion macro (.setting) files as Lua tables using stub constructors, checks that
every connection / instance input / expression points at something that exists, then
simulates the expression-driven animation over a sample clip so timing bugs show up
without opening Resolve.

Usage (any Lua 5.1 / LuaJIT, including Resolve's own fuscript):
    luajit tools/validate_settings.lua "Fusion/Templates/Edit/Titles/Loom Letter/"*.setting
    fuscript -l lua tools/validate_settings.lua <files...>

Exit code is non-zero when any file has errors.
]]

local V = {}

-- Inputs we rely on for each tool type. This is not the full Fusion list - it is the
-- set of IDs Loom Letter uses, so a typo in a template is caught here.
V.KNOWN_INPUTS = {
	TextPlus = {
		"UseFrameFormatSettings", "Width", "Height", "StyledText", "Font", "Style", "Size",
		"CharacterSpacing", "LineSpacing", "Red1", "Green1", "Blue1", "Alpha1", "Center",
		"HorizontalLeftCenterRight", "VerticalTopCenterBottom", "HorizontalJustificationNew",
		"VerticalJustificationNew", "Comments",
	},
	Transform = {
		"Input", "Center", "Size", "Angle", "Pivot", "Aspect", "Edges", "MotionBlur",
		"Quality", "ShutterAngle", "FlipHoriz", "FlipVert", "EffectMask",
	},
	Merge = {
		"Background", "Foreground", "Blend", "PerformDepthMerge", "ApplyMode", "Center",
		"Size", "Angle", "EffectMask",
	},
	Background = {
		"UseFrameFormatSettings", "Width", "Height", "TopLeftRed", "TopLeftGreen",
		"TopLeftBlue", "TopLeftAlpha", "EffectMask",
	},
	Blur = { "Input", "XBlurSize", "YBlurSize", "LockXY", "EffectMask" },
	RectangleMask = {
		"Center", "Width", "Height", "SoftEdge", "CornerRadius", "Angle", "Invert", "Level",
	},
	BrightnessContrast = { "Input", "Gain", "Brightness", "Contrast", "Gamma", "Saturation" },
}

local MACRO_TYPES = { MacroOperator = true, GroupOperator = true }

local function set(list)
	local s = {}
	for _, v in ipairs(list) do s[v] = true end
	return s
end

for k, v in pairs(V.KNOWN_INPUTS) do V.KNOWN_INPUTS[k] = set(v) end

-- Build a sandbox where any capitalised global is a constructor that tags its table.
local function make_env()
	local env = {}
	env.ordered = function() return function(t) return t end end
	setmetatable(env, {
		__index = function(_, name)
			return function(t)
				if type(t) ~= "table" then t = { t } end
				t.__type = name
				return t
			end
		end,
	})
	return env
end

function V.load(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, err end
	local src = f:read("*a")
	f:close()
	local chunk, perr = loadstring("return " .. src, "@" .. path)
	if not chunk then return nil, "syntax error: " .. tostring(perr) end
	setfenv(chunk, make_env())
	local ok, result = pcall(chunk)
	if not ok then return nil, "evaluation error: " .. tostring(result) end
	return result
end

local function find_macro(root)
	for name, tool in pairs(root.Tools or {}) do
		if type(tool) == "table" and MACRO_TYPES[tool.__type] then
			return name, tool
		end
	end
end

-- Find `Tool.Input` references in a Fusion expression (ignores comp./math. etc.).
local IGNORE_PREFIX = { comp = true, math = true, string = true, table = true, self = true }

local function expression_refs(expr)
	local refs = {}
	for tool, input in expr:gmatch("([%a_][%w_]*)%.([%a_][%w_]*)") do
		if not IGNORE_PREFIX[tool] then refs[#refs + 1] = { tool, input } end
	end
	return refs
end

local function has_input(tool, id)
	if tool.Inputs and tool.Inputs[id] then return true end
	if tool.UserControls and tool.UserControls[id] then return true end
	local known = V.KNOWN_INPUTS[tool.__type]
	return known ~= nil and known[id] == true
end

function V.check(root)
	local errors, warnings = {}, {}
	local function err(msg) errors[#errors + 1] = msg end
	local function warn(msg) warnings[#warnings + 1] = msg end

	local mname, macro = find_macro(root)
	if not macro then
		err("no MacroOperator/GroupOperator at top level")
		return errors, warnings
	end
	if root.ActiveTool ~= mname then
		warn(("ActiveTool is %q but the macro is %q"):format(tostring(root.ActiveTool), mname))
	end
	local tools = macro.Tools or {}

	for tname, tool in pairs(tools) do
		if not V.KNOWN_INPUTS[tool.__type] then
			warn(("%s: tool type %s is not in the validator's known list"):format(tname, tostring(tool.__type)))
		end
		for iname, inp in pairs(tool.Inputs or {}) do
			if not has_input(tool, iname) then
				err(("%s.%s: unknown input for %s"):format(tname, iname, tostring(tool.__type)))
			end
			if type(inp) == "table" and inp.SourceOp and not tools[inp.SourceOp] then
				err(("%s.%s: connected to missing tool %s"):format(tname, iname, inp.SourceOp))
			end
			if type(inp) == "table" and inp.Expression then
				local e = inp.Expression
				if e:sub(1, 1) ~= ":" then
					local chunk, perr = loadstring("return " .. e)
					if not chunk then err(("%s.%s: expression does not parse: %s"):format(tname, iname, perr)) end
				else
					local chunk, perr = loadstring(e:sub(2))
					if not chunk then err(("%s.%s: Lua expression does not parse: %s"):format(tname, iname, perr)) end
				end
				for _, ref in ipairs(expression_refs(e)) do
					local rt, ri = ref[1], ref[2]
					local target = tools[rt]
					if target then
						if not has_input(target, ri) then
							err(("%s.%s: expression references unknown input %s.%s"):format(tname, iname, rt, ri))
						end
					elseif has_input(tool, rt) then
						-- same-tool reference such as Message.Value inside a Lua expression
					else
						err(("%s.%s: expression references unknown tool %s"):format(tname, iname, rt))
					end
				end
			end
		end
	end

	for key, ii in pairs(macro.Inputs or {}) do
		local t = tools[ii.SourceOp]
		if not t then
			err(("macro input %s: SourceOp %s does not exist"):format(key, tostring(ii.SourceOp)))
		elseif not has_input(t, ii.Source) then
			err(("macro input %s: %s has no input %s"):format(key, ii.SourceOp, tostring(ii.Source)))
		end
	end

	local outs = macro.Outputs or {}
	if not outs.MainOutput1 then
		err("macro has no MainOutput1")
	end
	for key, o in pairs(outs) do
		if not tools[o.SourceOp] then
			err(("macro output %s: SourceOp %s does not exist"):format(key, tostring(o.SourceOp)))
		end
	end

	return errors, warnings, macro
end

-- Expression simulation -----------------------------------------------------

local function point(x, y)
	return { X = x, Y = y, [1] = x, [2] = y }
end

local function static_value(tool, id)
	local inp = tool.Inputs and tool.Inputs[id]
	if type(inp) == "table" and inp.Value ~= nil then return inp.Value end
	local uc = tool.UserControls and tool.UserControls[id]
	if uc and uc.INP_Default ~= nil then return uc.INP_Default end
	return nil
end

local function wrap(v)
	if type(v) == "table" and v[1] and v[2] and not v.__type then return point(v[1], v[2]) end
	if type(v) == "string" then
		return setmetatable({ Value = v }, { __tostring = function() return v end })
	end
	return v
end

--- Evaluate every expression of `macro` at frame `t` of a clip spanning [rs, re].
function V.simulate(macro, t, rs, re)
	local tools = macro.Tools
	local cache, busy = {}, {}
	local evaluate

	local function tool_proxy(tname)
		return setmetatable({}, {
			__index = function(_, id) return evaluate(tname, id) end,
		})
	end

	local base = {
		min = math.min, max = math.max, abs = math.abs, floor = math.floor, ceil = math.ceil,
		sin = math.sin, cos = math.cos, sqrt = math.sqrt, pi = math.pi, pow = math.pow,
		iif = function(c, a, b) if c ~= 0 and c then return a end return b end,
		Point = point, time = t, comp = { RenderStart = rs, RenderEnd = re },
		math = math, string = string, table = table, tostring = tostring, tonumber = tonumber,
	}

	evaluate = function(tname, id)
		local key = tname .. "." .. id
		if cache[key] ~= nil then return cache[key] end
		if busy[key] then error("expression cycle at " .. key) end
		local tool = tools[tname]
		if not tool then error("unknown tool " .. tname) end
		local inp = tool.Inputs and tool.Inputs[id]
		local value
		if type(inp) == "table" and inp.Expression then
			busy[key] = true
			local src = inp.Expression
			local chunk
			if src:sub(1, 1) == ":" then
				chunk = assert(loadstring(src:sub(2)))
			else
				chunk = assert(loadstring("return " .. src))
			end
			local env = setmetatable({}, {
				__index = function(_, name)
					if base[name] ~= nil then return base[name] end
					if tools[name] then return tool_proxy(name) end
					if has_input(tool, name) then return evaluate(tname, name) end
					return nil
				end,
			})
			setfenv(chunk, env)
			value = chunk()
			busy[key] = nil
		else
			value = static_value(tool, id)
		end
		value = wrap(value)
		cache[key] = value
		return value
	end

	local results = {}
	for tname, tool in pairs(tools) do
		for id, inp in pairs(tool.Inputs or {}) do
			if type(inp) == "table" and inp.Expression then
				local v = evaluate(tname, id)
				if type(v) == "table" and v.Value ~= nil then v = v.Value end
				results[tname .. "." .. id] = v
			end
		end
	end
	return results
end

local function fmt(v)
	if type(v) == "number" then return ("%.3f"):format(v) end
	if type(v) == "table" and v.X then return ("(%.3f, %.3f)"):format(v.X, v.Y) end
	return ("%q"):format(tostring(v))
end

local function is_num(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

--- Check the animation behaves like a title: hidden at both ends, fully on in the middle.
function V.check_animation(macro, rs, re)
	local errors, lines = {}, {}
	local frames = { rs, rs + 5, rs + 15, math.floor((rs + re) / 2), re - 10, re - 5, re }
	local series = {}
	for _, t in ipairs(frames) do
		local ok, res = pcall(V.simulate, macro, t, rs, re)
		if not ok then
			errors[#errors + 1] = ("frame %d: %s"):format(t, tostring(res))
			return errors, lines
		end
		for k, v in pairs(res) do
			series[k] = series[k] or {}
			series[k][#series[k] + 1] = v
			if type(v) == "number" and not is_num(v) then
				errors[#errors + 1] = ("%s is not a finite number at frame %d"):format(k, t)
			end
		end
	end
	local keys = {}
	local reveals_text = false -- e.g. a typewriter hides the title by typing, not by fading
	for k in pairs(series) do
		keys[#keys + 1] = k
		if k:match("%.StyledText$") then reveals_text = true end
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local parts = {}
		for i, v in ipairs(series[k]) do parts[i] = fmt(v) end
		lines[#lines + 1] = ("    %-28s %s"):format(k, table.concat(parts, "  "))
		local s = series[k]
		if k:match("%.Blend$") and type(s[1]) == "number" then
			if s[1] > 0.1 and not reveals_text then errors[#errors + 1] = k .. " should start near 0 (hidden)" end
			if s[4] < 0.99 then errors[#errors + 1] = k .. " should be 1 in the middle of the clip" end
			if s[#s] > 0.1 then errors[#errors + 1] = k .. " should end near 0 (hidden)" end
		end
	end
	return errors, lines
end

function V.main(args)
	local failed = 0
	if #args == 0 then
		io.stderr:write("usage: validate_settings.lua <file.setting> [...]\n")
		return 2
	end
	for _, path in ipairs(args) do
		print(("== %s"):format(path))
		local root, lerr = V.load(path)
		if not root then
			print("  ERROR " .. lerr)
			failed = failed + 1
		else
			local errors, warnings, macro = V.check(root)
			for _, w in ipairs(warnings) do print("  warn  " .. w) end
			if macro and #errors == 0 then
				local aerr, lines = V.check_animation(macro, 0, 119)
				print("  frames 0, 5, 15, 59, 109, 114, 119 of a 120-frame clip:")
				for _, l in ipairs(lines) do print(l) end
				for _, e in ipairs(aerr) do errors[#errors + 1] = e end
			end
			for _, e in ipairs(errors) do print("  ERROR " .. e) end
			if #errors > 0 then failed = failed + 1 else print("  ok") end
		end
	end
	print(("%d file(s) checked, %d failed"):format(#args, failed))
	return failed == 0 and 0 or 1
end

if ... ~= "validate_settings" and arg then
	os.exit(V.main(arg))
end

return V
