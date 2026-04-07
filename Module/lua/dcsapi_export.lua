-- dcsapi_export.lua
-- Loaded by DCS via a single line in Scripts/Export.lua:
--   dofile(lfs.writedir()..'Scripts/dcsapi_export.lua')
--
-- This script runs in the DCS Export environment, called each simulation
-- frame. It provides data not available in the Hooks environment:
-- per-player world positions and server FPS.
--
-- The dcsapi.dll STATE is shared at the process level, so positions written
-- here are immediately visible to the data already set by dcsapi.lua.

local dcsapi = nil

-- Read dcsapi.cfg from Scripts/DCS-API/ and return a config table.
-- Must mirror the same function in dcsapi.lua — both Lua states need init.
local function load_config()
    local cfg = { host = "127.0.0.1", port = 4414, api_key = "" }
    local path = lfs.writedir() .. "Scripts/DCS-API/dcsapi.cfg"
    local f = io.open(path, "r")
    if not f then return cfg end
    for line in f:lines() do
        local key, val = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key == "host" then
            cfg.host = val
        elseif key == "port" then
            cfg.port = tonumber(val) or cfg.port
        elseif key == "api_key" then
            cfg.api_key = val
        end
    end
    f:close()
    return cfg
end

local last_model_time = 0

function LuaExportStart()
    -- The DLL lives in Scripts/DCS-API/, which is not on the default cpath.
    package.cpath = package.cpath .. ";" .. lfs.writedir() .. "Scripts/DCS-API/?.dll"
    dcsapi = require("dcsapi")
    local cfg = load_config()
    dcsapi.init(cfg.host, cfg.port, cfg.api_key)
    last_model_time = LoGetModelTime()
end

function LuaExportStop()
    dcsapi = nil
end

-- LuaExportActivityNextEvent controls how often the export functions are called.
-- Return (t + interval) to schedule the next call. 0.1 = ~10 times per second.
function LuaExportActivityNextEvent(t)
    local interval = 0.1
    return t + interval
end

function LuaExportAfterNextFrame()
    if not dcsapi then return end

    -- LoGetWorldObjects() returns a table of all active objects in the simulation.
    -- Each entry is keyed by the DCS object ID and contains:
    --   .Name          unit name (matches player's unit_name set by dcsapi.lua)
    --   .Type          { level1, level2, level3, level4 } type descriptor
    --   .LatLongAlt    { Lat, Long, Alt } in degrees / meters
    --   .coalitionId   1 = red, 2 = blue
    local obj_positions = {}
    local objects = LoGetWorldObjects()
    if objects then
        for _, obj in pairs(objects) do
            if obj.LatLongAlt and obj.Name then
                obj_positions[obj.Name] = {
                    lat = obj.LatLongAlt.Lat,
                    lon = obj.LatLongAlt.Long,
                    alt = obj.LatLongAlt.Alt,
                }
            end
        end
    end

    dcsapi.set_positions_by_name(obj_positions)

    local now = LoGetModelTime()
    local delta = now - last_model_time
    local fps = delta > 0 and (1.0 / delta) or 0
    last_model_time = now
    dcsapi.set_fps(fps)
end
