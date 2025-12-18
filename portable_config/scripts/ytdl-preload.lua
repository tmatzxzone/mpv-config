local utils = require 'mp.utils'
local options = require 'mp.options'

-- [CONFIGURATION]
local preload_limit = 5      -- Max number of files to keep ahead
local trusted_domains = {    -- Domains allowed to use unsafe extensions
    "onedrive.live.com",
    "sharepoint.com",
    "1drv.ms"
}

-- [STATE TRACKING]
local download_queue = {}    -- URLs waiting to download
local queued_status = {}     -- { url = true }
local completed_files = {}   -- List of { path=... } in order of download
local is_busy = false        -- Worker busy state
local cache_path = "D:\\MPV Player\\Temp"

local opts = {
    temp = "D:\\MPV Player\\Temp",
    format = "bestvideo+bestaudio/best",
    ytdl_opt1 = "",
    ytdl_opt2 = "",
}
options.read_options(opts, "ytdl_preload")
cache_path = opts.temp

-- Ensure temp dir exists
local function ensure_dir(path)
    if package.config:sub(1, 1) == "\\" then
        os.execute('mkdir "' .. path .. '" 2>nul')
    else
        os.execute('mkdir -p "' .. path .. '"')
    end
end
ensure_dir(cache_path)

local function is_trusted_url(url)
    for _, domain in ipairs(trusted_domains) do
        if url:find(domain, 1, true) then return true end
    end
    return false
end

local function get_safe_filename(url)
    local sum = 0
    for i = 1, #url do sum = sum + string.byte(url, i) end
    return string.format("preload-%d-%d.mkv", #url, sum)
end

-- CLEANUP: Delete Old Files AND Remove from Playlist
local function try_cleanup()
    while #completed_files > preload_limit do
        local candidate = completed_files[1] -- Oldest file
        local current_playing = mp.get_property("path")
        
        -- Normalize paths for comparison (handle Windows backslashes)
        local cand_norm = candidate.path:gsub("\\", "/")
        local curr_norm = current_playing and current_playing:gsub("\\", "/") or ""
        
        -- SAFETY: Never delete the file currently being played
        if current_playing and (curr_norm == cand_norm) then
            print("[preload] Cache limit reached, but oldest file is playing. Skipping delete.")
            break
        end

        -- 1. Delete from Disk
        print("[preload] Deleting old file: " .. candidate.path)
        os.remove(candidate.path)
        
        -- 2. Remove from Playlist
        local count = tonumber(mp.get_property("playlist-count"))
        if count then
            for i = 0, count - 1 do
                local item = mp.get_property("playlist/" .. i .. "/filename")
                if item then
                    local item_norm = item:gsub("\\", "/")
                    if item_norm == cand_norm then
                        print("[preload] Removing deleted file from playlist index: " .. i)
                        mp.commandv("playlist_remove", i)
                        break -- Stop after removing (indices shift, but we restart loop next call anyway)
                    end
                end
            end
        end
        
        -- 3. Remove from internal tracker
        table.remove(completed_files, 1)
    end
end

-- ROBUST SWAP FUNCTION
local function perform_swap(url, local_file)
    local count = tonumber(mp.get_property("playlist-count"))
    local current_pos = tonumber(mp.get_property("playlist-pos"))
    local target_index = -1

    -- Scan playlist to find where this URL is currently located
    for i = 0, count - 1 do
        local path = mp.get_property("playlist/" .. i .. "/filename")
        if path == url then
            target_index = i
            break
        end
    end

    if target_index ~= -1 then
        if target_index == current_pos then
            print("[preload] Video is currently playing, skipping swap: " .. url)
            -- Track it so we delete it later when user moves to next video
            table.insert(completed_files, { path = local_file })
            return
        end

        print("[preload] Swapping index " .. target_index .. " with local file.")
        mp.commandv("loadfile", local_file, "append")
        mp.commandv("playlist_move", count, target_index)
        mp.commandv("playlist_remove", target_index + 1)
        
        -- Track swapped file for cleanup
        table.insert(completed_files, { path = local_file })
        
        mp.osd_message("Preloaded: Video " .. (target_index + 1))
    else
        print("[preload] Could not find URL in playlist to swap: " .. url)
        -- Still track it so we don't leave orphaned files forever
        table.insert(completed_files, { path = local_file })
    end
end

-- WORKER & DOWNLOADER
local process_queue -- Forward declaration

local function download_task(url)
    local safe_name = get_safe_filename(url)
    local output_path = utils.join_path(cache_path, safe_name)
    
    -- Check if file exists locally
    local f = io.open(output_path, "r")
    if f then
        f:close()
        print("[preload] File exists, swapping immediately.")
        perform_swap(url, output_path)
        
        try_cleanup()
        is_busy = false
        process_queue()
        return
    end

    local args = { "yt-dlp" }
    if is_trusted_url(url) then table.insert(args, "--compat-options=allow-unsafe-ext") end
    table.insert(args, "--no-part")
    table.insert(args, "--no-playlist")
    table.insert(args, "-f"); table.insert(args, opts.format)
    table.insert(args, "-o"); table.insert(args, output_path)
    if opts.ytdl_opt1 ~= "" then table.insert(args, opts.ytdl_opt1) end
    if opts.ytdl_opt2 ~= "" then table.insert(args, opts.ytdl_opt2) end
    table.insert(args, url)

    print("[preload] Downloading: " .. url)
    
    mp.command_native_async({
        name = "subprocess",
        args = args,
        playback_only = false,
        capture_stderr = true
    }, function(success, result)
        if success and result.status == 0 then
            print("[preload] Finished: " .. safe_name)
            perform_swap(url, output_path)
        else
            print("[preload] FAILED: " .. url)
        end
        
        queued_status[url] = nil
        try_cleanup() -- Trigger cleanup after every download
        is_busy = false
        process_queue() -- Start next
    end)
end

process_queue = function()
    if is_busy then return end
    if #download_queue == 0 then return end
    
    local next_url = table.remove(download_queue, 1)
    is_busy = true
    download_task(next_url)
end

-- QUEUE FEEDER
local function check_preload()
    local current = tonumber(mp.get_property("playlist-pos"))
    -- Skip first file (index 0) if nothing is playing
    if not current or current < 0 then current = 0 end
    
    local count = tonumber(mp.get_property("playlist-count"))
    if not count or count == 0 then return end

    -- Look ahead
    for i = 1, preload_limit do
        local target_idx = current + i
        if target_idx >= count then break end

        local url = mp.get_property("playlist/" .. target_idx .. "/filename")
        
        if url and url:find("://") and not queued_status[url] then
            print("[preload] Adding to queue: " .. url)
            table.insert(download_queue, url)
            queued_status[url] = true
        end
    end
    
    process_queue()
end

local function on_file_change()
    try_cleanup()
    check_preload()
end

local function cleanup_all()
    if package.config:sub(1, 1) == "\\" then
        os.execute('del /Q "' .. cache_path .. '\\preload-*.mkv" 2>nul')
    else
        os.execute('rm -f "' .. cache_path .. '/preload-*.mkv"')
    end
end

-- EVENTS
mp.register_event("start-file", on_file_change)
mp.observe_property("playlist-count", "number", check_preload)
mp.register_event("shutdown", cleanup_all)
