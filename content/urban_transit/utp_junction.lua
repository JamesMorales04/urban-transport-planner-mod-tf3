-- UTP junction inspector + repair v0.9 (read-only first, guarded writes).
--
-- Symptom (playtest Alteren): converted corridor shows no connected tram
-- tracks at crossings. Tram-ness of a crossing lives in
-- BaseNodeConfig.laneConnections[].withTram (api/tealdef/api/type.d.tl
-- :1193-1207, "Whether connection supports tram"), readable per node.
--
-- inspectCorridor(path): for each converted edge confirms live TRAM lanes;
-- for each internal node shared by two consecutive corridor edges counts
-- lane connections between exactly those edges with withTram == true.
-- Pure reads, no writes. Returns {edges, edgesWithTram, nodes, nodesWithTram,
-- detail = {"entity ..."}}.
--
-- repairCorridor: for nodes MISSING tram on a corridor pair, submits one
-- SimpleProposal per node flipping withTram false->true on THOSE rows only
-- (nodeConfigsToRemove={node}, nodeConfigsToAdd={borrowed entry}), mirroring
-- the borrowed-config pattern of the stop builder. Never creates lanes,
-- never touches other pairs, continues past refusals. Engine decides.
-- Rationale: the vanilla tram tool applies StreetEdgeNodeModifier with
-- overrideLaneConfigs; a template swap alone may leave junctions at
-- withTram=false. This only enables the documented flag on existing rows.

local junction = {}

local catalog = nil
local logger = nil
pcall(function()
    catalog = ug_require("urban_transport_planner::/urban_transit/utp_street_catalog.lua")
end)
pcall(function()
    logger = ug_require("urban_transport_planner::/urban_transit/utp_logger.lua")
end)

local function logRaw(msg)
    if logger and logger.raw then logger.raw(msg)
    else print("[Urban Tram Planner Alpha] " .. tostring(msg)) end
end

local function errorText(err)
    if logger and logger.errorText then return logger.errorText(err) end
    return tostring(err)
end

local function getComp(entity, name)
    local okType, ct = pcall(function() return api.type.ComponentType[name] end)
    if not okType or ct == nil then return nil end
    local ok, comp = pcall(api.engine.getComponent, entity, ct)
    return ok and comp or nil
end

-- Consecutive corridor pairs sharing a node: {node, edgeA, edgeB}.
local function corridorJoints(path)
    local byNode = {}
    for _, e in ipairs(path or {}) do
        for _, n in ipairs({ e.node0, e.node1 }) do
            if n then
                byNode[n] = byNode[n] or {}
                byNode[n][#byNode[n] + 1] = e.entity
            end
        end
    end
    local joints = {}
    for node, entities in pairs(byNode) do
        if #entities >= 2 then
            for i = 1, #entities - 1 do
                for j = i + 1, #entities do
                    joints[#joints + 1] = { node = node, edgeA = entities[i], edgeB = entities[j] }
                end
            end
        end
    end
    return joints
end
junction.corridorJoints = corridorJoints

local function pairMatches(lc, a, b)
    local s0, s1 = nil, nil
    pcall(function() s0, s1 = lc.segment0, lc.segment1 end)
    return (s0 == a and s1 == b) or (s0 == b and s1 == a)
end

function junction.inspectCorridor(path)
    local out = { edges = 0, edgesWithTram = 0, nodes = 0, nodesWithTram = 0, detail = {} }
    for _, e in ipairs(path or {}) do
        out.edges = out.edges + 1
        local edge = getComp(e.entity, "BASE_EDGE")
        if edge then
            local hasTram = catalog.edgeStreetTramKinds(edge)
            if hasTram then out.edgesWithTram = out.edgesWithTram + 1
            else
                out.detail[#out.detail + 1] =
                    string.format("edge %s: NO tram lanes live", tostring(e.entity))
            end
        else
            out.detail[#out.detail + 1] =
                string.format("edge %s: unreadable (world changed)", tostring(e.entity))
        end
    end
    for _, j in ipairs(corridorJoints(path)) do
        out.nodes = out.nodes + 1
        local cfg = getComp(j.node, "BASE_NODE_CONFIG")
        local tramConns = 0
        if cfg then
            pcall(function()
                for _, lc in ipairs(cfg.laneConnections or {}) do
                    if pairMatches(lc, j.edgeA, j.edgeB) then
                        local wt = false
                        pcall(function() wt = lc.withTram == true end)
                        if wt then tramConns = tramConns + 1 end
                    end
                end
            end)
        end
        if tramConns > 0 then
            out.nodesWithTram = out.nodesWithTram + 1
        else
            out.detail[#out.detail + 1] = string.format(
                "node %s (edges %s/%s): NO tram connection",
                tostring(j.node), tostring(j.edgeA), tostring(j.edgeB))
        end
    end
    return out
end

-- Build one repair proposal per deficient joint (caller sends sequentially).
-- Returns proposal or (nil, reason). Rows are the node's own connections
-- with withTram enabled on the corridor pair only.
function junction.repairProposal(joint)
    local cfg = getComp(joint.node, "BASE_NODE_CONFIG")
    if not cfg then return nil, "node config unreadable" end
    local entry = api.type.BaseNodeLaneConnectionAndEntity.new()
    entry.entity = joint.node
    entry.comp = cfg
    local fixed, conns = 0, {}
    for _, lc in ipairs(entry.comp.laneConnections or {}) do
        if pairMatches(lc, joint.edgeA, joint.edgeB) then
            local wt = false
            pcall(function() wt = lc.withTram == true end)
            if not wt then
                pcall(function() lc.withTram = true end)
                fixed = fixed + 1
            end
        end
        conns[#conns + 1] = lc
    end
    if fixed == 0 then return nil, "nothing to enable" end
    entry.comp.laneConnections = conns
    local proposal = api.type.SimpleProposal.new()
    proposal.streetProposal.nodeConfigsToRemove = { joint.node }
    proposal.streetProposal.nodeConfigsToAdd = { entry }
    return proposal, nil, fixed
end

-- Sequential guarded repair over deficient joints.
-- cb(repaired, refused, totalDeficient).
function junction.repairCorridor(path, player, context, report, cb)
    local joints = corridorJoints(path)
    local deficient = {}
    for _, j in ipairs(joints) do
        local cfg = getComp(j.node, "BASE_NODE_CONFIG")
        local tramConns = 0
        if cfg then
            pcall(function()
                for _, lc in ipairs(cfg.laneConnections or {}) do
                    if pairMatches(lc, j.edgeA, j.edgeB) then
                        local wt = false
                        pcall(function() wt = lc.withTram == true end)
                        if wt then tramConns = tramConns + 1 end
                    end
                end
            end)
        end
        if tramConns == 0 then deficient[#deficient + 1] = j end
    end
    local repaired, refused = 0, 0
    local function step(i)
        if i > #deficient then
            cb(repaired, refused, #deficient)
            return
        end
        local j = deficient[i]
        report(string.format("Reparando cruce %d/%d...", i, #deficient), false)
        local ok, err = pcall(function()
            local proposal, perr = junction.repairProposal(j)
            if not proposal then
                logRaw("junction node " .. tostring(j.node) .. ": " .. tostring(perr))
                refused = refused + 1
                return step(i + 1)
            end
            api.cmd.sendCommand(
                api.cmd.makeWorldBuildProposalCmd(proposal, context, false, true, true),
                function(res, success)
                    if success then repaired = repaired + 1
                    else
                        refused = refused + 1
                        local msg = ""
                        pcall(function()
                            for _, m in ipairs(res.resultProposalData.errorState.messages or {}) do
                                msg = msg .. " " .. tostring(m)
                            end
                        end)
                        logRaw("junction node " .. tostring(j.node) .. " refused:" .. msg)
                    end
                    step(i + 1)
                end)
        end)
        if not ok then
            refused = refused + 1
            logRaw("junction exception: " .. errorText(err))
            step(i + 1)
        end
    end
    step(1)
end

return junction
