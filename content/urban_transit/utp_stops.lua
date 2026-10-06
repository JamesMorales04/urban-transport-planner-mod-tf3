-- UTP stop planner v0.8: place two-sided street stops on the converted
-- tram corridor, one proposal per stop, sequential, failures don't sink rest.
--
-- Recipe provenance (all verified by direct reading, credited):
--   reference mod bus_loops_1 (content/bus_loops/bus_loops_core.lua),
--   a working GUI-side mod:
--     stopModel era thresholds (:311-320), candidate edges (:79-96),
--     cloneEdge/nodeConfigFor/edgeObject/makeStopProposal (:465-539),
--     sequential buildStop with continue-on-refusal (:648-673),
--     station-group discovery via before/after diff (:636-693).
--   Vanilla corroboration: stop .con shape
--     (stations/street.zip:street/small_stops/small_new.con.lua:
--     edgeObject snapToStreet/minDistToCrossing=10/catchment 160m,
--     PASSENGERS+UNIVERSAL, no tram-only stop exists);
--     SimpleStreetProposal.EdgeObject + EdgeObjectType.STOP_LEFT/RIGHT
--     (api/tealdef/api/type.d.tl:416,2760).
--
-- Single-source caveat (marked): borrowing native replaceSegment segments +
-- node configs into a hand-built SimpleProposal has no shipped-script writer;
-- it is proven by the reference mod only. Every stop is therefore built in
-- pcall, validated by the send callback, and a refused stop never aborts the
-- rest. Engine is the authority per stop.
--
-- NOTE: placing a stop splits its edge (remove 1 / add 1), so corridor edge
-- entity IDs go stale afterwards. Line creation below uses station groups
-- (stable), never edges. Re-run analysis to recover live edges.

local stops = {}

local catalog = nil
local logger = nil
pcall(function()
    catalog = ug_require("urban_transport_planner::/urban_transit/utp_street_catalog.lua")
end)
pcall(function()
    logger = ug_require("urban_transport_planner::/urban_transit/utp_logger.lua")
end)

-- Documented constants (origins in comments).
stops.MIN_EDGE_LENGTH = 30        -- bus_loops: 10 m crossing clearance each side
stops.STATION_SCAN_RADIUS = 80    -- bus_loops before/after diff radius (m)
stops.NEW_OBJECT_ID = -400000000 -- bus_loops: engine asserts new edge objects in this range

local function logRaw(msg)
    if logger and logger.raw then logger.raw(msg)
    else print("[Urban Tram Planner Alpha] " .. tostring(msg)) end
end

local function errorText(err)
    if logger and logger.errorText then return logger.errorText(err) end
    return tostring(err)
end
stops.errorText = errorText

local function getComp(entity, name)
    local okType, ct = pcall(function() return api.type.ComponentType[name] end)
    if not okType or ct == nil then return nil end
    local ok, comp = pcall(api.engine.getComponent, entity, ct)
    return ok and comp or nil
end

-- Era-appropriate two-sided stop model (bus_loops stopModel thresholds).
function stops.stopModel()
    local year = 2000
    pcall(function() year = api.engine.util.getYear() end)
    if year < 1920 then
        return "::/stations/street/small_stops/small_old_twosided.con"
    elseif year < 1980 then
        return "::/stations/street/small_stops/small_mid_twosided.con"
    end
    return "::/stations/street/small_stops/small_new_twosided.con"
end

-- Eligible stop edges from a live corridor path: converted to tram,
-- long enough, free of objects, normal structure.
function stops.planStops(path)
    local plan, skipped = {}, { short = 0, objects = 0, unconverted = 0 }
    for _, e in ipairs(path or {}) do
        if not e.satisfies then
            skipped.unconverted = skipped.unconverted + 1
        elseif (e.length or 0) < stops.MIN_EDGE_LENGTH then
            skipped.short = skipped.short + 1
        elseif e.hasObjects then
            skipped.objects = skipped.objects + 1
        else
            plan[#plan + 1] = e
        end
    end
    return plan, skipped
end

-- Components read from the engine are read-only; clone before editing
-- (bus_loops cloneEdge, with hand-copy fallback).
local function cloneEdge(edge)
    local ok, copy = pcall(function() return edge:clone() end)
    if ok and copy then return copy end
    copy = api.type.BaseEdge.new()
    for _, k in ipairs({ "type", "typeIndex", "roadDevelopmentLocked", "node0", "node1",
        "position0", "position1", "tangent0", "tangent1",
        "roadType", "roadTemplate", "roadStyle", "distance" }) do
        pcall(function() copy[k] = edge[k] end)
    end
    pcall(function() copy.laneConfigs = edge.laneConfigs end)
    pcall(function() copy.edgeDecorations = edge.edgeDecorations end)
    return copy
end

local function edgeObject(left, model, player)
    local eo = api.type.SimpleStreetProposal.EdgeObject.new()
    eo.edgeEntity = -1
    eo.param = 0.5
    eo.oneWay = false
    eo.left = left
    eo.model = model
    eo.playerEntity = player
    return eo
end

-- Borrowed native junction settings, old edge id -> new edge (-1).
local function nodeConfigFor(node, oldEdge)
    local cfg = getComp(node, "BASE_NODE_CONFIG")
    if not cfg then return nil end
    local entry = api.type.BaseNodeLaneConnectionAndEntity.new()
    entry.entity = node
    entry.comp = cfg
    local conns = {}
    for _, lc in ipairs(entry.comp.laneConnections or {}) do
        if lc.segment0 == oldEdge then lc.segment0 = -1 end
        if lc.segment1 == oldEdge then lc.segment1 = -1 end
        conns[#conns + 1] = lc
    end
    entry.comp.laneConnections = conns
    return entry
end

-- The game's own refresh request for this street, plus our two stop halves.
function stops.makeStopProposal(edgeEntity, model, player)
    local native = api.engine.util.proposal.replaceSegment(edgeEntity)
    local ns = native.proposal -- Proposal.proposal : StreetProposal
    local seg = ns.addedSegments[1]
    if not seg then return nil, "replaceSegment returned no added segment" end
    local newId = seg.entity
    seg.comp.objects = {
        { stops.NEW_OBJECT_ID, api.type.enum.EdgeObjectType.STOP_LEFT },
        { stops.NEW_OBJECT_ID - 1, api.type.enum.EdgeObjectType.STOP_RIGHT },
    }
    local left, right = edgeObject(true, model, player), edgeObject(false, model, player)
    left.edgeEntity, right.edgeEntity = newId, newId
    local proposal = api.type.SimpleProposal.new()
    proposal.streetProposal.edgesToRemove = { edgeEntity }
    proposal.streetProposal.edgesToAdd = { seg }
    proposal.streetProposal.edgeObjectsToAdd = { left, right }
    local configs, nodes = {}, {}
    for _, c in ipairs(ns.nodeConfigsToAdd or {}) do configs[#configs + 1] = c end
    for _, n in ipairs(ns.nodeConfigsToRemove or {}) do nodes[#nodes + 1] = n end
    if #configs > 0 then proposal.streetProposal.nodeConfigsToAdd = configs end
    if #nodes > 0 then proposal.streetProposal.nodeConfigsToRemove = nodes end
    return proposal, nil
end

-- Snapshot STATION entities near each planned stop, to diff afterwards.
function stops.snapshotStations(plan)
    local before = {}
    for _, e in ipairs(plan) do
        local ok, near = pcall(api.engine.util.octree.findEntitiesInCircle,
            api.type.Vec2f.new(e.x, e.y), stops.STATION_SCAN_RADIUS,
            api.type.ComponentType.STATION)
        for _, s in ipairs(ok and near or {}) do before[s] = true end
    end
    return before
end

-- Sequential build; one refused stop never sinks the rest (bus_loops).
-- onDone(built, refused, lastError).
function stops.buildStops(plan, model, player, context, report, onDone)
    local built, refused, lastError = 0, 0, ""
    local function step(i)
        if i > #plan then
            if onDone then onDone(built, refused, lastError) end
            return
        end
        local e = plan[i]
        report(string.format("Construyendo parada %d/%d...", i, #plan), false)
        local ok, err = pcall(function()
            local proposal, perr = stops.makeStopProposal(e.entity, model, player)
            if not proposal then
                refused = refused + 1
                lastError = tostring(perr)
                logRaw(string.format("stop %d proposal refused: %s", i, tostring(perr)))
                return step(i + 1)
            end
            api.cmd.sendCommand(
                api.cmd.makeWorldBuildProposalCmd(proposal, context, false, true, true),
                function(res, success)
                    if not success then
                        local msg = ""
                        pcall(function()
                            for _, m in ipairs(res.resultProposalData.errorState.messages or {}) do
                                msg = msg .. " " .. tostring(m)
                            end
                        end)
                        refused = refused + 1
                        lastError = msg
                        logRaw(string.format("stop %d send refused:%s", i, msg))
                    else
                        built = built + 1
                    end
                    step(i + 1)
                end)
        end)
        if not ok then
            refused = refused + 1
            lastError = tostring(errorText(err)):match("^[^\n]*") or ""
            logRaw(string.format("stop %d exception: %s", i, tostring(err)))
            step(i + 1)
        end
    end
    step(1)
end

-- Find new stops in corridor order; name them; return station groups.
function stops.discoverGroups(plan, before, townName)
    local groups = {}
    local used = {}
    for i, e in ipairs(plan) do
        local ok, near = pcall(api.engine.util.octree.findEntitiesInCircle,
            api.type.Vec2f.new(e.x, e.y), stops.STATION_SCAN_RADIUS,
            api.type.ComponentType.STATION)
        for _, s in ipairs(ok and near or {}) do
            if not before[s] and getComp(s, "EDGE_OBJECT") then
                local okG, g = pcall(api.engine.system.stationGroupSystem.getStationGroup, s)
                if okG and g and g >= 0 then
                    groups[#groups + 1] = g
                    local base = tostring(townName) .. " Tranvia " .. tostring(#groups)
                    if not used[base] then
                        used[base] = true
                        pcall(api.cmd.sendCommand, api.cmd.makeEntitySetNameCmd(g, base))
                    end
                    break
                end
            end
        end
        if #groups < i then
            logRaw(string.format("stop %d: no new station group found nearby", i))
        end
    end
    return groups
end

return stops
