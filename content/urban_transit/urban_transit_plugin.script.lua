-- Town-window UI for Urban Tram Planner Alpha v0.6.

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

    local Content = react.RegisterRecipe("urban_transit_alpha_Content_v06", function(params)
        local town = params.entityId
        local previewState = react.useState(nil)
        local busyState = react.useState(false)
        local statusState = react.useState("")
        local electricState = react.useState(true)

        local children = {
            text("ALPHA 0.6 - Ruta documentada Proposal/StreetTemplate para via tranviaria."),
            text("Correccion principal v0.6: las calles con tranvia usan TRAM/ELECTRIC_TRAM (no TRAM_TRACK de via ferrea). El inventario solo acepta plantillas STREET, conserva acceso de coches y excluye puentes/tuneles. La construccion revalida cada segmento."),
            text("Seguimos con UN corredor radial de control. Ring/Hybrid, paradas, lineas, vehiculos, feeders, carga y recálculo persistente siguen reservados hasta confirmar que esta conversion fisica funciona en partida."),
            builtin.CheckBox{
                value = electricState:old() and 1 or 0,
                label = "Preferir tranvia electrico / catenaria",
                onValueChange = function(v)
                    electricState:set(v == 1)
                    previewState:set(nil)
                    statusState:set("")
                end,
            },
            builtin.Button{
                meta = { class = "primary", enabled = not busyState:old() },
                content = text("Analizar corredor radial v0.6"),
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
                    "Corredor: %d segmentos | %.2f km | con via: %d | electricos: %d",
                    pv.segments or 0, (pv.length or 0) / 1000, pv.alreadyTram or 0, pv.alreadyElectric or 0
                ))
                children[#children + 1] = text(string.format(
                    "Carriles de via a agregar: %d | fallback no electrico: %d",
                    pv.tramLanesToAdd or 0, pv.electricFallbacks or 0
                ))
                children[#children + 1] = text("Source -> target: " .. compactSummary(pv.sourceTargetCounts, 4))
                children[#children + 1] = text(string.format(
                    "Validacion: %d segmento(s) rechazados | coste estimado: %s",
                    pv.refused or 0, money(pv.cost or 0)
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
                        content = text("CONSTRUIR CORREDOR DE PRUEBA v0.6"),
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

        if statusState:old() ~= "" then children[#children + 1] = text(statusState:old()) end
        return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = children }
    end)

    local m = {}
    m.condition = function(params)
        return not (params.state and params.state.isMapEditor)
    end

    m.Plugin = react.RegisterPluginRecipe(town_eow.TownEowExtensionPoint, "urban_transit_alpha_Plugin_v06", function(params)
        local ok, result = pcall(function()
            return builtin.BoxLayout{
                child = content_card.ContentCard{
                    title = "Urban Tram Planner [ALPHA 0.5]",
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
