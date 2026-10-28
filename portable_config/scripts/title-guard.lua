--[[
    title-guard.lua - keeps junk embedded titles off uosc's top bar

    Some releases put a site tag ("BLUDV") in the file's title field, and uosc
    shows the embedded title first. The embedded title is kept only when it
    shares a word with the file name; otherwise the file name, without its
    extension, takes the first line and the second line is dropped.

    uosc reads the result from two templates in uosc.conf:
        top_bar_title=${user-data/moonlight/title}
        top_bar_alt_title=${user-data/moonlight/alt_title}

    Source: https://github.com/v-amorim/moonlight-mpv
]]
--

local mp = require("mp")

-- Words of 3 or more letters or digits; bytes above 127 count as letters so accented and CJK text still match.
local function words(text)
    local set = {}
    for word in text:lower():gmatch("[%w\128-\255]+") do
        if #word >= 3 then
            set[word] = true
        end
    end
    return set
end

local function shares_a_word(a, b)
    local other = words(b)
    for word in pairs(words(a)) do
        if other[word] then
            return true
        end
    end
    return false
end

local function update()
    local filename = mp.get_property("filename")
    if not filename then
        return
    end
    local bare = mp.get_property("filename/no-ext", filename)
    local embedded = mp.get_property("metadata/by-key/title", "")
    local keep = embedded ~= "" and shares_a_word(embedded, bare)
    mp.set_property("user-data/moonlight/title", keep and embedded or bare)
    -- the same text twice makes uosc drop the second line; an empty one would still be drawn
    mp.set_property("user-data/moonlight/alt_title", keep and filename or bare)
end

mp.register_event("file-loaded", update)
mp.observe_property("metadata", "native", update)
