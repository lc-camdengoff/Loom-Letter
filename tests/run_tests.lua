--[[
Loom Letter headless tests. Runs without Resolve by loading the panel script in test
mode and driving it with small mock Resolve / Fusion objects.

    luajit tests/run_tests.lua
    fuscript -l lua tests/run_tests.lua      (Resolve's bundled interpreter)
]]

local root = ((arg and arg[0]) or ""):match("^(.*)[/\\]tests[/\\][^/\\]*$") or "."
local SCRIPT = root .. "/Fusion/Scripts/Utility/Loom Letter.lua"
local TEMPLATES = root .. "/Fusion/Templates/Edit/Titles/Loom Letter"

LOOMLETTER_TEST = true
local LL = assert(loadfile(SCRIPT))()
LL.quiet = true
local V = assert(loadfile(root .. "/tools/validate_settings.lua"))("validate_settings")

local passed, failed = 0, 0
local current = "?"

local function test(name, fn)
	current = name
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("ok    " .. name)
	else
		failed = failed + 1
		print("FAIL  " .. name .. "\n      " .. tostring(err))
	end
end

local function eq(a, b, msg)
	if a ~= b then error(("%s: expected %s, got %s"):format(msg or "value", tostring(b), tostring(a)), 2) end
end

local function near(a, b, msg, tol)
	tol = tol or 1e-6
	if type(a) ~= "number" or math.abs(a - b) > tol then
		error(("%s: expected %.6f, got %s"):format(msg or "value", b, tostring(a)), 2)
	end
end

local function truthy(v, msg)
	if not v then error(msg or "expected a true value", 2) end
end

-- ---------------------------------------------------------------------------------------
-- Mocks (tests/mocks.lua)
-- ---------------------------------------------------------------------------------------

local M = assert(loadfile(root .. "/tests/mocks.lua"))()
local mock_item, mock_timeline, mock_comp = M.item, M.timeline, M.comp

-- Evaluate a Fusion simple expression at frame t of a clip spanning [rs, re].
local function eval_expr(e, t, rs, re)
	local chunk = assert(loadstring("return " .. e))
	setfenv(chunk, {
		min = math.min, max = math.max, time = t, comp = { RenderStart = rs, RenderEnd = re },
		Point = function(x, y) return { X = x, Y = y } end,
	})
	return chunk()
end

-- ---------------------------------------------------------------------------------------
-- Pure helpers
-- ---------------------------------------------------------------------------------------

test("num formats expression constants", function()
	eq(LL.num(1), "1")
	eq(LL.num(0.5), "0.5")
	eq(LL.num(-90), "-90")
	eq(LL.num(1.25), "1.25")
	eq(LL.num(10), "10")
	eq(LL.num(-0.00001), "0")
	eq(LL.num(1 / 3), "0.3333")
end)

test("parseHex", function()
	local c = LL.parseHex("#FF8000")
	near(c[1], 1); near(c[2], 128 / 255); near(c[3], 0)
	c = LL.parseHex("fff")
	near(c[1], 1); near(c[2], 1); near(c[3], 1)
	eq(LL.parseHex(""), nil)
	eq(LL.parseHex("#12345"), nil)
	eq(LL.parseHex("zzzzzz"), nil)
end)

test("parseFrameRate", function()
	local fps, df = LL.parseFrameRate("23.976")
	near(fps, 23.976); eq(df, false)
	fps, df = LL.parseFrameRate("29.97 DF")
	near(fps, 29.97); eq(df, true)
	fps, df = LL.parseFrameRate("25")
	eq(fps, 25); eq(df, false)
end)

test("timecodeToFrames non-drop", function()
	eq(LL.timecodeToFrames("01:00:00:00", 24, false), 86400)
	eq(LL.timecodeToFrames("00:00:01:12", 23.976, false), 36)
	eq(LL.timecodeToFrames("00:00:10:00", 25, false), 250)
	eq(LL.timecodeToFrames("nonsense", 24, false), nil)
end)

test("timecodeToFrames drop-frame (29.97 / 59.94)", function()
	eq(LL.timecodeToFrames("00:00:59;29", 29.97, true), 1799)
	eq(LL.timecodeToFrames("00:01:00;02", 29.97, true), 1800)
	eq(LL.timecodeToFrames("00:10:00;00", 29.97, true), 17982)
	eq(LL.timecodeToFrames("01:00:00;00", 29.97, true), 107892)
	eq(LL.timecodeToFrames("00:01:00;04", 59.94, true), 3600)
	-- a ';' separator implies drop-frame even if the setting string did not say so
	eq(LL.timecodeToFrames("00:10:00;00", 29.97, false), 17982)
end)

-- ---------------------------------------------------------------------------------------
-- Cut transition expressions
-- ---------------------------------------------------------------------------------------

local function spec_value(style_id, side, input, t, opts)
	local style = LL.findPreset(LL.CUTS, style_id)
	local o = { frames = 8, intensity = 1, direction = "Left", motionBlur = true }
	for k, v in pairs(opts or {}) do o[k] = v end
	local specs = LL.buildCutSpec(style, side, o)
	for _, s in ipairs(specs) do
		if s.exprs[input] then return eval_expr(s.exprs[input], t, 0, 99), specs end
	end
	error(("no %s expression in %s/%s"):format(input, style_id, side))
end

test("intensity ramps to 1 exactly on the frames touching the cut", function()
	local out = LL.intensityExpr("out", 8)
	near(eval_expr(out, 99, 0, 99), 1, "out at last frame")
	near(eval_expr(out, 91, 0, 99), 0, "out 8 frames before")
	near(eval_expr(out, 50, 0, 99), 0, "out mid clip")
	near(eval_expr(out, 95, 0, 99), 0.5, "out halfway")
	local inn = LL.intensityExpr("in", 8)
	near(eval_expr(inn, 0, 0, 99), 1, "in at first frame")
	near(eval_expr(inn, 8, 0, 99), 0, "in 8 frames after")
	near(eval_expr(inn, 60, 0, 99), 0, "in mid clip")
	-- follows the clip when Resolve reports a non-zero render range
	near(eval_expr(inn, 1000, 1000, 1099), 1, "offset render range")
end)

test("every cut style is neutral away from the cut", function()
	for _, style in ipairs(LL.CUTS) do
		for _, side in ipairs({ "out", "in" }) do
			local specs = LL.buildCutSpec(style, side, { frames = 8, intensity = 1.5, direction = "Up", motionBlur = true })
			truthy(#specs > 0, style.id .. " builds nodes")
			for _, s in ipairs(specs) do
				truthy(s.name:match("^LL_%a+_%a+%d*$"), "tool name " .. tostring(s.name))
				for input, e in pairs(s.exprs) do
					local v = eval_expr(e, 50, 0, 99)
					if type(v) == "table" then
						near(v.X, 0.5, style.id .. " " .. side .. " " .. input .. ".X")
						near(v.Y, 0.5, style.id .. " " .. side .. " " .. input .. ".Y")
					else
						local neutral = (input == "Size" or input == "Gain") and 1 or 0
						near(v, neutral, style.id .. " " .. side .. " " .. input)
					end
				end
			end
		end
	end
end)

test("zoom in is continuous through the cut", function()
	near(spec_value("zoom_in", "out", "Size", 99), 2, "outgoing ends 2x")
	near(spec_value("zoom_in", "in", "Size", 0), 0.5, "incoming starts 0.5x and keeps growing")
	truthy(spec_value("zoom_in", "in", "Size", 4) > 0.5, "incoming grows")
	near(spec_value("zoom_in", "out", "Size", 99, { intensity = 0.5 }), 1.5, "intensity scales")
	near(spec_value("zoom_out", "out", "Size", 99), 0.5, "zoom out shrinks")
	near(spec_value("zoom_out", "in", "Size", 0), 2, "zoom out incoming starts big")
end)

test("whip pan travels one way through the cut", function()
	local a = spec_value("whip", "out", "Center", 99, { direction = "Left" })
	local b = spec_value("whip", "in", "Center", 0, { direction = "Left" })
	near(a.X, -0.5, "outgoing exits left")
	near(b.X, 1.5, "incoming enters from the right")
	local b2 = spec_value("whip", "in", "Center", 3, { direction = "Left" })
	truthy(b2.X < b.X, "incoming keeps moving left")
	local up = spec_value("whip", "out", "Center", 99, { direction = "Up" })
	near(up.Y, 1.5, "up moves the frame up")
	near(up.X, 0.5, "up does not move horizontally")
end)

test("spin keeps rotating the same way", function()
	local out = spec_value("spin", "out", "Angle", 99, { direction = "Left" })
	local inn = spec_value("spin", "in", "Angle", 0, { direction = "Left" })
	near(out, 90, "counter-clockwise out")
	near(inn, -90, "incoming starts behind")
	local cw = spec_value("spin", "out", "Angle", 99, { direction = "Right" })
	near(cw, -90, "Right spins clockwise")
end)

test("flash and blur peak on the cut", function()
	truthy(spec_value("flash", "out", "Gain", 99) > 2, "flash gain")
	near(spec_value("blur", "in", "XBlurSize", 0), 40, "blur size")
end)

test("motion blur toggle", function()
	local style = LL.findPreset(LL.CUTS, "whip")
	eq(LL.buildCutSpec(style, "out", { frames = 8, intensity = 1, direction = "Left", motionBlur = true })[1].values.MotionBlur, 1)
	eq(LL.buildCutSpec(style, "out", { frames = 8, intensity = 1, direction = "Left", motionBlur = false })[1].values.MotionBlur, 0)
end)

-- ---------------------------------------------------------------------------------------
-- Timeline geometry
-- ---------------------------------------------------------------------------------------

test("adjacentPairs only reports butt splices", function()
	local items = { mock_item(200, 50, 1), mock_item(100, 100, 1), mock_item(251, 10, 1) }
	local p = LL.adjacentPairs(items)
	eq(#p, 1, "one cut (the 1-frame gap is not a cut)")
	eq(p[1].frame, 200)
	eq(p[1].a.start, 100)
	eq(p[1].b.start, 200)
end)

test("nearestCut picks the closest cut, ties go to the upper track", function()
	local tl = mock_timeline({
		{ mock_item(0, 100, 1), mock_item(100, 100, 1), mock_item(200, 100, 1) },
		{ mock_item(90, 10, 2), mock_item(100, 50, 2) },
	})
	local c = LL.nearestCut(tl, 104, 0, 48)
	eq(c.frame, 100); eq(c.track, 2, "tie -> upper track")
	c = LL.nearestCut(tl, 104, 1, 48)
	eq(c.track, 1, "explicit track")
	c = LL.nearestCut(tl, 190, 0, 48)
	eq(c.frame, 200)
	eq(LL.nearestCut(tl, 150, 1, 20), nil, "outside radius")
end)

test("nearestCut skips disabled tracks", function()
	local tl = mock_timeline({
		{ mock_item(0, 100, 1), mock_item(100, 100, 1) },
		{ mock_item(0, 102, 2), mock_item(102, 50, 2) },
	}, { disabled = { [2] = true } })
	eq(LL.nearestCut(tl, 101, 0, 48).track, 1)
end)

test("selectionCuts groups by track", function()
	local a, b, c = mock_item(0, 50, 1), mock_item(50, 50, 1), mock_item(100, 50, 1)
	local x, y = mock_item(0, 30, 2), mock_item(40, 30, 2)
	local tl = mock_timeline({ { a, b, c }, { x, y } }, { selected = { c, a, b, x, y } })
	local cuts, n = LL.selectionCuts(tl)
	eq(n, 5)
	eq(#cuts, 2, "two cuts on V1, none on V2 (gap)")
	eq(cuts[1].frame, 50); eq(cuts[2].frame, 100)
end)

test("findTitleTrack places above everything under the title", function()
	local tl = mock_timeline({ { mock_item(0, 1000, 1) }, {}, { mock_item(5000, 100, 3) } })
	local t, added = LL.findTitleTrack(tl, 100, 220)
	eq(t, 2); eq(added, false)
	tl = mock_timeline({ { mock_item(0, 1000, 1) }, { mock_item(150, 50, 2) } })
	t, added = LL.findTitleTrack(tl, 100, 220)
	eq(t, 3, "new track above V2"); eq(added, true)
	tl = mock_timeline({ { mock_item(0, 1000, 1) }, {}, {} }, { locked = { [2] = true } })
	eq((LL.findTitleTrack(tl, 100, 220)), 3, "skips locked V2")
	tl = mock_timeline({ { mock_item(0, 100, 1) }, {} })
	eq((LL.findTitleTrack(tl, 100, 220)), 1, "empty spot on V1 is fine")
end)

-- ---------------------------------------------------------------------------------------
-- Fusion comp surgery
-- ---------------------------------------------------------------------------------------

test("insertChain / removeChain rewire around MediaOut", function()
	local comp = mock_comp()
	eq(comp:chain(), "MediaIn1 > MediaOut1")
	local zoom = LL.findPreset(LL.CUTS, "zoom_in")
	local flash = LL.findPreset(LL.CUTS, "flash")
	local o = { frames = 8, intensity = 1, direction = "Left", motionBlur = true }
	LL.insertChain(comp, LL.buildCutSpec(zoom, "in", o), { side = "in", style = "zoom_in" })
	eq(comp:chain(), "MediaIn1 > LL_In_ZoomIn > MediaOut1")
	LL.insertChain(comp, LL.buildCutSpec(flash, "out", o), { side = "out", style = "flash" })
	eq(comp:chain(), "MediaIn1 > LL_In_ZoomIn > LL_Out_Flash > LL_Out_Flash2 > MediaOut1")
	eq(comp.undo, 0, "undo blocks balanced"); eq(comp.locked, 0, "locks balanced")
	local t = comp:FindTool("LL_In_ZoomIn")
	truthy(t.inputs.Size.expression:find("comp.RenderStart", 1, true), "expression set")
	eq(t.values.Edges, 3, "mirror edges")
	eq(t:GetData("LoomLetter").side, "in")
	eq(LL.removeChain(comp, "out"), 2)
	eq(comp:chain(), "MediaIn1 > LL_In_ZoomIn > MediaOut1")
	eq(LL.removeChain(comp, nil), 1)
	eq(comp:chain(), "MediaIn1 > MediaOut1")
	eq(#comp.tools, 2, "only MediaIn/MediaOut left")
end)

test("insertChain leaves the comp untouched on failure", function()
	local comp = mock_comp()
	local bad = { { reg = "Transform", values = {}, exprs = {} }, { reg = "Nope", values = {}, exprs = {} } }
	local real_add = comp.AddTool
	comp.AddTool = function(self, reg) if reg == "Nope" then return nil end return real_add(self, reg) end
	local ok = pcall(LL.insertChain, comp, bad, { side = "out" })
	eq(ok, false)
	eq(comp:chain(), "MediaIn1 > MediaOut1")
	eq(comp.undo, 0); eq(comp.locked, 0)
end)

-- ---------------------------------------------------------------------------------------
-- Titles: panel presets must match what is inside the templates
-- ---------------------------------------------------------------------------------------

test("every title preset matches its template", function()
	for _, p in ipairs(LL.TITLES) do
		local path = TEMPLATES .. "/" .. p.template .. ".setting"
		local tree = assert(V.load(path))
		local errors, _, macro = V.check(tree)
		eq(#errors, 0, p.template .. " validates")
		local tools = macro.Tools
		local function need(tool, input)
			truthy(tools[tool], ("%s: no tool %s"):format(p.template, tool))
			truthy(tools[tool].Inputs[input] or (tools[tool].UserControls or {})[input]
				or V.KNOWN_INPUTS[tools[tool].__type][input],
				("%s: %s has no input %s"):format(p.template, tool, input))
		end
		for _, t in ipairs(p.textTargets or {}) do need(t[1], t[2]) end
		for _, t in ipairs(p.text2Targets or {}) do need(t[1], t[2]) end
		for _, name in ipairs(p.fontTools or {}) do need(name, "Font"); need(name, "Style") end
		for _, list in ipairs({ p.colorTargets or {}, p.accentTargets or {} }) do
			for _, t in ipairs(list) do need(t[1], t[2] == "bg" and "TopLeftRed" or "Red1") end
		end
		for _, t in ipairs(p.fpsTargets or {}) do need(t[1], t[2]) end
		truthy(p.category and LL.CATEGORY_NAMES[p.category], p.name .. " has a known category")
		if p.inFrames then need(p.host, "InFrames"); eq(tools[p.host].Inputs.InFrames.Value, p.inFrames, p.template .. " intro default") end
		if p.outFrames then need(p.host, "OutFrames"); eq(tools[p.host].Inputs.OutFrames.Value, p.outFrames, p.template .. " outro default") end
	end
end)

test("titleChanges only overrides what the user filled in", function()
	local lt = LL.findPreset(LL.TITLES, "Lower Third")
	local changes = LL.titleChanges(lt, { text = "Sam Lee", text2 = "", font = "", style = " ", color = "#ff0000",
		accent = "nope", inFrames = 10, outFrames = 6 })
	local got = {}
	for _, c in ipairs(changes) do got[c[1] .. "." .. c[2]] = c[3] end
	eq(got["NameText.StyledText"], "Sam Lee")
	eq(got["RoleText.StyledText"], nil, "empty line 2 keeps the template text")
	eq(got["NameText.Font"], nil); eq(got["NameText.Style"], nil)
	near(got["NameText.Red1"], 1); near(got["NameText.Green1"], 0)
	eq(got["Accent.TopLeftRed"], nil, "invalid accent ignored")
	eq(got["NameText.InFrames"], 10); eq(got["NameText.OutFrames"], 6)
	local tw = LL.findPreset(LL.TITLES, "Typewriter")
	changes = LL.titleChanges(tw, { text = "hello", inFrames = 5, outFrames = 3 })
	got = {}
	for _, c in ipairs(changes) do got[c[1] .. "." .. c[2]] = c[3] end
	eq(got["Title.Message"], "hello", "typewriter text goes to Message")
	eq(got["Title.InFrames"], nil, "typewriter has no intro timing")
end)

test("titleChanges converts numbers and passes the frame rate", function()
	local cd = LL.findPreset(LL.TITLES, "Countdown")
	local got = {}
	for _, c in ipairs(LL.titleChanges(cd, { text = " 1,200 ", fps = 29.97, accent = "#00ff00" })) do got[c[1] .. "." .. c[2]] = c[3] end
	eq(got["Title.StartSeconds"], 1200, "number field")
	near(got["Title.FPS"], 29.97)
	near(got["Bar.TopLeftGreen"], 1, "bg accent")
	got = {}
	for _, c in ipairs(LL.titleChanges(cd, { text = "soon" })) do got[c[1] .. "." .. c[2]] = c[3] end
	eq(got["Title.StartSeconds"], nil, "non-numbers are ignored")
	local sw = LL.findPreset(LL.TITLES, "Split Word")
	got = {}
	for _, c in ipairs(LL.titleChanges(sw, { accent = "#0000ff", font = "Inter" })) do got[c[1] .. "." .. c[2]] = c[3] end
	near(got["Title.Blue1"], 1, "text accent")
	eq(got["Right.Font"], "Inter", "font goes to both words")
end)

-- ---------------------------------------------------------------------------------------
-- Updater
-- ---------------------------------------------------------------------------------------

local function read(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function write(path, s)
	local f = assert(io.open(path, "wb"))
	f:write(s)
	f:close()
end

test("manifest parsing and update planning", function()
	local m = LL.parseManifest("version 1.2.3\r\naaa1  Scripts/Utility/Loom Letter.lua\nbbb2  LoomLetter/previews/x.png\n")
	eq(m.version, "1.2.3"); eq(m.count, 2); eq(m.files["LoomLetter/previews/x.png"], "bbb2")
	eq(LL.parseManifest("garbage"), nil)
	local remote = LL.parseManifest(table.concat({
		"version 2", "a1  Scripts/Utility/Loom Letter.lua", "b2  Templates/Edit/Titles/Loom Letter/LL New.setting",
		"c3  LoomLetter/previews/same.png", "d4  ../../etc/passwd", "e5  Scripts/Utility/Other.lua",
	}, "\n"))
	local localM = LL.parseManifest(table.concat({
		"version 1", "a0  Scripts/Utility/Loom Letter.lua", "c3  LoomLetter/previews/same.png",
		"f6  Templates/Edit/Titles/Loom Letter/LL Old.setting",
	}, "\n"))
	local get, remove = LL.planUpdate(localM, remote)
	eq(table.concat(get, ","), "Scripts/Utility/Loom Letter.lua,Templates/Edit/Titles/Loom Letter/LL New.setting",
		"changed + new files only; unsafe paths refused")
	eq(table.concat(remove, ","), "Templates/Edit/Titles/Loom Letter/LL Old.setting")
	get = LL.planUpdate(nil, remote)
	eq(#get, 3, "fresh install downloads every safe file")
end)

test("applyUpdate installs changed files, removes stale ones, rewrites the manifest", function()
	local base = os.tmpname()
	os.remove(base)
	local rootDir = base .. "-ll"
	os.execute("mkdir -p '" .. rootDir .. "/LoomLetter' '" .. rootDir .. "/Templates/Edit/Titles/Loom Letter'")
	local stale = rootDir .. "/Templates/Edit/Titles/Loom Letter/LL Gone.setting"
	write(stale, "old")
	local remoteText = assert(read(root .. "/Fusion/LoomLetter/manifest.txt"))
	local remote = LL.parseManifest(remoteText)
	-- local install: everything current except the panel script, plus a template that was removed upstream
	local lines = { "version 0.0.1" }
	for path, hash in pairs(remote.files) do
		if path ~= "Scripts/Utility/Loom Letter.lua" and not path:find("%.png$") then
			lines[#lines + 1] = hash .. "  " .. path
		end
	end
	lines[#lines + 1] = "0000  Templates/Edit/Titles/Loom Letter/LL Gone.setting"
	write(rootDir .. "/LoomLetter/manifest.txt", table.concat(lines, "\n"))
	local saved_paths, saved_download = LL.paths, LL.download
	LL.paths = { root = rootDir, data = rootDir .. "/LoomLetter" }
	local fetched = {}
	LL.download = function(url, dest)
		local rel = url:sub(#LL.UPDATE_BASE + 1):gsub("%?.*$", ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
		fetched[#fetched + 1] = rel
		local data = read(root .. "/Fusion/" .. rel)
		if not data then return false end
		write(dest, data)
		return true
	end
	local ok, res = pcall(function()
		local check = LL.checkForUpdate()
		truthy(check.available, "update detected")
		return LL.applyUpdate(check)
	end)
	LL.paths, LL.download = saved_paths, saved_download
	truthy(ok, tostring(res))
	truthy(res.installed and res.titlesChanged)
	eq(read(rootDir .. "/Scripts/Utility/Loom Letter.lua"), read(SCRIPT), "script updated")
	truthy(read(rootDir .. "/LoomLetter/previews/title-pop.png"), "previews downloaded")
	eq(read(stale), nil, "removed preset deleted")
	eq(LL.localManifest and LL.parseManifest(read(rootDir .. "/LoomLetter/manifest.txt")).version, remote.version)
	local again = LL.planUpdate(LL.parseManifest(read(rootDir .. "/LoomLetter/manifest.txt")), remote)
	eq(#again, 0, "nothing left to update")
	os.execute("rm -rf '" .. rootDir .. "'")
end)

test("preset names are unique", function()
	for _, list in ipairs({ LL.TITLES, LL.CUTS }) do
		local seen = {}
		for _, p in ipairs(list) do
			truthy(not seen[p.name], "duplicate " .. p.name)
			seen[p.name] = true
		end
	end
end)

-- ---------------------------------------------------------------------------------------
-- Integration: drive the real window code against mock UIManager + Resolve
-- ---------------------------------------------------------------------------------------

local TEMPLATE_SET = {}
for _, p in ipairs(LL.TITLES) do TEMPLATE_SET[p.template] = true end

local function run_panel(tracks, ropts, driver)
	ropts = ropts or {}
	ropts.templates = ropts.templates or TEMPLATE_SET
	local env = M.resolve(tracks, ropts)
	local ui, dispatcher = M.ui(function(win, w, windows) driver(win, w, env, windows) end)
	resolve = env.resolve
	fu = {
		UIManager = ui,
		GetData = function() return env.saved_prefs end,
		SetData = function(_, _, v) env.prefs = v end,
	}
	bmd = { UIDispatcher = dispatcher }
	LL._resolve, LL._sources = nil, {}
	LL.paths = { titles = TEMPLATES }
	local ok, err = pcall(LL.runUI)
	resolve, fu, bmd = nil, nil, nil
	if not ok then error(err, 0) end
	return env
end

local function find_timeline(env, name)
	for _, tl in ipairs(env.project.timelines) do
		if tl.name == name then return tl end
	end
end

local function status(w) return tostring(w.Status.Text) end

test("panel: add a title without touching the user's clips", function()
	local clip = mock_item(86400, 1000, 1, "A-roll")
	local env = run_panel({ { clip } }, {}, function(win, w)
		eq(#w.List.items, #LL.TITLES, "title presets listed")
		eq(w.Pages.CurrentIndex, 0, "titles page")
		w.TText.Text = "Hello World"
		w.TColor.Text = "#FF0000"
		win.On.AddTitle.Clicked({})
		truthy(status(w):find('Added "Slide Up" on V2', 1, true), status(w))
		win.On.LoomLetter.Close({})
	end)
	eq(env.project.current, env.timeline, "user's timeline is current again")
	eq(clip.start, 86400, "A-roll not moved"); eq(clip.dur, 1000, "A-roll not trimmed")
	local placed = env.timeline.tracks[2][1]
	truthy(placed, "title placed on V2")
	eq(placed.start, 86640, "at the playhead")
	eq(placed.dur, 120, "5 seconds at 24 fps")
	eq(placed.comps[1].sets["Title.StyledText"], "Hello World")
	near(placed.comps[1].sets["Title.Red1"], 1); near(placed.comps[1].sets["Title.Green1"], 0)
	local scratch = find_timeline(env, LL.SCRATCH_TIMELINE)
	truthy(scratch, "scratch timeline created")
	eq(scratch.folder and scratch.folder.name, LL.BIN_NAME, "scratch lives in the Loom Letter bin")
	eq(env.prefs and env.prefs.color, "#FF0000", "preferences saved on close")
end)

test("panel: second title reuses the cached source and stacks above the first", function()
	local env = run_panel({ { mock_item(86400, 1000, 1) } }, {}, function(win, w)
		win.On.AddTitle.Clicked({})
		win.On.AddTitle.Clicked({})
	end)
	eq(#env.timeline.tracks[2], 1); eq(#env.timeline.tracks[3], 1, "second title on V3")
	local inserts = 0
	for _, l in ipairs(env.log) do if l:find("^insert") then inserts = inserts + 1 end end
	eq(inserts, 1, "only one scratch insert")
end)

test("panel: titles fall back to compound clips when there is no media pool item", function()
	local env = run_panel({ { mock_item(86400, 1000, 1) } }, { titles_have_mpi = false }, function(win, w)
		for _, it in ipairs(w.List.items) do if it.Text[0] == "Lower Third" then w.List.current = it end end
		win.On.List.CurrentItemChanged({})
		w.TText.Text = "Sam Lee"
		w.TText2.Text = "Producer"
		w.TAccent.Text = "#00FF00"
		win.On.AddTitle.Clicked({})
		truthy(status(w):find("compound clip", 1, true), status(w))
	end)
	local placed = env.timeline.tracks[2][1]
	eq(placed.mpi.kind, "compound")
	local inner = placed.mpi.inner.comps[1].sets
	eq(inner["NameText.StyledText"], "Sam Lee"); eq(inner["RoleText.StyledText"], "Producer")
	near(inner["Accent.TopLeftGreen"], 1)
	-- the scratch keeps one probe instance per template and no compound clips
	local left = find_timeline(env, LL.SCRATCH_TIMELINE).tracks[1]
	eq(#left, 1, "scratch cleaned up")
	eq(left[1].name, "LL Lower Third")
end)

test("panel: long titles retry at the template length", function()
	local env = run_panel({ { mock_item(86400, 1000, 1) } }, { title_max_len = 120 }, function(win, w)
		w.TSeconds.Text = "10"
		win.On.AddTitle.Clicked({})
		truthy(status(w):find("Added", 1, true), status(w))
	end)
	eq(env.timeline.tracks[2][1].dur, 120)
end)

test("panel: apply and re-apply a cut transition at the playhead", function()
	local a, b = mock_item(86400, 240, 1, "A"), mock_item(86640, 360, 1, "B")
	run_panel({ { a, b } }, { playhead = 243 }, function(win, w)
		win.On.ModeCuts.Clicked({})
		eq(w.Pages.CurrentIndex, 1, "transitions page")
		eq(#w.List.items, #LL.CUTS)
		w.List.current = w.List.items[3] -- Whip Pan
		win.On.List.CurrentItemChanged({})
		eq(w.CDirection.Enabled, true, "direction enabled for whip")
		win.On.ApplyCut.Clicked({})
		truthy(status(w):find('Applied "Whip Pan" to the cut on V1', 1, true), status(w))
		win.On.ApplyCut.Clicked({})
	end)
	eq(a.comps[1]:chain(), "MediaIn1 > LL_Out_Whip > MediaOut1", "outgoing clip, no duplicates")
	eq(b.comps[1]:chain(), "MediaIn1 > LL_In_Whip > MediaOut1", "incoming clip")
	truthy(a.comps[1]:FindTool("LL_Out_Whip").inputs.Center.expression:find("comp.RenderEnd", 1, true))
end)

test("panel: selection applies to every cut and remove cleans up", function()
	local c1, c2, c3 = mock_item(86400, 100, 1), mock_item(86500, 100, 1), mock_item(86600, 100, 1)
	local sel = { c1, c2, c3 }
	run_panel({ { c1, c2, c3 } }, { selected = sel }, function(win, w)
		win.On.ModeCuts.Clicked({})
		w.Search.Text = "flash"
		win.On.Search.TextChanged({})
		eq(#w.List.items, 1, "search filters")
		win.On.ApplySelection.Clicked({})
		truthy(status(w):find("2 cut(s)", 1, true), status(w))
		eq(c2.comps[1]:chain(), "MediaIn1 > LL_In_Flash > LL_In_Flash2 > LL_Out_Flash > LL_Out_Flash2 > MediaOut1")
		win.On.RemoveSelection.Clicked({})
		truthy(status(w):find("from 3 clip(s)", 1, true), status(w))
	end)
	for _, c in ipairs(sel) do eq(c.comps[1]:chain(), "MediaIn1 > MediaOut1") end
end)

test("panel: category filter", function()
	run_panel({ { mock_item(86400, 1000, 1) } }, {}, function(win, w)
		eq(w.Category.items[1], "All titles")
		local idx
		for i, c in ipairs(w.Category.items) do if c == "Timers & Counters" then idx = i - 1 end end
		truthy(idx, "counters category listed")
		w.Category.CurrentIndex = idx
		win.On.Category.CurrentIndexChanged({})
		eq(#w.List.items, 4, "four counters")
		w.List.current = w.List.items[1]
		win.On.List.CurrentItemChanged({})
		eq(w.TTextLabel.Text, "End value", "field label follows the preset")
		win.On.ModeCuts.Clicked({})
		eq(w.Category.items[1], "All transitions")
		eq(#w.List.items, #LL.CUTS, "filter reset when switching mode")
	end)
end)

test("panel: diagnostics work with no timeline open", function()
	local env = run_panel({ { mock_item(86400, 100, 1) } }, {}, function(win, w, env, windows)
		env.project.current = nil
		env.timeline.name = "gone"
		win.On.Diag.Clicked({})
		truthy(status(w):find("iagnostics", 1, true), status(w))
	end)
	truthy(find_timeline(env, LL.SCRATCH_TIMELINE), "scratch used instead")
end)

test("panel: problems are reported in the status line", function()
	run_panel({ { mock_item(86400, 100, 1) } }, { playhead = 50 }, function(win, w, env)
		win.On.ModeCuts.Clicked({})
		win.On.ApplyCut.Clicked({})
		truthy(status(w):find("No cut within", 1, true), status(w))
		env.project.current = nil
		win.On.ModeTitles.Clicked({})
		win.On.AddTitle.Clicked({})
		truthy(status(w):find("Open a timeline", 1, true), status(w))
	end)
end)

test("panel: diagnostics run on the scratch timeline only", function()
	local clip = mock_item(86400, 1000, 1)
	local env = run_panel({ { clip } }, {}, function(win, w, _, windows)
		win.On.Diag.Clicked({})
		truthy(status(w):find("iagnostics", 1, true), status(w))
		truthy(windows[2] and windows[2].shown, "report window shown")
	end)
	eq(#env.timeline.tracks, 1, "no tracks added to the user's timeline")
	eq(#env.timeline.tracks[1], 1, "user's timeline unchanged")
	eq(env.project.current, env.timeline)
end)

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
