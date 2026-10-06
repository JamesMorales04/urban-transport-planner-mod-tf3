-- UTP city analysis: town shape (P95 radius), street graph scan, radial
-- endpoint choice, Dijkstra corridor. Pure graph algorithms are kept
-- dependency-free so tests can exercise them without the engine.

local city = {}

city.SEARCH_MARGIN = 260
city.MIN_EDGE_LENGTH = 18
city.OUTER_BUILDING_FRACTION = 0.45
city.OUTER_EDGE_FRACTION = 0.40
city.SECTORS = 8

local catalog = nil
pcall(function()
    catalog = ug_require("urban_transport_planner::/urban_transit/utp_street_catalog.lua")
end)

local function getComp(entity, name)
    local okType, ct = pcall(function() return api.type.ComponentType[name] end)
    if not okType or ct == nil then return nil end
    local ok, comp = pcall(api.engine.getComponent, entity, ct)
    return ok and comp or nil
end
city.getComp = getComp

local function xyz(v)
    if v == nil then return nil end
    local ok, x, y, z = pcall(function()
        return v.x or v[1], v.y or v[2], v.z or v[3]
    end)
    if ok and x ~= nil then return x, y, z or 0 end
    return nil
end

local function bboxCenter(entity)
    local bv = getComp(entity, "BOUNDING_VOLUME")
    if not bv or not bv.bbox then return nil end
    local x0, y0, z0 = xyz(bv.bbox.min)
    local x1, y1, z1 = xyz(bv.bbox.max)
    if not x0 or not x1 then return nil end
    return (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2, x1 - x0, y1 - y0
end
city.bboxCenter = bboxCenter

function city.townShape(town)
    local cx, cy, cz, w, h = bboxCenter(town)
    if not cx then return nil end
    local dists, points = {}, {}
    local ok, map = pcall(api.engine.system.townBuildingSystem.getTown2BuildingMap)
    local buildings = ok and map and map[town] or {}
    for _, b in ipairs(buildings) do
        local bx, by = bboxCenter(b)
        if bx then
            local d = math.sqrt((bx - cx) ^ 2 + (by - cy) ^ 2)
            dists[#dists + 1] = d
            points[#points + 1] = { bx, by, d }
        end
    end
    table.sort(dists)
    local radius
    if #dists >= 5 then
        radius = dists[math.max(1, math.floor(#dists * 0.95))]
    else
        radius = math.max(w or 0, h or 0) / 2
    end
    return {
        x = cx, y = cy, z = cz,
        radius = math.max(radius or 0, 120),
        buildings = #points,
        points = points,
    }
end

local function edgeLength(edge)
    local x0, y0 = xyz(edge.position0)
    local x1, y1 = xyz(edge.position1)
    if not x0 or not x1 then return 0, nil, nil end
    return math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2), (x0 + x1) / 2, (y0 + y1) / 2
end
city.edgeLength = edgeLength

-- Bridge/tunnel edges are excluded in v0.6: replaceSegment on them risks
-- destroying infrastructure the validator may not restore. Revisited after
-- the NORMAL-segment primitive is proven in game.
local function edgeStructureKind(edge)
    local t = nil
    pcall(function() t = edge.type end)
    if t == nil then return "UNKNOWN" end
    if type(t) == "string" then
        return (t == "NORMAL") and "NORMAL" or "SPECIAL"
    end
    local ok, normal = pcall(function() return api.type.enum["BaseEdgeType"]["NORMAL"] end)
    if ok and normal ~= nil then
        local okEq, eq = pcall(function() return t == normal end)
        if okEq and eq then return "NORMAL" end
    end
    return "SPECIAL"
end
city.edgeStructureKind = edgeStructureKind

function city.streetGraph(shape, preferElectric)
    local inventory, inventoryDiag = catalog.tramStreetInventory(preferElectric)
    local graph = {
        edges = {},
        adj = {},
        inventory = inventory,
        inventoryDiag = inventoryDiag,
        currentTemplateNames = {},
        incompatibleEdges = 0,
        excludedStructure = 0,
        excludedNonStreet = 0,
    }
    local templatesSeen = {}

    local ok, entities = pcall(
        api.engine.util.octree.findEntitiesInCircle,
        api.type.Vec2f.new(shape.x, shape.y),
        shape.radius + city.SEARCH_MARGIN,
        api.type.ComponentType.BASE_EDGE
    )
    if not ok then return nil, "No pude escanear las calles de la ciudad." end

    for _, entity in ipairs(entities or {}) do
        local edge = getComp(entity, "BASE_EDGE")
        local street = getComp(entity, "BASE_EDGE_STREET")
        if edge and street then
            local partOfConstruction = false
            local okC, con = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForEdge, entity)
            if okC and con and con >= 0 then partOfConstruction = true end

            local kind = edgeStructureKind(edge)
            local len, mx, my = edgeLength(edge)
            local currentName = catalog.safeField(edge, "roadTemplate")
            -- Require STREET roadType on the live edge (excludes rail TRACK).
            local edgeIsStreet = true
            pcall(function()
                local rt = edge.roadType
                if rt ~= nil then
                    if type(rt) == "string" then
                        edgeIsStreet = (rt == "STREET")
                    else
                        local st = api.type.enum["RoadType"]["STREET"]
                        edgeIsStreet = (rt == st)
                    end
                end
            end)
            if kind ~= "NORMAL" and kind ~= "UNKNOWN" then
                graph.excludedStructure = graph.excludedStructure + 1
            elseif not edgeIsStreet then
                graph.excludedNonStreet = graph.excludedNonStreet + 1
            elseif not partOfConstruction and len >= city.MIN_EDGE_LENGTH and mx and currentName then
                templatesSeen[currentName] = true
                local hasTram, hasElectric, tramLanes = catalog.edgeStreetTramKinds(edge)
                local target = catalog.bestTramStreetTemplate(currentName, inventory, preferElectric)
                local satisfies = hasTram and ((not preferElectric) or hasElectric)
                local usable = satisfies or target ~= nil
                if usable then
                    local rec = {
                        entity = entity,
                        node0 = edge.node0,
                        node1 = edge.node1,
                        x = mx,
                        y = my,
                        length = len,
                        currentTemplate = currentName,
                        targetTemplate = satisfies and currentName or (target and target.name or nil),
                        templateScore = satisfies and 0 or (target and target.score or catalog.INF),
                        targetElectric = satisfies and hasElectric or (target and target.electric or false),
                        electricFallback = target and target.electricFallback or false,
                        upgradeable = usable,
                        alreadyTram = hasTram,
                        alreadyElectric = hasElectric,
                        existingTramLanes = tramLanes,
                        satisfies = satisfies,
                        hasObjects = catalog.safeField(edge, "objects") and #edge.objects > 0 or false,
                    }
                    graph.edges[entity] = rec
                    graph.adj[rec.node0] = graph.adj[rec.node0] or {}
                    graph.adj[rec.node1] = graph.adj[rec.node1] or {}
                    graph.adj[rec.node0][#graph.adj[rec.node0] + 1] = rec
                    graph.adj[rec.node1][#graph.adj[rec.node1] + 1] = rec
                else
                    graph.incompatibleEdges = graph.incompatibleEdges + 1
                end
            end
        end
    end

    for name in pairs(templatesSeen) do
        graph.currentTemplateNames[#graph.currentTemplateNames + 1] = name
    end
    table.sort(graph.currentTemplateNames)
    return graph
end

function city.radialTarget(shape)
    local sectors = {}
    for i = 1, city.SECTORS do sectors[i] = { n = 0, sx = 0, sy = 0, sr = 0 } end
    for _, p in ipairs(shape.points) do
        local dx, dy = p[1] - shape.x, p[2] - shape.y
        local r = math.sqrt(dx * dx + dy * dy)
        if r >= shape.radius * city.OUTER_BUILDING_FRACTION then
            local angle = (math.atan2 or math.atan)(dy, dx)
            local normalized = (angle + math.pi) / (2 * math.pi)
            local idx = math.floor(normalized * city.SECTORS) % city.SECTORS + 1
            local s = sectors[idx]
            s.n, s.sx, s.sy, s.sr = s.n + 1, s.sx + p[1], s.sy + p[2], s.sr + r
        end
    end
    local best = nil
    for _, s in ipairs(sectors) do
        if s.n > 0 and (not best or s.n > best.n or (s.n == best.n and s.sr > best.sr)) then
            best = s
        end
    end
    if best then return best.sx / best.n, best.sy / best.n, best.n end
    local far, farD = nil, -1
    for _, p in ipairs(shape.points) do
        if p[3] > farD then far, farD = p, p[3] end
    end
    if far then return far[1], far[2], 1 end
    return shape.x + shape.radius, shape.y, 0
end

function city.pickEndpoints(graph, shape)
    local centerEdge, centerD = nil, math.huge
    for _, e in pairs(graph.edges) do
        local d = (e.x - shape.x) ^ 2 + (e.y - shape.y) ^ 2
        if d < centerD then centerEdge, centerD = e, d end
    end
    if not centerEdge then return nil, nil, nil end
    local tx, ty, sectorBuildings = city.radialTarget(shape)
    local outerEdge, outerScore = nil, math.huge
    for _, e in pairs(graph.edges) do
        if e.entity ~= centerEdge.entity then
            local dx, dy = e.x - shape.x, e.y - shape.y
            local r = math.sqrt(dx * dx + dy * dy)
            if r >= shape.radius * city.OUTER_EDGE_FRACTION then
                local targetD = math.sqrt((e.x - tx) ^ 2 + (e.y - ty) ^ 2)
                local radialPenalty = math.abs(r - shape.radius * 0.78) * 0.20
                local score = targetD + radialPenalty
                if score < outerScore then outerEdge, outerScore = e, score end
            end
        end
    end
    if not outerEdge then
        local farD = -1
        for _, e in pairs(graph.edges) do
            if e.entity ~= centerEdge.entity then
                local d = (e.x - shape.x) ^ 2 + (e.y - shape.y) ^ 2
                if d > farD then outerEdge, farD = e, d end
            end
        end
    end
    return centerEdge, outerEdge, { x = tx, y = ty, buildings = sectorBuildings }
end

local function heapPush(heap, item)
    heap[#heap + 1] = item
    local i = #heap
    while i > 1 do
        local p = math.floor(i / 2)
        if heap[p][1] <= item[1] then break end
        heap[i] = heap[p]
        i = p
    end
    heap[i] = item
end

local function heapPop(heap)
    if #heap == 0 then return nil end
    local root = heap[1]
    local last = table.remove(heap)
    if #heap > 0 then
        local i = 1
        while true do
            local left, right = i * 2, i * 2 + 1
            if left > #heap then break end
            local child = left
            if right <= #heap and heap[right][1] < heap[left][1] then child = right end
            if heap[child][1] >= last[1] then break end
            heap[i] = heap[child]
            i = child
        end
        heap[i] = last
    end
    return root
end

local function traversalCost(e)
    local factor = e.satisfies and 0.55 or 1.0
    if e.hasObjects then factor = factor * 1.08 end
    factor = factor + math.min(0.40, (e.templateScore or 0) / 12000)
    return e.length * factor
end
city.traversalCost = traversalCost

-- Share of town buildings within radius of the corridor (midpoint
-- approximation, documented heuristic for route-efficiency reporting).
city.COVERAGE_RADIUS = 160
function city.coverage(points, path, radius)
    radius = radius or city.COVERAGE_RADIUS
    if not points or #points == 0 or not path or #path == 0 then return 0, 0 end
    local served = 0
    for _, p in ipairs(points) do
        local px, py = p[1], p[2]
        for _, e in ipairs(path) do
            local dx, dy = px - (e.x or 0), py - (e.y or 0)
            if dx * dx + dy * dy <= radius * radius then
                served = served + 1
                break
            end
        end
    end
    return served / #points, served
end

function city.dijkstra(graph, startNode, goalNode, excluded)
    if startNode == goalNode then return {}, 0 end
    local dist = { [startNode] = 0 }
    local prevNode, prevEdge = {}, {}
    local heap = {}
    heapPush(heap, { 0, startNode })
    while #heap > 0 do
        local item = heapPop(heap)
        local d, node = item[1], item[2]
        if d == dist[node] then
            if node == goalNode then break end
            for _, e in ipairs(graph.adj[node] or {}) do
                if not (excluded and excluded[e.entity]) then
                    local nextNode = (e.node0 == node) and e.node1 or e.node0
                    local nd = d + traversalCost(e)
                    if dist[nextNode] == nil or nd < dist[nextNode] then
                        dist[nextNode] = nd
                        prevNode[nextNode] = node
                        prevEdge[nextNode] = e
                        heapPush(heap, { nd, nextNode })
                    end
                end
            end
        end
    end
    if dist[goalNode] == nil then return nil, math.huge end
    local path, node = {}, goalNode
    while node ~= startNode do
        local e = prevEdge[node]
        if not e then return nil, math.huge end
        table.insert(path, 1, e)
        node = prevNode[node]
    end
    return path, dist[goalNode]
end

function city.corridor(graph, centerEdge, outerEdge)
    if not centerEdge or not outerEdge then return nil end
    local centerNodes = { centerEdge.node0, centerEdge.node1 }
    local outerNodes = { outerEdge.node0, outerEdge.node1 }
    local excluded = { [centerEdge.entity] = true, [outerEdge.entity] = true }
    local best, bestCost = nil, math.huge
    for _, s in ipairs(centerNodes) do
        for _, g in ipairs(outerNodes) do
            local path, cost = city.dijkstra(graph, s, g, excluded)
            if path and cost < bestCost then best, bestCost = path, cost end
        end
    end
    if not best then
        for _, s in ipairs(centerNodes) do
            for _, g in ipairs(outerNodes) do
                local path, cost = city.dijkstra(graph, s, g, nil)
                if path and cost < bestCost then best, bestCost = path, cost end
            end
        end
    end
    if not best then return nil end
    local out, seen = {}, {}
    local function append(e)
        if e and not seen[e.entity] then
            out[#out + 1] = e
            seen[e.entity] = true
        end
    end
    append(centerEdge)
    for _, e in ipairs(best) do append(e) end
    append(outerEdge)
    return out
end

-- v0.11 green loop: close the radial into a circuit. The return leg avoids
-- the outbound interior edges so tracks do not dead-end (red) but run a
-- closed loop (green). Ida/Vuelta lines then serve the loop in both
-- directions, exactly like bus_loops CW/CCW. Falls back to the open
-- corridor when no disjoint return exists. Returns loop, closed:boolean.
function city.loopCorridor(graph, centerEdge, outerEdge)
    local out = city.corridor(graph, centerEdge, outerEdge)
    if not out or #out < 2 then return out, false end
    local outSet = {}
    for _, e in ipairs(out) do outSet[e.entity] = true end
    local interior = {}
    for _, e in ipairs(out) do
        if e.entity ~= centerEdge.entity and e.entity ~= outerEdge.entity then
            interior[e.entity] = true
        end
    end
    -- Traversal ends of the outbound leg (orientation-agnostic: either
    -- chain end works as loop joint).
    local function follow(list, startNode)
        local n = startNode
        local used = {}
        while true do
            local advanced = false
            for _, e in ipairs(list) do
                if not used[e.entity] then
                    if e.node0 == n then
                        n, used[e.entity], advanced = e.node1, true, true
                    elseif e.node1 == n then
                        n, used[e.entity], advanced = e.node0, true, true
                    end
                    if advanced then break end
                end
            end
            if not advanced then return n end
        end
    end
    local endA = follow(out, out[1].node0)
    local endB = follow(out, out[1].node1)
    do
        local centerNodes = { centerEdge.node0, centerEdge.node1 }
        local outerNodes = { outerEdge.node0, outerEdge.node1 }
        local best, bestRank, bestCost = nil, 99, math.huge
        for _, s in ipairs(outerNodes) do
            for _, g in ipairs(centerNodes) do
                local path, cost = city.dijkstra(graph, s, g, interior)
                if path then
                    local closed = (s == endA and g == endB) or (s == endB and g == endA)
                    local touches = (s == endA or s == endB or g == endA or g == endB)
                    local rank = closed and 0 or (touches and 1 or 2)
                    if rank < bestRank or (rank == bestRank and cost < bestCost) then
                        best, bestRank, bestCost = path, rank, cost
                    end
                end
            end
        end
        if not best or #best == 0 then return out, false end
        local loop, seen = {}, {}
        for _, e in ipairs(out) do
            loop[#loop + 1] = e
            seen[e.entity] = true
        end
        for _, e in ipairs(best) do
            if not seen[e.entity] then
                loop[#loop + 1] = e
                seen[e.entity] = true
            end
        end
        -- Any outerNodes->centerNodes return attaches both sides to the
        -- outbound leg, so the circuit is closed whenever it exists.
        return loop, true
    end
end

return city
