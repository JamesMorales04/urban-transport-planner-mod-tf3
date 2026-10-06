-- UTP logger: uniform levels, single prefix for log filtering.
-- Usage from GUI thread: print() goes to stdout.txt.
-- Keep the legacy "[Urban Tram Planner Alpha]" prefix so existing
-- grep filters keep working: grep -F "[Urban Tram Planner Alpha]" stdout.txt

local logger = {}

logger.PREFIX = "[Urban Tram Planner Alpha]"

local LEVELS = { DEBUG = "DEBUG", INFO = "INFO", WARN = "WARN", ERROR = "ERROR" }
logger.LEVELS = LEVELS

-- Operative area tags, used as [UTP][AREA][LEVEL] in new code.
-- Legacy free-text messages keep the plain prefix for compatibility.
function logger.log(area, level, msg)
    local a = tostring(area or "CORE")
    local l = tostring(level or LEVELS.INFO)
    print(logger.PREFIX .. "[" .. a .. "][" .. l .. "] " .. tostring(msg))
end

function logger.raw(msg)
    print(logger.PREFIX .. " " .. tostring(msg))
end

function logger.debug(area, msg) logger.log(area, LEVELS.DEBUG, msg) end
function logger.info(area, msg) logger.log(area, LEVELS.INFO, msg) end
function logger.warn(area, msg) logger.log(area, LEVELS.WARN, msg) end
function logger.error(area, msg) logger.log(area, LEVELS.ERROR, msg) end

function logger.errorText(err)
    if err == nil then return "nil" end
    if type(err) ~= "table" then return tostring(err) end
    for _, key in ipairs({ "message", "error", "what", "reason", "text", "msg" }) do
        local ok, v = pcall(function() return err[key] end)
        if ok and v ~= nil and type(v) ~= "table" then
            return key .. "=" .. tostring(v)
        end
    end
    local parts = {}
    local ok = pcall(function()
        local n = 0
        for k, v in pairs(err) do
            n = n + 1
            if n > 10 then break end
            parts[#parts + 1] = tostring(k) .. "=" .. (type(v) == "table" and "<table>" or tostring(v))
        end
    end)
    if ok and #parts > 0 then return "{" .. table.concat(parts, ", ") .. "}" end
    return "engine error table (no printable fields)"
end

return logger
