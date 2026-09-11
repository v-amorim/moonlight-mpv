-- sub-seek.lua
-- Source: https://github.com/v-amorim/moonlight-mpv
--
-- Fullscreen, clickable list of every subtitle line (with timestamps).
-- Click a line (or select with Up/Down + Enter) to seek to it; the list closes.
-- Behaves like the built-in sub-seek keybind, but lets you pick any line.
--
-- How it works: mpv exposes no API for "all subtitle lines", so the currently
-- selected sub track is extracted to a temporary .srt with ffmpeg and parsed.
-- ASS/embedded subs are converted to plain timed text by ffmpeg.
--
-- Bind it in input.conf, e.g.:   F7   script-binding   sub-seek-list

local mp = require("mp")
local utils = require("mp.utils")

----------------------------------------------------------------------
-- Options
----------------------------------------------------------------------
-- ffmpeg used to dump the selected subtitle track. Falls back to PATH.
local FFMPEG = [[ffmpeg]]
local WHEEL_ROWS = 3 -- rows scrolled per mouse wheel notch

----------------------------------------------------------------------
-- Colors (Moonlight theme, written as normal #RRGGBB hex) and helpers
----------------------------------------------------------------------
-- ASS wants colors in &HBBGGRR& byte order, so to_ass() reverses the byte
-- pairs once at load time; the rest of the script reads ready-to-use values.
-- Shared palette with keybind-visualizer.lua.
local function to_ass(rgb)
	return rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2)
end

local function say(state, detail)
	mp.commandv("script-message-to", "osd_theme", "say", "Subtitle index", state, detail)
end

-- the extract runs long enough that a message which faded would read as nothing
-- happening, and the list draws over the spot, so it is cleared rather than replaced
local function busy(detail)
	mp.commandv("script-message-to", "osd_theme", "busy", "Subtitle index", detail)
end

local function clear_osd()
	mp.commandv("script-message-to", "osd_theme", "clear")
end

local C = {}
for name, rgb in pairs({
	bg = "0D0E17", -- #0D0E17  full-screen dim behind the list
	panel = "141726", -- #141726  list panel background
	border = "252A42", -- #252A42  list panel border
	text = "EEEEFA", -- #EEEEFA  row text + "Subtitles" header
	dim = "9BA3C4", -- #9BA3C4  dimmed text (line count + footer hint)
	time = "8A9BE0", -- #8A9BE0  timestamp column
	cur = "7386D0", -- #7386D0  current line (under the playhead)
	sel_bg = "252A42", -- #252A42  selected row background
	hover_bg = "1C2033", -- #1C2033  hovered row background
	scroll_trk = "1C2033", -- #1C2033  scrollbar track
	scroll_thb = "8A9BE0", -- #8A9BE0  scrollbar thumb
	match = "A2B0EA", -- #A2B0EA  the typed words, picked out inside a row
}) do
	C[name] = to_ass(rgb)
end

local function round(x)
	return math.floor(x + 0.5)
end

local function rect_draw(w, h)
	return string.format("m 0 0 l %d 0 %d %d 0 %d", w, w, h, h)
end

-- escape user text so braces / backslashes are not read as ASS overrides
local function esc(s)
	s = s:gsub("\\", "\\\xE2\x81\xA0")
	s = s:gsub("{", "\\{"):gsub("}", "\\}")
	return s
end

-- first n unicode codepoints of s, with an ellipsis if truncated
local function utf8_sub(s, n)
	local i, count, len = 1, 0, #s
	while i <= len and count < n do
		local c = s:byte(i)
		local step = 1
		if c >= 0xF0 then
			step = 4
		elseif c >= 0xE0 then
			step = 3
		elseif c >= 0xC0 then
			step = 2
		end
		i = i + step
		count = count + 1
	end
	if i <= len then
		return s:sub(1, i - 1) .. "\xE2\x80\xA6"
	end
	return s
end

local function fmt_time(t)
	if t < 0 then
		t = 0
	end
	local h = math.floor(t / 3600)
	local m = math.floor((t % 3600) / 60)
	local s = math.floor(t % 60)
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%02d:%02d", m, s)
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local active = false
local overlay = nil
local subs = {} -- every parsed line: { {time=seconds, text=string}, ... }
local view = {} -- the lines the query keeps, and what every index below means
local query = "" -- what has been typed into the search
local tokens = {} -- the query split into lowercased words, all of which must hit
local sel = 1 -- highlighted index
local scroll = 1 -- index of the first visible row
local cur = nil -- index of the line under the playhead
local hovered = nil -- index under the mouse
local mouse_x, mouse_y = nil, nil
local geom = nil
local saved_autohide = nil
local loading = false

----------------------------------------------------------------------
-- Subtitle text cleanup + SRT parsing
----------------------------------------------------------------------
local function clean_text(s)
	s = s:gsub("\\N", " "):gsub("\\n", " ")
	s = s:gsub("{[^}]*}", "") -- ASS override blocks
	s = s:gsub("<[^>]->", "") -- html-ish tags (<i>, <b>, ...)
	s = s:gsub("%s+", " ")
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	return s
end

local function parse_srt(data)
	data = data:gsub("\r", "")
	data = data:gsub("^\xEF\xBB\xBF", "") -- strip UTF-8 BOM
	local out = {}
	local cur_start, cur_text
	local function flush()
		if cur_start then
			local t = clean_text(cur_text or "")
			if t ~= "" then
				out[#out + 1] = { time = cur_start, text = t }
			end
		end
		cur_start, cur_text = nil, nil
	end
	for line in (data .. "\n"):gmatch("(.-)\n") do
		local sh, sm, ss, ms = line:match("^%s*(%d+):(%d+):(%d+)[,%.](%d+)%s*%-%->")
		if sh then
			cur_start = sh * 3600 + sm * 60 + ss + ms / 1000
			cur_text = ""
		elseif cur_start then
			if line:match("^%s*$") then
				flush()
			else
				cur_text = (cur_text == "" and line) or (cur_text .. " " .. line)
			end
		end
		-- numeric index lines (before a timestamp) fall through and are ignored
	end
	flush()
	return out
end

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*all")
	f:close()
	return data
end

----------------------------------------------------------------------
-- Locate + extract the selected subtitle track
----------------------------------------------------------------------
local function selected_sub_track()
	local n = mp.get_property_number("track-list/count", 0)
	for i = 0, n - 1 do
		local p = string.format("track-list/%d/", i)
		if mp.get_property(p .. "type") == "sub" and mp.get_property(p .. "selected") == "yes" then
			return {
				external = mp.get_property(p .. "external") == "yes",
				ext_file = mp.get_property(p .. "external-filename"),
				ff_index = mp.get_property_number(p .. "ff-index"),
			}
		end
	end
	return nil
end

local function ffmpeg_bin()
	local fi = utils.file_info and utils.file_info(FFMPEG)
	if fi and fi.is_file then
		return FFMPEG
	end
	return "ffmpeg"
end

local function temp_srt()
	local dir = os.getenv("TEMP") or os.getenv("TMP") or "."
	return (dir .. "/mpv_sub_seek.srt"):gsub("\\", "/")
end

-- mpv reports "path" as it was given, so it is already complete for an absolute path or a
-- URL; joining those to the working directory points ffmpeg at a folder that does not exist
local function video_path()
	local path = mp.get_property("path") or ""
	if path:match("^%a:[/\\]") or path:match("^[/\\]") or path:match("^%a[%w+.-]*://") then
		return path
	end
	return mp.get_property("working-directory") .. "/" .. path
end

-- extract the selected track to a temp .srt, parse it, then call done(subs)
local function load_subs(done)
	local track = selected_sub_track()
	if not track then
		say("no track selected", "pick a subtitle track first, with CTRL+s")
		return
	end

	local out = temp_srt()
	local args
	if track.external and track.ext_file then
		args = { ffmpeg_bin(), "-y", "-hide_banner", "-loglevel", "error", "-i", track.ext_file, out }
	else
		local video = video_path()
		if not track.ff_index then
			say("track not found", "mpv reported no ffmpeg index for the selected track")
			return
		end
		args = {
			ffmpeg_bin(),
			"-y",
			"-hide_banner",
			"-loglevel",
			"error",
			"-i",
			video,
			"-map",
			string.format("0:%d", track.ff_index),
			out,
		}
	end

	loading = true
	busy("reading the track with ffmpeg")
	mp.command_native_async(
		{ name = "subprocess", playback_only = false, capture_stdout = true, args = args },
		function(success, res)
			loading = false
			if not (success and res and res.status == 0) then
				say("failed", "ffmpeg would not read the track, so it is probably neither ASS nor SRT")
				return
			end
			local data = read_file(out)
			local parsed = data and parse_srt(data) or {}
			if #parsed == 0 then
				say("empty", "the track carried no timed lines")
				return
			end
			clear_osd()
			done(parsed)
		end
	)
end

----------------------------------------------------------------------
-- Geometry
----------------------------------------------------------------------
local function compute_geom()
	-- osd-dimensions is the space ASS overlays render in and mouse-pos uses,
	-- so layout and hit-testing stay aligned in fullscreen / HiDPI.
	local dim = mp.get_property_native("osd-dimensions")
	if not dim or not dim.w or dim.w == 0 then
		return nil
	end
	local w, h = dim.w, dim.h
	local mx = round(w * 0.06)
	local my = round(h * 0.05)
	local header_h = round(h * 0.06)
	local footer_h = round(h * 0.04)
	local list_top = my + header_h + round(h * 0.012)
	local list_bottom = h - my - footer_h
	local row_h = math.max(16, round(h * 0.034))
	local fs = math.max(10, round(row_h * 0.6))
	local visible = math.max(1, math.floor((list_bottom - list_top) / row_h))
	local inner_x = mx + round(w * 0.012)
	local inner_w = w - 2 * inner_x
	local time_col_w = round(fs * 4.6)
	local max_chars = math.max(10, math.floor((inner_w - time_col_w) / (fs * 0.52)))
	return {
		w = w,
		h = h,
		mx = mx,
		my = my,
		header_y = my,
		header_h = header_h,
		footer_y = h - my - footer_h,
		list_top = list_top,
		list_bottom = list_top + visible * row_h,
		row_h = row_h,
		fs = fs,
		visible = visible,
		inner_x = inner_x,
		inner_w = inner_w,
		time_col_w = time_col_w,
		max_chars = max_chars,
	}
end

----------------------------------------------------------------------
-- Search
----------------------------------------------------------------------
-- Subtitles are prose, so every typed word has to appear literally: a fuzzy
-- match over sentences would keep almost every line.
local function line_matches(text)
	local low = text:lower()
	for _, token in ipairs(tokens) do
		if not low:find(token, 1, true) then
			return false
		end
	end
	return true
end

-- rebuild the view, keeping the same line selected when it survives the filter
local function apply_filter()
	local anchor = view[sel]
	tokens = {}
	for token in query:lower():gmatch("%S+") do
		tokens[#tokens + 1] = token
	end

	view = {}
	for _, line in ipairs(subs) do
		if #tokens == 0 or line_matches(line.text) then
			view[#view + 1] = line
		end
	end

	sel = 1
	if anchor then
		for i, line in ipairs(view) do
			if line == anchor then
				sel = i
				break
			end
		end
	end
end

-- colored ASS text: the typed words stand out from the rest of the line
local function highlight(text, base_color)
	local base = string.format("{\\1c&H%s&}", base_color)
	if #tokens == 0 then
		return base .. esc(text)
	end
	local low = text:lower()
	local mask = {}
	for _, token in ipairs(tokens) do
		local from = 1
		while true do
			local at = low:find(token, from, true)
			if not at then
				break
			end
			for i = at, at + #token - 1 do
				mask[i] = true
			end
			from = at + 1
		end
	end
	local hl = string.format("{\\1c&H%s&}", C.match)
	local out, i = {}, 1
	while i <= #text do
		local on = mask[i] == true
		local j = i
		while j < #text and (mask[j + 1] == true) == on do
			j = j + 1
		end
		out[#out + 1] = (on and hl or base) .. esc(text:sub(i, j))
		i = j + 1
	end
	return table.concat(out)
end

local function max_scroll()
	if not geom then
		return 1
	end
	return math.max(1, #view - geom.visible + 1)
end

local function clamp_scroll()
	if scroll < 1 then
		scroll = 1
	elseif scroll > max_scroll() then
		scroll = max_scroll()
	end
end

local function ensure_visible()
	if not geom then
		return
	end
	if sel < scroll then
		scroll = sel
	elseif sel > scroll + geom.visible - 1 then
		scroll = sel - geom.visible + 1
	end
	clamp_scroll()
end

local function cur_index(pos)
	if not pos then
		return nil
	end
	local idx = nil
	for i = 1, #view do
		if view[i].time <= pos + 0.05 then
			idx = i
		else
			break
		end
	end
	return idx
end

-- index of the subtitle row under (mx,my), or nil
local function row_at(px, py)
	if not geom then
		return nil
	end
	if py < geom.list_top or py >= geom.list_bottom then
		return nil
	end
	if px < geom.mx or px > geom.w - geom.mx then
		return nil
	end
	local i = scroll + math.floor((py - geom.list_top) / geom.row_h)
	if i >= 1 and i <= #view then
		return i
	end
	return nil
end

----------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------
local function render()
	if not active or not overlay then
		return
	end
	geom = compute_geom()
	if not geom then
		return
	end
	local g = geom
	clamp_scroll()
	overlay.res_x = g.w
	overlay.res_y = g.h

	local a = {}

	-- full-screen dim
	a[#a + 1] =
		string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H30&\\p1}%s{\\p0}", C.bg, rect_draw(g.w, g.h))
	-- list panel background
	a[#a + 1] = string.format(
		"{\\an7\\pos(%d,%d)\\bord2\\shad0\\3c&H%s&\\1c&H%s&\\1a&H18&\\p1}%s{\\p0}",
		g.mx,
		g.list_top - round(g.row_h * 0.3),
		C.border,
		C.panel,
		rect_draw(g.w - 2 * g.mx, (g.list_bottom - g.list_top) + round(g.row_h * 0.6))
	)

	-- header, with the query and how much of the track it leaves
	local hfs = math.max(12, round(g.header_h * 0.55))
	local counts = (query ~= "") and string.format("%d of %d lines", #view, #subs)
		or string.format("%d lines", #subs)
	local typed = (query ~= "")
			and string.format("{\\1c&H%s&}%s_", C.match, esc(query))
		or string.format("{\\1c&H%s&}type to search", C.dim)
	a[#a + 1] = string.format(
		"{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0\\b1\\1c&H%s&}Subtitles{\\b0\\fs%d\\1c&H%s&}   %s   %s",
		g.inner_x,
		g.header_y + round(g.header_h / 2),
		hfs,
		C.text,
		round(hfs * 0.7),
		C.dim,
		counts,
		typed
	)

	-- rows
	local first = scroll
	local last = math.min(#view, scroll + g.visible - 1)
	for i = first, last do
		local ry = g.list_top + (i - first) * g.row_h
		local is_sel = (i == sel)
		local is_cur = (i == cur)
		if is_sel or i == hovered then
			a[#a + 1] = string.format(
				"{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H%s&\\1a&H20&\\p1}%s{\\p0}",
				g.mx + round(g.row_h * 0.15),
				ry,
				is_sel and C.sel_bg or C.hover_bg,
				rect_draw(g.w - 2 * g.mx - round(g.row_h * 0.3), g.row_h)
			)
		end
		local cy = ry + round(g.row_h / 2)
		-- timestamp
		a[#a + 1] = string.format(
			"{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H%s&}%s",
			g.inner_x,
			cy,
			g.fs,
			is_cur and C.cur or C.time,
			fmt_time(view[i].time)
		)
		-- text, with the typed words picked out of it
		a[#a + 1] = string.format(
			"{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0}%s",
			g.inner_x + g.time_col_w,
			cy,
			g.fs,
			highlight(utf8_sub(view[i].text, g.max_chars), is_cur and C.cur or C.text)
		)
	end

	if #view == 0 then
		a[#a + 1] = string.format(
			"{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H%s&}No line matches that.",
			g.inner_x,
			g.list_top + round(g.row_h / 2),
			g.fs,
			C.dim
		)
	end

	-- scrollbar (only when the list overflows)
	if #view > g.visible then
		local trk_x = g.w - g.mx + round(g.mx * 0.25)
		local trk_y = g.list_top
		local trk_h = g.list_bottom - g.list_top
		local tw = math.max(4, round(g.mx * 0.18))
		a[#a + 1] = string.format(
			"{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H%s&\\1a&H40&\\p1}%s{\\p0}",
			trk_x,
			trk_y,
			C.scroll_trk,
			rect_draw(tw, trk_h)
		)
		local thb_h = math.max(round(g.row_h), round(trk_h * g.visible / #view))
		local thb_y = trk_y + round((trk_h - thb_h) * (scroll - 1) / math.max(1, max_scroll() - 1))
		a[#a + 1] = string.format(
			"{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H%s&\\1a&H10&\\p1}%s{\\p0}",
			trk_x,
			thb_y,
			C.scroll_thb,
			rect_draw(tw, thb_h)
		)
	end

	-- footer hint
	a[#a + 1] = string.format(
		"{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H%s&}Click a line to jump   "
			.. "{\\1c&H%s&}Up/Down{\\1c&H%s&}+{\\1c&H%s&}Enter{\\1c&H%s&}   "
			.. "Type to search, {\\1c&H%s&}BS{\\1c&H%s&} erases   {\\1c&H%s&}ESC{\\1c&H%s&} clears, then closes",
		g.inner_x,
		g.footer_y + round((g.h - g.footer_y - g.my) / 2),
		math.max(11, round(g.row_h * 0.55)),
		C.dim,
		C.time,
		C.dim,
		C.time,
		C.dim,
		C.time,
		C.dim,
		C.time,
		C.dim
	)

	overlay.data = table.concat(a, "\n")
	overlay:update()
end

----------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------
local function seek_to(i)
	if view[i] then
		mp.commandv("seek", string.format("%.3f", view[i].time), "absolute+exact")
	end
end

local close -- fwd decl

local function activate(i)
	if view[i] then
		seek_to(i)
		close()
	end
end

local function on_mouse(_, val)
	if not active then
		return
	end
	local mxp, myp
	if type(val) == "table" then
		mxp, myp = val.x, val.y
	else
		local pos = mp.get_property_native("mouse-pos")
		if pos then
			mxp, myp = pos.x, pos.y
		end
	end
	if not mxp then
		return
	end
	mouse_x, mouse_y = mxp, myp
	hovered = row_at(mxp, myp)
	render()
end

local function on_resize()
	if active then
		render()
	end
end

local function on_time(_, pos)
	if not active then
		return
	end
	local ni = cur_index(pos)
	if ni ~= cur then
		cur = ni
		render()
	end
end

local function on_click()
	if not active then
		return
	end
	local pos = mp.get_property_native("mouse-pos")
	if not pos then
		return
	end
	local i = row_at(pos.x, pos.y)
	if i then
		activate(i)
	end
end

local function move(delta)
	if #view == 0 then
		return
	end
	sel = math.max(1, math.min(#view, sel + delta))
	ensure_visible()
	render()
end

----------------------------------------------------------------------
-- Search input: while the list owns the screen, printable keys type into the
-- query instead of reaching the player.
----------------------------------------------------------------------
local SEARCH_KEYS = { SPACE = " ", ["-"] = "-", ["'"] = "'", ["."] = ".", [","] = ",", ["?"] = "?", ["!"] = "!" }
for c in ("abcdefghijklmnopqrstuvwxyz0123456789"):gmatch(".") do
	SEARCH_KEYS[c] = c
end

local function set_query(q)
	query = q
	apply_filter()
	-- indices moved under the filter, so the playhead row has to be found again
	cur = cur_index(mp.get_property_number("time-pos"))
	scroll = math.max(1, sel - math.floor((geom and geom.visible or 10) / 2))
	clamp_scroll()
	render()
end

local function bind_search_keys()
	for key, char in pairs(SEARCH_KEYS) do
		mp.add_forced_key_binding(key, "sub-seek-s-" .. key, function()
			set_query(query .. char)
		end, { repeatable = true })
	end
	mp.add_forced_key_binding("BS", "sub-seek-s-bs", function()
		set_query(query:sub(1, -2))
	end, { repeatable = true })
end

local function unbind_search_keys()
	for key in pairs(SEARCH_KEYS) do
		mp.remove_key_binding("sub-seek-s-" .. key)
	end
	mp.remove_key_binding("sub-seek-s-bs")
end

local function scroll_by(delta)
	scroll = scroll + delta
	clamp_scroll()
	-- keep hover in sync after a wheel scroll
	if mouse_x then
		hovered = row_at(mouse_x, mouse_y)
	end
	render()
end

----------------------------------------------------------------------
-- Open / close
----------------------------------------------------------------------
close = function()
	if not active then
		return
	end
	active = false
	hovered = nil
	query = ""
	tokens = {}
	mp.unobserve_property(on_mouse)
	mp.unobserve_property(on_resize)
	mp.unobserve_property(on_time)
	mp.remove_key_binding("sub-seek-esc")
	mp.remove_key_binding("sub-seek-click")
	mp.remove_key_binding("sub-seek-up")
	mp.remove_key_binding("sub-seek-down")
	mp.remove_key_binding("sub-seek-pgup")
	mp.remove_key_binding("sub-seek-pgdn")
	mp.remove_key_binding("sub-seek-enter")
	mp.remove_key_binding("sub-seek-wup")
	mp.remove_key_binding("sub-seek-wdn")
	mp.remove_key_binding("sub-seek-home")
	mp.remove_key_binding("sub-seek-end")
	unbind_search_keys()
	if saved_autohide ~= nil then
		mp.set_property("cursor-autohide", saved_autohide)
		saved_autohide = nil
	end
	if overlay then
		overlay:remove()
	end
end

local function open_with(parsed)
	subs = parsed
	query = ""
	apply_filter()
	if not overlay then
		overlay = mp.create_osd_overlay("ass-events")
	end
	active = true
	hovered = nil
	geom = compute_geom()

	cur = cur_index(mp.get_property_number("time-pos"))
	sel = cur or 1
	scroll = sel - math.floor((geom and geom.visible or 10) / 2)
	clamp_scroll()

	local pos = mp.get_property_native("mouse-pos")
	if pos then
		mouse_x, mouse_y = pos.x, pos.y
	end
	saved_autohide = mp.get_property("cursor-autohide")
	mp.set_property("cursor-autohide", "no")

	mp.observe_property("mouse-pos", "native", on_mouse)
	mp.observe_property("osd-dimensions", "native", on_resize)
	mp.observe_property("time-pos", "number", on_time)

	mp.add_forced_key_binding("ESC", "sub-seek-esc", function()
		if query ~= "" then
			set_query("")
		else
			close()
		end
	end)
	mp.add_forced_key_binding("MBTN_LEFT", "sub-seek-click", on_click)
	mp.add_forced_key_binding("UP", "sub-seek-up", function()
		move(-1)
	end, { repeatable = true })
	mp.add_forced_key_binding("DOWN", "sub-seek-down", function()
		move(1)
	end, { repeatable = true })
	mp.add_forced_key_binding("PGUP", "sub-seek-pgup", function()
		move(-(geom and geom.visible or 10))
	end, { repeatable = true })
	mp.add_forced_key_binding("PGDWN", "sub-seek-pgdn", function()
		move(geom and geom.visible or 10)
	end, { repeatable = true })
	mp.add_forced_key_binding("HOME", "sub-seek-home", function()
		sel = 1
		ensure_visible()
		render()
	end)
	mp.add_forced_key_binding("END", "sub-seek-end", function()
		sel = #view
		ensure_visible()
		render()
	end)
	mp.add_forced_key_binding("ENTER", "sub-seek-enter", function()
		activate(sel)
	end)
	mp.add_forced_key_binding("WHEEL_UP", "sub-seek-wup", function()
		scroll_by(-WHEEL_ROWS)
	end)
	mp.add_forced_key_binding("WHEEL_DOWN", "sub-seek-wdn", function()
		scroll_by(WHEEL_ROWS)
	end)
	bind_search_keys()

	render()
end

local function toggle()
	if active then
		close()
		return
	end
	if loading then
		return
	end
	load_subs(open_with)
end

mp.add_key_binding(nil, "sub-seek-list", toggle)
mp.register_event("shutdown", function()
	if overlay then
		overlay:remove()
	end
end)
