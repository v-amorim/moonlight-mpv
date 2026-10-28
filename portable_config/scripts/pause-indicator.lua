--[[
    pause-indicator.lua - a "Paused" card in the top right corner

    Descended from CogentRedTester's version, which printed the "⏸" character in
    the corner. This draws the Moonlight toast's card instead (surface-1, hairline,
    an icon square tinted 15 % with the accent, a bold title), so a pause reads as
    part of the same interface as every other message.

    Source: https://github.com/v-amorim/moonlight-mpv
]]
--

local mp = require("mp")

-- three quarters of the toast's size: a state, not news
local SCALE = 0.75

local function bgr(hex)
    return hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2)
end

local C = {}
for name, rgb in pairs({
    text = "EEEEFA", -- on-surface
    card = "141726", -- surface-1
    hairline = "242839", -- border over surface-1
    accent = "7386D0", -- primary
}) do
    C[name] = bgr(rgb)
end

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

local TITLE = "Paused"

local function draw()
    local dim = mp.get_property_native("osd-dimensions")
    if not dim or not dim.w or dim.w == 0 then
        return
    end
    -- Moonlight sizes are px at 1080 lines, scaled to the monitor, as the toast does.
    local s = (mp.get_property_number("display-height") or dim.h) / 1080
    local k = s * SCALE
    local pad, box, gap, fs = round(14 * k), round(36 * k), round(12 * k), round(18 * k)
    -- the OSD face is monospace, so a character count sizes the card
    local cw, ch = round(pad + box + gap + #TITLE * fs * 0.6 + pad), round(box + 2 * pad)
    -- below uosc's top bar while it shows, as the toast does; the patched bar publishes its bottom edge
    local bar = mp.get_property_native("user-data/moonlight/top_bar_bottom") or 0
    local x, y = dim.w - cw - round(24 * s), math.max(round(24 * s), bar + round(8 * s))
    mp.set_osd_ass(dim.w, dim.h, table.concat({
        string.format("{\\an7\\pos(%d,%d)\\bord0\\shad0\\4a&HFF&\\blur%d\\1c&H000000&\\1a&H60&\\p1}%s{\\p0}",
            x, y + round(8 * s), round(14 * s), rrect_draw(cw, ch, round(12 * k))),
        string.format("{\\an7\\pos(%d,%d)\\bord%d\\shad0\\4a&HFF&\\3c&H%s&\\1c&H%s&\\p1}%s{\\p0}",
            x, y, math.max(1, round(s)), C.hairline, C.card, rrect_draw(cw, ch, round(12 * k))),
        string.format("{\\an7\\pos(%d,%d)\\bord0\\shad0\\4a&HFF&\\1c&H%s&\\1a&HD9&\\p1}%s{\\p0}",
            x + pad, y + pad, C.accent, rrect_draw(box, box, round(8 * k))),
        string.format("{\\an5\\pos(%d,%d)\\fnMaterialIconsRound-Regular\\fs%d\\bord0\\shad0\\4a&HFF&\\1c&H%s&}pause",
            x + pad + round(box / 2), y + pad + round(box / 2), round(22 * k), C.accent),
        -- set_osd_ass does not take osd-font, so name it, or the label falls back to a sans face
        string.format("{\\an4\\pos(%d,%d)\\fn%s\\fs%d\\b1\\bord0\\shad0\\4a&HFF&\\1c&H%s&}%s",
            x + pad + box + gap, y + round(ch / 2), mp.get_property("osd-font", "sans-serif"), fs, C.text, TITLE),
    }, "\n"))
end

local function clear()
    mp.set_osd_ass(0, 0, "")
end

local shown = false

mp.observe_property("pause", "bool", function(_, paused)
    shown = paused == true
    mp.add_timeout(0.1, function()
        if shown then
            draw()
        else
            clear()
        end
    end)
end)

-- the old version read the OSD size once at load, so the mark drifted out of
-- the corner after a resize or a switch to fullscreen
mp.observe_property("osd-dimensions", "native", function()
    if shown then
        draw()
    end
end)

mp.observe_property("user-data/moonlight/top_bar_bottom", "native", function()
    if shown then
        draw()
    end
end)
