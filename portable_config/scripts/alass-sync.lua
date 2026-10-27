-- Retimes the selected external subtitle against the video's own audio with alass
-- (https://github.com/kaegi/alass), which also finds cuts and framerate changes,
-- so the end stays in sync and not only the start.

local utils = require("mp.utils")
local options = require("mp.options")

local opts = {
    alass_dir = utils.join_path(os.getenv("USERPROFILE") or "", ".local/opt/alass"),
}
options.read_options(opts, "alass-sync")

local LABEL = "Subtitle sync"
-- backslashes, because cmd's mkdir reads a forward slash as a switch
local out_dir = (os.getenv("TEMP") or ".") .. "\\mpv-alass"
local running = false

local function say(state, detail)
    mp.commandv("script-message-to", "osd_theme", "say", LABEL, state, detail)
end

local function busy(detail)
    mp.commandv("script-message-to", "osd_theme", "busy", LABEL, detail)
end

local function shifted_blocks(stdout)
    local n = 0
    for _ in (stdout or ""):gmatch("shifted block of") do n = n + 1 end
    return n
end

local function is_utf8(path)
    local file = io.open(path, "rb")
    if not file then return true end
    local s = file:read("*a")
    file:close()
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        local extra = c < 0x80 and 0 or (c >= 0xC2 and c <= 0xDF) and 1 or (c >= 0xE0 and c <= 0xEF) and 2
            or (c >= 0xF0 and c <= 0xF4) and 3 or nil
        if not extra then return false end
        for k = i + 1, i + extra do
            local b = s:byte(k)
            if not b or b < 0x80 or b > 0xBF then return false end
        end
        i = i + extra + 1
    end
    return true
end

-- Calls done(stdout) once alass has written out, or reports the failure itself.
local function run_alass(sub, out, done)
    local video = utils.join_path(mp.get_property("working-directory"), mp.get_property("path"))
    local ffmpeg_bin = utils.join_path(opts.alass_dir, "ffmpeg/bin")
    -- split penalty 20: the default 7 invents minute-long jumps on dubbed audio
    local args = { utils.join_path(opts.alass_dir, "bin/alass-cli.exe"), "-p", "20" }
    -- alass refuses anything but UTF-8, and pt-BR subtitles often come as Windows-1252
    if not is_utf8(sub) then
        args[#args + 1] = "--encoding-inc"
        args[#args + 1] = "windows-1252"
    end
    for _, a in ipairs({ video, sub, out }) do args[#args + 1] = a end

    running = true
    local started = mp.get_time()
    local function report()
        busy(string.format("matching the lines to the audio  \xC2\xB7  %ds", mp.get_time() - started))
    end
    report()
    local timer = mp.add_periodic_timer(1, report)

    mp.command_native_async({
        name = "subprocess",
        args = args,
        env = {
            "ALASS_FFMPEG_PATH=" .. utils.join_path(ffmpeg_bin, "ffmpeg.exe"),
            "ALASS_FFPROBE_PATH=" .. utils.join_path(ffmpeg_bin, "ffprobe.exe"),
            "SystemRoot=" .. (os.getenv("SystemRoot") or "C:\\Windows"),
            "TEMP=" .. (os.getenv("TEMP") or "."),
        },
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
    }, function(_, res)
        timer:kill()
        running = false
        if not res or res.status ~= 0 or not utils.file_info(out) then
            say("failed", "alass could not run; check " .. opts.alass_dir)
            mp.msg.error((res and res.stderr) or "no result")
            return
        end
        -- alass wrote absolute times, so a leftover manual delay would push them off again
        mp.set_property_number("sub-delay", 0)
        done(res.stdout)
    end)
end

local function report_done(stdout)
    local blocks = shifted_blocks(stdout)
    say("done", blocks > 1 and (blocks .. " parts retimed separately") or "whole file moved as one block")
end

local function sync()
    if running then return end
    local track = mp.get_property_native("current-tracks/sub")
    if not track then
        say("nothing to do", "select a subtitle track first")
        return
    end
    if not track.external then
        say("nothing to do", "the track lives inside the video; export it with F12 first")
        return
    end

    local sub = track["external-filename"]
    local _, sub_name = utils.split_path(sub)
    local out = utils.join_path(out_dir, "synced." .. sub_name)
    if not utils.file_info(out_dir) then
        mp.command_native({ name = "subprocess", args = { "cmd", "/c", "mkdir", out_dir }, playback_only = false })
    end

    run_alass(sub, out, function(stdout)
        mp.commandv("sub-add", out, "select", "synced " .. (track.title or sub_name), track.lang or "")
        report_done(stdout)
    end)
end

-- For sub-find: retime a file it just saved, in place, and reload the selected track.
-- On failure the file is left as downloaded.
local function sync_file(path)
    if running then return end
    local out = path:gsub("(%.[^.\\/]+)$", ".alass%1")
    run_alass(path, out, function(stdout)
        os.remove(path)
        os.rename(out, path)
        mp.command("sub-reload")
        report_done(stdout)
    end)
end

mp.add_key_binding("", "alass-sync", sync)
mp.register_script_message("sync-file", sync_file)
