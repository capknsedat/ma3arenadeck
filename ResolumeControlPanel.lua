-- Plugin: ResolumeControlPanel (Resolume composition grid for grandMA3)
-- Based on MA3ArenaDeck by Simon Kotting.
-- Copyright (c) 2026 Simon Kotting — MIT License (see LICENSE)
-- Fetches the current Resolume composition, builds a layout grid, imports
-- clip thumbnails as Images/Appearances, and can poll connected state to
-- highlight currently running clips.
--
-- Arguments:
--   (none)/setup - setup dialog, then sync
--   sync         - full sync (no dialog; used by SYNC button)
--   monitor      - start status polling / highlight loop
--   stop         - stop status polling
--   interval     - cycle poll interval
--   trigtoggle   - enable/disable tap-to-trigger clips
--   trigger L C  - fire Resolume clip at layer/column (from clip macros)
--
-- Layout buttons (macros) under the clip grid:
--   SYNC | POLL ON | POLL OFF | POLL xs | TRIG ON/OFF
--
-- API: GET http://<host>:<port>/api/v1/composition
--      POST .../layers/{L}/clips/{C}/connect  (when trigger mode is on)

local pluginName = select(1, ...)
local componentName = select(2, ...)
local signalTable = select(3, ...)
local myHandle = select(4, ...)

-- Bump when changing runtime behavior so System Monitor proves the reload.
local PLUGIN_VERSION = "2026-10-05v"

------------------------------------------------------------------------
-- Configuration (defaults; overridden by GlobalVars / setup dialog)
------------------------------------------------------------------------
local CFG_PREFIX = "ResArena_"
local MONITOR_VAR = CFG_PREFIX .. "Monitor"
local MONITOR_OWNER_VAR = CFG_PREFIX .. "MonitorOwner"
local INTERVAL_VAR = CFG_PREFIX .. "PollInterval"
local TRIGGER_VAR = CFG_PREFIX .. "Trigger"
-- Clip taps queue "L,C" here; the poll loop fires Resolume (no Plugin call).
local FIRE_VAR = CFG_PREFIX .. "Fire"
-- Layer / composition control taps (clear, bypass, fader steps) append
-- ";action" here; the poll loop sends them to Resolume.
local ACTION_VAR = CFG_PREFIX .. "Action"

local RESOLUME_HOST = "127.0.0.1"
local RESOLUME_PORT = 8080

local ONLY_WITH_THUMBNAIL = false

local LAYOUT_INDEX = 1
local LAYOUT_NAME = "ResolumeControlPanel"

local CELL_WIDTH = 160
local CELL_HEIGHT = 90
local CELL_GAP_X = 10
local CELL_GAP_Y = 10
local LABEL_WIDTH = 140
local ORIGIN_X = 0
local ORIGIN_Y = 0

local SHOW_LAYER_LABELS = true

local FETCH_THUMBNAILS = true
local IMAGE_POOL = 3
local IMAGE_START_INDEX = 200
local APPEARANCE_START_INDEX = 200
local MAX_MEDIA_SLOTS = 300
local IMAGE_NAME_PREFIX = "Res_"
local APPEARANCE_IDLE_PREFIX = "Res_"
local APPEARANCE_PLAY_PREFIX = "ResP_"

-- Status polling
local POLL_INTERVAL_SEC = 0.25
local POLL_INTERVAL_OPTIONS = { 0.10, 0.25, 0.50, 1.00, 2.00 }
-- While waiting between polls, check for queued layout taps this often.
local FIRE_CHECK_SEC = 0.03
local HIGHLIGHT_PREVIEWING = false -- also highlight "Previewing" clips
local PLAYING_BORDER_SIZE = 14
local IDLE_BORDER_SIZE = 7
local LAYER_BORDER_SIZE = 6
-- Clip frame colors (0-255): idle black, active/playing red
local PLAYING_BORDER_R = 255
local PLAYING_BORDER_G = 0
local PLAYING_BORDER_B = 0
local IDLE_BORDER_R = 0
local IDLE_BORDER_G = 0
local IDLE_BORDER_B = 0
-- Layer / COMPOSITION header frames: black like idle clips
local LAYER_BORDER_R = 0
local LAYER_BORDER_G = 0
local LAYER_BORDER_B = 0

-- Macros start at the setup dialog's Macro Start (lc.MACRO_START): each is
-- found by its own name from there on, else written to the next empty slot
-- (see lc.macro_slot). A used slot is never overwritten.
local BUTTON_WIDTH = 128
local BUTTON_HEIGHT = 60
local BUTTON_GAP = 12
-- Extra offset below layer-1 row so controls never sit on the clip grid
local BUTTON_ROW_OFFSET = 40

-- Helpers / settings for layer controls and border colours live in one
-- table: the main chunk is at the 200-local limit.
local lc = {}
lc.MACRO_START = 300
-- Resolume gone (closed / unreachable): after this many polls in a row
-- without any answer, POLL stops by itself instead of retrying forever.
lc.OFFLINE_STOP_AFTER = 3
-- Pause after a failed poll, so a dead connection is not hammered.
lc.OFFLINE_RETRY_SEC = 1.0

--- True when no HTTP answer came back at all (connection refused, timeout,
--- closed): Resolume is not running or not reachable.
function lc.is_conn_error(err)
    return type(err) == "string" and err:find("^HTTP request failed") ~= nil
end
-- clip id -> playing as last drawn by this monitor (so a redraw only
-- happens on a real change, independent of reading the note back).
lc.play_cache = {}
-- layer -> next column position to probe when nothing is known to play there.
lc.scan_cursor = {}
-- Clip slots probed per layer per poll when no clip is known to play there.
lc.SCAN_PER_TICK = 2

-- Scene recorder: REC n records clip / X / B taps with their timing,
-- PLAY n loops them until PLAY n is tapped again.
lc.SCENE_COUNT = 5
lc.SCENE_VAR = CFG_PREFIX .. "Scene"
lc.rec = nil -- { slot, start, events }
lc.play = nil -- { slot, start, length, events, i }

-- Layer / composition controls left of the layer labels:
--   [X] [M] [A] [V]   (one row per layer)
--   [X] [B] [GM]      (composition row above the top layer)
-- M / A / V / GM show the level; tapping one opens a fader popup.
lc.SHOW_LAYER_CONTROLS = true
lc.FADER_BTN_WIDTH = 70
lc.FADER_GAP = 14
lc.CTRL_BTN_WIDTH = 70
lc.LEVEL_COLOR = {
    master = { r = 200, g = 200, b = 200 },
    audio = { r = 230, g = 80, b = 140 },
    video = { r = 80, g = 210, b = 140 },
    off = { r = 45, g = 45, b = 50 },
    clear = { r = 120, g = 30, b = 30 },
    bypass_on = { r = 255, g = 0, b = 0 },
    bypass_off = { r = 70, g = 70, b = 75 },
}

-- Control button colors (active = currently selected mode)
local CTRL_COLOR = {
    sync = { r = 70, g = 90, b = 140 },
    -- Poll enabled: POLL ON = cyan, POLL OFF = dim
    poll_on_active = { r = 0, g = 220, b = 255 },
    poll_on_idle = { r = 55, g = 55, b = 60 },
    -- Poll disabled: POLL OFF = white, POLL ON = dim
    poll_off_active = { r = 255, g = 255, b = 255 },
    poll_off_idle = { r = 55, g = 55, b = 60 },
    interval = { r = 40, g = 130, b = 200 },
    -- Trigger mode: amber when taps fire clips
    trigger_active = { r = 255, g = 170, b = 0 },
    trigger_idle = { r = 55, g = 55, b = 60 },
    -- Scene recorder: REC red while recording, PLAY green while looping
    rec_active = { r = 255, g = 0, b = 0 },
    rec_idle = { r = 110, g = 30, b = 30 },
    play_active = { r = 0, g = 220, b = 80 },
    play_idle = { r = 30, g = 90, b = 50 },
}

------------------------------------------------------------------------
-- Lazy module load
------------------------------------------------------------------------
local http, ltn12, json

local function ensure_deps()
    if http and ltn12 and json then
        return true
    end

    local ok_http, mod_http = pcall(require, "http")
    local ok_ltn12, mod_ltn12 = pcall(require, "ltn12")
    local ok_json, mod_json = pcall(require, "json")

    if not (ok_http and ok_ltn12 and ok_json) then
        Printf(
            "ResolumeControlPanel ERROR: missing Lua modules (http=%s, ltn12=%s, json=%s)",
            tostring(ok_http),
            tostring(ok_ltn12),
            tostring(ok_json)
        )
        return false
    end

    http = mod_http
    ltn12 = mod_ltn12
    json = mod_json
    return true
end

------------------------------------------------------------------------
-- Persisted config (GlobalVars) + setup dialog
------------------------------------------------------------------------

local function cfg_get(key, default)
    local ok, v = pcall(function()
        return GetVar(GlobalVars(), CFG_PREFIX .. key)
    end)
    if not ok or v == nil or v == "" then
        return default
    end
    return v
end

local function cfg_set(key, value)
    pcall(function()
        SetVar(GlobalVars(), CFG_PREFIX .. key, value)
    end)
end

local function cfg_get_bool(key, default)
    local v = cfg_get(key, default and "1" or "0")
    if v == true or v == 1 or v == "1" or v == "true" or v == "True" then
        return true
    end
    if v == false or v == 0 or v == "0" or v == "false" or v == "False" then
        return false
    end
    return default and true or false
end

local function nearest_poll_interval(value)
    local n = tonumber(value) or POLL_INTERVAL_SEC
    local best = POLL_INTERVAL_OPTIONS[1]
    local best_d = math.abs(best - n)
    for _, opt in ipairs(POLL_INTERVAL_OPTIONS) do
        local d = math.abs(opt - n)
        if d < best_d then
            best = opt
            best_d = d
        end
    end
    return best
end

local function get_poll_interval()
    return nearest_poll_interval(cfg_get("PollInterval", POLL_INTERVAL_SEC))
end

local function set_poll_interval(sec)
    local value = nearest_poll_interval(sec)
    POLL_INTERVAL_SEC = value
    cfg_set("PollInterval", string.format("%.2f", value))
    return value
end

local function load_config()
    RESOLUME_HOST = tostring(cfg_get("Host", RESOLUME_HOST))
    RESOLUME_PORT = tonumber(cfg_get("Port", RESOLUME_PORT)) or RESOLUME_PORT
    LAYOUT_INDEX = tonumber(cfg_get("LayoutIndex", LAYOUT_INDEX)) or LAYOUT_INDEX
    LAYOUT_NAME = tostring(cfg_get("LayoutName", LAYOUT_NAME))
    IMAGE_START_INDEX = tonumber(cfg_get("ImageStart", IMAGE_START_INDEX)) or IMAGE_START_INDEX
    APPEARANCE_START_INDEX = tonumber(cfg_get("AppearanceStart", APPEARANCE_START_INDEX))
        or APPEARANCE_START_INDEX
    lc.MACRO_START = math.max(1, math.floor(tonumber(cfg_get("MacroStart", lc.MACRO_START)) or lc.MACRO_START))
    ONLY_WITH_THUMBNAIL = cfg_get_bool("OnlyWithThumbnail", ONLY_WITH_THUMBNAIL)
    FETCH_THUMBNAILS = cfg_get_bool("FetchThumbnails", FETCH_THUMBNAILS)
    HIGHLIGHT_PREVIEWING = cfg_get_bool("HighlightPreviewing", HIGHLIGHT_PREVIEWING)
    POLL_INTERVAL_SEC = get_poll_interval()
end

local function save_config()
    cfg_set("Host", RESOLUME_HOST)
    cfg_set("Port", tostring(RESOLUME_PORT))
    cfg_set("LayoutIndex", tostring(LAYOUT_INDEX))
    cfg_set("LayoutName", LAYOUT_NAME)
    cfg_set("ImageStart", tostring(IMAGE_START_INDEX))
    cfg_set("AppearanceStart", tostring(APPEARANCE_START_INDEX))
    cfg_set("MacroStart", tostring(lc.MACRO_START))
    cfg_set("OnlyWithThumbnail", ONLY_WITH_THUMBNAIL and "1" or "0")
    cfg_set("FetchThumbnails", FETCH_THUMBNAILS and "1" or "0")
    cfg_set("HighlightPreviewing", HIGHLIGHT_PREVIEWING and "1" or "0")
    set_poll_interval(POLL_INTERVAL_SEC)
end

local function mb_input(result, name, default)
    if type(result) ~= "table" then
        return default
    end
    local inputs = result.inputs or result
    local v = inputs[name]
    if v == nil or v == "" then
        return default
    end
    return v
end

local function mb_state(result, name, default)
    if type(result) ~= "table" then
        return default
    end
    local states = result.states or result
    local v = states[name]
    if v == nil then
        return default
    end
    return v and true or false
end

--- Setup UI when launched from the plugin pool (no argument).
--- Returns: "sync" | "save" | "cancel"
local function show_setup_dialog(display_handle)
    load_config()
    Printf("ResolumeControlPanel: opening setup dialog...")

    local options = {
        title = "ResolumeControlPanel",
        message = "Set Resolume host/port and MA3 pool slots, then Sync.\n\n"
            .. "Note: Resolume's default webserver port is 8080, which grandMA3 "
            .. "also uses by default. If both run on the same machine, change "
            .. "Resolume's port (e.g. 8090) and enter that port here.",
        autoCloseOnInput = false,
        commands = {
            { value = 1, name = "Sync" },
            { value = 2, name = "Save Only" },
            { value = 0, name = "Cancel" },
        },
        inputs = {
            { name = "01 Host", value = tostring(RESOLUME_HOST) },
            {
                name = "02 Port",
                value = tostring(RESOLUME_PORT),
                whiteFilter = "0123456789",
                vkPlugin = "TextInputNumOnly",
            },
            {
                name = "03 Layout Index",
                value = tostring(LAYOUT_INDEX),
                whiteFilter = "0123456789",
                vkPlugin = "TextInputNumOnly",
            },
            { name = "04 Layout Name", value = tostring(LAYOUT_NAME) },
            {
                name = "05 Image Start",
                value = tostring(IMAGE_START_INDEX),
                whiteFilter = "0123456789",
                vkPlugin = "TextInputNumOnly",
            },
            {
                name = "06 Appearance Start",
                value = tostring(APPEARANCE_START_INDEX),
                whiteFilter = "0123456789",
                vkPlugin = "TextInputNumOnly",
            },
            {
                name = "07 Macro Start",
                value = tostring(lc.MACRO_START),
                whiteFilter = "0123456789",
                vkPlugin = "TextInputNumOnly",
            },
            {
                name = "08 Poll Interval (s)",
                value = string.format("%.2f", get_poll_interval()),
                whiteFilter = "0123456789.",
                vkPlugin = "TextInputNumOnly",
            },
        },
        states = {
            { name = "Fetch thumbnails", state = FETCH_THUMBNAILS and true or false },
            { name = "Only clips with thumbnail", state = ONLY_WITH_THUMBNAIL and true or false },
            { name = "Highlight previewing", state = HIGHLIGHT_PREVIEWING and true or false },
        },
    }

    -- Only pass display when it looks valid; a bad handle can suppress the popup.
    if display_handle ~= nil then
        options.display = display_handle
    end

    local ok, result = pcall(MessageBox, options)
    if not ok then
        Printf("ResolumeControlPanel: MessageBox failed: %s", tostring(result))
        -- Retry with a minimal dialog (some builds dislike states/inputs combo).
        ok, result = pcall(MessageBox, {
            title = "ResolumeControlPanel",
            message = string.format(
                "Host=%s  Port=%d  Layout=%d\nEdit values in code/GlobalVars if this dialog is limited.\n\nContinue with Sync?",
                RESOLUME_HOST,
                RESOLUME_PORT,
                LAYOUT_INDEX
            ),
            commands = {
                { value = 1, name = "Sync" },
                { value = 0, name = "Cancel" },
            },
        })
        if not ok or type(result) ~= "table" then
            Printf("ResolumeControlPanel: setup dialog unavailable")
            return "cancel"
        end
        local cmd = tonumber(result.result)
        if cmd == nil and type(result.result) == "string" then
            cmd = (result.result:lower() == "sync") and 1 or 0
        end
        if (cmd or 0) == 1 then
            return "sync"
        end
        return "cancel"
    end

    if type(result) ~= "table" then
        Printf("ResolumeControlPanel: MessageBox returned %s", type(result))
        return "cancel"
    end
    if result.success == false then
        Printf("ResolumeControlPanel: setup cancelled")
        return "cancel"
    end

    local cmd = tonumber(result.result)
    if cmd == nil and type(result.result) == "string" then
        local r = result.result:lower()
        if r == "sync" then
            cmd = 1
        elseif r == "save only" or r == "save" then
            cmd = 2
        else
            cmd = 0
        end
    end
    cmd = cmd or 0
    if cmd == 0 then
        Printf("ResolumeControlPanel: setup cancelled")
        return "cancel"
    end

    RESOLUME_HOST = tostring(mb_input(result, "01 Host", RESOLUME_HOST))
    RESOLUME_PORT = tonumber(mb_input(result, "02 Port", RESOLUME_PORT)) or RESOLUME_PORT
    LAYOUT_INDEX = tonumber(mb_input(result, "03 Layout Index", LAYOUT_INDEX)) or LAYOUT_INDEX
    LAYOUT_NAME = tostring(mb_input(result, "04 Layout Name", LAYOUT_NAME))
    IMAGE_START_INDEX = tonumber(mb_input(result, "05 Image Start", IMAGE_START_INDEX))
        or IMAGE_START_INDEX
    APPEARANCE_START_INDEX = tonumber(mb_input(result, "06 Appearance Start", APPEARANCE_START_INDEX))
        or APPEARANCE_START_INDEX
    lc.MACRO_START = math.max(1, math.floor(tonumber(mb_input(result, "07 Macro Start", lc.MACRO_START))
        or lc.MACRO_START))
    POLL_INTERVAL_SEC = nearest_poll_interval(
        mb_input(result, "08 Poll Interval (s)", POLL_INTERVAL_SEC)
    )
    FETCH_THUMBNAILS = mb_state(result, "Fetch thumbnails", FETCH_THUMBNAILS)
    ONLY_WITH_THUMBNAIL = mb_state(result, "Only clips with thumbnail", ONLY_WITH_THUMBNAIL)
    HIGHLIGHT_PREVIEWING = mb_state(result, "Highlight previewing", HIGHLIGHT_PREVIEWING)

    save_config()
    Printf(
        "ResolumeControlPanel: config saved (%s:%d, Layout %d, poll %.2fs)",
        RESOLUME_HOST,
        RESOLUME_PORT,
        LAYOUT_INDEX,
        POLL_INTERVAL_SEC
    )

    if cmd == 2 then
        return "save"
    end
    return "sync"
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function param_value(param, default)
    if param == nil then
        return default
    end
    if type(param) == "table" then
        if param.value ~= nil then
            return param.value
        end
        return default
    end
    return param
end

local function http_get(url, accept, timeout_sec, keep_alive)
    local previous_timeout = http.TIMEOUT
    if timeout_sec ~= nil then
        http.TIMEOUT = timeout_sec
    end

    local body = {}
    local ok, code, _headers, status = http.request({
        url = url,
        method = "GET",
        headers = {
            ["Accept"] = accept or "application/json",
            ["Connection"] = keep_alive and "keep-alive" or "close",
        },
        sink = ltn12.sink.table(body),
    })

    if previous_timeout ~= nil then
        http.TIMEOUT = previous_timeout
    end

    if not ok then
        return nil, string.format("HTTP request failed: %s", tostring(code))
    end

    local status_code = tonumber(code)
    if status_code ~= 200 then
        return nil, string.format("HTTP %s (%s)", tostring(code), tostring(status))
    end

    return table.concat(body), nil
end

local function composition_url()
    return string.format("http://%s:%d/api/v1/composition", RESOLUME_HOST, RESOLUME_PORT)
end

local function layer_url(layer_index)
    return string.format(
        "http://%s:%d/api/v1/composition/layers/%d",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tonumber(layer_index) or 1
    )
end

local function clip_slot_url(layer_index, column_index)
    return string.format(
        "http://%s:%d/api/v1/composition/layers/%d/clips/%d",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tonumber(layer_index) or 1,
        tonumber(column_index) or 1
    )
end

local function clip_by_id_url(clip_id)
    return string.format(
        "http://%s:%d/api/v1/composition/clips/by-id/%s",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tostring(clip_id)
    )
end

local function clip_connect_url(layer_index, column_index)
    return string.format(
        "http://%s:%d/api/v1/composition/layers/%d/clips/%d/connect",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tonumber(layer_index) or 1,
        tonumber(column_index) or 1
    )
end

local function clip_connect_by_id_url(clip_id)
    return string.format(
        "http://%s:%d/api/v1/composition/clips/by-id/%s/connect",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tostring(clip_id)
    )
end

--- POST with optional body. Treats 2xx (incl. 204) as success.
local function http_post(url, body, timeout_sec)
    local previous_timeout = http.TIMEOUT
    if timeout_sec ~= nil then
        http.TIMEOUT = timeout_sec
    end

    body = body or ""
    local response = {}
    local ok, code, _headers, status = http.request({
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["Connection"] = "close",
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    })

    if previous_timeout ~= nil then
        http.TIMEOUT = previous_timeout
    end

    if not ok then
        return nil, string.format("HTTP POST failed: %s", tostring(code))
    end

    local status_code = tonumber(code) or 0
    -- Resolume connect often returns 204 No Content.
    if status_code < 200 or status_code >= 300 then
        return nil, string.format("HTTP %s (%s)", tostring(code), tostring(status))
    end

    return true, nil
end

--- PUT a JSON body (Resolume parameter updates). Treats 2xx as success.
function lc.http_put(url, body, timeout_sec)
    local previous_timeout = http.TIMEOUT
    if timeout_sec ~= nil then
        http.TIMEOUT = timeout_sec
    end

    body = body or ""
    local response = {}
    local ok, code, _headers, status = http.request({
        url = url,
        method = "PUT",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["Connection"] = "close",
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    })

    if previous_timeout ~= nil then
        http.TIMEOUT = previous_timeout
    end

    if not ok then
        return nil, string.format("HTTP PUT failed: %s", tostring(code))
    end
    local status_code = tonumber(code) or 0
    if status_code < 200 or status_code >= 300 then
        return nil, string.format("HTTP %s (%s)", tostring(code), tostring(status))
    end
    return true, nil
end

function lc.layer_clear_url(layer_index)
    return string.format(
        "http://%s:%d/api/v1/composition/layers/%d/clear",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tonumber(layer_index) or 1
    )
end

function lc.disconnect_all_url()
    return string.format(
        "http://%s:%d/api/v1/composition/disconnect-all",
        RESOLUME_HOST,
        RESOLUME_PORT
    )
end

local function thumbnail_url(clip)
    if type(clip.thumbnail_path) == "string" and clip.thumbnail_path ~= "" then
        if clip.thumbnail_path:sub(1, 1) == "/" then
            return string.format("http://%s:%d%s", RESOLUME_HOST, RESOLUME_PORT, clip.thumbnail_path)
        end
        return clip.thumbnail_path
    end
    return string.format(
        "http://%s:%d/api/v1/composition/clips/by-id/%s/thumbnail",
        RESOLUME_HOST,
        RESOLUME_PORT,
        tostring(clip.id)
    )
end

local function clip_is_available(clip)
    if type(clip) ~= "table" then
        return false
    end

    local thumbnail = clip.thumbnail
    if type(thumbnail) == "table" and thumbnail.is_default == false then
        return true
    end

    if ONLY_WITH_THUMBNAIL then
        return false
    end

    return clip.video ~= nil or clip.audio ~= nil
end

local function clip_media_path(clip)
    local video = clip.video
    if type(video) == "table" and type(video.fileinfo) == "table" then
        return video.fileinfo.path
    end
    local audio = clip.audio
    if type(audio) == "table" and type(audio.fileinfo) == "table" then
        return audio.fileinfo.path
    end
    return nil
end

local function is_playing_state(state)
    if state == "Connected" or state == "Connected & previewing" then
        return true
    end
    if HIGHLIGHT_PREVIEWING and state == "Previewing" then
        return true
    end
    return false
end

local function collect_clips(composition)
    local clips = {}
    local layers_meta = {}
    local layers = composition.layers or {}
    local max_column = 0

    for layer_index, layer in ipairs(layers) do
        local layer_name = param_value(layer.name, string.format("Layer %d", layer_index))
        local layer_clips = layer.clips or {}
        local filled = 0

        if #layer_clips > max_column then
            max_column = #layer_clips
        end

        for column_index, clip in ipairs(layer_clips) do
            if clip_is_available(clip) then
                filled = filled + 1
                if column_index > max_column then
                    max_column = column_index
                end
                local thumbnail = clip.thumbnail or {}
                clips[#clips + 1] = {
                    layer = layer_index,
                    column = column_index,
                    layer_name = layer_name,
                    layer_id = layer.id,
                    id = clip.id,
                    name = param_value(clip.name, ""),
                    connected = param_value(clip.connected, "Disconnected"),
                    selected = param_value(clip.selected, false),
                    media_path = clip_media_path(clip),
                    thumbnail_path = thumbnail.path,
                    has_thumbnail = thumbnail.is_default == false,
                    thumbnail_update = thumbnail.last_update,
                }
            end
        end

        local video = type(layer.video) == "table" and layer.video or {}
        local audio = type(layer.audio) == "table" and layer.audio or {}
        layers_meta[#layers_meta + 1] = {
            index = layer_index,
            id = layer.id,
            name = layer_name,
            filled = filled,
            columns = #layer_clips,
            master = tonumber(param_value(layer.master, 1)) or 1,
            opacity = tonumber(param_value(video.opacity, 1)) or 1,
            volume = type(audio.volume) == "table" and audio.volume or nil,
        }
    end

    local used_max = 0
    for _, clip in ipairs(clips) do
        if clip.column > used_max then
            used_max = clip.column
        end
    end
    if used_max > 0 then
        max_column = used_max
    end

    return clips, {
        layers = layers_meta,
        layer_count = #layers_meta,
        max_column = max_column,
        master = tonumber(param_value(composition.master, 1)) or 1,
        bypassed = param_value(composition.bypassed, false) == true,
    }
end

local function fetch_composition(timeout_sec)
    local raw, err = http_get(composition_url(), "application/json", timeout_sec)
    if not raw then
        return nil, err
    end

    local ok, composition = pcall(json.decode, raw)
    if not ok or type(composition) ~= "table" then
        return nil, "Failed to decode composition JSON"
    end
    return composition, nil, raw and #raw or 0
end

local function fetch_available_clips()
    local composition, err = fetch_composition(10)
    if not composition then
        return nil, err
    end
    local clips, grid = collect_clips(composition)
    return clips, nil, composition, grid
end

--- id(string) -> connected state string
local function collect_connected_states(composition)
    local states = {}
    for _, layer in ipairs(composition.layers or {}) do
        for _, clip in ipairs(layer.clips or {}) do
            if clip.id ~= nil then
                states[tostring(clip.id)] = param_value(clip.connected, "Disconnected")
            end
        end
    end
    return states
end

local function fetch_clip_connected_state(meta, timeout_sec)
    -- Connection: close on purpose. LuaSocket never reuses the socket, and a
    -- keep-alive reply without a usable length is read until the timeout.
    local raw, err
    if meta.layer and meta.layer > 0 and meta.column and meta.column > 0 then
        raw, err = http_get(
            clip_slot_url(meta.layer, meta.column),
            "application/json",
            timeout_sec or 1.0
        )
    end
    if not raw and not lc.is_conn_error(err) then
        raw, err = http_get(
            clip_by_id_url(meta.id),
            "application/json",
            timeout_sec or 1.0
        )
    end
    if not raw then
        return nil, err, 0
    end
    local ok, clip = pcall(json.decode, raw)
    if not ok or type(clip) ~= "table" then
        return nil, "Failed to decode clip JSON", #raw
    end
    return param_value(clip.connected, "Disconnected"), nil, #raw
end

--- Fast poll: one small request per clip slot.
--- Only one clip per Resolume layer can be Connected, so once we find it we
--- mark the rest of that layer Disconnected without more HTTP calls.
--- Previously-playing clips are checked first (usually 1 request/layer).
--- should_abort (optional) runs before every request; returning true stops the
--- scan so a queued layout tap is not stuck behind dozens of GETs.
local POLL_ABORTED = "poll aborted"

local function collect_connected_states_by_clips(clip_metas, timeout_sec, should_abort)
    local by_layer = {}
    local no_layer = {}
    for _, meta in ipairs(clip_metas) do
        if meta.layer and meta.layer > 0 then
            by_layer[meta.layer] = by_layer[meta.layer] or {}
            local list = by_layer[meta.layer]
            list[#list + 1] = meta
        else
            no_layer[#no_layer + 1] = meta
        end
    end

    local states = {}
    local bytes = 0
    local requests = 0
    local failures = 0
    local last_err = nil

    -- One bad slot must not fail the whole poll (that used to drop into the
    -- multi-second layer/composition fallbacks). Keep its last known state.
    local function check_meta(meta)
        if should_abort and should_abort() then
            return nil, POLL_ABORTED
        end
        requests = requests + 1
        local state, err, n = fetch_clip_connected_state(meta, timeout_sec)
        bytes = bytes + (n or 0)
        if not state then
            failures = failures + 1
            last_err = err
            if lc.is_conn_error(err) then
                -- No answer at all: Resolume is gone, so skip the rest of
                -- this scan instead of waiting on every clip in turn.
                return nil, err
            end
            state = meta.playing and "Connected" or "Disconnected"
        end
        states[tostring(meta.id)] = state
        return state, nil
    end

    -- Per layer: confirm the clip(s) we believe are playing (1 request).
    -- Only when nothing plays there, probe a few other slots round-robin
    -- instead of every slot each poll; a full scan of all clips every
    -- 0.1 s kept MA3 busy and made the layout feel like it kept reloading.
    -- Only one clip per Resolume layer can be Connected.
    for layer, metas in pairs(by_layer) do
        table.sort(metas, function(a, b)
            return (a.column or 0) < (b.column or 0)
        end)
        for _, meta in ipairs(metas) do
            states[tostring(meta.id)] = "Disconnected"
        end

        local connected = false
        for _, meta in ipairs(metas) do
            if meta.playing and not connected then
                local state, err = check_meta(meta)
                if not state then
                    return nil, err, bytes, requests
                end
                connected = is_playing_state(state)
            end
        end

        if not connected and #metas > 0 then
            local cursor = lc.scan_cursor[layer] or 1
            local probes = math.min(lc.SCAN_PER_TICK, #metas)
            for _ = 1, probes do
                if cursor > #metas then
                    cursor = 1
                end
                local meta = metas[cursor]
                cursor = cursor + 1
                if not meta.playing then
                    local state, err = check_meta(meta)
                    if not state then
                        return nil, err, bytes, requests
                    end
                    if is_playing_state(state) then
                        break
                    end
                end
            end
            lc.scan_cursor[layer] = cursor
        end
    end

    for _, meta in ipairs(no_layer) do
        local state, err = check_meta(meta)
        if not state then
            return nil, err, bytes, requests
        end
    end

    if requests > 0 and failures == requests then
        return nil, last_err, bytes, requests
    end

    return states, nil, bytes, requests
end

------------------------------------------------------------------------
-- File helpers
------------------------------------------------------------------------

local function ensure_dir(path)
    pcall(function()
        os.execute(string.format('mkdir -p "%s"', path))
    end)
end

local function write_binary_file(path, data)
    local file, err = io.open(path, "wb")
    if not file then
        return false, err or "open failed"
    end
    file:write(data)
    file:close()
    return true
end

local function write_text_file(path, text)
    local file, err = io.open(path, "w")
    if not file then
        return false, err or "open failed"
    end
    file:write(text)
    file:close()
    return true
end

local function images_library_path()
    local path = nil
    if Enums and Enums.PathType and Enums.PathType.UserImageLibrary then
        path = GetPath(Enums.PathType.UserImageLibrary, true)
    end
    if path == nil or path == "" then
        path = GetPath("gma3_library/media/images", true)
    end
    return path
end

local function path_join(a, b)
    local sep = "/"
    if GetPathSeparator then
        sep = GetPathSeparator()
    end
    if a:sub(-1) == "/" or a:sub(-1) == "\\" then
        return a .. b
    end
    return a .. sep .. b
end

------------------------------------------------------------------------
-- Image + Appearance pool management
------------------------------------------------------------------------

local function get_images_pool()
    return ShowData().MediaPools.Images
end

local function get_appearances_pool()
    return ShowData().Appearances
end

local function object_name(obj)
    if obj == nil then
        return nil
    end
    local ok, name = pcall(function()
        return obj.Name or obj.name
    end)
    if ok then
        return name
    end
    return nil
end

local function pool_object_valid(obj)
    if obj == nil then
        return false
    end
    if IsObjectValid then
        local ok, valid = pcall(IsObjectValid, obj)
        if ok then
            return valid and true or false
        end
    end
    return true
end

--- Fresh shows only initialize a small pool range. Create(index) beyond
--- Count() silently fails (nil). Resize first, then Create.
local function ensure_pool_object(pool, index)
    if pool == nil then
        return nil
    end
    index = tonumber(index)
    if index == nil or index < 1 then
        return nil
    end

    if pool_object_valid(pool[index]) then
        return pool[index]
    end

    pcall(function()
        local count = pool:Count()
        if type(count) ~= "number" or index <= count then
            return
        end
        local max_count = nil
        pcall(function()
            max_count = pool:MaxCount()
        end)
        local new_size = math.ceil(index / 1000) * 1000
        if new_size < index then
            new_size = index
        end
        if type(max_count) == "number" and max_count > 0 then
            new_size = math.min(max_count, new_size)
            if index > new_size then
                return
            end
        end
        pool:Resize(new_size)
    end)

    local created = nil
    pcall(function()
        created = pool:Create(index)
    end)
    if pool_object_valid(created) then
        return created
    end
    if pool_object_valid(pool[index]) then
        return pool[index]
    end
    return nil
end

--- Macro-specific create with Cmd("Store Macro N") fallback for empty shows.
local function ensure_macro(index)
    local macros = DataPool().Macros
    if macros == nil then
        return nil
    end
    local macro = ensure_pool_object(macros, index)
    if pool_object_valid(macro) then
        return macro
    end
    pcall(function()
        Cmd(string.format("Store Macro %d /Overwrite", index))
    end)
    if pool_object_valid(macros[index]) then
        return macros[index]
    end
    return nil
end

--- Macro slots by name: one scan of the Macros pool per run, then each
--- plugin macro reuses the slot already carrying its name at or after
--- Macro Start, or takes the next empty slot from Macro Start on. A slot
--- holding any other macro is never touched.
function lc.scan_macro_slots()
    lc.macro_by_name = {}
    lc.macro_used = {}
    lc.macro_next_free = lc.MACRO_START
    local macros = DataPool().Macros
    if macros == nil then
        return
    end
    local count = 0
    pcall(function()
        count = tonumber(macros:Count()) or 0
    end)
    for i = lc.MACRO_START, count do
        local obj = macros[i]
        if pool_object_valid(obj) then
            lc.macro_used[i] = true
            local name = object_name(obj)
            if name ~= nil and lc.macro_by_name[name] == nil then
                lc.macro_by_name[name] = i
            end
        end
    end
end

function lc.macro_slot(name)
    if lc.macro_by_name == nil then
        lc.scan_macro_slots()
    end
    local index = lc.macro_by_name[name]
    if index then
        local obj = DataPool().Macros[index]
        if not pool_object_valid(obj) or object_name(obj) == name then
            return index
        end
    end
    local i = lc.macro_next_free
    while lc.macro_used[i] or pool_object_valid(DataPool().Macros[i]) do
        lc.macro_used[i] = true
        i = i + 1
    end
    lc.macro_used[i] = true
    lc.macro_next_free = i + 1
    lc.macro_by_name[name] = i
    return i
end

local function find_pool_index_by_name(pool, name, start_index, max_slots)
    for i = start_index, start_index + max_slots - 1 do
        local obj = pool[i]
        if pool_object_valid(obj) and object_name(obj) == name then
            return i
        end
    end
    return nil
end

local function find_free_pool_index(pool, start_index, max_slots)
    for i = start_index, start_index + max_slots - 1 do
        if not pool_object_valid(pool[i]) then
            return i
        end
    end
    return nil
end

local function ensure_pool_index(pool, name, start_index, max_slots)
    local existing = find_pool_index_by_name(pool, name, start_index, max_slots)
    if existing then
        return existing
    end
    local free = find_free_pool_index(pool, start_index, max_slots)
    if not free then
        return nil, "No free pool slots left in configured range"
    end
    return free
end

--- Write PNG + .png.xml library descriptor (FileName pointer).
--- This MA3 build accepts: Import Image Library "name.png.xml" At Image …
local function write_image_import_files(clip, png_data)
    local lib = images_library_path()
    if lib == nil or lib == "" then
        return nil, "Could not resolve UserImageLibrary path"
    end
    ensure_dir(lib)

    local base = IMAGE_NAME_PREFIX .. tostring(clip.id)
    local png_name = base .. ".png"
    local sidecar_name = png_name .. ".xml"
    local png_path = path_join(lib, png_name)
    local sidecar_path = path_join(lib, sidecar_name)

    local ok, err = write_binary_file(png_path, png_data)
    if not ok then
        return nil, "Failed to write PNG: " .. tostring(err)
    end

    local sidecar = string.format(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
            .. '<GMA3 DataVersion="2.2.1.1">\n'
            .. '    <UserImage FileName="%s" />\n'
            .. "</GMA3>\n",
        png_name
    )
    ok, err = write_text_file(sidecar_path, sidecar)
    if not ok then
        return nil, "Failed to write PNG XML sidecar: " .. tostring(err)
    end

    return {
        base = base,
        png_name = png_name,
        sidecar_name = sidecar_name,
        lib = lib,
        png_path = png_path,
        sidecar_path = sidecar_path,
        png_bytes = #png_data,
    }
end

local function delete_image_slot(images, image_index)
    if images == nil or image_index == nil then
        return
    end
    if pool_object_valid(images[image_index]) then
        pcall(function()
            images:Delete(image_index)
        end)
    end
    if pool_object_valid(images[image_index]) then
        pcall(function()
            Cmd(string.format("Delete Image %d.%d /NoConfirmation", IMAGE_POOL, image_index))
        end)
    end
end

--- Import via the one path this build accepts without Illegal object spam:
---   Import Image Library "Res_….png.xml" At Image 3.N
--- Do not try embedded Res_….xml library import — that logs Illegal object.
local function try_import_image(images, image_index, files)
    delete_image_slot(images, image_index)

    local image_obj = ensure_pool_object(images, image_index)
    if image_obj == nil then
        pcall(function()
            Cmd(string.format("Store Image %d.%d /Overwrite", IMAGE_POOL, image_index))
        end)
        image_obj = images[image_index]
    end
    if image_obj == nil or not pool_object_valid(image_obj) then
        return nil, "no-slot (pool Resize/Create failed at " .. tostring(image_index) .. ")"
    end

    local ok = pcall(function()
        Cmd(string.format(
            'Import Image Library "%s" At Image %d.%d /NoConfirmation',
            files.sidecar_name,
            IMAGE_POOL,
            image_index
        ))
    end)
    image_obj = images[image_index]
    if ok and pool_object_valid(image_obj) then
        return image_obj, "cmd-import-library-sidecar"
    end

    -- Quiet fallback (no Cmd noise): object API with the same sidecar XML.
    ok = pcall(function()
        image_obj:Import(files.lib, files.sidecar_name)
    end)
    image_obj = images[image_index]
    if ok and pool_object_valid(image_obj) then
        return image_obj, "object-import-sidecar-xml"
    end

    if pool_object_valid(images[image_index]) then
        return images[image_index], "import-failed"
    end
    return nil, "import-failed (slot missing after Import)"
end

local function import_image_to_pool(clip, png_data)
    if type(png_data) ~= "string" or #png_data < 24 or png_data:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        return nil, "invalid PNG payload"
    end

    local files, err = write_image_import_files(clip, png_data)
    if not files then
        return nil, err
    end

    local images = get_images_pool()
    if images == nil then
        return nil, "Images pool not found"
    end

    local image_index, index_err = ensure_pool_index(
        images,
        files.base,
        IMAGE_START_INDEX,
        MAX_MEDIA_SLOTS
    )
    if not image_index then
        return nil, index_err
    end

    local image_obj, method = try_import_image(images, image_index, files)
    if image_obj == nil then
        return nil, tostring(method or ("Image import did not create pool object " .. tostring(image_index)))
    end

    pcall(function()
        image_obj:Set("Name", files.base)
    end)
    pcall(function()
        Cmd(string.format('Label Image %d.%d "%s"', IMAGE_POOL, image_index, files.base))
    end)

    Printf(
        "ResolumeControlPanel: image import Image %d.%d via %s (%d bytes)",
        IMAGE_POOL,
        image_index,
        tostring(method),
        files.png_bytes
    )

    return {
        index = image_index,
        name = files.base,
        handle = image_obj,
    }
end

--- Background colour of a clip appearance (shows around / behind the thumbnail).
local function set_appearance_back(appearance, r, g, b)
    local color01 = string.format("%.3f,%.3f,%.3f,1", r / 255, g / 255, b / 255)
    local props = {
        { "Color", color01 },
        { "BackR", tostring(r) },
        { "BackG", tostring(g) },
        { "BackB", tostring(b) },
        { "BackAlpha", "255" },
        { "BACKR", tostring(r) },
        { "BACKG", tostring(g) },
        { "BACKB", tostring(b) },
    }
    for _, p in ipairs(props) do
        pcall(function()
            appearance:Set(p[1], p[2])
        end)
    end
end

local function style_idle_appearance(appearance)
    set_appearance_back(appearance, IDLE_BORDER_R, IDLE_BORDER_G, IDLE_BORDER_B)
    local props = {
        { "ImageR", "255" },
        { "ImageG", "255" },
        { "ImageB", "255" },
    }
    for _, p in ipairs(props) do
        pcall(function()
            appearance:Set(p[1], p[2])
        end)
    end
end

-- Remember which border-color write works on this console (avoid Cmd spam).
-- nil = not probed yet, false = nothing worked, else index into lc.BORDER_COLOR_WAYS.
local border_color_way = nil
local border_color_logged = false

function lc.color_formats(r, g, b)
    return {
        -- grandMA3 colour properties are 0..1 floats (same as Appearance "Color").
        float = string.format("%.3f,%.3f,%.3f,1", r / 255, g / 255, b / 255),
        int = string.format("%d,%d,%d,255", r, g, b),
        hex = string.format("%02X%02X%02XFF", r, g, b),
    }
end

lc.BORDER_COLOR_WAYS = {
    { prop = "BorderColor", fmt = "float" },
    { prop = "BorderColor", fmt = "hex" },
    { prop = "BorderColor", fmt = "int" },
    { prop = "BORDERCOLOR", fmt = "float" },
    { prop = "BorderColor", fmt = "float", cmd = true },
    { prop = "BorderColor", fmt = "int", cmd = true },
}

function lc.read_element_prop(element, prop)
    local value = nil
    pcall(function()
        value = element:Get(prop)
    end)
    if value == nil then
        pcall(function()
            value = element[prop]
        end)
    end
    if value == nil then
        return nil
    end
    return tostring(value)
end

--- True when a read-back colour string matches the wanted 0-255 RGB.
function lc.color_matches(readback, r, g, b)
    if type(readback) ~= "string" or readback == "" then
        return false
    end
    local want = { r / 255, g / 255, b / 255 }
    local hex = readback:match("^#?(%x%x%x%x%x%x)")
    if hex and not readback:find(",") then
        local got = {
            tonumber(hex:sub(1, 2), 16) / 255,
            tonumber(hex:sub(3, 4), 16) / 255,
            tonumber(hex:sub(5, 6), 16) / 255,
        }
        for i = 1, 3 do
            if math.abs(got[i] - want[i]) > 0.02 then
                return false
            end
        end
        return true
    end
    local nums = {}
    for n in readback:gmatch("[%d%.]+") do
        nums[#nums + 1] = tonumber(n)
    end
    if #nums < 3 then
        return false
    end
    local scale = (nums[1] > 1 or nums[2] > 1 or nums[3] > 1) and 255 or 1
    for i = 1, 3 do
        if math.abs((nums[i] or 0) / scale - want[i]) > 0.02 then
            return false
        end
    end
    return true
end

function lc.write_border_color(element, way, r, g, b)
    local value = lc.color_formats(r, g, b)[way.fmt]
    if way.cmd then
        local idx = nil
        pcall(function()
            idx = element:Index()
        end)
        if not idx then
            return false
        end
        return pcall(function()
            Cmd(string.format(
                'Set Layout %d.%d Property "%s" "%s"',
                LAYOUT_INDEX,
                idx,
                way.prop,
                value
            ))
        end)
    end
    return pcall(function()
        element:Set(way.prop, value)
    end)
end

--- Apply border color on a layout element.
--- The first call probes which property/format the console accepts by
--- reading the value back, and logs the result once to System Monitor.
local function set_element_border_color(element, r, g, b)
    if element == nil then
        return
    end

    if border_color_way then
        lc.write_border_color(element, lc.BORDER_COLOR_WAYS[border_color_way], r, g, b)
        return
    end
    if border_color_way == false then
        return
    end

    local before = lc.read_element_prop(element, "BorderColor")
    for i, way in ipairs(lc.BORDER_COLOR_WAYS) do
        if lc.write_border_color(element, way, r, g, b)
            and lc.color_matches(lc.read_element_prop(element, way.prop), r, g, b)
        then
            border_color_way = i
            Printf(
                "ResolumeControlPanel: border colour via %s (%s) -> '%s'",
                way.prop,
                way.fmt,
                tostring(lc.read_element_prop(element, way.prop))
            )
            return
        end
    end

    -- Nothing verified: keep the float write (most likely format) but say so.
    lc.write_border_color(element, lc.BORDER_COLOR_WAYS[1], r, g, b)
    if not border_color_logged then
        border_color_logged = true
        Printf(
            "ResolumeControlPanel: border colour not confirmed (BorderColor was '%s', now '%s'); using appearance colours",
            tostring(before),
            tostring(lc.read_element_prop(element, "BorderColor"))
        )
    end
    border_color_way = 1
end

local function apply_playing_chrome(element, playing)
    local border = playing and PLAYING_BORDER_SIZE or IDLE_BORDER_SIZE
    pcall(function()
        element:Set("bordersize", tostring(border))
        element:Set("visibilityborder", "Visible")
    end)
    if playing then
        set_element_border_color(element, PLAYING_BORDER_R, PLAYING_BORDER_G, PLAYING_BORDER_B)
    else
        set_element_border_color(element, IDLE_BORDER_R, IDLE_BORDER_G, IDLE_BORDER_B)
    end
end

local function ensure_named_appearance(app_name, image_info, playing)
    local appearances = get_appearances_pool()
    if appearances == nil then
        return nil, "Appearances pool not found"
    end

    local app_index, err = ensure_pool_index(
        appearances,
        app_name,
        APPEARANCE_START_INDEX,
        MAX_MEDIA_SLOTS
    )
    if not app_index then
        return nil, err
    end

    if appearances[app_index] == nil then
        ensure_pool_object(appearances, app_index)
    end

    local appearance = appearances[app_index]
    if appearance == nil or not pool_object_valid(appearance) then
        return nil, "Could not create Appearance " .. tostring(app_index)
    end

    appearance:Set("Name", app_name)
    if image_info then
        Cmd(string.format(
            "Assign Image %d.%d At Appearance %d",
            IMAGE_POOL,
            image_info.index,
            app_index
        ))
    end
    -- Playing vs idle differ only by the red border, not the picture.
    style_idle_appearance(appearance)

    return {
        index = app_index,
        name = app_name,
        handle = appearance,
    }
end

local function ensure_appearances_for_image(image_info, clip_id)
    local idle_name = APPEARANCE_IDLE_PREFIX .. tostring(clip_id)
    local play_name = APPEARANCE_PLAY_PREFIX .. tostring(clip_id)

    local idle, idle_err = ensure_named_appearance(idle_name, image_info, false)
    if not idle then
        return nil, idle_err
    end

    local play, play_err = ensure_named_appearance(play_name, image_info, true)
    if not play then
        return nil, play_err
    end

    return {
        image = image_info,
        appearance_idle = idle,
        appearance_play = play,
    }
end

local function ensure_appearances_without_image(clip_id)
    -- Clips without a thumbnail (e.g. effect / generator clips) get no
    -- appearance at all; an empty one only shows MA3's macro icon.
    -- Remove ones left over from earlier syncs so lookups find nothing.
    local appearances = get_appearances_pool()
    if appearances ~= nil then
        for _, prefix in ipairs({ APPEARANCE_IDLE_PREFIX, APPEARANCE_PLAY_PREFIX }) do
            local name = prefix .. tostring(clip_id)
            local idx = find_pool_index_by_name(appearances, name, APPEARANCE_START_INDEX, MAX_MEDIA_SLOTS)
            if idx then
                lc.delete_appearance(idx)
            end
        end
    end
    return { image = nil }
end

local function lookup_appearances_for_clip(clip_id)
    local appearances = get_appearances_pool()
    if appearances == nil then
        return nil
    end

    local idle_name = APPEARANCE_IDLE_PREFIX .. tostring(clip_id)
    local play_name = APPEARANCE_PLAY_PREFIX .. tostring(clip_id)
    local idle_index = find_pool_index_by_name(appearances, idle_name, APPEARANCE_START_INDEX, MAX_MEDIA_SLOTS)
    local play_index = find_pool_index_by_name(appearances, play_name, APPEARANCE_START_INDEX, MAX_MEDIA_SLOTS)

    if not idle_index and not play_index then
        return nil
    end

    local result = {}
    if idle_index then
        result.appearance_idle = {
            index = idle_index,
            name = idle_name,
            handle = appearances[idle_index],
        }
    end
    if play_index then
        result.appearance_play = {
            index = play_index,
            name = play_name,
            handle = appearances[play_index],
        }
    end
    return result
end

local function sync_clip_thumbnail(clip)
    if not clip.has_thumbnail then
        return ensure_appearances_without_image(clip.id)
    end

    local png, err = http_get(thumbnail_url(clip), "image/png")
    if not png then
        return ensure_appearances_without_image(clip.id)
    end

    if png:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        return ensure_appearances_without_image(clip.id)
    end

    local image_info, image_err = import_image_to_pool(clip, png)
    if not image_info then
        return nil, image_err
    end

    return ensure_appearances_for_image(image_info, clip.id)
end

local function sync_thumbnails(clips)
    local map = {}
    local ok_count = 0
    local skip_count = 0
    local fail_count = 0

    Printf("ResolumeControlPanel: importing thumbnails / appearances...")

    for _, clip in ipairs(clips) do
        local media, err
        if FETCH_THUMBNAILS then
            media, err = sync_clip_thumbnail(clip)
        else
            media, err = ensure_appearances_without_image(clip.id)
        end

        if media then
            map[tostring(clip.id)] = media
            ok_count = ok_count + 1
            if clip.has_thumbnail and media.image then
                Printf(
                    "  thumb OK  L%02d C%03d %-20s -> Image %d.%d / App %d/%d",
                    clip.layer,
                    clip.column,
                    tostring(clip.name),
                    IMAGE_POOL,
                    media.image.index,
                    media.appearance_idle.index,
                    media.appearance_play.index
                )
            else
                skip_count = skip_count + 1
            end
        else
            fail_count = fail_count + 1
            Printf(
                "  thumb FAIL L%02d C%03d %-20s (%s)",
                clip.layer,
                clip.column,
                tostring(clip.name),
                tostring(err)
            )
        end
    end

    Printf(
        "ResolumeControlPanel: media done (ok=%d no-thumb=%d fail=%d)",
        ok_count,
        skip_count,
        fail_count
    )
    return map
end

------------------------------------------------------------------------
-- Plugin address / macros / monitor flag
------------------------------------------------------------------------

local function resolve_plugin_index()
    if myHandle == nil then
        return nil
    end
    -- ComponentLua -> parent UserPlugin
    local ok, parent = pcall(function()
        return myHandle:Parent()
    end)
    if ok and parent ~= nil then
        local idx = nil
        pcall(function()
            idx = parent:Index()
        end)
        if idx then
            return idx
        end
    end
    local idx = nil
    pcall(function()
        idx = myHandle:Index()
    end)
    return idx
end

local function plugin_command(argument)
    local arg = argument or "sync"
    if type(pluginName) == "string" and pluginName ~= "" then
        return string.format('Plugin "%s" "%s"', pluginName, arg)
    end

    local index = resolve_plugin_index()
    if index then
        return string.format('Plugin %d "%s"', index, arg)
    end
    return string.format('Plugin 1 "%s"', arg)
end

local function set_monitor_flag(enabled)
    SetVar(GlobalVars(), MONITOR_VAR, enabled and 1 or 0)
end

local function get_monitor_flag()
    local v = GetVar(GlobalVars(), MONITOR_VAR)
    return tonumber(v) == 1 or v == true or v == "1"
end

local function set_trigger_flag(enabled)
    SetVar(GlobalVars(), TRIGGER_VAR, enabled and 1 or 0)
end

local function get_trigger_flag()
    local v = GetVar(GlobalVars(), TRIGGER_VAR)
    return tonumber(v) == 1 or v == true or v == "1"
end

local function write_macro_lines(macro, macro_index, lines)
    local children = macro:Children()
    for i = #children, 1, -1 do
        macro:Delete(i)
    end

    for line_index, command in ipairs(lines) do
        local line = macro:Acquire()
        if line then
            local set_ok = pcall(function()
                line:Set("Command", command)
            end)
            if not set_ok then
                pcall(function()
                    line.Command = command
                end)
            end
            local got = ""
            pcall(function()
                got = tostring(line.Command or "")
            end)
            if got == "" then
                local escaped = command:gsub('\\', '\\\\'):gsub('"', '\\"')
                pcall(function()
                    Cmd(string.format(
                        'Set Macro %d.%d Property "Command" "%s"',
                        macro_index,
                        line_index,
                        escaped
                    ))
                end)
            end
        end
    end
end

local function ensure_control_macros()
    local macros = DataPool().Macros
    if macros == nil then
        return nil, "Macros pool not found"
    end

    local defs = {
        {
            name = "Res_Sync",
            note = "resolume-ctrl:sync",
            lines = {
                string.format('Lua "SetVar(GlobalVars(), \'%s\', 0)"', MONITOR_VAR),
                "Wait 0.5",
                plugin_command("sync"),
            },
        },
        {
            name = "Res_PollOn",
            note = "resolume-ctrl:monitor",
            lines = {
                plugin_command("monitor"),
            },
        },
        {
            name = "Res_PollOff",
            note = "resolume-ctrl:stop",
            -- Clear flag immediately (interrupts loop), then plugin stop for UI chrome.
            lines = {
                string.format('Lua "SetVar(GlobalVars(), \'%s\', 0)"', MONITOR_VAR),
                plugin_command("stop"),
            },
        },
        {
            name = "Res_Interval",
            note = "resolume-ctrl:interval",
            lines = {
                plugin_command("interval"),
            },
        },
        {
            name = "Res_TrigToggle",
            note = "resolume-ctrl:trigger",
            lines = {
                plugin_command("trigtoggle"),
            },
        },
    }

    for _, def in ipairs(defs) do
        def.index = lc.macro_slot(def.name)
        local macro = ensure_macro(def.index)
        if macro == nil then
            Printf("ResolumeControlPanel: could not create Macro %d '%s'", def.index, def.name)
            return nil, string.format("Could not create Macro %d", def.index)
        end
        macro:Set("Name", def.name)
        write_macro_lines(macro, def.index, def.lines)

        local line_count = 0
        pcall(function()
            line_count = #macro:Children()
        end)
        Printf(
            "ResolumeControlPanel: Macro %d '%s' ready (%d lines)",
            def.index,
            def.name,
            line_count
        )
    end

    return defs
end

--- One macro per clip: queue L,C for the poll loop (Lua SetVar only).
--- Do NOT Call Plugin here — that runs Cleanup on the monitor and stops poll.
--- Returns map clip_id_string -> macro_index
local function ensure_clip_trigger_macros(clips)
    local macros = DataPool().Macros
    local map = {}
    if macros == nil or type(clips) ~= "table" then
        return map
    end

    -- Pick every slot first, then grow the pool once to the highest one
    -- (fresh shows need Resize before Create).
    local slots = {}
    local highest = 0
    for i, clip in ipairs(clips) do
        slots[i] = lc.macro_slot(string.format(
            "Res_Clip_L%dC%d",
            tonumber(clip.layer) or 1,
            tonumber(clip.column) or 1
        ))
        highest = math.max(highest, slots[i])
    end
    if highest > 0 then
        ensure_macro(highest)
    end

    for i, clip in ipairs(clips) do
        local macro_index = slots[i]
        local macro = ensure_macro(macro_index)
        if macro == nil then
            Printf(
                "ResolumeControlPanel: could not create trigger Macro %d (clip L%d C%d)",
                macro_index,
                tonumber(clip.layer) or 1,
                tonumber(clip.column) or 1
            )
        else
            local layer = tonumber(clip.layer) or 1
            local column = tonumber(clip.column) or 1
            local name = string.format("Res_Clip_L%dC%d", layer, column)
            macro:Set("Name", name)
            write_macro_lines(macro, macro_index, {
                -- Third field = tap time, so the log shows how long the tap waited.
                string.format(
                    'Lua "SetVar(GlobalVars(), \'%s\', \'%d,%d,\' .. (Time and Time() or \'\'))"',
                    FIRE_VAR,
                    layer,
                    column
                ),
            })
            map[tostring(clip.id)] = macro_index
        end
    end

    Printf(
        "ResolumeControlPanel: clip trigger macros ready (%d)",
        #clips
    )
    return map
end

--- Resolume layer audio volume is a dB range (e.g. -192..12); fader steps
--- are 0..1, so convert both ways. Linear 0..1 ranges pass through.
function lc.volume_is_db(param)
    if type(param) ~= "table" then
        return false
    end
    local min = tonumber(param.min) or 0
    local max = tonumber(param.max) or 1
    return min < 0 or max > 1
end

function lc.fraction_to_volume(param, p)
    if not lc.volume_is_db(param) then
        return p
    end
    local min = tonumber(param.min) or -192
    local max = tonumber(param.max) or 0
    if p <= 0 then
        return min
    end
    local db = 20 * math.log(p) / math.log(10)
    if db < min then
        db = min
    end
    if db > max then
        db = max
    end
    return db
end

function lc.volume_to_fraction(param)
    if type(param) ~= "table" then
        return 1
    end
    local v = tonumber(param_value(param, 0)) or 0
    if not lc.volume_is_db(param) then
        return v
    end
    local min = tonumber(param.min) or -192
    if v <= min + 0.5 then
        return 0
    end
    local p = 10 ^ (v / 20)
    if p > 1 then
        p = 1
    end
    return p
end

function lc.action_macro_line(action)
    return string.format(
        'Lua "SetVar(GlobalVars(), \'%s\', tostring(GetVar(GlobalVars(), \'%s\') or \'\') .. \';%s\')"',
        ACTION_VAR,
        ACTION_VAR,
        action
    )
end

--- Macros for layer / composition controls, each in its own named slot.
--- Returns a list of { macro_index, action, ... } definitions in build order.
function lc.ensure_layer_control_macros(grid)
    local defs = {}
    local function add(def)
        def.macro_index = lc.macro_slot(def.name)
        defs[#defs + 1] = def
    end
    local function fader(scope, kind, name)
        add({
            scope = scope,
            kind = kind,
            line = plugin_command(string.format("fader %d %s", scope, kind)),
            name = name,
        })
    end

    add({ scope = 0, kind = "clear", line = lc.action_macro_line("clearall"), name = "Res_ClearAll" })
    add({ scope = 0, kind = "bypass", line = lc.action_macro_line("bypass"), name = "Res_Bypass" })
    fader(0, "master", "Res_GrandMaster")

    for _, layer in ipairs(grid.layers or {}) do
        local L = layer.index
        add({
            scope = L,
            kind = "clear",
            line = lc.action_macro_line(string.format("clear,%d", L)),
            name = string.format("Res_L%d_Clear", L),
        })
        for _, kind in ipairs({ "master", "audio", "video" }) do
            fader(L, kind, string.format("Res_L%d_%s", L, kind:sub(1, 1):upper()))
        end
    end

    local highest = 0
    for _, def in ipairs(defs) do
        highest = math.max(highest, def.macro_index)
    end
    if highest > 0 then
        ensure_macro(highest)
    end
    for _, def in ipairs(defs) do
        local macro = ensure_macro(def.macro_index)
        if macro == nil then
            Printf("ResolumeControlPanel: could not create control Macro %d", def.macro_index)
            def.macro_index = nil
        else
            macro:Set("Name", def.name)
            write_macro_lines(macro, def.macro_index, { def.line })
        end
    end
    Printf(
        "ResolumeControlPanel: layer control macros ready (%d)",
        #defs
    )
    return defs
end

------------------------------------------------------------------------
-- Output
------------------------------------------------------------------------

local function print_clips(clips, composition, grid)
    local comp_name = "unknown"
    if type(composition) == "table" then
        comp_name = param_value(composition.name, "unknown")
    end

    Printf("ResolumeControlPanel ----------------------------------------")
    Printf("Host: %s:%d", RESOLUME_HOST, RESOLUME_PORT)
    Printf("Composition: %s", tostring(comp_name))
    Printf("Available clips: %d", #clips)
    if grid then
        Printf("Grid: %d layers x %d columns (used)", grid.layer_count, grid.max_column)
    end
    Printf("-----------------------------------------------------------")

    for i, clip in ipairs(clips) do
        local selected = clip.selected and "*" or " "
        local thumb = clip.has_thumbnail and "T" or "-"
        Printf(
            "[%03d]%s%s L%02d C%03d | %-24s | %-16s | %s",
            i,
            selected,
            thumb,
            clip.layer,
            clip.column,
            tostring(clip.layer_name),
            tostring(clip.connected),
            tostring(clip.name)
        )
    end

    Printf("-----------------------------------------------------------")
end

------------------------------------------------------------------------
-- Layout builder
------------------------------------------------------------------------

local function get_layouts_pool()
    return DataPool().Layouts
end

--- A layout already at Layout Index is only reused when it is ours (its
--- name is the Layout Name, ResolumeControlPanel or the old MA3ArenaDeck)
--- or empty. Anything else is the user's and is never cleared: returns the
--- reason, or nil when the slot is free to use.
function lc.layout_slot_blocked()
    local layouts = get_layouts_pool()
    if layouts == nil then
        return nil
    end
    local layout = layouts[LAYOUT_INDEX]
    if layout == nil or not pool_object_valid(layout) then
        return nil
    end
    local name = object_name(layout) or ""
    if name == LAYOUT_NAME or name == "ResolumeControlPanel" or name == "MA3ArenaDeck" then
        return nil
    end
    local count = 0
    pcall(function()
        count = #layout:Children()
    end)
    if count == 0 then
        return nil
    end
    return string.format(
        "Layout %d is already used by '%s' (%d elements).\n"
            .. "It was not changed. Pick an empty Layout Index in setup and Sync again.",
        LAYOUT_INDEX,
        name,
        count
    )
end

local function ensure_layout()
    local layouts = get_layouts_pool()
    if layouts == nil then
        return nil, "Layouts pool not found"
    end

    if layouts[LAYOUT_INDEX] == nil then
        ensure_pool_object(layouts, LAYOUT_INDEX)
    end

    local layout = layouts[LAYOUT_INDEX]
    if layout == nil or not pool_object_valid(layout) then
        return nil, string.format("Could not create Layout %d", LAYOUT_INDEX)
    end

    layout:Set("Name", LAYOUT_NAME)
    return layout, nil
end

local function clear_layout_elements(layout)
    local children = layout:Children()
    for i = #children, 1, -1 do
        layout:Delete(i)
    end
end

local function cell_pos(column_index, layer_index, _layer_count)
    local x = ORIGIN_X + LABEL_WIDTH + ((column_index - 1) * (CELL_WIDTH + CELL_GAP_X))
    local y = ORIGIN_Y + ((layer_index - 1) * (CELL_HEIGHT + CELL_GAP_Y))
    return x, y
end

local function label_pos(layer_index, _layer_count)
    local x = ORIGIN_X
    local y = ORIGIN_Y + ((layer_index - 1) * (CELL_HEIGHT + CELL_GAP_Y))
    return x, y
end

--- Delete one appearance pool slot (references to it fall back to none).
function lc.delete_appearance(index)
    local appearances = get_appearances_pool()
    if appearances == nil or index == nil then
        return
    end
    pcall(function()
        Cmd(string.format("Delete Appearance %d /NoConfirm", index))
    end)
    if pool_object_valid(appearances[index]) then
        pcall(function()
            appearances:Delete(index)
        end)
    end
end

--- Earlier versions gave buttons / their macros solid-colour appearances.
--- Deleting those makes every button and macro that used them "none".
lc.LEGACY_APPEARANCES = {
    "MAD_Lvl_Off", "MAD_Lvl_master", "MAD_Lvl_audio", "MAD_Lvl_video",
    "MAD_Bypass_On", "MAD_Bypass_Off", "MAD_Clear",
    "MAD_Btn_PollOn_On", "MAD_Btn_PollOn_Off", "MAD_Btn_PollOff_On", "MAD_Btn_PollOff_Off",
    "MAD_Btn_Interval", "MAD_Btn_Trig_On", "MAD_Btn_Trig_Off", "MAD_Btn_Sync",
}

function lc.delete_legacy_appearances()
    local appearances = get_appearances_pool()
    if appearances == nil then
        return
    end
    local removed = 0
    for _, name in ipairs(lc.LEGACY_APPEARANCES) do
        local idx = find_pool_index_by_name(appearances, name, APPEARANCE_START_INDEX, MAX_MEDIA_SLOTS)
        if idx then
            lc.delete_appearance(idx)
            removed = removed + 1
        end
    end
    if removed > 0 then
        Printf("ResolumeControlPanel: removed %d old button appearances", removed)
    end
end

--- Set "no appearance" on a layout element and on the Macro it carries.
--- With an appearance (even a plain colour) MA3 draws the macro's paper
--- icon; with none the button is just its border and centred text.
--- Set the layout element's appearance to None (as picked in the element
--- editor). The Macro objects themselves are left untouched.
function lc.clear_appearance(element)
    if element == nil then
        return
    end
    for _, value in ipairs({ "None", "" }) do
        pcall(function()
            element:Set("Appearance", value)
        end)
    end
    pcall(function()
        element.Appearance = nil
    end)
    local idx = nil
    pcall(function()
        idx = element:Index()
    end)
    if idx then
        pcall(function()
            Cmd(string.format('Set Layout %d.%d Property "Appearance" "None"', LAYOUT_INDEX, idx))
        end)
    end
end

--- Keep the label inside the button, centred both ways (also after the
--- Macro is assigned, which may reset text placement).
function lc.center_text(element)
    local idx = nil
    pcall(function()
        idx = element:Index()
    end)
    for _, pair in ipairs({
        { "customtextalignmenth", "Center" },
        { "customtextalignmentv", "Center" },
        { "CustomTextAlignmentH", "Center" },
        { "CustomTextAlignmentV", "Center" },
        { "visibilityobjectname", "Hidden" },
    }) do
        pcall(function()
            element:Set(pair[1], pair[2])
        end)
    end
    if idx then
        pcall(function()
            Cmd(string.format(
                'Set Layout %d.%d Property "CustomTextAlignmentV" "Center"',
                LAYOUT_INDEX,
                idx
            ))
        end)
    end
end

--- One-time System Monitor dump of a control element's text / appearance
--- properties, so the exact property names on this MA3 build are visible.
function lc.dump_element_props(element)
    if lc.props_dumped or element == nil then
        return
    end
    lc.props_dumped = true
    local count = 0
    pcall(function()
        count = element:PropertyCount()
    end)
    local parts = {}
    for i = 0, count - 1 do
        pcall(function()
            local name = element:PropertyName(i)
            local lname = tostring(name):lower()
            if lname:find("text") or lname:find("align") or lname:find("appear")
                or lname:find("visib") or lname:find("label")
            then
                parts[#parts + 1] = string.format("%s=%s", tostring(name), tostring(element:Get(name)))
            end
        end)
    end
    Printf("ResolumeControlPanel: element props: %s", table.concat(parts, " | "))
end

local function assign_appearance(element, appearance_info)
    if element == nil or appearance_info == nil or appearance_info.handle == nil then
        return false
    end

    local ok = pcall(function()
        element.Appearance = appearance_info.handle:AddrNative()
    end)
    if ok then
        return true
    end

    ok = pcall(function()
        element:Set("Appearance", appearance_info.handle:AddrNative())
    end)
    if ok then
        return true
    end

    local elem_no = nil
    pcall(function()
        elem_no = element:Index()
    end)
    if elem_no == nil then
        elem_no = element.No or element.index
    end
    if elem_no then
        pcall(function()
            Cmd(string.format(
                'Set Layout %d.%d Property "Appearance" %d',
                LAYOUT_INDEX,
                elem_no,
                appearance_info.index
            ))
        end)
        pcall(function()
            Cmd(string.format(
                "Assign Appearance %d At Layout %d.%d",
                appearance_info.index,
                LAYOUT_INDEX,
                elem_no
            ))
        end)
        return true
    end

    return false
end

--- Solid fill Appearance for control buttons (no image).
local function element_addr(element)
    if element == nil then
        return nil
    end
    local addr = nil
    pcall(function()
        addr = element:ToAddr()
    end)
    return addr
end

local function cleanup_stray_rcs_macro_elements(layout)
    if layout == nil then
        return 0
    end

    local removed = 0
    local children = layout:Children()
    for i = #children, 1, -1 do
        local el = children[i]
        local note = ""
        pcall(function()
            note = el.Note or el.note or ""
        end)

        local is_ctrl_button = type(note) == "string" and note:find("^resolume%-ctrl:") ~= nil
        local is_clip = type(note) == "string" and note:find("^resolume%-clip:") ~= nil
        local is_level = type(note) == "string" and note:find("^resolume%-lvl:") ~= nil
        -- Clip cells may have Res_Clip_* macros assigned when trigger mode is on;
        -- layer / composition control cells always carry their Res_* macro.
        if not is_ctrl_button and not is_clip and not is_level then
            local obj_name = ""
            pcall(function()
                local obj = el.Object
                if obj ~= nil then
                    obj_name = tostring(obj.Name or obj.name or "")
                end
            end)
            if obj_name == "" then
                pcall(function()
                    obj_name = tostring(el.Name or "")
                end)
            end

            if obj_name:find("^Res_") ~= nil or obj_name:find("^MAD_") ~= nil then
                layout:Delete(i)
                removed = removed + 1
                Printf("ResolumeControlPanel: removed stray '%s' from layout", obj_name)
            end
        end
    end
    return removed
end

local function style_element(element, opts)
    element:Set("posx", tostring(opts.x))
    element:Set("posy", tostring(opts.y))
    element:Set("width", tostring(opts.width))
    element:Set("height", tostring(opts.height))
    element:Set("customtexttext", tostring(opts.text or ""))
    element:Set("customtextsize", tostring(opts.text_size or 16))
    element:Set("customtextalignmenth", "Center")
    element:Set("customtextalignmentv", opts.text_align_v or "Center")
    element:Set("visibilityborder", "Visible")
    element:Set("bordersize", tostring(opts.border or 2))
    element:Set("visibilityobjectname", "Hidden")
    if opts.note then
        element:Set("note", tostring(opts.note))
    end
end

local function interval_button_label()
    return string.format("POLL %.2fs", get_poll_interval())
end

local function trigger_button_label()
    return get_trigger_flag() and "TRIG ON" or "TRIG OFF"
end

local function parse_ctrl_note(note)
    if type(note) ~= "string" then
        return nil
    end
    return note:match("^resolume%-ctrl:([%w_]+)")
end

local function apply_control_chrome(element, kind, active)
    if element == nil or kind == nil then
        return
    end

    local color = CTRL_COLOR.sync
    local border = 5
    if kind == "monitor" then
        color = active and CTRL_COLOR.poll_on_active or CTRL_COLOR.poll_on_idle
        border = active and 10 or 4
    elseif kind == "stop" then
        color = active and CTRL_COLOR.poll_off_active or CTRL_COLOR.poll_off_idle
        border = active and 10 or 4
    elseif kind == "interval" then
        color = CTRL_COLOR.interval
        border = 6
    elseif kind == "trigger" then
        color = active and CTRL_COLOR.trigger_active or CTRL_COLOR.trigger_idle
        border = active and 10 or 4
    elseif kind == "sync" then
        color = CTRL_COLOR.sync
        border = 5
    elseif kind:match("^rec%d+$") then
        color = active and CTRL_COLOR.rec_active or CTRL_COLOR.rec_idle
        border = active and 12 or 4
    elseif kind:match("^play%d+$") then
        color = active and CTRL_COLOR.play_active or CTRL_COLOR.play_idle
        border = active and 12 or 4
    end

    pcall(function()
        element:Set("bordersize", tostring(border))
        element:Set("visibilityborder", "Visible")
    end)
    set_element_border_color(element, color.r, color.g, color.b)

    -- No appearance: it only makes MA3 draw the macro icon; the coloured
    -- border carries the state.
    lc.clear_appearance(element)

    if kind == "interval" then
        pcall(function()
            element:Set("customtexttext", interval_button_label())
        end)
    elseif kind == "trigger" then
        pcall(function()
            element:Set("customtexttext", trigger_button_label())
        end)
    end
end

local function update_control_button_styles()
    local layout = DataPool().Layouts[LAYOUT_INDEX]
    if layout == nil then
        return
    end

    local monitoring = get_monitor_flag()
    local triggering = get_trigger_flag()
    for _, element in ipairs(layout:Children()) do
        local note = nil
        pcall(function()
            note = element.Note or element.note
        end)
        local kind = parse_ctrl_note(note)
        if kind then
            local active = false
            if kind == "monitor" then
                active = monitoring
            elseif kind == "stop" then
                active = not monitoring
            elseif kind == "trigger" then
                active = triggering
            elseif kind == "interval" or kind == "sync" then
                active = true
            else
                local rec_n = tonumber(kind:match("^rec(%d+)$"))
                local play_n = tonumber(kind:match("^play(%d+)$"))
                if rec_n then
                    active = lc.rec ~= nil and lc.rec.slot == rec_n
                elseif play_n then
                    active = lc.play ~= nil and lc.play.slot == play_n
                end
            end
            apply_control_chrome(element, kind, active)
        end
    end
end

local function set_element_action_go(element)
    if element == nil then
        return
    end
    local addr = element_addr(element)
    if addr then
        pcall(function()
            Cmd('Set ' .. addr .. ' Property "Action" "Go+"')
        end)
    end
    local child_index = nil
    pcall(function()
        child_index = element:Index()
    end)
    if child_index then
        pcall(function()
            Cmd(string.format(
                'Set Layout %d.%d Property "Action" "Go+"',
                LAYOUT_INDEX,
                child_index
            ))
        end)
    end
end

--- Place a control Macro on the layout as a new element, then style it.
--- Do not create an empty placeholder first: on this MA3 build,
--- `Assign Macro N At Layout X.Y` appends a sibling, and deleting that
--- "stray" removed the only element that actually had the Macro/Action.
local function place_control_macro(layout, macro_index, geo)
    if layout == nil or macro_index == nil then
        return false
    end

    local macro = DataPool().Macros[macro_index]
    if macro == nil then
        Printf("ResolumeControlPanel: Macro %d missing", macro_index)
        return false
    end

    local before = #layout:Children()
    local ok = pcall(function()
        Cmd(string.format(
            "Assign Macro %d At Layout %d",
            macro_index,
            LAYOUT_INDEX
        ))
    end)

    local children = layout:Children()
    local target = nil
    if #children > before then
        target = children[#children]
    else
        -- Fallback: find by assigned object / name.
        for i = #children, 1, -1 do
            local el = children[i]
            local match = false
            pcall(function()
                local obj = el.Object
                if obj and obj:Index() == macro_index then
                    match = true
                end
            end)
            if not match then
                pcall(function()
                    local name = tostring(el.Name or "")
                    if name == tostring(macro.Name) then
                        match = true
                    end
                end)
            end
            if match then
                target = el
                break
            end
        end
    end

    if target == nil then
        Printf(
            "ResolumeControlPanel: Assign Macro %d did not create a layout element",
            macro_index
        )
        return false
    end

    if geo then
        style_element(target, geo)
    end
    set_element_action_go(target)
    lc.center_text(target)
    pcall(function()
        target:Set("visibilityobjectname", "Hidden")
    end)

    local child_index = nil
    pcall(function()
        child_index = target:Index()
    end)

    Printf(
        "ResolumeControlPanel: button Macro %d -> Layout %d.%s (%s)",
        macro_index,
        LAYOUT_INDEX,
        tostring(child_index or "?"),
        ok and "ok" or "cmd-failed"
    )
    return true
end

local function add_element(layout, opts)
    local element = layout:Acquire()
    if element == nil then
        return nil
    end
    style_element(element, opts)
    if opts.appearance then
        assign_appearance(element, opts.appearance)
    end
    if opts.playing ~= nil then
        apply_playing_chrome(element, opts.playing)
    end
    return element
end

local function clip_note(clip_id, clip_name, playing, layer, column, macro_index)
    local note = string.format(
        "resolume-clip:%s|name:%s|play:%s|L:%s|C:%s",
        tostring(clip_id),
        tostring(clip_name or ""):gsub("|", "/"),
        playing and "1" or "0",
        tostring(layer or 0),
        tostring(column or 0)
    )
    if macro_index then
        note = note .. "|M:" .. tostring(macro_index)
    end
    return note
end

local function parse_clip_note(note)
    if type(note) ~= "string" then
        return nil
    end
    local id = note:match("resolume%-clip:([%w%-]+)")
    if not id then
        return nil
    end
    local name = note:match("|name:([^|]*)") or ""
    local play = note:match("|play:(%d)") == "1"
    local layer = tonumber(note:match("|L:(%d+)"))
    local column = tonumber(note:match("|C:(%d+)"))
    local macro_index = tonumber(note:match("|M:(%d+)"))
    return {
        id = id,
        name = name,
        playing = play,
        layer = layer,
        column = column,
        macro_index = macro_index,
    }
end

local function clear_element_action(element)
    if element == nil then
        return
    end
    local idx = nil
    pcall(function()
        idx = element:Index()
    end)
    pcall(function()
        element:Set("Action", "")
    end)
    pcall(function()
        element:Set("Object", "")
    end)
    if idx then
        pcall(function()
            Cmd(string.format('Set Layout %d.%d Property "Action" ""', LAYOUT_INDEX, idx))
        end)
        pcall(function()
            Cmd(string.format('Set Layout %d.%d Property "Object" ""', LAYOUT_INDEX, idx))
        end)
    end
end

local function assign_clip_trigger_macro(element, macro_index)
    if element == nil or macro_index == nil then
        return false
    end
    local macro = DataPool().Macros[macro_index]
    if macro == nil then
        return false
    end

    -- Prefer Object property (Assign Macro At Layout X.Y often appends a sibling).
    local ok = pcall(function()
        element:Set("Object", macro)
    end)
    if not ok then
        ok = pcall(function()
            element:Set("Object", string.format("Macro %d", macro_index))
        end)
    end
    set_element_action_go(element)
    pcall(function()
        element:Set("visibilityobjectname", "Hidden")
    end)
    return true
end

local function apply_trigger_mode_to_layout(enabled)
    local layout = DataPool().Layouts[LAYOUT_INDEX]
    if layout == nil then
        return 0
    end

    local count = 0
    for _, element in ipairs(layout:Children()) do
        local note = nil
        pcall(function()
            note = element.Note or element.note
        end)
        local meta = parse_clip_note(note)
        if meta then
            if enabled and meta.macro_index then
                if assign_clip_trigger_macro(element, meta.macro_index) then
                    count = count + 1
                end
            else
                clear_element_action(element)
                count = count + 1
            end
        end
    end
    return count
end

--- Returns new enabled state (true = trigger on).
local function toggle_trigger_mode()
    local enabled = not get_trigger_flag()
    set_trigger_flag(enabled)
    local n = apply_trigger_mode_to_layout(enabled)
    update_control_button_styles()
    Printf(
        "ResolumeControlPanel: trigger mode %s (%d clip elements)",
        enabled and "ON" or "OFF",
        n
    )
    pcall(function()
        Echo(string.format("ResolumeControlPanel: TRIG %s", enabled and "ON" or "OFF"))
    end)
    return enabled
end

--- Called from the poll loop: handle clip taps queued via GlobalVars.
--- Returns layer, column of the fired clip (nil when nothing was queued).
local function process_pending_fire()
    local v = nil
    pcall(function()
        v = GetVar(GlobalVars(), FIRE_VAR)
    end)
    if v == nil or v == "" or v == 0 or v == "0" then
        return nil
    end
    pcall(function()
        SetVar(GlobalVars(), FIRE_VAR, "")
    end)

    local layer, column, tapped_at = tostring(v):match("^(%d+)%s*,%s*(%d+)%s*,?%s*([%d%.]*)$")
    if not layer then
        return nil
    end
    lc.record_event("f", layer .. "," .. column)

    local t_post = Time()
    local ok, err = http_post(clip_connect_url(layer, column), "", 2)
    if ok then
        local waited = tonumber(tapped_at) and (t_post - tonumber(tapped_at)) or -1
        Printf(
            "ResolumeControlPanel: triggered L%d C%d (tap waited %.2fs, POST %.2fs)",
            tonumber(layer) or 0,
            tonumber(column) or 0,
            waited,
            Time() - t_post
        )
        return tonumber(layer), tonumber(column)
    end

    Printf("ResolumeControlPanel: trigger FAILED (%s)", tostring(err))
    return nil
end

local function fire_resolume_clip(layer, column, clip_id)
    if not ensure_deps() then
        return false
    end

    local ok, err
    if layer and column then
        ok, err = http_post(clip_connect_url(layer, column), "", 2)
        if ok then
            Printf(
                "ResolumeControlPanel: triggered L%d C%d",
                tonumber(layer) or 0,
                tonumber(column) or 0
            )
            return true
        end
    end

    if clip_id then
        ok, err = http_post(clip_connect_by_id_url(clip_id), "", 2)
        if ok then
            Printf("ResolumeControlPanel: triggered clip id %s", tostring(clip_id))
            return true
        end
    end

    Printf("ResolumeControlPanel: trigger FAILED (%s)", tostring(err))
    return false
end

local function add_control_buttons(layout, layer_count)
    local macros = ensure_control_macros()
    if not macros then
        return 0
    end

    -- Below layer 1 (Y-up): negative Y, with extra offset so they never cover clips.
    local y = ORIGIN_Y - (BUTTON_HEIGHT + BUTTON_GAP + BUTTON_ROW_OFFSET)
    local x = ORIGIN_X
    local created = 0

    local buttons = {
        { label = "SYNC", macro = macros[1], note = "resolume-ctrl:sync", kind = "sync" },
        { label = "POLL ON", macro = macros[2], note = "resolume-ctrl:monitor", kind = "monitor" },
        { label = "POLL OFF", macro = macros[3], note = "resolume-ctrl:stop", kind = "stop" },
        {
            label = interval_button_label(),
            macro = macros[4],
            note = "resolume-ctrl:interval",
            kind = "interval",
        },
        {
            label = trigger_button_label(),
            macro = macros[5],
            note = "resolume-ctrl:trigger",
            kind = "trigger",
        },
    }

    -- Scene recorder row at the top, right of the COMPOSITION label (same
    -- row, starting over the first clip column): REC 1, PLAY 1, REC 2, ...
    local scene_y = ORIGIN_Y + ((layer_count or 0) * (CELL_HEIGHT + CELL_GAP_Y))
    local scene_x = ORIGIN_X + LABEL_WIDTH
    for n = 1, lc.SCENE_COUNT do
        for _, def in ipairs({
            { kind = "rec", label = "\226\151\143 REC " .. n, name = "Res_Rec" .. n },
            { kind = "play", label = "\226\150\182 PLAY " .. n, name = "Res_Play" .. n },
        }) do
            local index = lc.macro_slot(def.name)
            local macro = ensure_macro(index)
            if macro then
                macro:Set("Name", def.name)
                write_macro_lines(macro, index, { lc.action_macro_line(def.kind .. "," .. n) })
                buttons[#buttons + 1] = {
                    label = def.label,
                    macro = { index = index },
                    note = "resolume-ctrl:" .. def.kind .. n,
                    kind = def.kind .. n,
                    row = 2,
                }
            else
                Printf("ResolumeControlPanel: could not create Macro %d '%s'", index, def.name)
            end
        end
    end

    local row_count = { 0, 0 }
    for _, btn in ipairs(buttons) do
        local row = btn.row or 1
        row_count[row] = row_count[row] + 1
        local bx = (row == 2 and scene_x or x) + ((row_count[row] - 1) * (BUTTON_WIDTH + BUTTON_GAP))
        local geo = {
            x = bx,
            y = row == 2 and scene_y or y,
            width = BUTTON_WIDTH,
            height = row == 2 and CELL_HEIGHT or BUTTON_HEIGHT,
            text = btn.label,
            text_size = 16,
            border = 5,
            note = btn.note,
        }
        if place_control_macro(layout, btn.macro.index, geo) then
            created = created + 1
        else
            Printf("ResolumeControlPanel: failed to wire button '%s'", btn.label)
        end
    end

    cleanup_stray_rcs_macro_elements(layout)
    update_control_button_styles()
    return created
end

function lc.level_note(scope, kind, step)
    return string.format("resolume-lvl:%d:%s:%.2f", scope, kind, step or 0)
end

function lc.parse_level_note(note)
    if type(note) ~= "string" then
        return nil
    end
    local scope, kind, step = note:match("^resolume%-lvl:(%d+):(%a+):([%d%.]+)")
    if not scope then
        return nil
    end
    return tonumber(scope), kind, tonumber(step)
end

function lc.fader_label(scope, kind, value)
    local name = scope == 0 and "GM" or (kind == "master" and "M" or kind:sub(1, 1):upper())
    return string.format("%s %d%%", name, math.floor((value or 0) * 100 + 0.5))
end

function lc.style_fader_button(element, scope, kind, value)
    local lit = (value or 0) > 0.001
    lc.clear_appearance(element)
    local c = lit and (lc.LEVEL_COLOR[kind] or lc.LEVEL_COLOR.master) or lc.LEVEL_COLOR.off
    set_element_border_color(element, c.r, c.g, c.b)
    pcall(function()
        element:Set("customtexttext", lc.fader_label(scope, kind, value))
    end)
end

--- Last level sent from MA3 (0..1), kept in GlobalVars so every plugin
--- call (layout tap, fader popup, poll loop) sees the same value.
function lc.get_level(scope, kind)
    return tonumber(cfg_get(string.format("Lvl_%d_%s", scope, kind), 1)) or 1
end

function lc.set_level(scope, kind, value)
    cfg_set(string.format("Lvl_%d_%s", scope, kind), string.format("%.4f", value or 0))
end

--- Layer audio volume range stored at SYNC ("min,max"); nil = linear 0..1.
function lc.get_volume_param(scope)
    local v = cfg_get(string.format("VolR_%d", scope), "")
    local min, max = tostring(v):match("^(%-?[%d%.]+),(%-?[%d%.]+)$")
    if not min then
        return nil
    end
    return { min = tonumber(min), max = tonumber(max) }
end

function lc.set_volume_param(scope, param)
    local value = ""
    if type(param) == "table" and param.min ~= nil and param.max ~= nil then
        value = string.format("%.4f,%.4f", tonumber(param.min) or 0, tonumber(param.max) or 1)
    end
    cfg_set(string.format("VolR_%d", scope), value)
end

function lc.style_bypass_button(element, on)
    lc.clear_appearance(element)
    local c = on and lc.LEVEL_COLOR.bypass_on or lc.LEVEL_COLOR.bypass_off
    set_element_border_color(element, c.r, c.g, c.b)
    pcall(function()
        element:Set("customtexttext", on and "B ON" or "B")
    end)
end

function lc.get_bypass_flag()
    return cfg_get_bool("Bypassed", false)
end

function lc.set_bypass_flag(on)
    cfg_set("Bypassed", on and "1" or "0")
end

--- Recolour one fader (scope 0 = composition) after a level change.
function lc.update_level_display(scope, kind, value)
    local layout = DataPool().Layouts[LAYOUT_INDEX]
    if layout == nil then
        return
    end
    for _, element in ipairs(layout:Children()) do
        local note = nil
        pcall(function()
            note = element.Note or element.note
        end)
        local s_scope, s_kind = lc.parse_level_note(note)
        if s_scope == scope and s_kind == kind then
            if kind == "bypass" then
                lc.style_bypass_button(element, value and true or false)
            else
                lc.style_fader_button(element, scope, kind, value)
            end
        end
    end
end

--- Build the X / B buttons and fader buttons left of the layer labels.
function lc.add_layer_controls(layout, grid)
    local defs = lc.ensure_layer_control_macros(grid)
    local created = 0
    local layer_count = grid.layer_count or 0

    lc.set_level(0, "master", grid.master or 1)
    for _, layer in ipairs(grid.layers or {}) do
        lc.set_level(layer.index, "master", layer.master or 1)
        lc.set_level(layer.index, "video", layer.opacity or 1)
        lc.set_level(layer.index, "audio", lc.volume_to_fraction(layer.volume))
        lc.set_volume_param(layer.index, layer.volume)
    end
    lc.set_bypass_flag(grid.bypassed)

    local fw = lc.FADER_BTN_WIDTH
    local gap = lc.FADER_GAP
    local strip_w = lc.CTRL_BTN_WIDTH + gap + 3 * (fw + gap)
    local x0 = ORIGIN_X - strip_w

    local function row_y(scope)
        if scope == 0 then
            -- Composition row sits above the top layer (Y-up).
            return ORIGIN_Y + (layer_count * (CELL_HEIGHT + CELL_GAP_Y))
        end
        local _, y = label_pos(scope, layer_count)
        return y
    end

    local slots = { bypass = 0, master = 0, audio = 1, video = 2 }

    for _, def in ipairs(defs) do
        if def.macro_index then
            local opts = {
                y = row_y(def.scope),
                height = CELL_HEIGHT,
                text_size = 16,
                border = 4,
                note = lc.level_note(def.scope, def.kind, 0),
            }
            if def.kind == "clear" then
                opts.x = x0
                opts.width = lc.CTRL_BTN_WIDTH
                opts.text = def.scope == 0 and "X ALL" or "X"
                opts.text_size = def.scope == 0 and 14 or 24
            else
                local slot = slots[def.kind] or 0
                if def.scope == 0 and def.kind == "master" then
                    slot = 1 -- GM next to B
                end
                opts.x = x0 + lc.CTRL_BTN_WIDTH + gap + slot * (fw + gap)
                opts.width = fw
                opts.text = def.kind == "bypass" and "B"
                    or lc.fader_label(def.scope, def.kind, lc.get_level(def.scope, def.kind))
            end

            local el = add_element(layout, opts)
            if el then
                assign_clip_trigger_macro(el, def.macro_index)
                lc.center_text(el)
                lc.dump_element_props(el)
                if def.kind == "clear" then
                    local c = lc.LEVEL_COLOR.clear
                    lc.clear_appearance(el)
                    set_element_border_color(el, c.r, c.g, c.b)
                elseif def.kind == "bypass" then
                    lc.style_bypass_button(el, grid.bypassed)
                else
                    lc.style_fader_button(el, def.scope, def.kind, lc.get_level(def.scope, def.kind))
                end
                created = created + 1
            end
        end
    end

    -- Composition label in the layer-label column.
    local cx, _ = label_pos(1, layer_count)
    local el = add_element(layout, {
        x = cx,
        y = row_y(0),
        width = LABEL_WIDTH - CELL_GAP_X,
        height = CELL_HEIGHT,
        text = "COMPOSITION",
        text_size = 14,
        border = LAYER_BORDER_SIZE,
        note = "resolume-layer:composition",
    })
    if el then
        set_element_border_color(el, LAYER_BORDER_R, LAYER_BORDER_G, LAYER_BORDER_B)
        created = created + 1
    end
    return created
end

local function build_layout(clips, grid, appearance_map)
    local layout, err = ensure_layout()
    if not layout then
        return nil, err
    end

    clear_layout_elements(layout)

    local layer_count = grid.layer_count
    local created = 0
    appearance_map = appearance_map or {}

    if layer_count >= 1 and SHOW_LAYER_LABELS then
        for _, layer in ipairs(grid.layers) do
            local x, y = label_pos(layer.index, layer_count)
            local label = string.format("L%d %s", layer.index, tostring(layer.name))
            local el = add_element(layout, {
                x = x,
                y = y,
                width = LABEL_WIDTH - CELL_GAP_X,
                height = CELL_HEIGHT,
                text = label,
                text_size = 14,
                border = LAYER_BORDER_SIZE,
                note = string.format("resolume-layer:%s", tostring(layer.id or layer.index)),
            })
            if el then
                set_element_border_color(el, LAYER_BORDER_R, LAYER_BORDER_G, LAYER_BORDER_B)
                created = created + 1
            end
        end
    end

    local fire_macros = ensure_clip_trigger_macros(clips)
    local trigger_enabled = get_trigger_flag()

    for _, clip in ipairs(clips) do
        local x, y = cell_pos(clip.column, clip.layer, layer_count)
        local playing = is_playing_state(clip.connected)
        local text = tostring(clip.name)
        if playing then
            text = "> " .. text
        end

        local media = appearance_map[tostring(clip.id)]
        local appearance = nil
        if media then
            appearance = playing and media.appearance_play or media.appearance_idle
        end

        local macro_index = fire_macros[tostring(clip.id)]
        local element = add_element(layout, {
            x = x,
            y = y,
            width = CELL_WIDTH,
            height = CELL_HEIGHT,
            text = text,
            text_size = appearance and 12 or 14,
            text_align_v = appearance and "Bottom" or "Center",
            border = playing and PLAYING_BORDER_SIZE or IDLE_BORDER_SIZE,
            appearance = appearance,
            playing = playing,
            note = clip_note(
                clip.id,
                clip.name,
                playing,
                clip.layer,
                clip.column,
                macro_index
            ),
        })
        if element then
            created = created + 1
            if trigger_enabled and macro_index then
                assign_clip_trigger_macro(element, macro_index)
            end
        end
    end

    if lc.SHOW_LAYER_CONTROLS then
        created = created + lc.add_layer_controls(layout, grid)
    end

    created = created + add_control_buttons(layout, layer_count)
    cleanup_stray_rcs_macro_elements(layout)

    return layout, nil, created
end

------------------------------------------------------------------------
-- Status polling / highlight updates
------------------------------------------------------------------------

local function apply_element_playing_state(element, meta, playing)
    local apps = lookup_appearances_for_clip(meta.id)
    local appearance = nil
    if apps then
        appearance = playing and apps.appearance_play or apps.appearance_idle
        if appearance == nil then
            appearance = apps.appearance_idle or apps.appearance_play
        end
    end

    if appearance then
        assign_appearance(element, appearance)
    end

    local name = meta.name
    if name == "" then
        name = tostring(meta.id)
    end
    lc.play_cache[meta.id] = playing
    local text = playing and ("> " .. name) or name
    pcall(function()
        element:Set("customtexttext", text)
        element:Set(
            "note",
            clip_note(meta.id, name, playing, meta.layer, meta.column, meta.macro_index)
        )
    end)
    apply_playing_chrome(element, playing)
end

--- Mark the fired clip as playing (and its layer neighbours idle) right away,
--- without waiting for the next poll round-trip to confirm it.
local function apply_fired_highlight(layer, column)
    local layout = DataPool().Layouts[LAYOUT_INDEX]
    if layout == nil then
        return
    end
    for _, element in ipairs(layout:Children()) do
        local note = nil
        pcall(function()
            note = element.Note or element.note
        end)
        local meta = parse_clip_note(note)
        -- layer nil = every layer (clear all); column nil = nothing playing.
        if meta and (layer == nil or meta.layer == layer) then
            local playing = column ~= nil and meta.column == column
            local shown = lc.play_cache[meta.id]
            if shown == nil then
                shown = meta.playing
            end
            if playing ~= shown then
                apply_element_playing_state(element, meta, playing)
            end
        end
    end
end

function lc.layer_level_body(kind, value)
    if kind == "video" then
        return string.format('{"video":{"opacity":{"value":%.4f}}}', value)
    elseif kind == "audio" then
        return string.format('{"audio":{"volume":{"value":%.4f}}}', value)
    end
    return string.format('{"master":{"value":%.4f}}', value)
end

------------------------------------------------------------------------
-- Scene recorder (REC / PLAY)
------------------------------------------------------------------------

function lc.record_event(kind, value)
    local r = lc.rec
    if r == nil then
        return
    end
    r.events[#r.events + 1] = { t = Time() - r.start, k = kind, v = value }
end

--- "len=12.340;0.000|f|1,3;1.500|a|clear,2;..." in ResArena_Scene<n>.
function lc.save_scene(slot, length, events)
    local parts = { string.format("len=%.3f", length) }
    for _, ev in ipairs(events) do
        parts[#parts + 1] = string.format("%.3f|%s|%s", ev.t, ev.k, ev.v)
    end
    pcall(function()
        SetVar(GlobalVars(), lc.SCENE_VAR .. tostring(slot), table.concat(parts, ";"))
    end)
end

function lc.load_scene(slot)
    local v = nil
    pcall(function()
        v = GetVar(GlobalVars(), lc.SCENE_VAR .. tostring(slot))
    end)
    if type(v) ~= "string" or v == "" then
        return nil
    end
    local length = tonumber(v:match("^len=([%d%.]+)")) or 0
    local events = {}
    for t, k, val in v:gmatch("([%d%.]+)|(%a)|([^;]+)") do
        events[#events + 1] = { t = tonumber(t) or 0, k = k, v = val }
    end
    if #events == 0 then
        return nil
    end
    return length, events
end

--- Also write the scene as MA3 macro Res_Scene<n> (one line per tap, the
--- line's Wait = time to the next tap). Like the layout buttons, it only
--- reaches Resolume while POLL ON runs. The macro plays once.
function lc.write_scene_macro(slot, length, events)
    local name = "Res_Scene" .. tostring(slot)
    local index = lc.macro_slot(name)
    local macro = ensure_macro(index)
    if macro == nil then
        Printf("ResolumeControlPanel: could not create Macro %d '%s'", index, name)
        return
    end
    macro:Set("Name", name)
    local children = macro:Children()
    for i = #children, 1, -1 do
        macro:Delete(i)
    end
    for i, ev in ipairs(events) do
        local command
        if ev.k == "f" then
            command = string.format('Lua "SetVar(GlobalVars(), \'%s\', \'%s\')"', FIRE_VAR, ev.v)
        else
            command = lc.action_macro_line(ev.v)
        end
        local next_t = events[i + 1] and events[i + 1].t or length
        local wait = math.max(0, next_t - ev.t)
        local line = macro:Acquire()
        if line then
            pcall(function()
                line:Set("Command", command)
            end)
            pcall(function()
                line:Set("Wait", string.format("%.2f", wait))
            end)
        end
    end
    Printf("ResolumeControlPanel: scene %d written to Macro %d '%s' (%d taps)", slot, index, name, #events)
end

function lc.stop_rec()
    local r = lc.rec
    if r == nil then
        return
    end
    lc.rec = nil
    local length = Time() - r.start
    if #r.events == 0 then
        Printf("ResolumeControlPanel: REC %d stopped, nothing tapped; old scene kept", r.slot)
        return
    end
    lc.save_scene(r.slot, length, r.events)
    lc.write_scene_macro(r.slot, length, r.events)
    Printf("ResolumeControlPanel: REC %d saved (%d taps, %.2fs loop)", r.slot, #r.events, length)
end

function lc.toggle_rec(slot)
    local was = lc.rec and lc.rec.slot
    lc.stop_rec()
    if was ~= slot then
        if lc.play and lc.play.slot == slot then
            lc.play = nil
        end
        lc.rec = { slot = slot, start = Time(), events = {} }
        Printf("ResolumeControlPanel: REC %d started", slot)
    end
    update_control_button_styles()
end

function lc.toggle_play(slot)
    local was = lc.play and lc.play.slot
    lc.play = nil
    if was ~= slot then
        if lc.rec and lc.rec.slot == slot then
            lc.stop_rec()
        end
        local length, events = lc.load_scene(slot)
        if not length then
            Printf("ResolumeControlPanel: scene %d is empty, record it with REC %d first", slot, slot)
        else
            -- A loop never runs shorter than its last tap.
            length = math.max(length, events[#events].t + 0.1)
            lc.play = { slot = slot, start = Time(), length = length, events = events, i = 1 }
            Printf("ResolumeControlPanel: PLAY %d looping (%d taps, %.2fs)", slot, #events, length)
        end
    else
        Printf("ResolumeControlPanel: PLAY %d stopped", slot)
    end
    update_control_button_styles()
end

function lc.run_scene_event(ev)
    if ev.k == "f" then
        local layer, column = ev.v:match("^(%d+),(%d+)$")
        if layer and http_post(clip_connect_url(layer, column), "", 2) then
            apply_fired_highlight(tonumber(layer), tonumber(column))
        end
    else
        lc.run_control_action(ev.v)
    end
end

--- Called from the poll loop: send every scene tap that is due.
function lc.play_tick()
    local p = lc.play
    if p == nil then
        return false
    end
    local now = Time() - p.start
    if now > p.length * 2 then
        -- The loop was stalled (e.g. a slow poll); restart instead of bursting.
        p.start = Time()
        p.i = 1
        now = 0
    end
    local any = false
    while lc.play == p do
        local ev = p.events[p.i]
        if ev == nil then
            if now < p.length then
                break
            end
            p.start = p.start + p.length
            now = now - p.length
            p.i = 1
        elseif ev.t <= now then
            p.i = p.i + 1
            lc.run_scene_event(ev)
            any = true
        else
            break
        end
    end
    return any
end

--- Run one queued control action. Returns true when Resolume accepted it.
function lc.run_control_action(action)
    local rec_n = tonumber(action:match("^rec,(%d+)$"))
    if rec_n then
        lc.toggle_rec(rec_n)
        return true
    end
    local play_n = tonumber(action:match("^play,(%d+)$"))
    if play_n then
        lc.toggle_play(play_n)
        return true
    end

    local t0 = Time()
    local ok, err, what

    if action == "clearall" then
        what = "clear all"
        ok, err = http_post(lc.disconnect_all_url(), "", 2)
        if ok then
            apply_fired_highlight(nil, nil)
        end
    elseif action == "bypass" then
        local on = not lc.get_bypass_flag()
        what = on and "bypass ON" or "bypass OFF"
        ok, err = lc.http_put(
            composition_url(),
            string.format('{"bypassed":{"value":%s}}', on and "true" or "false"),
            2
        )
        if ok then
            lc.set_bypass_flag(on)
            lc.update_level_display(0, "bypass", on)
        end
    else
        local clear_layer = action:match("^clear,(%d+)$")
        local L, kind, step, raw = action:match("^lvl,(%d+),(%a+),([%d%.]+),(%-?[%d%.]+)$")
        if clear_layer then
            what = "clear L" .. clear_layer
            ok, err = http_post(lc.layer_clear_url(clear_layer), "", 2)
            if ok then
                apply_fired_highlight(tonumber(clear_layer), nil)
            end
        elseif L then
            L = tonumber(L)
            what = string.format("L%d %s %s%%", L, kind, tostring(math.floor(tonumber(step) * 100 + 0.5)))
            local url = L == 0 and composition_url() or layer_url(L)
            ok, err = lc.http_put(url, lc.layer_level_body(kind, tonumber(raw) or 0), 2)
            if ok then
                lc.set_level(L, kind, tonumber(step) or 0)
                lc.update_level_display(L, kind, tonumber(step) or 0)
            end
        else
            Printf("ResolumeControlPanel: unknown control action '%s'", tostring(action))
            return false
        end
    end

    if ok then
        Printf("ResolumeControlPanel: %s (%.2fs)", what, Time() - t0)
        return true
    end
    Printf("ResolumeControlPanel: %s FAILED (%s)", tostring(what), tostring(err))
    return false
end

--- Layer / composition control taps queued as ";action;action" in ACTION_VAR.
function lc.process_pending_actions()
    local v = nil
    pcall(function()
        v = GetVar(GlobalVars(), ACTION_VAR)
    end)
    if v == nil or v == "" or v == 0 or v == "0" then
        return false
    end
    pcall(function()
        SetVar(GlobalVars(), ACTION_VAR, "")
    end)
    -- A fader drag queues many levels for the same target: only send the
    -- newest one per layer + parameter.
    local actions = {}
    local last_for = {}
    for action in tostring(v):gmatch("[^;]+") do
        actions[#actions + 1] = action
        local key = action:match("^(lvl,%d+,%a+),")
        if key then
            last_for[key] = #actions
        end
    end
    local any = false
    for i, action in ipairs(actions) do
        local key = action:match("^(lvl,%d+,%a+),")
        if not key or last_for[key] == i then
            if action == "clearall" or action == "bypass" or action:match("^clear,%d+$") then
                lc.record_event("a", action)
            end
            if lc.run_control_action(action) then
                any = true
            end
        end
    end
    return any
end

--- Fire a queued layout tap (if any) and show it immediately, then run any
--- queued layer / composition controls. Returns true when something ran.
local function handle_pending_fire()
    local acted = lc.process_pending_actions()
    if lc.play_tick() then
        acted = true
    end
    local layer, column = process_pending_fire()
    if not layer then
        return acted
    end
    apply_fired_highlight(layer, column)
    return true
end

--- Returns ok, err, changed, stats_table
local function update_playing_highlights()
    local layout = DataPool().Layouts[LAYOUT_INDEX]
    if layout == nil then
        return false, "Layout not found", 0, nil
    end

    local layer_indexes = {}
    local clip_elements = {}
    for _, element in ipairs(layout:Children()) do
        local note = nil
        pcall(function()
            note = element.Note or element.note
        end)
        local meta = parse_clip_note(note)
        if meta then
            local cached = lc.play_cache[meta.id]
            if cached ~= nil then
                meta.playing = cached
            end
            clip_elements[#clip_elements + 1] = { element = element, meta = meta }
            if meta.layer and meta.layer > 0 then
                layer_indexes[meta.layer] = true
            end
        end
    end

    local t_fetch0 = Time()
    local states, err, bytes, requests
    local mode = "clips"
    local layer_count = 0
    for _ in pairs(layer_indexes) do
        layer_count = layer_count + 1
    end

    local clip_metas = {}
    for _, item in ipairs(clip_elements) do
        clip_metas[#clip_metas + 1] = item.meta
    end

    if #clip_metas > 0 then
        -- Prefer tiny per-clip requests (layer JSON was ~350KB each / ~3s).
        states, err, bytes, requests =
            collect_connected_states_by_clips(clip_metas, 1.0, handle_pending_fire)
        if err == POLL_ABORTED then
            -- A tap fired mid-scan; these results are stale, re-poll right away.
            return true, nil, 0, {
                mode = "aborted",
                fetch_s = Time() - t_fetch0,
                apply_s = 0,
                bytes = bytes or 0,
                requests = requests or 0,
                layers = layer_count,
                clips = #clip_elements,
                aborted = true,
            }
        end
        -- No layer/composition fallback here: those responses are hundreds
        -- of KB and took several seconds each, blocking layout taps meanwhile.
        if not states then
            return false, tostring(err), 0, {
                mode = mode,
                fetch_s = Time() - t_fetch0,
                bytes = bytes or 0,
                requests = requests or 0,
            }
        end
    else
        mode = "composition"
        local composition, comp_err, comp_bytes = fetch_composition(5)
        if not composition then
            return false, tostring(comp_err), 0, {
                mode = mode,
                fetch_s = Time() - t_fetch0,
                bytes = 0,
                requests = 1,
            }
        end
        states = collect_connected_states(composition)
        bytes = comp_bytes or 0
        requests = 1
    end
    local fetch_s = Time() - t_fetch0

    local t_apply0 = Time()
    local changed = 0
    for _, item in ipairs(clip_elements) do
        local meta = item.meta
        local state = states[meta.id] or "Disconnected"
        local playing = is_playing_state(state)
        if playing ~= meta.playing then
            apply_element_playing_state(item.element, meta, playing)
            changed = changed + 1
        end
    end
    local apply_s = Time() - t_apply0

    return true, nil, changed, {
        mode = mode,
        fetch_s = fetch_s,
        apply_s = apply_s,
        bytes = bytes or 0,
        requests = requests or 0,
        layers = layer_count,
        clips = #clip_elements,
    }
end

local function ui_echo(msg)
    pcall(function()
        Echo(msg)
    end)
end

local function cycle_poll_interval()
    local current = get_poll_interval()
    local next_index = 1
    for i, opt in ipairs(POLL_INTERVAL_OPTIONS) do
        if math.abs(opt - current) < 0.001 then
            next_index = (i % #POLL_INTERVAL_OPTIONS) + 1
            break
        end
    end
    local value = set_poll_interval(POLL_INTERVAL_OPTIONS[next_index])
    update_control_button_styles()
    Printf("ResolumeControlPanel: poll interval -> %.2fs", value)
    ui_echo(string.format("ResolumeControlPanel: poll interval -> %.2fs", value))
end

local function run_monitor_loop()
    local interval = get_poll_interval()

    -- Always take ownership. A previous monitor may have been killed when
    -- another Plugin call ran (Cleanup), leaving a stale MONITOR flag.
    local owner = string.format("%0.4f-%d", Time(), math.random(10000, 99999))
    pcall(function()
        SetVar(GlobalVars(), MONITOR_OWNER_VAR, owner)
    end)
    set_monitor_flag(true)
    update_control_button_styles()

    Printf(
        "ResolumeControlPanel: POLL ON - monitor started (v%s)",
        PLUGIN_VERSION
    )
    Printf(
        "  interval=%.2fs  host=%s:%d  url=%s",
        interval,
        RESOLUME_HOST,
        RESOLUME_PORT,
        composition_url()
    )
    ui_echo(string.format(
        "ResolumeControlPanel: POLL ON v%s (%.2fs) %s:%d",
        PLUGIN_VERSION,
        interval,
        RESOLUME_HOST,
        RESOLUME_PORT
    ))

    local function still_owner()
        local current = nil
        pcall(function()
            current = GetVar(GlobalVars(), MONITOR_OWNER_VAR)
        end)
        return tostring(current or "") == owner
    end

    -- Plugins run as coroutines: must yield or the loop is a busy-wait that
    -- freezes / gets aborted, so highlights only refresh when POLL ON is tapped again.
    local tick = 0
    local last_tick_end = Time()
    local fails_in_row = 0
    while get_monitor_flag() and still_owner() do
        tick = tick + 1
        local tick_start = Time()
        local gap_s = tick_start - last_tick_end

        -- Layout taps queue fires here (SetVar) so Plugin/Cleanup never runs.
        handle_pending_fire()

        local ok, err, changed, stats = update_playing_highlights()
        local tick_s = Time() - tick_start
        last_tick_end = Time()

        if not ok then
            fails_in_row = fails_in_row + 1
            -- Log once per outage, not every poll.
            if fails_in_row == 1 then
                Printf("ResolumeControlPanel monitor ERROR: %s", tostring(err))
                ui_echo(string.format("ResolumeControlPanel poll ERROR: %s", tostring(err)))
            end
            if fails_in_row >= lc.OFFLINE_STOP_AFTER then
                Printf(
                    "ResolumeControlPanel: no answer from Resolume %s:%d in %d polls - POLL stopped. Tap POLL ON when Resolume is running again.",
                    RESOLUME_HOST,
                    RESOLUME_PORT,
                    fails_in_row
                )
                ui_echo("ResolumeControlPanel: Resolume not reachable - POLL stopped")
                break
            end
        else
            if fails_in_row > 0 then
                Printf("ResolumeControlPanel: Resolume answering again")
            end
            fails_in_row = 0
            -- Always log the first few ticks so slow fetches are obvious.
            if tick <= 5 or (changed and changed > 0) or (tick % 20 == 0) then
                Printf(
                    "ResolumeControlPanel: poll #%d changed=%d total=%.2fs fetch=%.2fs apply=%.2fs gap=%.2fs mode=%s req=%d bytes=%d layers=%d",
                    tick,
                    changed or 0,
                    tick_s,
                    stats and stats.fetch_s or 0,
                    stats and stats.apply_s or 0,
                    gap_s,
                    stats and stats.mode or "?",
                    stats and stats.requests or 0,
                    stats and stats.bytes or 0,
                    stats and stats.layers or 0
                )
            end
            if tick == 1 then
                ui_echo(string.format(
                    "ResolumeControlPanel: first poll %.2fs (fetch %.2fs, mode=%s)",
                    tick_s,
                    stats and stats.fetch_s or 0,
                    stats and stats.mode or "?"
                ))
            end
        end

        if not get_monitor_flag() or not still_owner() then
            break
        end

        -- Wait in short slices so a layout tap fires within ~FIRE_CHECK_SEC
        -- instead of waiting out the whole poll interval. A tap ends the wait
        -- early so the next poll confirms the new state at once. An aborted
        -- poll (tap fired mid-scan) skips the wait entirely.
        interval = get_poll_interval()
        if not ok then
            interval = math.max(interval, lc.OFFLINE_RETRY_SEC)
        end
        local until_t = Time() + interval
        local skip_wait = stats and stats.aborted
        while not skip_wait and get_monitor_flag() and still_owner() do
            if handle_pending_fire() then
                break
            end
            local remaining = until_t - Time()
            if remaining <= 0 then
                break
            end
            local slice = math.min(FIRE_CHECK_SEC, remaining)
            local yield_ok = pcall(function()
                coroutine.yield(slice)
            end)
            if not yield_ok then
                local slice_end = Time() + slice
                while Time() < slice_end do
                end
            end
        end
    end

    if still_owner() then
        set_monitor_flag(false)
        update_control_button_styles()
        Printf("ResolumeControlPanel: POLL OFF - monitor stopped (after %d ticks)", tick)
        ui_echo("ResolumeControlPanel: POLL OFF - monitor stopped")
    else
        Printf("ResolumeControlPanel: monitor instance replaced (after %d ticks)", tick)
    end
end

------------------------------------------------------------------------
-- Fader popup
------------------------------------------------------------------------

--- Queue a level for the poll loop (same path as the layout buttons).
function lc.queue_level(scope, kind, frac)
    if frac < 0 then
        frac = 0
    elseif frac > 1 then
        frac = 1
    end
    local raw = frac
    if kind == "audio" then
        raw = lc.fraction_to_volume(lc.get_volume_param(scope), frac)
    end
    local action = string.format("lvl,%d,%s,%.3f,%.4f", scope, kind, frac, raw)
    pcall(function()
        local cur = tostring(GetVar(GlobalVars(), ACTION_VAR) or "")
        SetVar(GlobalVars(), ACTION_VAR, cur .. ";" .. action)
    end)
end

--- UiFader values arrive as "50%" (or a number); return 0..1.
function lc.parse_fader_value(v)
    local n = tonumber(tostring(v or ""):match("%-?[%d%.]+"))
    if n == nil then
        return nil
    end
    if n > 1.0001 or tostring(v):find("%%") then
        n = n / 100
    end
    return n
end

function lc.fader_title(scope, kind)
    if scope == 0 then
        return "Composition Grand Master"
    end
    local names = { master = "Master", audio = "Audio", video = "Video" }
    return string.format("Layer %d %s", scope, names[kind] or kind)
end

--- Pop up a draggable fader for one layer / composition level.
--- Returns true when the on-screen dialog was built.
--- x, y, w, h from an AbsRect (table with x/y/w/h keys, X/Y/W/H keys,
--- an array, or a "x,y,w,h" string, depending on the build).
function lc.rect_numbers(r)
    if r == nil then
        return nil
    end
    if type(r) == "string" then
        local n = {}
        for v in r:gmatch("-?%d+%.?%d*") do
            n[#n + 1] = tonumber(v)
        end
        r = n
    end
    local x, y, w, h
    pcall(function()
        x = r.x or r.X or r[1]
        y = r.y or r.Y or r[2]
        w = r.w or r.W or r.width or r[3]
        h = r.h or r.H or r.height or r[4]
    end)
    x, y = tonumber(x), tonumber(y)
    if x == nil or y == nil then
        return nil
    end
    return x, y, tonumber(w), tonumber(h)
end

--- Move the popup next to where the screen was tapped / clicked (the
--- cursor position) instead of the screen centre. Right of the cursor,
--- or left of it when there is no room, and kept fully on screen.
function lc.place_near_cursor(base, overlay, w, h)
    local ok, err = pcall(function()
        local mx, my = lc.rect_numbers(MouseObj().AbsRect)
        if mx == nil then
            error("no cursor position")
        end
        local ox, oy, ow, oh = lc.rect_numbers(overlay.AbsRect)
        ox, oy = ox or 0, oy or 0
        ow, oh = ow or 1920, oh or 1080
        mx, my = mx - ox, my - oy
        local gap = 30
        local x = mx + gap
        if x + w > ow then
            x = mx - gap - w
        end
        local y = my - h / 2
        x = math.max(0, math.min(x, ow - w))
        y = math.max(0, math.min(y, oh - h))
        pcall(function()
            base.AlignmentH = "Left"
        end)
        pcall(function()
            base.AlignmentV = "Top"
        end)
        base.X = math.floor(x)
        base.Y = math.floor(y)
        Printf(
            "ResolumeControlPanel: fader popup at %d,%d (cursor %d,%d)",
            math.floor(x),
            math.floor(y),
            math.floor(mx),
            math.floor(my)
        )
    end)
    if not ok then
        Printf("ResolumeControlPanel: fader popup stays centred (%s)", tostring(err))
    end
end

function lc.open_fader_dialog(scope, kind)
    local current = lc.get_level(scope, kind)

    local picked_up = false
    local last_frac = nil
    local signals = signalTable or {}
    signals.MADFaderChanged = function(caller)
        local value = nil
        pcall(function()
            value = caller.Value
        end)
        if value == nil then
            pcall(function()
                value = caller:Get("Value")
            end)
        end
        local frac = lc.parse_fader_value(value)
        if not frac then
            return
        end
        -- Pick-up: the popup fader may open at 0 instead of the current
        -- level. Send nothing until it reaches / crosses the current level,
        -- so grabbing it never makes the picture or sound jump.
        if not picked_up then
            local near = math.abs(frac - current) <= 0.03
            local crossed = last_frac ~= nil and (last_frac - current) * (frac - current) <= 0
            last_frac = frac
            if not (near or crossed) then
                pcall(function()
                    caller.Text = string.format(
                        "%s -> %d%%",
                        lc.fader_label(scope, kind, frac),
                        math.floor(current * 100 + 0.5)
                    )
                end)
                return
            end
            picked_up = true
        end
        pcall(function()
            caller.Text = lc.fader_label(scope, kind, frac)
        end)
        lc.queue_level(scope, kind, frac)
    end

    local ok, err = pcall(function()
        local display = GetFocusDisplay()
        local overlay = display.ScreenOverlay
        overlay:ClearUIChildren()

        local base = overlay:Append("BaseInput")
        base.Name = "ResArena Fader Control"
        base.W = 260
        base.H = 620
        lc.place_near_cursor(base, overlay, 260, 620)
        base.Columns = 1
        base.Rows = 2
        base[1][1].SizePolicy = "Fixed"
        base[1][1].Size = "60"
        base[1][2].SizePolicy = "Stretch"
        base.AutoClose = "No"
        base.CloseOnEscape = "Yes"

        local title = base:Append("TitleBar")
        title.Columns = 2
        title.Rows = 1
        title.Anchors = "0,0"
        title[2][2].SizePolicy = "Fixed"
        title[2][2].Size = "50"
        title.Texture = "corner2"

        local caption = title:Append("TitleButton")
        caption.Text = lc.fader_title(scope, kind)
        caption.Texture = "corner1"
        caption.Anchors = "0,0"

        local close = title:Append("CloseButton")
        close.Anchors = "1,0"
        close.Texture = "corner2"

        local frame = base:Append("DialogFrame")
        frame.H = "100%"
        frame.W = "100%"
        frame.Columns = 1
        frame.Rows = 1
        frame.Anchors = { left = 0, right = 0, top = 1, bottom = 1 }

        local fader = frame:Append("UiFader")
        fader.Anchors = "0,0"
        fader.Text = lc.fader_label(scope, kind, current)
        fader.PluginComponent = myHandle
        fader.Changed = "MADFaderChanged"
        pcall(function()
            local c = lc.LEVEL_COLOR[kind] or lc.LEVEL_COLOR.master
            fader.Color = string.format("%.3f,%.3f,%.3f,1", c.r / 255, c.g / 255, c.b / 255)
        end)
        -- Start at the current level where the build allows setting it
        -- (UiFader.Value is read-only on some versions; pick-up covers that).
        local pct = math.floor(current * 100 + 0.5)
        local set_ok = pcall(function()
            fader.Value = pct
        end)
        if not set_ok then
            set_ok = pcall(function()
                fader:Set("Value", tostring(pct))
            end)
        end
        if not set_ok then
            pcall(function()
                fader.Value = string.format("%d%%", pct)
            end)
        end
        local start = nil
        pcall(function()
            start = lc.parse_fader_value(fader.Value)
        end)
        if start and math.abs(start - current) <= 0.03 then
            picked_up = true
        else
            fader.Text = string.format(
                "%s (%d%%)",
                lc.fader_title(scope, kind),
                pct
            )
        end
    end)

    if ok then
        Printf("ResolumeControlPanel: fader popup %s", lc.fader_title(scope, kind))
        return true
    end

    -- Fallback: type a value (0-100) when the UI objects are unavailable.
    Printf("ResolumeControlPanel: fader popup failed (%s), asking for a value", tostring(err))
    local typed = nil
    pcall(function()
        typed = TextInput(
            lc.fader_title(scope, kind) .. " (0-100)",
            tostring(math.floor(current * 100 + 0.5))
        )
    end)
    local n = tonumber(typed)
    if n then
        lc.queue_level(scope, kind, n / 100)
    end
    return false
end

------------------------------------------------------------------------
-- Uninstall (Kaldır): delete everything this plugin created, and nothing
-- else. Objects are matched by the exact names the plugin gives them.
------------------------------------------------------------------------

lc.OWN_MACRO_PATTERNS = {
    "^Res_Sync$", "^Res_PollOn$", "^Res_PollOff$", "^Res_Interval$", "^Res_TrigToggle$",
    "^Res_Clip_L%d+C%d+$", "^Res_ClearAll$", "^Res_Bypass$", "^Res_GrandMaster$",
    "^Res_L%d+_Clear$", "^Res_L%d+_[MAV]$",
    "^Res_Rec%d+$", "^Res_Play%d+$", "^Res_Scene%d+$",
}
lc.OWN_LAYOUT_NAMES = { "ResolumeControlPanel", "MA3ArenaDeck" }

function lc.is_own_macro_name(name)
    for _, pattern in ipairs(lc.OWN_MACRO_PATTERNS) do
        if name:find(pattern) then
            return true
        end
    end
    return false
end

--- Slots in `pool` whose object name passes `match(name)`.
function lc.find_own(pool, match)
    local found = {}
    if pool == nil then
        return found
    end
    local count = 0
    pcall(function()
        count = tonumber(pool:Count()) or 0
    end)
    for i = 1, count do
        local obj = pool[i]
        if pool_object_valid(obj) then
            local name = object_name(obj)
            if name ~= nil and match(name) then
                found[#found + 1] = { index = i, name = name }
            end
        end
    end
    return found
end

function lc.collect_own_objects()
    local own_layout_names = { [LAYOUT_NAME] = true }
    for _, n in ipairs(lc.OWN_LAYOUT_NAMES) do
        own_layout_names[n] = true
    end
    local legacy = {}
    for _, n in ipairs(lc.LEGACY_APPEARANCES) do
        legacy[n] = true
    end
    return {
        layouts = lc.find_own(get_layouts_pool(), function(name)
            return own_layout_names[name] == true
        end),
        macros = lc.find_own(DataPool().Macros, lc.is_own_macro_name),
        appearances = lc.find_own(get_appearances_pool(), function(name)
            return name:find("^Res_%d+$") ~= nil or name:find("^ResP_%d+$") ~= nil or legacy[name] == true
        end),
        images = lc.find_own(get_images_pool(), function(name)
            return name:find("^Res_%d+$") ~= nil
        end),
    }
end

function lc.delete_slot(pool, index, cmd)
    if pool_object_valid(pool[index]) then
        pcall(function()
            pool:Delete(index)
        end)
    end
    if pool_object_valid(pool[index]) then
        pcall(function()
            Cmd(cmd)
        end)
    end
end

--- Every ResArena_ GlobalVar the plugin may have written.
function lc.delete_global_vars()
    local keys = {
        "Host", "Port", "LayoutIndex", "LayoutName", "ImageStart", "AppearanceStart",
        "MacroStart", "OnlyWithThumbnail", "FetchThumbnails", "HighlightPreviewing",
        "PollInterval", "Monitor", "MonitorOwner", "Trigger", "Fire", "Action", "Bypassed",
    }
    for n = 1, lc.SCENE_COUNT do
        keys[#keys + 1] = "Scene" .. n
    end
    for scope = 0, 64 do
        keys[#keys + 1] = "VolR_" .. scope
        for _, kind in ipairs({ "master", "audio", "video" }) do
            keys[#keys + 1] = string.format("Lvl_%d_%s", scope, kind)
        end
    end
    for _, key in ipairs(keys) do
        pcall(function()
            DelVar(GlobalVars(), CFG_PREFIX .. key)
        end)
    end
end

function lc.run_uninstall(display_handle)
    load_config()
    local own = lc.collect_own_objects()
    local summary = string.format(
        "%d layout, %d macro, %d appearance, %d image\n"
            .. "and the thumbnail files and ResArena_ settings will be deleted.\n"
            .. "Nothing else in the show is touched.",
        #own.layouts,
        #own.macros,
        #own.appearances,
        #own.images
    )
    local options = {
        title = "ResolumeControlPanel",
        message = summary,
        commands = {
            { value = 1, name = "Kald\196\177r" },
            { value = 0, name = "\196\176ptal" },
        },
    }
    if display_handle ~= nil then
        options.display = display_handle
    end
    local ok, result = pcall(MessageBox, options)
    local cmd = ok and type(result) == "table" and tonumber(result.result) or 0
    if cmd ~= 1 then
        Printf("ResolumeControlPanel: uninstall cancelled")
        return
    end

    set_monitor_flag(false)

    local layouts = get_layouts_pool()
    for i = #own.layouts, 1, -1 do
        local idx = own.layouts[i].index
        lc.delete_slot(layouts, idx, string.format("Delete Layout %d /NoConfirmation", idx))
    end
    local macros = DataPool().Macros
    for i = #own.macros, 1, -1 do
        local idx = own.macros[i].index
        lc.delete_slot(macros, idx, string.format("Delete Macro %d /NoConfirmation", idx))
    end
    for i = #own.appearances, 1, -1 do
        lc.delete_appearance(own.appearances[i].index)
    end
    local images = get_images_pool()
    local lib = images_library_path()
    for i = #own.images, 1, -1 do
        delete_image_slot(images, own.images[i].index)
        if lib ~= nil and lib ~= "" then
            local png = path_join(lib, own.images[i].name .. ".png")
            pcall(os.remove, png)
            pcall(os.remove, png .. ".xml")
        end
    end
    lc.delete_global_vars()

    local done = string.format(
        "ResolumeControlPanel removed: %d layout, %d macro, %d appearance, %d image.",
        #own.layouts,
        #own.macros,
        #own.appearances,
        #own.images
    )
    Printf("%s", done)
    pcall(MessageBox, {
        title = "ResolumeControlPanel",
        message = done .. "\nYou can now delete the plugin from the Plugin pool.",
        commands = { { value = 1, name = "OK" } },
        display = display_handle,
    })
end

--- First screen when the plugin is tapped in the Plugin pool.
function lc.choose_install_or_uninstall(display_handle)
    local options = {
        title = "ResolumeControlPanel",
        message = "Kur: setup and Sync.\nKald\196\177r: delete everything this plugin created.",
        commands = {
            { value = 1, name = "Kur" },
            { value = 2, name = "Kald\196\177r" },
            { value = 0, name = "\196\176ptal" },
        },
    }
    if display_handle ~= nil then
        options.display = display_handle
    end
    local ok, result = pcall(MessageBox, options)
    if not ok then
        -- No chooser on this build: fall back to the setup dialog.
        return "install"
    end
    local cmd = type(result) == "table" and tonumber(result.result) or tonumber(result)
    if cmd == 1 then
        return "install"
    elseif cmd == 2 then
        return "uninstall"
    end
    return "cancel"
end

------------------------------------------------------------------------
-- Actions
------------------------------------------------------------------------

local function run_full_sync()
    -- Ensure a running monitor yields before we rebuild the layout.
    set_monitor_flag(false)

    Printf("ResolumeControlPanel: SYNC starting (v%s)", PLUGIN_VERSION)
    -- Check the layout slot first, so nothing is created when it is taken.
    local blocked = lc.layout_slot_blocked()
    if blocked then
        Printf("ResolumeControlPanel: SYNC stopped - %s", blocked)
        pcall(MessageBox, {
            title = "ResolumeControlPanel",
            message = blocked,
            commands = { { value = 1, name = "OK" } },
        })
        return
    end
    Printf("ResolumeControlPanel: fetching composition...")
    local clips, err, composition, grid = fetch_available_clips()
    if not clips then
        Printf("ResolumeControlPanel ERROR: %s", tostring(err))
        Printf("Check that Resolume Webserver is enabled and reachable at %s", composition_url())
        return
    end

    print_clips(clips, composition, grid)

    lc.delete_legacy_appearances()
    local appearance_map = sync_thumbnails(clips)

    Printf("ResolumeControlPanel: building Layout %d '%s'...", LAYOUT_INDEX, LAYOUT_NAME)
    local layout, layout_err, created = build_layout(clips, grid, appearance_map)
    if not layout then
        Printf("ResolumeControlPanel ERROR: %s", tostring(layout_err))
        return
    end

    local ctrl = ensure_control_macros() or {}
    local function ctrl_index(i)
        return ctrl[i] and ctrl[i].index or 0
    end

    Printf(
        "ResolumeControlPanel: layout ready (%d elements, %d clips, %d layer rows)",
        created or 0,
        #clips,
        grid.layer_count
    )
    Printf(
        "Controls: Macro %d SYNC | %d POLL ON | %d POLL OFF | %d INTERVAL | %d TRIG",
        ctrl_index(1),
        ctrl_index(2),
        ctrl_index(3),
        ctrl_index(4),
        ctrl_index(5)
    )
    Printf(
        "Trigger mode: %s (tap clips %s)",
        get_trigger_flag() and "ON" or "OFF",
        get_trigger_flag() and "fire Resolume" or "monitor only"
    )
end

------------------------------------------------------------------------
-- Entry point
------------------------------------------------------------------------

function Main(display_handle, argument)
    load_config()
    -- Re-read the Macros pool each run; the user may have changed it.
    lc.macro_by_name = nil

    -- Normalize argument. Pool taps often pass nil; macros pass "sync"/etc.
    -- Some builds pass a non-string; coerce safely.
    local arg = ""
    if argument ~= nil then
        arg = tostring(argument):lower():gsub("^%s+", ""):gsub("%s+$", "")
    end

    Printf(
        "ResolumeControlPanel: v%s starting (%s) arg='%s' (type=%s)",
        PLUGIN_VERSION,
        tostring(pluginName or "plugin"),
        arg,
        type(argument)
    )

    -- Fire a Resolume clip (from per-clip layout macros). Keep this first / cheap.
    local trig_layer, trig_col = arg:match("^trigger%s+(%d+)%s+(%d+)$")
    if trig_layer then
        fire_resolume_clip(tonumber(trig_layer), tonumber(trig_col), nil)
        return
    end
    local trig_id = arg:match("^trigger%s+id%s+([%w%-]+)$")
    if trig_id then
        fire_resolume_clip(nil, nil, trig_id)
        return
    end

    -- Layout M / A / V / GM buttons: open a fader popup, then keep polling
    -- (this call replaces the running monitor) so fader moves are sent.
    local fader_scope, fader_kind = arg:match("^fader%s+(%d+)%s+(%a+)$")
    if fader_scope then
        if not ensure_deps() then
            return
        end
        lc.open_fader_dialog(tonumber(fader_scope), fader_kind)
        run_monitor_loop()
        return
    end

    if arg == "trigtoggle" or arg == "trig" or arg == "trigger toggle" then
        toggle_trigger_mode()
        -- Calling Plugin replaces the previous monitor coroutine; always resume poll.
        if not ensure_deps() then
            return
        end
        run_monitor_loop()
        return
    end

    if arg == "stop" or arg == "polloff" or arg == "poll off" or arg == "off" then
        set_monitor_flag(false)
        update_control_button_styles()
        Printf("ResolumeControlPanel: stop requested")
        return
    end

    if arg == "interval" or arg == "pollinterval" or arg == "poll interval" then
        cycle_poll_interval()
        return
    end

    if arg == "monitor" or arg == "pollon" or arg == "poll on" or arg == "on" then
        if not ensure_deps() then
            return
        end
        run_monitor_loop()
        return
    end

    -- Layout SYNC button: sync without dialog.
    if arg == "sync" then
        if not ensure_deps() then
            return
        end
        run_full_sync()
        return
    end

    if arg == "uninstall" then
        lc.run_uninstall(display_handle)
        return
    end

    -- Plugin pool: Kur (setup) / Kaldır (uninstall) first; "setup" skips it.
    if arg ~= "setup" then
        local choice = lc.choose_install_or_uninstall(display_handle)
        if choice == "uninstall" then
            lc.run_uninstall(display_handle)
            return
        elseif choice ~= "install" then
            return
        end
    end
    local action = show_setup_dialog(display_handle)
    if action ~= "sync" then
        return
    end
    if not ensure_deps() then
        return
    end
    run_full_sync()
end

function Cleanup()
    -- Intentionally do NOT clear MONITOR_VAR here.
    -- Any other Plugin invocation (old trigger macros, interval, etc.) would
    -- stop the poll via Cleanup. Poll is stopped only by POLL OFF / SYNC.
end

return Main, Cleanup
