-- UTP proposal builder / validator / construction executor.
--
-- VERIFIED:
--   api.engine.util.proposal.replaceSegment(entity, streetTemplate?)
--     -> Proposal  (api/tealdef/api/engine/util.d.tl:987-991)
--   api.cmd.makeWorldBuildProposalCmd(proposal, context, ignoreErrors,
--     playerInitiated, doDust?)  (api/tealdef/api/cmd.d.tl:961-962)
--   Vanilla GUI example (gui/construction/construction.tl:1301):
--     api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, nil, false, true), cb)
--   Context pattern (gui/entity_window/bridge_and_tunnel.tl, buy button):
--     local context = api.type.Context.new()
--     context.player = api.engine.util.getPlayer()
--     ... makeWorldBuildProposalCmd(proposal, context, false, true)
--   Vanilla pre-validation pattern (bridge_and_tunnel.tl:130): the engine
--     computes ProposalData asynchronously inside builtin.ProposalViewer
--     (onCreateProposalData -> proposalData.errorState.messages / .costs).
--     There is NO shipped direct call of makeProposalData in GUI content.
--
-- RUNTIME FINDING (v0.6 playtest, Alteren): calling
--   api.engine.util.proposal.makeProposalData(replaceSegmentResult, context)
-- directly throws:
--   "bad argument #2 to '?' (SimpleProposal expected, got Proposal)"
-- i.e. the binding only accepts SimpleProposal there, while replaceSegment
-- yields a full Proposal. The tealdef signature (proposal: Proposal) does not
-- match runtime behaviour, and with zero shipped callers there is nothing to
-- copy. Therefore v0.7 does NOT call makeProposalData on replaceSegment
-- output. Validation rests on two engine-backed pillars instead:
--   1. creation check: replaceSegment itself throws on invalid replacement
--      (proposals are inert until sent, so creating them validates safely);
--   2. send result: makeWorldBuildProposalCmd callback reports success plus
--      resultProposalData (costs/errorState), per segment, sequentially.
-- Design: analyze-time creation check only enables Build. Build-time
-- re-creates every proposal (world revision may have shifted after each
-- sequential command) and aborts safely on the first rejection. No direct
-- writes to BaseEdge/lane internals, no Proposal field mutation.

local executor = {}

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
executor.errorText = errorText

local function getComp(entity, name)
    local okType, ct = pcall(function() return api.type.ComponentType[name] end)
    if not okType or ct == nil then return nil end
    local ok, comp = pcall(api.engine.getComponent, entity, ct)
    return ok and comp or nil
end

function executor.newContext(player)
    local context = api.type.Context.new()
    context.player = player
    return context
end

-- Replacement only. Returns (proposal, nil, changedLanes, already:boolean)
-- or (nil, errMsg, 0, false).
function executor.makeTramProposal(edgeRec, preferElectric)
    if edgeRec.satisfies then return nil, nil, 0, true end
    if not edgeRec.targetTemplate then
        return nil, "No compatible tram StreetTemplate was found.", 0, false
    end
    local targetTpl = catalog.streetTemplateByName(edgeRec.targetTemplate)
    if not targetTpl then
        return nil, "Target StreetTemplate is not present in streetTemplateRep: "
            .. tostring(edgeRec.targetTemplate), 0, false
    end
    if not catalog.isStreetRoadType(targetTpl) then
        return nil, "Target is not a STREET template (rail TRACK rejected): "
            .. tostring(edgeRec.targetTemplate), 0, false
    end
    local hasTram, hasElectric, tramLanes = catalog.templateStreetTramKinds(targetTpl)
    if not hasTram then
        return nil, "Target StreetTemplate contains no TRAM/ELECTRIC_TRAM lanes: "
            .. tostring(edgeRec.targetTemplate), 0, false
    end
    if preferElectric and edgeRec.targetElectric and not hasElectric then
        return nil, "Electric target contains no ELECTRIC_TRAM lanes: "
            .. tostring(edgeRec.targetTemplate), 0, false
    end

    local phase = "replaceSegment(" .. tostring(edgeRec.targetTemplate) .. ")"
    local ok, native = pcall(api.engine.util.proposal.replaceSegment, edgeRec.entity, edgeRec.targetTemplate)
    if not ok or not native then
        return nil, phase .. ": " .. errorText(native), 0, false
    end
    local changed = math.max(0, tramLanes - (edgeRec.existingTramLanes or 0))
    return native, nil, changed, false
end

-- Analyze-time validation: creating the proposal IS the engine check.
-- Never calls makeProposalData (runtime rejects Proposal there; see header).
function executor.validateForBuild(edgeRec, preferElectric)
    if edgeRec.satisfies then
        return { ok = true, critical = false, already = true, changedLanes = 0 }
    end
    local okMake, proposal, proposalError, changedLanes =
        pcall(executor.makeTramProposal, edgeRec, preferElectric)
    if not okMake then
        return { ok = false, critical = true,
            error = "makeTramProposal exception: " .. errorText(proposal), changedLanes = 0 }
    end
    if not proposal then
        return { ok = false, critical = true,
            error = proposalError or "Engine refused the replacement.", changedLanes = changedLanes or 0 }
    end
    return { ok = true, critical = false, changedLanes = changedLanes or 0 }
end

-- Re-resolve a planned edge against the live world right before building it.
-- Returns (freshRec, nil) or (nil, reason). Never builds a stale entity.
function executor.refreshEdge(planRec)
    local entity = planRec.entity
    local edge = getComp(entity, "BASE_EDGE")
    local street = getComp(entity, "BASE_EDGE_STREET")
    if not edge or not street then
        return nil, "entity " .. tostring(entity) .. " no longer has street components (world changed)"
    end
    local liveTemplate = catalog.safeField(edge, "roadTemplate")
    local fresh = {}
    for k, v in pairs(planRec) do fresh[k] = v end
    fresh.liveTemplate = liveTemplate
    if liveTemplate ~= planRec.currentTemplate then
        -- Another build (or the player) already changed it: re-check tram state.
        local hasTram, hasElectric = catalog.edgeStreetTramKinds(edge)
        fresh.liveHasTram = hasTram
        fresh.liveHasElectric = hasElectric
        return fresh, "changed"
    end
    return fresh, nil
end

local function callbackCost(res)
    local cost = 0
    pcall(function()
        local pd = res and res.resultProposalData
        if pd and tonumber(pd.costs) then cost = tonumber(pd.costs) end
    end)
    return cost
end

function executor.buildPath(path, preferElectric, report)
    report = report or function() end
    local player = api.engine.util.getPlayer()
    local context = executor.newContext(player)
    local changed, skipped, actualCost = 0, 0, 0

    local function step(i)
        if i > #path then
            return report(string.format(
                "Done: corredor radial de prueba construido. %d segmentos cambiados, %d ya cumplian, coste motor $%d.",
                changed, skipped, actualCost), false)
        end
        local e = path[i]

        -- Re-resolve: a previous sequential command may have invalidated IDs.
        local fresh, refreshNote = executor.refreshEdge(e)
        if not fresh then
            return report("El mundo cambio bajo el plan en el segmento " .. i .. ": "
                .. tostring(refreshNote)
                .. ". Plan detenido sin mas cambios; recarga la copia de prueba si hace falta.", true)
        end
        if refreshNote == "changed" then
            local wantElectric = preferElectric ~= false
            local satisfiedNow = fresh.liveHasTram and ((not wantElectric) or fresh.liveHasElectric)
            if satisfiedNow then
                skipped = skipped + 1
                logRaw(string.format("segment %d entity changed externally but already satisfies; skipping", i))
                return step(i + 1)
            end
            return report("El segmento " .. i .. " cambio desde el analisis ("
                .. tostring(e.currentTemplate) .. " -> " .. tostring(fresh.liveTemplate)
                .. "). Plan detenido para no construir sobre un mundo distinto; re-analiza.", true)
        end

        if e.satisfies then
            skipped = skipped + 1
            report(string.format("Segmento %d/%d ya tiene la via requerida; se conserva.", i, #path), false)
            return step(i + 1)
        end

        -- Fresh creation check immediately before sending (world may differ).
        local proposal, proposalError, changedLanes =
            executor.makeTramProposal(e, preferElectric)
        if not proposal then
            return report("El segmento " .. i .. " ya no valida: " .. tostring(proposalError or "?")
                .. ". Plan detenido sin mas cambios.", true)
        end

        report(string.format(
            "Convirtiendo segmento %d/%d: %s -> %s (%d carril(es) de via nuevos)...",
            i, #path, tostring(e.currentTemplate), tostring(e.targetTemplate), changedLanes or 0), false)

        local okSend, err = pcall(function()
            -- Verified signature: (proposal, context, ignoreErrors,
            -- playerInitiated, doDust?). Vanilla uses (proposal, nil, false, true).
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
                        logRaw(string.format("segment %d failed:%s", i, msg))
                        return report(
                            "El juego rechazo el segmento " .. i .. "." .. msg ..
                            " La ruta puede haber quedado parcialmente construida; recarga la copia de prueba si hace falta.",
                            true)
                    end
                    changed = changed + 1
                    actualCost = actualCost + callbackCost(res)
                    step(i + 1)
                end)
        end)
        if not okSend then
            return report("Error enviando segmento " .. i .. ": " .. errorText(err), true)
        end
    end

    report("Construyendo corredor tranviario con reemplazo nativo de StreetTemplate...", false)
    step(1)
end

return executor
