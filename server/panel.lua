--[[
    HTTP bridge for the local control panel (panel/Panel.ps1, started by run.bat).

    Exposes http://<server>:30120/qbx_migrate/{status,run,job} so the panel can run
    `qbxmigrate` commands and stream their console output. Locked down two ways:

      - token:    every request must send `X-Qbxm-Token`. The token comes from the
                  `qbx_migrate_panel_token` convar, or is generated once and saved to
                  <resource>/panel_token.txt, where the panel picks it up by itself.
      - loopback: requests from anything but 127.0.0.1 / ::1 are refused unless
                  `set qbx_migrate_panel_remote true` is in server.cfg.

    `set qbx_migrate_panel false` turns the bridge off entirely.
]]

local RES = GetCurrentResourceName()
local TOKEN_FILE = 'panel_token.txt'
local MAX_LINES = 20000
local KEEP_JOBS = 10

if GetConvar('qbx_migrate_panel', 'true') == 'false' then return end

-- Commands and argument shapes the panel may run. Anything else is refused.
local ALLOWED = {
    help = true, inspect = true, check = true, backup = true, identity = true,
    schema = true, items = true, jobs = true, inventory = true, phone = true,
    metadata = true, all = true, esx = true, restore = true,
}

local function validArgs(command, arg2, arg3)
    if command == 'restore' then
        return type(arg2) == 'string' and arg2:match('^[%w_%-]+$') ~= nil
            and (arg3 == nil or arg3 == 'apply')
    end
    if command == 'esx' and arg2 == 'rollback' then
        return arg3 == nil or arg3 == 'apply'
    end
    return (arg2 == nil or arg2 == 'apply') and arg3 == nil
end

local function loadToken()
    local token = GetConvar('qbx_migrate_panel_token', '')
    if token ~= '' then return token end
    token = (LoadResourceFile(RES, TOKEN_FILE) or ''):match('^%s*(%x+)%s*$')
    if token and #token >= 32 then return token end
    local parts = {}
    for i = 1, 32 do parts[i] = ('%x'):format(math.random(0, 15)) end
    token = table.concat(parts)
    SaveResourceFile(RES, TOKEN_FILE, token, -1)
    return token
end

local TOKEN = loadToken()
local ALLOW_REMOTE = GetConvar('qbx_migrate_panel_remote', 'false') == 'true'

-- ---------------------------------------------------------------------------------
-- Jobs: one command at a time, console output captured while it runs.
-- ---------------------------------------------------------------------------------

local jobs, order, nextId, current = {}, {}, 0, nil

local rawPrint = print
function print(...)
    rawPrint(...)
    if not current then return end
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local text = table.concat(parts, '\t')
    for line in (text .. '\n'):gmatch('(.-)\r?\n') do
        if #current.lines < MAX_LINES then current.lines[#current.lines + 1] = line end
        local file = line:match('report written %-> [^/]+/(.+)$')
        if file then current.reportFile = file end
    end
end

local function startJob(command, arg2, arg3)
    if current or QBXM.isRunning() then return nil, 'a command is already running' end
    nextId = nextId + 1
    local job = {
        id = nextId, command = command, args = { arg2, arg3 },
        text = table.concat({ 'qbxmigrate', command, arg2, arg3 }, ' '),
        status = 'running', lines = {}, started = os.time(),
    }
    jobs[job.id], order[#order + 1] = job, job.id
    while #order > KEEP_JOBS do jobs[table.remove(order, 1)] = nil end

    current = job
    rawPrint(('[qbx_migrate] panel: %s'):format(job.text))
    CreateThread(function()
        local ok, result, err = pcall(QBXM.run, command, arg2, arg3)
        current = nil
        job.finished = os.time()
        job.status = (ok and result ~= false) and 'done' or 'failed'
        job.error = not ok and tostring(result) or (result == false and tostring(err) or nil)
        if job.reportFile then job.report = LoadResourceFile(RES, job.reportFile) end
    end)
    return job
end

-- ---------------------------------------------------------------------------------
-- HTTP
-- ---------------------------------------------------------------------------------

local function header(req, name)
    for k, v in pairs(req.headers or {}) do
        if k:lower() == name then return v end
    end
end

local function isLoopback(address)
    if not address then return false end
    return address:match('^127%.') ~= nil or address:match('^%[::1%]') ~= nil
        or address == '::1' or address:match('^%[?::ffff:127%.') ~= nil
end

local function parseQuery(qs)
    local out = {}
    for k, v in (qs or ''):gmatch('([^&=]+)=([^&]*)') do out[k] = v end
    return out
end

local function reply(res, code, body)
    res.writeHead(code, { ['Content-Type'] = 'application/json', ['Cache-Control'] = 'no-store' })
    res.send(json.encode(body))
end

local function jobView(job, from)
    local lines = {}
    for i = (from or 0) + 1, #job.lines do lines[#lines + 1] = job.lines[i] end
    return {
        id = job.id, command = job.text, status = job.status, error = job.error,
        started = job.started, finished = job.finished,
        lines = lines, next = #job.lines,
        reportFile = job.reportFile, report = job.status ~= 'running' and job.report or nil,
    }
end

local function handle(req, res, body)
    local path, qs = (req.path or '/'):match('^([^?]*)%??(.*)$')

    if path == '/status' then
        local recent = {}
        for i = #order, 1, -1 do
            local job = jobs[order[i]]
            recent[#recent + 1] = { id = job.id, command = job.text, status = job.status, started = job.started, finished = job.finished }
        end
        return reply(res, 200, {
            resource = RES,
            version = GetResourceMetadata and GetResourceMetadata(RES, 'version', 0) or nil,
            busy = current ~= nil or QBXM.isRunning(),
            esx = QBXM.HOOKS.esxDetected and QBXM.HOOKS.esxDetected() or false,
            jobs = recent,
        })
    end

    if path == '/job' then
        local q = parseQuery(qs)
        local job = jobs[tonumber(q.id)]
        if not job then return reply(res, 404, { error = 'no such job' }) end
        return reply(res, 200, jobView(job, tonumber(q.from)))
    end

    if path == '/run' then
        if req.method ~= 'POST' then return reply(res, 405, { error = 'POST only' }) end
        local ok, data = pcall(json.decode, body or '')
        if not ok or type(data) ~= 'table' then return reply(res, 400, { error = 'bad JSON' }) end
        local command, arg2, arg3 = data.command, data.arg2, data.arg3
        if arg2 == '' then arg2 = nil end
        if arg3 == '' then arg3 = nil end
        if not ALLOWED[command] or not validArgs(command, arg2, arg3) then
            return reply(res, 400, { error = 'command not allowed' })
        end
        local job, err = startJob(command, arg2, arg3)
        if not job then return reply(res, 409, { error = err }) end
        return reply(res, 200, { id = job.id })
    end

    return reply(res, 404, { error = 'not found' })
end

SetHttpHandler(function(req, res)
    if not ALLOW_REMOTE and not isLoopback(req.address) then
        return reply(res, 403, { error = 'loopback only (set qbx_migrate_panel_remote true to allow)' })
    end
    if header(req, 'x-qbxm-token') ~= TOKEN then
        return reply(res, 401, { error = 'bad token' })
    end
    if req.method == 'POST' then
        req.setDataHandler(function(body) handle(req, res, body) end)
    else
        handle(req, res)
    end
end)
