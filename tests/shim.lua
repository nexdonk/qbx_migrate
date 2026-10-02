-- FiveM / oxmysql / ox_lib shims for running qbx_migrate outside the game.
-- Every MySQL call yields a request table to the JS driver, which runs it against
-- MariaDB and resumes with the result.

json = dofile(HARNESS_DIR .. '/dkjson.lua')

local function dbcall(kind, query, params)
    local ok, result, err = coroutine.yield({ db = kind, query = query, params = params })
    if not ok then error(('SQL error in %s: %s\n  query: %s'):format(kind, tostring(result), tostring(query)), 2) end
    return result
end

MySQL = {
    query = { await = function(q, p) return dbcall('query', q, p) end },
    scalar = { await = function(q, p) return dbcall('scalar', q, p) end },
    single = { await = function(q, p) return dbcall('single', q, p) end },
    prepare = { await = function(q, p) return dbcall('prepare', q, p) end },
    insert = { await = function(q, p) return dbcall('insert', q, p) end },
    update = { await = function(q, p) return dbcall('update', q, p) end },
    transaction = { await = function(list) return dbcall('transaction', nil, list) end },
    rawExecute = { await = function(q, p) return dbcall('prepare', q, p) end },
}
setmetatable(MySQL.query, { __call = function(_, q, p, cb) local r = dbcall('query', q, p) if cb then cb(r) end return r end })

RESOURCE_NAME = 'qbx_migrate'
function GetCurrentResourceName() return RESOURCE_NAME end

SAVED_FILES = {}
function SaveResourceFile(res, path, data)
    SAVED_FILES[path] = data
    coroutine.yield({ file = path, data = data })
    return true
end

FIXTURE_FILES = FIXTURE_FILES or {}
function LoadResourceFile(res, path)
    local key = res .. '/' .. path
    if FIXTURE_FILES[key] then return FIXTURE_FILES[key] end
    if res == RESOURCE_NAME and SAVED_FILES[path] then return SAVED_FILES[path] end
    if res == RESOURCE_NAME and PROJECT_FILES then
        return PROJECT_FILES[path]
    end
    return nil
end

CONVARS = CONVARS or {}
function GetConvarInt(name, default) return CONVARS[name] or default end
function GetConvar(name, default) return CONVARS[name] or default end

RESOURCE_STATES = RESOURCE_STATES or {}
function GetResourceState(name) return RESOURCE_STATES[name] or 'missing' end

COMMANDS = {}
function RegisterCommand(name, fn) COMMANDS[name] = fn end

EVENT_HANDLERS = {}
function AddEventHandler(name, fn)
    EVENT_HANDLERS[name] = EVENT_HANDLERS[name] or {}
    table.insert(EVENT_HANDLERS[name], fn)
end
RegisterNetEvent = AddEventHandler

THREADS = {}
function CreateThread(fn) table.insert(THREADS, fn) end
function Wait() end
function SetTimeout(_, fn) table.insert(THREADS, fn) end

OX_ITEMS = OX_ITEMS or {}
exports = setmetatable({}, { __index = function(_, res)
    if res == 'ox_inventory' then
        return { Items = function() return OX_ITEMS end }
    end
    return setmetatable({}, { __index = function() return function() error('export not available in harness') end end })
end })

-- fake connecting player
PLAYER_IDENTIFIERS = PLAYER_IDENTIFIERS or {}
function GetPlayerIdentifierByType(src, kind)
    for _, id in ipairs(PLAYER_IDENTIFIERS[src] or {}) do
        if id:sub(1, #kind + 1) == kind .. ':' then return id end
    end
    return nil
end
function GetNumPlayerIdentifiers(src) return #(PLAYER_IDENTIFIERS[src] or {}) end
function GetPlayerIdentifier(src, i) return (PLAYER_IDENTIFIERS[src] or {})[i + 1] end
function GetPlayerName(src) return 'TestPlayer' .. tostring(src) end
function IsPlayerAceAllowed() return true end
function DropPlayer() end

PRINTED = {}
local rawprint = print
function print(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, '\t')
    PRINTED[#PRINTED + 1] = line
    if HARNESS_ECHO then rawprint(line) end
end

-- Runs a console command as the resource would (RegisterCommand handler + CreateThread).
function RUN_COMMAND(...)
    THREADS = {}
    COMMANDS.qbxmigrate(0, { ... }, table.concat({ ... }, ' '))
    for _, fn in ipairs(THREADS) do fn() end
end

-- Simulates playerConnecting for the identity reconciler.
function RUN_CONNECT(src)
    local done = false
    local deferrals = {
        defer = function() end,
        update = function() end,
        done = function(msg) done = true; DEFERRAL_MSG = msg end,
    }
    for _, fn in ipairs(EVENT_HANDLERS.playerConnecting or {}) do
        source = src
        fn(GetPlayerName(src), function() end, deferrals)
    end
    return done
end

-- HTTP bridge (server/panel.lua). HTTP_REQUEST drives the registered handler.
function SetHttpHandler(fn) HTTP_HANDLER = fn end
function GetResourceMetadata() return 'test' end
function HTTP_REQUEST(method, path, headers, address, body)
    local out = {}
    local req = { method = method, path = path, headers = headers or {}, address = address or '127.0.0.1:50000' }
    function req.setDataHandler(cb) cb(body or '') end
    local res = {
        writeHead = function(code) out.code = code end,
        send = function(data) out.body = data end,
    }
    HTTP_HANDLER(req, res)
    return out.code, out.body and json.decode(out.body)
end
