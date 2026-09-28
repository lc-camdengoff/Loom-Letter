--[[
Mock Resolve / Fusion / UIManager objects for Loom Letter's headless tests.
They model only what Loom Letter calls, plus a few checks that catch misuse (for example
inserting a title into a timeline that isn't the current one).
]]

local M = {}

-- ---------------------------------------------------------------------------------------
-- Fusion comps
-- ---------------------------------------------------------------------------------------

local function new_output(comp, tool)
	local out = { tool = tool }
	function out:GetTool() return self.tool end
	function out:GetConnectedInputs()
		local list = {}
		for _, t in ipairs(comp.tools) do
			for _, inp in pairs(t.inputs) do
				if inp.source == self then list[#list + 1] = inp end
			end
		end
		return list
	end
	return out
end

local function new_input(tool, id)
	local inp = { tool = tool, id = id }
	function inp:ConnectTo(output) self.source = output end
	function inp:GetConnectedOutput() return self.source end
	function inp:SetExpression(e) self.expression = e end
	return inp
end

function M.comp(opts)
	opts = opts or {}
	local comp = { tools = {}, undo = 0, locked = 0, counter = 0, sets = {},
		render = opts.render or { 0, 119 } }

	function comp:new_tool(reg, name)
		local tool = { reg = reg, Name = name, inputs = {}, values = {}, data = {} }
		tool.main_in = new_input(tool, "Input")
		tool.inputs.Input = tool.main_in
		tool.output = new_output(comp, tool)
		setmetatable(tool, { __index = function(t, k)
			local inp = rawget(t, "inputs")[k]
			if not inp then
				inp = new_input(t, k)
				rawget(t, "inputs")[k] = inp
			end
			return inp
		end })
		function tool:FindMainInput() return self.main_in end
		function tool:FindMainOutput() return self.output end
		function tool:SetInput(id, v)
			self.values[id] = v
			comp.sets[self.Name .. "." .. id] = v
		end
		function tool:GetInput(id) return self.values[id] end
		function tool:SetData(k, v) self.data[k] = v end
		function tool:GetData(k) return self.data[k] end
		function tool:SetAttrs(a) if a.TOOLS_Name then self.Name = a.TOOLS_Name end end
		function tool:GetAttrs() return { TOOLS_RegID = self.reg, TOOLS_Name = self.Name } end
		function tool:Delete()
			for i, t in ipairs(comp.tools) do
				if t == self then table.remove(comp.tools, i) break end
			end
			for _, t in ipairs(comp.tools) do
				for _, inp in pairs(t.inputs) do
					if inp.source == self.output then inp.source = nil end
				end
			end
		end
		self.tools[#self.tools + 1] = tool
		return tool
	end

	local media_in = comp:new_tool("MediaIn", "MediaIn1")
	local media_out = comp:new_tool("MediaOut", "MediaOut1")
	media_out.main_in:ConnectTo(media_in.output)
	comp.media_in, comp.media_out = media_in, media_out

	-- Tools that exist inside a title macro (FindTool finds them, like in Fusion).
	for _, name in ipairs(opts.inner or {}) do comp:new_tool("TextPlus", name) end

	function comp:GetToolList(selected, reg)
		local list = {}
		for _, t in ipairs(self.tools) do
			if not reg or t.reg == reg then list[#list + 1] = t end
		end
		return list
	end
	function comp:AddTool(reg)
		self.counter = self.counter + 1
		return self:new_tool(reg, reg .. self.counter)
	end
	function comp:FindTool(name)
		for _, t in ipairs(self.tools) do if t.Name == name then return t end end
	end
	function comp:GetAttrs()
		return { COMPN_RenderStart = self.render[1], COMPN_RenderEnd = self.render[2],
			COMPN_GlobalStart = self.render[1], COMPN_GlobalEnd = self.render[2] }
	end
	function comp:Lock() self.locked = self.locked + 1 end
	function comp:Unlock() self.locked = self.locked - 1 end
	function comp:StartUndo() self.undo = self.undo + 1 end
	function comp:EndUndo() self.undo = self.undo - 1 end

	--- "MediaIn1 > ... > MediaOut1" following main inputs back from MediaOut.
	function comp:chain()
		local names, out = {}, self.media_out.main_in:GetConnectedOutput()
		while out do
			local t = out:GetTool()
			table.insert(names, 1, t.Name)
			out = t.main_in:GetConnectedOutput()
		end
		names[#names + 1] = "MediaOut1"
		return table.concat(names, " > ")
	end
	return comp
end

-- ---------------------------------------------------------------------------------------
-- Timelines and items
-- ---------------------------------------------------------------------------------------

function M.item(start, dur, track, name)
	local it = {
		start = start, dur = dur, track = track, name = name or ("clip@" .. start), comps = {},
		id = tostring(math.random(1, 1e9)),
	}
	function it:GetStart() return self.start end
	function it:GetDuration() return self.dur end
	function it:GetEnd() return self.start + self.dur end
	function it:GetName() return self.name end
	function it:GetUniqueId() return self.id end
	function it:GetTrackTypeAndIndex() return { "video", self.track } end
	function it:GetMediaPoolItem() return self.mpi end
	function it:GetFusionCompCount() return #self.comps end
	function it:GetFusionCompByIndex(i) return self.comps[i] end
	function it:AddFusionComp()
		local c = M.comp({ render = { 0, self.dur - 1 } })
		self.comps[#self.comps + 1] = c
		return c
	end
	return it
end

function M.timeline(tracks, opts)
	opts = opts or {}
	local function copy(t) local c = {} for k, v in pairs(t or {}) do c[k] = v end return c end
	local tl = { tracks = tracks, locked = copy(opts.locked), disabled = copy(opts.disabled), selected = opts.selected }
	for t, items in pairs(tracks) do
		for _, it in ipairs(items) do it.track = t end
	end
	function tl:GetTrackCount(kind) return kind == "video" and #self.tracks or 0 end
	function tl:GetItemListInTrack(kind, t)
		-- Resolve returns a 1..n table; hand back a reversed copy so order isn't assumed
		local items, out = self.tracks[t] or {}, {}
		for i = #items, 1, -1 do out[#items - i + 1] = items[i] end
		return out
	end
	function tl:GetIsTrackLocked(kind, t)
		if kind ~= "video" then return (self.otherLocks or {})[kind .. t] == true end
		return self.locked[t] == true
	end
	function tl:SetTrackLock(kind, t, v)
		if kind ~= "video" then
			self.otherLocks = self.otherLocks or {}
			self.otherLocks[kind .. t] = v
		else
			self.locked[t] = v
		end
		return true
	end
	function tl:DeleteTrack(kind, t)
		if kind == "video" and self.tracks[t] then table.remove(self.tracks, t) end
		return true
	end
	function tl:GetIsTrackEnabled(kind, t) return self.disabled[t] ~= true end
	function tl:AddTrack(kind) self.tracks[#self.tracks + 1] = {}; return true end
	function tl:GetSelectedClips() return self.selected or {} end
	function tl:all_items()
		local list = {}
		for t, items in ipairs(self.tracks) do
			for _, it in ipairs(items) do list[#list + 1] = it end
		end
		return list
	end
	return tl
end

local function frames_to_tc(frames, fps)
	local f = frames % fps
	local s = math.floor(frames / fps)
	return ("%02d:%02d:%02d:%02d"):format(math.floor(s / 3600), math.floor(s / 60) % 60, s % 60, f)
end

--- A small Resolve: one project, a media pool, and a user timeline built from `tracks`.
--- opts.titles_have_mpi = false simulates titles without a media pool item (compound fallback).
function M.resolve(tracks, opts)
	opts = opts or {}
	local env = { log = {} }
	local project = { timelines = {}, settings = { timelineFrameRate = "24" } }
	env.project = project

	local function folder(name)
		local f = { name = name, clips = {}, subs = {} }
		function f:GetName() return self.name end
		function f:GetClipList() return self.clips end
		function f:GetSubFolderList() return self.subs end
		return f
	end

	local function add_timeline(name, t)
		local tl = M.timeline(t or { {} }, opts)
		tl.name, tl.start_frame, tl.playhead = name, 86400, 86400 + (opts.playhead or 240)
		function tl:GetName() return self.name end
		function tl:GetUniqueId() return self.name end
		function tl:GetSetting(k) return project.settings[k] end
		function tl:GetStartFrame() return self.start_frame end
		function tl:GetStartTimecode() return "01:00:00:00" end
		function tl:GetCurrentTimecode() return frames_to_tc(self.playhead, 24) end
		function tl:GetCurrentVideoItem()
			for t = #self.tracks, 1, -1 do
				for _, it in ipairs(self.tracks[t]) do
					if it.start <= self.playhead and self.playhead < it.start + it.dur then return it end
				end
			end
		end
		function tl:SetCurrentTimecode(tc)
			local h, m, s, f = tc:match("(%d+):(%d+):(%d+)[:;](%d+)")
			self.playhead = ((tonumber(h) * 60 + tonumber(m)) * 60 + tonumber(s)) * 24 + tonumber(f)
			return true
		end
		function tl:InsertFusionTitleIntoTimeline(name)
			assert(project.current == self, "InsertFusionTitleIntoTimeline on a timeline that is not current")
			if not (opts.templates or {})[name] then return nil end
			-- "lock_aware": lands on the top unlocked video track and ripples unlocked tracks only
			-- otherwise: lands on V1 and ripples every track (a Resolve that ignores locks)
			local track, lockAware = 1, opts.insert_model == "lock_aware"
			if lockAware then
				track = nil
				for t = #self.tracks, 1, -1 do
					if not self.locked[t] then track = t break end
				end
				if not track then return nil end
			end
			for t, items in ipairs(self.tracks) do
				if not (lockAware and self.locked[t]) then
					for _, other in ipairs(items) do
						if other.start >= self.playhead then other.start = other.start + 120 end
					end
				end
			end
			local it = M.item(self.playhead, 120, track, name)
			it.comps = { M.comp({ inner = { "Title", "NameText", "RoleText", "Accent" } }) }
			if opts.titles_have_mpi ~= false then
				it.mpi = { name = name, kind = "title", max_len = opts.title_max_len }
				function it.mpi:GetName() return self.name end
				function it.mpi:GetClipProperty() return "Fusion Title" end
			end
			table.insert(self.tracks[track], it)
			env.log[#env.log + 1] = "insert " .. name .. " into " .. self.name
			return it
		end
		function tl:CreateCompoundClip(items, info)
			assert(project.current == self, "CreateCompoundClip on a timeline that is not current")
			local src = items[1]
			local c = M.item(src.start, src.dur, src.track, info and info.name or "Compound Clip")
			c.mpi = { name = c.name, kind = "compound", inner = src }
			function c.mpi:GetName() return self.name end
			self:DeleteClips(items)
			table.insert(self.tracks[c.track], c)
			return c
		end
		function tl:DeleteClips(items)
			for _, target in ipairs(items) do
				for _, list in ipairs(self.tracks) do
					for i = #list, 1, -1 do
						if list[i] == target then table.remove(list, i) end
					end
				end
			end
			return true
		end
		project.timelines[#project.timelines + 1] = tl
		return tl
	end

	local root = folder("Master")
	local pool = { root = root, current = root }
	function pool:GetRootFolder() return self.root end
	function pool:GetCurrentFolder() return self.current end
	function pool:SetCurrentFolder(f) self.current = f; return true end
	function pool:AddSubFolder(parent, name)
		local f = folder(name)
		parent.subs[#parent.subs + 1] = f
		return f
	end
	function pool:CreateEmptyTimeline(name)
		local tl = add_timeline(name, { {} })
		tl.folder = self.current
		project.current = tl -- Resolve opens new timelines; Loom Letter must switch back
		return tl
	end
	function pool:AppendToTimeline(list)
		local tl = project.current
		local out = {}
		for _, info in ipairs(list) do
			local mpi = info.mediaPoolItem
			local dur = info.endFrame - info.startFrame + 1
			local track = info.trackIndex or 1
			if not tl.tracks[track] then return {} end
			if mpi.max_len and dur > mpi.max_len then return {} end
			local it = M.item(info.recordFrame or tl.start_frame, dur, track, mpi.name)
			it.mpi = mpi
			if mpi.kind == "title" then
				it.comps = { M.comp({ inner = { "Title", "NameText", "RoleText", "Accent" } }) }
			end
			table.insert(tl.tracks[track], it)
			env.log[#env.log + 1] = ("append %s to %s V%d @%d"):format(mpi.name, tl.name, track, it.start)
			out[#out + 1] = it
		end
		return out
	end
	env.pool = pool

	function project:GetMediaPool() return pool end
	function project:GetCurrentTimeline() return self.current end
	function project:SetCurrentTimeline(tl) self.current = tl; return true end
	function project:GetTimelineCount() return #self.timelines end
	function project:GetTimelineByIndex(i) return self.timelines[i] end
	function project:GetSetting(k) return self.settings[k] end

	env.timeline = add_timeline("Edit 1", tracks)
	project.current = env.timeline

	env.resolve = {
		GetProjectManager = function() return { GetCurrentProject = function() return project end } end,
		GetProductName = function() return "DaVinci Resolve Studio (mock)" end,
		GetVersionString = function() return "21.0.0.0" end,
	}
	return env
end

-- ---------------------------------------------------------------------------------------
-- UIManager
-- ---------------------------------------------------------------------------------------

--- ui, dispatcher and a handle to drive events. `driver(win, items)` runs inside RunLoop.
function M.ui(driver)
	local ui, widgets = {}, {}
	local windows = {}

	local function widget(kind, props)
		local w = { __kind = kind, children = {} }
		if type(props) == "table" then
			for k, v in pairs(props) do
				if type(k) == "number" then w.children[#w.children + 1] = v else w[k] = v end
			end
		end
		if kind == "Tree" then
			w.items, w.ColumnWidth = {}, {}
			function w:SetHeaderLabels(l) self.headers = l end
			function w:Clear() self.items = {}; self.current = nil end
			function w:NewItem() return { Text = {}, Icon = {} } end
			function w:AddTopLevelItem(it) self.items[#self.items + 1] = it end
			function w:CurrentItem() return self.current end
		elseif kind == "ComboBox" then
			w.items, w.CurrentIndex = {}, 0
			function w:AddItem(s) self.items[#self.items + 1] = s; self.CurrentText = self.CurrentText or s end
			function w:AddItems(l) for _, s in ipairs(l) do self:AddItem(s) end end
			function w:Clear() self.items = {}; self.CurrentText = nil; self.CurrentIndex = 0 end
			function w:SetEditText(s) self.CurrentText = s end
		elseif kind == "LineEdit" then
			w.Text = w.Text or ""
		elseif kind == "SpinBox" then
			w.Value = w.Value or 0
		end
		if w.ID then widgets[w.ID] = w end
		return w
	end

	setmetatable(ui, { __index = function(_, kind)
		return function(self, props) return widget(kind, props) end
	end })

	function ui:FindWindow(id)
		for _, w in ipairs(windows) do
			if w.props.ID == id and w.shown then return w end
		end
	end

	local function autoviv()
		return setmetatable({}, { __index = function(t, k)
			local v = {}
			rawset(t, k, v)
			return v
		end })
	end

	local disp = {}
	function disp:AddWindow(props, rootw)
		local win = { props = props, root = rootw, On = autoviv(), shown = false }
		function win:GetItems() return widgets end
		function win:Show() self.shown = true end
		function win:Hide() self.shown = false end
		windows[#windows + 1] = win
		return win
	end
	function disp:RunLoop() driver(windows[1], widgets, windows) end
	function disp:ExitLoop() self.exited = true end

	return ui, function() return disp end, widgets, windows
end

return M
