--[[
    qbx_migrate - QBCore -> Qbox (qbx_core + ox stack) database migrator.

    Console usage (server console or ACE `command.qbxmigrate`):
        qbxmigrate help
        qbxmigrate check          -- read-only pre-flight audit, writes report, changes NOTHING
        qbxmigrate backup         -- snapshot every table this tool can touch
        qbxmigrate schema         -- add qbx/ox columns + tables (additive only)
        qbxmigrate items          -- generate ox_inventory/data/items.lua from qb-core
        qbxmigrate jobs           -- generate qbx_core/shared/{jobs,gangs}.lua from qb-core
        qbxmigrate inventory      -- convert qb-inventory data to ox_inventory format
        qbxmigrate phone          -- backfill players.phone_number from charinfo
        qbxmigrate metadata       -- add missing qbx metadata defaults (additive only)
        qbxmigrate all            -- backup + schema + items + jobs + inventory + phone + metadata
        qbxmigrate restore <stamp>-- restore tables from a backup folder name

    Every write step is DRY RUN unless you append `apply`:
        qbxmigrate inventory apply

    Reports land in  <resource>/output/  and backups in  <resource>/backups/
]]

local RES = GetCurrentResourceName()

-- =====================================================================================
-- CONFIG
-- =====================================================================================

local CONFIG = {
    batchSize = 250,

    -- QBCore stores cash/bank in players.money. ox_inventory re-creates the money item
    -- from that on login, so leftover money/cash items in the inventory JSON would
    -- duplicate funds. They are stripped and every removal is logged in the report.
    stripAccountItems = true,
    accountItems = { money = true, cash = true, black_money = true, markedbills = false },

    -- ---------------------------------------------------------------------------------
    -- SOURCE INVENTORY LAYOUT
    -- Run `qbxmigrate inspect` first: it reports which of these your server actually
    -- uses and prints a real sample row from each. Then adjust here if needed.
    --
    -- Layout A (legacy qb-inventory, older ps-inventory):
    --     stashitems(stash, items) / trunkitems(plate, items) / gloveboxitems(plate, items)
    -- Layout B (modern qb-inventory, qs-inventory / Quasar, ps-inventory):
    --     inventories(identifier, items) where identifier is 'stash-x', 'trunk-PLATE',
    --     'glovebox-PLATE', or a bare citizenid for a player inventory.
    -- Both layouts are handled, and both can be present at once.
    -- ---------------------------------------------------------------------------------
    qbStashTable = 'stashitems',
    qbTrunkTable = 'trunkitems',
    qbGloveTable = 'gloveboxitems',

    unifiedTable = 'inventories',
    unifiedIdColumn = 'identifier',
    unifiedItemsColumn = 'items',

    -- identifier prefixes that route to a vehicle instead of a stash
    trunkPrefixes = { 'trunk-', 'trunk_', 'bigtrunk-', 'big_trunk-' },
    glovePrefixes = { 'glovebox-', 'glovebox_', 'glove-' },

    -- identifier prefixes that are thrown away (ground drops do not persist in ox)
    skipPrefixes = { 'drop-', 'drop_' },

    -- Leading text stripped when turning an identifier into an ox_inventory stash name.
    -- Every rename is logged so you can see exactly what became what.
    stashPrefixStrip = { 'stash-', 'stash_', 'otherstash-', 'otherstash_' },

    -- Metadata keys qbx_core expects to exist. Only ADDED when missing, never overwritten.
    metadataDefaults = {
        hunger = 100,
        thirst = 100,
        stress = 0,
        isdead = false,
        inlaststand = false,
        armor = 0,
        ishandcuffed = false,
        tracker = false,
        injail = 0,
        jailitems = {},
        status = {},
        phone = {},
        fitbit = {},
        commandbinds = {},
        bloodtype = 'A+',
        dealerrep = 0,
        craftingrep = 0,
        attachmentcraftingrep = 0,
        jobrep = { tow = 0, trucker = 0, taxi = 0, hotdog = 0 },
        callsign = 'NO CALLSIGN',
        criminalrecord = { hasRecord = false },
        licences = { driver = true, business = false, weapon = false },
        inside = { apartment = {} },
        phonedata = { InstalledApps = {} },
        -- currentapartment / fingerprint / walletid are intentionally absent:
        -- qbx_core generates them, and a null default would look like real data.
    },

    -- ---------------------------------------------------------------------------------
    -- IDENTITY RECONCILER  (server/identity.lua)
    -- Qbox keys players by `license2:`. QBCore stored `license:`, ESX stored a bare
    -- license hash, `charN:hash`, or steam/fivem/discord. license2 cannot be derived
    -- offline, so on every connect the reconciler looks the joining player's rows up by
    -- ANY of their identifiers and rewrites the stored value to license2, before
    -- qbx_core loads their characters. Runs once per row; a no-op afterwards.
    -- ---------------------------------------------------------------------------------
    identity = {
        enabled = true,
        -- Every (table, column) that stores a Rockstar/steam identifier and should be
        -- moved to license2. Missing tables/columns are skipped silently.
        columns = {
            { table = 'players',         column = 'license' },
            { table = 'bans',            column = 'license' },
            { table = 'player_vehicles', column = 'license' },
        },
        -- Print one console line per rewritten row.
        verbose = true,
    },

    -- ---------------------------------------------------------------------------------
    -- ESX SOURCE  (server/esx.lua)  -  `qbxmigrate esx [apply]`
    -- ---------------------------------------------------------------------------------
    esx = {
        -- ESX's `users` table collides with the `users` table qbx_core creates on
        -- start (userId / license / license2). Applying the ESX step RENAMES ESX's
        -- users table to this name first; nothing is dropped.
        usersTable = 'esx_users',

        -- What ESX's Config.Identifier was. 'auto' inspects the stored value:
        -- 40 hex chars = license, 15 digits starting 1100 = steam, 17+ digits = discord,
        -- short digits = fivem. Set it explicitly if `qbxmigrate esx` reports guesses.
        identifierType = 'auto',
        -- esx_multicharacter Config.Prefix
        charPrefix = 'char',

        -- esx_identity Config.DateFormat. 'DMY' for DD/MM/YYYY, 'MDY' for MM/DD/YYYY.
        dateFormat = 'DMY',

        -- Default nationality written into charinfo (ESX has no such field).
        nationality = 'USA',

        -- ESX inventory weights are in whole units where Config.MaxWeight ~= 24.
        -- ox_inventory weights are grams; the ox ESX bridge multiplies by 1000.
        itemWeightMultiplier = 1000,

        -- Extra model names for hash -> spawn name resolution of owned_vehicles.
        -- Base-game names come from data/vehicle_models.lua, qbx_core/shared/vehicles.lua
        -- and qb-core/shared/vehicles.lua are read too when present on disk.
        vehicleModels = {},

        -- owned_vehicles rows whose owner is not a known ESX identifier (job / society
        -- vehicles). true = insert with citizenid NULL, false = skip and list them.
        keepOrphanVehicles = false,

        -- Map ESX weapon component names to ox_inventory attachment items. Anything
        -- not listed (or not defined by ox_inventory) is dropped and counted.
        componentMap = {
            flashlight     = 'at_flashlight',
            suppressor     = 'at_suppressor',
            grip           = 'at_grip',
            scope          = 'at_scope',
            scope_small    = 'at_scope_small',
            scope_medium   = 'at_scope_medium',
            scope_large    = 'at_scope_large',
            compensator    = 'at_compensator',
            luxury_finish  = 'at_skin_luxe',
            -- clip_extended is resolved per weapon class (pistol / smg / rifle / shotgun)
        },
    },
}

-- =====================================================================================
-- REPORT / LOGGING
-- =====================================================================================

local WARN_CAP = 200 -- per bucket, so a broken 5000-player table cannot spam the console into oblivion

local Report = {}
Report.__index = Report

local function newReport(title)
    return setmetatable({ title = title, lines = {}, warnings = 0, errors = 0, capped = {} }, Report)
end

function Report:add(fmt, ...)
    local line = select('#', ...) > 0 and (fmt):format(...) or fmt
    self.lines[#self.lines + 1] = line
    print(('[qbx_migrate] %s'):format(line:gsub('^%s*[%-*#]+%s*', '')))
end

--- Appends to the report without echoing to console. For long tables.
function Report:row(fmt, ...)
    self.lines[#self.lines + 1] = select('#', ...) > 0 and (fmt):format(...) or fmt
end

function Report:heading(text)
    self.lines[#self.lines + 1] = ''
    self.lines[#self.lines + 1] = '## ' .. text
    self.lines[#self.lines + 1] = ''
    print(('[qbx_migrate] === %s ==='):format(text))
end

function Report:warn(fmt, ...)
    self.warnings = self.warnings + 1
    self:add('- **WARN** ' .. (select('#', ...) > 0 and fmt:format(...) or fmt))
end

--- Warning that stops flooding the console after WARN_CAP hits in the same bucket.
--- The full detail still lands in the report file.
function Report:warnCapped(bucket, fmt, ...)
    local n = (self.capped[bucket] or 0) + 1
    self.capped[bucket] = n
    self.warnings = self.warnings + 1
    local text = '- **WARN** ' .. (select('#', ...) > 0 and fmt:format(...) or fmt)
    if n <= WARN_CAP then
        self:add(text)
    else
        self:row(text)
        if n == WARN_CAP + 1 then
            print(('[qbx_migrate] (further `%s` warnings suppressed on console - see the report file)'):format(bucket))
        end
    end
end

function Report:err(fmt, ...)
    self.errors = self.errors + 1
    self:add('- **ERROR** ' .. (select('#', ...) > 0 and fmt:format(...) or fmt))
end

function Report:ok(fmt, ...)
    self:add('- OK ' .. (select('#', ...) > 0 and fmt:format(...) or fmt))
end

function Report:save(name)
    local body = ('# %s\n\nGenerated: %s\nWarnings: %d  Errors: %d\n\n%s\n')
        :format(self.title, os.date('%Y-%m-%d %H:%M:%S'), self.warnings, self.errors,
            table.concat(self.lines, '\n'))
    local file = ('output/%s_%s.md'):format(os.date('%Y%m%d_%H%M%S'), name)
    SaveResourceFile(RES, file, body, -1)
    print(('[qbx_migrate] report written -> %s/%s'):format(RES, file))
    return file
end

-- =====================================================================================
-- DB HELPERS
-- =====================================================================================

local function tableExists(tbl)
    return (MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
    ]], { tbl }) or 0) > 0
end

local function columnExists(tbl, col)
    return (MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
    ]], { tbl, col }) or 0) > 0
end

local function columnCollation(tbl, col)
    return MySQL.scalar.await([[
        SELECT COLLATION_NAME FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
    ]], { tbl, col })
end

--- Builds a MODIFY COLUMN that changes only the collation, keeping the column's
--- existing type and nullability. Hardcoding `varchar(50)` here would silently
--- truncate any server that widened the column.
--- Returns nil when the column cannot be described.
local function buildCollationAlter(tbl, col)
    local info = MySQL.single.await([[
        SELECT COLUMN_TYPE, IS_NULLABLE
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?
    ]], { tbl, col })

    if not info or not info.COLUMN_TYPE then return nil end

    local nullable = info.IS_NULLABLE == 'YES' and 'NULL' or 'NOT NULL'

    return ('ALTER TABLE `%s` MODIFY COLUMN `%s` %s CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci %s')
        :format(tbl, col, info.COLUMN_TYPE, nullable)
end

local function rowCount(tbl)
    if not tableExists(tbl) then return nil end
    return MySQL.scalar.await(('SELECT COUNT(*) FROM `%s`'):format(tbl)) or 0
end

local function ensureMigrationsTable()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `qbx_migrations` (
            `id` varchar(64) NOT NULL,
            `ran_at` timestamp NOT NULL DEFAULT current_timestamp(),
            `rows_affected` int(11) NOT NULL DEFAULT 0,
            `notes` text DEFAULT NULL,
            PRIMARY KEY (`id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
end

local function migrationRan(id)
    return MySQL.scalar.await('SELECT ran_at FROM qbx_migrations WHERE id = ?', { id })
end

local function markMigration(id, rows, notes)
    -- A nil in a positional parameter list truncates the list before it reaches
    -- oxmysql, so the optional column is fed '' and NULLIF'd server-side.
    MySQL.query.await([[
        INSERT INTO qbx_migrations (id, rows_affected, notes) VALUES (?, ?, NULLIF(?, ''))
        ON DUPLICATE KEY UPDATE rows_affected = VALUES(rows_affected), notes = VALUES(notes), ran_at = current_timestamp()
    ]], { id, rows or 0, notes or '' })
end

-- =====================================================================================
-- JSON HELPERS
-- =====================================================================================

local function decodeMaybe(raw)
    if raw == nil then return nil end
    if type(raw) == 'table' then return raw end
    if type(raw) ~= 'string' or raw == '' or raw == 'null' then return nil end
    local ok, decoded = pcall(json.decode, raw)
    if not ok then return nil, decoded end
    return decoded
end

--- json.encode of an empty Lua table yields `{}`; ox_inventory wants `[]` for item lists.
local function encodeArray(list)
    if #list == 0 then return '[]' end
    return json.encode(list)
end

-- =====================================================================================
-- BACKUP / RESTORE
-- =====================================================================================

local BACKUP_SPEC = {
    { table = 'players',         key = 'citizenid', columns = { 'citizenid', 'inventory', 'job', 'gang', 'metadata', 'charinfo', 'money', 'phone_number' } },
    { table = 'player_vehicles', key = 'id',        columns = { 'id', 'plate', 'trunk', 'glovebox', 'mods' } },
    -- ox_inventory rows are CREATED by the migration, so an UPDATE-by-key restore would
    -- leave the new stashes behind. This table is wiped and re-inserted from the snapshot.
    { table = 'ox_inventory',    key = 'name',      columns = { 'owner', 'name', 'data' }, mode = 'replace' },
    { table = CONFIG.qbStashTable, key = 'stash',   columns = { 'stash', 'items' } },
    { table = CONFIG.qbTrunkTable, key = 'plate',   columns = { 'plate', 'items' } },
    { table = CONFIG.qbGloveTable, key = 'plate',   columns = { 'plate', 'items' } },
    -- Source table for modern qb-inventory / qs-inventory (Quasar) / ps-inventory.
    -- Read-only during migration, but snapshotted so a rollback has the originals.
    { table = CONFIG.unifiedTable, key = CONFIG.unifiedIdColumn,
      columns = { CONFIG.unifiedIdColumn, CONFIG.unifiedItemsColumn } },
    -- ESX sources. Read-only during migration (the ESX step only ever INSERTs into the
    -- qbx tables), snapshotted whole so a rollback has the originals. `users` is listed
    -- twice because the ESX step renames it to CONFIG.esx.usersTable.
    { table = 'users',                 key = 'identifier', all = true, esx = true },
    { table = CONFIG.esx.usersTable,   key = 'identifier', all = true, esx = true },
    { table = 'owned_vehicles',        key = 'plate',      all = true, esx = true },
    { table = 'user_licenses',         key = 'id',         all = true, esx = true },
    { table = 'addon_inventory_items', key = 'id',         all = true, esx = true },
    { table = 'addon_account_data',    key = 'id',         all = true, esx = true },
    { table = 'datastore_data',        key = 'id',         all = true, esx = true },
}

local function doBackup(report)
    local stamp = os.date('%Y%m%d_%H%M%S')
    -- Two apply steps inside one second must not overwrite each other's snapshot.
    local base, n = stamp, 1
    while LoadResourceFile(RES, ('backups/%s/manifest.json'):format(stamp)) do
        n = n + 1
        stamp = ('%s_%d'):format(base, n)
    end
    local manifest = { stamp = stamp, tables = {} }

    report:heading('Backup ' .. stamp)

    for _, spec in ipairs(BACKUP_SPEC) do
        if not tableExists(spec.table) then
            report:add('- skip `%s` (table not present)', spec.table)
        elseif spec.esx and not (columnExists(spec.table, spec.key)) then
            -- `users` exists but is qbx_core's registry (userId/license2), not ESX's.
            report:add('- skip `%s` (not an ESX table)', spec.table)
        else
            local cols = {}
            if spec.all then
                cols[1] = '*'
            else
                for _, c in ipairs(spec.columns) do
                    if columnExists(spec.table, c) then cols[#cols + 1] = ('`%s`'):format(c) end
                end
            end
            if #cols == 0 then
                report:add('- skip `%s` (no matching columns)', spec.table)
            else
                local rows = MySQL.query.await(('SELECT %s FROM `%s`'):format(table.concat(cols, ', '), spec.table)) or {}
                local file = ('backups/%s/%s.json'):format(stamp, spec.table)
                SaveResourceFile(RES, file, json.encode(rows), -1)
                manifest.tables[#manifest.tables + 1] = {
                    name = spec.table, key = spec.key, rows = #rows, file = file,
                    mode = spec.mode or 'update',
                }
                report:ok('backed up `%s` (%d rows) -> %s', spec.table, #rows, file)
            end
        end
    end

    SaveResourceFile(RES, ('backups/%s/manifest.json'):format(stamp), json.encode(manifest), -1)
    report:add('')
    report:add('Restore with: `qbxmigrate restore %s apply`', stamp)
    return stamp
end

local function doRestore(report, stamp, apply)
    local raw = LoadResourceFile(RES, ('backups/%s/manifest.json'):format(stamp))
    if not raw then
        report:err('no backup manifest found for stamp `%s`', tostring(stamp))
        return
    end
    local manifest = decodeMaybe(raw)
    if not manifest then
        report:err('backup manifest for `%s` is unreadable', stamp)
        return
    end

    report:heading('Restore ' .. stamp .. (apply and ' (APPLY)' or ' (DRY RUN)'))

    for _, entry in ipairs(manifest.tables) do
        local body = LoadResourceFile(RES, entry.file)
        local rows = body and decodeMaybe(body)
        if not rows then
            report:err('cannot read backup file %s', entry.file)
            goto continue
        end

        local mode = entry.mode or 'update'

        -- The table may have been renamed/replaced since the snapshot (ESX `users`
        -- becomes qbx_core's `users`). Never UPDATE a table whose key column is gone.
        if tableExists(entry.name) and not columnExists(entry.name, entry.key) then
            report:warn('`%s` no longer has a `%s` column - skipped (restore the ESX side with `qbxmigrate esx rollback apply`)', entry.name, entry.key)
            goto continue
        end

        if not apply then
            if mode == 'replace' then
                report:add('- would WIPE `%s` and re-insert %d snapshot rows', entry.name, #rows)
            else
                report:add('- would restore %d rows into `%s` (key `%s`)', #rows, entry.name, entry.key)
            end
            goto continue
        end

        if mode == 'replace' then
            if not tableExists(entry.name) then
                report:warn('`%s` no longer exists - skipped', entry.name)
                goto continue
            end
            report:warn('wiping `%s` before re-inserting the snapshot. Anything written to it after the backup is lost.', entry.name)
            MySQL.query.await(('DELETE FROM `%s`'):format(entry.name))

            local inserted = 0
            for i = 1, #rows, CONFIG.batchSize do
                local batch = {}
                for j = i, math.min(i + CONFIG.batchSize - 1, #rows) do
                    local row = rows[j]
                    local cols, marks, params = {}, {}, {}
                    for col, val in pairs(row) do
                        cols[#cols + 1] = ('`%s`'):format(col)
                        marks[#marks + 1] = '?'
                        params[#params + 1] = val
                    end
                    if #cols > 0 then
                        batch[#batch + 1] = {
                            query = ('INSERT INTO `%s` (%s) VALUES (%s)'):format(entry.name, table.concat(cols, ', '), table.concat(marks, ', ')),
                            values = params,
                        }
                    end
                end
                if #batch > 0 then
                    MySQL.transaction.await(batch)
                    inserted = inserted + #batch
                end
            end
            report:ok('re-inserted %d rows into `%s`', inserted, entry.name)
            goto continue
        end

        do
            local restored = 0
            for i = 1, #rows, CONFIG.batchSize do
                local batch = {}
                for j = i, math.min(i + CONFIG.batchSize - 1, #rows) do
                    local row = rows[j]
                    local sets, params = {}, {}
                    for col, val in pairs(row) do
                        if col ~= entry.key then
                            sets[#sets + 1] = ('`%s` = ?'):format(col)
                            params[#params + 1] = val
                        end
                    end
                    if #sets > 0 then
                        params[#params + 1] = row[entry.key]
                        batch[#batch + 1] = {
                            query = ('UPDATE `%s` SET %s WHERE `%s` = ?'):format(entry.name, table.concat(sets, ', '), entry.key),
                            values = params,
                        }
                    end
                end
                if #batch > 0 then
                    MySQL.transaction.await(batch)
                    restored = restored + #batch
                end
            end
            report:ok('restored %d rows into `%s`', restored, entry.name)
        end

        ::continue::
    end
end

-- =====================================================================================
-- STEP: SCHEMA (additive only - never drops anything)
-- =====================================================================================

local SCHEMA_STATEMENTS = {
    {
        id = 'players.last_logged_out',
        check = function() return columnExists('players', 'last_logged_out') end,
        sql = 'ALTER TABLE `players` ADD COLUMN `last_logged_out` timestamp NULL DEFAULT NULL',
        why = 'qbx_core tracks logout time',
    },
    {
        id = 'players.userId',
        check = function() return columnExists('players', 'userId') end,
        sql = 'ALTER TABLE `players` ADD COLUMN `userId` INT UNSIGNED DEFAULT NULL',
        why = 'qbx_core user id',
    },
    {
        id = 'players.phone_number',
        check = function() return columnExists('players', 'phone_number') end,
        sql = 'ALTER TABLE `players` ADD COLUMN `phone_number` VARCHAR(20) DEFAULT NULL',
        why = 'qbx_core phone number column',
    },
    {
        id = 'players.citizenid.collation',
        check = function() return columnCollation('players', 'citizenid') == 'utf8mb4_unicode_ci' end,
        -- Built at runtime so the existing column length/nullability is preserved.
        -- Hardcoding varchar(50) would silently truncate servers that widened it.
        sql = function() return buildCollationAlter('players', 'citizenid') end,
        why = 'player_groups foreign key needs matching collation',
    },
    {
        id = 'players.name.collation',
        check = function() return columnCollation('players', 'name') == 'utf8mb4_unicode_ci' end,
        sql = function() return buildCollationAlter('players', 'name') end,
        why = 'qbx_core schema parity',
    },
    {
        id = 'player_vehicles.trunk',
        check = function() return not tableExists('player_vehicles') or columnExists('player_vehicles', 'trunk') end,
        sql = 'ALTER TABLE `player_vehicles` ADD COLUMN `trunk` longtext DEFAULT NULL',
        why = 'ox_inventory stores trunk contents here',
    },
    {
        id = 'player_vehicles.glovebox',
        check = function() return not tableExists('player_vehicles') or columnExists('player_vehicles', 'glovebox') end,
        sql = 'ALTER TABLE `player_vehicles` ADD COLUMN `glovebox` longtext DEFAULT NULL',
        why = 'ox_inventory stores glovebox contents here',
    },
    {
        id = 'table.bans',
        check = function() return tableExists('bans') end,
        sql = [[CREATE TABLE IF NOT EXISTS `bans` (
            `id` int(11) NOT NULL AUTO_INCREMENT,
            `name` varchar(50) DEFAULT NULL,
            `license` varchar(50) DEFAULT NULL,
            `discord` varchar(50) DEFAULT NULL,
            `ip` varchar(50) DEFAULT NULL,
            `reason` text DEFAULT NULL,
            `expire` int(11) DEFAULT NULL,
            `bannedby` varchar(255) NOT NULL DEFAULT 'LeBanhammer',
            PRIMARY KEY (`id`), KEY `license` (`license`), KEY `discord` (`discord`), KEY `ip` (`ip`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
        why = 'qbx_core ban table',
    },
    {
        id = 'table.ox_inventory',
        check = function() return tableExists('ox_inventory') end,
        sql = [[CREATE TABLE IF NOT EXISTS `ox_inventory` (
            `owner` varchar(60) DEFAULT NULL,
            `name` varchar(100) NOT NULL,
            `data` longtext DEFAULT NULL,
            `lastupdated` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
            UNIQUE KEY `owner_name` (`owner`,`name`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
        why = 'ox_inventory stash storage',
    },
    {
        id = 'table.player_groups',
        check = function() return tableExists('player_groups') end,
        sql = [[CREATE TABLE IF NOT EXISTS `player_groups` (
            `citizenid` VARCHAR(50) NOT NULL,
            `group` VARCHAR(50) NOT NULL,
            `type` VARCHAR(50) NOT NULL,
            `grade` TINYINT(3) UNSIGNED NOT NULL,
            PRIMARY KEY (`citizenid`, `type`, `group`),
            CONSTRAINT `fk_citizenid` FOREIGN KEY (`citizenid`) REFERENCES `players` (`citizenid`) ON UPDATE CASCADE ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]],
        why = 'qbx_core multijob / multigang',
    },
}

local function stepSchema(report, apply)
    report:heading('Schema' .. (apply and ' (APPLY)' or ' (DRY RUN)'))

    if not tableExists('players') then
        report:err('`players` table does not exist. Wrong database selected in your oxmysql connection string?')
        return 0
    end

    local changed = 0
    for _, stmt in ipairs(SCHEMA_STATEMENTS) do
        local okCheck, satisfied = pcall(stmt.check)
        if not okCheck then
            report:err('%s - check failed: %s', stmt.id, tostring(satisfied))
            goto nextStatement
        end
        if satisfied then
            report:add('- already present: `%s`', stmt.id)
            goto nextStatement
        end

        do
            local sql = stmt.sql
            if type(sql) == 'function' then
                local okBuild, built = pcall(sql)
                if not okBuild or type(built) ~= 'string' then
                    report:err('`%s` could not be built: %s', stmt.id, tostring(built))
                    goto nextStatement
                end
                sql = built
            end

            if not apply then
                report:add('- WOULD RUN `%s` (%s)', stmt.id, stmt.why)
                report:row('    ```sql')
                report:row('    ' .. sql:gsub('\n%s*', ' '))
                report:row('    ```')
                changed = changed + 1
            else
                local ok, err = pcall(MySQL.query.await, sql)
                if ok then
                    report:ok('applied `%s` (%s)', stmt.id, stmt.why)
                    changed = changed + 1
                else
                    report:err('`%s` failed: %s', stmt.id, tostring(err))
                end
            end
        end

        ::nextStatement::
    end

    if apply then markMigration('schema', changed) end
    return changed
end

-- =====================================================================================
-- LUA SERIALIZER (for generated items.lua / jobs.lua / gangs.lua)
-- =====================================================================================

local function isIdentifier(s)
    return type(s) == 'string' and s:match('^[%a_][%w_]*$') ~= nil and not s:match('^%d')
end

local RESERVED = {
    ['and']=true,['break']=true,['do']=true,['else']=true,['elseif']=true,['end']=true,['false']=true,
    ['for']=true,['function']=true,['goto']=true,['if']=true,['in']=true,['local']=true,['nil']=true,
    ['not']=true,['or']=true,['repeat']=true,['return']=true,['then']=true,['true']=true,['until']=true,['while']=true,
}

local function luaKey(k)
    if type(k) == 'number' then return ('[%s]'):format(tostring(k)) end
    if isIdentifier(k) and not RESERVED[k] then return k end
    return ('[%q]'):format(tostring(k))
end

--- True only when the table's keys are exactly 1..n.
--- `#t` is NOT enough: job grades start at [0], and #{[0]=a,[1]=b,[2]=c} == 2,
--- which would silently drop grade 0 if we serialized it as an array.
local function isSequence(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k % 1 ~= 0 or k < 1 then return false end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return n > 0
end

local serialize
function serialize(value, indent)
    indent = indent or 1
    local t = type(value)
    if t == 'string' then return ('%q'):format(value) end
    if t == 'number' or t == 'boolean' then return tostring(value) end
    if t ~= 'table' then return 'nil' end

    local pad = string.rep('    ', indent)
    local padEnd = string.rep('    ', indent - 1)
    local parts = {}

    if isSequence(value) then
        for i = 1, #value do
            parts[#parts + 1] = pad .. serialize(value[i], indent + 1)
        end
    else
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            local ta, tb = type(a), type(b)
            if ta == 'number' and tb == 'number' then return a < b end
            if ta ~= tb then return ta == 'number' end
            return tostring(a) < tostring(b)
        end)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = ('%s%s = %s'):format(pad, luaKey(k), serialize(value[k], indent + 1))
        end
    end

    if #parts == 0 then return '{}' end
    return '{\n' .. table.concat(parts, ',\n') .. '\n' .. padEnd .. '}'
end

-- =====================================================================================
-- READ qb-core SHARED FILES
-- =====================================================================================

--- Loads a qb-core shared file in a sandbox and returns the populated shared table.
local function loadQbShared(path)
    local raw = LoadResourceFile('qb-core', path)
    if not raw then return nil, ('qb-core/%s not readable (is qb-core still in your resources folder?)'):format(path) end

    local shared = {}
    local env = setmetatable({
        QBShared = shared,
        QBCore = { Shared = shared },
    }, { __index = _G })

    local chunk, loadErr = load(raw, '@qb-core/' .. path, 't', env)
    if not chunk then return nil, loadErr end

    local ok, ret = pcall(chunk)
    if not ok then return nil, ret end

    if type(ret) == 'table' then
        for k, v in pairs(ret) do
            if shared[k] == nil then shared[k] = v end
        end
        -- Newer qb-core files `return QBShared.Items` style; also accept a bare table.
        if next(shared) == nil then return ret end
    end
    return shared
end

-- =====================================================================================
-- STEP: ITEMS  (qb-core/shared/items.lua -> ox_inventory/data/items.lua)
-- =====================================================================================

local function getOxItems()
    local ok, items = pcall(function() return exports.ox_inventory:Items() end)
    if ok and type(items) == 'table' then return items end
    return nil
end

local function stepItems(report, apply)
    report:heading('Items' .. (apply and ' (WRITE FILE)' or ' (DRY RUN)'))

    local shared, err = loadQbShared('shared/items.lua')
    if not shared then
        -- No qb-core on disk: an ESX server keeps its items in the `items` table.
        if QBXM.HOOKS.esxItems and QBXM.HOOKS.esxDetected and QBXM.HOOKS.esxDetected() then
            return QBXM.HOOKS.esxItems(report, apply)
        end
        report:err('cannot read qb-core items: %s', tostring(err))
        return 0
    end

    local qbItems = shared.Items or shared.items
    if type(qbItems) ~= 'table' then
        report:err('qb-core/shared/items.lua produced no Items table')
        return 0
    end

    local oxItems = getOxItems()
    if not oxItems then
        report:warn('ox_inventory is not running - cannot skip items it already defines. Generating ALL items; review before merging.')
    end

    local out, generated, skipped = {}, 0, 0
    for name, item in pairs(qbItems) do
        if type(item) == 'table' then
            local key = tostring(name):lower()
            if oxItems and oxItems[key] then
                skipped = skipped + 1
            else
                local entry = {
                    label = tostring(item.label or key),
                    weight = tonumber(item.weight) or 0,
                    stack = item.unique ~= true,
                    close = item.shouldClose ~= false,
                }
                if item.description and item.description ~= '' then
                    entry.description = tostring(item.description)
                end
                if item.image and item.image ~= '' then
                    entry.client = { image = tostring(item.image) }
                end
                out[key] = entry
                generated = generated + 1
            end
        end
    end

    local keys = {}
    for k in pairs(out) do keys[#keys + 1] = k end
    table.sort(keys)

    local buf = {
        '-- Generated by qbx_migrate from qb-core/shared/items.lua',
        '-- Merge these entries into ox_inventory/data/items.lua (they are NOT already defined by ox_inventory).',
        '-- Copy item images from qb-inventory/html/images -> ox_inventory/web/images',
        '',
        'return {',
    }
    for _, k in ipairs(keys) do
        buf[#buf + 1] = ('    [%q] = %s,'):format(k, serialize(out[k], 2))
    end
    buf[#buf + 1] = '}'
    buf[#buf + 1] = ''

    report:add('- %d qb items found, %d already defined by ox_inventory, %d to add', generated + skipped, skipped, generated)

    if apply then
        SaveResourceFile(RES, 'output/items.lua', table.concat(buf, '\n'), -1)
        report:ok('wrote output/items.lua (%d items)', generated)
        markMigration('items', generated)
    else
        report:add('- dry run: append `apply` to write output/items.lua')
    end

    return generated
end

-- =====================================================================================
-- STEP: JOBS / GANGS  (qb-core/shared -> qbx_core/shared)
-- =====================================================================================

local function convertGrades(qbGrades, report, groupName)
    local grades = {}
    if type(qbGrades) ~= 'table' then return grades end

    for rawLevel, grade in pairs(qbGrades) do
        local level = tonumber(rawLevel)
        if not level then
            report:warn('%s: grade key `%s` is not numeric - skipped', groupName, tostring(rawLevel))
        elseif type(grade) ~= 'table' then
            report:warn('%s: grade %s is not a table - skipped', groupName, tostring(rawLevel))
        else
            local entry = { name = tostring(grade.name or ('Grade ' .. level)) }
            local pay = tonumber(grade.payment or grade.salary)
            if pay then entry.payment = pay end
            if grade.isboss == true then
                entry.isboss = true
                entry.bankAuth = true
            end
            grades[level] = entry
        end
    end

    if next(grades) == nil then
        grades[0] = { name = 'Grade 0', payment = 0 }
        report:warn('%s: no valid grades found, inserted a placeholder grade 0', groupName)
    end
    return grades
end

local function stepJobs(report, apply)
    report:heading('Jobs & Gangs' .. (apply and ' (WRITE FILES)' or ' (DRY RUN)'))

    local generated = 0

    -- ESX keeps jobs in the `jobs` / `job_grades` tables, not in a shared file.
    if not LoadResourceFile('qb-core', 'shared/jobs.lua')
        and QBXM.HOOKS.esxJobs and QBXM.HOOKS.esxDetected and QBXM.HOOKS.esxDetected() then
        return QBXM.HOOKS.esxJobs(report, apply)
    end

    local sources = {
        { path = 'shared/jobs.lua',  field = 'Jobs',  outFile = 'output/jobs.lua',  header = 'qbx_core/shared/jobs.lua' },
        { path = 'shared/gangs.lua', field = 'Gangs', outFile = 'output/gangs.lua', header = 'qbx_core/shared/gangs.lua' },
    }

    for _, src in ipairs(sources) do
        local shared, err = loadQbShared(src.path)
        if not shared then
            report:warn('skip %s: %s', src.path, tostring(err))
            goto continue
        end

        local data = shared[src.field]
        if type(data) ~= 'table' then
            report:warn('skip %s: no %s table found', src.path, src.field)
            goto continue
        end

        local out = {}
        for name, def in pairs(data) do
            if type(def) == 'table' then
                local key = tostring(name):lower()
                local entry = {
                    label = tostring(def.label or key),
                    grades = convertGrades(def.grades, report, key),
                }
                if def.type then entry.type = tostring(def.type) end
                if src.field == 'Jobs' then
                    entry.defaultDuty = def.defaultDuty ~= false
                    entry.offDutyPay = def.offDutyPay == true
                end
                out[key] = entry
            end
        end

        local keys = {}
        for k in pairs(out) do keys[#keys + 1] = k end
        table.sort(keys)

        local buf = {
            ('-- Generated by qbx_migrate. Replace %s with this file.'):format(src.header),
            '-- Grade keys are numbers (qbx_core requirement), not strings.',
            '',
            'return {',
        }
        for _, k in ipairs(keys) do
            buf[#buf + 1] = ('    [%q] = %s,'):format(k, serialize(out[k], 2))
        end
        buf[#buf + 1] = '}'
        buf[#buf + 1] = ''

        report:add('- %s: converted %d entries', src.field, #keys)
        generated = generated + #keys

        if apply then
            SaveResourceFile(RES, src.outFile, table.concat(buf, '\n'), -1)
            report:ok('wrote %s', src.outFile)
        end

        ::continue::
    end

    if apply then
        markMigration('jobs', generated)
        report:add('')
        report:add('After copying these into qbx_core/shared/, restart and run `convertjobs` in the server console to populate `player_groups`.')
    else
        report:add('- dry run: append `apply` to write output/jobs.lua and output/gangs.lua')
    end

    return generated
end

-- =====================================================================================
-- STEP: INVENTORY  (qb-inventory format -> ox_inventory format)
-- =====================================================================================

-- qb / qs (Quasar) `info` key -> ox_inventory `metadata` key.
-- Anything not listed is copied across verbatim, so custom script data survives.
local INFO_TO_METADATA = {
    serie = 'serial',
    serial = 'serial',
    attachments = 'components',
    attachment = 'components',   -- Quasar singular spelling
    components = 'components',
    registered = 'registered',
}

-- Keys that mean "percentage condition" in qb/qs but mean something else in ox.
-- `durability` is a RESERVED ox key: on a weapon it is a 0-100 percentage, but on any
-- item with `degrade` set it is a unix expiry timestamp. Handing ox a value of 88 for a
-- burger means "expired in 1970", and ox bins it on load. So on non-weapons the value is
-- preserved under a non-reserved key instead of being passed through.
local CONDITION_KEYS = { quality = true, durability = true }
local NON_WEAPON_CONDITION_KEY = 'condition'

local function isWeapon(name)
    return name:sub(1, 7) == 'weapon_'
end

local InvStats

local function resetStats()
    InvStats = {
        itemsConverted = 0,
        itemsUnknown = {},      -- [name] = count
        itemsDropped = 0,
        accountItemsStripped = 0,
        slotsReassigned = 0,
        durabilityRenamed = 0,
        overweight = {},        -- list of {owner, weight}
        alreadyOx = 0,
        decodeFailures = {},
    }
end

local function startsWithAny(text, list)
    for _, prefix in ipairs(list) do
        if text:sub(1, #prefix):lower() == prefix:lower() then return prefix end
    end
    return nil
end

--- Decides what a row in the unified `inventories` table actually is.
--- Returns kind ('trunk' | 'glovebox' | 'player' | 'stash' | 'skip'), plus the key
--- for that kind (plate, citizenid or stash name).
local function classifyIdentifier(identifier, citizenIds)
    local id = tostring(identifier)

    local prefix = startsWithAny(id, CONFIG.skipPrefixes)
    if prefix then return 'skip', id end

    prefix = startsWithAny(id, CONFIG.trunkPrefixes)
    if prefix then return 'trunk', id:sub(#prefix + 1) end

    prefix = startsWithAny(id, CONFIG.glovePrefixes)
    if prefix then return 'glovebox', id:sub(#prefix + 1) end

    -- Some inventories store a player's own inventory under their citizenid.
    if citizenIds[id] then return 'player', id end

    prefix = startsWithAny(id, CONFIG.stashPrefixStrip)
    if prefix then return 'stash', id:sub(#prefix + 1) end

    return 'stash', id
end

--- Converts one qb-inventory item list into ox_inventory format.
--- Returns oxList, notes
local function convertItemList(raw, ownerLabel, oxItems, maxSlots, maxWeight, report)
    local decoded, decErr = decodeMaybe(raw)
    if decoded == nil then
        if raw ~= nil and raw ~= '' and raw ~= 'null' and raw ~= '[]' and raw ~= '{}' then
            InvStats.decodeFailures[#InvStats.decodeFailures + 1] = ownerLabel
            report:err('%s: inventory JSON is unreadable (%s) - LEFT UNTOUCHED', ownerLabel, tostring(decErr))
        end
        return nil
    end

    -- Nothing in it: leave the row exactly as it is rather than writing an empty list.
    if next(decoded) == nil then return nil end

    -- Idempotency: if it already looks like ox format, leave it alone.
    local looksOx, sawAny = true, false
    for _, v in pairs(decoded) do
        if type(v) == 'table' then
            sawAny = true
            -- `info` is the qb/qs metadata key; a slotted list carrying it is NOT ox
            -- format even when it also happens to use `count` (qs-inventory on ESX).
            if v.count == nil or v.amount ~= nil or v.info ~= nil or v.slot == nil then looksOx = false break end
        end
    end
    if sawAny and looksOx then
        InvStats.alreadyOx = InvStats.alreadyOx + 1
        return nil -- signal "no change needed"
    end

    local used, out, weight = {}, {}, 0

    -- Deterministic order so reruns produce identical output.
    local entries = {}
    for k, v in pairs(decoded) do
        if type(v) == 'table' and v.name then
            entries[#entries + 1] = { key = tonumber(k) or 0, item = v }
        end
    end
    table.sort(entries, function(a, b)
        local sa = tonumber(a.item.slot) or a.key
        local sb = tonumber(b.item.slot) or b.key
        if sa == sb then return tostring(a.item.name) < tostring(b.item.name) end
        return sa < sb
    end)

    for _, entry in ipairs(entries) do
        local item = entry.item
        local name = tostring(item.name):lower()
        local count = math.floor(tonumber(item.amount or item.count) or 1)

        if count <= 0 then
            goto nextItem
        end

        if CONFIG.stripAccountItems and CONFIG.accountItems[name] then
            InvStats.accountItemsStripped = InvStats.accountItemsStripped + 1
            report:warnCapped('account-item', '%s: stripped account item `%s` x%d (money lives in players.money, ox_inventory recreates it)', ownerLabel, name, count)
            goto nextItem
        end

        if oxItems and not oxItems[name] then
            InvStats.itemsUnknown[name] = (InvStats.itemsUnknown[name] or 0) + count
        end

        -- metadata
        local metadata = nil
        if type(item.info) == 'table' and next(item.info) ~= nil then
            metadata = {}
            for k, v in pairs(item.info) do
                local mapped = INFO_TO_METADATA[k]
                if mapped then
                    metadata[mapped] = v
                elseif CONDITION_KEYS[k] then
                    if isWeapon(name) then
                        metadata.durability = tonumber(v) or 100
                    elseif k == 'durability' then
                        metadata[NON_WEAPON_CONDITION_KEY] = v
                        InvStats.durabilityRenamed = InvStats.durabilityRenamed + 1
                    else
                        metadata[k] = v
                    end
                else
                    metadata[k] = v
                end
            end
            if next(metadata) == nil then metadata = nil end
        end
        if isWeapon(name) then
            metadata = metadata or {}
            if metadata.durability == nil then metadata.durability = 100 end
            if metadata.serial == nil then metadata.serial = ('QBX%s'):format(tostring(math.random(100000, 999999))) end
        end

        -- slot
        local slot = tonumber(item.slot) or entry.key
        if not slot or slot < 1 or slot > maxSlots or used[slot] then
            local free
            for s = 1, maxSlots do
                if not used[s] then free = s break end
            end
            if not free then
                InvStats.itemsDropped = InvStats.itemsDropped + 1
                report:warnCapped('no-slot', '%s: NO FREE SLOT for `%s` x%d - item recorded here, not migrated. Raw: `%s`',
                    ownerLabel, name, count, json.encode(item))
                goto nextItem
            end
            if slot ~= free then InvStats.slotsReassigned = InvStats.slotsReassigned + 1 end
            slot = free
        end
        used[slot] = true

        if oxItems and oxItems[name] then
            weight = weight + ((tonumber(oxItems[name].weight) or 0) * count)
        end

        out[#out + 1] = { slot = slot, name = name, count = count, metadata = metadata }
        InvStats.itemsConverted = InvStats.itemsConverted + 1

        ::nextItem::
    end

    if maxWeight and weight > maxWeight then
        InvStats.overweight[#InvStats.overweight + 1] = { owner = ownerLabel, weight = weight }
        report:warnCapped('overweight', '%s: converted weight %d exceeds ox_inventory cap %d - ox will drop the overflow on load', ownerLabel, weight, maxWeight)
    end

    table.sort(out, function(a, b) return a.slot < b.slot end)
    return out
end

local function stepInventory(report, apply)
    report:heading('Inventory' .. (apply and ' (APPLY)' or ' (DRY RUN)'))
    resetStats()

    local oxItems = getOxItems()
    if not oxItems then
        report:warn('ox_inventory is not running - unknown-item and weight checks are DISABLED. Start ox_inventory and rerun `check` before applying.')
    end

    local maxSlots = GetConvarInt('inventory:slots', 50)
    local maxWeight = GetConvarInt('inventory:weight', 30000)
    report:add('- ox_inventory limits: %d slots, %d weight', maxSlots, maxWeight)

    local totalUpdates = 0

    if not tableExists('players') then
        report:warn('`players` table missing - skipped (ESX: run `qbxmigrate esx apply` first)')
        return 0
    end

    ---------------------------------------------------------------------------
    -- 1. players.inventory
    ---------------------------------------------------------------------------
    if columnExists('players', 'inventory') then
        local rows = MySQL.query.await('SELECT citizenid, inventory FROM players') or {}
        report:add('- players: %d rows', #rows)

        local updates = {}
        for _, row in ipairs(rows) do
            local converted = convertItemList(row.inventory, 'player ' .. row.citizenid, oxItems, maxSlots, maxWeight, report)
            if converted then
                updates[#updates + 1] = { encodeArray(converted), row.citizenid }
            end
        end

        report:add('- players: %d rows need conversion, %d already ox format', #updates, InvStats.alreadyOx)
        if apply and #updates > 0 then
            for i = 1, #updates, CONFIG.batchSize do
                local batch = {}
                for j = i, math.min(i + CONFIG.batchSize - 1, #updates) do batch[#batch + 1] = updates[j] end
                MySQL.prepare.await('UPDATE players SET inventory = ? WHERE citizenid = ?', batch)
            end
            report:ok('players: converted %d inventories', #updates)
        end
        totalUpdates = totalUpdates + #updates
    else
        report:warn('`players.inventory` column missing - skipping player inventories')
    end

    ---------------------------------------------------------------------------
    -- 2. stashitems -> ox_inventory
    ---------------------------------------------------------------------------
    if tableExists(CONFIG.qbStashTable) then
        local rows = MySQL.query.await(('SELECT stash, items FROM `%s`'):format(CONFIG.qbStashTable)) or {}
        report:add('- %s: %d rows', CONFIG.qbStashTable, #rows)

        local updates = {}
        for _, row in ipairs(rows) do
            local converted = convertItemList(row.items, 'stash ' .. tostring(row.stash), oxItems, maxSlots, nil, report)
            if converted then
                -- ox_inventory looks stashes up with `owner = ''` when unowned.
                updates[#updates + 1] = { encodeArray(converted), '', tostring(row.stash) }
            end
        end

        report:add('- %s: %d stashes to write', CONFIG.qbStashTable, #updates)
        if apply and #updates > 0 then
            for i = 1, #updates, CONFIG.batchSize do
                local batch = {}
                for j = i, math.min(i + CONFIG.batchSize - 1, #updates) do batch[#batch + 1] = updates[j] end
                MySQL.prepare.await([[
                    INSERT INTO ox_inventory (data, owner, name) VALUES (?, ?, ?)
                    ON DUPLICATE KEY UPDATE data = VALUES(data)
                ]], batch)
            end
            report:ok('%s: wrote %d stashes into ox_inventory', CONFIG.qbStashTable, #updates)
        end
        totalUpdates = totalUpdates + #updates
    else
        report:add('- `%s` not present, skipping stashes', CONFIG.qbStashTable)
    end

    ---------------------------------------------------------------------------
    -- 3. trunkitems / gloveboxitems -> player_vehicles.trunk / .glovebox
    ---------------------------------------------------------------------------
    local vehicleSources = {
        { table = CONFIG.qbTrunkTable, column = 'trunk' },
        { table = CONFIG.qbGloveTable, column = 'glovebox' },
    }

    -- Plate -> player_vehicles.id, loaded once. Doing this per row would be tens of
    -- thousands of round trips on a mature server and would stall the whole tick.
    -- Plates are normalised because qb pads them to a fixed width.
    local function normalisePlate(plate)
        return (tostring(plate):gsub('%s+', ''):upper())
    end

    local plateMap = {}
    if tableExists('player_vehicles') then
        for _, veh in ipairs(MySQL.query.await('SELECT id, plate FROM player_vehicles') or {}) do
            plateMap[normalisePlate(veh.plate)] = veh.id
        end
    end

    for _, src in ipairs(vehicleSources) do
        if not tableExists(src.table) then
            report:add('- `%s` not present, skipping %s', src.table, src.column)
            goto continueVeh
        end
        if not tableExists('player_vehicles') or not columnExists('player_vehicles', src.column) then
            report:warn('`player_vehicles.%s` missing - run `qbxmigrate schema apply` first', src.column)
            goto continueVeh
        end

        do
            local rows = MySQL.query.await(('SELECT plate, items FROM `%s`'):format(src.table)) or {}
            report:add('- %s: %d rows', src.table, #rows)

            local updates, orphans = {}, {}
            for _, row in ipairs(rows) do
                local plate = tostring(row.plate)
                local vehId = plateMap[normalisePlate(plate)]
                if not vehId then
                    orphans[#orphans + 1] = plate
                else
                    local converted = convertItemList(row.items, ('%s %s'):format(src.column, plate), oxItems, maxSlots, nil, report)
                    if converted then
                        updates[#updates + 1] = { encodeArray(converted), vehId }
                    end
                end
            end

            if #orphans > 0 then
                report:warn('%s: %d plates have no row in `player_vehicles` (unowned vehicles). ox_inventory keys vehicle storage by player_vehicles.id, so these cannot be migrated. Plates: %s',
                    src.table, #orphans, table.concat(orphans, ', '))
            end

            report:add('- %s: %d vehicles to update', src.table, #updates)
            if apply and #updates > 0 then
                for i = 1, #updates, CONFIG.batchSize do
                    local batch = {}
                    for j = i, math.min(i + CONFIG.batchSize - 1, #updates) do batch[#batch + 1] = updates[j] end
                    MySQL.prepare.await(('UPDATE player_vehicles SET `%s` = ? WHERE id = ?'):format(src.column), batch)
                end
                report:ok('%s: wrote %d %s inventories', src.table, #updates, src.column)
            end
            totalUpdates = totalUpdates + #updates
        end

        ::continueVeh::
    end

    ---------------------------------------------------------------------------
    -- 4. unified `inventories` table
    --    Used by modern qb-inventory, qs-inventory (Quasar) and newer ps-inventory.
    --    One table, one row per inventory, routed by an identifier prefix.
    ---------------------------------------------------------------------------
    if tableExists(CONFIG.unifiedTable)
        and columnExists(CONFIG.unifiedTable, CONFIG.unifiedIdColumn)
        and columnExists(CONFIG.unifiedTable, CONFIG.unifiedItemsColumn) then

        local citizenIds, playerHasInventory = {}, {}
        for _, r in ipairs(MySQL.query.await(
            "SELECT citizenid, (inventory IS NOT NULL AND inventory <> '' AND inventory <> 'null' AND inventory <> '[]' AND inventory <> '{}') AS filled FROM players") or {}) do
            local cid = tostring(r.citizenid)
            citizenIds[cid] = true
            playerHasInventory[cid] = (tonumber(r.filled) or 0) == 1
        end

        local rows = MySQL.query.await(('SELECT `%s` AS ident, `%s` AS items FROM `%s`')
            :format(CONFIG.unifiedIdColumn, CONFIG.unifiedItemsColumn, CONFIG.unifiedTable)) or {}
        report:add('- `%s`: %d rows', CONFIG.unifiedTable, #rows)

        local stashUpdates, playerUpdates = {}, {}
        local vehUpdates = { trunk = {}, glovebox = {} }
        local orphanPlates, renames = {}, {}
        local skipped, conflicts = 0, 0

        for _, row in ipairs(rows) do
            local kind, key = classifyIdentifier(row.ident, citizenIds)
            local label = ('%s `%s`'):format(kind, tostring(row.ident))

            if kind == 'skip' then
                skipped = skipped + 1
                goto nextRow
            end

            do
                local cap = (kind == 'player') and maxWeight or nil
                local converted = convertItemList(row.items, label, oxItems, maxSlots, cap, report)
                if not converted then goto nextRow end

                if kind == 'trunk' or kind == 'glovebox' then
                    local vehId = plateMap[normalisePlate(key)]
                    if vehId then
                        vehUpdates[kind][#vehUpdates[kind] + 1] = { encodeArray(converted), vehId }
                    else
                        orphanPlates[#orphanPlates + 1] = tostring(row.ident)
                    end

                elseif kind == 'player' then
                    -- players.inventory was already converted in step 1. If it holds data,
                    -- it wins; this row is left alone rather than silently overwriting it.
                    if playerHasInventory[key] then
                        conflicts = conflicts + 1
                        report:warnCapped('inv-conflict',
                            'player %s has items in BOTH players.inventory and `%s` - kept players.inventory, ignored the `%s` row',
                            key, CONFIG.unifiedTable, CONFIG.unifiedTable)
                    else
                        playerUpdates[#playerUpdates + 1] = { encodeArray(converted), key }
                    end

                else
                    stashUpdates[#stashUpdates + 1] = { encodeArray(converted), '', key }
                    if key ~= tostring(row.ident) then
                        renames[#renames + 1] = { from = tostring(row.ident), to = key }
                    end
                end
            end

            ::nextRow::
        end

        report:add('- routed: %d stashes, %d player inventories, %d trunks, %d gloveboxes, %d skipped (drops), %d conflicts',
            #stashUpdates, #playerUpdates, #vehUpdates.trunk, #vehUpdates.glovebox, skipped, conflicts)

        if #orphanPlates > 0 then
            report:warn('%d trunk/glovebox rows reference a plate with no `player_vehicles` row (unowned vehicles). ox_inventory keys vehicle storage by player_vehicles.id, so these cannot be migrated.', #orphanPlates)
            report:row('')
            report:row('Unmigratable vehicle inventories: `%s`', table.concat(orphanPlates, '`, `'))
        end

        if #renames > 0 then
            report:heading('Stash name changes')
            report:add('The identifier prefix was stripped. If a script registers its stash under the OLD name, the contents will not show up. Adjust CONFIG.stashPrefixStrip or rename in the script.')
            report:row('')
            report:row('| from | to |')
            report:row('| --- | --- |')
            for _, r in ipairs(renames) do
                report:row('| `%s` | `%s` |', r.from, r.to)
            end
        end

        if apply then
            local function flush(query, list)
                for i = 1, #list, CONFIG.batchSize do
                    local batch = {}
                    for j = i, math.min(i + CONFIG.batchSize - 1, #list) do batch[#batch + 1] = list[j] end
                    MySQL.prepare.await(query, batch)
                end
            end

            if #stashUpdates > 0 then
                flush([[
                    INSERT INTO ox_inventory (data, owner, name) VALUES (?, ?, ?)
                    ON DUPLICATE KEY UPDATE data = VALUES(data)
                ]], stashUpdates)
                report:ok('wrote %d stashes into ox_inventory', #stashUpdates)
            end

            if #playerUpdates > 0 and columnExists('players', 'inventory') then
                flush('UPDATE players SET inventory = ? WHERE citizenid = ?', playerUpdates)
                report:ok('wrote %d player inventories', #playerUpdates)
            end

            for _, column in ipairs({ 'trunk', 'glovebox' }) do
                local list = vehUpdates[column]
                if #list > 0 then
                    if columnExists('player_vehicles', column) then
                        flush(('UPDATE player_vehicles SET `%s` = ? WHERE id = ?'):format(column), list)
                        report:ok('wrote %d %s inventories', #list, column)
                    else
                        report:err('`player_vehicles.%s` missing - run `qbxmigrate schema apply` first. %d rows NOT written.', column, #list)
                    end
                end
            end
        end

        totalUpdates = totalUpdates + #stashUpdates + #playerUpdates + #vehUpdates.trunk + #vehUpdates.glovebox
    else
        report:add('- `%s` not present, skipping the unified inventory layout', CONFIG.unifiedTable)
    end

    ---------------------------------------------------------------------------
    -- Summary
    ---------------------------------------------------------------------------
    report:heading('Inventory summary')
    report:add('- items converted: %d', InvStats.itemsConverted)
    report:add('- slots reassigned (collision or out of range): %d', InvStats.slotsReassigned)
    report:add('- items dropped (no free slot): %d', InvStats.itemsDropped)
    report:add('- account items stripped: %d', InvStats.accountItemsStripped)
    report:add('- non-weapon `durability` renamed to `%s` (ox reads that key as an expiry timestamp): %d',
        NON_WEAPON_CONDITION_KEY, InvStats.durabilityRenamed)
    report:add('- inventories already in ox format (untouched): %d', InvStats.alreadyOx)
    report:add('- unreadable JSON blobs (untouched): %d', #InvStats.decodeFailures)

    local unknown = {}
    for name, count in pairs(InvStats.itemsUnknown) do unknown[#unknown + 1] = { name = name, count = count } end
    table.sort(unknown, function(a, b) return a.count > b.count end)

    if #unknown > 0 then
        report:heading('Items NOT defined in ox_inventory')
        report:add('These will be silently discarded by ox_inventory on load. Add them to ox_inventory/data/items.lua (run `qbxmigrate items apply`) BEFORE applying the inventory step.')
        report:add('- %d distinct undefined item names', #unknown)
        report:row('')
        report:row('| item | total count |')
        report:row('| --- | --- |')
        for _, u in ipairs(unknown) do
            report:row('| `%s` | %d |', u.name, u.count)
        end
    end

    if apply then markMigration('inventory', totalUpdates) end
    return totalUpdates
end

-- =====================================================================================
-- STEP: PHONE NUMBER BACKFILL
-- =====================================================================================

local function stepPhone(report, apply)
    report:heading('Phone numbers' .. (apply and ' (APPLY)' or ' (DRY RUN)'))

    if not tableExists('players') then
        report:warn('`players` table missing - nothing to backfill (ESX: run `qbxmigrate esx apply` first)')
        return 0
    end
    if not columnExists('players', 'phone_number') then
        report:warn('`players.phone_number` missing - run `qbxmigrate schema apply` first')
        return 0
    end

    local rows = MySQL.query.await("SELECT citizenid, charinfo FROM players WHERE phone_number IS NULL OR phone_number = ''") or {}
    report:add('- %d players without phone_number', #rows)

    local updates, seen = {}, {}
    -- Preload existing numbers so we never create a duplicate.
    local existing = MySQL.query.await("SELECT phone_number FROM players WHERE phone_number IS NOT NULL AND phone_number <> ''") or {}
    for _, r in ipairs(existing) do seen[tostring(r.phone_number)] = true end

    for _, row in ipairs(rows) do
        local charinfo = decodeMaybe(row.charinfo)
        local phone = charinfo and charinfo.phone and tostring(charinfo.phone) or nil
        if phone and phone ~= '' and not seen[phone] then
            seen[phone] = true
            updates[#updates + 1] = { phone, row.citizenid }
        elseif phone and seen[phone] then
            report:warn('player %s: charinfo phone `%s` is already taken - left NULL, qbx_core will generate a new one', row.citizenid, phone)
        end
    end

    report:add('- %d phone numbers to backfill', #updates)
    if apply and #updates > 0 then
        for i = 1, #updates, CONFIG.batchSize do
            local batch = {}
            for j = i, math.min(i + CONFIG.batchSize - 1, #updates) do batch[#batch + 1] = updates[j] end
            MySQL.prepare.await('UPDATE players SET phone_number = ? WHERE citizenid = ?', batch)
        end
        report:ok('backfilled %d phone numbers', #updates)
        markMigration('phone', #updates)
    end

    return #updates
end

-- =====================================================================================
-- STEP: METADATA DEFAULTS (additive only)
-- =====================================================================================

local function stepMetadata(report, apply)
    report:heading('Metadata defaults' .. (apply and ' (APPLY)' or ' (DRY RUN)'))

    if not tableExists('players') then
        report:warn('`players` table missing - skipped (ESX: run `qbxmigrate esx apply` first)')
        return 0
    end

    local rows = MySQL.query.await('SELECT citizenid, metadata FROM players') or {}
    report:add('- %d players', #rows)

    local updates, addedKeys = {}, {}
    for _, row in ipairs(rows) do
        local meta = decodeMaybe(row.metadata)
        if type(meta) ~= 'table' then
            report:warn('player %s: metadata unreadable - LEFT UNTOUCHED', row.citizenid)
        else
            local dirty = false
            for key, default in pairs(CONFIG.metadataDefaults) do
                if meta[key] == nil and default ~= nil then
                    meta[key] = default
                    addedKeys[key] = (addedKeys[key] or 0) + 1
                    dirty = true
                end
            end
            if dirty then
                updates[#updates + 1] = { json.encode(meta), row.citizenid }
            end
        end
    end

    report:add('- %d players need added metadata keys', #updates)
    local keyList = {}
    for k, v in pairs(addedKeys) do keyList[#keyList + 1] = ('`%s` (%d)'):format(k, v) end
    table.sort(keyList)
    if #keyList > 0 then report:add('- keys added: %s', table.concat(keyList, ', ')) end

    if apply and #updates > 0 then
        for i = 1, #updates, CONFIG.batchSize do
            local batch = {}
            for j = i, math.min(i + CONFIG.batchSize - 1, #updates) do batch[#batch + 1] = updates[j] end
            MySQL.prepare.await('UPDATE players SET metadata = ? WHERE citizenid = ?', batch)
        end
        report:ok('updated metadata on %d players', #updates)
        markMigration('metadata', #updates)
    end

    return #updates
end

-- =====================================================================================
-- STEP: CHECK (read-only audit)
-- =====================================================================================

-- =====================================================================================
-- STEP: INSPECT (read-only schema discovery)
-- Escrowed inventories (qs-inventory / Quasar in particular) do not publish their
-- schema. Rather than guess, this reports what is actually in your database.
-- =====================================================================================

local ITEM_COLUMN_NAMES = { 'items', 'inventory', 'data', 'loadout', 'trunk', 'glovebox' }

--- Looks at a decoded item list and reports which dialect it is written in.
local function detectDialect(decoded)
    if type(decoded) ~= 'table' then return 'not a table' end
    if next(decoded) == nil then return 'empty' end

    local hasCount, hasAmount, hasInfo, hasMetadata, n = false, false, false, false, 0
    for _, v in pairs(decoded) do
        if type(v) == 'table' then
            n = n + 1
            if v.count ~= nil then hasCount = true end
            if v.amount ~= nil then hasAmount = true end
            if v.info ~= nil then hasInfo = true end
            if v.metadata ~= nil then hasMetadata = true end
        end
    end

    if n == 0 then return 'no item objects' end
    if hasAmount or hasInfo then return 'qb / qs format (amount + info) - NEEDS CONVERSION' end
    if hasCount or hasMetadata then return 'ox format (count + metadata) - already converted' end
    return 'unrecognised item shape'
end

local function stepInspect(report)
    report:heading('Database')

    local dbName = MySQL.scalar.await('SELECT DATABASE()')
    report:add('- connected to `%s`', tostring(dbName))

    local tables = MySQL.query.await([[
        SELECT TABLE_NAME AS name, TABLE_ROWS AS approxRows
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
        ORDER BY TABLE_NAME
    ]]) or {}

    report:add('- %d tables', #tables)

    report:heading('Tables holding item data')

    local found = {}

    for _, tbl in ipairs(tables) do
        local name = tostring(tbl.name)
        local cols = MySQL.query.await([[
            SELECT COLUMN_NAME AS col, COLUMN_TYPE AS coltype
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ?
            ORDER BY ORDINAL_POSITION
        ]], { name }) or {}

        local itemCols = {}
        for _, c in ipairs(cols) do
            for _, candidate in ipairs(ITEM_COLUMN_NAMES) do
                if tostring(c.col):lower() == candidate then
                    itemCols[#itemCols + 1] = tostring(c.col)
                    break
                end
            end
        end

        if #itemCols > 0 then
            local n = rowCount(name) or 0
            found[#found + 1] = { name = name, columns = itemCols, rows = n }

            report:add('')
            report:add('### `%s` - %d rows', name, n)

            local colList = {}
            for _, c in ipairs(cols) do
                colList[#colList + 1] = ('`%s` %s'):format(c.col, c.coltype)
            end
            report:row('')
            report:row('Columns: %s', table.concat(colList, ', '))

            for _, itemCol in ipairs(itemCols) do
                local sample = MySQL.single.await(
                    ('SELECT * FROM `%s` WHERE `%s` IS NOT NULL AND `%s` <> \'\' LIMIT 1')
                    :format(name, itemCol, itemCol))

                if not sample then
                    report:add('  - `%s`: no populated rows', itemCol)
                else
                    local raw = sample[itemCol]
                    local decoded = decodeMaybe(raw)
                    report:add('  - `%s`: %s', itemCol, detectDialect(decoded))

                    -- Show the identifying columns of the sample row so the routing
                    -- prefixes above can be checked against real values.
                    local idBits = {}
                    for k, v in pairs(sample) do
                        if k ~= itemCol and type(v) ~= 'table' then
                            local s = tostring(v)
                            if #s <= 60 then idBits[#idBits + 1] = ('%s=%s'):format(k, s) end
                        end
                    end
                    table.sort(idBits)
                    if #idBits > 0 then
                        report:row('    - sample row keys: `%s`', table.concat(idBits, '`, `'))
                    end

                    local text = tostring(raw)
                    if #text > 600 then text = text:sub(1, 600) .. ' ...(truncated)' end
                    report:row('    - sample `%s`:', itemCol)
                    report:row('      ```json')
                    report:row('      ' .. text)
                    report:row('      ```')
                end
            end
        end
    end

    if #found == 0 then
        report:err('no tables with an items/inventory/data column were found. Is oxmysql pointed at the right database?')
        return
    end

    report:heading('Verdict')

    local hasLegacy = tableExists(CONFIG.qbStashTable) or tableExists(CONFIG.qbTrunkTable) or tableExists(CONFIG.qbGloveTable)
    local hasUnified = tableExists(CONFIG.unifiedTable) and columnExists(CONFIG.unifiedTable, CONFIG.unifiedIdColumn)

    if hasLegacy then
        report:ok('legacy layout present: `%s` / `%s` / `%s` - handled by `qbxmigrate inventory`',
            CONFIG.qbStashTable, CONFIG.qbTrunkTable, CONFIG.qbGloveTable)
    end

    if hasUnified then
        report:ok('unified layout present: `%s`(`%s`, `%s`) - handled by `qbxmigrate inventory`',
            CONFIG.unifiedTable, CONFIG.unifiedIdColumn, CONFIG.unifiedItemsColumn)

        -- Show the real identifier prefixes so the routing config can be verified.
        local prefixes = MySQL.query.await(([[
            SELECT SUBSTRING_INDEX(`%s`, '-', 1) AS prefix, COUNT(*) AS n
            FROM `%s` GROUP BY prefix ORDER BY n DESC LIMIT 40
        ]]):format(CONFIG.unifiedIdColumn, CONFIG.unifiedTable)) or {}

        if #prefixes > 0 then
            report:add('- identifier prefixes actually in use:')
            report:row('')
            report:row('| prefix | rows | routes to |')
            report:row('| --- | --- | --- |')
            local citizenIds = {}
            for _, r in ipairs(MySQL.query.await('SELECT citizenid FROM players LIMIT 5000') or {}) do
                citizenIds[tostring(r.citizenid)] = true
            end
            for _, p in ipairs(prefixes) do
                local sampleId = MySQL.scalar.await(
                    ('SELECT `%s` FROM `%s` WHERE `%s` LIKE ? LIMIT 1')
                    :format(CONFIG.unifiedIdColumn, CONFIG.unifiedTable, CONFIG.unifiedIdColumn),
                    { tostring(p.prefix) .. '%' })
                local kind = select(1, classifyIdentifier(sampleId or p.prefix, citizenIds))
                report:row('| `%s` | %d | %s |', tostring(p.prefix), tonumber(p.n) or 0, kind)
            end
            report:add('- if any prefix routes to the wrong thing, edit CONFIG.trunkPrefixes / glovePrefixes / skipPrefixes / stashPrefixStrip at the top of server.lua')
        end
    end

    if not hasLegacy and not hasUnified then
        report:warn('neither known layout was found. Your inventory stores data somewhere else - use the table dump above and set CONFIG.unifiedTable / unifiedIdColumn / unifiedItemsColumn accordingly.')
    end

    if columnExists('players', 'inventory') then
        report:ok('`players.inventory` exists - this is the column ox_inventory reads from, so it carries over. Its CONTENTS still have to be rewritten.')
    else
        report:err('`players.inventory` is missing. ox_inventory runs `SELECT inventory FROM players WHERE citizenid = ?` - add the column before going live.')
    end
end

local function getQbxGroups()
    local jobs, gangs
    pcall(function() jobs = exports.qbx_core:GetJobs() end)
    pcall(function() gangs = exports.qbx_core:GetGangs() end)
    return jobs, gangs
end

local function stepCheck(report)
    report:heading('Environment')

    local function resState(name)
        local state = GetResourceState(name)
        if state == 'started' then report:ok('`%s` running', name)
        elseif state == 'missing' then report:warn('`%s` NOT INSTALLED', name)
        else report:warn('`%s` state: %s', name, state) end
        return state
    end

    for _, r in ipairs({ 'qbx_core', 'ox_lib', 'ox_inventory', 'ox_target', 'oxmysql' }) do resState(r) end
    for _, r in ipairs({ 'qb-core', 'qb-inventory', 'qb-target', 'qb-menu', 'qb-input' }) do
        local state = GetResourceState(r)
        if state ~= 'missing' then
            report:add('- legacy resource `%s` is present (state: %s)', r, state)
        end
    end

    if GetResourceState('qb-core') == 'started' and GetResourceState('qbx_core') == 'started' then
        report:err('qb-core AND qbx_core are both STARTED. They will fight over the same events. Stop qb-core before going live.')
    end

    report:heading('Schema')
    for _, tbl in ipairs({ 'players', 'player_vehicles', 'player_groups', 'ox_inventory', 'bans',
                           CONFIG.unifiedTable, CONFIG.qbStashTable, CONFIG.qbTrunkTable, CONFIG.qbGloveTable }) do
        local n = rowCount(tbl)
        if n == nil then report:add('- `%s`: MISSING', tbl)
        else report:add('- `%s`: %d rows', tbl, n) end
    end

    for _, stmt in ipairs(SCHEMA_STATEMENTS) do
        local ok, satisfied = pcall(stmt.check)
        if ok and not satisfied then
            report:warn('schema change pending: `%s` (%s)', stmt.id, stmt.why)
        end
    end

    local coll = columnCollation('players', 'citizenid')
    if coll and coll ~= 'utf8mb4_unicode_ci' then
        report:warn('players.citizenid collation is `%s`; qbx_core needs utf8mb4_unicode_ci for the player_groups foreign key', coll)
    end

    if tableExists('player_groups') and (rowCount('player_groups') or 0) == 0 and (rowCount('players') or 0) > 0 then
        report:warn('`player_groups` is empty. After qbx_core is installed and jobs.lua is in place, run `convertjobs` in the server console.')
    end

    if not tableExists('players') then
        if QBXM.HOOKS.esxDetected and QBXM.HOOKS.esxDetected() then
            report:add('')
            report:add('- ESX database detected (no `players` table yet). Run `qbxmigrate esx` for the ESX-specific report; the job / inventory audits below apply after `esx apply`.')
        else
            report:err('`players` table does not exist and no ESX `users` table was found. Wrong database?')
        end
        report:heading('Migrations already run')
        ensureMigrationsTable()
        for _, r in ipairs(MySQL.query.await('SELECT id, ran_at, rows_affected FROM qbx_migrations ORDER BY ran_at') or {}) do
            report:add('- `%s` at %s (%d rows)', r.id, tostring(r.ran_at), r.rows_affected or 0)
        end
        return
    end

    report:heading('Jobs & gangs in use')
    local jobs, gangs = getQbxGroups()
    if not jobs then
        report:warn('qbx_core is not running, cannot validate job names against qbx_core/shared/jobs.lua')
    end

    local function auditGroup(column, configured, label)
        local rows = MySQL.query.await(('SELECT `%s` AS groupdata, COUNT(*) AS n FROM players GROUP BY `%s`'):format(column, column)) or {}
        local tally = {}
        for _, row in ipairs(rows) do
            local data = decodeMaybe(row.groupdata)
            local name = data and data.name and tostring(data.name):lower() or '<unset>'
            tally[name] = (tally[name] or 0) + (tonumber(row.n) or 0)
        end
        local names = {}
        for k in pairs(tally) do names[#names + 1] = k end
        table.sort(names)
        for _, name in ipairs(names) do
            if configured and name ~= '<unset>' and not configured[name] then
                report:err('%s `%s` is used by %d players but is NOT defined in qbx_core. Those players will be reset to the default %s on login.', label, name, tally[name], label)
            else
                report:add('- %s `%s`: %d players', label, name, tally[name])
            end
        end
    end

    auditGroup('job', jobs, 'job')
    if columnExists('players', 'gang') then auditGroup('gang', gangs, 'gang') end

    report:heading('Inventory format')
    local sample = MySQL.query.await('SELECT citizenid, inventory FROM players WHERE inventory IS NOT NULL LIMIT 500') or {}
    local qbFormat, oxFormat, empty, broken = 0, 0, 0, 0
    for _, row in ipairs(sample) do
        local decoded = decodeMaybe(row.inventory)
        if decoded == nil then
            if row.inventory == '' or row.inventory == 'null' then empty = empty + 1 else broken = broken + 1 end
        elseif next(decoded) == nil then
            empty = empty + 1
        else
            local isOx = true
            for _, v in pairs(decoded) do
                if type(v) == 'table' and (v.amount ~= nil or v.count == nil) then isOx = false break end
            end
            if isOx then oxFormat = oxFormat + 1 else qbFormat = qbFormat + 1 end
        end
    end
    report:add('- sampled %d players: %d qb format, %d ox format, %d empty, %d unreadable', #sample, qbFormat, oxFormat, empty, broken)
    if broken > 0 then
        report:err('%d player inventories contain invalid JSON. qbx_migrate will NOT touch them; fix or clear them manually.', broken)
    end

    report:heading('Migrations already run')
    ensureMigrationsTable()
    local ran = MySQL.query.await('SELECT id, ran_at, rows_affected FROM qbx_migrations ORDER BY ran_at') or {}
    if #ran == 0 then
        report:add('- none')
    else
        for _, r in ipairs(ran) do
            report:add('- `%s` at %s (%d rows)', r.id, tostring(r.ran_at), r.rows_affected or 0)
        end
    end
end

-- =====================================================================================
-- COMMAND
-- =====================================================================================

local HELP = [[
qbx_migrate commands (server console / ACE command.qbxmigrate)

  qbxmigrate help
  qbxmigrate inspect               read-only schema discovery; run this FIRST if you are
                                   on qs-inventory / Quasar, ps-inventory, or anything
                                   that does not publish its database layout
  qbxmigrate check                 read-only audit; writes output/<stamp>_check.md
  qbxmigrate backup                snapshot every table this tool can touch
  qbxmigrate restore <stamp> apply restore from backups/<stamp>
  qbxmigrate esx [apply]           ESX users/owned_vehicles/societies -> qbx players/
                                   player_vehicles/ox_inventory (creates the qbx tables)
  qbxmigrate esx rollback [apply]  remove everything the esx step inserted, rename
                                   esx_users back to users
  qbxmigrate schema [apply]        add qbx/ox columns and tables (additive only)
  qbxmigrate items [apply]         generate output/items.lua from qb-core / ESX items
  qbxmigrate jobs [apply]          generate output/jobs.lua + output/gangs.lua
  qbxmigrate inventory [apply]     convert qb-inventory data to ox_inventory format
  qbxmigrate phone [apply]         backfill players.phone_number
  qbxmigrate metadata [apply]      add missing metadata keys (additive only)
  qbxmigrate identity              report rows still keyed by a pre-Qbox identifier
                                   (rewritten to license2 automatically on each login)
  qbxmigrate all [apply]           backup + [esx] + schema + items + jobs + inventory + phone + metadata

Without `apply` every step is a DRY RUN and writes only a report.
QBCore order: inspect -> check -> backup -> schema apply -> items apply -> jobs apply
              -> (merge generated files, restart) -> check -> inventory apply
ESX order:    inspect -> check -> backup -> esx apply -> items apply -> jobs apply
              -> (merge generated files, restart with qbx_core) -> check
]]

local STEPS = {
    schema = stepSchema,
    items = stepItems,
    jobs = stepJobs,
    inventory = stepInventory,
    phone = stepPhone,
    metadata = stepMetadata,
}

-- Extra top-level commands registered by server/esx.lua and server/identity.lua.
-- fn(report, arg2, arg3) -> nil. `report` is saved under the command name afterwards.
local COMMANDS = {}

-- Shared surface for the other server files. They load after this one (see
-- fxmanifest) and register into STEPS / COMMANDS / HOOKS.
QBXM = {
    CONFIG = CONFIG,
    STEPS = STEPS,
    COMMANDS = COMMANDS,
    HOOKS = {},                 -- esxDetected(), esxItems(report), esxJobs(report)
    newReport = newReport,
    tableExists = tableExists,
    columnExists = columnExists,
    rowCount = rowCount,
    decodeMaybe = decodeMaybe,
    encodeArray = encodeArray,
    serialize = serialize,
    convertItemList = convertItemList,
    resetInvStats = resetStats,
    invStats = function() return InvStats end,
    getOxItems = getOxItems,
    loadQbShared = loadQbShared,
    markMigration = markMigration,
    migrationRan = migrationRan,
    doBackup = doBackup,
    batchSize = CONFIG.batchSize,
}

local running = false

local function run(action, arg2, arg3)
    if running then
        print('[qbx_migrate] a migration is already running, wait for it to finish')
        return
    end
    running = true

    local ok, err = pcall(function()
        ensureMigrationsTable()

        if action == nil or action == 'help' then
            print(HELP)
            return
        end

        if action == 'inspect' then
            local report = newReport('qbx_migrate schema inspection')
            stepInspect(report)
            report:save('inspect')
            return
        end

        if action == 'check' then
            local report = newReport('qbx_migrate pre-flight check')
            stepCheck(report)
            report:save('check')
            return
        end

        if action == 'backup' then
            local report = newReport('qbx_migrate backup')
            doBackup(report)
            report:save('backup')
            return
        end

        if action == 'restore' then
            local report = newReport('qbx_migrate restore')
            doRestore(report, arg2, arg3 == 'apply')
            report:save('restore')
            return
        end

        if action == 'all' then
            local apply = arg2 == 'apply'
            local report = newReport('qbx_migrate full run' .. (apply and ' (APPLY)' or ' (DRY RUN)'))
            if not apply then stepInspect(report) end
            stepCheck(report)
            if apply then doBackup(report) end
            -- An ESX database has no `players` table yet; the ESX step creates the qbx
            -- tables and fills them, so it must run before every other write step.
            local isEsx = QBXM.HOOKS.esxDetected and QBXM.HOOKS.esxDetected()
            if isEsx and STEPS.esx then
                STEPS.esx(report, apply)
            end
            stepSchema(report, apply)
            stepItems(report, apply)
            stepJobs(report, apply)
            stepInventory(report, apply)
            stepPhone(report, apply)
            stepMetadata(report, apply)
            if COMMANDS.identity then COMMANDS.identity(report) end
            report:heading('Done')
            if not apply then
                report:add('DRY RUN - nothing was written. Review this report, then run `qbxmigrate all apply`.')
            end
            report:save('all')
            return
        end

        local command = COMMANDS[action]
        if command then
            local report = newReport('qbx_migrate ' .. action)
            command(report, arg2, arg3)
            report:save(action)
            return
        end

        local step = STEPS[action]
        if not step then
            print(('[qbx_migrate] unknown command `%s`'):format(tostring(action)))
            print(HELP)
            return
        end

        local apply = arg2 == 'apply'
        local report = newReport('qbx_migrate ' .. action .. (apply and ' (APPLY)' or ' (DRY RUN)'))
        if apply and (action == 'inventory' or action == 'esx') then doBackup(report) end
        step(report, apply)
        if not apply then
            report:add('')
            report:add('DRY RUN - nothing was written. Rerun with `qbxmigrate %s apply`.', action)
        end
        report:save(action)
    end)

    running = false
    if not ok then
        print(('[qbx_migrate] FAILED: %s'):format(tostring(err)))
    end
end

RegisterCommand('qbxmigrate', function(source, args)
    if source ~= 0 then
        -- Restricted command; ACE already gates this, but never let it run from a live player unannounced.
        print(('[qbx_migrate] invoked by player %s'):format(source))
    end
    CreateThread(function()
        run(args[1], args[2], args[3])
    end)
end, true)

CreateThread(function()
    Wait(2000)
    print('[qbx_migrate] loaded. Run `qbxmigrate help` in the server console.')
end)
