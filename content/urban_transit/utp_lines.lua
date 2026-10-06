-- UTP line + vehicle planner v0.8: one radial tram line through the new
-- stops, then best-effort tram purchase/assignment.
--
-- Recipe provenance (verified by direct reading, credited):
--   bus_loops_1 bus_loops_core.lua: makeLine/getBestLineAssignment (:434-463),
--   passengerLoad (:422-432), makeTvc/makeTvcPart (:398-420), availableBuses
--   via modelRep (:352-396), findBestDepotForLine + buy/assign (:706-734),
--   makeLineCreateCmd + result entity extraction (:736-753).
--   Shipped twin: gui/line_vehicle_mgmt/manager_window.tl:6523-6544
--   (makeLineCreateCmd same arg order) and line_util.tl:224
--   (getBestLineAssignment(-1-or-entity, comp, true), fallback 0).
--
-- Tram specifics (marked): Carrier.TRAM exists (api/tealdef/api/type.d.tl
-- :398-406); depot search uses it with the line's tram mode, falling back
-- to the other tram mode when the first yields no depot. Vehicle count
-- formula is a documented heuristic, not engine data:
--   n = clamp(1, floor(corridorLength / METERS_PER_TRAM) + 1, #groups).
-- A radial line lists groups in corridor order; the game closes the loop
-- (out-and-back over the same streets), so one line suffices.

local lines = {}

local logger = nil
pcall(function()
    logger = ug_require("urban_transport_planner::/urban_transit/utp_logger.lua")
end)

lines.METERS_PER_TRAM = 500
lines.DEPOT_RADIUS = 4000 -- bus_loops pre-check radius (m)
lines.LINE_COLOR = { 0.2, 0.7, 0.3 }

local function logRaw(msg)
    if logger and logger.raw then logger.raw(msg)
    else print("[Urban Tram Planner Alpha] " .. tostring(msg)) end
end

local function errorText(err)
    if logger and logger.errorText then return logger.errorText(err) end
    return tostring(err)
end
lines.errorText = errorText

local function tramMode(wantElectric)
    local ok, m = pcall(function()
        return api.type.enum["TransportMode"][wantElectric and "ELECTRIC_TRAM" or "TRAM"]
    end)
    return ok and m or nil
end

function lines.vehicleCount(corridorLength, groupCount)
    local n = math.floor((corridorLength or 0) / lines.METERS_PER_TRAM) + 1
    if n < 1 then n = 1 end
    if groupCount and groupCount >= 1 and n > groupCount then n = groupCount end
    return n
end

-- Passenger-only stop cargo config (bus_loops passengerLoad).
local function passengerLoad()
    local pax = api.res.cargoTypeRep.getPassengerCargoTypeId()
    local n = pax + 1
    for id in pairs(api.res.cargoTypeRep.getAll()) do
        if id + 1 > n then n = id + 1 end
    end
    local load, maxLoad = {}, {}
    for i = 1, n do load[i], maxLoad[i] = false, 0 end
    load[pax + 1], maxLoad[pax + 1] = true, 1
    return load, maxLoad
end

function lines.makeLine(groups)
    local comp = api.type.Line.new()
    local stops = {}
    for _, g in ipairs(groups) do
        local s = api.type.Line.Stop.new()
        s.stationGroup = g
        s.station = -1
        s.terminal = -1
        stops[#stops + 1] = s
    end
    comp.stops = stops
    local ok, best = pcall(api.engine.system.lineSystem.getBestLineAssignment, -1, comp, true)
    stops = {}
    for i, g in ipairs(groups) do
        local s = api.type.Line.Stop.new()
        s.stationGroup = g
        local b = ok and best and best[i]
        s.station = (b and b.station and b.station >= 0) and b.station or 0
        s.terminal = (b and b.terminal and b.terminal >= 0) and b.terminal or 0
        local cfg = s.stopConfig
        cfg.load, cfg.maxLoad = passengerLoad()
        s.stopConfig = cfg
        stops[#stops + 1] = s
    end
    comp.stops = stops
    return comp
end

-- Trams on sale this year (mirrors bus_loops availableBuses for TRAM modes).
function lines.availableTrams(wantElectric)
    local year = 2000
    pcall(function() year = api.engine.util.getYear() end)
    local list = {}
    local okEach = pcall(api.res.modelRep.forEachModelWithMetadata, "transportVehicle", function(name)
        local id = api.res.modelRep.find(name)
        local model = id and id >= 0 and api.res.modelRep.get(id)
        local md = model and model.metadata
        local tv = md and md.transportVehicle
        if not tv then return end
        local isTram, isElectric = false, false
        for _, mode in pairs(tv.transportModes or {}) do
            if mode == "TRAM" or mode == api.type.enum.TransportMode.TRAM then isTram = true end
            if mode == "ELECTRIC_TRAM" or mode == api.type.enum.TransportMode.ELECTRIC_TRAM then
                isTram, isElectric = true, true
            end
        end
        if not isTram then return end
        if wantElectric and not isElectric then return end
        local av = md.availability or {}
        local from, to = av.yearFrom or 0, av.yearTo or 0
        if (from == 0 or from <= year) and (to == 0 or to > year) then
            local desc = md.description or {}
            local tram = { id = id, name = desc.name or name, from = from, to = to,
                electric = isElectric }
            pcall(function()
                local cap = 0
                for _, c in ipairs(tv.compartments or {}) do
                    local lc = c.loadConfigs and c.loadConfigs[1]
                    cap = cap + (lc and lc.cargoEntry and lc.cargoEntry.capacity or 0)
                end
                tram.capacity = cap
            end)
            list[#list + 1] = tram
        end
    end)
    if not okEach then return {} end
    table.sort(list, function(a, b) return a.from > b.from end)
    return list
end

local function makeTvcPart(modelId)
    local part = api.type.TransportVehiclePart.new()
    part.part.modelId = modelId
    local tv = api.res.modelRep.get(modelId).metadata.transportVehicle
    local lcs, auto = {}, {}
    for _ in ipairs(tv.compartments or {}) do
        local lc = api.type.LoadConfig.new()
        lc.loadConfigIndex = 0
        lcs[#lcs + 1] = lc
        auto[#auto + 1] = true
    end
    part.part.reversed = false
    part.part.compartment2loadConfig = lcs
    part.autoLoadConfig = auto
    return part
end

function lines.makeTvc(modelId)
    local cfg = api.type.TransportVehicleConfig.new()
    cfg.vehicles = { makeTvcPart(modelId) }
    cfg.vehicleGroups = { 1 }
    return cfg
end

-- Pre-check only (the line-based check happens after the line exists):
-- a depot with tram mode + vehicle exits within radius.
function lines.nearbyTramDepot(shape, wantElectric)
    local modes = {}
    pcall(function()
        modes = {
            api.type.enum.TransportMode.TRAM,
            api.type.enum.TransportMode.ELECTRIC_TRAM,
        }
    end)
    local ok, depots = pcall(api.engine.util.octree.findEntitiesInCircle,
        api.type.Vec2f.new(shape.x, shape.y), lines.DEPOT_RADIUS,
        api.type.ComponentType.VEHICLE_DEPOT)
    if not ok or not depots then return nil end
    for _, d in ipairs(depots) do
        local depot = nil
        pcall(function()
            depot = api.engine.getComponent(d, api.type.ComponentType.VEHICLE_DEPOT)
        end)
        if depot then
            local exits = 0
            pcall(function() exits = #depot.outNodes end)
            if exits > 0 then
                local hasTram = false
                pcall(function()
                    for _, m in ipairs(modes) do
                        if depot.transportModes[m] == true then hasTram = true end
                    end
                end)
                if hasTram then return d end
            end
        end
    end
    return nil
end

function lines.bestDepotForLine(line, pos, wantElectric)
    -- Uncertain order: try the line's own mode first, then the other.
    local order = wantElectric and { "ELECTRIC_TRAM", "TRAM" } or { "TRAM", "ELECTRIC_TRAM" }
    for _, modeName in ipairs(order) do
        local depot = nil
        pcall(function()
            depot = api.engine.util.vehicle.findBestDepotForLine(
                api.type.enum.Carrier.TRAM,
                { api.type.enum.TransportMode[modeName] },
                line, pos)
        end)
        if depot and depot >= 0 then return depot end
    end
    return -1
end

-- Create "<town> Tranvia" through groups (corridor order). Calls back
-- with (lineEntity or nil, message, isError).
function lines.createLine(groups, townName, player, report, cb)
    local c = lines.LINE_COLOR
    local compOk, comp = pcall(lines.makeLine, groups)
    if not compOk or not comp then
        cb(nil, "No pude armar la linea: " .. errorText(comp), true)
        return
    end
    local okSend, err = pcall(function()
        api.cmd.sendCommand(
            api.cmd.makeLineCreateCmd(tostring(townName) .. " Tranvia",
                api.type.Vec3f.new(c[1], c[2], c[3]), player, comp),
            function(data, ok, results)
                local line = nil
                pcall(function() line = results[1][1] end)
                if (not line) and data then
                    pcall(function() line = data.resultEntity end)
                end
                if ok and line and line >= 0 then
                    logRaw("line created: entity=" .. tostring(line))
                    cb(line, "Linea creada.", false)
                else
                    logRaw("line create failed")
                    cb(nil, "El juego no acepto la linea de tranvia.", true)
                end
            end)
    end)
    if not okSend then
        cb(nil, "Error creando la linea: " .. errorText(err), true)
    end
end

-- Best-effort tram purchase + assignment. Never fails the whole job:
-- reports what happened.
function lines.buyTrams(line, tramModelId, count, player, pos, wantElectric, report, done)
    local depot = lines.bestDepotForLine(line, pos, wantElectric)
    if not depot or depot < 0 then
        report("Linea creada, pero ningun deposito de tranvias conectado. Compra los tranvias manualmente.", true)
        if done then done(0) end
        return
    end
    local bought = 0
    local function oneMore(n)
        if n > count then
            if done then done(bought) end
            return
        end
        report(string.format("Comprando tranvia %d/%d...", n, count), false)
        pcall(function()
            api.cmd.sendCommand(
                api.cmd.makeVehicleBuyCmd(player, depot, lines.makeTvc(tramModelId)),
                function(data, ok)
                    local vehicle = ok and data and data.resultVehicleEntity
                    if vehicle and vehicle >= 0 then
                        pcall(api.cmd.sendCommand,
                            api.cmd.makeVehicleSetLineCmd(vehicle, line, 0))
                        bought = bought + 1
                    else
                        logRaw("tram purchase failed " .. n .. "/" .. count)
                    end
                    oneMore(n + 1)
                end)
        end)
    end
    oneMore(1)
end

return lines
