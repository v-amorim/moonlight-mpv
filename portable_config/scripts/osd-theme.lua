-- One OSD message shape for input.conf:
--   expand-properties script-message-to osd_theme say "<label>" "<state>" "<detail>"
-- State may be empty. "yes"/"no" become "on" / "off".
-- For `af toggle @name:...`, `say-filter "<label>" "<name>" "<detail>"` reads the
-- state back off the filter chain instead.
--
-- Drawn as the Moonlight toast: a surface-1 card with a hairline and a soft shadow,
-- a square icon tinted 15 % with the accent, a bold title and a muted detail line.

local function ease_out(t)
    return 1 - (1 - t) ^ 3
end

-- The entrance: drops 16 px (at 1080) from above while it fades in, as if from the top bar.
local ENTER_SECONDS = 0.3
local ENTER_DROP = 16

local function bgr(hex)
    return hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2)
end

-- Moonlight tokens, turned into the BBGGRR order ASS wants.
local C = {}
for name, rgb in pairs({
    card = "141726", -- surface-1
    hairline = "242839", -- border over surface-1
    title = "EEEEFA", -- on-surface
    value = "A2B0EA", -- primary-70
    detail = "9BA3C4", -- muted
    accent = "7386D0", -- primary, the icon and its 15 % square
}) do
    C[name] = bgr(rgb)
end

-- mpv answers in its own vocabulary: loop-file set to "yes" reads back as "inf".
local BOOLEAN_WORDS = { yes = "on", on = "on", inf = "on", no = "off", off = "off" }
-- Material Icons Round ligatures from the font uosc ships.
local ICONS = { on = "toggle_on", off = "toggle_off", value = "tune", busy = "autorenew" }

local overlay = mp.create_osd_overlay("ass-events")
local hide_timer, spin_timer
local busy_label, busy_detail, busy_angle = "", nil, 0

local function round(x)
    return math.floor(x + 0.5)
end

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

local function esc(s)
    return ((s or ""):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"))
end

local function utf8_len(s)
    local _, n = (s or ""):gsub("[^\128-\191]", "")
    return n
end

-- The patched uosc top bar publishes its drawn bottom edge. Without it, uosc raises its
-- bar near the top edge and publishes a margin only while pinned, so both are read.
local function top_bar_bottom(h, s)
    local drawn = mp.get_property_native("user-data/moonlight/top_bar_bottom")
    if drawn then
        return drawn
    end
    local margins = mp.get_property_native("user-data/osc/margins")
    local pinned = margins and margins.t and margins.t * h or 0
    local mouse = mp.get_property_native("mouse-pos")
    local raised = mouse and mouse.hover and mouse.y < round(120 * s) and round(56 * s) or 0
    return math.max(pinned, raised)
end

-- Top left, dropped below uosc's top bar while it shows.
local function place(h, s)
    local margin = round(24 * s)
    return margin, math.max(margin, top_bar_bottom(h, s) + round(8 * s))
end

-- An element's own transparency (ASS hex, 00 opaque) faded by the entrance's opacity.
local function faded(own, opacity)
    return string.format("%02X", round(255 - (255 - tonumber(own, 16)) * opacity))
end

local function draw(label, state, detail, angle, t)
    local dim = mp.get_property_native("osd-dimensions")
    if not dim or not dim.w or dim.w == 0 then
        return
    end
    local w, h = dim.w, dim.h
    -- Moonlight sizes are px at 1080 lines, scaled to the monitor, as the script panels do.
    local s = (mp.get_property_number("display-height") or h) / 1080
    local title_fs, detail_fs = round(18 * s), round(15 * s)
    local k = s
    local pad, icon_box, gap = round(14 * k), round(36 * k), round(12 * k)
    t = math.min(1, math.max(0, t or 1))
    local op = ease_out(t)
    local A = function(own) return faded(own, op) end

    local word = state and state ~= "" and (BOOLEAN_WORDS[state] or state) or nil
    local icon = angle and ICONS.busy or (word == "on" and ICONS.on) or (word == "off" and ICONS.off) or ICONS.value
    local title_chars = utf8_len(label) + (word and utf8_len(word) + 1 or 0)
    local has_detail = detail and detail ~= ""
    -- the OSD face is monospace, so a character count sizes the card
    local text_w = math.max(title_chars * title_fs * 0.6, has_detail and utf8_len(detail) * detail_fs * 0.6 or 0)
    local cw = round(pad + icon_box + gap + text_w + pad + 4 * s)
    local ch = round(math.max(icon_box, title_fs * 1.25 + (has_detail and detail_fs * 1.35 or 0)) + 2 * pad)
    local x, y = place(h, s)
    y = y - round(ENTER_DROP * (1 - op) * s)

    local a = {}
    -- shadow, then the card with its hairline
    a[#a + 1] = string.format("{\\an7\\pos(%d,%d)\\bord0\\shad0\\4a&HFF&\\blur%d\\1c&H000000&\\1a&H%s&\\p1}%s{\\p0}",
        x, y + round(8 * s), round(14 * s), A("60"), rrect_draw(cw, ch, round(12 * s)))
    a[#a + 1] = string.format("{\\an7\\pos(%d,%d)\\bord%d\\shad0\\4a&HFF&\\3c&H%s&\\1c&H%s&\\alpha&H%s&\\4a&HFF&\\p1}%s{\\p0}",
        x, y, math.max(1, round(s)), C.hairline, C.card, A("00"), rrect_draw(cw, ch, round(12 * s)))
    -- icon square: the accent at 15 %, 8 px corners
    local ix, iy = x + pad, y + round((ch - icon_box) / 2)
    a[#a + 1] = string.format("{\\an7\\pos(%d,%d)\\bord0\\shad0\\4a&HFF&\\1c&H%s&\\1a&H%s&\\p1}%s{\\p0}",
        ix, iy, C.accent, A("D9"), rrect_draw(icon_box, icon_box, round(8 * s)))
    a[#a + 1] = string.format("{\\an5\\pos(%d,%d)\\fnMaterialIconsRound-Regular\\fs%d\\bord0\\shad0\\4a&HFF&\\1c&H%s&\\alpha&H%s&\\4a&HFF&\\frz%d}%s",
        ix + round(icon_box / 2), iy + round(icon_box / 2), round(22 * k), C.accent, A("00"), angle or 0, icon)
    -- title and value, then the detail
    local tx = ix + icon_box + gap
    local title = string.format("{\\1c&H%s&}%s", C.title, esc(label))
    if word then
        title = title .. string.format(" {\\1c&H%s&}%s", C.value, esc(word))
    end
    if has_detail then
        local ty = y + round(ch / 2 - (title_fs * 1.25 + detail_fs * 1.35) / 2)
        a[#a + 1] = string.format("{\\an7\\pos(%d,%d)\\fs%d\\b1\\bord0\\shad0\\4a&HFF&\\q2\\alpha&H%s&\\4a&HFF&}%s", tx, ty, title_fs, A("00"), title)
        a[#a + 1] = string.format("{\\an7\\pos(%d,%d)\\fs%d\\b0\\bord0\\shad0\\4a&HFF&\\q2\\1c&H%s&\\alpha&H%s&\\4a&HFF&}%s",
            tx, ty + round(title_fs * 1.3), detail_fs, C.detail, A("00"), esc(detail))
    else
        a[#a + 1] = string.format("{\\an4\\pos(%d,%d)\\fs%d\\b1\\bord0\\shad0\\4a&HFF&\\q2\\alpha&H%s&\\4a&HFF&}%s", tx, y + round(ch / 2), title_fs, A("00"), title)
    end

    overlay.res_x, overlay.res_y = w, h
    overlay.data = table.concat(a, "\n")
    overlay:update()
end

local function stop_spinning()
    if spin_timer then
        spin_timer:kill()
        spin_timer = nil
    end
end

local shown, enter_timer

local function show(label, state, detail)
    stop_spinning()
    shown = { label, state, detail }
    if enter_timer then enter_timer:kill() end
    local start = mp.get_time()
    draw(label, state, detail, nil, 0)
    enter_timer = mp.add_periodic_timer(1 / 60, function()
        local t = (mp.get_time() - start) / ENTER_SECONDS
        draw(label, state, detail, nil, t)
        if t >= 1 then enter_timer:kill() end
    end)
    if hide_timer then hide_timer:kill() end
    hide_timer = mp.add_timeout(mp.get_property_number("osd-duration", 1000) / 1000, function()
        shown = nil
        overlay:remove()
    end)
end

-- a toast on screen steps down when the top bar rises under it, and back up after
mp.observe_property("mouse-pos", "native", function()
    if shown and not (enter_timer and enter_timer:is_enabled()) then
        draw(shown[1], shown[2], shown[3])
    end
end)

mp.register_script_message("say", show)

-- `af toggle` adds or removes the filter outright, so presence is the state.
mp.register_script_message("say-filter", function(label, filter_label, detail)
    local on = false
    for _, filter in ipairs(mp.get_property_native("af") or {}) do
        on = on or filter.label == filter_label
    end
    show(label, on and "yes" or "no", detail)
end)

-- For a script that spins through `busy` and then draws its own full screen
-- interface: there is nothing left to report, and a `say` would sit on top of it.
mp.register_script_message("clear", function()
    stop_spinning()
    if hide_timer then hide_timer:kill() end
    if enter_timer then enter_timer:kill() end
    shown = nil
    overlay:remove()
end)

-- Stays on screen until a `say` replaces it, for work that takes long enough
-- that a message which faded would look like nothing is happening.
local SPIN_STEP, SPIN_INTERVAL = 24, 0.05

local function draw_busy()
    busy_angle = (busy_angle + SPIN_STEP) % 360
    draw(busy_label, nil, busy_detail, -busy_angle)
end

mp.register_script_message("busy", function(label, detail)
    if hide_timer then hide_timer:kill() end
    shown = nil
    busy_label, busy_detail = label, detail
    -- a progress update only changes the words, so the icon keeps turning
    if not spin_timer then
        spin_timer = mp.add_periodic_timer(SPIN_INTERVAL, draw_busy)
    end
    draw_busy()
end)
