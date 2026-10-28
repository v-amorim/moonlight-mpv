-- chapters-menu.lua
-- Source: https://github.com/v-amorim/moonlight-mpv
--
-- A uosc front end for chapters.lua, which ships eleven bindings and no way to
-- see what any of them would do.
--
-- Adding, renaming and deleting are done here rather than delegated: chapters.lua
-- asks for a title through mp.input, which drops mpv's console over the video,
-- and it acts on the chapter playing rather than the one you picked.
-- Exporting, remuxing and the mkv rewrite are its own, and are called by name.
--
-- Activate with:  script-binding chapters_menu/menu

local mp = require("mp")
local utils = require("mp.utils")

local MENU_TYPE = "chapters-menu"
local RENAME_TYPE = "chapter-rename"
local script_name = mp.get_script_name()
local is_open = false
local renaming = nil

local function fmt_time(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	local hours = math.floor(seconds / 3600)
	local minutes = math.floor(seconds % 3600 / 60)
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, seconds % 60)
	end
	return string.format("%02d:%02d", minutes, seconds % 60)
end

local function chapters()
	return mp.get_property_native("chapter-list") or {}
end

-- mpv leaves the title empty for a chapter nobody named, and reports -1 for the
-- stretch of file before the first one
local function display_title(chapter, index)
	if chapter.title and chapter.title ~= "" then
		return chapter.title
	end
	return "Chapter " .. index
end

local function current_index()
	local current = mp.get_property_number("chapter")
	if not current or current < 0 then
		return nil
	end
	return chapters()[current + 1] and current + 1 or nil
end

-- CHAPTER EDITS ---------------------------------------------------------------

local function set_title(index, title)
	local list = chapters()
	if not list[index] then
		return
	end
	list[index].title = title
	mp.set_property_native("chapter-list", list)
end

local function delete_chapter(index)
	local list = chapters()
	if not list[index] then
		return
	end
	table.remove(list, index)
	mp.set_property_native("chapter-list", list)
end

-- MENU ------------------------------------------------------------------------

local EXPORTS = {
	{ "write_chapters", "Save chapters file", "save" },
	{ "write_txt", "Timestamps (.txt)", "description" },
	{ "write_list", "Plain list (.txt)", "list" },
	{ "write_xml", "Matroska XML", "code" },
	{ "write_ffmetadata", "ffmetadata", "text_snippet" },
	{ "bake_chapters", "Remux into a new file", "movie" },
	{ "mkvpropedit", "Write into the MKV in place", "construction" },
}

local function export_items()
	local items = {}
	for _, export in ipairs(EXPORTS) do
		items[#items + 1] = { title = export[2], icon = export[3], value = { "run", export[1] } }
	end
	-- the last two rewrite the video file itself, the ones above only write beside it
	items[#items - 2].separator = true
	return items
end

-- youtube wants a chapter at 0:00, at least three of them, and none under 10s
local function youtube_items(list)
	local duration = mp.get_property_number("duration")
	local items = {}

	local function verdict(passed, text)
		items[#items + 1] = {
			title = text,
			icon = passed and "check_circle" or "cancel",
			muted = not passed,
			selectable = false,
		}
	end

	local short = {}
	for index, chapter in ipairs(list) do
		-- a stream can report no duration, and the last chapter is the only one
		-- that needs it: measuring it against nothing would fail it on a lie
		local stop = list[index + 1] and list[index + 1].time or duration
		local length = stop and math.floor(stop) - math.floor(chapter.time)
		if length and length < 10 then
			short[#short + 1] = { index = index, length = length }
		end
	end

	verdict(list[1] ~= nil and math.floor(list[1].time) == 0, "First chapter starts at 0:00")
	verdict(#list >= 3, "At least three chapters")
	verdict(#list > 0 and #short == 0, "Every chapter lasts ten seconds or more")

	for _, entry in ipairs(short) do
		items[#items + 1] = {
			title = display_title(list[entry.index], entry.index),
			hint = entry.length .. "s",
			muted = true,
			selectable = false,
		}
	end

	return items
end

local function build_items()
	local list = chapters()
	local current = mp.get_property_number("chapter")
	local items = {}

	for index, chapter in ipairs(list) do
		items[#items + 1] = {
			title = display_title(chapter, index),
			hint = fmt_time(chapter.time),
			active = current == index - 1,
			keep_open = true,
			value = { "seek", index },
		}
	end

	if #items == 0 then
		items[1] = {
			title = "This file has no chapters",
			align = "center",
			muted = true,
			italic = true,
			selectable = false,
		}
	end
	items[#items].separator = true

	local index = current_index()
	local title = index and display_title(list[index], index)

	items[#items + 1] = {
		title = "Add chapter at the current position",
		icon = "add",
		value = { "add" },
	}
	items[#items + 1] = {
		title = title and ('Rename "' .. title .. '"') or "Rename chapter",
		icon = "edit",
		value = { "rename", index },
		selectable = index ~= nil,
		muted = index == nil,
	}
	items[#items + 1] = {
		title = title and ('Delete "' .. title .. '"') or "Delete chapter",
		icon = "remove",
		keep_open = true,
		value = { "delete", index },
		selectable = index ~= nil,
		muted = index == nil,
	}
	items[#items].separator = true

	items[#items + 1] = { title = "Export", icon = "save", items = export_items() }
	items[#items + 1] = { title = "YouTube check", icon = "fact_check", items = youtube_items(list) }

	return items
end

local function menu_json(cursor)
	return utils.format_json({
		type = MENU_TYPE,
		title = "Chapters",
		items = build_items(),
		selected_index = cursor,
		callback = { script_name, "menu-event" },
		on_close = { "script-message-to", script_name, "menu-closed" },
	})
end

local function open(cursor)
	mp.commandv("script-message-to", "uosc", "open-menu", menu_json(cursor))
	is_open = true
end

local function refresh()
	if is_open then
		mp.commandv("script-message-to", "uosc", "update-menu", menu_json())
	end
end

-- Prefilling the query is what makes this a rename rather than a retype, and
-- "submit" keeps uosc quiet until Enter.
local function open_rename(index)
	local list = chapters()
	if not list[index] then
		return
	end
	renaming = index
	mp.commandv(
		"script-message-to",
		"uosc",
		"open-menu",
		utils.format_json({
			type = RENAME_TYPE,
			title = "Chapter title",
			items = {
				{
					title = "Enter rename  \xC2\xB7  Esc keep",
					align = "center",
					muted = true,
					italic = true,
					selectable = false,
				},
			},
			search_style = "palette",
			search_debounce = "submit",
			search_suggestion = display_title(list[index], index),
			on_search = "callback",
			callback = { script_name, "menu-event" },
			on_close = { "script-message-to", script_name, "rename-closed" },
		})
	)
end

local function activate(value)
	local action, index = value[1], value[2]

	if action == "seek" then
		mp.set_property_number("chapter", index - 1)
	elseif action == "add" then
		local list = chapters()
		-- mpv counts from 0 and reports -1 before the first chapter, Lua counts from
		-- 1, and the new one goes after the current one: +2
		local at = (mp.get_property_number("chapter") or -1) + 2
		table.insert(list, at, { title = "", time = mp.get_property_number("time-pos") or 0 })
		mp.set_property_native("chapter-list", list)
		open_rename(at)
	elseif action == "rename" then
		open_rename(index)
	elseif action == "delete" then
		delete_chapter(index)
		refresh()
	elseif action == "run" then
		mp.commandv("script-binding", "chapters/" .. index)
	end
end

mp.register_script_message("menu-event", function(json)
	local event = utils.parse_json(json or "")
	if not event then
		return
	end

	if event.type == "search" and renaming then
		set_title(renaming, event.query)
		open(renaming)
		renaming = nil
	elseif event.type == "activate" and type(event.value) == "table" then
		activate(event.value)
	end
end)

mp.register_script_message("menu-closed", function()
	is_open = false
end)

mp.register_script_message("rename-closed", function()
	renaming = nil
end)

-- seeking from the menu moves the active marker, and so does the video reaching
-- the next chapter on its own
mp.observe_property("chapter", "number", refresh)

mp.add_key_binding(nil, "menu", function()
	if is_open then
		mp.commandv("script-message-to", "uosc", "close-menu", MENU_TYPE)
	else
		open()
	end
end)
