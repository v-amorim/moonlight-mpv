-- keybind-visualizer.lua
-- Source: https://github.com/v-amorim/moonlight-mpv
--
-- An interactive on-screen keyboard for mpv. Toggle it, then move the mouse
-- over any key to see its bindings.
--
-- Bindings are read live from mpv's "input-bindings" property, so it reflects
-- whatever the user has in input.conf (plus builtin defaults).
--
-- The drawn physical layouts live in an external JSON data file (mpv cannot
-- auto-detect the OS keyboard layout). Pick one, or add your own, via:
--   script-opts/keybind-visualizer.conf
--     layout=abnt2                                  (key in the JSON "layouts")
--     layouts_file=keybind-visualizer-layouts.json  (searched in mpv config dir)
--
-- Activate with:  script-binding keybind-visualizer
-- Close with ESC (or toggle again).

local mp = require("mp")
local utils = require("mp.utils")

local options = { layout = "abnt2", layouts_file = "script-opts/keybind-visualizer-layouts.json" }
require("mp.options").read_options(options, "keybind-visualizer")

----------------------------------------------------------------------
-- Load layout data from JSON. Each key entry: { id, label, mpv?, x, y, w?, h? }
-- (units; rendering scales to screen). A layout has `center` + `bottom`; the
-- shared `frow`/`nav`/`numpad` clusters are reused by every layout.
----------------------------------------------------------------------
local load_error = nil

local function load_layout_data()
	-- try the configured path, then its basename at the config root, so the
	-- JSON can live in a subfolder (script-opts/) or the config root.
	local path = mp.find_config_file(options.layouts_file)
	if not path then
		local base = options.layouts_file:match("([^/\\]+)$")
		if base then
			path = mp.find_config_file(base)
		end
	end
	if not path then
		return nil, "layouts file not found: " .. options.layouts_file
	end
	local f = io.open(path, "r")
	if not f then
		return nil, "cannot open " .. path
	end
	local content = f:read("*all")
	f:close()
	local data, err = utils.parse_json(content or "")
	if not data then
		return nil, "JSON parse error in " .. path .. ": " .. tostring(err)
	end
	if type(data.shared) ~= "table" or type(data.layouts) ~= "table" then
		return nil, "layouts file missing 'shared'/'layouts' keys"
	end
	return data
end

-- flow one row left-to-right: x is summed from widths (default 1); {gap=n}
-- advances x without emitting a key; y comes from the row.
local function flow_row(row, out)
	local x = row.x or 0
	local y = row.y or 0
	for _, cell in ipairs(row.keys or {}) do
		if cell.gap then
			x = x + cell.gap
		else
			out[#out + 1] = {
				id = cell.id,
				label = cell.label,
				mpv = cell.mpv,
				w = cell.w,
				h = cell.h,
				x = x,
				y = y,
			}
			x = x + (cell.w or 1)
		end
	end
end

local function assemble(data, name)
	local L = data.layouts[name] or data.layouts.abnt2
	if not L then
		return {}
	end
	local keys = {}
	for _, row in ipairs((data.shared and data.shared.rows) or {}) do
		flow_row(row, keys)
	end
	for _, row in ipairs(L.rows or {}) do
		flow_row(row, keys)
	end
	return keys
end

local KEYS = {}
local GRID_W, GRID_H = 1, 1
local ID2KEY = {}
local MPV2ID = {}
local layout_data = nil
local layout_names = {}
local layout_name = (options.layout or "abnt2"):lower()

-- Mouse cluster, drawn beside the keyboard. Coordinates are relative to the
-- mouse origin (placed just right of the keyboard); units match the keys.
local MOUSE_BODY_REL = { x = 0, y = 0.4, w = 4.3, h = 5.8 }
local MOUSE_REL = {
	{ id = "MBTN_LEFT", label = "L", mpv = "MBTN_LEFT", x = 0.2, y = 0.65, w = 1.7, h = 2.0 },
	{ id = "WHEEL_UP", label = "▲", mpv = "WHEEL_UP", x = 1.95, y = 0.65, w = 0.5, h = 0.75 },
	{ id = "MBTN_MID", label = "M", mpv = "MBTN_MID", x = 1.95, y = 1.43, w = 0.5, h = 0.45 },
	{ id = "WHEEL_DOWN", label = "▼", mpv = "WHEEL_DOWN", x = 1.95, y = 1.9, w = 0.5, h = 0.75 },
	{ id = "MBTN_RIGHT", label = "R", mpv = "MBTN_RIGHT", x = 2.5, y = 0.65, w = 1.7, h = 2.0 },
	{ id = "MBTN_FORWARD", label = "X2", mpv = "MBTN_FORWARD", x = -0.5, y = 1.2, w = 0.55, h = 0.7 },
	{ id = "MBTN_BACK", label = "X1", mpv = "MBTN_BACK", x = -0.5, y = 2.0, w = 0.55, h = 0.7 },
}
local MOUSE_NAMES = {
	MBTN_LEFT = "Left Click",
	MBTN_RIGHT = "Right Click",
	MBTN_MID = "Middle / Wheel Click",
	WHEEL_UP = "Wheel Up",
	WHEEL_DOWN = "Wheel Down",
	MBTN_BACK = "Back",
	MBTN_FORWARD = "Forward",
}
local mouse_body = nil -- { x, y, w, h } in grid units, set by rebuild_keys

-- (re)build KEYS, grid extent and id index for the current layout_name
local function rebuild_keys()
	KEYS = assemble(layout_data, layout_name)
	-- place the mouse cluster just to the right of the widest keyboard column
	local kbw = 0
	for _, k in ipairs(KEYS) do
		local ex = k.x + (k.w or 1)
		if ex > kbw then
			kbw = ex
		end
	end
	local mx0 = kbw + 0.7
	for _, m in ipairs(MOUSE_REL) do
		KEYS[#KEYS + 1] =
			{ id = m.id, label = m.label, mpv = m.mpv, x = mx0 + m.x, y = m.y, w = m.w, h = m.h, mouse = true }
	end
	mouse_body = { x = mx0 + MOUSE_BODY_REL.x, y = MOUSE_BODY_REL.y, w = MOUSE_BODY_REL.w, h = MOUSE_BODY_REL.h }

	GRID_W, GRID_H = 1, 1
	for _, k in ipairs(KEYS) do
		local ex = k.x + (k.w or 1)
		local ey = k.y + (k.h or 1)
		if ex > GRID_W then
			GRID_W = ex
		end
		if ey > GRID_H then
			GRID_H = ey
		end
	end
	local mex, mey = mouse_body.x + mouse_body.w, mouse_body.y + mouse_body.h
	if mex > GRID_W then
		GRID_W = mex
	end
	if mey > GRID_H then
		GRID_H = mey
	end

	ID2KEY = {}
	MPV2ID = {}
	for _, k in ipairs(KEYS) do
		ID2KEY[k.id] = k
		if k.mpv then
			k.mpv_lc = k.mpv:lower()
			MPV2ID[k.mpv_lc] = k.id
		end
	end
end

do
	local data, err = load_layout_data()
	if not data then
		load_error = err
		mp.msg.error(err)
	else
		layout_data = data
		for name in pairs(data.layouts) do
			layout_names[#layout_names + 1] = name
		end
		table.sort(layout_names)
		if not data.layouts[layout_name] then
			mp.msg.warn("unknown layout '" .. tostring(options.layout) .. "', falling back")
			layout_name = data.layouts.abnt2 and "abnt2" or layout_names[1] or "abnt2"
		end
		rebuild_keys()
	end
end

----------------------------------------------------------------------
-- Colors: Moonlight theme, written as normal #RRGGBB hex.
----------------------------------------------------------------------
-- ASS wants colors in &HBBGGRR& byte order, so to_ass() reverses the byte
-- pairs once at load time; the rest of the script reads ready-to-use values.
local function to_ass(rgb)
	return rgb:sub(5, 6) .. rgb:sub(3, 4) .. rgb:sub(1, 2)
end

local C = {}
for name, rgb in pairs({
	dim = "0D0E17", -- #0D0E17  full-screen dim behind the keyboard
	key_bg = "141726", -- #141726  unbound key fill
	key_brd = "1C2033", -- #1C2033  unbound key border
	bind_bg = "1C2033", -- #1C2033  bound key fill
	bind_brd = "252A42", -- #252A42  bound key border
	hover_bg = "252A42", -- #252A42  hovered key fill
	hover_brd = "7386D0", -- #7386D0  hovered key border
	match_bg = "2F3654", -- #2F3654  search-matched key fill
	match_brd = "B9C6F5", -- #B9C6F5  search-matched key border + query text
	match_hl = "A2B0EA", -- #A2B0EA  the typed characters inside a description
	text = "EEEEFA", -- #EEEEFA  key labels + info panel text
	text_dim = "9BA3C4", -- #9BA3C4  unbound key labels + "No bindings" text
	panel_bg = "141726", -- #141726  info panel background
	panel_brd = "252A42", -- #252A42  info panel border
	accent = "7386D0", -- #7386D0  binding combos + layout button + cursor dot
	header = "EEEEFA", -- #EEEEFA  info panel title (key name)
	sep = "6e7681", -- #6e7681  separator line between bindings
}) do
	C[name] = to_ass(rgb)
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local overlay = nil
local active = false
local geom = nil
local hovered = nil
local saved_autohide = nil
local mouse_x, mouse_y = nil, nil
local button_rect = nil -- clickable layout-switch button { x, y, w, h }
local BK = {} -- lowercased base key -> sorted list of binding entries
local query = ""
local query_tokens = {} -- lowercased whitespace-separated pieces of the query
local match_ids = {} -- key id -> true, for the keys lit by the current query
local match_list = {} -- { key_id, binding, score }, best score first

----------------------------------------------------------------------
-- Read bindings from the input-bindings property
----------------------------------------------------------------------
local MODS = { ctrl = true, shift = true, alt = true, meta = true }

-- split "Ctrl+Shift+x" into modifier flags + base key (case-insensitive mods)
local function parse_combo(key)
	local ctrl, shift, alt, meta = false, false, false, false
	local rest = key or ""
	while true do
		local tok, after = rest:match("^(%a+)%+(.+)$")
		if tok and MODS[tok:lower()] then
			local t = tok:lower()
			if t == "ctrl" then
				ctrl = true
			elseif t == "shift" then
				shift = true
			elseif t == "alt" then
				alt = true
			elseif t == "meta" then
				meta = true
			end
			rest = after
		else
			break
		end
	end
	if rest:match("^[A-Z]$") then
		shift = true
		rest = rest:lower()
	end
	return ctrl, shift, alt, meta, rest
end

local function mods_key(c, s, a, m)
	return (c and "c" or "") .. (s and "s" or "") .. (a and "a" or "") .. (m and "m" or "")
end
local function mods_label(c, s, a, m)
	return (c and "Ctrl+" or "") .. (s and "Shift+" or "") .. (a and "Alt+" or "") .. (m and "Win+" or "")
end

local function build_bindings()
	BK = {}
	local list = mp.get_property_native("input-bindings") or {}
	-- keep the highest-priority binding for each (base, modifiers) combo
	local best = {}
	for _, e in ipairs(list) do
		local section = e.section or "default"
		if section == "default" then
			local cmd = (e.cmd or ""):gsub("^%s+", ""):gsub("%s+$", "")
			if cmd ~= "" and cmd:lower() ~= "ignore" then
				local c, s, a, m, base = parse_combo(e.key or "")
				if base ~= "" then
					local bk = base:lower()
					local mk = mods_key(c, s, a, m)
					local uid = bk .. "|" .. mk
					local pr = e.priority or 0
					local prev = best[uid]
					if (not prev) or pr >= prev.priority then
						best[uid] = {
							priority = pr,
							base = bk,
							c = c,
							s = s,
							a = a,
							m = m,
							label = mods_label(c, s, a, m),
							cmd = cmd,
							comment = e.comment,
							menu = (e.comment or ""):match("^%s*#?!") ~= nil,
						}
					end
				end
			end
		end
	end
	for _, b in pairs(best) do
		BK[b.base] = BK[b.base] or {}
		table.insert(BK[b.base], b)
	end
	for _, lst in pairs(BK) do
		table.sort(lst, function(x, y)
			local nx = (x.c and 1 or 0) + (x.s and 1 or 0) + (x.a and 1 or 0) + (x.m and 1 or 0)
			local ny = (y.c and 1 or 0) + (y.s and 1 or 0) + (y.a and 1 or 0) + (y.m and 1 or 0)
			if nx ~= ny then
				return nx < ny
			end
			return x.label < y.label
		end)
	end
end

local function bindings_for(id)
	local k = ID2KEY[id]
	if not k or not k.mpv_lc then
		return nil
	end
	return BK[k.mpv_lc]
end

local function has_bindings(id)
	local lst = bindings_for(id)
	return lst ~= nil and #lst > 0
end

local MENU_ICON = "\xE2\x89\xA1" -- ≡, marks a binding that also sits in the uosc menu

local function has_menu(id)
	for _, b in ipairs(bindings_for(id) or {}) do
		if b.menu then
			return true
		end
	end
	return false
end

local function binding_desc(b)
	local t = b.comment or ""
	-- a "#!" comment is a uosc menu path: it says where the entry lives, not what
	-- it does, so the command leads and the path trails it
	local menu = t:match("^%s*#?!%s*(.+)$")
	if menu then
		-- a menu line describes itself after "?"; the rest is a path plus the
		-- "@icon" tokens that belong to uosc-menu.lua, neither of which says what
		-- the binding does. Parents carry descriptions of their own, so the entry's
		-- is the one after the last "?", not the first.
		local described = menu:match(".*%?%s*(.+)$")
		t = described or (b.cmd .. "  \xC2\xB7  " .. menu:gsub("%s+@[%w_]+", ""))
	else
		t = t:gsub("^#%s*", "")
	end
	-- the command has a column of its own now, so an undescribed binding stays
	-- blank rather than repeating it
	return (t:gsub("%s+", " "))
end

-- prefixes that say how a command reports itself, not what it does
local CMD_PREFIXES = {
	["no-osd"] = true,
	["osd-auto"] = true,
	["osd-bar"] = true,
	["osd-msg"] = true,
	["osd-msg-bar"] = true,
	["expand-properties"] = true,
	["raw"] = true,
	["async"] = true,
	["sync"] = true,
	["repeatable"] = true,
	["nonrepeatable"] = true,
}

-- split on ";" while leaving the separators inside quoted arguments alone, which
-- a shader list ("a.glsl;b.glsl") depends on
local function split_commands(cmd)
	local parts, buf, quote = {}, {}, nil
	for i = 1, #cmd do
		local c = cmd:sub(i, i)
		if quote then
			if c == quote then
				quote = nil
			end
			buf[#buf + 1] = c
		elseif c == '"' or c == "'" then
			quote = c
			buf[#buf + 1] = c
		elseif c == ";" then
			parts[#parts + 1] = table.concat(buf)
			buf = {}
		else
			buf[#buf + 1] = c
		end
	end
	parts[#parts + 1] = table.concat(buf)
	return parts
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- what the binding actually does: prefixes and the osd-theme message are dropped,
-- and the remaining commands collapse to the first one plus a count
local function binding_cmd(cmd)
	local kept = {}
	for _, part in ipairs(split_commands(cmd or "")) do
		part = trim(part)
		local head, rest = part:match("^(%S+)%s+(.+)$")
		while head and CMD_PREFIXES[head] do
			part = rest
			head, rest = part:match("^(%S+)%s+(.+)$")
		end
		if part ~= "" and not part:match("^script%-message%-to%s+osd_theme") then
			kept[#kept + 1] = (part:gsub("%s+", " "))
		end
	end
	if #kept == 0 then
		return trim((cmd or ""):gsub("%s+", " "))
	end
	if #kept == 1 then
		return kept[1]
	end
	return string.format("%s (+%d)", kept[1], #kept - 1)
end

-- combo labels carry multi-byte glyphs (arrows), so padding needs characters, not bytes
local function ulen(s)
	local _, n = s:gsub("[^\128-\191]", "")
	return n
end

-- cut to a character width, marking the cut so a clipped command cannot be read
-- as the whole of it
local function utrunc(s, width)
	if ulen(s) <= width then
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

-- word-wrap a string to a max width (in characters), hard-breaking words that
-- are longer than the width; returns a list of lines.
local function wrap_text(s, width)
	if width < 4 then
		width = 4
	end
	local words = {}
	for w in s:gmatch("%S+") do
		while #w > width do
			words[#words + 1] = w:sub(1, width)
			w = w:sub(width + 1)
		end
		words[#words + 1] = w
	end
	local lines, line = {}, ""
	for _, w in ipairs(words) do
		if line == "" then
			line = w
		elseif #line + 1 + #w <= width then
			line = line .. " " .. w
		else
			lines[#lines + 1] = line
			line = w
		end
	end
	if line ~= "" then
		lines[#lines + 1] = line
	end
	if #lines == 0 then
		lines[1] = ""
	end
	return lines
end

-- human readable key name for the info panel header / combos
local function key_name(id, label)
	if MOUSE_NAMES[id] then
		return MOUSE_NAMES[id]
	end
	local s = id:match("^Key(.+)$")
	if s then
		return s
	end
	s = id:match("^Digit(.+)$")
	if s then
		return s
	end
	s = id:match("^Numpad(.+)$")
	if s then
		return "KP " .. s
	end
	return label
end

----------------------------------------------------------------------
-- Search
----------------------------------------------------------------------
local function split_words(low)
	local words, i = {}, 1
	while true do
		local s, e = low:find("%w+", i)
		if not s then
			return words
		end
		words[#words + 1] = { s = s, e = e }
		i = e + 1
	end
end

-- token as a gapped run inside one word: "dlay" finds "delay", but the run may
-- not wander past the word's end, so "sbdly" never reaches "sub-delay"
local function subseq_in_word(low, ws, we, tok)
	local pos, positions, gaps = ws, {}, 0
	for i = 1, #tok do
		local at = low:find(tok:sub(i, i), pos, true)
		if not at or at > we then
			return nil
		end
		if i > 1 and at > pos then
			gaps = gaps + 1
		end
		positions[#positions + 1] = at
		pos = at + 1
	end
	local score = 100 - gaps * 20
	if score < 1 then
		return nil
	end
	return score, positions
end

-- match one token against a text and report where it landed: a literal
-- substring first, then a gapped run inside a single word, then the initials of
-- consecutive words. A run allowed to wander across the whole text would match
-- nearly every binding, so it is deliberately not offered.
-- Tokens are ASCII, so a reported byte can never sit inside a UTF-8 sequence.
local function token_hits(text, tok)
	local low = text:lower()
	local positions, score, from = {}, nil, 1
	while true do
		local at = low:find(tok, from, true)
		if not at then
			break
		end
		for i = at, at + #tok - 1 do
			positions[#positions + 1] = i
		end
		local edge = (at == 1 or not low:sub(at - 1, at - 1):match("%w")) and 30 or 0
		score = math.max(score or 0, 200 - math.min(at, 60) + edge)
		from = at + 1
	end
	if score then
		return score, positions
	end

	local words = split_words(low)
	local best, best_pos
	for _, w in ipairs(words) do
		local s, p = subseq_in_word(low, w.s, w.e, tok)
		if s and (not best or s > best) then
			best, best_pos = s, p
		end
	end
	if best then
		return best, best_pos
	end

	local initials, starts = {}, {}
	for _, w in ipairs(words) do
		initials[#initials + 1] = low:sub(w.s, w.s)
		starts[#initials] = w.s
	end
	local at = table.concat(initials):find(tok, 1, true)
	if at then
		local pos = {}
		for i = at, at + #tok - 1 do
			pos[#pos + 1] = starts[i]
		end
		return 80, pos
	end
	return nil
end

local function match_score(hay, tokens)
	local total = 0
	for _, tok in ipairs(tokens) do
		local s = token_hits(hay, tok)
		if not s then
			return nil
		end
		total = total + s
	end
	return total
end

local function compute_matches()
	match_ids, match_list, query_tokens = {}, {}, {}
	if query == "" then
		return
	end
	local tokens = {}
	for tok in query:lower():gmatch("%S+") do
		tokens[#tokens + 1] = tok
	end
	if #tokens == 0 then
		return
	end
	query_tokens = tokens
	for base, lst in pairs(BK) do
		local id = MPV2ID[base]
		local name = id and key_name(id, ID2KEY[id].label) or base:upper()
		for _, b in ipairs(lst) do
			local hay = (b.label .. name .. " " .. binding_desc(b) .. " " .. b.cmd):lower()
			local score = match_score(hay, tokens)
			if score then
				match_list[#match_list + 1] = { id = id, name = name, b = b, score = score }
				if id then
					match_ids[id] = true
				end
			end
		end
	end
	table.sort(match_list, function(x, y)
		if x.score ~= y.score then
			return x.score > y.score
		end
		return (x.b.label .. x.name) < (y.b.label .. y.name)
	end)
end

----------------------------------------------------------------------
-- ASS helpers
----------------------------------------------------------------------
local function round(v)
	return math.floor(v + 0.5)
end

local function rect_draw(w, h)
	return string.format("m 0 0 l %d 0 l %d %d l 0 %d", w, w, h, h)
end

-- rounded rectangle path (corners approximated with bezier control at corner)
local function rrect_draw(w, h, r)
	if r * 2 > w then
		r = w / 2
	end
	if r * 2 > h then
		r = h / 2
	end
	local wr, hr = w - r, h - r
	return string.format(
		"m %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d l %d %d b %d %d %d %d %d %d",
		r,
		0,
		wr,
		0,
		w,
		0,
		w,
		0,
		w,
		r,
		w,
		hr,
		w,
		h,
		w,
		h,
		wr,
		h,
		r,
		h,
		0,
		h,
		0,
		h,
		0,
		hr,
		0,
		r,
		0,
		0,
		0,
		0,
		r,
		0
	)
end

local function esc(s)
	s = s:gsub("\\", "\\\xE2\x81\xA0")
	s = s:gsub("{", "\\{"):gsub("}", "\\}")
	return s
end

-- colored ASS text: the query's own characters stand out from the rest
local function highlight(text, base_col)
	local base = string.format("{\\1c&H%s&\\b0}", base_col)
	if #query_tokens == 0 then
		return base .. esc(text)
	end
	local mask = {}
	for _, tok in ipairs(query_tokens) do
		local _, positions = token_hits(text, tok)
		for _, at in ipairs(positions or {}) do
			mask[at] = true
		end
	end
	local hl = string.format("{\\1c&H%s&\\b1}", C.match_hl)
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

----------------------------------------------------------------------
-- Geometry
----------------------------------------------------------------------
local function compute_geom()
	-- osd-dimensions is the coordinate space ASS overlays render in and that
	-- mouse-pos is reported in, so layout + hit-testing stay aligned in
	-- fullscreen / HiDPI (get_osd_size can differ).
	local dim = mp.get_property_native("osd-dimensions")
	if not dim or not dim.w or dim.w == 0 then
		return nil
	end
	local w, h = dim.w, dim.h
	-- the panel needs room for the busiest key (6 bindings plus separators), so it
	-- gets the larger share of the vertical stack and the keyboard shrinks to suit
	local panel_units = 6
	local header_units = 0.9
	local stack = header_units + 0.3 + GRID_H + 0.6 + panel_units
	local ku = math.min((w * 0.96) / GRID_W, (h * 0.94) / stack)
	local kbd_w = GRID_W * ku
	local kbd_h = GRID_H * ku
	local header_h = header_units * ku
	local ox = (w - kbd_w) / 2
	-- top-anchor the keyboard so the info panel can grow downward to fit every
	-- binding (no "+N more"); keep a small centering bias when there is slack.
	local nominal = header_h + ku * 0.3 + kbd_h + ku * 0.6 + panel_units * ku
	local top = math.max(ku * 0.4, math.min((h - nominal) / 2, ku * 1.2))
	local oy = top + header_h + ku * 0.3
	local panel_y = oy + kbd_h + ku * 0.6
	return {
		sw = w,
		sh = h,
		ku = ku,
		ox = ox,
		oy = oy,
		gap = math.max(2, ku * 0.07),
		kbd_h = kbd_h,
		panel_y = panel_y,
		panel_max_h = math.max(ku * 1.5, h - panel_y - ku * 0.4),
		header_y = top,
		header_h = header_h,
	}
end

local function key_rect(k)
	local g = geom
	local px = g.ox + k.x * g.ku
	local py = g.oy + k.y * g.ku
	local pw = (k.w or 1) * g.ku - g.gap
	local ph = (k.h or 1) * g.ku - g.gap
	return px, py, pw, ph
end

local function key_at(mx, my)
	if not geom then
		return nil
	end
	for _, k in ipairs(KEYS) do
		local px, py, pw, ph = key_rect(k)
		if mx >= px and mx <= px + pw and my >= py and my <= py + ph then
			return k.id
		end
	end
	return nil
end

----------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------
local function build_info_lines(id)
	local g = geom
	local k = ID2KEY[id]
	local name = key_name(id, k and k.label or id)

	-- base font for the panel; every line sets \fs explicitly so the smaller
	-- separator font does not leak into the lines that follow it (\N keeps
	-- inline overrides within one ASS event).
	local info_fs = math.max(1, round(g.ku * 0.3))
	local sep_fs = math.max(1, round(info_fs * 0.55))
	local line_h = info_fs * 1.2 -- rendered height of a normal line
	local sep_h = sep_fs * 1.2 -- rendered height of a separator line

	-- returns lines plus the precise total height (separators are shorter, so
	-- a uniform per-line height would make the panel box too tall)
	local lines = {}
	local total_h = 0
	lines[#lines + 1] = string.format("{\\fs%d\\b1\\1c&H%s&}%s{\\b0\\1c&H%s&}", info_fs, C.header, esc(name), C.text)
	total_h = total_h + line_h
	local lst = bindings_for(id)
	if not lst or #lst == 0 then
		lines[#lines + 1] = string.format("{\\fs%d\\1c&H%s&}No bindings", info_fs, C.text_dim)
		return lines, total_h + line_h
	end

	-- how many physical lines fit in the panel, and chars per line by width
	local max_lines = math.max(3, math.floor((g.panel_max_h - g.ku * 0.5) / line_h))
	local inner_px = GRID_W * g.ku - g.ku * 0.9
	local max_chars = math.max(20, math.floor(inner_px / (info_fs * 0.6)))

	-- thin separator (smaller font) between bindings
	local sep =
		string.format("{\\fs%d\\1c&H%s&}%s", sep_fs, C.sep, string.rep("\xE2\x94\x80", math.floor(max_chars * 0.98)))

	-- combo, command and description each start at one column, so both leading
	-- columns pad out to their widest entry
	local div = "\xE2\x94\x82"
	local combo_w, cmd_w = 0, 0
	for _, b in ipairs(lst) do
		combo_w = math.max(combo_w, ulen(b.label .. name))
		cmd_w = math.max(cmd_w, ulen(binding_cmd(b.cmd)))
	end
	local fixed = combo_w + 8 -- pads, spaces, two dividers and the menu badge
	cmd_w = math.max(8, math.min(cmd_w, math.floor((max_chars - fixed) * 0.4)))
	local indent = fixed + cmd_w

	local budget = max_lines - 1 -- title already used one line
	local shown = 0
	for i, b in ipairs(lst) do
		local combo = b.label .. name
		local cmd = utrunc(binding_cmd(b.cmd), cmd_w)
		local wrapped = wrap_text(binding_desc(b), math.max(8, max_chars - indent))
		local need = #wrapped + ((i > 1) and 1 or 0) -- +1 for the separator row
		local reserve = (i == #lst) and 0 or 1
		if budget - need < reserve then
			lines[#lines + 1] = string.format("{\\fs%d\\1c&H%s&}... (+%d more)", info_fs, C.text_dim, #lst - shown)
			total_h = total_h + line_h
			break
		end
		if i > 1 then
			lines[#lines + 1] = sep
			total_h = total_h + sep_h
		end
		-- first physical line: accent combo, the command, then the menu badge
		-- column and the first chunk of the description
		lines[#lines + 1] = string.format(
			"{\\fs%d\\1c&H%s&}%s%s{\\1c&H%s&}\\h%s\\h%s%s{\\1c&H%s&}\\h%s\\h{\\1c&H%s&}%s\\h%s",
			info_fs,
			C.accent,
			esc(combo),
			string.rep("\\h", combo_w - ulen(combo)),
			C.sep,
			div,
			highlight(cmd, C.text_dim),
			string.rep("\\h", cmd_w - ulen(cmd)),
			C.sep,
			div,
			C.accent,
			b.menu and MENU_ICON or "\\h",
			highlight(wrapped[1], C.text)
		)
		-- continuation lines: hanging indent under the description
		for j = 2, #wrapped do
			lines[#lines + 1] = string.format(
				"{\\fs%d}%s%s",
				info_fs,
				string.rep("\\h", indent),
				highlight(wrapped[j], C.text)
			)
		end
		total_h = total_h + #wrapped * line_h
		budget = budget - need
		shown = shown + 1
	end
	return lines, total_h
end

local function build_search_lines()
	local g = geom
	local info_fs = math.max(1, round(g.ku * 0.3))
	local line_h = info_fs * 1.2

	local lines = {}
	lines[#lines + 1] = string.format(
		"{\\fs%d\\b1\\1c&H%s&}%d match%s{\\b0\\1c&H%s&}",
		info_fs,
		C.match_brd,
		#match_list,
		#match_list == 1 and "" or "es",
		C.text
	)
	local total_h = line_h
	if #match_list == 0 then
		lines[#lines + 1] = string.format("{\\fs%d\\1c&H%s&}Nothing matches that.", info_fs, C.text_dim)
		return lines, total_h + line_h
	end

	local max_lines = math.max(3, math.floor((g.panel_max_h - g.ku * 0.5) / line_h))
	local inner_px = GRID_W * g.ku - g.ku * 0.9
	local max_chars = math.max(20, math.floor(inner_px / (info_fs * 0.6)))

	local budget = max_lines - 1
	local shown = math.min(#match_list, budget)
	local combo_w, cmd_w = 0, 0
	for i = 1, shown do
		combo_w = math.max(combo_w, ulen(match_list[i].b.label .. match_list[i].name))
		cmd_w = math.max(cmd_w, ulen(binding_cmd(match_list[i].b.cmd)))
	end

	-- the command column takes what it needs, up to a third of the row, so the
	-- description keeps the rest
	local fixed = combo_w + 8
	cmd_w = math.max(8, math.min(cmd_w, math.floor((max_chars - fixed) * 0.4)))
	local desc_w = math.max(8, max_chars - fixed - cmd_w)
	local div = "\xE2\x94\x82"

	for i, hit in ipairs(match_list) do
		local combo = hit.b.label .. hit.name
		local cmd = utrunc(binding_cmd(hit.b.cmd), cmd_w)
		local desc = wrap_text(binding_desc(hit.b), desc_w)[1]
		if budget < ((i < #match_list) and 2 or 1) then
			lines[#lines + 1] =
				string.format("{\\fs%d\\1c&H%s&}... (+%d more)", info_fs, C.text_dim, #match_list - i + 1)
			total_h = total_h + line_h
			break
		end
		lines[#lines + 1] = string.format(
			"{\\fs%d\\1c&H%s&}%s%s{\\1c&H%s&}\\h%s\\h%s%s{\\1c&H%s&}\\h%s\\h{\\1c&H%s&}%s\\h%s",
			info_fs,
			C.accent,
			esc(combo),
			string.rep("\\h", combo_w - ulen(combo)),
			C.sep,
			div,
			highlight(cmd, C.text_dim),
			string.rep("\\h", cmd_w - ulen(cmd)),
			C.sep,
			div,
			C.accent,
			hit.b.menu and MENU_ICON or "\\h",
			highlight(desc, C.text)
		)
		total_h = total_h + line_h
		budget = budget - 1
	end
	return lines, total_h
end

local function render()
	if not active or not overlay then
		return
	end
	geom = compute_geom()
	if not geom then
		return
	end
	local g = geom

	overlay.res_x = g.sw
	overlay.res_y = g.sh

	-- error state: no usable layout data
	if load_error or #KEYS == 0 then
		local msg = load_error or "no keys in layout '" .. layout_name .. "'"
		overlay.data = string.format(
			"{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H70&\\p1}%s{\\p0}\\n"
				.. "{\\an5\\pos(%d,%d)\\fs%d\\bord2\\shad0\\3c&H000000&\\1c&H%s&}keybind-visualizer: %s",
			C.dim,
			rect_draw(round(g.sw), round(g.sh)),
			round(g.sw / 2),
			round(g.sh / 2),
			round(g.sh * 0.03),
			C.text,
			esc(msg)
		)
		overlay:update()
		return
	end

	local a = {}

	-- full screen dim
	a[#a + 1] = string.format(
		"{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H70&\\p1}%s{\\p0}",
		C.dim,
		rect_draw(round(g.sw), round(g.sh))
	)

	-- mouse body (drawn behind the mouse buttons, which live in KEYS)
	if mouse_body then
		local bx = g.ox + mouse_body.x * g.ku
		local by = g.oy + mouse_body.y * g.ku
		local bw = mouse_body.w * g.ku
		local bh = mouse_body.h * g.ku
		a[#a + 1] = string.format(
			"{\\an7\\pos(%d,%d)\\bord2\\shad0\\3c&H%s&\\1c&H%s&\\1a&H10&\\p1}%s{\\p0}",
			round(bx),
			round(by),
			C.key_brd,
			C.key_bg,
			rrect_draw(round(bw), round(bh), round(g.ku * 0.55))
		)
		a[#a + 1] = string.format(
			"{\\an5\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H%s&}MOUSE",
			round(bx + bw / 2),
			round(by + bh * 0.8),
			round(g.ku * 0.3),
			C.text_dim
		)
	end

	-- keys
	for _, k in ipairs(KEYS) do
		local px, py, pw, ph = key_rect(k)
		local bg, brd
		if k.id == hovered then
			bg, brd = C.hover_bg, C.hover_brd
		elseif match_ids[k.id] then
			bg, brd = C.match_bg, C.match_brd
		elseif has_bindings(k.id) then
			bg, brd = C.bind_bg, C.bind_brd
		else
			bg, brd = C.key_bg, C.key_brd
		end
		a[#a + 1] = string.format(
			"{\\an7\\pos(%d,%d)\\bord2\\shad0\\3c&H%s&\\1c&H%s&\\1a&H08&\\p1}%s{\\p0}",
			round(px),
			round(py),
			brd,
			bg,
			rect_draw(round(pw), round(ph))
		)
	end

	-- labels
	local fs = round(g.ku * 0.34)
	for _, k in ipairs(KEYS) do
		local px, py, pw, ph = key_rect(k)
		local col = has_bindings(k.id) and C.text or C.text_dim
		if k.id == hovered then
			col = C.text
		end
		a[#a + 1] = string.format(
			"{\\an5\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H%s&}%s",
			round(px + pw / 2),
			round(py + ph / 2),
			fs,
			col,
			esc(k.label)
		)
		if has_menu(k.id) then
			a[#a + 1] = string.format(
				"{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H%s&}%s",
				round(px + g.ku * 0.07),
				round(py + g.ku * 0.02),
				math.max(1, round(g.ku * 0.22)),
				C.accent,
				MENU_ICON
			)
		end
	end

	-- info panel: build the lines first, then size the background to fit them
	local info_fs = round(g.ku * 0.3)
	local panel_lines, content_h
	if hovered then
		panel_lines, content_h = build_info_lines(hovered)
	elseif query ~= "" then
		panel_lines, content_h = build_search_lines()
	else
		panel_lines = {
			string.format(
				"{\\fs%d\\1c&H%s&}Hover a key for its bindings, or type to search them.   {\\1c&H%s&}ESC{\\1c&H%s&} to close.",
				info_fs,
				C.text,
				C.accent,
				C.text
			),
		}
		content_h = info_fs * 1.2
	end
	local pad_top, pad_bot = g.ku * 0.25, g.ku * 0.25
	local panel_h = math.max(g.ku, math.min(g.panel_max_h, pad_top + content_h + pad_bot))

	a[#a + 1] = string.format(
		"{\\an7\\pos(%d,%d)\\bord2\\shad0\\3c&H%s&\\1c&H%s&\\1a&H10&\\p1}%s{\\p0}",
		round(g.ox),
		round(g.panel_y),
		C.panel_brd,
		C.panel_bg,
		rect_draw(round(GRID_W * g.ku), round(panel_h))
	)
	a[#a + 1] = string.format(
		"{\\an7\\pos(%d,%d)\\bord0\\shad0\\q2}%s",
		round(g.ox + g.ku * 0.4),
		round(g.panel_y + pad_top),
		table.concat(panel_lines, "\\N")
	)

	-- clickable layout-switch button (header band, above the keyboard)
	local lay_label = "LAYOUT: " .. layout_name:upper()
	if #layout_names > 1 then
		lay_label = lay_label .. "   (click to change)"
	end
	local bfs = round(g.header_h * 0.48)
	local bx, by, bh = g.ox, g.header_y, g.header_h
	local bw = math.max(g.ku * 4, #lay_label * bfs * 0.5 + g.ku * 0.6)
	button_rect = { x = bx, y = by, w = bw, h = bh }
	local over_btn = mouse_x ~= nil and mouse_x >= bx and mouse_x <= bx + bw and mouse_y >= by and mouse_y <= by + bh
	a[#a + 1] = string.format(
		"{\\an7\\pos(%d,%d)\\bord2\\shad0\\3c&H%s&\\1c&H%s&\\1a&H08&\\p1}%s{\\p0}",
		round(bx),
		round(by),
		over_btn and C.hover_brd or C.bind_brd,
		over_btn and C.hover_bg or C.bind_bg,
		rect_draw(round(bw), round(bh))
	)
	a[#a + 1] = string.format(
		"{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H%s&}%s",
		round(bx + g.ku * 0.3),
		round(by + bh / 2),
		bfs,
		over_btn and C.accent or C.text,
		esc(lay_label)
	)

	-- search box, filling the header band right of the layout button
	local sx = bx + bw + g.ku * 0.3
	local sw = g.ox + GRID_W * g.ku - sx
	if sw > g.ku * 2 then
		a[#a + 1] = string.format(
			"{\\an7\\pos(%d,%d)\\bord2\\shad0\\3c&H%s&\\1c&H%s&\\1a&H08&\\p1}%s{\\p0}",
			round(sx),
			round(by),
			query ~= "" and C.match_brd or C.bind_brd,
			query ~= "" and C.match_bg or C.bind_bg,
			rect_draw(round(sw), round(bh))
		)
		local stext
		if query == "" then
			stext = string.format("{\\1c&H%s&}Search: type to filter bindings", C.text_dim)
		else
			stext = string.format(
				"{\\1c&H%s&}Search: {\\1c&H%s&}%s_{\\1c&H%s&}   %d hit%s   BS erase, ESC clear",
				C.text,
				C.match_brd,
				esc(query),
				C.text_dim,
				#match_list,
				#match_list == 1 and "" or "s"
			)
		end
		a[#a + 1] = string.format(
			"{\\an4\\pos(%d,%d)\\fs%d\\bord0\\shad0\\q2}%s",
			round(sx + g.ku * 0.3),
			round(by + bh / 2),
			bfs,
			stext
		)
	end

	-- cursor dot (sits exactly under the real pointer when spaces are aligned)
	if mouse_x then
		local r = math.max(3, round(g.ku * 0.06))
		a[#a + 1] = string.format(
			"{\\an7\\pos(%d,%d)\\bord1\\3c&H000000&\\shad0\\1c&H%s&\\1a&H20&\\p1}%s{\\p0}",
			round(mouse_x - r),
			round(mouse_y - r),
			C.accent,
			rect_draw(r * 2, r * 2)
		)
	end

	overlay.data = table.concat(a, "\n")
	overlay:update()
end

----------------------------------------------------------------------
-- Mouse / events
----------------------------------------------------------------------
local function on_mouse(_, val)
	if not active then
		return
	end
	local mx, my
	if type(val) == "table" then
		mx, my = val.x, val.y
	else
		local pos = mp.get_property_native("mouse-pos")
		if pos then
			mx, my = pos.x, pos.y
		end
	end
	if not mx then
		return
	end
	mouse_x, mouse_y = mx, my
	hovered = key_at(mx, my)
	render()
end

local function on_resize()
	if active then
		render()
	end
end

-- advance to the next layout in the JSON (sorted) and redraw
local function cycle_layout()
	if load_error or #layout_names < 2 then
		return
	end
	local idx = 1
	for i, n in ipairs(layout_names) do
		if n == layout_name then
			idx = i
			break
		end
	end
	layout_name = layout_names[idx % #layout_names + 1]
	rebuild_keys()
	hovered = nil
	compute_matches()
	render()
end

local function on_click()
	if not active or not button_rect then
		return
	end
	local pos = mp.get_property_native("mouse-pos")
	if not pos then
		return
	end
	local r = button_rect
	if pos.x >= r.x and pos.x <= r.x + r.w and pos.y >= r.y and pos.y <= r.y + r.h then
		cycle_layout()
	end
end

----------------------------------------------------------------------
-- Search input: while the overlay owns the screen, printable keys type into
-- the query instead of reaching the player.
----------------------------------------------------------------------
local SEARCH_KEYS = { SPACE = " ", ["-"] = "-", ["_"] = "_", ["."] = ".", ["/"] = "/", ["+"] = "+" }
for c in ("abcdefghijklmnopqrstuvwxyz0123456789"):gmatch(".") do
	SEARCH_KEYS[c] = c
end

local function set_query(q)
	query = q
	compute_matches()
	render()
end

local function bind_search_keys()
	for key, char in pairs(SEARCH_KEYS) do
		mp.add_forced_key_binding(key, "keybind-visualizer-s-" .. key, function()
			set_query(query .. char)
		end, { repeatable = true })
	end
	mp.add_forced_key_binding("BS", "keybind-visualizer-s-bs", function()
		set_query(query:sub(1, -2))
	end, { repeatable = true })
end

local function unbind_search_keys()
	for key in pairs(SEARCH_KEYS) do
		mp.remove_key_binding("keybind-visualizer-s-" .. key)
	end
	mp.remove_key_binding("keybind-visualizer-s-bs")
end

----------------------------------------------------------------------
-- Toggle
----------------------------------------------------------------------
local function close()
	if not active then
		return
	end
	active = false
	hovered = nil
	query = ""
	match_ids, match_list = {}, {}
	mp.unobserve_property(on_mouse)
	mp.unobserve_property(on_resize)
	mp.remove_key_binding("keybind-visualizer-esc")
	mp.remove_key_binding("keybind-visualizer-click")
	unbind_search_keys()
	if saved_autohide ~= nil then
		mp.set_property("cursor-autohide", saved_autohide)
		saved_autohide = nil
	end
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
	build_bindings()
	active = true
	hovered = nil
	query = ""
	match_ids, match_list = {}, {}
	mouse_x, mouse_y = nil, nil
	local pos = mp.get_property_native("mouse-pos")
	if pos then
		mouse_x, mouse_y = pos.x, pos.y
	end
	saved_autohide = mp.get_property("cursor-autohide")
	mp.set_property("cursor-autohide", "no")
	mp.observe_property("mouse-pos", "native", on_mouse)
	mp.observe_property("osd-dimensions", "native", on_resize)
	mp.add_forced_key_binding("ESC", "keybind-visualizer-esc", function()
		if query ~= "" then
			set_query("")
		else
			close()
		end
	end)
	mp.add_forced_key_binding("MBTN_LEFT", "keybind-visualizer-click", on_click)
	bind_search_keys()
	render()
end

local function toggle()
	if active then
		close()
	else
		open()
	end
end

mp.add_key_binding(nil, "keybind-visualizer", toggle)
mp.register_event("shutdown", function()
	if overlay then
		overlay:remove()
	end
end)
