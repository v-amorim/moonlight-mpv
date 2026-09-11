--[[
    watched-folder.lua - mpv script to move watched files into a watched folder

    Watched means everything sitting before the furthest file you opened, whatever order you
    jumped around in, so going back to an earlier file still leaves it watched. Set
    require_eof to count only the files whose playback actually reached the end instead.
    The move runs when the playlist reaches the end of its last file, and again when mpv
    closes. Use `F10` key to toggle the moving on/off with an OSD message.

    Source: https://github.com/v-amorim/moonlight-mpv/blob/main/portable_config/scripts/watched-folder.lua
]]
--

local utils = require("mp.utils")

local opts = {
	subfolder = "watched",
	destination = "",
	require_eof = false,
}
require("mp.options").read_options(opts, "watched-folder")

local playlistPaths = {}
local visited = {}
local finished = {}
local moved = {}
local currentFilePath = nil
local fileMovingEnabled = true

-- md rejects forward slashes, and expand-path hands them back
local function normalize(folder)
	return (folder:gsub("/", "\\"):gsub("\\+$", ""))
end

-- mpv reports the file it was launched with in forward slashes, and the rest in backslashes
local function key(path)
	return normalize(path):lower()
end

local function destinationFor(path)
	if opts.destination ~= "" then
		return normalize(mp.command_native({ "expand-path", opts.destination }))
	end
	local thisFolder = utils.split_path(path)
	return normalize(utils.join_path(thisFolder, opts.subfolder))
end

local function alreadyMoved(path)
	local thisFolder = normalize(utils.split_path(path)):lower()
	if opts.destination ~= "" then
		return thisFolder == destinationFor(path):lower()
	end
	return thisFolder:match("\\([^\\]+)$") == opts.subfolder:lower()
end

-- autoload inserts entries before the current one, so a position taken on load goes stale
local function highWaterIndex()
	local highest = 0
	for i, path in ipairs(playlistPaths) do
		if visited[key(path)] then
			highest = i
		end
	end
	return highest
end

local function watchedPaths()
	local paths = {}
	if opts.require_eof then
		for _, path in ipairs(playlistPaths) do
			if finished[key(path)] then
				paths[#paths + 1] = path
			end
		end
		return paths
	end

	local upTo = highWaterIndex()
	if upTo > 0 and not finished[key(playlistPaths[upTo])] then
		upTo = upTo - 1
	end
	for i = 1, upTo do
		paths[#paths + 1] = playlistPaths[i]
	end
	return paths
end

local function movablePaths()
	local paths = {}
	local current = currentFilePath and key(currentFilePath)
	for _, path in ipairs(watchedPaths()) do
		if not moved[key(path)] and key(path) ~= current and not alreadyMoved(path) then
			paths[#paths + 1] = path
		end
	end
	return paths
end

-- move renames the file to the folder name when the folder is missing, so create it first
local function ensureFolder(folder)
	if not utils.readdir(folder) then
		utils.subprocess({ args = { "cmd.exe", "/C", "md", folder }, playback_only = false })
	end
	return utils.readdir(folder) ~= nil
end

local function moveWatched()
	if not fileMovingEnabled then
		return
	end
	for _, path in ipairs(movablePaths()) do
		local destFolder = destinationFor(path)
		if not ensureFolder(destFolder) then
			mp.msg.error("cannot create " .. destFolder .. ", leaving " .. path .. " in place")
		else
			-- cmd reads a forward slash as the start of a switch, so the source needs normalizing too
			local res = utils.subprocess({
				args = { "cmd.exe", "/C", "move", normalize(path), destFolder },
				playback_only = false,
			})
			moved[key(path)] = res.status == 0
			if res.status ~= 0 then
				mp.msg.error("could not move " .. path .. " into " .. destFolder)
			end
		end
	end
end

local function onPlaylist(_, value)
	playlistPaths = {}
	for _, entry in ipairs(value or {}) do
		playlistPaths[#playlistPaths + 1] = entry.filename
	end
end

local function onFileLoaded()
	currentFilePath = mp.get_property("path")
	visited[key(currentFilePath)] = true
end

local function onEndFile(event)
	if currentFilePath and event.reason == "eof" then
		finished[key(currentFilePath)] = true
	end
	currentFilePath = nil
end

-- keep-open holds the last file open, so it can only move once mpv releases it at shutdown
local function onEofReached(_, value)
	if not value or not currentFilePath then
		return
	end
	finished[key(currentFilePath)] = true
	if mp.get_property_number("playlist-pos", 0) == mp.get_property_number("playlist-count", 1) - 1 then
		moveWatched()
	end
end

local function pending()
	if not fileMovingEnabled then
		return "watched files stay where they are"
	end
	local target = opts.destination ~= "" and opts.destination or (opts.subfolder .. " folder")
	local count = #movablePaths()
	if count == 0 then
		return "the files you watch move into the " .. target .. " when you close mpv"
	end
	local label = count == 1 and "1 file" or (count .. " files")
	return label .. " moving into the " .. target .. " when you close mpv"
end

local function toggleFileMoving()
	fileMovingEnabled = not fileMovingEnabled
	local state = fileMovingEnabled and "yes" or "no"
	mp.commandv("script-message-to", "osd_theme", "say", "File moving", state, pending())
end

mp.register_event("file-loaded", onFileLoaded)
mp.register_event("end-file", onEndFile)
mp.register_event("shutdown", moveWatched)
mp.observe_property("playlist", "native", onPlaylist)
mp.observe_property("eof-reached", "bool", onEofReached)

mp.add_key_binding("", "watched-folder", toggleFileMoving)
