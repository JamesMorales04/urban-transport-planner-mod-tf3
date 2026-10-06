-- Urban Tram Planner Alpha - Transport Fever 3 - v0.6
--
-- Facade kept for backward compatibility: the town-window plugin requires
-- this file as `core` (analyzeSafe/build/log/errorText/townShape).
-- Real logic lives in:
--   utp_logger.lua         uniform logging
--   utp_street_catalog.lua TRAM/ELECTRIC_TRAM detection, STREET inventory, scoring
--   utp_city.lua           town shape, street graph, radial corridor
--   utp_proposal.lua       replaceSegment proposals, validation, safe executor
--
-- v0.6 root-cause fix (verified against base/content + api/tealdef):
--   Street tram templates carry TRAM / ELECTRIC_TRAM lane modes
--   (town_new_large_tram_electrified: 2/8 lanes). TRAM_TRACK /
--   ELECTRIC_TRAM_TRACK belong to rail TRACK templates (track.zip) and must
--   never be used as street conversion targets. v0.5 checked the rail modes,
--   so its inventory held only the 6 rail tracks and no street was ever
--   convertible. v0.6 detects TRAM/ELECTRIC_TRAM, filters roadType STREET,
--   preserves car access, excludes bridges/tunnels, and re-resolves entities
--   sequentially at build time.
--
-- Deliberately still gated until this primitive passes an in-game test:
-- stops, lines, vehicle purchase, ring/hybrid topology, bus feeders, cargo
-- supply routes, persistent network manifest and incremental reconciliation.

local core = {}

local logger = ug_require("urban_transport_planner::/urban_transit/utp_logger.lua")
local catalog = ug_require("urban_transport_planner::/urban_transit/utp_street_catalog.lua")
local city = ug_require("urban_transport_planner::/urban_transit/utp_city.lua")
local executor = ug_require("urban_transport_planner::/urban_transit/utp_proposal.lua")

local function log(msg)
    logger.raw(msg)
end
core.log = log
core.errorText = logger.errorText
core.townShape = city.townShape

local function entityName(entity)
    local ok, name = pcall(api.engine.util.getEntityName, entity)
    return ok and name or "?"
end

function core.analyze(town, preferElectric)
    local t0 = os.clock()
    local wantElectric = preferElectric ~= false
    local result = {
        town = entityName(town),
        preferElectric = wantElectric,
        buildings = 0,
        radius = 0,
        streetEdges = 0,
        currentTemplates = 0,
        trackTemplates = 0,
        incompatibleEdges = 0,
        excludedStructure = 0,
        excludedNonStreet = 0,
        segments = 0,
        alreadyTram = 0,
        alreadyElectric = 0,
        length = 0,
        cost = 0,
        refused = 0,
        templateCounts = {},
        sourceTargetCounts = {},
        tramLanesToAdd = 0,
        electricFallbacks = 0,
        templateRepoTotal = 0,
        templateRepoAvailable = 0,
        streetResources = 0,
        directStreetTram = 0,
        railTrackResources = 0,
        trackTemplateSamples = {},
    }

    local shape = city.townShape(town)
    if not shape then result.error = "No pude leer la forma de la ciudad." return result end
    result.buildings, result.radius = shape.buildings, shape.radius
    if shape.buildings < 3 then
        result.error = "La ciudad tiene muy pocos edificios para planificar un corredor."
        return result
    end

    local graph, graphError = city.streetGraph(shape, wantElectric)
    if not graph then result.error = graphError or "No pude construir el grafo vial." return result end
    result.trackTemplates = #(graph.inventory or {})
    result.currentTemplates = #(graph.currentTemplateNames or {})
    result.incompatibleEdges = graph.incompatibleEdges or 0
    result.excludedStructure = graph.excludedStructure or 0
    result.excludedNonStreet = graph.excludedNonStreet or 0
    local id = graph.inventoryDiag or {}
    result.templateRepoTotal = id.totalResources or 0
    result.templateRepoAvailable = id.availableResources or 0
    result.streetResources = id.streetResources or 0
    result.directStreetTram = id.directStreetTram or 0
    result.railTrackResources = id.railTrackResources or 0
    for i = 1, math.min(8, #(graph.inventory or {})) do
        local t = graph.inventory[i]
        result.trackTemplateSamples[#result.trackTemplateSamples + 1] = string.format(
            "%s [electric=%s lanes=%d]",
            tostring(t.name), tostring(t.electric), tonumber(t.trackLanes) or 0
        )
    end
    for _ in pairs(graph.edges) do result.streetEdges = result.streetEdges + 1 end

    log(string.format(
        "template repository: total=%d available=%d street=%d streetTram=%d railTrack=%d uniqueStreetTram=%d",
        result.templateRepoTotal, result.templateRepoAvailable, result.streetResources,
        result.directStreetTram, result.railTrackResources, result.trackTemplates
    ))
    for i, sample in ipairs(result.trackTemplateSamples) do log("  street tram candidate " .. i .. ": " .. sample) end

    if result.trackTemplates == 0 then
        result.error = "No encontre ningun StreetTemplate de calle con TRAM/ELECTRIC_TRAM. Revisa el diagnostico en stdout.txt."
        log("analysis stopped: " .. result.error)
        return result
    end
    if result.streetEdges < 3 then
        result.error = string.format(
            "Solo %d calles convertibles (incompatibles=%d, puentes/tuneles=%d, no-calle=%d). Ningun corredor fiable.",
            result.streetEdges, result.incompatibleEdges,
            result.excludedStructure, result.excludedNonStreet)
        log("analysis stopped: " .. result.error)
        return result
    end

    local centerEdge, outerEdge, target = city.pickEndpoints(graph, shape)
    if not centerEdge or not outerEdge then
        result.error = "No pude elegir los extremos del corredor radial."
        return result
    end

    local path = city.corridor(graph, centerEdge, outerEdge)
    if not path or #path < 2 then
        result.error = "No encontre un camino continuo centro-periferia usando solo calles convertibles a tranvia."
        return result
    end

    result.target = target
    result.segments = #path
    result._path = path

    local player = api.engine.util.getPlayer()
    local context = executor.newContext(player)
    local firstError = nil

    for i, e in ipairs(path) do
        result.length = result.length + e.length
        if e.alreadyTram then result.alreadyTram = result.alreadyTram + 1 end
        if e.alreadyElectric then result.alreadyElectric = result.alreadyElectric + 1 end
        if e.electricFallback then result.electricFallbacks = result.electricFallbacks + 1 end

        local targetName = e.targetTemplate or "<sin objetivo>"
        result.templateCounts[targetName] = (result.templateCounts[targetName] or 0) + 1
        local mapping = tostring(e.currentTemplate) .. " -> " .. tostring(targetName)
        result.sourceTargetCounts[mapping] = (result.sourceTargetCounts[mapping] or 0) + 1

        log(string.format(
            "corridor edge %d entity=%s track=%s electric=%s source=%s target=%s targetElectric=%s fallback=%s score=%.1f",
            i, tostring(e.entity), tostring(e.alreadyTram), tostring(e.alreadyElectric),
            tostring(e.currentTemplate), tostring(e.targetTemplate), tostring(e.targetElectric),
            tostring(e.electricFallback), tonumber(e.templateScore) or -1
        ))

        local pd = executor.proposalDataFor(e, context, wantElectric)
        if not pd.ok or pd.critical then
            result.refused = result.refused + 1
            firstError = firstError or pd.error or "El juego rechazo una propuesta de segmento."
        else
            result.cost = result.cost + (pd.cost or 0)
            result.tramLanesToAdd = result.tramLanesToAdd + (pd.changedLanes or 0)
        end
    end

    result.firstError = firstError
    result.seconds = os.clock() - t0
    result.buildable = result.refused == 0 and result.segments > 0

    log(string.format(
        "analysis %s: buildings=%d radius=%.0fm usableEdges=%d incompatible=%d bridges/tunnels=%d nonStreet=%d currentTpl=%d streetTram=%d corridor=%d/%.0fm refused=%d lanesToAdd=%d",
        result.town, result.buildings, result.radius, result.streetEdges, result.incompatibleEdges,
        result.excludedStructure, result.excludedNonStreet,
        result.currentTemplates, result.trackTemplates, result.segments, result.length,
        result.refused, result.tramLanesToAdd
    ))
    for mapping, n in pairs(result.sourceTargetCounts) do
        log(string.format("  mapping x%d: %s", n, mapping))
    end
    if firstError then log("  first validation error: " .. tostring(firstError)) end
    return result
end

function core.build(town, preferElectric, report)
    report = report or function() end
    local plan = core.analyze(town, preferElectric)
    if plan.error then return report(plan.error, true) end
    if not plan.buildable then
        return report(string.format(
            "No se construyo nada: %d segmento(s) fallaron la validacion. %s",
            plan.refused or 0, plan.firstError or "Revisa stdout.txt."
        ), true)
    end
    executor.buildPath(plan._path, preferElectric, report)
end

function core.analyzeSafe(town, preferElectric)
    local ok, result = pcall(core.analyze, town, preferElectric)
    if ok then return result end
    local msg = logger.errorText(result)
    log("analysis exception: " .. msg)
    return { error = "Excepcion interna durante el analisis: " .. msg, buildable = false }
end

return core
