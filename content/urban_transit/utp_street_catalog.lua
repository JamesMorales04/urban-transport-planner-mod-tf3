-- UTP street catalog: TransportMode detection, StreetTemplate inventory,
-- structural compatibility and template scoring.
--
-- VERIFIED against game data (Transport Fever 3 base/content):
--   api/tealdef/api/type.d.tl:2211-2227 TransportMode = { ..., TRAM,
--     ELECTRIC_TRAM, ..., TRAM_TRACK, ELECTRIC_TRAM_TRACK, ... }
--   LaneConfig.transportModes : {TransportMode : boolean} (map, check value==true)
--   StreetTemplate.roadType : RoadType { STREET, TRACK }
--   infrastructure/street.zip street templates use lane modes
--     "TRAM" / "ELECTRIC_TRAM" (e.g. town_new_large_tram_electrified has 2 of
--     8 lanes with {"CAR","BUS","TRUCK","TRAM","ELECTRIC_TRAM"}; the plain
--     town_new_large has {"CAR","BUS","TRUCK"} on the same lanes).
--   infrastructure/track.zip rail templates use "TRAM_TRACK" /
--     "ELECTRIC_TRAM_TRACK" and roadType TRACK. They are NOT valid targets
--     for converting a car street and must be excluded from the inventory.
--   street.zip contains NO catenaryAdd field (verified: 0 hits). catenaryAdd
--     exists only on track.zip templates. Do NOT follow catenaryAdd for streets.
--
-- v0.5 bug fixed here: it checked TRAM_TRACK/ELECTRIC_TRAM_TRACK for streets,
-- so the inventory contained only the 6 rail tracks and no street corridor
-- could ever be convertible. Logs proved it (6/6 candidates were
-- ::/infrastructure/track/...).

local catalog = {}

local logger = nil
pcall(function()
    logger = ug_require("urban_transport_planner::/urban_transit/utp_logger.lua")
end)
if logger == nil then logger = { info = function() end, warn = function() end } end

local INF = 1e30
catalog.INF = INF

local function safeField(t, key)
    -- Preserve false: `ok and v or nil` would collapse false to nil and
    -- silently disable country/forward/boolean guards. Return v as-is.
    local ok, v = pcall(function() return t and t[key] end)
    if ok then return v end
    return nil
end
catalog.safeField = safeField

local function resNameString(v)
    if v == nil then return nil end
    if type(v) == "string" then return v ~= "" and v or nil end
    local ok, s = pcall(tostring, v)
    if ok and s and s ~= "" and s ~= "nil" then return s end
    return nil
end

local function enumValue(enumName, key)
    local ok, value = pcall(function() return api.type.enum[enumName][key] end)
    if ok then return value end
    return nil
end

local TRAM = enumValue("TransportMode", "TRAM")
local ELECTRIC_TRAM = enumValue("TransportMode", "ELECTRIC_TRAM")
local TRAM_TRACK = enumValue("TransportMode", "TRAM_TRACK")
local ELECTRIC_TRAM_TRACK = enumValue("TransportMode", "ELECTRIC_TRAM_TRACK")
local CAR = enumValue("CAR", nil) -- placeholder, resolved below
do
    local ok, v = pcall(function() return api.type.enum["TransportMode"]["CAR"] end)
    if ok then CAR = v end
end
catalog.TRAME = function() return TRAM, ELECTRIC_TRAM end

local function modeEnabled(modes, enumVal, enumName)
    if not modes then return false end
    -- Documented shape: map keyed by TransportMode, check value == true.
    if enumVal ~= nil then
        local ok, v = pcall(function() return modes[enumVal] end)
        if ok and v == true then return true end
    end
    if enumName ~= nil then
        local ok, v = pcall(function() return modes[enumName] end)
        if ok and v == true then return true end
    end
    -- Fallback for plain-Lua list-shaped content (mod files on disk).
    local okList, found = pcall(function()
        for _, v in ipairs(modes) do
            if (enumVal ~= nil and v == enumVal) or v == enumName then return true end
        end
        return false
    end)
    return okList and found or false
end
catalog.modeEnabled = modeEnabled

-- Street tram detection: TRAM / ELECTRIC_TRAM on lanes.
local function laneStreetTram(lane)
    local modes = safeField(lane, "transportModes")
    local normal = modeEnabled(modes, TRAM, "TRAM")
    local electric = modeEnabled(modes, ELECTRIC_TRAM, "ELECTRIC_TRAM")
    return normal or electric, electric
end
catalog.laneStreetTram = laneStreetTram

-- Rail-track detection (TRACK templates). Used ONLY to exclude rail from the
-- street inventory, never as a conversion target for streets.
local function laneRailTrack(lane)
    local modes = safeField(lane, "transportModes")
    local t = modeEnabled(modes, TRAM_TRACK, "TRAM_TRACK")
    local e = modeEnabled(modes, ELECTRIC_TRAM_TRACK, "ELECTRIC_TRAM_TRACK")
    return t or e, e
end
catalog.laneRailTrack = laneRailTrack

local function templateStreetTramKinds(tpl)
    local hasTram, hasElectric, tramLanes = false, false, 0
    for _, lane in pairs(safeField(tpl, "laneConfigs") or {}) do
        local t, e = laneStreetTram(lane)
        if t then hasTram = true tramLanes = tramLanes + 1 end
        if e then hasElectric = true end
    end
    local streetModes = safeField(tpl, "transportModesStreet")
    if modeEnabled(streetModes, TRAM, "TRAM") then hasTram = true end
    if modeEnabled(streetModes, ELECTRIC_TRAM, "ELECTRIC_TRAM") then
        hasTram, hasElectric = true, true
    end
    return hasTram, hasElectric, tramLanes
end
catalog.templateStreetTramKinds = templateStreetTramKinds

local function edgeStreetTramKinds(edge)
    local hasTram, hasElectric, tramLanes = false, false, 0
    for _, lane in pairs(safeField(edge, "laneConfigs") or {}) do
        local t, e = laneStreetTram(lane)
        if t then hasTram = true tramLanes = tramLanes + 1 end
        if e then hasElectric = true end
    end
    return hasTram, hasElectric, tramLanes
end
catalog.edgeStreetTramKinds = edgeStreetTramKinds

local function templateHasCarAccess(tpl)
    for _, lane in pairs(safeField(tpl, "laneConfigs") or {}) do
        if modeEnabled(safeField(lane, "transportModes"), CAR, "CAR") then return true end
    end
    return false
end
catalog.templateHasCarAccess = templateHasCarAccess

-- roadType check tolerant to both runtime enum userdata and on-disk strings.
-- Vanilla GUI compares: streetTemplate.roadType == api.type["enum"].RoadType.STREET
local function isStreetRoadType(tpl)
    local rt = safeField(tpl, "roadType")
    if rt == nil then return false end
    if type(rt) == "string" then return rt == "STREET" end
    local ok, street = pcall(function() return api.type.enum["RoadType"]["STREET"] end)
    if ok and street ~= nil then
        local okEq, eq = pcall(function() return rt == street end)
        if okEq then return eq end
    end
    return false
end
catalog.isStreetRoadType = isStreetRoadType

local function laneStats(tpl)
    local count, forward, width, absOffset = 0, 0, 0, 0
    for _, lane in pairs(safeField(tpl, "laneConfigs") or {}) do
        count = count + 1
        if safeField(lane, "forward") == true then forward = forward + 1 end
        width = width + math.abs(tonumber(safeField(lane, "width")) or 0)
        absOffset = absOffset + math.abs(tonumber(safeField(lane, "offset")) or 0)
    end
    return count, forward, width, absOffset
end
catalog.laneStats = laneStats

local function sameIfKnown(a, b)
    return a == nil or b == nil or a == b
end

-- Never turn a town road into a country road / another family, never drop
-- car access, never jump lane counts. Unknown native fields are tolerated.
function catalog.structurallyCompatible(current, candidate)
    local cc, cf = laneStats(current)
    local nc, nf = laneStats(candidate)
    if cc ~= nc or cf ~= nf then return false end
    if not sameIfKnown(safeField(current, "roadType"), safeField(candidate, "roadType")) then return false end
    if not sameIfKnown(safeField(current, "country"), safeField(candidate, "country")) then return false end
    if templateHasCarAccess(current) and not templateHasCarAccess(candidate) then return false end
    return true
end

function catalog.templateScore(current, candidate)
    local hasTram = templateStreetTramKinds(candidate)
    if not hasTram or not catalog.structurallyCompatible(current, candidate) then return INF end
    local cc, cf, cw, co = laneStats(current)
    local nc, nf, nw, no = laneStats(candidate)
    local score = 0
    score = score + math.abs(cc - nc) * 5000
    score = score + math.abs(cf - nf) * 1000
    score = score + math.abs(cw - nw) * 50
    score = score + math.abs(co - no) * 10
    local cs, ns = safeField(current, "streetStyle"), safeField(candidate, "streetStyle")
    if cs ~= nil and ns ~= nil and cs ~= ns then score = score + 500 end
    local cCost, nCost = tonumber(safeField(current, "cost")), tonumber(safeField(candidate, "cost"))
    if cCost and nCost then score = score + math.min(200, math.abs(cCost - nCost) / 20) end
    return score
end

local function currentYear()
    local y = 2000
    pcall(function() y = api.engine.util.getYear() end)
    return y
end
catalog.currentYear = currentYear

local function availableNow(tpl, year)
    local av = safeField(tpl, "availability")
    if not av then return true end
    local from = tonumber(safeField(av, "yearFrom")) or 0
    local to = tonumber(safeField(av, "yearTo")) or 0
    return (from == 0 or from <= year) and (to == 0 or to > year)
end
catalog.availableNow = availableNow

function catalog.streetTemplateByName(name)
    if not name then return nil, nil end
    local rep = api.res.streetTemplateRep
    local ok, id = pcall(rep.find, name)
    if not ok or id == nil or id < 0 then return nil, nil end
    local okGet, tpl = pcall(rep.get, id)
    if not okGet then return nil, nil end
    return tpl, id
end

-- Inventory of STREET templates carrying real TRAM/ELECTRIC_TRAM lanes.
-- Rail TRACK templates are counted for diagnostics but never added.
function catalog.tramStreetInventory(preferElectric)
    local year = currentYear()
    local rep = api.res.streetTemplateRep
    local out, seen = {}, {}
    local diag = {
        totalResources = 0,
        availableResources = 0,
        streetResources = 0,
        directStreetTram = 0,
        railTrackResources = 0,
    }
    local ok, all = pcall(rep.getAll, true)
    if not ok or not all then return out, diag end

    local function addCandidate(name, tpl)
        if not name or not tpl or seen[name] or not availableNow(tpl, year) then return end
        local hasTram, hasElectric, lanes = templateStreetTramKinds(tpl)
        if not hasTram then return end
        seen[name] = true
        out[#out + 1] = {
            name = name,
            tpl = tpl,
            electric = hasElectric,
            trackLanes = lanes,
        }
    end

    for id, name in pairs(all) do
        diag.totalResources = diag.totalResources + 1
        local rid = tonumber(id) or id
        local okGet, tpl = pcall(rep.get, rid)
        if okGet and tpl and availableNow(tpl, year) then
            diag.availableResources = diag.availableResources + 1
            if isStreetRoadType(tpl) then
                diag.streetResources = diag.streetResources + 1
                local hasTram = templateStreetTramKinds(tpl)
                if hasTram then
                    diag.directStreetTram = diag.directStreetTram + 1
                    addCandidate(name, tpl)
                end
            else
                -- Rail TRACK etc: diagnostic only, never a street target.
                local okRail = false
                pcall(function()
                    for _, lane in pairs(safeField(tpl, "laneConfigs") or {}) do
                        local t = laneRailTrack(lane)
                        if t then okRail = true end
                    end
                end)
                if okRail then diag.railTrackResources = diag.railTrackResources + 1 end
            end
        end
    end

    table.sort(out, function(a, b)
        if preferElectric and a.electric ~= b.electric then return a.electric end
        return tostring(a.name) < tostring(b.name)
    end)
    return out, diag
end

function catalog.bestTramStreetTemplate(currentName, inventory, preferElectric)
    local current = catalog.streetTemplateByName(currentName)
    if not current then return nil end

    local currentTram, currentElectric = templateStreetTramKinds(current)
    if currentTram and ((not preferElectric) or currentElectric) then
        return {
            name = currentName,
            score = 0,
            electric = currentElectric,
            alreadyTemplate = true,
            electricFallback = false,
        }
    end

    local best, bestScore = nil, INF
    for _, candidate in ipairs(inventory) do
        if (not preferElectric) or candidate.electric then
            local score = catalog.templateScore(current, candidate.tpl)
            if score < bestScore then
                best, bestScore = candidate, score
            end
        end
    end

    local fallback = false
    if not best and preferElectric then
        fallback = true
        for _, candidate in ipairs(inventory) do
            local score = catalog.templateScore(current, candidate.tpl)
            if score < bestScore then
                best, bestScore = candidate, score
            end
        end
    end

    if not best or bestScore >= INF then return nil end
    return {
        name = best.name,
        score = bestScore,
        electric = best.electric,
        electricFallback = fallback or (preferElectric and not best.electric),
    }
end

return catalog
