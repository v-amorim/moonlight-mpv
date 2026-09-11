-- https://github.com/AzuredBlue/mpv-anilist-updater

local utils = require("mp.utils")

local options = { auto_update = true, auto_update_paths = "animation" }
require("mp.options").read_options(options, "anilistUpdater")

local function say(label, state, detail)
	mp.commandv("script-message-to", "osd_theme", "say", label, state or "", detail or "")
end

-- The python side marks these on stdout so the OSD can say what to do next.
local function report(output)
	if output:find("ANILIST_NOT_LINKED", 1, true) then
		say("AniList", "not linked", "copy a token, then press the setup binding")
	elseif output:find("ANILIST_EXPIRED", 1, true) then
		say("AniList", "expired", "copy a fresh token, then press the setup binding")
	elseif output:find("ANILIST_API_DOWN", 1, true) then
		say("AniList", "unreachable", "their API is refusing requests, nothing to fix here")
	else
		local pinned = output:match("PINNED: (.+)")
		if pinned then
			say("AniList", "pinned", pinned:gsub("%s+$", ""))
			return
		end
		local name = output:match("LINKED: (%S+)")
		if name then
			say("AniList", "linked", "as " .. name)
			return
		end
		-- Anything else that failed still has to say so, or a menu that never
		-- opens looks like a dead keybinding.
		local problem = output:match("ERROR: ([^\r\n]+)")
		if problem then
			say("AniList", "failed", problem)
		end
	end
end

function callback(success, result, error, action)
	local output = result.stdout or ""

	-- Only a guess that produced nothing opens the picker uninvited; a match,
	-- an outage or an expired token must not.
	local guessed = output:match("ANILIST_NO_MATCH: ([^\r\n]*)")
	if guessed then
		say("AniList", "no match", "for " .. guessed .. ", pick the right entry")
		open_picker(guessed)
		return
	end

	-- "launch" only opens the page, so claiming an update there would be a lie.
	if result.status == 0 and action == "update" then
		local progress = output:match("New progress: (%d+)")
		say("AniList", progress and ("episode " .. progress) or "updated", "pushed to your list")
	end
	report(output)
end

local function get_python_command()
	local os_name = package.config:sub(1, 1)
	if os_name == "\\" then
		-- Windows
		return "python"
	else
		-- Linux
		return "python3"
	end
end

local python_command = get_python_command()

local function absolute_path()
	local directory = mp.get_property("working-directory")
	local path = mp.get_property("path")
	if not directory or not path then
		return nil
	end
	return ((directory:sub(-1) == "/" or directory:sub(-1) == "\\") and directory or directory .. "/") .. path
end

-- Only the anime library auto-updates. Anywhere else a wrong guess would push a
-- random episode onto a random entry, so those files wait for a keypress.
local function in_library()
	if options.auto_update_paths:match("^%s*$") then
		return true
	end

	local path = absolute_path()
	if not path then
		return false
	end

	path = path:lower()
	for fragment in options.auto_update_paths:gmatch("[^,]+") do
		fragment = fragment:match("^%s*(.-)%s*$"):lower()
		if fragment ~= "" and path:find(fragment, 1, true) then
			return true
		end
	end
	return false
end

-- Make sure it doesnt trigger twice in 1 video
local triggered = false

-- Function to check if we've reached 85% of the video
function check_progress()
	if triggered or not options.auto_update then
		return
	end

	local percent_pos = mp.get_property_number("percent-pos")

	if percent_pos then
		if percent_pos >= 85 then
			triggered = true
			if in_library() then
				update_anilist("update")
			end
		end
	end
end

-- Function to launch the .py script
function update_anilist(action)
	if action == "launch" then
		say("AniList", "opening", "the page for this anime, in your browser")
	end
	local script_dir = debug.getinfo(1).source:match("@?(.*/)")
	local path = absolute_path()
	local table = {}
	table.name = "subprocess"
	table.args = { python_command, script_dir .. "anilistUpdater.py", path, action }
	table.capture_stdout = true
	local cmd = mp.command_native_async(table, function(success, result, error)
		callback(success, result, error, action)
	end)
end

-- The token goes over stdin rather than argv, which any process list can read.
function link_anilist()
	local token = mp.get_property("clipboard/text")
	if not token or token:match("^%s*$") then
		say("AniList", "no token", "copy the token from the AniList page first")
		return
	end

	local script_dir = debug.getinfo(1).source:match("@?(.*/)")
	mp.command_native_async({
		name = "subprocess",
		args = { python_command, script_dir .. "anilistUpdater.py", "--setup" },
		stdin_data = token,
		capture_stdout = true,
	}, function(success, result, error)
		report(result.stdout or "")
	end)
end

mp.observe_property("percent-pos", "number", check_progress)

-- Reset triggered
mp.register_event("file-loaded", function()
	triggered = false
end)

-- Keybinds, modify as you please
mp.add_key_binding("", "update_anilist", function()
	update_anilist("update")
end)

mp.add_key_binding("", "launch_anilist", function()
	update_anilist("launch")
end)

mp.add_key_binding("", "link_anilist", link_anilist)

-- ---------------------------------------------------------------------------
-- Picker: a uosc menu over AniList search, for when the filename guess is wrong
-- ---------------------------------------------------------------------------

local MENU_ID = "anilist-picker"
local picker_open = false

local function python(args, done)
	local script_dir = debug.getinfo(1).source:match("@?(.*/)")
	local argv = { python_command, script_dir .. "anilistUpdater.py" }
	for _, arg in ipairs(args) do
		argv[#argv + 1] = arg
	end

	mp.command_native_async({ name = "subprocess", args = argv, capture_stdout = true }, function(_, result)
		done(result and result.stdout or "")
	end)
end

-- guessit's own chatter is full of braces, so the payload is found by its
-- marker rather than by hunting for the first bracket.
local function parse_payload(output)
	local payload = output:match("ANILIST_JSON:([^\r\n]*)")
	return payload and utils.parse_json(payload) or nil
end

-- Named markers, not an "ANILIST_" prefix test: the payload marker shares it.
local function failed(output)
	return output:find("ANILIST_NOT_LINKED", 1, true)
		or output:find("ANILIST_EXPIRED", 1, true)
		or output:find("ANILIST_API_DOWN", 1, true)
		or output:find("ERROR:", 1, true)
end

local function entry_hint(entry)
	local parts = {}
	for _, field in ipairs({ entry.format, entry.year, entry.episodes and (entry.episodes .. " ep") }) do
		if field then
			parts[#parts + 1] = tostring(field)
		end
	end
	return table.concat(parts, "  ")
end

local function menu_payload(query, entries)
	local items = {}
	for _, entry in ipairs(entries or {}) do
		items[#items + 1] = {
			title = entry.title,
			hint = entry_hint(entry),
			value = tostring(entry.id),
		}
	end

	if #items == 0 then
		items[1] = { title = "No results", selectable = false, muted = true, italic = true }
	end

	return utils.format_json({
		id = MENU_ID,
		type = MENU_ID,
		title = "Link on AniList",
		footnote = "type to search, or paste an AniList link",
		search_style = "palette",
		search_debounce = 400,
		search_suggestion = query,
		items = items,
		callback = { mp.get_script_name(), "picker-activate" },
		-- These take a raw mpv command, not a script-message target, so the
		-- literal "callback" is what routes them to the callback above.
		-- on_paste is pointless here: with a search palette open, uosc types a
		-- paste into the query instead of firing it. A pasted link is picked up
		-- by the search handler instead.
		on_search = "callback",
		on_close = "callback",
	})
end

local function show(query, entries, reopen)
	mp.commandv("script-message-to", "uosc", reopen and "update-menu" or "open-menu", menu_payload(query, entries))
	picker_open = true
end

local function search_into_menu(query, reopen)
	python({ "--search", query }, function(output)
		if failed(output) then
			report(output)
			return
		end
		show(query, parse_payload(output), reopen)
	end)
end

function open_picker(seed)
	if seed and seed ~= "" then
		search_into_menu(seed, picker_open)
		return
	end

	local path = mp.get_property("path")
	if not path then
		say("AniList", "no file", "nothing playing to look up")
		return
	end

	python({ "--guess", path }, function(output)
		local guess = parse_payload(output)
		search_into_menu(guess and guess.name or "", picker_open)
	end)
end

local function pin(anime_id)
	python({ "--pin", absolute_path(), anime_id }, function(output)
		report(output)
		-- Fixing the match is never the goal in itself, so land back on the menu
		-- with the corrected entry showing and the write one keypress away.
		if not failed(output) then
			open_root_menu()
		end
	end)
end

-- An AniList link or a bare id collapses the menu to that one entry; anything
-- else is a title search.
local function query_into_menu(query)
	local id = query:match("anilist%.co/anime/(%d+)") or query:match("^%s*(%d+)%s*$")
	if not id then
		search_into_menu(query, true)
		return
	end

	python({ "--resolve", id }, function(output)
		if failed(output) then
			report(output)
			return
		end
		local entry = parse_payload(output)
		if entry then
			show(query, { entry }, true)
		end
	end)
end

mp.register_script_message("picker-activate", function(json)
	local event = utils.parse_json(json)
	if not event then
		return
	end

	if event.type == "search" then
		query_into_menu(event.query or "")
	elseif event.type == "close" then
		picker_open = false
	elseif event.type == "activate" and event.value then
		pin(event.value)
		mp.commandv("script-message-to", "uosc", "close-menu", MENU_ID)
	end
end)

-- ---------------------------------------------------------------------------
-- Root menu: everything AniList behind one key
-- ---------------------------------------------------------------------------

local ROOT_ID = "anilist-root"

-- AniList's own vocabulary is shoutier than this menu wants.
local STATUS_WORDS = {
	CURRENT = "watching",
	PLANNING = "planning",
	COMPLETED = "completed",
	DROPPED = "dropped",
	PAUSED = "paused",
	REPEATING = "rewatching",
}

-- A total only means something once no more episodes are coming; while a show
-- is still airing the count it declares is the plan, not the ceiling.
local function progress_text(entry)
	local watched = tostring(entry.progress or 0)
	if not entry.episodes then
		return watched
	end

	local over = entry.airing == "FINISHED" or entry.airing == "CANCELLED"
	return watched .. "/" .. entry.episodes .. (over and "" or "+")
end

local function countdown(seconds)
	local days = math.floor(seconds / 86400)
	if days > 0 then
		return days .. "d"
	end

	local hours = math.floor(seconds / 3600)
	if hours > 0 then
		return hours .. "h"
	end

	return math.max(1, math.floor(seconds / 60)) .. "m"
end

local function saved_state(entry)
	if not entry then
		return "not on your list"
	end

	local word = STATUS_WORDS[entry.status] or (entry.status or ""):lower()
	local text = word .. " " .. progress_text(entry)

	if entry.next_in and entry.next_episode then
		text = text .. "  ·  ep " .. entry.next_episode .. " in " .. countdown(entry.next_in)
	end

	return text
end

-- The row that names what this file resolved to. Provenance rides on the type
-- style rather than a word, so the title keeps the width it needs: pinned is
-- bold, a bare guess is italic and carries a question mark on the right.
local function match_item(menu)
	if not menu.match then
		return {
			title = 'No match for "' .. (menu.guess or "?") .. '"',
			hint = menu.episode and ("ep " .. tostring(menu.episode)) or "",
			icon = "search_off",
			italic = true,
			muted = true,
			selectable = false,
			separator = true,
		}
	end

	local guessed = menu.match.source == "guessed"
	return {
		title = menu.match.title,
		hint = saved_state(menu.match.entry),
		icon = guessed and "help" or nil,
		bold = not guessed,
		italic = guessed,
		value = "launch",
		separator = true,
	}
end

-- Returns the item list plus the index the cursor should start on. The cursor
-- never lands on the write when the match was only guessed: one reflexive
-- Enter would push the wrong episode onto the wrong anime.
local function root_items(menu)
	local items = {}
	local function add(item)
		items[#items + 1] = item
		return #items
	end

	local relink = {
		title = "Re-link account",
		hint = "from clipboard",
		value = "link",
		muted = true,
	}

	if not menu.linked then
		local cursor = add({
			title = "Link account",
			hint = "copy a token first",
			value = "link",
			separator = true,
		})
		add({ title = "Get a token from AniList", hint = "browser", value = "token-page" })
		return items, cursor
	end

	if not menu.match and not menu.guess then
		add({
			title = "No file playing",
			italic = true,
			muted = true,
			selectable = false,
			separator = true,
		})
		return items, add(relink)
	end

	add(match_item(menu))

	local entry = menu.match and menu.match.entry
	local seen = entry and menu.episode and entry.progress and entry.progress >= menu.episode

	local mark = { title = "Mark episode " .. tostring(menu.episode) .. " watched", value = "update" }
	if not menu.match then
		mark.hint, mark.muted, mark.selectable = "no anime yet", true, false
	elseif seen then
		mark.hint, mark.muted, mark.selectable = "already seen", true, false
	end
	local mark_index = add(mark)

	local fix_index = add({ title = "Fix the match", hint = "search", value = "pick", separator = true })
	add(relink)

	local pinned = menu.match and menu.match.source == "pinned"
	return items, (pinned and not seen) and mark_index or fix_index
end

local function root_payload(menu)
	local items, cursor = root_items(menu)
	local title = "AniList"
	if menu.linked then
		title = menu.name and ("AniList · " .. menu.name) or "AniList"
	else
		title = "AniList · not linked"
	end

	return utils.format_json({
		id = ROOT_ID,
		type = ROOT_ID,
		title = title,
		items = items,
		selected_index = cursor,
		callback = { mp.get_script_name(), "root-activate" },
	})
end

-- The menu needs an AniList round trip before it can say anything, which is
-- long enough that an empty screen reads as a missed keypress. So it opens
-- immediately on the spinner uosc already draws, and fills in when data lands.
local function loading_payload()
	return utils.format_json({
		id = ROOT_ID,
		type = ROOT_ID,
		title = "AniList",
		items = { { icon = "spinner", align = "center", selectable = false, muted = true } },
		callback = { mp.get_script_name(), "root-activate" },
	})
end

function open_root_menu()
	mp.commandv("script-message-to", "uosc", "open-menu", loading_payload())

	python({ "--menu", mp.get_property("path") or "" }, function(output)
		if failed(output) then
			mp.commandv("script-message-to", "uosc", "close-menu", ROOT_ID)
			report(output)
			return
		end
		mp.commandv("script-message-to", "uosc", "update-menu", root_payload(parse_payload(output) or {}))
	end)
end

mp.register_script_message("root-activate", function(json)
	local event = utils.parse_json(json)
	if not event or event.type ~= "activate" then
		return
	end

	mp.commandv("script-message-to", "uosc", "close-menu", ROOT_ID)

	if event.value == "update" then
		update_anilist("update")
	elseif event.value == "launch" then
		update_anilist("launch")
	elseif event.value == "link" then
		link_anilist()
	elseif event.value == "token-page" then
		mp.commandv("run", "cmd", "/c", "start", "", "https://anilist.co/settings/developer")
	elseif event.value == "pick" then
		open_picker(nil)
	end
end)

mp.add_key_binding("", "anilist_menu", open_root_menu)
