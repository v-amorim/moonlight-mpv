--[[
    pause-indicator.lua - a pause glyph in the top right corner

    Descended from CogentRedTester's version, which printed the "⏸" character:
    that glyph is drawn by whatever system font mpv falls back to, so its box and
    bars sit off centre, and `\an9` alone pins it flush into the corner.

    This draws the icon from the font uosc already ships, at a size and margin
    derived from the current OSD, so it stays symmetric and matches the rest of
    the interface.

    Source: https://github.com/v-amorim/moonlight-mpv
]]
--

local mp = require("mp")

local FONT = "MaterialIconsRound-Regular"
local ICON = "pause_circle_filled"
local COLOR = "FAEEEE" -- the Moonlight text colour #EEEEFA, written in BGR for ASS
local SIZE = 0.055 -- share of the OSD height
local MARGIN = 0.022 -- share of the OSD height, from both edges

local function draw()
    local width, height = mp.get_osd_size()
    if not width or width == 0 then
        return
    end
    local margin = height * MARGIN
    mp.set_osd_ass(
        width,
        height,
        string.format(
            "{\\an9\\pos(%d,%d)\\fn%s\\fs%d\\bord%.1f\\shad0\\1c&H%s&\\3c&H000000&\\alpha&H20&}%s",
            math.floor(width - margin),
            math.floor(margin),
            FONT,
            math.floor(height * SIZE),
            math.max(1, height * 0.002),
            COLOR,
            ICON
        )
    )
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

-- the old version read the OSD size once at load, so the glyph drifted out of
-- the corner after a resize or a switch to fullscreen
mp.observe_property("osd-dimensions", "native", function()
    if shown then
        draw()
    end
end)
