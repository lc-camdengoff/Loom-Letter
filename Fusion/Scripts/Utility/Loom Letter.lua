--[[
Loom Letter - text presets and cut transitions for DaVinci Resolve Studio.

Open it from Workspace > Scripts > Loom Letter (Edit or Cut page).

  Titles       Pick a preset, type your text, click "Add Title at Playhead". The title is
               placed on the first free video track above whatever is under the playhead
               (a new track is added if needed) - nothing on your timeline is rippled.
  Transitions  Park the playhead on a cut (or select a run of clips) and click Apply.
               Loom Letter adds an animated node chain to the end of the outgoing clip and
               the start of the incoming clip, so no handles are needed.

The floating window needs DaVinci Resolve Studio (UIManager is Studio-only since 19.1).
The title templates themselves also work in the free version from the Effects Library.

Everything this script does is logged to <Fusion>/LoomLetter/logs/loomletter.log. When
something misbehaves, run "Diagnostics" in the window and send that report along.
]]

local LL = {}
LL.VERSION = "0.3.1"
LL.BIN_NAME = "Loom Letter"
LL.SCRATCH_TIMELINE = "Loom Letter Scratch"
LL.TOOL_TAG = "LoomLetter"          -- tool:SetData key that marks nodes Loom Letter owns
LL.PREFS_KEY = "LoomLetter.Prefs"
LL.CUT_SEARCH_SECONDS = 2           -- how far from the playhead to look for a cut
LL.UPDATE_REPO = "lc-camdengoff/Loom-Letter"
LL.UPDATE_BRANCH = "main"
LL.UPDATE_INTERVAL = 12 * 3600      -- automatic update checks at most this often (seconds)

local IS_WINDOWS = package and package.config and package.config:sub(1, 1) == "\\"

-- ---------------------------------------------------------------------------------------
-- Small utilities
-- ---------------------------------------------------------------------------------------

-- Errors meant for the user (shown as-is in the status line, no stack trace).
local UserError = {}
UserError.__tostring = function(e) return e.msg end

function LL.fail(msg)
	error(setmetatable({ msg = msg }, UserError), 0)
end

function LL.isUserError(e)
	return getmetatable(e) == UserError
end

--- Resolve returns lists as tables keyed 1..n (sometimes sparse, sometimes with an extra
--- count field such as n = 3); normalise to an array of the objects/strings only.
function LL.list(t)
	local out = {}
	if type(t) ~= "table" then return out end
	local keys = {}
	for k, v in pairs(t) do
		if k ~= "n" and type(v) ~= "number" and type(v) ~= "boolean" then keys[#keys + 1] = k end
	end
	table.sort(keys, function(a, b)
		if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
		return type(a) == "number"
	end)
	for _, k in ipairs(keys) do out[#out + 1] = t[k] end
	return out
end

--- Format a number for a Fusion expression: 4 decimals, no trailing zeros.
function LL.num(x)
	local s = ("%.4f"):format(x)
	s = s:gsub("0+$", ""):gsub("%.$", "")
	if s == "-0" then s = "0" end
	return s
end

function LL.trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- "#RGB" / "#RRGGBB" / "RRGGBB" -> { r, g, b } in 0..1, or nil.
function LL.parseHex(s)
	s = LL.trim(s):gsub("^#", "")
	if #s == 3 then s = s:gsub(".", "%0%0") end
	if #s ~= 6 or s:find("[^%x]") then return nil end
	return {
		tonumber(s:sub(1, 2), 16) / 255,
		tonumber(s:sub(3, 4), 16) / 255,
		tonumber(s:sub(5, 6), 16) / 255,
	}
end

function LL.join(...)
	return table.concat({ ... }, "/")
end

function LL.fileExists(path)
	local f = path and io.open(path, "rb")
	if f then f:close() return true end
	return false
end

-- ---------------------------------------------------------------------------------------
-- Paths, logging, preferences
-- ---------------------------------------------------------------------------------------

LL.paths = {}

--- Per-user Fusion folder for this OS (where install.sh / install.ps1 put Loom Letter).
function LL.userFusionDir()
	if IS_WINDOWS then
		local appdata = os.getenv("APPDATA")
		return appdata and (appdata:gsub("\\", "/") .. "/Blackmagic Design/DaVinci Resolve/Support/Fusion")
	end
	local home = os.getenv("HOME")
	if not home then return nil end
	if jit and jit.os == "OSX" then
		return home .. "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion"
	end
	return home .. "/.local/share/DaVinciResolve/Fusion"
end

--- The Fusion folder this script was installed into, e.g.
--- ~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion
function LL.fusionRoot()
	local info = debug and debug.getinfo and debug.getinfo(1, "S")
	local src = info and info.source or ""
	if src:sub(1, 1) == "@" then
		local root = src:sub(2):match("^(.*)[/\\][Ss]cripts[/\\]")
		if root then return root end
	end
	local user = LL.userFusionDir()
	if user and LL.fileExists(LL.join(user, "Scripts", "Utility", "Loom Letter.lua")) then return user end
	if fu and fu.MapPath then
		local ok, p = pcall(function() return fu:MapPath("Scripts:") end)
		if ok and type(p) == "string" then
			local root = p:match("^(.*)[/\\][Ss]cripts[/\\]?$")
			if root then return root end
		end
	end
	return user
end

local function dir_writable(path)
	local probe = path .. "/.loomletter-probe"
	local f = io.open(probe, "w")
	if not f then return false end
	f:close()
	os.remove(probe)
	return true
end

function LL.ensureDir(path)
	if dir_writable(path) then return end
	if bmd and bmd.createdir then pcall(bmd.createdir, path) end
	if dir_writable(path) then return end
	if IS_WINDOWS then
		os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
	else
		os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
	end
end

function LL.initPaths()
	local root = LL.fusionRoot()
	LL.paths.root = root
	if not root then return end
	LL.paths.titles = LL.join(root, "Templates", "Edit", "Titles", "Loom Letter")
	LL.paths.data = LL.join(root, "LoomLetter")
	LL.paths.previews = LL.join(LL.paths.data, "previews")
	LL.paths.logs = LL.join(LL.paths.data, "logs")
	LL.ensureDir(LL.paths.logs)
	LL.paths.log = LL.join(LL.paths.logs, "loomletter.log")
end

function LL.log(fmt, ...)
	local msg = select("#", ...) > 0 and fmt:format(...) or tostring(fmt)
	if not LL.quiet then print("[Loom Letter] " .. msg) end
	if LL.paths.log then
		local f = io.open(LL.paths.log, "a")
		if f then
			f:write(os.date("%Y-%m-%d %H:%M:%S  "), msg, "\n")
			f:close()
		end
	end
end

function LL.loadPrefs()
	local ok, t = pcall(function() return fu:GetData(LL.PREFS_KEY) end)
	if ok and type(t) == "table" then return t end
	return {}
end

function LL.savePrefs(t)
	pcall(function() fu:SetData(LL.PREFS_KEY, t) end)
end

-- ---------------------------------------------------------------------------------------
-- Presets
-- ---------------------------------------------------------------------------------------

--[[ Title presets map onto the .setting templates in Templates/Edit/Titles/Loom Letter.
     Target lists name the tools inside each template that receive the panel's fields:
       textTargets / text2Targets  { tool, input [, "number"] }   ("number" converts the text)
       colorTargets / accentTargets { tool, "text" | "bg" }       (Text+ fill or Background colour)
       fontTools { tool, ... }        fpsTargets { { tool, input } }  (set from the timeline)
     Adding a preset: build the template (tools/build_templates.py), then add an entry. ]]
local function T(p)
	p.host = p.host or "Title"
	p.template = p.template or ("LL " .. p.name)
	p.preview = p.preview or ("title-" .. (p.name:lower():gsub("[^%w]+", "-")) .. ".png")
	p.textTargets = p.textTargets or { { p.host, "StyledText" } }
	p.fontTools = p.fontTools or { p.host }
	p.colorTargets = p.colorTargets or { { p.host, "text" } }
	return p
end

LL.CATEGORY_ORDER = { "Essential", "Social", "Counters", "Cinematic", "Shapes" }
LL.CATEGORY_NAMES = {
	Essential = "Essential Typography", Social = "Social Media", Counters = "Timers & Counters",
	Cinematic = "Cinematic Titles", Shapes = "Shape Elements",
}

LL.TITLES = {
	-- Essential Typography
	T{ name = "Slide Up", category = "Essential", tag = "Clean", text = "YOUR TITLE HERE", inFrames = 15, outFrames = 12,
		desc = "Rises into place with a soft fade and keeps rising on the way out." },
	T{ name = "Boxed Title", category = "Essential", tag = "Frame", text = "MOTION GRAPHICS", text2 = "WITHOUT HASSLE",
		text2Label = "Caption", inFrames = 18, outFrames = 12,
		desc = "Title inside an accent outline that draws open, with a caption tag underneath.",
		text2Targets = { { "Caption", "StyledText" } }, accentTargets = { { "Box", "bg" }, { "Tag", "bg" } } },
	T{ name = "Tag Title", category = "Essential", tag = "Label", text = "MOTION GRAPHICS", text2 = "WITHOUT HASSLE",
		text2Label = "Tag", inFrames = 15, outFrames = 12,
		desc = "A small accent tag drops in above the title as it rises.",
		text2Targets = { { "Caption", "StyledText" } }, accentTargets = { { "Tag", "bg" } } },
	T{ name = "Split Word", category = "Essential", tag = "Two words", text = "MISTER", text2 = "HORSE",
		textLabel = "Left word", text2Label = "Right word", inFrames = 18, outFrames = 12,
		desc = "Two words slide out from a divider; the left one in the accent colour.",
		text2Targets = { { "Right", "StyledText" } }, fontTools = { "Title", "Right" },
		colorTargets = { { "Right", "text" } }, accentTargets = { { "Title", "text" } } },
	T{ name = "Underline", category = "Essential", tag = "Line", text = "POWERFUL WORKFLOW", inFrames = 18, outFrames = 12,
		desc = "An accent underline wipes out while the title rises onto it.",
		accentTargets = { { "Line", "bg" } } },
	T{ name = "Highlight", category = "Essential", tag = "Marker", text = "KEY TAKEAWAY", inFrames = 20, outFrames = 12,
		desc = "A marker stroke sweeps across and reveals the words, then wipes off to the right.",
		accentTargets = { { "Mark", "bg" } } },
	T{ name = "Pop", category = "Essential", tag = "Bouncy", text = "POP!", inFrames = 12, outFrames = 8,
		desc = "Springs in with an overshoot and pops back out. Great for short words." },
	T{ name = "Typewriter", category = "Essential", tag = "Retro", text = "Type your message here", outFrames = 10,
		desc = "Types the message out one character at a time with a blinking cursor.",
		textTargets = { { "Title", "Message" } } },
	T{ name = "Lower Third", category = "Essential", tag = "Name + role", text = "JANE DOE", text2 = "Title / Role",
		text2Label = "Role", host = "NameText", inFrames = 18, outFrames = 12,
		desc = "Name and role slide out from behind an accent bar.",
		text2Targets = { { "RoleText", "StyledText" } }, accentTargets = { { "Accent", "bg" } } },

	-- Social Media
	T{ name = "Subscribe", category = "Social", tag = "Button", text = "SUBSCRIBE", text2 = "SUBSCRIBED",
		text2Label = "Clicked", inFrames = 12, outFrames = 10, seconds = 3,
		desc = "Red button pops in, gets clicked a second later and turns to Subscribed.",
		textTargets = { { "Title", "ButtonText" } }, text2Targets = { { "Title", "ClickedText" } },
		accentTargets = { { "Button", "bg" } } },
	T{ name = "Follow", category = "Social", tag = "Button", text = "+  FOLLOW", text2 = "FOLLOWING",
		text2Label = "Clicked", inFrames = 12, outFrames = 10, seconds = 3,
		desc = "Blue follow button with a click and a Following state.",
		textTargets = { { "Title", "ButtonText" } }, text2Targets = { { "Title", "ClickedText" } },
		accentTargets = { { "Button", "bg" } } },
	T{ name = "Handle", category = "Social", tag = "@name", text = "@yourname", textLabel = "Handle",
		inFrames = 16, outFrames = 12,
		desc = "A white pill wipes open with an accent icon dot and your handle.",
		accentTargets = { { "Dot", "bg" } } },
	T{ name = "Chat Bubble", category = "Social", tag = "Message", text = "What's up?", textLabel = "Message",
		inFrames = 12, outFrames = 10, seconds = 3,
		desc = "A chat bubble pops out of its tail corner." },

	-- Timers & Counters
	T{ name = "Counter", category = "Counters", tag = "Number", text = "38458", text2 = "$",
		textLabel = "End value", text2Label = "Prefix", inFrames = 10, outFrames = 10,
		desc = "Counts up to a number with thousands separators, prefix and suffix.",
		textTargets = { { "Title", "EndValue", "number" } }, text2Targets = { { "Title", "Prefix" } } },
	T{ name = "Countdown", category = "Counters", tag = "Timer", text = "5", textLabel = "Seconds",
		inFrames = 10, outFrames = 10,
		desc = "MM:SS countdown in a box with a shrinking progress line. Set Seconds to the clip length.",
		textTargets = { { "Title", "StartSeconds", "number" } }, fpsTargets = { { "Title", "FPS" } },
		accentTargets = { { "Bar", "bg" } } },
	T{ name = "Progress Bar", category = "Counters", tag = "Bar", text = "80", text2 = "1980 VOTES",
		textLabel = "Percent", text2Label = "Label", inFrames = 12, outFrames = 12,
		desc = "A bar fills to a percentage while the number counts up.",
		textTargets = { { "Title", "Percent", "number" } }, text2Targets = { { "Title", "StyledText" } },
		accentTargets = { { "Fill", "bg" } } },
	T{ name = "Bar Stat", category = "Counters", tag = "Stat", text = "80", text2 = "YOUR TITLE",
		textLabel = "Percent", text2Label = "Label", inFrames = 12, outFrames = 12,
		desc = "A vertical bar grows next to a big counting percentage.",
		textTargets = { { "Title", "Percent", "number" } }, text2Targets = { { "Title", "StyledText" } },
		accentTargets = { { "Bar", "bg" } } },

	-- Cinematic
	T{ name = "Blur In", category = "Cinematic", tag = "Soft", text = "YOUR TITLE HERE", inFrames = 18, outFrames = 12,
		desc = "Resolves out of a blur while settling from slightly larger." },
	T{ name = "Tracking", category = "Cinematic", tag = "Wide", text = "CINEMATIC", inFrames = 30, outFrames = 15,
		desc = "Wide letter spacing that slowly tightens as the title fades up." },
	T{ name = "Glow", category = "Cinematic", tag = "Glow", text = "HORSE OF STEEL", inFrames = 24, outFrames = 18,
		desc = "Fades up through a bright bloom that settles into a soft glow." },
	T{ name = "Credits", category = "Cinematic", tag = "Credit", text = "Mister Horse", text2 = "Created by",
		textLabel = "Name", text2Label = "Credit line", inFrames = 30, outFrames = 24,
		desc = "Opening-credit style: a small credit line over a slowly drifting name.",
		text2Targets = { { "Credit", "StyledText" } } },
	T{ name = "Flicker", category = "Cinematic", tag = "Neon", text = "PARADOX", inFrames = 20, outFrames = 14,
		desc = "Flickers on and off like a failing light before holding steady." },
	T{ name = "Converge", category = "Cinematic", tag = "Echo", text = "GRAND TITLES", inFrames = 24, outFrames = 16,
		desc = "Echoes slide in from above and below and lock together on an accent line.",
		accentTargets = { { "Line", "bg" } } },

	-- Shape Elements (no text)
	T{ name = "Ring Burst", category = "Shapes", tag = "Burst", host = "Canvas", seconds = 1,
		desc = "A ring bursts outward and thins away. Stack a few with different delays.",
		textTargets = {}, fontTools = {}, colorTargets = { { "Ring", "bg" } } },
	T{ name = "Sparkle", category = "Shapes", tag = "Twinkle", host = "Canvas", seconds = 1,
		desc = "A four-point sparkle swells, turns and fades.",
		textTargets = {}, fontTools = {}, colorTargets = { { "HRay", "bg" } } },
	T{ name = "Speed Lines", category = "Shapes", tag = "Motion", host = "Canvas", seconds = 1,
		desc = "Staggered dashes streak across the frame.",
		textTargets = {}, fontTools = {}, colorTargets = { { "Line2", "bg" } }, accentTargets = { { "Line1", "bg" } } },
	T{ name = "Circle Pop", category = "Shapes", tag = "Pop", host = "Canvas", seconds = 1,
		desc = "A dot pops with an overshoot while a ring ripples out.",
		textTargets = {}, fontTools = {}, colorTargets = { { "Ring", "bg" } }, accentTargets = { { "Dot", "bg" } } },
}

LL.DIRECTIONS = { "Left", "Right", "Up", "Down" }
local DIR_VECTORS = { Left = { -1, 0 }, Right = { 1, 0 }, Up = { 0, 1 }, Down = { 0, -1 } }

local function transform_spec(exprs, o)
	return {
		reg = "Transform",
		values = { Edges = 3, MotionBlur = o.motionBlur and 1 or 0, Quality = 8, ShutterAngle = 180 },
		exprs = exprs,
	}
end

--[[ Cut transitions. build(side, E, o) returns the node chain for one side of the cut.
     side is "out" (end of the outgoing clip) or "in" (start of the incoming clip).
     E is an expression that is 0 away from the cut and 1 on the frames touching it.
     o.intensity scales the effect (1 = default), o.direction is one of LL.DIRECTIONS. ]]
LL.CUTS = {
	{
		id = "zoom_in", short = "ZoomIn", name = "Zoom In", preview = "cut-zoom-in.png", tag = "Zoom", category = "Zoom",
		desc = "Punches through the cut with one continuous zoom and motion blur.",
		ease = "accel",
		build = function(side, E, o)
			local i = LL.num(o.intensity)
			local size = side == "out" and ("1 + %s * %s"):format(i, E) or ("1 / (1 + %s * %s)"):format(i, E)
			return { transform_spec({ Size = size }, o) }
		end,
	},
	{
		id = "zoom_out", short = "ZoomOut", name = "Zoom Out", preview = "cut-zoom-out.png", tag = "Zoom", category = "Zoom",
		desc = "Pulls back through the cut; edges are mirrored so the frame stays full.",
		ease = "accel",
		build = function(side, E, o)
			local i = LL.num(o.intensity)
			local size = side == "out" and ("1 / (1 + %s * %s)"):format(i, E) or ("1 + %s * %s"):format(i, E)
			return { transform_spec({ Size = size }, o) }
		end,
	},
	{
		id = "whip", short = "Whip", name = "Whip Pan", preview = "cut-whip.png", tag = "Motion", category = "Motion",
		desc = "Fast pan with heavy motion blur. Direction sets which way the frame travels.",
		ease = "accel", usesDirection = true,
		build = function(side, E, o)
			local v = DIR_VECTORS[o.direction] or DIR_VECTORS.Left
			local s = side == "out" and 1 or -1
			local dx, dy = LL.num(s * v[1] * o.intensity), LL.num(s * v[2] * o.intensity)
			return { transform_spec({ Center = ("Point(0.5 + %s * %s, 0.5 + %s * %s)"):format(dx, E, dy, E) }, o) }
		end,
	},
	{
		id = "spin", short = "Spin", name = "Spin", preview = "cut-spin.png", tag = "Motion", category = "Motion",
		desc = "Rotates through the cut. Left/Up spin counter-clockwise, Right/Down clockwise.",
		ease = "accel", usesDirection = true,
		build = function(side, E, o)
			local sgn = (o.direction == "Right" or o.direction == "Down") and -1 or 1
			-- the incoming clip starts rotated "behind" and finishes the same turn
			if side == "in" then sgn = -sgn end
			local angle = ("%s * %s"):format(LL.num(sgn * 90 * o.intensity), E)
			local size = ("1 + %s * %s"):format(LL.num(0.25 * o.intensity), E)
			return { transform_spec({ Angle = angle, Size = size }, o) }
		end,
	},
	{
		id = "flash", short = "Flash", name = "Flash", preview = "cut-flash.png", tag = "Light", category = "Light & Blur",
		desc = "Blows out to a bright flash on the cut, with a touch of blur.",
		ease = "smooth",
		build = function(side, E, o)
			local i = o.intensity
			return {
				{ reg = "BrightnessContrast", values = {}, exprs = {
					Gain = ("1 + %s * %s"):format(LL.num(1.5 * i), E),
					Brightness = ("%s * %s"):format(LL.num(0.6 * i), E),
				} },
				{ reg = "Blur", values = {}, exprs = { XBlurSize = ("%s * %s"):format(LL.num(6 * i), E) } },
			}
		end,
	},
	{
		id = "blur", short = "Blur", name = "Blur", preview = "cut-blur.png", tag = "Soft", category = "Light & Blur",
		desc = "Defocuses into the cut and pulls focus on the other side.",
		ease = "smooth",
		build = function(side, E, o)
			return { { reg = "Blur", values = {}, exprs = { XBlurSize = ("%s * %s"):format(LL.num(40 * o.intensity), E) } } }
		end,
	},
}

function LL.findPreset(list, name)
	for _, p in ipairs(list) do
		if p.name == name or p.id == name or p.template == name then return p end
	end
end

--- Expression that is 1 on the frame touching the cut and falls to 0 `frames` away.
function LL.intensityExpr(side, frames)
	local n = LL.num(frames)
	if side == "out" then
		return ("min(max((time - comp.RenderEnd + %s) / %s, 0), 1)"):format(n, n)
	end
	return ("min(max((comp.RenderStart + %s - time) / %s, 0), 1)"):format(n, n)
end

function LL.easeExpr(kind, k)
	if kind == "smooth" then
		return ("(%s * %s * (3 - 2 * %s))"):format(k, k, k)
	end
	-- "accel": cubic, so motion is fastest right at the cut
	return ("(%s * %s * %s)"):format(k, k, k)
end

function LL.buildCutSpec(style, side, o)
	local E = LL.easeExpr(style.ease, LL.intensityExpr(side, o.frames))
	local specs = style.build(side, E, o)
	for i, s in ipairs(specs) do
		s.name = ("LL_%s_%s%s"):format(side == "out" and "Out" or "In", style.short, i > 1 and tostring(i) or "")
	end
	return specs
end

-- ---------------------------------------------------------------------------------------
-- Timecode and timeline geometry (pure functions, covered by tests/run_tests.lua)
-- ---------------------------------------------------------------------------------------

--- "23.976" -> 23.976, false ; "29.97 DF" -> 29.97, true
function LL.parseFrameRate(s)
	s = tostring(s or "")
	local fps = tonumber(s:match("%d+%.?%d*")) or 24
	return fps, s:upper():find("DF", 1, true) ~= nil
end

--- Timecode string -> frame count (drop-frame aware).
function LL.timecodeToFrames(tc, fps, dropFrame)
	local h, m, s, sep, f = tostring(tc or ""):match("^%s*(%d+):(%d+):(%d+)([:;%.,])(%d+)%s*$")
	if not h then return nil end
	h, m, s, f = tonumber(h), tonumber(m), tonumber(s), tonumber(f)
	local nominal = math.floor(fps + 0.5)
	local frames = ((h * 60 + m) * 60 + s) * nominal + f
	if dropFrame or sep == ";" then
		local drop = math.floor(nominal / 15 + 0.5) -- 2 per minute at 29.97, 4 at 59.94
		local minutes = h * 60 + m
		frames = frames - drop * (minutes - math.floor(minutes / 10))
	end
	return frames
end

--- Frame count -> timecode string (inverse of timecodeToFrames, drop-frame aware).
function LL.framesToTimecode(frames, fps, dropFrame)
	local nominal = math.floor(fps + 0.5)
	frames = math.floor(frames + 0.5)
	local sep = ":"
	if dropFrame then
		local drop = math.floor(nominal / 15 + 0.5)
		local perMinute = nominal * 60 - drop
		local perTen = nominal * 600 - drop * 9
		local tens, rem = math.floor(frames / perTen), frames % perTen
		frames = frames + drop * 9 * tens
		if rem > drop then frames = frames + drop * math.floor((rem - drop) / perMinute) end
		sep = ";"
	end
	local f = frames % nominal
	local total = math.floor(frames / nominal)
	return ("%02d:%02d:%02d%s%02d"):format(math.floor(total / 3600), math.floor(total / 60) % 60, total % 60, sep, f)
end

--- Timeline item -> start, exclusive end (start + duration, so it never depends on
--- whether GetEnd() is inclusive).
function LL.itemSpan(item)
	local s = item:GetStart()
	return s, s + item:GetDuration()
end

function LL.trackOf(item)
	local a, b = item:GetTrackTypeAndIndex()
	if type(a) == "table" then a, b = a[1], a[2] end
	return a, tonumber(b)
end

--- Adjacent (butt-spliced) pairs on one track: { a = outgoing, b = incoming, frame = cut }
function LL.adjacentPairs(items)
	local sorted = {}
	for i, it in ipairs(items) do sorted[i] = it end
	table.sort(sorted, function(x, y) return x:GetStart() < y:GetStart() end)
	local out = {}
	for i = 1, #sorted - 1 do
		local a, b = sorted[i], sorted[i + 1]
		local _, aEnd = LL.itemSpan(a)
		if math.abs(aEnd - b:GetStart()) < 0.5 then
			out[#out + 1] = { a = a, b = b, frame = b:GetStart() }
		end
	end
	return out
end

--- Nearest cut to `frame` within `radius` frames. trackIndex 0/nil searches all enabled
--- video tracks (ties go to the upper track).
function LL.nearestCut(tl, frame, trackIndex, radius)
	local best
	local first, last = 1, tl:GetTrackCount("video")
	if trackIndex and trackIndex > 0 then first, last = trackIndex, trackIndex end
	for t = last, first, -1 do
		if tl:GetIsTrackEnabled("video", t) ~= false then
			for _, c in ipairs(LL.adjacentPairs(LL.list(tl:GetItemListInTrack("video", t)))) do
				local d = math.abs(c.frame - frame)
				if d <= radius and (not best or d < best.distance) then
					c.track, c.distance = t, d
					best = c
				end
			end
		end
	end
	return best
end

--- Every cut between adjacent selected clips (grouped per track).
function LL.selectionCuts(tl)
	local ok, sel = pcall(function() return tl:GetSelectedClips() end)
	if not ok then
		LL.fail("This Resolve version cannot report the timeline selection (needs Timeline:GetSelectedClips).")
	end
	local byTrack, count = {}, 0
	for _, it in ipairs(LL.list(sel)) do
		local ttype, idx = LL.trackOf(it)
		if ttype == "video" and idx then
			byTrack[idx] = byTrack[idx] or {}
			table.insert(byTrack[idx], it)
			count = count + 1
		end
	end
	local cuts = {}
	for t, items in pairs(byTrack) do
		for _, c in ipairs(LL.adjacentPairs(items)) do
			c.track = t
			cuts[#cuts + 1] = c
		end
	end
	table.sort(cuts, function(x, y)
		if x.track ~= y.track then return x.track < y.track end
		return x.frame < y.frame
	end)
	return cuts, count
end

--- First unlocked, enabled video track above everything that overlaps [s, e).
--- Returns track index and whether a new track had to be added.
function LL.findTitleTrack(tl, s, e)
	local n = tl:GetTrackCount("video")
	local topBusy = 0
	for t = 1, n do
		for _, it in ipairs(LL.list(tl:GetItemListInTrack("video", t))) do
			local a, b = LL.itemSpan(it)
			if a < e and b > s then
				topBusy = t
				break
			end
		end
	end
	for t = topBusy + 1, n do
		if not tl:GetIsTrackLocked("video", t) and tl:GetIsTrackEnabled("video", t) ~= false then
			return t, false
		end
	end
	if not tl:AddTrack("video") then LL.fail("Could not add a video track for the title.") end
	return tl:GetTrackCount("video"), true
end

-- ---------------------------------------------------------------------------------------
-- Resolve access
-- ---------------------------------------------------------------------------------------

function LL.resolve()
	if LL._resolve then return LL._resolve end
	local r = resolve
	if not r and type(Resolve) == "function" then r = Resolve() end
	if not r and bmd and bmd.scriptapp then r = bmd.scriptapp("Resolve") end
	LL._resolve = r
	return r
end

function LL.context(allowNoTimeline)
	local r = LL.resolve()
	if not r then LL.fail("Loom Letter could not connect to DaVinci Resolve.") end
	local pm = r:GetProjectManager()
	local project = pm and pm:GetCurrentProject()
	if not project then LL.fail("Open a project first.") end
	local tl = project:GetCurrentTimeline()
	if not tl and not allowNoTimeline then LL.fail("Open a timeline on the Edit page first.") end
	return { resolve = r, project = project, timeline = tl, mediaPool = project:GetMediaPool() }
end

function LL.playheadFrame(ctx)
	local tl = ctx.timeline
	local rate = tl:GetSetting("timelineFrameRate")
	if not rate or rate == "" then rate = ctx.project:GetSetting("timelineFrameRate") end
	local fps, df = LL.parseFrameRate(rate)
	local cur = LL.timecodeToFrames(tl:GetCurrentTimecode(), fps, df)
	local start = LL.timecodeToFrames(tl:GetStartTimecode(), fps, df)
	if not cur or not start then
		LL.fail("Could not read the playhead position - switch to the Edit page and try again.")
	end
	return tl:GetStartFrame() + (cur - start), fps
end

--- Run fn with `tl` as the current timeline, always switching back to the user's timeline.
function LL.withTimeline(ctx, tl, fn)
	ctx.project:SetCurrentTimeline(tl)
	local ok, a, b, c = pcall(fn)
	ctx.project:SetCurrentTimeline(ctx.timeline)
	if not ok then error(a, 0) end
	return a, b, c
end

function LL.getBin(ctx, create)
	local mp = ctx.mediaPool
	local root = mp:GetRootFolder()
	for _, f in ipairs(LL.list(root:GetSubFolderList())) do
		if f:GetName() == LL.BIN_NAME then return f end
	end
	if create then return mp:AddSubFolder(root, LL.BIN_NAME) end
end

function LL.findTimeline(project, name)
	for i = 1, project:GetTimelineCount() do
		local t = project:GetTimelineByIndex(i)
		if t and t:GetName() == name then return t end
	end
end

--- A timeline Loom Letter owns, used to create title instances without touching yours.
function LL.getScratchTimeline(ctx)
	local tl = LL.findTimeline(ctx.project, LL.SCRATCH_TIMELINE)
	if tl then return tl end
	local mp = ctx.mediaPool
	local prev = mp:GetCurrentFolder()
	local bin = LL.getBin(ctx, true)
	if bin then mp:SetCurrentFolder(bin) end
	tl = mp:CreateEmptyTimeline(LL.SCRATCH_TIMELINE)
	if prev then mp:SetCurrentFolder(prev) end
	ctx.project:SetCurrentTimeline(ctx.timeline)
	if not tl then LL.fail("Could not create the Loom Letter scratch timeline.") end
	LL.log("created scratch timeline %q", LL.SCRATCH_TIMELINE)
	return tl
end

function LL.findTool(comp, name)
	local ok, t = pcall(function() return comp:FindTool(name) end)
	if ok and t then return t end
	for _, tool in ipairs(LL.list(comp:GetToolList(false))) do
		local n = tool.Name
		if n == name or (type(n) == "string" and n:match("^" .. name .. "_?%d+$")) then return tool end
	end
end

--- Set inputs inside a comp. changes = { { toolName, inputId, value }, ... }
function LL.applyInputs(comp, changes)
	local missing = {}
	comp:Lock()
	comp:StartUndo("Loom Letter")
	local ok, err = pcall(function()
		for _, c in ipairs(changes) do
			local tool = LL.findTool(comp, c[1])
			if tool then tool:SetInput(c[2], c[3]) else missing[c[1]] = true end
		end
	end)
	comp:EndUndo(true)
	comp:Unlock()
	if not ok then error(err, 0) end
	for name in pairs(missing) do LL.log("customise: tool %s not found in the title comp", name) end
	return next(missing) == nil
end

-- ---------------------------------------------------------------------------------------
-- Titles
-- ---------------------------------------------------------------------------------------

LL._sources = {}

--- Changes to push into a freshly placed title, based on the panel's fields.
function LL.titleChanges(preset, opts)
	local changes = {}
	local function add(tool, id, v) changes[#changes + 1] = { tool, id, v } end
	local function texts(targets, raw)
		if LL.trim(raw) == "" then return end
		for _, t in ipairs(targets or {}) do
			if t[3] == "number" then
				local n = tonumber((LL.trim(raw):gsub(",", "")))
				if n then add(t[1], t[2], n) end
			else
				add(t[1], t[2], raw)
			end
		end
	end
	local function colors(targets, hex)
		local rgb = LL.parseHex(hex)
		if not rgb then return end
		for _, t in ipairs(targets or {}) do
			local keys = t[2] == "bg" and { "TopLeftRed", "TopLeftGreen", "TopLeftBlue" } or { "Red1", "Green1", "Blue1" }
			for i = 1, 3 do add(t[1], keys[i], rgb[i]) end
		end
	end
	texts(preset.textTargets, opts.text)
	texts(preset.text2Targets, opts.text2)
	local font, style = LL.trim(opts.font), LL.trim(opts.style)
	for _, name in ipairs(preset.fontTools or {}) do
		if font ~= "" then add(name, "Font", font) end
		if style ~= "" then add(name, "Style", style) end
	end
	colors(preset.colorTargets, opts.color)
	colors(preset.accentTargets, opts.accent)
	if opts.fps then
		for _, t in ipairs(preset.fpsTargets or {}) do add(t[1], t[2], opts.fps) end
	end
	if preset.inFrames and opts.inFrames then add(preset.host, "InFrames", opts.inFrames) end
	if preset.outFrames and opts.outFrames then add(preset.host, "OutFrames", opts.outFrames) end
	return changes
end

function LL.customizeTitle(item, preset, opts)
	local comp = item:GetFusionCompByIndex(1)
	if not comp then
		LL.log("title %s has no Fusion comp; left at template defaults", preset.template)
		return false
	end
	return LL.applyInputs(comp, LL.titleChanges(preset, opts))
end

--- Something AppendToTimeline can place: a media pool item for the title.
--- Order: a clip named after the template in the "Loom Letter" bin (manual override),
--- then the media pool item behind a title instance on the scratch timeline.
function LL.titleSource(ctx, preset)
	local key = preset.template
	if LL._sources[key] then return LL._sources[key] end
	local bin = LL.getBin(ctx, false)
	if bin then
		for _, clip in ipairs(LL.list(bin:GetClipList())) do
			if clip:GetName() == key then
				LL._sources[key] = { mpi = clip, how = "bin clip" }
				return LL._sources[key]
			end
		end
	end
	local scratch = LL.getScratchTimeline(ctx)
	local item
	for _, it in ipairs(LL.list(scratch:GetItemListInTrack("video", 1))) do
		if it:GetName() == key then item = it end
	end
	if not item then
		item = LL.withTimeline(ctx, scratch, function() return scratch:InsertFusionTitleIntoTimeline(key) end)
	end
	if not item then
		LL.fail(("Resolve could not find the Fusion title %q. Run the installer, then restart Resolve."):format(key))
	end
	local mpi = item:GetMediaPoolItem()
	local src = { mpi = mpi, how = mpi and "title" or "compound", length = item:GetDuration() }
	if mpi then LL._sources[key] = src end
	LL.log("title source for %s: %s (template length %d frames)", key, src.how, src.length or -1)
	return src
end

--- Fallback when a title has no media pool item: customise a scratch instance and wrap it
--- in a compound clip, which can be placed with AppendToTimeline.
function LL.compoundTitle(ctx, preset, opts)
	local scratch = LL.getScratchTimeline(ctx)
	local mp = ctx.mediaPool
	local prev = mp:GetCurrentFolder()
	local bin = LL.getBin(ctx, true)
	local ok, a, b = pcall(LL.withTimeline, ctx, scratch, function()
		local item = scratch:InsertFusionTitleIntoTimeline(preset.template)
		if not item then LL.fail(("Resolve could not insert %q."):format(preset.template)) end
		LL.customizeTitle(item, preset, opts)
		if bin then mp:SetCurrentFolder(bin) end
		local compound = scratch:CreateCompoundClip({ item }, { name = ("%s %s"):format(preset.template, os.date("%H%M%S")) })
		return compound, compound and compound:GetDuration()
	end)
	if prev then mp:SetCurrentFolder(prev) end
	if not ok then error(a, 0) end
	local compound, length = a, b
	local cmpi = compound and compound:GetMediaPoolItem()
	if not cmpi then LL.fail("Could not wrap the title in a compound clip.") end
	return cmpi, compound, scratch, length
end

function LL.place(ctx, mpi, frames, track, record)
	local res = ctx.mediaPool:AppendToTimeline({ {
		mediaPoolItem = mpi, startFrame = 0, endFrame = frames - 1, trackIndex = track, recordFrame = record,
	} })
	return LL.list(res)[1]
end

-- Resolve's insert edit gives a real, Inspector-editable title, but it ripples every
-- unlocked track. Locked tracks are left alone, so we lock everything except one track that
-- is empty from the playhead onwards, insert, then restore the user's locks.

local TRACK_TYPES = { "video", "audio", "subtitle" }

--- id -> "type:track:start:duration" for every item on the timeline.
function LL.snapshot(tl)
	local snap = {}
	for _, kind in ipairs(TRACK_TYPES) do
		local ok, n = pcall(function() return tl:GetTrackCount(kind) end)
		for t = 1, (ok and tonumber(n) or 0) do
			for _, it in ipairs(LL.list(tl:GetItemListInTrack(kind, t))) do
				local id = it.GetUniqueId and it:GetUniqueId() or tostring(it)
				snap[id] = ("%s:%d:%s:%s"):format(kind, t, tostring(it:GetStart()), tostring(it:GetDuration()))
			end
		end
	end
	return snap
end

--- Video track above everything under the playhead that has nothing at or after `frame`.
function LL.findInsertTrack(tl, frame)
	local n = tl:GetTrackCount("video")
	local topBusy = 0
	for t = 1, n do
		for _, it in ipairs(LL.list(tl:GetItemListInTrack("video", t))) do
			local a, b = LL.itemSpan(it)
			if a <= frame and b > frame then topBusy = t break end
		end
	end
	for t = topBusy + 1, n do
		local clear = not tl:GetIsTrackLocked("video", t) and tl:GetIsTrackEnabled("video", t) ~= false
		if clear then
			for _, it in ipairs(LL.list(tl:GetItemListInTrack("video", t))) do
				local _, b = LL.itemSpan(it)
				if b > frame then clear = false break end
			end
		end
		if clear then return t, false end
	end
	if not tl:AddTrack("video") then LL.fail("Could not add a video track for the title.") end
	return tl:GetTrackCount("video"), true
end

--- Insert `template` at the playhead of `tl` (which must be current) with only video track
--- `track` unlocked. Returns the new item and a report of what happened.
function LL.lockedInsert(tl, template, track)
	local saved = {}
	for _, kind in ipairs(TRACK_TYPES) do
		saved[kind] = {}
		local ok, n = pcall(function() return tl:GetTrackCount(kind) end)
		for t = 1, (ok and tonumber(n) or 0) do
			saved[kind][t] = tl:GetIsTrackLocked(kind, t) == true
			tl:SetTrackLock(kind, t, not (kind == "video" and t == track))
		end
	end
	local before = LL.snapshot(tl)
	local ok, item = pcall(function() return tl:InsertFusionTitleIntoTimeline(template) end)
	for kind, tracks in pairs(saved) do
		for t, locked in pairs(tracks) do tl:SetTrackLock(kind, t, locked) end
	end
	if not ok then error(item, 0) end
	local after = LL.snapshot(tl)
	local moved = 0
	for id, state in pairs(before) do
		if after[id] ~= state then moved = moved + 1 end
	end
	local report = { moved = moved }
	if item then
		local _, t = LL.trackOf(item)
		report.track, report.start, report.frames = t, item:GetStart(), item:GetDuration()
	end
	return item, report
end

--- Rehearse the locked insert on the scratch timeline once per session.
function LL.insertModeWorks(ctx, template)
	if LL._insertMode ~= nil then return LL._insertMode end
	local scratch = LL.getScratchTimeline(ctx)
	local ok, pass, detail = pcall(LL.withTimeline, ctx, scratch, function()
		local fillers = LL.list(scratch:GetItemListInTrack("video", 1))
		if #fillers == 0 then
			scratch:InsertFusionTitleIntoTimeline(template)
			fillers = LL.list(scratch:GetItemListInTrack("video", 1))
		end
		local filler = fillers[1]
		if not filler then return false, "no filler clip" end
		local rate = scratch:GetSetting("timelineFrameRate")
		if not rate or rate == "" then rate = ctx.project:GetSetting("timelineFrameRate") end
		local fps, df = LL.parseFrameRate(rate)
		local mid = filler:GetStart() + math.floor(filler:GetDuration() / 2)
		local startTc = LL.timecodeToFrames(scratch:GetStartTimecode(), fps, df) or 0
		scratch:SetCurrentTimecode(LL.framesToTimecode(mid - scratch:GetStartFrame() + startTc, fps, df))
		scratch:AddTrack("video")
		local track = scratch:GetTrackCount("video")
		local item, rep = LL.lockedInsert(scratch, template, track)
		local good = item ~= nil and rep.track == track and rep.moved == 0 and math.abs((rep.start or -1) - mid) < 1
		local msg = ("landed on V%s at %s (wanted V%d at %d), %d other clip(s) moved"):format(
			tostring(rep.track), tostring(rep.start), track, mid, rep.moved)
		if item then scratch:DeleteClips({ item }) end
		pcall(function() scratch:DeleteTrack("video", track) end)
		return good, msg
	end)
	LL._insertMode = ok and pass == true
	LL._insertDetail = ok and detail or tostring(pass)
	LL.log("insert rehearsal: %s (%s)", LL._insertMode and "pass" or "fail", tostring(LL._insertDetail))
	return LL._insertMode
end

--- Place a real title with Resolve's insert edit, protected by track locks.
function LL.insertTitle(ctx, preset, opts, playhead)
	local tl = ctx.timeline
	local track, added = LL.findInsertTrack(tl, playhead)
	local item, rep = LL.lockedInsert(tl, preset.template, track)
	if not item then return nil end
	if rep.moved > 0 then
		LL.log("WARNING: inserting %s moved %d clip(s)", preset.template, rep.moved)
	end
	LL.customizeTitle(item, preset, opts)
	return {
		item = item, track = rep.track or track, addedTrack = added, frames = rep.frames or 0, how = "title",
		moved = rep.moved, timecode = tl:GetCurrentTimecode(),
	}
end

--- Add a title at the playhead without rippling anything.
function LL.addTitle(preset, opts)
	local ctx = LL.context()
	local playhead, fps = LL.playheadFrame(ctx)
	local frames = math.max(1, math.floor((tonumber(opts.seconds) or 5) * fps + 0.5))
	opts.fps = fps
	if LL.insertModeWorks(ctx, preset.template) then
		local res = LL.insertTitle(ctx, preset, opts, playhead)
		if res then
			res.fps = fps
			res.requested = frames
			LL.log("inserted %s on V%d at frame %d (%d frames)", preset.template, res.track, playhead, res.frames)
			return res
		end
		LL.log("locked insert returned nothing for %s; falling back", preset.template)
	end
	local src = LL.titleSource(ctx, preset)
	local mpi, compound, scratch, length = src.mpi, nil, nil, src.length
	if not mpi then
		mpi, compound, scratch, length = LL.compoundTitle(ctx, preset, opts)
		if length then frames = math.min(frames, length) end
	end
	local track, added = LL.findTitleTrack(ctx.timeline, playhead, playhead + frames)
	local item = LL.place(ctx, mpi, frames, track, playhead)
	if not item and length and frames > length then
		LL.log("placing %d frames failed; retrying with the template length %d", frames, length)
		frames = length
		item = LL.place(ctx, mpi, frames, track, playhead)
	end
	if compound then
		pcall(LL.withTimeline, ctx, scratch, function() return scratch:DeleteClips({ compound }) end)
	end
	if not item then
		LL.fail("Resolve refused to place the title. Check that the track isn't locked and try again.")
	end
	if not compound then LL.customizeTitle(item, preset, opts) end
	LL.log("added %s on V%d at frame %d for %d frames (%s)", preset.template, track, playhead, frames, src.how)
	return {
		item = item, track = track, addedTrack = added, frames = frames, fps = fps,
		how = compound and "compound" or src.how, timecode = ctx.timeline:GetCurrentTimecode(),
	}
end

-- ---------------------------------------------------------------------------------------
-- Cut transitions (node chains in each clip's Fusion comp)
-- ---------------------------------------------------------------------------------------

function LL.clipComp(item)
	local n = item:GetFusionCompCount() or 0
	if n >= 1 then
		if n > 1 then LL.log("%s has %d Fusion comps; using the first", item:GetName(), n) end
		return item:GetFusionCompByIndex(1)
	end
	local comp = item:AddFusionComp()
	if not comp then LL.fail(("Could not create a Fusion composition on %q."):format(item:GetName())) end
	return comp
end

function LL.findMediaOut(comp)
	return LL.list(comp:GetToolList(false, "MediaOut"))[1]
end

--- Insert tools (upstream -> downstream) directly in front of MediaOut.
function LL.insertChain(comp, specs, tag)
	local mediaOut = LL.findMediaOut(comp)
	if not mediaOut then LL.fail("The clip's Fusion comp has no MediaOut node.") end
	local outIn = mediaOut:FindMainInput(1)
	local upstream = outIn and outIn:GetConnectedOutput()
	if not upstream then LL.fail("MediaOut isn't connected to anything in the clip's Fusion comp.") end
	local added = {}
	comp:Lock()
	comp:StartUndo("Loom Letter: add transition")
	local ok, err = pcall(function()
		local prev = upstream
		for _, spec in ipairs(specs) do
			local tool = comp:AddTool(spec.reg, -32768, -32768)
			if not tool then LL.fail("Could not add a " .. spec.reg .. " node.") end
			added[#added + 1] = tool
			for id, v in pairs(spec.values or {}) do tool:SetInput(id, v) end
			for id, e in pairs(spec.exprs or {}) do tool[id]:SetExpression(e) end
			tool:FindMainInput(1):ConnectTo(prev)
			tool:SetData(LL.TOOL_TAG, tag)
			tool:SetAttrs({ TOOLS_Name = spec.name })
			prev = tool:FindMainOutput(1)
		end
		outIn:ConnectTo(prev)
	end)
	if not ok then
		-- leave the comp as we found it
		pcall(function()
			outIn:ConnectTo(upstream)
			for _, t in ipairs(added) do t:Delete() end
		end)
	end
	comp:EndUndo(true)
	comp:Unlock()
	if not ok then error(err, 0) end
	return added
end

--- Remove Loom Letter nodes (optionally only one side) and reconnect around them.
function LL.removeChain(comp, side)
	local removed = 0
	local tools = LL.list(comp:GetToolList(false))
	comp:Lock()
	comp:StartUndo("Loom Letter: remove transition")
	local ok, err = pcall(function()
		for _, tool in ipairs(tools) do
			local tag = tool:GetData(LL.TOOL_TAG)
			if type(tag) == "table" and (side == nil or tag.side == side) then
				local mainIn = tool:FindMainInput(1)
				local upstream = mainIn and mainIn:GetConnectedOutput()
				local mainOut = tool:FindMainOutput(1)
				for _, inp in ipairs(LL.list(mainOut and mainOut:GetConnectedInputs())) do
					inp:ConnectTo(upstream)
				end
				tool:Delete()
				removed = removed + 1
			end
		end
	end)
	comp:EndUndo(true)
	comp:Unlock()
	if not ok then error(err, 0) end
	return removed
end

function LL.cutOptions(o)
	return {
		frames = math.max(1, math.floor(tonumber(o.frames) or 8)),
		intensity = math.max(0.05, (tonumber(o.intensity) or 100) / 100),
		direction = o.direction or "Left",
		motionBlur = o.motionBlur ~= false,
		track = tonumber(o.track) or 0,
	}
end

function LL.applyToPair(pair, style, o)
	for _, side in ipairs({ "out", "in" }) do
		local item = side == "out" and pair.a or pair.b
		-- never let one side's ramp cover more than half the clip
		local frames = math.max(1, math.min(o.frames, math.floor(item:GetDuration() / 2)))
		local comp = LL.clipComp(item)
		LL.removeChain(comp, side)
		local specs = LL.buildCutSpec(style, side, {
			frames = frames, intensity = o.intensity, direction = o.direction, motionBlur = o.motionBlur,
		})
		LL.insertChain(comp, specs, { side = side, style = style.id, frames = frames, version = LL.VERSION })
	end
end

function LL.applyAtPlayhead(style, rawOpts)
	local o = LL.cutOptions(rawOpts)
	local ctx = LL.context()
	local playhead, fps = LL.playheadFrame(ctx)
	local radius = math.max(fps * LL.CUT_SEARCH_SECONDS, o.frames * 2)
	local cut = LL.nearestCut(ctx.timeline, playhead, o.track, radius)
	if not cut then
		LL.fail(("No cut within %d seconds of the playhead%s. Park the playhead on an edit between two clips."):format(
			LL.CUT_SEARCH_SECONDS, o.track > 0 and (" on V" .. o.track) or ""))
	end
	LL.applyToPair(cut, style, o)
	LL.log("applied %s at frame %d on V%d (%d frames/side)", style.id, cut.frame, cut.track, o.frames)
	return cut
end

function LL.applyToSelection(style, rawOpts)
	local o = LL.cutOptions(rawOpts)
	local ctx = LL.context()
	local cuts, selected = LL.selectionCuts(ctx.timeline)
	if #cuts == 0 then
		LL.fail(selected == 0 and "Select two or more clips that touch each other on the same track."
			or "None of the selected clips butt up against each other on the same track.")
	end
	for _, c in ipairs(cuts) do LL.applyToPair(c, style, o) end
	LL.log("applied %s to %d cut(s) in the selection", style.id, #cuts)
	return #cuts
end

function LL.removeFromSelection()
	local ctx = LL.context()
	local ok, sel = pcall(function() return ctx.timeline:GetSelectedClips() end)
	local items = ok and LL.list(sel) or {}
	if #items == 0 then
		local cur = ctx.timeline:GetCurrentVideoItem()
		if cur then items = { cur } end
	end
	if #items == 0 then LL.fail("Select the clips to clean up (or park the playhead over one).") end
	local removed, clips = 0, 0
	for _, it in ipairs(items) do
		local ttype = LL.trackOf(it)
		if ttype == "video" then
			local n = it:GetFusionCompCount() or 0
			local here = 0
			for i = 1, n do
				local comp = it:GetFusionCompByIndex(i)
				if comp then here = here + LL.removeChain(comp, nil) end
			end
			if here > 0 then clips = clips + 1 end
			removed = removed + here
		end
	end
	LL.log("removed %d node(s) from %d clip(s)", removed, clips)
	return removed, clips
end

-- ---------------------------------------------------------------------------------------
-- Updates: pull changed files from GitHub (see tools/build_manifest.py)
-- ---------------------------------------------------------------------------------------

--- "version X\n<sha1>  <path>\n..." -> { version = "X", files = { [path] = sha1 }, count = n }
function LL.parseManifest(text)
	local m = { files = {}, count = 0 }
	for line in tostring(text or ""):gmatch("[^\r\n]+") do
		local v = line:match("^version%s+(%S+)")
		if v then
			m.version = v
		else
			local hash, path = line:match("^(%x+)%s+(.+)$")
			if hash then
				m.files[path] = hash
				m.count = m.count + 1
			end
		end
	end
	if not m.version or m.count == 0 then return nil end
	return m
end

--- Only files Loom Letter owns may be written or deleted by an update.
function LL.safeUpdatePath(path)
	if path:find("%.%.") or path:find("^[/\\]") or path:find(":") then return false end
	return path == "Scripts/Utility/Loom Letter.lua"
		or path:match("^Templates/Edit/Titles/Loom Letter/[^/]+%.setting$") ~= nil
		or path:match("^LoomLetter/previews/[^/]+%.png$") ~= nil
end

--- Files to download (new or changed) and to delete (gone from the remote manifest).
function LL.planUpdate(localM, remoteM, diskHash)
	local get, remove = {}, {}
	local have = localM and localM.files or {}
	for path, hash in pairs(remoteM.files) do
		-- trust the file on disk over the recorded manifest when we can read it
		local actual = diskHash and diskHash(path)
		if actual == nil then actual = have[path] end
		if LL.safeUpdatePath(path) and actual ~= hash then get[#get + 1] = path end
	end
	for path in pairs(have) do
		if remoteM.files[path] == nil and LL.safeUpdatePath(path) then remove[#remove + 1] = path end
	end
	table.sort(get)
	table.sort(remove)
	return get, remove
end

local function shell_quote(s)
	if IS_WINDOWS then return '"' .. s:gsub("/", "\\") .. '"' end
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function url_path(p)
	return (p:gsub("[^%w%-%._/]", function(c) return ("%%%02X"):format(c:byte()) end))
end

--- Download with curl (bundled with macOS and Windows 10+). Returns true on success.
function LL.download(url, dest, accept)
	local header = accept and (" -H " .. shell_quote("Accept: " .. accept)) or ""
	local cmd = ("curl -fsSL --max-time 30%s -o %s %s"):format(header, shell_quote(dest), shell_quote(url))
	if IS_WINDOWS then cmd = '"' .. cmd .. '"' end -- cmd.exe strips one outer pair of quotes
	local r = os.execute(cmd)
	return (r == 0 or r == true) and LL.fileExists(dest)
end

function LL.readFile(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

--- SHA-1 of a string (hex), pure LuaJIT - used to fingerprint installed and downloaded files.
function LL.sha1(msg)
	local bit = require("bit")
	local band, bor, bxor, bnot, rol, tobit = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rol, bit.tobit
	local function u32(x) return x % 4294967296 end
	local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
	local len = #msg
	local bits = len * 8
	msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
	local hi, lo = math.floor(bits / 4294967296), bits % 4294967296
	msg = msg .. string.char(math.floor(hi / 16777216) % 256, math.floor(hi / 65536) % 256, math.floor(hi / 256) % 256, hi % 256,
		math.floor(lo / 16777216) % 256, math.floor(lo / 65536) % 256, math.floor(lo / 256) % 256, lo % 256)
	local w = {}
	for chunk = 1, #msg, 64 do
		for i = 0, 15 do
			local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
			w[i] = tobit(a * 16777216 + b * 65536 + c * 256 + d)
		end
		for i = 16, 79 do w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1) end
		local a, b, c, d, e = tobit(h0), tobit(h1), tobit(h2), tobit(h3), tobit(h4)
		for i = 0, 79 do
			local f, k
			if i < 20 then f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
			elseif i < 40 then f, k = bxor(b, c, d), 0x6ED9EBA1
			elseif i < 60 then f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
			else f, k = bxor(b, c, d), 0xCA62C1D6 end
			local t = tobit(rol(a, 5) + f + e + tobit(k) + w[i])
			e, d, c, b, a = d, c, rol(b, 30), a, t
		end
		h0, h1, h2, h3, h4 = u32(h0 + a), u32(h1 + b), u32(h2 + c), u32(h3 + d), u32(h4 + e)
	end
	return ("%08x%08x%08x%08x%08x"):format(h0, h1, h2, h3, h4)
end

function LL.fileSha1(path)
	local data = LL.readFile(path)
	return data and LL.sha1(data) or nil
end

function LL.localManifest()
	return LL.parseManifest(LL.readFile(LL.join(LL.paths.data or "?", "manifest.txt")))
end

--- -1 / 0 / 1 comparing dotted versions ("0.2.10" > "0.2.9").
function LL.compareVersions(a, b)
	local pa, pb = {}, {}
	for n in tostring(a):gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
	for n in tostring(b):gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i] or 0, pb[i] or 0
		if x ~= y then return x < y and -1 or 1 end
	end
	return 0
end

function LL.rawBase(ref)
	return ("https://raw.githubusercontent.com/%s/%s/Fusion/"):format(LL.UPDATE_REPO, ref)
end

--- The exact commit at the tip of the update branch. Downloading from that commit's URLs
--- gives one consistent version; branch URLs on raw.githubusercontent.com are cached and can
--- mix old and new files for a few minutes after a push.
function LL.latestCommit()
	local tmp = LL.join(LL.paths.data, "commit.remote")
	os.remove(tmp)
	local url = ("https://api.github.com/repos/%s/commits/%s"):format(LL.UPDATE_REPO, LL.UPDATE_BRANCH)
	local sha
	if LL.download(url, tmp, "application/vnd.github.sha") then
		sha = (LL.readFile(tmp) or ""):match("^%s*(%x+)%s*$")
	end
	os.remove(tmp)
	if sha and #sha == 40 then return sha end
	return nil
end

--- Returns remote manifest plus the plan, or raises a user error.
function LL.checkForUpdate()
	if not LL.paths.data then LL.fail("Can't find the Loom Letter install folder.") end
	LL.ensureDir(LL.paths.data)
	local tmp = LL.join(LL.paths.data, "manifest.remote")
	os.remove(tmp)
	local commit = LL.latestCommit()
	local base = commit and LL.rawBase(commit) or LL.rawBase(LL.UPDATE_BRANCH)
	if not LL.download(base .. "LoomLetter/manifest.txt" .. (commit and "" or "?t=" .. os.time()), tmp) then
		LL.fail("Couldn't reach GitHub to check for updates (are you online?).")
	end
	local remote = LL.parseManifest(LL.readFile(tmp))
	os.remove(tmp)
	if not remote then LL.fail("The update manifest on GitHub couldn't be read.") end
	if LL.compareVersions(remote.version, LL.VERSION) < 0 then
		-- GitHub hasn't caught up with a newer push yet; never go backwards
		return { remote = remote, get = {}, remove = {}, available = false, base = base }
	end
	local get, remove = LL.planUpdate(LL.localManifest(), remote, function(path)
		local p = LL.join(LL.paths.root, path)
		if not LL.fileExists(p) then return false end -- missing: always download
		return LL.fileSha1(p)
	end)
	return { remote = remote, get = get, remove = remove, available = #get + #remove > 0, base = base, commit = commit }
end

--- Download every changed file first, then move them into place, then write the manifest.
function LL.applyUpdate(check)
	check = check or LL.checkForUpdate()
	if not check.available then return check end
	local stage = LL.join(LL.paths.data, "update")
	LL.ensureDir(stage)
	local staged = {}
	for i, path in ipairs(check.get) do
		local tmp = LL.join(stage, tostring(i) .. ".part")
		os.remove(tmp)
		local want = check.remote.files[path]
		local good = false
		for attempt = 1, 3 do
			os.remove(tmp)
			local url = check.base .. url_path(path) .. (check.commit and "" or ("?t=" .. os.time() .. attempt))
			if LL.download(url, tmp)
				and LL.fileSha1(tmp) == want then
				good = true
				break
			end
		end
		if not good then
			for _, s in ipairs(staged) do os.remove(s.tmp) end
			os.remove(tmp)
			LL.fail(("Update stopped: %s didn't download correctly (GitHub may still be publishing it - try again in a minute). Nothing was changed."):format(path))
		end
		staged[#staged + 1] = { tmp = tmp, path = path }
	end
	local titlesChanged = false
	for _, s in ipairs(staged) do
		local dest = LL.join(LL.paths.root, s.path)
		LL.ensureDir((dest:gsub("/[^/]+$", "")))
		os.remove(dest)
		local ok, err = os.rename(s.tmp, dest)
		if not ok then LL.fail(("Couldn't install %s: %s"):format(s.path, tostring(err))) end
		if s.path:find("^Templates/") then titlesChanged = true end
	end
	for _, path in ipairs(check.remove) do
		os.remove(LL.join(LL.paths.root, path))
		if path:find("^Templates/") then titlesChanged = true end
	end
	local f = io.open(LL.join(LL.paths.data, "manifest.txt"), "wb")
	if f then
		f:write("version ", check.remote.version, "\n")
		local paths = {}
		for path in pairs(check.remote.files) do paths[#paths + 1] = path end
		table.sort(paths)
		for _, path in ipairs(paths) do f:write(check.remote.files[path], "  ", path, "\n") end
		f:close()
	end
	check.titlesChanged = titlesChanged
	check.installed = true
	LL.log("updated to %s: %d file(s) downloaded, %d removed", check.remote.version, #check.get, #check.remove)
	return check
end

-- ---------------------------------------------------------------------------------------
-- Diagnostics: exercises the assumptions Loom Letter makes, on the scratch timeline only
-- ---------------------------------------------------------------------------------------

function LL.describeTools(comp)
	local parts = {}
	for _, t in ipairs(LL.list(comp:GetToolList(false))) do
		local attrs = t:GetAttrs() or {}
		parts[#parts + 1] = ("%s(%s)"):format(tostring(t.Name), tostring(attrs.TOOLS_RegID))
	end
	return table.concat(parts, ", ")
end

function LL.firstVideoClip(folder, depth)
	depth = depth or 0
	for _, clip in ipairs(LL.list(folder:GetClipList())) do
		local ok, kind = pcall(function() return clip:GetClipProperty("Type") end)
		if ok and type(kind) == "string" and kind:find("Video", 1, true) then return clip end
	end
	if depth < 4 then
		for _, sub in ipairs(LL.list(folder:GetSubFolderList())) do
			local c = LL.firstVideoClip(sub, depth + 1)
			if c then return c end
		end
	end
end

function LL.diagnostics()
	local lines = {}
	local function say(fmt, ...)
		local s = select("#", ...) > 0 and fmt:format(...) or fmt
		lines[#lines + 1] = s
		LL.log("diag: %s", s)
	end
	local function step(name, fn)
		local ok, err = pcall(fn)
		if not ok then say("FAIL  %s: %s", name, tostring(err)) end
		return ok
	end

	local r = LL.resolve()
	say("Loom Letter %s", LL.VERSION)
	step("version", function() say("INFO  %s %s", r:GetProductName(), r:GetVersionString()) end)
	say("INFO  Fusion folder: %s", tostring(LL.paths.root))
	say("INFO  log file: %s", tostring(LL.paths.log))
	local ctx
	if not step("context", function() ctx = LL.context(true) end) then return lines end
	local userTimeline = ctx.timeline ~= nil
	if not userTimeline then
		say("INFO  no timeline is open - testing on the scratch timeline only")
		if not step("scratch timeline", function() ctx.timeline = LL.getScratchTimeline(ctx) end) then return lines end
	end
	local playhead, fps
	step("playhead", function()
		playhead, fps = LL.playheadFrame(ctx)
		say("PASS  playhead %s = frame %d at %s fps (timeline starts at frame %d)",
			ctx.timeline:GetCurrentTimecode(), playhead, tostring(fps), ctx.timeline:GetStartFrame())
	end)
	step("templates on disk", function()
		local missing = {}
		for _, p in ipairs(LL.TITLES) do
			if not LL.fileExists(LL.join(LL.paths.titles or "?", p.template .. ".setting")) then missing[#missing + 1] = p.template end
		end
		if #missing == 0 then say("PASS  all %d title templates are installed", #LL.TITLES)
		else say("FAIL  missing templates: %s (looked in %s)", table.concat(missing, ", "), tostring(LL.paths.titles)) end
	end)

	local scratch
	if not step("scratch timeline", function() scratch = LL.getScratchTimeline(ctx) end) then return lines end
	say("PASS  scratch timeline %q", LL.SCRATCH_TIMELINE)

	-- 1. Titles: insert, inspect the comp, check the expressions evaluate, find a media pool item.
	local preset = LL.TITLES[1]
	local titleItem
	step("insert title", function()
		titleItem = LL.withTimeline(ctx, scratch, function() return scratch:InsertFusionTitleIntoTimeline(preset.template) end)
		if not titleItem then LL.fail("InsertFusionTitleIntoTimeline returned nil") end
		say("PASS  InsertFusionTitleIntoTimeline(%q) -> %q, %d frames", preset.template, titleItem:GetName(), titleItem:GetDuration())
	end)
	if titleItem then
		step("title comp", function()
			local comp = titleItem:GetFusionCompByIndex(1)
			if not comp then LL.fail("title has no Fusion comp") end
			local a = comp:GetAttrs()
			say("INFO  title comp tools: %s", LL.describeTools(comp))
			say("INFO  title comp render range %s..%s (global %s..%s)", tostring(a.COMPN_RenderStart),
				tostring(a.COMPN_RenderEnd), tostring(a.COMPN_GlobalStart), tostring(a.COMPN_GlobalEnd))
			local host = LL.findTool(comp, preset.host)
			if not host then LL.fail("could not find tool " .. preset.host .. " inside the title") end
			say("PASS  found tool %q inside the title macro", preset.host)
			local s, e = a.COMPN_RenderStart, a.COMPN_RenderEnd
			local e0, e1, e2 = host:GetInput("Ease", s), host:GetInput("Ease", math.floor((s + e) / 2)), host:GetInput("Ease", e)
			say("%s  title visibility start/middle/end = %s / %s / %s (want 0 / 1 / 0)",
				(tonumber(e0) or 1) < 0.05 and (tonumber(e1) or 0) > 0.95 and (tonumber(e2) or 1) < 0.05 and "PASS" or "FAIL",
				tostring(e0), tostring(e1), tostring(e2))
			LL.applyInputs(comp, { { preset.host, "StyledText", "Loom Letter diagnostics" } })
			say("PASS  set StyledText via script: %q", tostring(host:GetInput("StyledText")))
		end)
		local mpi
		step("title media pool item", function()
			mpi = titleItem:GetMediaPoolItem()
			if mpi then
				local ok, kind = pcall(function() return mpi:GetClipProperty("Type") end)
				say("PASS  title has a media pool item %q (type %s) - titles are placed directly", mpi:GetName(), ok and tostring(kind) or "?")
			else
				say("INFO  title has no media pool item - titles will be placed as compound clips")
			end
		end)
		if mpi then
			step("place title with AppendToTimeline", function()
				if scratch:GetTrackCount("video") < 2 then scratch:AddTrack("video") end
				local want = titleItem:GetDuration() * 2
				local record = scratch:GetStartFrame() + 100000
				local placed = LL.withTimeline(ctx, scratch, function()
					return LL.list(ctx.mediaPool:AppendToTimeline({ {
						mediaPoolItem = mpi, startFrame = 0, endFrame = want - 1, trackIndex = 2, recordFrame = record,
					} }))[1]
				end)
				if not placed then LL.fail("AppendToTimeline returned nothing") end
				local t, idx = LL.trackOf(placed)
				say("%s  placed title on %s %s at %d for %d frames (asked for %d at %d)",
					placed:GetStart() == record and "PASS" or "FAIL", tostring(t), tostring(idx), placed:GetStart(),
					placed:GetDuration(), want, record)
				pcall(LL.withTimeline, ctx, scratch, function() return scratch:DeleteClips({ placed }) end)
			end)
		end
	end

	step("locked insert rehearsal", function()
		LL._insertMode = nil
		local pass = LL.insertModeWorks(ctx, preset.template)
		say("%s  locked insert: %s - %s", pass and "PASS" or "INFO", tostring(LL._insertDetail),
			pass and "titles are placed as normal titles" or "titles will be placed as compound clips")
	end)

	-- 2. Cut transitions: put a media pool clip on the scratch timeline and build a chain.
	step("cut transition pipeline", function()
		local clip = LL.firstVideoClip(ctx.mediaPool:GetRootFolder())
		if not clip then say("SKIP  no video clip in the media pool to test cut transitions with") return end
		local item = LL.withTimeline(ctx, scratch, function()
			return LL.list(ctx.mediaPool:AppendToTimeline({ { mediaPoolItem = clip, startFrame = 0, endFrame = 47, mediaType = 1 } }))[1]
		end)
		if not item then LL.fail("could not append a test clip to the scratch timeline") end
		local ok, err = pcall(function()
			local comp = LL.clipComp(item)
			local a = comp:GetAttrs()
			local s, e = a.COMPN_RenderStart, a.COMPN_RenderEnd
			say("INFO  clip %q: %d frames on the timeline, Fusion render range %s..%s", clip:GetName(), item:GetDuration(), tostring(s), tostring(e))
			say("INFO  clip comp tools: %s", LL.describeTools(comp))
			local style = LL.findPreset(LL.CUTS, "zoom_in")
			local tools = LL.insertChain(comp, LL.buildCutSpec(style, "out", { frames = 8, intensity = 1, direction = "Left", motionBlur = true }),
				{ side = "out", style = style.id, frames = 8, version = LL.VERSION })
			local t = tools[1]
			local v0, v1, v2 = t:GetInput("Size", e - 8), t:GetInput("Size", e - 4), t:GetInput("Size", e)
			say("%s  zoom at end-8 / end-4 / end = %s / %s / %s (want 1 / ~1.125 / 2)",
				math.abs((tonumber(v0) or 0) - 1) < 0.01 and math.abs((tonumber(v2) or 0) - 2) < 0.01 and "PASS" or "FAIL",
				tostring(v0), tostring(v1), tostring(v2))
			local up = LL.findMediaOut(comp):FindMainInput(1):GetConnectedOutput()
			say("%s  MediaOut is fed by %s", up and up:GetTool().Name == t.Name and "PASS" or "FAIL", up and tostring(up:GetTool().Name) or "nothing")
			local n = LL.removeChain(comp, nil)
			up = LL.findMediaOut(comp):FindMainInput(1):GetConnectedOutput()
			say("%s  removed %d node(s); MediaOut is fed by %s again", n == 1 and "PASS" or "FAIL", n, up and tostring(up:GetTool().Name) or "nothing")
		end)
		pcall(LL.withTimeline, ctx, scratch, function() return scratch:DeleteClips({ item }) end)
		if not ok then error(err, 0) end
	end)

	if userTimeline then step("selection API", function()
		local sel = ctx.timeline:GetSelectedClips()
		say("PASS  Timeline:GetSelectedClips() works (%d selected)", #LL.list(sel))
	end) end
	if titleItem then pcall(LL.withTimeline, ctx, scratch, function() return scratch:DeleteClips({ titleItem }) end) end
	say("Done. Your own timeline was not modified.")
	return lines
end

-- ---------------------------------------------------------------------------------------
-- UI (UIManager - DaVinci Resolve Studio)
-- ---------------------------------------------------------------------------------------

function LL.fontList()
	local names, seen = {}, {}
	pcall(function()
		local fm = fu.FontManager
		local list = fm and fm:GetFontList()
		if type(list) == "table" then
			for k, v in pairs(list) do
				local n = type(k) == "string" and k or (type(v) == "string" and v) or nil
				if n and not seen[n] then seen[n] = true; names[#names + 1] = n end
			end
		end
	end)
	if #names == 0 then
		names = { "Open Sans", "Arial", "Helvetica", "Montserrat", "Roboto", "Inter", "Bebas Neue",
			"Courier New", "Georgia", "Impact", "Futura", "Avenir Next" }
	end
	table.sort(names)
	return names
end

local function firstLine(s)
	s = tostring(s or "")
	s = s:gsub("^[^\n]-:%d+: ", "") -- drop "file:line:" prefixes from Lua errors
	return (s:match("^[^\n]*"))
end

function LL.runUI()
	if not (fu and fu.UIManager and bmd and bmd.UIDispatcher) then
		print("[Loom Letter] The Loom Letter window needs DaVinci Resolve Studio (UIManager).")
		print("[Loom Letter] The Loom Letter titles still work from Effects Library > Titles.")
		return
	end
	local ui = fu.UIManager
	-- running the script again brings the open window forward instead of opening a second one
	local existing = ui.FindWindow and ui:FindWindow("LoomLetter")
	if existing then
		pcall(function() existing:Show(); existing:Raise() end)
		return
	end
	local disp = bmd.UIDispatcher(ui)
	local prefs = LL.loadPrefs()
	local PRESET_FONT = "(preset font)"
	local LABEL_W = 92

	local function row(label, ...)
		local text, id = label, nil
		if type(label) == "table" then text, id = label[1], label[2] end
		return ui:HGroup{ Weight = 0, ui:Label{ ID = id, Text = text, Weight = 0, MinimumSize = { LABEL_W, 0 } }, ... }
	end

	local win = disp:AddWindow({
		ID = "LoomLetter",
		WindowTitle = "Loom Letter " .. LL.VERSION,
		Geometry = { 160, 120, 880, 600 },
		WindowFlags = { Window = true, WindowStaysOnTopHint = true },
	}, ui:VGroup{
		ID = "Root", Spacing = 8,
		ui:HGroup{
			Weight = 0,
			ui:Button{ ID = "ModeTitles", Text = "Titles", Checkable = true, Checked = true, MinimumSize = { 110, 28 } },
			ui:Button{ ID = "ModeCuts", Text = "Transitions", Checkable = true, MinimumSize = { 110, 28 } },
			ui:HGap(0, 1),
			ui:ComboBox{ ID = "Category", MinimumSize = { 170, 0 } },
			ui:LineEdit{ ID = "Search", PlaceholderText = "Search presets", MinimumSize = { 220, 0 } },
		},
		ui:HGroup{
			Weight = 1,
			ui:Tree{ ID = "List", Weight = 1, ColumnCount = 2, SortingEnabled = false },
			ui:VGroup{
				Weight = 0, MinimumSize = { 340, 0 }, MaximumSize = { 340, 100000 },
				ui:Button{ ID = "Preview", Flat = true, Text = "", IconSize = { 320, 180 },
					MinimumSize = { 336, 190 }, MaximumSize = { 336, 190 } },
				ui:Label{ ID = "Desc", WordWrap = true, Text = "", MinimumSize = { 336, 44 }, MaximumSize = { 336, 44 } },
				ui:Stack{
					ID = "Pages", Weight = 1,
					ui:VGroup{
						ID = "TitlePage", Spacing = 4,
						row({ "Text", "TTextLabel" }, ui:LineEdit{ ID = "TText" }),
						row({ "Line 2", "TText2Label" }, ui:LineEdit{ ID = "TText2" }),
						row("Font", ui:ComboBox{ ID = "TFont", Editable = true }),
						row("Style", ui:LineEdit{ ID = "TStyle", PlaceholderText = "(preset style)" }),
						row("Color", ui:LineEdit{ ID = "TColor", PlaceholderText = "#FFFFFF" },
							ui:Label{ Text = "Accent", Weight = 0 }, ui:LineEdit{ ID = "TAccent", PlaceholderText = "#F5B300" }),
						row("Seconds", ui:LineEdit{ ID = "TSeconds", Text = tostring(prefs.seconds or 5) },
							ui:Label{ Text = "In", Weight = 0 }, ui:SpinBox{ ID = "TIn", Minimum = 0, Maximum = 240 },
							ui:Label{ Text = "Out", Weight = 0 }, ui:SpinBox{ ID = "TOut", Minimum = 0, Maximum = 240 }),
						ui:VGap(0, 1),
						ui:Button{ ID = "AddTitle", Text = "Add Title at Playhead", MinimumSize = { 0, 34 } },
					},
					ui:VGroup{
						ID = "CutPage", Spacing = 4,
						row("Frames / side", ui:SpinBox{ ID = "CFrames", Minimum = 2, Maximum = 60, Value = prefs.cutFrames or 8 }),
						row("Intensity %", ui:SpinBox{ ID = "CIntensity", Minimum = 10, Maximum = 300, SingleStep = 10, Value = prefs.cutIntensity or 100 }),
						row("Direction", ui:ComboBox{ ID = "CDirection" }),
						row("Track", ui:ComboBox{ ID = "CTrack" }, ui:Button{ ID = "CRefresh", Text = "Refresh", Weight = 0 }),
						ui:CheckBox{ ID = "CMotionBlur", Text = "Motion blur", Checked = prefs.cutMotionBlur ~= false },
						ui:VGap(0, 1),
						ui:Button{ ID = "ApplyCut", Text = "Apply to Cut at Playhead", MinimumSize = { 0, 34 } },
						ui:Button{ ID = "ApplySelection", Text = "Apply to Every Cut in Selection", MinimumSize = { 0, 28 } },
						ui:Button{ ID = "RemoveSelection", Text = "Remove from Selected Clips", MinimumSize = { 0, 28 } },
					},
				},
			},
		},
		ui:HGroup{
			Weight = 0,
			ui:Label{ ID = "Status", Weight = 1, WordWrap = true, Text = "Ready." },
			ui:Button{ ID = "Update", Text = "Check for Updates", Weight = 0 },
			ui:Button{ ID = "Diag", Text = "Diagnostics", Weight = 0 },
		},
	})
	if not win then
		print("[Loom Letter] Resolve did not open the Loom Letter window (the window needs DaVinci Resolve Studio).")
		return
	end

	local itm = win:GetItems()
	local state = { mode = prefs.mode == "cuts" and "cuts" or "titles", visible = {}, current = nil, busy = false,
		diagRuns = 0, categories = {} }

	local function setStatus(msg)
		itm.Status.Text = msg
	end

	local function on_error(e)
		if LL.isUserError(e) then return e end
		return debug.traceback(tostring(e), 2)
	end

	local function guarded(label, fn)
		return function(ev)
			if state.busy then return end
			state.busy = true
			local ok, err = xpcall(function() fn(ev) end, on_error)
			state.busy = false
			if ok then return end
			if LL.isUserError(err) then
				LL.log("%s: %s", label, err.msg)
				setStatus(err.msg)
			else
				LL.log("%s failed: %s", label, tostring(err))
				setStatus(label .. " failed: " .. firstLine(err) .. " (details in the log)")
			end
		end
	end

	-- static widget content (built before the loop starts, never re-laid-out in signals)
	pcall(function() itm.List:SetHeaderLabels({ "Preset", "Style" }) end)
	pcall(function() itm.List.ColumnWidth[0] = 220 end)
	itm.TFont:AddItem(PRESET_FONT)
	itm.TFont:AddItems(LL.fontList())
	if prefs.font and prefs.font ~= "" then pcall(function() itm.TFont:SetEditText(prefs.font) end) end
	itm.TStyle.Text = prefs.style or ""
	itm.TColor.Text = prefs.color or ""
	itm.TAccent.Text = prefs.accent or ""
	itm.CDirection:AddItems(LL.DIRECTIONS)
	for i, d in ipairs(LL.DIRECTIONS) do
		if d == prefs.cutDirection then itm.CDirection.CurrentIndex = i - 1 end
	end

	local function refreshTracks()
		itm.CTrack:Clear()
		itm.CTrack:AddItem("Auto (nearest cut)")
		local ok, ctx = pcall(LL.context)
		if ok then
			for t = 1, ctx.timeline:GetTrackCount("video") do itm.CTrack:AddItem("V" .. t) end
		end
	end
	refreshTracks()

	local function presets()
		return state.mode == "titles" and LL.TITLES or LL.CUTS
	end

	local function showPreset(p)
		state.current = p
		if not p then
			itm.Desc.Text = "No preset matches the search."
			return
		end
		itm.Desc.Text = p.desc
		local img = LL.paths.previews and LL.join(LL.paths.previews, p.preview or "")
		if img and LL.fileExists(img) then
			pcall(function()
				itm.Preview.Icon = ui:Icon{ File = img }
				itm.Preview.Text = ""
			end)
		else
			pcall(function()
				itm.Preview.Icon = ui:Icon{}
				itm.Preview.Text = p.name
			end)
		end
		if state.mode == "titles" then
			local hasText = #(p.textTargets or {}) > 0
			itm.TTextLabel.Text = p.textLabel or "Text"
			itm.TText2Label.Text = p.text2Label or "Line 2"
			itm.TText.PlaceholderText = hasText and (p.text or "") or "(no text in this preset)"
			itm.TText2.PlaceholderText = p.text2 or "(not used by this preset)"
			itm.TText.Enabled = hasText
			itm.TText2.Enabled = p.text2Targets ~= nil
			itm.TFont.Enabled = #(p.fontTools or {}) > 0
			itm.TStyle.Enabled = #(p.fontTools or {}) > 0
			itm.TColor.Enabled = #(p.colorTargets or {}) > 0
			itm.TAccent.Enabled = p.accentTargets ~= nil
			itm.TIn.Enabled = p.inFrames ~= nil
			itm.TOut.Enabled = p.outFrames ~= nil
			itm.TIn.Value = p.inFrames or 0
			itm.TOut.Value = p.outFrames or 0
			itm.TSeconds.Text = tostring(p.seconds or 5)
		else
			itm.CDirection.Enabled = p.usesDirection == true
		end
	end

	local function refill()
		local q = LL.trim(itm.Search.Text):lower()
		local cat = state.categories[(itm.Category.CurrentIndex or 0) + 1]
		itm.List:Clear()
		state.visible = {}
		for _, p in ipairs(presets()) do
			local hay = (p.name .. " " .. (p.tag or "") .. " " .. (p.category or "") .. " " .. (p.desc or "")):lower()
			if (q == "" or hay:find(q, 1, true)) and (not cat or p.category == cat) then
				local it = itm.List:NewItem()
				it.Text[0] = p.name
				it.Text[1] = (p.category and (p.category .. "  ·  ") or "") .. (p.tag or "")
				itm.List:AddTopLevelItem(it)
				state.visible[#state.visible + 1] = p
			end
		end
		showPreset(state.visible[1])
	end

	local function setMode(mode)
		state.mode = mode
		itm.ModeTitles.Checked = mode == "titles"
		itm.ModeCuts.Checked = mode == "cuts"
		itm.Pages.CurrentIndex = mode == "titles" and 0 or 1
		-- category filter: index 0 is "All", then categories in LL.CATEGORY_ORDER / list order
		state.categories = { false }
		local seen = {}
		local ordered = {}
		if mode == "titles" then
			for _, c in ipairs(LL.CATEGORY_ORDER) do ordered[#ordered + 1] = c end
		end
		for _, p in ipairs(presets()) do ordered[#ordered + 1] = p.category end
		itm.Category:Clear()
		itm.Category:AddItem(mode == "titles" and "All titles" or "All transitions")
		for _, c in ipairs(ordered) do
			if c and not seen[c] then
				seen[c] = true
				state.categories[#state.categories + 1] = c
				itm.Category:AddItem(LL.CATEGORY_NAMES[c] or c)
			end
		end
		itm.Category.CurrentIndex = 0
		refill()
	end

	local function titleOpts()
		local font = LL.trim(itm.TFont.CurrentText)
		if font == PRESET_FONT then font = "" end
		return {
			text = itm.TText.Text, text2 = itm.TText2.Text, font = font, style = itm.TStyle.Text,
			color = itm.TColor.Text, accent = itm.TAccent.Text, seconds = tonumber(itm.TSeconds.Text) or 5,
			inFrames = itm.TIn.Value, outFrames = itm.TOut.Value,
		}
	end

	local function cutOpts()
		return {
			frames = itm.CFrames.Value, intensity = itm.CIntensity.Value,
			direction = LL.DIRECTIONS[(itm.CDirection.CurrentIndex or 0) + 1] or "Left",
			motionBlur = itm.CMotionBlur.Checked, track = itm.CTrack.CurrentIndex or 0,
		}
	end

	local function remember()
		local o, c = titleOpts(), cutOpts()
		LL.savePrefs({
			mode = state.mode, seconds = o.seconds, font = o.font, style = o.style, color = o.color, accent = o.accent,
			cutFrames = c.frames, cutIntensity = c.intensity, cutDirection = c.direction, cutMotionBlur = c.motionBlur,
			lastUpdateCheck = prefs.lastUpdateCheck,
		})
	end

	local function needPreset()
		if not state.current then LL.fail("Pick a preset first.") end
		return state.current
	end

	local function addTitle()
		local p = needPreset()
		setStatus(("Adding %s..."):format(p.name))
		local res = LL.addTitle(p, titleOpts())
		local msg = ("Added %q on V%d at %s (%.1f s)%s%s."):format(p.name, res.track, res.timecode,
			res.frames / res.fps, res.addedTrack and " on a new track" or "",
			res.how == "compound" and " as a compound clip" or "")
		if res.requested and math.abs(res.frames - res.requested) > 1 then
			msg = msg .. " Resolve uses its standard title length - drag the end to resize."
		end
		if res.moved and res.moved > 0 then
			msg = ("Added %q, but Resolve shifted %d clip(s) - press Cmd/Ctrl+Z to undo."):format(p.name, res.moved)
		end
		setStatus(msg)
		remember()
	end

	local function applyCut()
		local p = needPreset()
		local cut = LL.applyAtPlayhead(p, cutOpts())
		setStatus(("Applied %q to the cut on V%d (%d frames each side)."):format(p.name, cut.track, itm.CFrames.Value))
		remember()
	end

	function win.On.LoomLetter.Close(ev)
		remember()
		disp:ExitLoop()
	end

	win.On.ModeTitles.Clicked = guarded("Switch", function() setMode("titles") end)
	win.On.ModeCuts.Clicked = guarded("Switch", function() setMode("cuts") end)
	win.On.Search.TextChanged = guarded("Search", function() refill() end)
	win.On.Category.CurrentIndexChanged = guarded("Filter", function() refill() end)

	win.On.List.CurrentItemChanged = guarded("Select", function(ev)
		local it = itm.List:CurrentItem()
		if not it then return end
		local name = it.Text[0]
		for _, p in ipairs(state.visible) do
			if p.name == name then showPreset(p) end
		end
	end)

	local function primaryAction()
		if state.mode == "titles" then addTitle() else applyCut() end
	end
	win.On.List.ItemDoubleClicked = guarded("Apply", primaryAction)
	win.On.Preview.Clicked = guarded("Apply", primaryAction)

	win.On.AddTitle.Clicked = guarded("Add title", addTitle)
	win.On.ApplyCut.Clicked = guarded("Apply", applyCut)

	win.On.ApplySelection.Clicked = guarded("Apply", function()
		local p = needPreset()
		local n = LL.applyToSelection(p, cutOpts())
		setStatus(("Applied %q to %d cut(s) in the selection."):format(p.name, n))
		remember()
	end)

	win.On.RemoveSelection.Clicked = guarded("Remove", function()
		local removed, clips = LL.removeFromSelection()
		setStatus(removed == 0 and "No Loom Letter transitions found on the selected clips."
			or ("Removed Loom Letter transitions from %d clip(s)."):format(clips))
	end)

	win.On.CRefresh.Clicked = guarded("Refresh", function()
		refreshTracks()
		setStatus("Track list refreshed.")
	end)

	win.On.Diag.Clicked = guarded("Diagnostics", function()
		setStatus("Running diagnostics on the scratch timeline...")
		local lines = LL.diagnostics()
		local report = table.concat(lines, "\n")
		state.diagRuns = state.diagRuns + 1
		local id = "LoomLetterDiag" .. state.diagRuns
		local dwin = disp:AddWindow({
			ID = id, WindowTitle = "Loom Letter Diagnostics",
			Geometry = { 220, 160, 760, 460 }, WindowFlags = { Window = true, WindowStaysOnTopHint = true },
		}, ui:VGroup{ ui:TextEdit{ ID = "Report", ReadOnly = true } })
		if dwin then
			local ditm = dwin:GetItems()
			if not pcall(function() ditm.Report.PlainText = report end) then ditm.Report.Text = report end
			dwin.On[id].Close = function() dwin:Hide() end
			dwin:Show()
		end
		local fails = select(2, report:gsub("FAIL", ""))
		setStatus(fails == 0 and "Diagnostics passed. Report saved to the log."
			or ("Diagnostics found %d problem(s) - see the report window and the log."):format(fails))
	end)

	local function updateMessage(res)
		if res.installed then
			return ("Updated to %s. Close and reopen Loom Letter%s."):format(res.remote.version,
				res.titlesChanged and ", and restart Resolve so it picks up the new titles" or "")
		end
		return ("Update %s is available (%d file(s)). Click Update to install it."):format(res.remote.version, #res.get + #res.remove)
	end

	win.On.Update.Clicked = guarded("Update", function()
		if state.pendingUpdate then
			setStatus("Installing update...")
			local res = LL.applyUpdate(state.pendingUpdate)
			state.pendingUpdate = nil
			itm.Update.Text = "Check for Updates"
			setStatus(updateMessage(res))
			return
		end
		setStatus("Checking for updates...")
		local res = LL.checkForUpdate()
		prefs.lastUpdateCheck = os.time()
		if res.available then
			state.pendingUpdate = res
			itm.Update.Text = "Update"
			setStatus(updateMessage(res))
		else
			setStatus(("Loom Letter is up to date (%s)."):format(LL.VERSION))
		end
	end)

	setMode(state.mode)
	-- quiet automatic check, at most every LL.UPDATE_INTERVAL
	if os.time() - (tonumber(prefs.lastUpdateCheck) or 0) > LL.UPDATE_INTERVAL then
		local ok, res = pcall(LL.checkForUpdate)
		prefs.lastUpdateCheck = os.time()
		LL.savePrefs(prefs)
		if ok and res.available then
			state.pendingUpdate = res
			itm.Update.Text = "Update"
			setStatus(updateMessage(res))
		end
	end
	win:Show()
	disp:RunLoop()
	win:Hide()
end

-- ---------------------------------------------------------------------------------------

if LOOMLETTER_TEST then
	return LL
end

LL.initPaths()
LL.log("Loom Letter %s starting", LL.VERSION)
local ok, err = xpcall(LL.runUI, debug.traceback)
if not ok then
	LL.log("fatal: %s", tostring(err))
	print("[Loom Letter] " .. tostring(err))
end
