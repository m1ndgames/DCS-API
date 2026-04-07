-- dcsapi.lua
-- Place this file in: Saved Games/DCS World/Scripts/Hooks/dcsapi.lua
--
-- This script runs in the DCS Hooks environment (always-on, server-side).
-- It handles mission lifecycle events and pushes player + mission data to
-- the dcsapi.dll, which forwards everything to the API backend.

-- The DLL lives in Scripts/DCS-API/, which is not on the default cpath.
package.cpath = package.cpath .. ";" .. lfs.writedir() .. "Scripts/DCS-API/?.dll"
local dcsapi = require("dcsapi")

-- Read dcsapi.cfg from Scripts/DCS-API/ and return a config table.
-- Missing keys fall back to the defaults below.
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

local cfg = load_config()
dcsapi.init(cfg.host, cfg.port, cfg.api_key)

-- Read max player slots from serverSettings.lua once at startup.
-- net.get_config() does not exist in the Hooks environment.
local function read_max_players()
    local path = lfs.writedir() .. "Config/serverSettings.lua"
    local chunk, _ = loadfile(path)
    if not chunk then return 0 end
    local env = {}
    setfenv(chunk, env)
    local ok = pcall(chunk)
    if ok and env.cfg and env.cfg.maxPlayers then
        return tonumber(env.cfg.maxPlayers) or 0
    end
    return 0
end

local players_max = read_max_players()

-- unitId (string) -> { type, name }, built once per mission load from DCS.getCurrentMission().
-- nil means not yet built (or reset after mission stop).
local unit_by_slot_id = nil

local function ensure_unit_map()
    if unit_by_slot_id then return end
    unit_by_slot_id = {}
    local ok, md = pcall(function() return DCS.getCurrentMission() end)
    if not ok or not md or not md.mission then return end
    for _, coalition in pairs(md.mission.coalition or {}) do
        for _, country in ipairs(coalition.country or {}) do
            for _, cat in ipairs({"plane", "helicopter"}) do
                if country[cat] then
                    for _, grp in ipairs(country[cat].group or {}) do
                        for _, unit in ipairs(grp.units or {}) do
                            if unit.unitId and unit.type and unit.name then
                                unit_by_slot_id[tostring(unit.unitId)] = {
                                    type = unit.type,
                                    name = unit.name,
                                }
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Get a player's position and aircraft info via the mission scripting engine.
-- coalition.getPlayers() is the correct DCS API for player-controlled units on a
-- dedicated server. coord.LOtoLL() returns two values (lat, lon), not a table.
-- Returns: lat, lon, alt, type_name, unit_name, speed
local function get_player_data(player_name)
    if not player_name or player_name == "" then return 0, 0, 0, "", "", 0 end
    local ok, result = pcall(function()
        return net.dostring_in("server", string.format([[
            for _, s in ipairs({1, 2}) do
                local ok_p, players = pcall(coalition.getPlayers, s)
                if ok_p and players then
                    for _, unit in ipairs(players) do
                        if Unit.getPlayerName(unit) == %q then
                            local pos = unit:getPosition().p
                            local lat, lon = coord.LOtoLL(pos)
                            local vel = unit:getVelocity()
                            local spd = math.sqrt(vel.x*vel.x + vel.y*vel.y + vel.z*vel.z)
                            return string.format("%%.8f|%%.8f|%%.1f|%%s|%%s|%%.1f",
                                lat, lon, pos.y,
                                unit:getTypeName() or "",
                                unit:getName() or "",
                                spd)
                        end
                    end
                end
            end
            return ""
        ]], player_name))
    end)
    if not ok or not result or result == "" then return 0, 0, 0, "", "", 0 end
    local lat, lon, alt, type_name, unit_name, speed = result:match("([^|]+)|([^|]+)|([^|]+)|([^|]*)|([^|]*)|([^|]*)")
    return tonumber(lat) or 0, tonumber(lon) or 0, tonumber(alt) or 0,
           type_name or "", unit_name or "", tonumber(speed) or 0
end

-- Collect all world units (AI + players + statics) from the mission scripting engine.
-- Results are serialized as tab-separated lines to pass through net.dostring_in.
-- Unit.Category: 0=airplane, 1=helicopter → "air"; 2=ground unit, 3=ship → "ground"; 4=structure → "static"
-- Fields (10): name, class, player_controlled, group_name, type_name, lat, lon, alt, speed, coalition
local UNITS_QUERY = [[
    local lines = {}

    local function unit_type_str(unit)
        local ok, desc = pcall(function() return unit:getDesc() end)
        if not ok or not desc then return "ground" end
        local c = desc.category
        if c == 0 or c == 1 then return "air"
        elseif c == 4 then return "static"
        else return "ground" end
    end

    -- AI units from all coalitions
    for _, side in ipairs({0, 1, 2}) do
        local ok_g, groups = pcall(coalition.getGroups, side)
        if ok_g and groups then
            for _, grp in ipairs(groups) do
                local gname = grp:getName() or ""
                for _, unit in ipairs(grp:getUnits()) do
                    local pos = unit:getPosition().p
                    local lat, lon = coord.LOtoLL(pos)
                    local vel = unit:getVelocity()
                    local spd = math.sqrt(vel.x*vel.x + vel.y*vel.y + vel.z*vel.z)
                    table.insert(lines, string.format("%s\t%s\tfalse\t%s\t%s\t%.8f\t%.8f\t%.1f\t%.1f\t%d",
                        unit:getName() or "", unit_type_str(unit), gname,
                        unit:getTypeName() or "", lat, lon, pos.y, spd, side))
                end
            end
        end
    end

    -- Player-controlled units (not returned by coalition.getGroups)
    for _, side in ipairs({1, 2}) do
        local ok_p, players = pcall(coalition.getPlayers, side)
        if ok_p and players then
            for _, unit in ipairs(players) do
                local ok_grp, grp = pcall(Unit.getGroup, unit)
                local gname = (ok_grp and grp and grp:getName()) or ""
                local pos = unit:getPosition().p
                local lat, lon = coord.LOtoLL(pos)
                local vel = unit:getVelocity()
                local spd = math.sqrt(vel.x*vel.x + vel.y*vel.y + vel.z*vel.z)
                table.insert(lines, string.format("%s\tair\ttrue\t%s\t%s\t%.8f\t%.8f\t%.1f\t%.1f\t%d",
                    unit:getName() or "", gname, unit:getTypeName() or "", lat, lon, pos.y, spd, side))
            end
        end
    end

    -- Static objects
    for _, side in ipairs({0, 1, 2}) do
        local ok_s, statics = pcall(coalition.getStaticObjects, side)
        if ok_s and statics then
            for _, obj in ipairs(statics) do
                local pos = obj:getPosition().p
                local lat, lon = coord.LOtoLL(pos)
                table.insert(lines, string.format("%s\tstatic\tfalse\t\t%s\t%.8f\t%.8f\t%.1f\t0.0\t%d",
                    obj:getName() or "", obj:getTypeName() or "", lat, lon, pos.y, side))
            end
        end
    end

    return table.concat(lines, "\n")
]]

local function collect_units()
    local ok, result = pcall(net.dostring_in, "server", UNITS_QUERY)
    if not ok or not result or result == "" then return {} end
    local units = {}
    for line in result:gmatch("[^\n]+") do
        local name, uclass, pctrl, gname, utype, lat, lon, alt, spd, coal =
            line:match("([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)")
        if name and name ~= "" then
            table.insert(units, {
                name              = name,
                unit_class        = uclass or "ground",
                unit_type         = utype or "",
                player_controlled = (pctrl == "true"),
                group_name        = gname or "",
                lat       = tonumber(lat)  or 0,
                lon       = tonumber(lon)  or 0,
                alt       = tonumber(alt)  or 0,
                speed     = tonumber(spd)  or 0,
                coalition = tonumber(coal) or 0,
            })
        end
    end
    return units
end

-- Collect all airbases (airports, helipads, FARPs, ships) from the mission scripting engine.
-- Fields (6): name, category, coalition, lat, lon, alt
-- category: "airdrome" (0), "helipad" (1), "ship" (2)
local AIRBASES_QUERY = [[
    local lines = {}
    local cats = {[0]="airdrome", [1]="helipad", [2]="ship"}
    local ok_ab, ab_list = pcall(world.getAirbases)
    if ok_ab and ab_list then
        for _, ab in pairs(ab_list) do
            local ok_p, pos = pcall(function() return ab:getPoint() end)
            if ok_p and pos then
                local lat, lon = coord.LOtoLL(pos)
                local cat  = cats[ab:getCategory()] or "airdrome"
                local coal = ab:getCoalition() or 0
                table.insert(lines, string.format("%s\t%s\t%d\t%.8f\t%.8f\t%.1f",
                    ab:getName() or "", cat, coal, lat, lon, pos.y))
            end
        end
    end
    return table.concat(lines, "\n")
]]

local function collect_airbases()
    local ok, result = pcall(net.dostring_in, "server", AIRBASES_QUERY)
    if not ok or not result or result == "" then return {} end
    local bases = {}
    for line in result:gmatch("[^\n]+") do
        local name, cat, coal, lat, lon, alt =
            line:match("([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)")
        if name and name ~= "" then
            table.insert(bases, {
                name      = name,
                category  = cat or "airdrome",
                coalition = tonumber(coal) or 0,
                lat = tonumber(lat) or 0,
                lon = tonumber(lon) or 0,
                alt = tonumber(alt) or 0,
            })
        end
    end
    return bases
end

-- Collect weather at sea level. Returns: wind_dir (°, met), wind_speed (m/s), temp (°C), pressure (hPa).
-- In DCS coordinates x=north, z=east. Meteorological wind direction = direction FROM which wind blows.
local WEATHER_QUERY = [[
    local pt = {x=0, y=0, z=0}
    local ok_w, wind = pcall(atmosphere.getWind, pt)
    if not ok_w or not wind then wind = {x=0, y=0, z=0} end
    local spd = math.sqrt(wind.x*wind.x + wind.z*wind.z)
    local dir = (math.atan2(wind.z, wind.x) * 180 / math.pi + 180 + 360) % 360
    local ok_tp, temp, pres = pcall(atmosphere.getTemperatureAndPressure, pt)
    if not ok_tp or not temp then temp = 288.15 end
    if not ok_tp or not pres then pres = 101325 end
    return string.format("%.1f|%.2f|%.1f|%.1f", dir, spd, temp - 273.15, pres / 100)
]]

-- Collect bullseye reference points for red (side=1) and blue (side=2) coalitions.
local BULLSEYE_QUERY = [[
    local lines = {}
    for _, side in ipairs({1, 2}) do
        local ok, ref = pcall(coalition.getMainRefPoint, side)
        if ok and ref then
            local lat, lon = coord.LOtoLL(ref)
            table.insert(lines, string.format("%d|%.8f|%.8f", side, lat, lon))
        end
    end
    return table.concat(lines, "\n")
]]

local UPDATE_INTERVAL = 1.0  -- seconds between API updates
local last_update     = 0

local callbacks = {}

-- Called when the simulation stops (mission ended or server shutdown).
function callbacks.onSimulationStop()
    unit_by_slot_id = nil  -- reset so next mission rebuilds the map
    dcsapi.update_mission("", 0, "", 0)
    dcsapi.update_players({})
    dcsapi.update_units({})
    dcsapi.update_airbases({})
    dcsapi.update_weather(0, 0, 0, 0)
    dcsapi.update_bullseye(0, 0, 0, 0)
end

-- Called every simulation frame. We throttle actual updates to UPDATE_INTERVAL
-- to avoid hammering the API backend on every frame.
function callbacks.onSimulationFrame()
    local now = DCS.getModelTime()
    if (now - last_update) < UPDATE_INTERVAL then return end
    last_update = now

    ensure_unit_map()

    -- Mission state
    local mission_name = DCS.getMissionName() or ""

    local map = ""
    local ok, mission_data = pcall(function() return DCS.getCurrentMission() end)
    if ok and mission_data and mission_data.mission then
        map = mission_data.mission.theatre or ""
    end

    dcsapi.update_mission(mission_name, now, map, players_max)

    -- Player list
    local players = {}
    for _, id in ipairs(net.get_player_list()) do
        if id ~= 1 then
            local info = nil
            local ok_info, result = pcall(function() return net.get_player_info(id) end)
            if ok_info and type(result) == "table" then info = result end

            local player_name = net.get_name(id) or ""
            local lat, lon, alt, dyn_aircraft, dyn_unit_name, speed = get_player_data(player_name)

            local slot_id   = (info and info.slot) or ""
            local slot_data = unit_by_slot_id[slot_id]
            local aircraft  = (slot_data and slot_data.type) or dyn_aircraft
            local unit_name = (slot_data and slot_data.name) or dyn_unit_name

            table.insert(players, {
                name      = player_name,
                player_id = id,
                aircraft  = aircraft,
                unit_name = unit_name,
                ucid      = (info and info.ucid)   or "",
                ip        = (info and info.ipaddr) or "",
                coalition = (info and info.side)   or 0,
                lat = lat, lon = lon, alt = alt,
                speed = speed,
            })
        end
    end
    dcsapi.update_players(players)

    -- All world units (AI + players + statics)
    dcsapi.update_units(collect_units())

    -- Airbases
    dcsapi.update_airbases(collect_airbases())

    -- Weather
    local ok_wx, wx_str = pcall(net.dostring_in, "server", WEATHER_QUERY)
    if ok_wx and wx_str and wx_str ~= "" then
        local wd, ws, temp, pres = wx_str:match("([^|]+)|([^|]+)|([^|]+)|([^|]+)")
        dcsapi.update_weather(
            tonumber(wd)   or 0,
            tonumber(ws)   or 0,
            tonumber(temp) or 15,
            tonumber(pres) or 1013.25)
    end

    -- Bullseye
    local ok_bull, bull_str = pcall(net.dostring_in, "server", BULLSEYE_QUERY)
    if ok_bull and bull_str and bull_str ~= "" then
        local rl, rlo, bl, blo = 0, 0, 0, 0
        for line in bull_str:gmatch("[^\n]+") do
            local side_s, lat_s, lon_s = line:match("([^|]+)|([^|]+)|([^|]+)")
            local s = tonumber(side_s)
            if s == 1 then
                rl, rlo = tonumber(lat_s) or 0, tonumber(lon_s) or 0
            elseif s == 2 then
                bl, blo = tonumber(lat_s) or 0, tonumber(lon_s) or 0
            end
        end
        dcsapi.update_bullseye(rl, rlo, bl, blo)
    end
end

DCS.setUserCallbacks(callbacks)
