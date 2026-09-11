-- One OSD message shape for input.conf:
--   expand-properties script-message-to osd_theme say "<label>" "<state>" "<detail>"
-- State may be empty. "yes"/"no" become a green "on" / red "off".
-- For `af toggle @name:...`, `say-filter "<label>" "<name>" "<detail>"` reads the
-- state back off the filter chain instead.

-- Moonlight, in the &HBBGGRR& order ASS wants, from the oh-my-posh palette.
local LABEL = '&HFAEEEE&' -- terminal_brightgray #EEEEFA
local ON = '&H95EF49&' -- terminal_green #49EF95
local OFF = '&H715FCA&' -- terminal_error #CA5F71
local VALUE = '&HD08673&' -- terminal_blue #7386D0
local DETAIL = '&HF5C6B9&' -- terminal_bluegray #B9C6F5
local OUTLINE = '&H261714&' -- main_background #141726

-- mpv answers in its own vocabulary: loop-file set to "yes" reads back as "inf".
local BOOLEAN_WORDS = { yes = 'on', on = 'on', inf = 'on', no = 'off', off = 'off' }

-- Overlay coordinates are fixed at 720 tall, so these scale with the window.
local ANCHOR = '{\\an7\\pos(26,24)\\fs34\\bord2\\shad1\\b1\\3c' .. OUTLINE .. '\\4c' .. OUTLINE .. '}'
local DETAIL_SIZE = '{\\fs26\\b0}'

-- The icon font uosc ships, so a wait here spins the same glyph its menus do.
local SPINNER = '{\\an5\\pos(43,41)\\fs30\\b0\\bord2\\shad1\\3c' .. OUTLINE .. '\\4c' .. OUTLINE
    .. '\\fnMaterialIconsRound-Regular\\1c' .. VALUE .. '\\frz%d}autorenew'
local BUSY_ANCHOR = ANCHOR:gsub('\\pos%(26,24%)', '\\pos(70,24)')
local SPIN_STEP = 24
local SPIN_INTERVAL = 0.05

local overlay = mp.create_osd_overlay('ass-events')
local hide_timer
local spin_timer

local function paint(colour, text)
    return string.format('{\\1c%s}%s', colour, text)
end

local function state_chunk(state)
    if not state or state == '' then return '' end
    local word = BOOLEAN_WORDS[state]
    if word then
        return ' ' .. paint(word == 'on' and ON or OFF, word)
    end
    return ' ' .. paint(VALUE, state)
end

local function body(anchor, label, state, detail)
    local text = anchor .. paint(LABEL, label) .. state_chunk(state)
    if detail and detail ~= '' then
        text = text .. '\\N' .. DETAIL_SIZE .. paint(DETAIL, detail)
    end
    return text
end

local function stop_spinning()
    if spin_timer then
        spin_timer:kill()
        spin_timer = nil
    end
end

local function show(label, state, detail)
    stop_spinning()
    overlay.data = body(ANCHOR, label, state, detail)
    overlay:update()

    if hide_timer then hide_timer:kill() end
    hide_timer = mp.add_timeout(mp.get_property_number('osd-duration', 1000) / 1000, function()
        overlay:remove()
    end)
end

mp.register_script_message('say', show)

-- `af toggle` adds or removes the filter outright, so presence is the state.
mp.register_script_message('say-filter', function(label, filter_label, detail)
    local on = false
    for _, filter in ipairs(mp.get_property_native('af') or {}) do
        on = on or filter.label == filter_label
    end
    show(label, on and 'yes' or 'no', detail)
end)

-- For a script that spins through `busy` and then draws its own full screen
-- interface: there is nothing left to report, and a `say` would sit on top of it.
mp.register_script_message('clear', function()
    stop_spinning()
    if hide_timer then hide_timer:kill() end
    overlay:remove()
end)

-- Stays on screen until a `say` replaces it, for work that takes long enough
-- that a message which faded would look like nothing is happening.
local busy_label, busy_detail, busy_angle = '', nil, 0

local function draw_busy()
    busy_angle = (busy_angle + SPIN_STEP) % 360
    overlay.data = SPINNER:format(-busy_angle) .. '\n' .. body(BUSY_ANCHOR, busy_label, nil, busy_detail)
    overlay:update()
end

mp.register_script_message('busy', function(label, detail)
    if hide_timer then hide_timer:kill() end
    busy_label, busy_detail = label, detail
    -- a progress update only changes the words, so the icon keeps turning
    if not spin_timer then
        spin_timer = mp.add_periodic_timer(SPIN_INTERVAL, draw_busy)
    end
    draw_busy()
end)
