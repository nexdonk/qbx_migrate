--[[
    qbx_migrate :: server/identity.lua

    Login-time identifier reconciler.

    Qbox keys a player by `license2:<hash>`. Anything migrated from QBCore is stored
    as `license:<hash>`; anything migrated from ESX is stored as whatever ESX's
    Config.Identifier was (license, steam, fivem, discord). license2 is a different
    Rockstar identifier and cannot be computed from any of those offline.

    qbx_core itself tolerates this (it selects `WHERE license = license2 OR license =
    license`), but it never rewrites the stored value, and anything else keyed by
    license - bans, player_vehicles.license, third-party tables - stays on the old id
    forever. So, on every connect, BEFORE qbx_core loads characters:

        1. collect every identifier the joining client presents
        2. for each configured (table, column), find rows whose value matches ANY of
           them - full `type:value` or the bare value ESX stored
        3. rewrite those rows to license2

    Idempotent: once a row says license2 it never matches again. Rows that belong to
    somebody else can't match, because identifiers are per-account.

    `qbxmigrate identity` reports how many rows are still on a pre-Qbox identifier.
]]

local CFG = QBXM.CONFIG.identity
local tableExists, columnExists = QBXM.tableExists, QBXM.columnExists

-- (table, column) pairs that exist in this database, resolved once and refreshed
-- whenever a migration step runs (tables appear after `esx apply`).
local liveColumns
local logTableReady = false

local function ensureLogTable()
    if logTableReady then return end
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `qbx_migrate_identity_log` (
            `id` int(11) NOT NULL AUTO_INCREMENT,
            `license2` varchar(60) NOT NULL,
            `old_value` varchar(60) NOT NULL,
            `table_name` varchar(64) NOT NULL,
            `column_name` varchar(64) NOT NULL,
            `rows` int(11) NOT NULL,
            `player_name` varchar(255) DEFAULT NULL,
            `at` timestamp NOT NULL DEFAULT current_timestamp(),
            PRIMARY KEY (`id`), KEY `license2` (`license2`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    logTableReady = true
end

local function resolveColumns(force)
    if liveColumns and not force then return liveColumns end
    liveColumns = {}
    for _, spec in ipairs(CFG.columns) do
        if tableExists(spec.table) and columnExists(spec.table, spec.column) then
            liveColumns[#liveColumns + 1] = spec
        end
    end
    return liveColumns
end

QBXM.refreshIdentityColumns = function() resolveColumns(true) end

--- Every value a stored identifier could have been written as for this client:
--- `license:abc`, `steam:1100..`, plus the bare `abc` / `1100..` that ESX Legacy strips
--- to. `ip:` is excluded on purpose - it is shared between accounts behind one NAT.
--- Returns the candidate list and the license2 value, or nil when the client has none.
local function candidateIdentifiers(src)
    local license2 = GetPlayerIdentifierByType(src, 'license2')
    if not license2 then return nil end

    local list, seen = {}, {}
    local function push(v)
        if v and v ~= '' and v ~= license2 and not seen[v] then
            seen[v] = true
            list[#list + 1] = v
        end
    end

    for i = 0, GetNumPlayerIdentifiers(src) - 1 do
        local id = GetPlayerIdentifier(src, i)
        local kind, value = id:match('^(%a+):(.+)$')
        if kind and kind ~= 'ip' and kind ~= 'license2' then
            push(id)
            push(value)
        end
    end

    return list, license2
end

local function placeholders(n)
    return string.rep('?', n, ', ')
end

--- Rewrites every matching row for this client. Returns total rows rewritten.
local function reconcile(src, playerName)
    local candidates, license2 = candidateIdentifiers(src)
    if not candidates or #candidates == 0 then return 0 end

    local total = 0
    for _, spec in ipairs(resolveColumns()) do
        local marks = placeholders(#candidates)

        -- Read first so the log records what the value used to be. Rows on
        -- license2 already do not match and cost nothing.
        local matches = MySQL.query.await(
            ('SELECT DISTINCT `%s` AS v FROM `%s` WHERE `%s` IN (%s)'):format(spec.column, spec.table, spec.column, marks),
            candidates) or {}

        if #matches > 0 then
            local params = { license2 }
            for _, c in ipairs(candidates) do params[#params + 1] = c end

            local affected = MySQL.update.await(
                ('UPDATE `%s` SET `%s` = ? WHERE `%s` IN (%s)'):format(spec.table, spec.column, spec.column, marks),
                params) or 0
            total = total + affected

            ensureLogTable()
            for _, m in ipairs(matches) do
                MySQL.insert.await(
                    'INSERT INTO qbx_migrate_identity_log (license2, old_value, table_name, column_name, `rows`, player_name) VALUES (?, ?, ?, ?, ?, ?)',
                    { license2, tostring(m.v), spec.table, spec.column, affected, playerName })
                if CFG.verbose then
                    print(('[qbx_migrate] identity: %s.%s `%s` -> `%s` for %s (%d rows)')
                        :format(spec.table, spec.column, tostring(m.v), license2, tostring(playerName), affected))
                end
            end
        end
    end

    return total
end

AddEventHandler('playerConnecting', function(name, _, deferrals)
    if not CFG.enabled then return end
    local src = source

    -- Hold the connection until the rows are rewritten. qbx_core's own deferral runs
    -- alongside this one; the join proceeds only when every handler has called done().
    deferrals.defer()
    Wait(0)

    local ok, err = pcall(reconcile, src, name)
    if not ok then
        -- Never block a join over this: the qbx_core `license OR license2` lookup still
        -- finds the characters. Log loudly and try again on the next connect.
        print(('[qbx_migrate] identity reconcile FAILED for %s: %s'):format(tostring(name), tostring(err)))
    end

    deferrals.done()
end)

-- =====================================================================================
-- COMMAND: qbxmigrate identity   (read-only)
-- =====================================================================================

QBXM.COMMANDS.identity = function(report)
    report:heading('Identity reconciler')

    if not CFG.enabled then
        report:warn('CONFIG.identity.enabled is false - stored identifiers will NOT be rewritten to license2 on login')
    else
        report:ok('enabled: matching rows are rewritten to `license2:` when the player connects')
    end

    local specs = resolveColumns(true)
    if #specs == 0 then
        report:warn('none of the configured identity columns exist yet (run the esx / schema steps first)')
    end

    for _, spec in ipairs(specs) do
        local total = MySQL.scalar.await(('SELECT COUNT(*) FROM `%s` WHERE `%s` IS NOT NULL AND `%s` <> \'\''):format(spec.table, spec.column, spec.column)) or 0
        local done = MySQL.scalar.await(('SELECT COUNT(*) FROM `%s` WHERE `%s` LIKE \'license2:%%\''):format(spec.table, spec.column)) or 0
        report:add('- `%s.%s`: %d rows, %d already on license2, %d pending', spec.table, spec.column, total, done, total - done)

        if total - done > 0 then
            local prefixes = MySQL.query.await(([[
                SELECT SUBSTRING_INDEX(`%s`, ':', 1) AS prefix, COUNT(*) AS n
                FROM `%s`
                WHERE `%s` IS NOT NULL AND `%s` NOT LIKE 'license2:%%'
                GROUP BY prefix ORDER BY n DESC LIMIT 10
            ]]):format(spec.column, spec.table, spec.column, spec.column)) or {}
            for _, p in ipairs(prefixes) do
                local prefix = tostring(p.prefix)
                local label = prefix
                if #prefix > 12 then label = 'bare value (no type prefix)' end
                report:row('    - `%s`: %d rows', label, tonumber(p.n) or 0)
            end
        end
    end

    if tableExists('qbx_migrate_identity_log') then
        local n = MySQL.scalar.await('SELECT COUNT(*) FROM qbx_migrate_identity_log') or 0
        local players = MySQL.scalar.await('SELECT COUNT(DISTINCT license2) FROM qbx_migrate_identity_log') or 0
        report:add('- rewritten so far: %d row groups across %d players (see `qbx_migrate_identity_log`)', n, players)
    else
        report:add('- nothing rewritten yet (no player with a legacy identifier has connected)')
    end

    report:add('')
    report:add('Pending rows are normal: each player is rewritten the first time they connect. Rows that never get rewritten belong to players who never came back.')
end
