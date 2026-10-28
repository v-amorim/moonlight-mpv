-- active-state.lua
-- Source: https://github.com/v-amorim/moonlight-mpv
--
-- Lists every tracked setting currently holding a value other than this
-- config's own baked-in default: audio filters, deinterlace, speed, subtitle
-- overrides, colour and more.
--
-- The "default" for each property is snapshotted once at mpv startup, before
-- any binding runs, so it is whatever mpv.conf actually set, not a guessed
-- factory value duplicated here. Audio filters and GLSL shaders are the
-- exception: they are compared by label/name instead, since the toggle
-- bindings always add a labeled filter or named shader on top of the config's
-- own unlabeled default.
--
-- Click any entry to put that one setting back to its default.
--
-- Activate with:  script-binding active-state
-- Close with ESC (or toggle again).

local mp = require("mp")

----------------------------------------------------------------------
-- Colors (Moonlight theme, written as normal #RRGGBB hex) and helpers
----------------------------------------------------------------------
-- ASS wants colors in &HBBGGRR& byte order, so to_ass() reverses the byte
-- pairs once at load time; the rest of the script reads ready-to-use values.
-- Shared palette with keybind-visualizer.lua / sub-seek.lua.
local function to_ass(rgb)
	return rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2)
end

local C = {}
for name, rgb in pairs({
	bg = "0D0E17", -- #0D0E17  full-screen dim behind the panel
	panel = "141726", -- #141726  panel background
	border = "242839", -- #242839  panel hairline
	text = "EEEEFA", -- #EEEEFA  row text + "Active state" header
	dim = "9BA3C4", -- #9BA3C4  dimmed text (group headings + footer hint)
	value = "A2B0EA", -- #A2B0EA  the current value column, primary-70
	accent = "7386D0", -- #7386D0  cursor dot
	hover_bg = "1C2033", -- #1C2033  hovered row background
	key = "252A42", -- #252A42  keycap in the key hints
	edge = "0D0E17", -- #0D0E17  keycap bottom edge
}) do
	C[name] = to_ass(rgb)
end

-- Rounded rectangle with circular corners (bezier handles at 0.5523 of the radius); r = half the side draws a circle.
local function rrect_draw(w, h, r)
	r = math.min(r, w / 2, h / 2)
	local k = r * 0.4477
	return string.format(
		"m %.1f 0 l %.1f 0 b %.1f 0 %.1f %.1f %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f "
			.. "l %.1f %.1f b %.1f %.1f 0 %.1f 0 %.1f l 0 %.1f b 0 %.1f %.1f 0 %.1f 0",
		r, w - r, w - k, w, k, w, r,
		w, h - r, w, h - k, w - k, h, w - r, h,
		r, h, k, h, h - k, h - r,
		r, k, k, r
	)
end

local ITEMS = {
	{ group = "Video", prop = "deinterlace", label = "Deinterlace" },
	{ group = "Video", prop = "deband", label = "Debanding" },
	{ group = "Video", prop = "deband-iterations", label = "Debanding passes" },
	{ group = "Video", prop = "interpolation", label = "Interpolation" },
	{ group = "Video", prop = "target-trc", label = "Display output" },
	{ group = "Video", prop = "video-zoom", label = "Zoom" },
	{ group = "Video", prop = "video-pan-x", label = "Pan X" },
	{ group = "Video", prop = "video-pan-y", label = "Pan Y" },
	{ group = "Video", prop = "video-aspect-override", label = "Aspect override" },
	{ group = "Video", prop = "video-rotate", label = "Rotation" },
	{ group = "Video", prop = "panscan", label = "Pan and scan" },
	{ group = "Video", prop = "contrast", label = "Contrast" },
	{ group = "Video", prop = "brightness", label = "Brightness" },
	{ group = "Video", prop = "gamma", label = "Gamma" },
	{ group = "Video", prop = "saturation", label = "Saturation" },
	{ group = "Video", prop = "ontop", label = "Always on top" },

	{ group = "Audio", prop = "volume", label = "Volume" },
	{ group = "Audio", prop = "mute", label = "Mute" },
	{ group = "Audio", prop = "audio-delay", label = "Audio delay" },

	{ group = "Subtitles", prop = "sub-delay", label = "Subtitle delay" },
	{ group = "Subtitles", prop = "sub-scale", label = "Subtitle size" },
	{ group = "Subtitles", prop = "sub-pos", label = "Subtitle position" },
	{ group = "Subtitles", prop = "sub-visibility", label = "Subtitles" },
	{ group = "Subtitles", prop = "secondary-sub-visibility", label = "Second subtitles" },
	{ group = "Subtitles", prop = "sub-forced-events-only", label = "Forced lines only" },
	{ group = "Subtitles", prop = "sub-ass-override", label = "Subtitle styling" },
	{ group = "Subtitles", prop = "sub-ass-use-video-data", label = "Subtitle stretch fix" },
	{ group = "Subtitles", prop = "sub-ass-style-overrides", label = "Subtitle look override" },

	{ group = "Playback", prop = "speed", label = "Speed" },
	{ group = "Playback", prop = "loop-file", label = "Loop" },
	{ group = "Playback", prop = "play-dir", label = "Playback direction" },
}

-- native snapshot for resetting a property back to its exact type/value, plus a
-- string snapshot (mpv's own formatted readout) for comparing and displaying it,
-- since a choice property like sub-ass-override reads back as a plain string
-- ("force"/"yes") while a flag property reads back as "yes"/"no"
local DEFAULTS = {}
local DEFAULTS_STR = {}
for _, item in ipairs(ITEMS) do
	DEFAULTS[item.prop] = mp.get_property_native(item.prop)
	DEFAULTS_STR[item.prop] = mp.get_property(item.prop)
end

-- mpv answers in its own vocabulary: a flag reads back "yes"/"no", loop-file
-- reads back "inf" when looping, matching osd-theme.lua's BOOLEAN_WORDS
local BOOLEAN_WORDS = { yes = "on", on = "on", inf = "on", no = "off", off = "off" }

local function format_value(v)
	return BOOLEAN_WORDS[v] or v
end

local function collect_af()
	local rows = {}
	for _, filter in ipairs(mp.get_property_native("af") or {}) do
		if filter.label then
			local label = filter.label
			rows[#rows + 1] = {
				label = label,
				value = filter.name or label,
				-- "af del <label>" doesn't accept a bare label; rewriting the
				-- property with that entry dropped is the reliable way to remove it
				reset = function()
					local kept = {}
					for _, f in ipairs(mp.get_property_native("af") or {}) do
						if f.label ~= label then
							kept[#kept + 1] = f
						end
					end
					mp.set_property_native("af", kept)
				end,
			}
		end
	end
	return rows
end

local function collect_shaders()
	local shaders = mp.get_property_native("glsl-shaders") or {}
	if #shaders == 0 then
		return {}
	end
	local names = {}
	for _, s in ipairs(shaders) do
		names[#names + 1] = s:match("([^/\\]+)$") or s
	end
	return {
		{
			label = "Shaders",
			value = table.concat(names, ", "),
			reset = function()
				mp.commandv("change-list", "glsl-shaders", "clr", "")
			end,
		},
	}
end

-- returns an ordered list of { group, label, value, reset } for everything off default
local function collect_active()
	local groups, order = {}, {}
	local function push(group, label, value, reset)
		if not groups[group] then
			groups[group] = {}
			order[#order + 1] = group
		end
		table.insert(groups[group], { label = label, value = value, reset = reset })
	end

	for _, item in ipairs(ITEMS) do
		local cur = mp.get_property(item.prop)
		if cur ~= DEFAULTS_STR[item.prop] then
			local default = DEFAULTS[item.prop]
			push(item.group, item.label, format_value(cur), function()
				mp.set_property_native(item.prop, default)
			end)
		end
	end
	for _, row in ipairs(collect_af()) do
		push("Audio", row.label, row.value, row.reset)
	end
	for _, row in ipairs(collect_shaders()) do
		push("Video", row.label, row.value, row.reset)
	end

	return groups, order
end

local function esc(s)
	s = s:gsub("\\", "\\\xE2\x81\xA0")
	s = s:gsub("{", "\\{"):gsub("}", "\\}")
	return s
end

local function ulen(s)
	local _, n = s:gsub("[^\128-\191]", "")
	return n
end

-- cut to a character width, marking the cut so a clipped value cannot be
-- read as the whole of it
local function utrunc(s, width)
	if width < 1 or ulen(s) <= width then
		return s
	end
	local out, taken = {}, 0
	for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		if taken >= width - 1 then
			break
		end
		out[#out + 1] = ch
		taken = taken + 1
	end
	return table.concat(out) .. "\xE2\x80\xA6"
end

local function round(v)
	return math.floor(v + 0.5)
end

-- Key hints: each key on a surface-3 keycap (4 px corners, a darker edge below), its action muted after it.
-- The OSD font is JetBrains Mono: libass sizes it by its 1320-unit line, so a 600-unit character is 0.455 of the font size wide.
local function key_hints(x, y, fs, s, hints)
	local out, cx = {}, x
	local cw, padx, kh = fs * 0.455, round(6 * s), round(fs * 1.5)
	for _, hint in ipairs(hints) do
		for key in hint[1]:gmatch("%S+") do
			local w = round(ulen(key) * cw + 2 * padx)
			-- the darker edge is its own shape, not a shadow: osd-border-style=background-box turns a shadow into a square box
			for _, part in ipairs({ { math.max(1, round(2 * s)), C.edge }, { 0, C.key } }) do
				out[#out + 1] = string.format("{\\an4\\pos(%d,%d)\\bord0\\shad0\\4a&HFF&\\1c&H%s&\\p1}%s{\\p0}",
					round(cx), round(y) + part[1], part[2], rrect_draw(w, kh, round(4 * s)))
			end
			out[#out + 1] = string.format("{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0\\4a&HFF&\\1c&H%s&}%s", round(cx + padx), round(y), fs, C.text, key)
			cx = cx + w + round(4 * s)
		end
		out[#out + 1] = string.format("{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0\\4a&HFF&\\1c&H%s&}%s", round(cx + 2 * s), round(y), fs, C.dim, hint[2])
		cx = cx + ulen(hint[2]) * cw + round(24 * s)
	end
	return table.concat(out, "\n"), cx - x
end

local overlay = nil
local active = false
local refresh_timer = nil
local hit_rows = {} -- { y0, y1, reset } in OSD pixel space, spanning the panel's width
local mouse_x, mouse_y = nil, nil
local panel_x0, panel_x1 = nil, nil
local PANEL_X = 26

local function row_at(x, y)
	if not panel_x0 or x < panel_x0 or x > panel_x1 then
		return nil
	end
	for _, r in ipairs(hit_rows) do
		if y >= r.y0 and y <= r.y1 then
			return r
		end
	end
	return nil
end

local function render()
	if not active or not overlay then
		return
	end
	local dim = mp.get_property_native("osd-dimensions")
	if not dim or not dim.w or dim.w == 0 then
		return
	end
	overlay.res_x, overlay.res_y = dim.w, dim.h

	-- Moonlight sizes are px at 1080 lines, scaled to the monitor rather than the window, so text in a window stays as readable as in fullscreen.
	local s = (mp.get_property_number("display-height") or dim.h) / 1080
	local fs = math.max(11, round(15 * s))
	local group_fs = math.max(9, round(12 * s))
	local row_h = round(28 * s)
	local pad = round(16 * s)
	-- Starts below uosc's top bar (32 px, top_bar_size in uosc.conf), its chapter line (24 px) and a 16 px gap, so neither draws over it.
	local top = round(72 * s) + pad
	-- widest a row can get before it would run off the video, so a long value
	-- (a shader chain, an audio filter graph) clips with an ellipsis instead of
	-- wrapping into the next row's y
	local avail_chars = math.max(12, math.floor((dim.w - PANEL_X - pad - 20) / (fs * 0.56)))

	local groups, order = collect_active()

	-- each entry gets its own explicit \pos rather than joining text with \N,
	-- so the y this script hands to the hit-test is exactly the y ASS renders
	-- at, instead of a guessed line-pitch drifting away from the real one
	local entries = { { y = top, fs = fs, bold = true, col = C.text, text = "Active state" } }
	local max_chars = ulen("Active state")
	hit_rows = {}
	local y = top + row_h

	if #order == 0 then
		local text = "Everything is at default."
		entries[#entries + 1] = { y = y, fs = fs, col = C.dim, text = text }
		max_chars = math.max(max_chars, ulen(text))
		y = y + row_h
	else
		for _, group in ipairs(order) do
			local heading = group:upper()
			entries[#entries + 1] = { y = y, fs = group_fs, col = C.dim, text = heading, rule = true }
			max_chars = math.max(max_chars, ulen(heading))
			y = y + group_fs * 1.25
			for _, row in ipairs(groups[group]) do
				local row_y = y
				local hovered = mouse_x
					and mouse_x >= PANEL_X
					and mouse_y
					and mouse_y >= row_y
					and mouse_y <= row_y + row_h
				local suffix = hovered and "  (click to reset)" or ""
				local value_budget = math.max(8, avail_chars - ulen(row.label) - 2 - ulen(suffix))
				local value = utrunc(row.value, value_budget)
				local plain = row.label .. ": " .. value .. suffix
				entries[#entries + 1] = {
					-- Text sits centred in its row; the hit-test keeps the row's own y.
					y = row_y + (row_h - fs * 1.2) / 2,
					fs = fs,
					col = C.text,
					text = esc(row.label) .. ": ",
					rest = string.format(
						"{\\1c&H%s&}%s%s",
						C.value,
						esc(value),
						hovered and string.format("  {\\1c&H%s&}(click to reset)", C.dim) or ""
					),
				}
				max_chars = math.max(max_chars, ulen(plain))
				hit_rows[#hit_rows + 1] = { y0 = row_y, y1 = row_y + row_h, reset = row.reset }
				y = y + row_h
			end
		end
	end
	local hint_fs = math.max(9, round(13 * s))
	local hints, hints_w = key_hints(PANEL_X, y + row_h / 2, hint_fs, s, { { "Click", "reset a row" }, { "Esc F3", "close" } })
	y = y + row_h

	max_chars = math.min(max_chars, avail_chars)
	local panel_w = math.max(max_chars * fs * 0.56, hints_w) + pad * 2
	local panel_h = (y - top) + pad * 2
	panel_x0, panel_x1 = PANEL_X - pad, PANEL_X - pad + panel_w

	local a = {}
	a[#a + 1] = string.format(
		"{\\an7\\pos(%d,%d)\\bord1\\shad0\\4a&HFF&\\3c&H%s&\\1c&H%s&\\1a&H18&\\p1}%s{\\p0}",
		round(PANEL_X - pad),
		round(top - pad),
		C.border,
		C.panel,
		rrect_draw(round(panel_w), round(panel_h), round(16 * s))
	)
	-- hovered row's own background, an 8 px chip set 8 px inside the panel, drawn under the text
	for _, r in ipairs(hit_rows) do
		if mouse_x and mouse_x >= panel_x0 and mouse_x <= panel_x1 and mouse_y and mouse_y >= r.y0 and mouse_y <= r.y1 then
			a[#a + 1] = string.format(
				"{\\an7\\pos(%d,%d)\\bord0\\shad0\\4a&HFF&\\1c&H%s&\\1a&H20&\\p1}%s{\\p0}",
				round(panel_x0 + 8 * s),
				round(r.y0),
				C.hover_bg,
				rrect_draw(round(panel_x1 - panel_x0 - 16 * s), round(r.y1 - r.y0), round(8 * s))
			)
		end
	end
	for _, e in ipairs(entries) do
		if e.rule then
			-- section header: the caps label on a hairline that runs to the panel's right padding
			local rx = PANEL_X + round(ulen(e.text) * e.fs * 0.56 + 8 * s)
			a[#a + 1] = string.format(
				"{\\an7\\pos(%d,%d)\\bord0\\shad0\\4a&HFF&\\1c&H%s&\\p1}%s{\\p0}",
				rx,
				round(e.y + e.fs * 0.6),
				C.border,
				rrect_draw(math.max(0, round(panel_x1 - pad - rx)), math.max(1, round(s)), 0)
			)
		end
		a[#a + 1] = string.format(
			"{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\4a&HFF&\\q2%s\\1c&H%s&}%s%s",
			PANEL_X,
			round(e.y),
			e.fs,
			e.bold and "\\b1" or "",
			e.col,
			e.text,
			e.rest or ""
		)
	end
	a[#a + 1] = hints

	-- cursor dot (sits exactly under the real pointer when spaces are aligned)
	if mouse_x then
		local r = math.max(3, round(row_h * 0.12))
		a[#a + 1] = string.format(
			"{\\an7\\pos(%d,%d)\\bord1\\3c&H170E0D&\\shad0\\4a&HFF&\\1c&H%s&\\1a&H20&\\p1}%s{\\p0}",
			round(mouse_x - r),
			round(mouse_y - r),
			C.accent,
			rrect_draw(r * 2, r * 2, r)
		)
	end

	overlay.data = table.concat(a, "\n")
	overlay:update()
end

local function on_mouse_move()
	if not active then
		return
	end
	local pos = mp.get_property_native("mouse-pos")
	mouse_x, mouse_y = pos and pos.x or nil, pos and pos.y or nil
	render()
end

local function on_click()
	if not active then
		return
	end
	local pos = mp.get_property_native("mouse-pos")
	if not pos then
		return
	end
	local row = row_at(pos.x, pos.y)
	if row and row.reset then
		row.reset()
		render()
	end
end

local function close()
	if not active then
		return
	end
	active = false
	mouse_x, mouse_y = nil, nil
	if refresh_timer then
		refresh_timer:kill()
		refresh_timer = nil
	end
	mp.unobserve_property(on_mouse_move)
	mp.remove_key_binding("active-state-esc")
	mp.remove_key_binding("active-state-click")
	if overlay then
		overlay:remove()
	end
end

local function open()
	if active then
		return
	end
	if not overlay then
		overlay = mp.create_osd_overlay("ass-events")
	end
	active = true
	mp.add_forced_key_binding("ESC", "active-state-esc", close)
	mp.add_forced_key_binding("MBTN_LEFT", "active-state-click", on_click)
	mp.observe_property("mouse-pos", "native", on_mouse_move)
	refresh_timer = mp.add_periodic_timer(0.3, render)
	render()
end

local function toggle()
	if active then
		close()
	else
		open()
	end
end

mp.add_key_binding(nil, "active-state", toggle)
mp.register_event("shutdown", function()
	if overlay then
		overlay:remove()
	end
end)
