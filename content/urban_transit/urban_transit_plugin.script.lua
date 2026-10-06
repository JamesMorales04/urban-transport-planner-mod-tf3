-- Town-window UI for Urban Tram Planner Alpha v0.10.

local module = nil

local function build()
    local builtin = ug_require("::/gui/main/builtin.lua")
    local react = ug_require("::/gui/main/react.lua")
    local content_card = ug_require("::/gui/main/content_card.tl")
    local town_eow = ug_require("::/gui/entity_window/town/town_eow.script.tl")
    local core = ug_require("urban_transport_planner::/urban_transit/urban_transit_core.lua")

    local function text(t, class)
        return builtin.TextView{ meta = { class = class or "font-scale-body" }, text = tostring(t) }
    end

    local function money(n)
        local sign = n < 0 and "-" or ""
        n = math.abs(n or 0)
        local s = tostring(math.floor(n + 0.5)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
        return sign .. "$" .. s:gsub("^,", "")
    end

    local function compactSummary(counts, maxRows)
        local rows = {}
        for name, n in pairs(counts or {}) do
            rows[#rows + 1] = tostring(name) .. " x" .. tostring(n)
        end
        table.sort(rows)
        if #rows == 0 then return "-" end
        maxRows = maxRows or 3
        if #rows <= maxRows then return table.concat(rows, " | ") end
        local out = {}
        for i = 1, maxRows do out[#out + 1] = rows[i] end
        out[#out + 1] = "+" .. tostring(#rows - maxRows) .. " mas"
        return table.concat(out, " | ")
    end

    local Content = react.RegisterRecipe("urban_transit_alpha_Content_v10", function(params)
        local town = params.entityId
        local previewState = react.useState(nil)
        local busyState = react.useState(false)
        local statusState = react.useState("")
        local electricState = react.useState(true)
        local stopPlanState = react.useState(nil)
        local lineInfoState = react.useState(nil)

        local children = {
            text("ALPHA 0.10 - Ida + vuelta, cruces automaticos, paradas recuperables."),
            text("Flujo: analiza -> construye (verifica y repara cruces solo) -> paradas (espaciadas o reutiliza existentes) -> crea IDA + VUELTA y tranvias repartidos."),
            text("Feeders de bus y carga: tras validar el tranvia en servicio (ver docs/STATUS.md)."),
            builtin.CheckBox{
                value = electricState:old() and 1 or 0,
                label = "Preferir tranvia electrico / catenaria",
                onValueChange = function(v)
                    electricState:set(v == 1)
                    previewState:set(nil)
                    stopPlanState:set(nil)
                    lineInfoState:set(nil)
                    statusState:set("")
                end,
            },
            builtin.Button{
                meta = { class = "primary", enabled = not busyState:old() },
                content = text("Analizar corredor radial v0.10"),
                onClick = function()
                    statusState:set("Analizando StreetTemplates reales y validando propuestas...")
                    local r = core.analyzeSafe(town, electricState:old())
                    previewState:set(r)
                    statusState:set(r.error and r.error or "Analisis completado. Revisa source -> target antes de construir.")
                end,
            },
        }

        local pv = previewState:old()
        if pv then
            if pv.error then
                children[#children + 1] = text("ERROR: " .. pv.error)
                if (pv.templateRepoTotal or 0) > 0 then
                    children[#children + 1] = text(string.format(
                        "Repositorio: %d total | %d disponibles | %d calles | %d calles con tranvia | %d vias ferreas",
                        pv.templateRepoTotal or 0, pv.templateRepoAvailable or 0, pv.streetResources or 0,
                        pv.directStreetTram or 0, pv.railTrackResources or 0
                    ))
                end
                if pv.trackTemplateSamples and #pv.trackTemplateSamples > 0 then
                    children[#children + 1] = text("Muestra de plantillas con via: " .. table.concat(pv.trackTemplateSamples, " | "))
                end
            else
                children[#children + 1] = text(string.format(
                    "Ciudad: %d edificios | radio P95: %.0f m",
                    pv.buildings or 0, pv.radius or 0
                ))
                children[#children + 1] = text(string.format(
                    "Calles convertibles: %d | incompatibles: %d | puentes/tuneles excluidos: %d | no-calle excluidas: %d",
                    pv.streetEdges or 0, pv.incompatibleEdges or 0,
                    pv.excludedStructure or 0, pv.excludedNonStreet or 0
                ))
                children[#children + 1] = text(string.format(
                    "Plantillas actuales: %d | plantillas con via fisica: %d | repo: %d (%d disponibles)",
                    pv.currentTemplates or 0, pv.trackTemplates or 0, pv.templateRepoTotal or 0, pv.templateRepoAvailable or 0
                ))
                children[#children + 1] = text(string.format(
                    "Corredor: %d segmentos | %.2f km | con via: %d | electricos: %d | cobertura: %d%% (%d edificios <160m) | circuito: %s",
                    pv.segments or 0, (pv.length or 0) / 1000, pv.alreadyTram or 0, pv.alreadyElectric or 0,
                    pv.coveragePct or 0, pv.coverageN or 0,
                    pv.loopClosed and "cerrado" or "abierto (sin retorno disjunto)"
                ))
                children[#children + 1] = text(string.format(
                    "Carriles de via a agregar: %d | fallback no electrico: %d",
                    pv.tramLanesToAdd or 0, pv.electricFallbacks or 0
                ))
                children[#children + 1] = text("Source -> target: " .. compactSummary(pv.sourceTargetCounts, 4))
                children[#children + 1] = text(string.format(
                    "Validacion (creacion): %d segmento(s) rechazados | coste: %s",
                    pv.refused or 0,
                    pv.costKnown and money(pv.cost or 0) or "lo calcula el motor al construir"
                ))
                if pv.target then
                    children[#children + 1] = text(string.format(
                        "Sector periferico elegido: %d edificios exteriores",
                        pv.target.buildings or 0
                    ))
                end
                if pv.firstError then children[#children + 1] = text("Primer error: " .. pv.firstError) end

                if pv.buildable then
                    children[#children + 1] = text("Todos los segmentos pasaron la validacion. Haz una copia/manual save antes de la prueba fisica.")
                    children[#children + 1] = builtin.Button{
                        meta = { class = "primary", enabled = not busyState:old() },
                        content = text("CONSTRUIR CORREDOR DE PRUEBA v0.10"),
                        onClick = function()
                            busyState:set(true)
                            statusState:set("Iniciando construccion...")
                            local ok, err = pcall(core.build, town, electricState:old(), function(msg, isError)
                                statusState:set(msg)
                                if isError or string.find(msg, "^Done") then busyState:set(false) end
                                if isError or string.find(msg, "^Done") then core.log(msg) end
                            end)
                            if not ok then
                                local msg = core.errorText and core.errorText(err) or tostring(err)
                                core.log("build exception: " .. msg)
                                statusState:set("Error inesperado: " .. msg)
                                busyState:set(false)
                            end
                        end,
                    }
                else
                    children[#children + 1] = text("Construccion deshabilitada: la validacion detecto uno o mas segmentos no aceptados. Copia las lineas [Urban Tram Planner Alpha] de stdout.txt.")
                end
            end
        end

        -- v0.9: cruces, paradas y linea sobre el corredor construido.
        do
            children[#children + 1] = builtin.Button{
                meta = { class = "primary", enabled = not busyState:old() },
                content = text("DIAGNOSTICAR + REPARAR CRUCES"),
                onClick = function()
                    busyState:set(true)
                    statusState:set("Inspeccionando cruces del corredor...")
                    local ok, err = pcall(core.checkAndRepairJunctions, town, electricState:old(),
                        function(msg, isError)
                            statusState:set(msg)
                            if isError then core.log(msg) end
                        end,
                        function(insp, summary, isError)
                            busyState:set(false)
                            statusState:set(summary)
                        end)
                    if not ok then
                        statusState:set("Error inesperado: " .. core.errorText(err))
                        busyState:set(false)
                    end
                end,
            }
            children[#children + 1] = builtin.Button{
                meta = { class = "primary", enabled = not busyState:old() },
                content = text("USAR PARADAS EXISTENTES"),
                onClick = function()
                    statusState:set("Buscando paradas junto al corredor...")
                    local r = core.findCorridorGroupsSafe(town, electricState:old())
                    if r.error then
                        statusState:set(r.error)
                    else
                        lineInfoState:set(r)
                        stopPlanState:set(nil)
                        statusState:set(string.format(
                            "Paradas existentes: %d grupos.", #r.groups))
                    end
                end,
            }
            local sp = stopPlanState:old()
            children[#children + 1] = builtin.Button{
                meta = { class = "primary", enabled = not busyState:old() },
                content = text("PLANIFICAR PARADAS v0.10"),
                onClick = function()
                    statusState:set("Planificando paradas sobre el corredor actual...")
                    local r = core.planStopsSafe(town, electricState:old())
                    stopPlanState:set(r)
                    lineInfoState:set(nil)
                    statusState:set(r.error and r.error or "Plan de paradas listo.")
                end,
            }
            if sp then
                if sp.error then
                    children[#children + 1] = text("ERROR paradas: " .. sp.error)
                else
                    local sk = sp.skipped or {}
                    children[#children + 1] = text(string.format(
                        "Paradas ubicables: %d (minimo 2, separadas 272m) | sin convertir: %d | cortas: %d | con objetos: %d | muy juntas omitidas: %d",
                        sp.stops or 0, sk.unconverted or 0, sk.short or 0, sk.objects or 0,
                        sk.spacing or 0
                    ))
                    children[#children + 1] = text(string.format(
                        "Tranvias a la venta: %d%s | deposito tranviario: %s",
                        sp.tramModels or 0,
                        sp.tramModelName and (" (" .. sp.tramModelName .. ")") or "",
                        sp.depotFound and "si" or "NO"
                    ))
                    if not sp.depotFound then
                        children[#children + 1] = text("Sin deposito: la linea se crea igual. Para tranvias automaticos, construye un deposito de tranvias pegado a una calle con via y luego usa COMPRAR TRANVIAS.")
                    end
                    if sp.buildable then
                        children[#children + 1] = builtin.Button{
                            meta = { class = "primary", enabled = not busyState:old() },
                            content = text("CONSTRUIR PARADAS"),
                            onClick = function()
                                busyState:set(true)
                                statusState:set("Construyendo paradas...")
                                local ok, err = pcall(core.buildStops, town, electricState:old(),
                                    function(msg, isError)
                                        statusState:set(msg)
                                        if isError then busyState:set(false) end
                                        if isError then core.log(msg) end
                                    end,
                                    function(info, summary, isError)
                                        lineInfoState:set(isError and nil or info)
                                        if not isError then busyState:set(false) end
                                    end)
                                if not ok then
                                    statusState:set("Error inesperado: " .. core.errorText(err))
                                    busyState:set(false)
                                end
                            end,
                        }
                    else
                        children[#children + 1] = text("Construye primero el corredor con tranvia (se necesitan 2+ paradas ubicables).")
                    end
                end
            end

            local li = lineInfoState:old()
            if li and li.groups and #li.groups >= 2 then
                children[#children + 1] = text(string.format(
                    "Grupos de estacion: %d en %.2f km. Se crean IDA + VUELTA (ambos sentidos).",
                    #li.groups, (li.length or 0) / 1000
                ))
                children[#children + 1] = builtin.Button{
                    meta = { class = "primary", enabled = not busyState:old() },
                    content = text("CREAR IDA + VUELTA + TRANVIAS"),
                    onClick = function()
                        busyState:set(true)
                        statusState:set("Creando lineas...")
                        local ok, err = pcall(core.createLineAndTrams, li, electricState:old(), town,
                            function(msg, isError)
                                statusState:set(msg)
                                if isError then core.log(msg) end
                            end,
                            function(res, msg, isError)
                                busyState:set(false)
                                statusState:set(msg)
                                if res and (res.out or res.back) then
                                    lineInfoState:set({
                                        groups = li.groups,
                                        length = li.length,
                                        townName = li.townName,
                                        lines = { out = res.out, back = res.back },
                                    })
                                end
                            end)
                        if not ok then
                            statusState:set("Error inesperado: " .. core.errorText(err))
                            busyState:set(false)
                        end
                    end,
                }
            end
            if li and li.lines and (li.lines.out or li.lines.back) then
                children[#children + 1] = builtin.Button{
                    meta = { class = "primary", enabled = not busyState:old() },
                    content = text("COMPRAR TRANVIAS (linea existente)"),
                    onClick = function()
                        busyState:set(true)
                        statusState:set("Buscando deposito...")
                        local ok, err = pcall(core.buyTramsForLine, li, town, electricState:old(),
                            function(msg, isError)
                                statusState:set(msg)
                                if isError then core.log(msg) end
                            end,
                            function(bought, msg, isError)
                                busyState:set(false)
                                statusState:set(msg)
                            end)
                        if not ok then
                            statusState:set("Error inesperado: " .. core.errorText(err))
                            busyState:set(false)
                        end
                    end,
                }
            end
        end

        if statusState:old() ~= "" then children[#children + 1] = text(statusState:old()) end
        return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
    end)

    local m = {}
    m.condition = function(params)
        return not (params.state and params.state.isMapEditor)
    end

    m.Plugin = react.RegisterPluginRecipe(town_eow.TownEowExtensionPoint, "urban_transit_alpha_Plugin_v10", function(params)
        local ok, result = pcall(function()
            return builtin.BoxLayout{
                child = content_card.ContentCard{
                    title = "Urban Tram Planner [ALPHA 0.10]",
                    initialCalloutTextPermanent = "",
                    recipeAndParamPermanent = content_card.makeRecipeAndParam(Content, { entityId = params.entityId }),
                    gameCtx = params.gameCtx,
                    showOnRightSide = params.showCalloutOnRightSide,
                },
            }
        end)
        if not ok then
            print("[Urban Tram Planner Alpha] plugin error: " .. tostring(result))
            return nil
        end
        return result
    end)

    return m
end

function data()
    if not module then
        local ok, result = pcall(build)
        if not ok then
            print("[Urban Tram Planner Alpha] could not start: " .. tostring(result))
            result = {}
        end
        module = result
    end
    return module
end
