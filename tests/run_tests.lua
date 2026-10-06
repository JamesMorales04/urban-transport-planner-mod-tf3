-- UTP unit tests (engine-independent). Run: lua tests/run_tests.lua
-- Stubs the `api` global and `ug_require` so the real modules load unmodified.

local BASE = arg and arg[0] and arg[0]:match("^(.*)/tests/run_tests%.lua$") or "."
local CONTENT = BASE .. "/content/urban_transit"

-- Minimal api stub: distinct enum sentinels, in-memory streetTemplateRep.
local TRAM, ETRAM, TTRACK, ETRACK = {}, {}, {}, {}
local CAR, BUS, TRUCK = {}, {}, {}
local STREET, TRACK, NORMAL = {}, {}, {}
_G.api = {
    type = {
        enum = {
            TransportMode = {
                TRAM = TRAM, ELECTRIC_TRAM = ETRAM,
                TRAM_TRACK = TTRACK, ELECTRIC_TRAM_TRACK = ETRACK,
                CAR = CAR, BUS = BUS, TRUCK = TRUCK,
            },
            RoadType = { STREET = STREET, TRACK = TRACK },
            BaseEdgeType = { NORMAL = NORMAL },
            ComponentType = { BASE_EDGE = {}, BASE_EDGE_STREET = {} },
        },
        Vec2f = { new = function(x, y) return { x = x, y = y } end },
        Context = { new = function() return {} end },
    },
    engine = {
        util = { getYear = function() return 2000 end },
    },
    res = {},
}

local failures, passes = 0, 0
local function check(name, cond, extra)
    if cond then
        passes = passes + 1
        print("PASS " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. (extra and (" | " .. tostring(extra)) or ""))
    end
end

-- ug_require stub loading real files with caching.
local cache = {}
_G.ug_require = function(path)
    if cache[path] then return cache[path] end
    local file = path:match("/([^/]+)%.lua$")
    local mod = dofile(CONTENT .. "/" .. file .. ".lua")
    cache[path] = mod
    return mod
end

local logger = ug_require("urban_transport_planner::/urban_transit/utp_logger.lua")
local catalog = ug_require("urban_transport_planner::/urban_transit/utp_street_catalog.lua")
local city = ug_require("urban_transport_planner::/urban_transit/utp_city.lua")
local stopMod = ug_require("urban_transport_planner::/urban_transit/utp_stops.lua")
local lineMod = ug_require("urban_transport_planner::/urban_transit/utp_lines.lua")
local jointMod = ug_require("urban_transport_planner::/urban_transit/utp_junction.lua")

check("logger.errorText string", logger.errorText("boom") == "boom")
check("logger.errorText table", logger.errorText({ message = "m1" }) == "message=m1")

-- Mock lanes faithfully mirroring street.zip content (string list form).
local function carLane() return { forward = false, width = 4, offset = 0, transportModes = { "CAR", "BUS", "TRUCK" } } end
local function tramLane()
    return { forward = false, width = 5, offset = -0.5,
        transportModes = { "CAR", "BUS", "TRUCK", "TRAM", "ELECTRIC_TRAM" } }
end
local function railLane()
    return { forward = true, width = 5, offset = 0,
        transportModes = { "TRAIN", "ELECTRIC_TRAIN", "TRAM_TRACK", "ELECTRIC_TRAM_TRACK" } }
end

-- 1-2: lane detection
do
    local t, e = catalog.laneStreetTram(tramLane())
    check("laneStreetTram mixed", t == true and e == true)
    local t2, e2 = catalog.laneStreetTram(carLane())
    check("laneStreetTram plain car", t2 == false and e2 == false)
    local t3 = catalog.laneStreetTram(railLane())
    check("laneStreetTram ignores rail TRAM_TRACK", t3 == false)
    local r1 = catalog.laneRailTrack(railLane())
    check("laneRailTrack detects rail", r1 == true)
    local r2 = catalog.laneRailTrack(tramLane())
    check("laneRailTrack ignores street TRAM", r2 == false)
end

-- Enum-keyed runtime form { [TRAM]=true }.
do
    local t, e = catalog.laneStreetTram({ transportModes = { [TRAM] = true, [CAR] = true } })
    check("laneStreetTram enum-keyed map", t == true and e == false)
    local t2, e2 = catalog.laneStreetTram({ transportModes = { [ETRAM] = true } })
    check("laneStreetTram enum electric", t2 == true and e2 == true)
end

-- 3: template kinds. 8-lane town_new_large analogues.
local function mockPlainLarge()
    local lanes = {
        { forward = false, width = 3, offset = 0.15, transportModes = { "PERSON", "CARGO" } },
        { forward = false, width = 5, offset = -0.5, transportModes = { "CAR", "BUS", "TRUCK" } },
    }
    for _ = 1, 4 do lanes[#lanes + 1] = carLane() end
    lanes[#lanes + 1] = { forward = true, width = 5, offset = 0.5, transportModes = { "CAR", "BUS", "TRUCK" } }
    lanes[#lanes + 1] = { forward = true, width = 3, offset = -0.15, transportModes = { "PERSON", "CARGO" } }
    return { roadType = "STREET", country = false, streetStyle = "S", cost = 500, laneConfigs = lanes }
end
local function mockTramLarge()
    local tpl = mockPlainLarge()
    tpl.laneConfigs[2] = tramLane()
    tpl.laneConfigs[7] = { forward = true, width = 5, offset = 0.5,
        transportModes = { "CAR", "BUS", "TRUCK", "TRAM", "ELECTRIC_TRAM" } }
    return tpl
end
local function mockPureTramway()
    return { roadType = "STREET", country = true, laneConfigs = {
        { forward = false, width = 5.5, offset = -0.25, transportModes = { "TRAM", "ELECTRIC_TRAM" } },
        { forward = true, width = 5.5, offset = 0.25, transportModes = { "TRAM", "ELECTRIC_TRAM" } },
    } }
end

do
    local h, e, n = catalog.templateStreetTramKinds(mockTramLarge())
    check("template kinds electrified 2 lanes", h == true and e == true and n == 2, "n=" .. tostring(n))
    local h2, e2, n2 = catalog.templateStreetTramKinds(mockPlainLarge())
    check("template kinds plain", h2 == false and e2 == false and n2 == 0)
end

-- 4: roadType
do
    check("isStreet STREET", catalog.isStreetRoadType({ roadType = "STREET" }) == true)
    check("isStreet TRACK rejected", catalog.isStreetRoadType({ roadType = "TRACK" }) == false)
    check("isStreet enum form", catalog.isStreetRoadType({ roadType = STREET }) == true)
end

-- 5-6: compatibility + scoring
do
    local plain, tram = mockPlainLarge(), mockTramLarge()
    check("compatible plain->tram", catalog.structurallyCompatible(plain, tram) == true)
    check("car access preserved required", catalog.structurallyCompatible(plain, mockPureTramway()) == false)
    local narrow = { roadType = "STREET", country = false, laneConfigs = { carLane(), carLane() } }
    check("lane count mismatch rejected", catalog.structurallyCompatible(plain, narrow) == false)
    local otherCountry = mockTramLarge()
    otherCountry.country = true
    check("country mismatch rejected", catalog.structurallyCompatible(plain, otherCountry) == false)
    check("score compatible finite", catalog.templateScore(plain, tram) < catalog.INF)
    check("score incompatible INF", catalog.templateScore(plain, mockPureTramway()) == catalog.INF)
end

-- 7: best-template choice with stubbed repository.
do
    local plain, tram = mockPlainLarge(), mockTramLarge()
    local repo = {
        ["town/plain"] = plain,
        ["town/tram_electrified"] = tram,
        ["rail/high_speed"] = { roadType = "TRACK", laneConfigs = { railLane() } },
    }
    -- Wire stub rep AFTER catalog load (catalog reads api.res at call time).
    local ids, names, byId = {}, {}, {}
    local i = 0
    for name, tpl in pairs(repo) do
        i = i + 1
        ids[name] = i names[i] = name byId[i] = tpl
    end
    api.res.streetTemplateRep = {
        getAll = function() local t = {} for id, n in pairs(names) do t[id] = n end return t end,
        find = function(name) return ids[name] or -1 end,
        get = function(id) return byId[id] end,
    }
    local inv = catalog.tramStreetInventory(true)
    check("inventory holds 1 street tram (rail excluded)", #inv == 1, "#=" .. #inv)
    if #inv == 1 then
        check("inventory entry is street tram", inv[1].name == "town/tram_electrified")
    end
    local best = catalog.bestTramStreetTemplate("town/plain", inv, true)
    check("best maps plain->tram", best ~= nil and best.name == "town/tram_electrified",
        best and best.name or "nil")
    local already = catalog.bestTramStreetTemplate("town/tram_electrified", inv, true)
    check("already-tram short-circuits", already ~= nil and already.alreadyTemplate == true)
    local missing = catalog.bestTramStreetTemplate("town/unknown", inv, true)
    check("unknown source returns nil", missing == nil)
end

-- 8: dijkstra + corridor on a square: 1-2-3-4 with shortcut 1-4 long.
do
    local function E(ent, n0, n1, len)
        return { entity = ent, node0 = n0, node1 = n1, length = len,
            satisfies = true, templateScore = 0, hasObjects = false }
    end
    local e12, e23, e34, e14 = E(12, 1, 2, 100), E(23, 2, 3, 100), E(34, 3, 4, 100), E(14, 1, 4, 500)
    local g = { adj = {
        [1] = { e12, e14 }, [2] = { e12, e23 }, [3] = { e23, e34 }, [4] = { e34, e14 },
    } }
    local path, cost = city.dijkstra(g, 1, 4, nil)
    check("dijkstra prefers 1-2-3-4 over direct", path ~= nil and #path == 3, "n=" .. (path and #path or -1))
    check("dijkstra cost 300*factor", cost ~= nil and math.abs(cost - 300 * 0.55) < 1e-6, "cost=" .. tostring(cost))
    local none = city.dijkstra({ adj = {} }, 1, 9, nil)
    check("dijkstra disconnected returns nil", none == nil)
end

-- 9: structure kind + traversal cost penalty for objects.
do
    check("edgeStructureKind NORMAL", city.edgeStructureKind({ type = "NORMAL" }) == "NORMAL")
    check("edgeStructureKind bridge SPECIAL", city.edgeStructureKind({ type = "BRIDGE" }) == "SPECIAL")
    local base = { length = 100, satisfies = false, templateScore = 0, hasObjects = false }
    local withObj = { length = 100, satisfies = false, templateScore = 0, hasObjects = true }
    check("objects penalize cost", city.traversalCost(withObj) > city.traversalCost(base))
end

-- 10: stop planning filters (pure: satisfies/length/objects).
do
    local path = {
        { entity = 1, satisfies = true, length = 60, hasObjects = false },
        { entity = 2, satisfies = true, length = 20, hasObjects = false },
        { entity = 3, satisfies = true, length = 80, hasObjects = true },
        { entity = 4, satisfies = false, length = 90, hasObjects = false },
    }
    local plan, skipped = stopMod.planStops(path)
    check("planStops keeps 1 eligible", #plan == 1 and plan[1].entity == 1,
        "#=" .. #plan)
    check("planStops counts skips",
        skipped.short == 1 and skipped.objects == 1 and skipped.unconverted == 1,
        string.format("short=%s obj=%s unconv=%s", tostring(skipped.short),
            tostring(skipped.objects), tostring(skipped.unconverted)))
    local empty = stopMod.planStops(nil)
    check("planStops nil-safe", #empty == 0)
end

-- 10b: bus_loops-style spacing along path order.
do
    local function E(ent, len)
        return { entity = ent, satisfies = true, length = len, hasObjects = false }
    end
    local path5 = { E(1, 100), E(2, 100), E(3, 100), E(4, 100), E(5, 100) }
    local plan5, sk5 = stopMod.planStops(path5)
    check("spacing spreads 5x100m to 2 stops", #plan5 == 2
        and plan5[1].entity == 1 and plan5[2].entity == 4,
        "got " .. table.concat((function()
            local t = {} for _, e in ipairs(plan5) do t[#t + 1] = e.entity end return t
        end)(), ","))
    check("spacing counts omitted", sk5.spacing == 3, "spacing=" .. tostring(sk5.spacing))
    local short3 = { E(1, 60), E(2, 60), E(3, 60) }
    local planS = stopMod.planStops(short3)
    check("short corridor keeps widest pair", #planS == 2
        and planS[1].entity == 1 and planS[2].entity == 3)
    local long12 = {}
    for i = 1, 12 do long12[#long12 + 1] = E(i, 300) end
    local planL = stopMod.planStops(long12)
    check("stops capped at MAX_STOPS", #planL == stopMod.MAX_STOPS, "#=" .. #planL)
end

-- 10c: corridor coverage (pure geometry).
do
    local pts = { { 0, 0 }, { 100, 0 }, { 1000, 1000 } }
    local path = { { x = 0, y = 0 }, { x = 200, y = 0 } }
    local frac, n = city.coverage(pts, path, 160)
    check("coverage 2/3 near", n == 2 and math.abs(frac - 2 / 3) < 1e-9,
        string.format("n=%s frac=%s", tostring(n), tostring(frac)))
    local f0 = city.coverage({}, path)
    check("coverage empty-safe", f0 == 0)
end

-- 10d: corridor joints pair consecutive edges per shared node (pure).
do
    local jp = {
        { entity = 11, node0 = 1, node1 = 2 },
        { entity = 22, node0 = 2, node1 = 3 },
        { entity = 33, node0 = 3, node1 = 4 },
    }
    local joints = jointMod.corridorJoints(jp)
    check("joints link consecutive pairs", #joints == 2, "#=" .. #joints)
    local okPairs = true
    for _, j in ipairs(joints) do
        if not ((j.edgeA == 11 and j.edgeB == 22) or (j.edgeA == 22 and j.edgeB == 33)) then
            okPairs = false
        end
    end
    check("joints carry shared node", okPairs and joints[1].node == 2)
    check("joints nil-safe", #jointMod.corridorJoints(nil) == 0)
end

-- 11: stop model era (stub year 2000 -> new).
do
    check("stopModel modern era", stopMod.stopModel() ==
        "::/stations/street/small_stops/small_new_twosided.con")
end

-- 12: vehicle count heuristic.
do
    check("vehicleCount 220m/4 groups = 1", lineMod.vehicleCount(220, 4) == 1)
    check("vehicleCount 1200m/4 groups = 3", lineMod.vehicleCount(1200, 4) == 3)
    check("vehicleCount capped by groups", lineMod.vehicleCount(5000, 2) == 2)
    check("vehicleCount minimum 1", lineMod.vehicleCount(0, 0) == 1)
end

-- 13: tram discovery with stubbed modelRep.
do
    local fakeModels = {
        ["tram/old.mdl"] = { transportVehicle = { transportModes = { "TRAM" } },
            availability = { yearFrom = 1900, yearTo = 0 },
            description = { name = "Old Tram" } },
        ["tram/modern.mdl"] = { transportVehicle = { transportModes = { "ELECTRIC_TRAM" } },
            availability = { yearFrom = 1950, yearTo = 0 },
            description = { name = "Modern Tram" } },
        ["bus/city.mdl"] = { transportVehicle = { transportModes = { "BUS" } },
            availability = { yearFrom = 1950, yearTo = 0 },
            description = { name = "City Bus" } },
    }
    local ids, byId, i = {}, {}, 0
    for name in pairs(fakeModels) do i = i + 1 ids[name] = i end
    for name, id in pairs(ids) do byId[id] = { metadata = fakeModels[name] } end
    api.res.modelRep = {
        forEachModelWithMetadata = function(kind, fn)
            for name in pairs(fakeModels) do fn(name) end
        end,
        find = function(name) return ids[name] or -1 end,
        get = function(id) return byId[id] end,
    }
    local all = lineMod.availableTrams(false)
    check("availableTrams finds 2 trams, no bus", #all == 2, "#=" .. #all)
    local elec = lineMod.availableTrams(true)
    check("availableTrams electric filter", #elec == 1 and elec[1].electric == true,
        #elec > 0 and elec[1].name or "none")
    check("availableTrams newest first", #all == 2 and all[1].from >= all[2].from)
end

print(string.format("--- %d passed, %d failed ---", passes, failures))
os.exit(failures == 0 and 0 or 1)
