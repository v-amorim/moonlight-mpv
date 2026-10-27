-- Lists subtitles for the playing file from opensubtitles.org, no account needed, and
-- saves the picked one next to the video. A match on the file's own hash is made for
-- this exact file; anything else is retimed by alass-sync afterwards.

local utils = require("mp.utils")
local options = require("mp.options")

local opts = {
    -- opensubtitles.org codes, in order of preference: pob is pt-BR, eng English
    languages = "pob,eng",
}
options.read_options(opts, "sub-find")

local MENU_ID = "sub-find"
local LABEL = "Subtitle search"
local LANG_NAMES = { pob = "pt-BR", por = "pt", eng = "en", spa = "es" }
local helper = mp.get_script_directory() .. "/sub_find.py"

local function say(state, detail)
    mp.commandv("script-message-to", "osd_theme", "say", LABEL, state, detail)
end

local function video_path()
    return utils.join_path(mp.get_property("working-directory"), mp.get_property("path"))
end

local function python(args, done)
    local argv = { "python", "-I", helper }
    for _, arg in ipairs(args) do
        argv[#argv + 1] = arg
    end
    mp.command_native_async(
        { name = "subprocess", args = argv, capture_stdout = true, playback_only = false },
        function(_, res)
            local payload = (res and res.stdout or ""):match("SUBFIND_JSON:([^\r\n]*)")
            local answer = payload and utils.parse_json(payload)
            if not answer or answer.error then
                say("failed", answer and answer.error or "python did not answer; is it on PATH?")
                mp.commandv("script-message-to", "uosc", "close-menu", MENU_ID)
                return
            end
            done(answer)
        end
    )
end

local function menu(items, footnote, suggestion, selected)
    return utils.format_json({
        id = MENU_ID,
        type = MENU_ID,
        title = "Find subtitles",
        footnote = footnote,
        items = items,
        selected_index = selected,
        callback = { mp.get_script_name(), "activate" },
        -- Enter on a result downloads it; typing and Enter searches the site again with that text.
        -- uosc only applies the suggestion when the menu opens, so updates keep what was typed.
        search_style = "palette",
        search_debounce = "submit",
        search_suggestion = suggestion,
        on_search = "callback",
    })
end

local function placeholder(text)
    return { { title = text, selectable = false, muted = true, italic = true } }
end

local DOT = "  \xC2\xB7  "

local function lang_name(code)
    return LANG_NAMES[code] or code
end

-- uosc right-aligns hints, so every hint is padded to one length to line the columns up
-- in the monospace menu font.
local function hint(c, digits)
    return string.format("%-5s%s%" .. digits .. "d downloads", lang_name(c.lang), DOT, c.downloads)
end

local function footnote(answer, typed)
    local by
    if answer.imdb then
        by = "file hash and the IMDb id in the .nfo"
    elseif answer.query == "" then
        by = "file hash only; the file name gave no title"
    else
        by = "file hash and \"" .. answer.query .. "\"" .. (typed and "" or ", read from the file name")
    end
    return "searched by " .. by .. DOT .. "the check mark means made for this exact file"
        .. DOT .. "edit the text as Title S01E05 or Title 1999, Enter to search"
end

-- The last search, kept so the language filter can redraw without asking the site again.
local last = { answer = nil, typed = false, filter = nil }

local function languages_found(results)
    local found, seen = {}, {}
    for _, c in ipairs(results) do seen[c.lang] = true end
    for code in opts.languages:gmatch("[^,]+") do
        if seen[code] then found[#found + 1] = code end
    end
    return found
end

local function results_menu(keep_on_filter)
    local answer, results = last.answer, last.answer.results or {}
    local langs = languages_found(results)
    local filter_found = false
    for _, code in ipairs(langs) do filter_found = filter_found or code == last.filter end
    if not filter_found then last.filter = nil end

    local shown, digits = {}, 1
    for _, c in ipairs(results) do
        if not last.filter or c.lang == last.filter then
            shown[#shown + 1] = c
            digits = math.max(digits, #tostring(c.downloads))
        end
    end

    local items = {}
    if #langs > 1 then
        local names = {}
        for _, code in ipairs(langs) do names[#names + 1] = lang_name(code) end
        items[1] = {
            title = "Language: " .. (last.filter and lang_name(last.filter) or "All"),
            hint = "Enter cycles All" .. DOT .. table.concat(names, DOT),
            icon = "translate",
            value = "filter",
            muted = true,
        }
    end
    local first_result = #items + 1
    for _, c in ipairs(shown) do
        items[#items + 1] = {
            title = c.release ~= "" and c.release or ("subtitle " .. c.id),
            hint = hint(c, digits),
            -- every row carries an icon, or the rows without one would push their hint right
            icon = c.hash_match and "verified" or "subtitles",
            value = table.concat({ c.id, c.lang, c.hash_match and "1" or "0" }, "|"),
        }
    end
    if #shown == 0 then
        for _, row in ipairs(placeholder("No subtitles in " .. opts.languages)) do items[#items + 1] = row end
    end
    return menu(items, footnote(answer, last.typed), answer.query, keep_on_filter and 1 or first_result)
end

local function cycle_filter()
    local langs = languages_found(last.answer.results or {})
    local next_filter = langs[1]
    for i, code in ipairs(langs) do
        if code == last.filter then next_filter = langs[i + 1] end
    end
    last.filter = next_filter
    mp.commandv("script-message-to", "uosc", "update-menu", results_menu(true))
end

-- The menu opens only once the first search is back, because that is the one
-- moment uosc takes the guessed title as the editable search text.
local function open()
    if not mp.get_property("path") then
        say("nothing to do", "no file is playing")
        return
    end
    mp.commandv("script-message-to", "osd_theme", "busy", LABEL, "searching opensubtitles.org")
    python({ "--search", video_path(), opts.languages }, function(answer)
        last = { answer = answer, typed = false, filter = nil }
        mp.commandv("script-message-to", "osd_theme", "clear")
        mp.commandv("script-message-to", "uosc", "open-menu", results_menu())
    end)
end

local function search_again(query)
    mp.commandv("script-message-to", "uosc", "update-menu", menu(placeholder("Searching\xE2\x80\xA6"), nil, query))
    python({ "--search", video_path(), opts.languages, query }, function(answer)
        -- the filter survives a new search, since what is being narrowed down is the same
        last = { answer = answer, typed = true, filter = last.filter }
        mp.commandv("script-message-to", "uosc", "update-menu", results_menu())
    end)
end

local function fetch(value)
    local id, lang, hash_match = value:match("^(%d+)|([^|]+)|([01])$")
    mp.commandv("script-message-to", "osd_theme", "busy", LABEL, "downloading subtitle " .. id)
    python({ "--download", id, lang, video_path() }, function(answer)
        mp.commandv("sub-add", answer.path, "select")
        local _, name = utils.split_path(answer.path)
        if hash_match == "1" then
            say("done", "saved " .. name .. ", made for this file")
        else
            -- the release differs, so its timing needs matching to this file's audio
            mp.commandv("script-message-to", "alass_sync", "sync-file", answer.path)
        end
    end)
end

mp.register_script_message("activate", function(json)
    local event = utils.parse_json(json)
    if event and event.type == "search" and (event.query or "") ~= "" then
        search_again(event.query)
    elseif event and event.type == "activate" and event.value == "filter" then
        cycle_filter()
    elseif event and event.type == "activate" and event.value then
        mp.commandv("script-message-to", "uosc", "close-menu", MENU_ID)
        fetch(event.value)
    end
end)

mp.add_key_binding("", "sub-find", open)
