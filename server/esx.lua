--[[
    qbx_migrate :: server/esx.lua

    ESX Legacy -> Qbox (qbx_core + ox_inventory + qbx_vehicles) database conversion.

        qbxmigrate esx              dry run, report only
        qbxmigrate esx apply        backup, then convert
        qbxmigrate esx rollback     dry run of the undo
        qbxmigrate esx rollback apply

    What moves where:

        users                      -> players            (one row per character)
        users.identifier           -> players.license    (`charN:` stripped, typed `license:`/`steam:`...)
                                      players.cid        (N from `charN:`, else 1)
        users.accounts             -> players.money      (money -> cash, bank -> bank, crypto 0)
                                      black_money        -> `black_money` item in the inventory
        users.job + job_grade      -> players.job        (label/payment/isboss from jobs + job_grades)
                                      player_groups      (type 'job')
        users.firstname/lastname/
          dateofbirth/sex/height/
          phone_number             -> players.charinfo + players.phone_number
        users.inventory + loadout  -> players.inventory  (ox_inventory format; legacy {name=count}
                                      map, legacy [{name,count}] list, qs/qb slotted lists and
                                      already-ox lists are all recognised)
        users.status / is_dead /
          metadata / user_licenses -> players.metadata
        users.position             -> players.position
        users.group (admin/mod)    -> output/esx_admins.cfg   (ACE lines, not written to DB)
        owned_vehicles             -> player_vehicles     (hash -> model name, stored -> state,
                                      vehicle JSON -> mods, trunk/glovebox copied if present)
        addon_inventory_items      -> ox_inventory stashes
        datastore_data (items)     -> ox_inventory stashes
        addon_account_data         -> management_funds if that table exists, else report + JSON
        ox_inventory.owner         -> rewritten from the ESX identifier to the new citizenid

    Every insert is keyed (citizenid / plate / owner+name) and recorded in
    `qbx_migrate_esx_map` / `qbx_migrate_esx_log`, so re-running is safe and
    `esx rollback` can remove exactly what was added.

    NOT migrated, on purpose (reported instead): skins (illenium-appearance has its own
    importer), billing, phone tables, properties, and any third-party table keyed by the
    ESX identifier. The renamed `esx_users` table keeps every original column.
]]

local Q = QBXM
local CFG = Q.CONFIG.esx
local RES = GetCurrentResourceName()
local tableExists, columnExists, decodeMaybe, encodeArray = Q.tableExists, Q.columnExists, Q.decodeMaybe, Q.encodeArray

local MAP_TABLE = 'qbx_migrate_esx_map'
local LOG_TABLE = 'qbx_migrate_esx_log'

-- =====================================================================================
-- DETECTION
-- =====================================================================================

--- Name of the ESX users table, or nil. Prefers the renamed one so a re-run after
--- `apply` reads the same data. qbx_core's own `users` (userId/license2) is not ESX.
local function esxUsersTable()
    if tableExists(CFG.usersTable) and columnExists(CFG.usersTable, 'identifier') then
        return CFG.usersTable
    end
    if tableExists('users') and columnExists('users', 'identifier') and not columnExists('users', 'userId') then
        return 'users'
    end
    return nil
end

Q.HOOKS.esxDetected = function() return esxUsersTable() ~= nil end

-- =====================================================================================
-- SMALL HELPERS
-- =====================================================================================

local function escapePattern(s)
    return (tostring(s):gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0'))
end

local function trim(s)
    return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Jenkins one-at-a-time, as GTA uses it (lowercased input). Unsigned 32-bit.
local function joaat(s)
    s = tostring(s):lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = (h ~ (h >> 6)) & 0xFFFFFFFF
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = (h ~ (h >> 11)) & 0xFFFFFFFF
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end

local function toUnsigned(n)
    n = math.tointeger(n) or math.floor(tonumber(n) or 0)
    return n & 0xFFFFFFFF
end

local function toSigned(n)
    n = toUnsigned(n)
    if n >= 0x80000000 then return n - 0x100000000 end
    return n
end

local CID_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

--- qbx_core default is one uppercase letter followed by 7 alphanumerics.
local function randomCitizenId()
    local first = math.random(1, 26)
    local out = { CID_ALPHABET:sub(first, first) }
    for _ = 1, 7 do
        local i = math.random(1, #CID_ALPHABET)
        out[#out + 1] = CID_ALPHABET:sub(i, i)
    end
    return table.concat(out)
end

--- Loads a `return { ... }` Lua file from a resource in a sandbox. `env` extras are
--- merged over _G. Returns the table or nil, err.
local function loadLuaTable(resource, path, extraEnv)
    local raw = LoadResourceFile(resource, path)
    if not raw then return nil, ('%s/%s not readable'):format(resource, path) end
    local env = setmetatable(extraEnv or {}, { __index = _G })
    local chunk, err = load(raw, ('@%s/%s'):format(resource, path), 't', env)
    if not chunk then return nil, err end
    local ok, ret = pcall(chunk)
    if not ok then return nil, ret end
    return ret, nil, env
end

-- =====================================================================================
-- IDENTIFIER PARSING
-- =====================================================================================

local KNOWN_TYPES = { license = true, license2 = true, steam = true, fivem = true, discord = true, ip = true, xbl = true, live = true }

--- Turns whatever ESX wrote into users.identifier into a typed `type:value` string
--- plus the character slot. Shapes handled:
---   abc...(40 hex)        ESX Legacy, Config.Identifier = 'license', prefix stripped
---   char2:abc...          esx_multicharacter
---   license:abc...        ESX 1.1 / 1.2 (prefix kept)
---   steam:1100...  /  1100...(15 hex)  / fivem:123 / discord:1234567890123456789
--- Returns typed, cid (or nil), how ('typed' | 'guessed:<type>' | 'unknown')
local function parseIdentifier(raw)
    local s = trim(raw)
    local cid

    local slot, rest = s:match('^' .. escapePattern(CFG.charPrefix) .. '(%d+):(.+)$')
    if slot then
        cid = tonumber(slot)
        s = rest
    end

    local kind, value = s:match('^(%a+):(.+)$')
    if kind and KNOWN_TYPES[kind:lower()] then
        return kind:lower() .. ':' .. value, cid, 'typed'
    end

    local ty = CFG.identifierType
    local how = 'configured'
    if ty == 'auto' then
        how = 'guessed'
        if #s == 40 and s:match('^%x+$') then
            ty = 'license'
        elseif #s == 15 and s:match('^1100%x+$') then
            ty = 'steam'
        elseif s:match('^%d+$') and #s >= 17 then
            ty = 'discord'
        elseif s:match('^%d+$') then
            ty = 'fivem'
        elseif s:match('^%d+%.%d+%.%d+%.%d+$') then
            ty = 'ip'
        else
            return 'license:' .. s, cid, 'unknown'
        end
    end

    return ty .. ':' .. s, cid, how .. ':' .. ty
end

-- =====================================================================================
-- VEHICLE MODEL RESOLUTION  (hash -> spawn name)
-- =====================================================================================

local hashToModel

local function addModel(name)
    if type(name) ~= 'string' or name == '' then return end
    name = name:lower()
    hashToModel[joaat(name)] = name
end

local function buildModelIndex(report)
    if hashToModel then return hashToModel end
    hashToModel = {}
    local sources = {}

    local bundled = loadLuaTable(RES, 'data/vehicle_models.lua')
    if type(bundled) == 'table' then
        for _, name in ipairs(bundled) do addModel(name) end
        sources[#sources + 1] = ('data/vehicle_models.lua (%d)'):format(#bundled)
    end

    for _, name in ipairs(CFG.vehicleModels or {}) do addModel(name) end
    if #(CFG.vehicleModels or {}) > 0 then
        sources[#sources + 1] = ('CONFIG.esx.vehicleModels (%d)'):format(#CFG.vehicleModels)
    end

    -- qbx_core/shared/vehicles.lua: { adder = { model = 'adder', hash = `adder` } }
    local qbx = loadLuaTable('qbx_core', 'shared/vehicles.lua', { joaat = joaat, GetHashKey = joaat })
    if type(qbx) == 'table' then
        local n = 0
        for key, v in pairs(qbx) do
            addModel(type(v) == 'table' and v.model or key)
            n = n + 1
        end
        sources[#sources + 1] = ('qbx_core/shared/vehicles.lua (%d)'):format(n)
    end

    -- qb-core/shared/vehicles.lua: QBShared.Vehicles = { adder = { model = 'adder' } }
    local shared = {}
    local _, _, env = loadLuaTable('qb-core', 'shared/vehicles.lua', {
        QBShared = shared, QBCore = { Shared = shared }, joaat = joaat, GetHashKey = joaat,
    })
    if env and type(shared.Vehicles) == 'table' then
        local n = 0
        for key, v in pairs(shared.Vehicles) do
            addModel(type(v) == 'table' and v.model or key)
            n = n + 1
        end
        sources[#sources + 1] = ('qb-core/shared/vehicles.lua (%d)'):format(n)
    end

    -- ESX `vehicles` table (esx_vehicleshop): model column
    if tableExists('vehicles') and columnExists('vehicles', 'model') then
        local rows = MySQL.query.await('SELECT model FROM vehicles') or {}
        for _, r in ipairs(rows) do addModel(r.model) end
        sources[#sources + 1] = ('vehicles table (%d)'):format(#rows)
    end

    report:add('- vehicle model index: %s', table.concat(sources, ', '))
    return hashToModel
end

--- Returns model name (lowercase) or nil.
local function resolveModel(props)
    if type(props) ~= 'table' then return nil end
    for _, key in ipairs({ 'modelName', 'model_name', 'name', 'spawnName', 'spawncode' }) do
        if type(props[key]) == 'string' and props[key] ~= '' then return props[key]:lower() end
    end
    local model = props.model
    if type(model) == 'string' then
        if tonumber(model) then
            return hashToModel[toUnsigned(tonumber(model))]
        end
        return model:lower()
    end
    if type(model) == 'number' then
        return hashToModel[toUnsigned(model)]
    end
    return nil
end

-- =====================================================================================
-- CHARINFO / MONEY / JOB / METADATA BUILDERS
-- =====================================================================================

--- ESX dateofbirth 'DD/MM/YYYY' (or MM/DD/YYYY) -> qb 'YYYY-MM-DD'. Unknown shapes pass through.
local function convertBirthdate(dob)
    if type(dob) ~= 'string' then return nil end
    local a, b, y = dob:match('^(%d%d?)[/%-%.](%d%d?)[/%-%.](%d%d%d%d)$')
    if not a then
        local yy, mm, dd = dob:match('^(%d%d%d%d)[/%-%.](%d%d?)[/%-%.](%d%d?)$')
        if yy then return ('%s-%02d-%02d'):format(yy, tonumber(mm), tonumber(dd)) end
        return dob
    end
    local day, month
    if CFG.dateFormat == 'MDY' then month, day = a, b else day, month = a, b end
    return ('%s-%02d-%02d'):format(y, tonumber(month), tonumber(day))
end

local function buildMoney(accountsRaw)
    local accounts = decodeMaybe(accountsRaw)
    if type(accounts) ~= 'table' then accounts = {} end
    return {
        cash = math.floor(tonumber(accounts.money) or 0),
        bank = math.floor(tonumber(accounts.bank) or 0),
        crypto = 0,
    }, math.floor(tonumber(accounts.black_money) or 0)
end

--- jobs + job_grades -> { [name] = { label, type, grades = { [level] = { name, label, payment, isboss } } } }
local function loadEsxJobs(report)
    local jobs = {}
    if not tableExists('jobs') or not tableExists('job_grades') then
        report:warn('`jobs` / `job_grades` tables missing - every player will be written as unemployed grade 0')
        return jobs
    end

    local hasType = columnExists('jobs', 'type')
    for _, j in ipairs(MySQL.query.await(('SELECT name, label%s FROM jobs'):format(hasType and ', type' or '')) or {}) do
        jobs[tostring(j.name):lower()] = { label = tostring(j.label or j.name), type = j.type, grades = {} }
    end

    for _, g in ipairs(MySQL.query.await('SELECT job_name, grade, name, label, salary FROM job_grades') or {}) do
        local job = jobs[tostring(g.job_name):lower()]
        if job then
            local level = tonumber(g.grade) or 0
            job.grades[level] = {
                name = tostring(g.name or ('grade' .. level)),
                label = tostring(g.label or g.name or ('Grade ' .. level)),
                payment = tonumber(g.salary) or 0,
                isboss = tostring(g.name):lower() == 'boss',
            }
        end
    end

    return jobs
end

local function buildJob(jobName, jobGrade, esxJobs, report, label)
    local name = tostring(jobName or 'unemployed'):lower()
    local level = tonumber(jobGrade) or 0
    local def = esxJobs[name]
    local grade = def and def.grades[level]

    if not def or not grade then
        if name ~= 'unemployed' then
            report:warnCapped('esx-job', '%s: job `%s` grade %d not in job_grades - written as unemployed', label, name, level)
        end
        name, level = 'unemployed', 0
        def = esxJobs.unemployed
        grade = def and def.grades[0]
    end

    return {
        name = name,
        label = def and def.label or 'Civilian',
        payment = grade and grade.payment or 10,
        type = def and def.type or nil,
        onduty = true,
        isboss = grade and grade.isboss or false,
        grade = {
            name = grade and grade.label or 'Freelancer',
            level = level,
        },
    }
end

local DEFAULT_GANG = { name = 'none', label = 'No Gang', isboss = false, grade = { name = 'Unaffiliated', level = 0 } }

--- ESX status blob [{name='hunger', val=800000}] is 0..1,000,000; qbx metadata is 0..100.
local function buildMetadata(row, licences)
    local meta = {}

    local status = decodeMaybe(row.status)
    if type(status) == 'table' then
        for _, s in pairs(status) do
            if type(s) == 'table' and s.name and s.val ~= nil then
                local pct = math.floor((tonumber(s.val) or 0) / 10000 + 0.5)
                if s.name == 'hunger' then meta.hunger = math.max(0, math.min(100, pct))
                elseif s.name == 'thirst' then meta.thirst = math.max(0, math.min(100, pct))
                elseif s.name == 'stress' then meta.stress = math.max(0, math.min(100, pct))
                elseif s.name == 'drunk' or s.name == 'drug' then meta[s.name] = pct end
            end
        end
    end

    local esxMeta = decodeMaybe(row.metadata)
    if type(esxMeta) == 'table' then
        if tonumber(esxMeta.health) then meta.health = tonumber(esxMeta.health) end
        if tonumber(esxMeta.armor) then meta.armor = tonumber(esxMeta.armor) end
        if esxMeta.jailed then meta.injail = tonumber(esxMeta.jailTime) or 0 end
        -- Keep everything ESX-side scripts stored, under a key nothing in qbx reads.
        meta.esx = esxMeta
    end

    local dead = row.is_dead
    meta.isdead = dead == 1 or dead == true or dead == '1'

    meta.licences = { id = true, driver = false, weapon = false }
    for _, lic in ipairs(licences or {}) do
        local t = tostring(lic):lower()
        if t == 'drive' or t == 'driver' or t == 'dmv' then meta.licences.driver = true
        elseif t == 'weapon' then meta.licences.weapon = true
        else meta.licences[t] = true end
    end

    return meta
end

local function buildPosition(raw)
    local pos = decodeMaybe(raw)
    if type(pos) ~= 'table' or not tonumber(pos.x) then return nil end
    return { x = tonumber(pos.x), y = tonumber(pos.y), z = tonumber(pos.z) or 0, w = tonumber(pos.w or pos.heading) or 0 }
end

-- =====================================================================================
-- INVENTORY / LOADOUT
-- =====================================================================================

--- Extended-clip attachment differs per weapon class in ox_inventory.
local function extendedClipFor(weapon)
    if weapon:find('shotgun') or weapon:find('musket') then return 'at_clip_extended_shotgun' end
    if weapon:find('smg') or weapon:find('machinepistol') or weapon:find('microsmg') or weapon:find('combatpdw')
        or weapon:find('minismg') or weapon:find('assaultsmg') or weapon:find('gusenberg') then
        return 'at_clip_extended_smg'
    end
    if weapon:find('rifle') or weapon:find('carbine') or weapon:find('mg') or weapon:find('bullpup')
        or weapon:find('gusenberg') or weapon:find('sniper') or weapon:find('musket') then
        return 'at_clip_extended_rifle'
    end
    return 'at_clip_extended_pistol'
end

local LoadoutStats

--- ESX loadout {WEAPON_PISTOL = {ammo, components, tintIndex}} (or a list) -> qb-shaped
--- entries convertItemList understands. Component names are translated to ox
--- attachment items and dropped (counted) when ox does not define the target.
local function loadoutToEntries(raw, oxItems)
    local loadout = decodeMaybe(raw)
    if type(loadout) ~= 'table' then return {} end

    local entries = {}
    for key, weapon in pairs(loadout) do
        if type(weapon) == 'table' then
            local name = tostring(weapon.name or key):lower()
            if name:sub(1, 7) == 'weapon_' then
                local components = {}
                for _, comp in ipairs(weapon.components or {}) do
                    local c = tostring(comp):lower()
                    if c ~= 'clip_default' then
                        local mapped = CFG.componentMap[c]
                        if not mapped and c == 'clip_extended' then mapped = extendedClipFor(name) end
                        if mapped and (not oxItems or oxItems[mapped]) then
                            components[#components + 1] = mapped
                        else
                            LoadoutStats.componentsDropped[c] = (LoadoutStats.componentsDropped[c] or 0) + 1
                        end
                    end
                end
                local info = {
                    ammo = math.floor(tonumber(weapon.ammo) or 0),
                    durability = 100,
                }
                if #components > 0 then info.components = components end
                local tint = tonumber(weapon.tintIndex or weapon.tint)
                if tint and tint > 0 then info.tint = tint end
                entries[#entries + 1] = { name = name, amount = 1, info = info }
                LoadoutStats.weapons = LoadoutStats.weapons + 1
            end
        end
    end
    return entries
end

--- Appends `extra` (ox list) after `base` (ox list), re-slotting anything that would
--- collide or overflow. Items with no free slot are dropped and counted.
local function mergeSlots(base, extra, maxSlots, label, report)
    local out, used = {}, {}
    for _, it in ipairs(base or {}) do
        out[#out + 1] = it
        used[it.slot] = true
    end
    for _, it in ipairs(extra or {}) do
        if not it.slot or it.slot < 1 or it.slot > maxSlots or used[it.slot] then
            local free
            for s = 1, maxSlots do
                if not used[s] then free = s break end
            end
            if not free then
                Q.invStats().itemsDropped = Q.invStats().itemsDropped + 1
                report:warnCapped('no-slot', '%s: NO FREE SLOT for `%s` x%d - item recorded here, not migrated', label, it.name, it.count)
                goto skip
            end
            it.slot = free
        end
        used[it.slot] = true
        out[#out + 1] = it
        ::skip::
    end
    table.sort(out, function(a, b) return a.slot < b.slot end)
    return out
end

--- Normalises every ESX inventory dialect into ox_inventory format and appends the
--- loadout weapons and black money. Returns oxList (table) or nil when nothing needs
--- writing, plus `keepRaw` = true when the column is already ox format and must be
--- left exactly as it is.
local function buildInventory(row, label, oxItems, maxSlots, maxWeight, blackMoney, report)
    local decoded = decodeMaybe(row.inventory)
    local entries, slot = {}, 0

    local function push(name, count, info)
        if type(name) ~= 'string' or name == '' then return end
        count = math.floor(tonumber(count) or 0)
        if count <= 0 then return end
        slot = slot + 1
        entries[#entries + 1] = { name = name:lower(), amount = count, info = info, slot = slot }
    end

    local base = nil
    if type(decoded) == 'table' and next(decoded) ~= nil then
        local firstKey, firstVal = next(decoded)
        if type(firstVal) == 'number' then
            -- Legacy ESX map: {"bread": 2, "water": 1}
            local names = {}
            for name in pairs(decoded) do names[#names + 1] = tostring(name) end
            table.sort(names)
            for _, name in ipairs(names) do push(name, decoded[name]) end
        elseif type(firstVal) == 'table' then
            local sawSlot = false
            for _, v in pairs(decoded) do
                if type(v) == 'table' and v.slot ~= nil then sawSlot = true break end
            end
            if sawSlot then
                -- Slotted list: either ox already ([{slot,name,count,metadata}]) or
                -- qs/qb on ESX ([{slot,name,count|amount,info}]). The shared converter
                -- tells them apart and leaves ox alone.
                local before = Q.invStats().alreadyOx
                base = Q.convertItemList(row.inventory, label, oxItems, maxSlots, maxWeight, report)
                if Q.invStats().alreadyOx > before then
                    -- ox_inventory was already running on ESX: weapons and black_money
                    -- are in this list already and the loadout column is empty.
                    return nil, true
                end
            else
                -- Legacy ESX list: [{name='bread', count=2}]
                for _, v in pairs(decoded) do
                    if type(v) == 'table' then push(v.name, v.count or v.amount, v.info or v.metadata) end
                end
            end
        elseif type(firstKey) == 'string' and type(firstVal) == 'string' and tonumber(firstVal) then
            for name, count in pairs(decoded) do push(tostring(name), count) end
        end
    elseif row.inventory ~= nil and row.inventory ~= '' and row.inventory ~= 'null' and decoded == nil then
        report:warnCapped('esx-inv-json', '%s: inventory JSON unreadable - weapons/black money still migrated, items were NOT', label)
    end

    if #entries > 0 then
        base = Q.convertItemList(json.encode(entries), label, oxItems, maxSlots, maxWeight, report)
    end

    -- Loadout weapons and black money are appended after the last used slot.
    local extras = {}
    for _, it in ipairs(base or {}) do slot = math.max(slot, it.slot) end
    for _, e in ipairs(loadoutToEntries(row.loadout, oxItems)) do
        slot = slot + 1
        e.slot = slot
        extras[#extras + 1] = e
    end
    if blackMoney > 0 then
        slot = slot + 1
        extras[#extras + 1] = { name = 'black_money', amount = blackMoney, slot = slot }
        LoadoutStats.blackMoney = LoadoutStats.blackMoney + blackMoney
    end

    local extraOx
    if #extras > 0 then
        -- black_money is an account item in CONFIG.accountItems (stripped for QBCore,
        -- where money lives in players.money). Here it is real inventory, so shield it.
        local strip = Q.CONFIG.accountItems.black_money
        Q.CONFIG.accountItems.black_money = false
        extraOx = Q.convertItemList(json.encode(extras), label, oxItems, maxSlots, nil, report)
        Q.CONFIG.accountItems.black_money = strip
    end

    if not base and not extraOx then return nil, false end
    return mergeSlots(base, extraOx, maxSlots, label, report), false
end

-- =====================================================================================
-- SCHEMA (qbx tables an ESX database does not have)
-- =====================================================================================

local ESX_SCHEMA = {
    { id = 'table.players', check = function() return tableExists('players') end, sql = [[
        CREATE TABLE IF NOT EXISTS `players` (
            `id` int(11) NOT NULL AUTO_INCREMENT,
            `userId` INT UNSIGNED DEFAULT NULL,
            `citizenid` varchar(50) NOT NULL,
            `cid` int(11) DEFAULT NULL,
            `license` varchar(255) NOT NULL,
            `name` varchar(255) NOT NULL,
            `money` text NOT NULL,
            `charinfo` text DEFAULT NULL,
            `job` text NOT NULL,
            `gang` text DEFAULT NULL,
            `position` text NOT NULL,
            `metadata` text NOT NULL,
            `inventory` longtext DEFAULT NULL,
            `phone_number` VARCHAR(20) DEFAULT NULL,
            `last_updated` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
            `last_logged_out` timestamp NULL DEFAULT NULL,
            PRIMARY KEY (`citizenid`),
            KEY `id` (`id`), KEY `last_updated` (`last_updated`), KEY `license` (`license`)
        ) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]] },
    { id = 'table.player_vehicles', check = function() return tableExists('player_vehicles') end, sql = [[
        CREATE TABLE IF NOT EXISTS `player_vehicles` (
            `id` int(11) NOT NULL AUTO_INCREMENT,
            `license` varchar(50) DEFAULT NULL,
            `citizenid` varchar(50) DEFAULT NULL,
            `vehicle` varchar(50) DEFAULT NULL,
            `hash` varchar(50) DEFAULT NULL,
            `mods` longtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL,
            `plate` varchar(15) NOT NULL,
            `fakeplate` varchar(50) DEFAULT NULL,
            `garage` varchar(50) DEFAULT NULL,
            `fuel` int(11) DEFAULT 100,
            `engine` float DEFAULT 1000,
            `body` float DEFAULT 1000,
            `state` int(11) DEFAULT 1,
            `depotprice` int(11) NOT NULL DEFAULT 0,
            `drivingdistance` int(50) DEFAULT NULL,
            `status` text DEFAULT NULL,
            `coords` text DEFAULT NULL,
            `trunk` longtext DEFAULT NULL,
            `glovebox` longtext DEFAULT NULL,
            PRIMARY KEY (`id`),
            UNIQUE KEY `plate` (`plate`),
            KEY `citizenid` (`citizenid`),
            CONSTRAINT `fk_player_vehicles_citizenid` FOREIGN KEY (`citizenid`) REFERENCES `players` (`citizenid`) ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]] },
    { id = 'table.bans', check = function() return tableExists('bans') end, sql = [[
        CREATE TABLE IF NOT EXISTS `bans` (
            `id` int(11) NOT NULL AUTO_INCREMENT,
            `name` varchar(50) DEFAULT NULL,
            `license` varchar(50) DEFAULT NULL,
            `discord` varchar(50) DEFAULT NULL,
            `ip` varchar(50) DEFAULT NULL,
            `reason` text DEFAULT NULL,
            `expire` int(11) DEFAULT NULL,
            `bannedby` varchar(255) NOT NULL DEFAULT 'LeBanhammer',
            PRIMARY KEY (`id`), KEY `license` (`license`), KEY `discord` (`discord`), KEY `ip` (`ip`)
        ) ENGINE=InnoDB AUTO_INCREMENT=1 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]] },
    { id = 'table.player_groups', check = function() return tableExists('player_groups') end, sql = [[
        CREATE TABLE IF NOT EXISTS `player_groups` (
            `citizenid` VARCHAR(50) NOT NULL,
            `group` VARCHAR(50) NOT NULL,
            `type` VARCHAR(50) NOT NULL,
            `grade` TINYINT(3) UNSIGNED NOT NULL,
            PRIMARY KEY (`citizenid`, `type`, `group`),
            CONSTRAINT `fk_citizenid` FOREIGN KEY (`citizenid`) REFERENCES `players` (`citizenid`) ON UPDATE CASCADE ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]] },
    { id = 'table.ox_inventory', check = function() return tableExists('ox_inventory') end, sql = [[
        CREATE TABLE IF NOT EXISTS `ox_inventory` (
            `owner` varchar(60) DEFAULT NULL,
            `name` varchar(100) NOT NULL,
            `data` longtext DEFAULT NULL,
            `lastupdated` timestamp NOT NULL DEFAULT current_timestamp() ON UPDATE current_timestamp(),
            UNIQUE KEY `owner_name` (`owner`,`name`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]] },
    { id = 'table.' .. MAP_TABLE, check = function() return tableExists(MAP_TABLE) end, sql = ([[
        CREATE TABLE IF NOT EXISTS `%s` (
            `identifier` varchar(60) NOT NULL,
            `citizenid` varchar(50) NOT NULL,
            `license` varchar(60) NOT NULL,
            `cid` int(11) NOT NULL,
            `created_at` timestamp NOT NULL DEFAULT current_timestamp(),
            PRIMARY KEY (`identifier`), KEY `citizenid` (`citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]]):format(MAP_TABLE) },
    { id = 'table.' .. LOG_TABLE, check = function() return tableExists(LOG_TABLE) end, sql = ([[
        CREATE TABLE IF NOT EXISTS `%s` (
            `kind` varchar(20) NOT NULL,
            `ref` varchar(160) NOT NULL,
            `extra` varchar(160) DEFAULT NULL,
            PRIMARY KEY (`kind`, `ref`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]]):format(LOG_TABLE) },
}

-- Columns to add when the qbx tables already existed in an older shape.
local ESX_COLUMNS = {
    { 'players', 'inventory', 'longtext DEFAULT NULL' },
    { 'players', 'phone_number', 'VARCHAR(20) DEFAULT NULL' },
    { 'players', 'last_logged_out', 'timestamp NULL DEFAULT NULL' },
    { 'players', 'userId', 'INT UNSIGNED DEFAULT NULL' },
    { 'player_vehicles', 'trunk', 'longtext DEFAULT NULL' },
    { 'player_vehicles', 'glovebox', 'longtext DEFAULT NULL' },
    { 'player_vehicles', 'license', 'varchar(50) DEFAULT NULL' },
}

local function ensureQbxSchema(report, apply)
    report:heading('Qbx tables')
    local created = 0
    for _, stmt in ipairs(ESX_SCHEMA) do
        if stmt.check() then
            report:add('- already present: `%s`', stmt.id)
        elseif apply then
            local ok, err = pcall(MySQL.query.await, stmt.sql)
            if ok then
                report:ok('created `%s`', stmt.id)
                created = created + 1
            else
                report:err('`%s` failed: %s', stmt.id, tostring(err))
            end
        else
            report:add('- WOULD CREATE `%s`', stmt.id)
            created = created + 1
        end
    end
    for _, col in ipairs(ESX_COLUMNS) do
        local tbl, name, def = col[1], col[2], col[3]
        if tableExists(tbl) and not columnExists(tbl, name) then
            if apply then
                local ok, err = pcall(MySQL.query.await, ('ALTER TABLE `%s` ADD COLUMN `%s` %s'):format(tbl, name, def))
                if ok then report:ok('added `%s.%s`', tbl, name) else report:err('`%s.%s` failed: %s', tbl, name, tostring(err)) end
            else
                report:add('- WOULD ADD `%s.%s`', tbl, name)
            end
        end
    end
    return created
end

-- =====================================================================================
-- LOG / MAP HELPERS
-- =====================================================================================

--- Positional parameter lists cannot carry nil (a hole truncates the array before it
--- reaches oxmysql). Nullable columns are written as NULLIF(?, '') and fed '' instead.
local function orEmpty(v)
    if v == nil then return '' end
    return v
end

local function logRow(kind, ref, extra)
    MySQL.query.await(('INSERT INTO `%s` (kind, ref, extra) VALUES (?, ?, NULLIF(?, \'\')) ON DUPLICATE KEY UPDATE extra = VALUES(extra)'):format(LOG_TABLE),
        { kind, ref, orEmpty(extra) })
end

local function flush(query, list)
    for i = 1, #list, Q.batchSize do
        local batch = {}
        for j = i, math.min(i + Q.batchSize - 1, #list) do batch[#batch + 1] = list[j] end
        MySQL.prepare.await(query, batch)
    end
end

-- =====================================================================================
-- STEP: ESX
-- =====================================================================================

local function stepEsx(report, apply)
    report:heading('ESX -> Qbox' .. (apply and ' (APPLY)' or ' (DRY RUN)'))

    local usersTable = esxUsersTable()
    if not usersTable then
        report:err('no ESX `users` table found (looked for `users` with an `identifier` column, and `%s`)', CFG.usersTable)
        return 0
    end

    ---------------------------------------------------------------------------
    -- 0. users -> esx_users rename (qbx_core will create its own `users`)
    ---------------------------------------------------------------------------
    if usersTable == 'users' then
        if tableExists(CFG.usersTable) then
            report:err('both `users` (ESX) and `%s` exist - refusing to guess which is the source. Rename or drop one.', CFG.usersTable)
            return 0
        end
        if apply then
            MySQL.query.await(('RENAME TABLE `users` TO `%s`'):format(CFG.usersTable))
            report:ok('renamed `users` -> `%s` (qbx_core creates its own `users` table on start; the two cannot coexist)', CFG.usersTable)
            usersTable = CFG.usersTable
        else
            report:add('- WOULD RENAME `users` -> `%s` (qbx_core creates its own `users` table on start; the two cannot coexist)', CFG.usersTable)
        end
    else
        report:add('- reading from `%s`', usersTable)
    end

    ---------------------------------------------------------------------------
    -- 1. schema
    ---------------------------------------------------------------------------
    ensureQbxSchema(report, apply)
    if apply and not tableExists('players') then
        report:err('`players` could not be created - aborting')
        return 0
    end

    ---------------------------------------------------------------------------
    -- 2. reference data
    ---------------------------------------------------------------------------
    report:heading('Players')

    local oxItems = Q.getOxItems()
    if not oxItems then
        report:warn('ox_inventory is not running - unknown-item, weight and attachment checks are DISABLED. Start ox_inventory (with the generated items merged) before applying.')
    end
    local maxSlots = GetConvarInt('inventory:slots', 50)
    local maxWeight = GetConvarInt('inventory:weight', 30000)

    local esxJobs = loadEsxJobs(report)

    local licencesByOwner = {}
    if tableExists('user_licenses') then
        for _, r in ipairs(MySQL.query.await('SELECT type, owner FROM user_licenses') or {}) do
            local o = tostring(r.owner)
            licencesByOwner[o] = licencesByOwner[o] or {}
            table.insert(licencesByOwner[o], r.type)
        end
    end

    -- Existing mapping (re-run) and existing citizenids (uniqueness).
    local map, usedCitizenIds = {}, {}
    if tableExists(MAP_TABLE) then
        for _, r in ipairs(MySQL.query.await(('SELECT identifier, citizenid, license, cid FROM `%s`'):format(MAP_TABLE)) or {}) do
            map[tostring(r.identifier)] = { citizenid = r.citizenid, license = r.license, cid = tonumber(r.cid) }
        end
    end
    if tableExists('players') then
        for _, r in ipairs(MySQL.query.await('SELECT citizenid FROM players') or {}) do
            usedCitizenIds[tostring(r.citizenid)] = true
        end
    end
    local function newCitizenId()
        local id
        repeat id = randomCitizenId() until not usedCitizenIds[id]
        usedCitizenIds[id] = true
        return id
    end

    local existingPhones = {}
    if tableExists('players') and columnExists('players', 'phone_number') then
        for _, r in ipairs(MySQL.query.await("SELECT phone_number FROM players WHERE phone_number IS NOT NULL AND phone_number <> ''") or {}) do
            existingPhones[tostring(r.phone_number)] = true
        end
    end

    ---------------------------------------------------------------------------
    -- 3. users -> players
    ---------------------------------------------------------------------------
    Q.resetInvStats()
    LoadoutStats = { weapons = 0, componentsDropped = {}, blackMoney = 0 }

    local users = MySQL.query.await(('SELECT * FROM `%s` ORDER BY `identifier`'):format(usersTable)) or {}
    report:add('- %d ESX user rows', #users)

    local hasCol = {}
    for _, c in ipairs({ 'firstname', 'lastname', 'dateofbirth', 'sex', 'height', 'phone_number', 'status', 'is_dead', 'metadata', 'loadout', 'disabled', 'group', 'skin', 'position', 'accounts', 'inventory' }) do
        hasCol[c] = columnExists(usersTable, c)
    end
    for _, c in ipairs({ 'firstname', 'accounts', 'inventory', 'loadout', 'status', 'phone_number' }) do
        if not hasCol[c] then report:add('- `%s.%s` column absent, that data will use defaults', usersTable, c) end
    end

    local playerRows, mapRows, groupRows = {}, {}, {}
    local shapeTally, cidByLicense, admins, disabled = {}, {}, {}, 0
    local identifierToCitizen, citizenToLicense = {}, {}
    local blackMoneyTotal = 0

    for _, row in ipairs(users) do
        local identifier = tostring(row.identifier)
        local license, cid, how = parseIdentifier(identifier)
        shapeTally[how] = (shapeTally[how] or 0) + 1

        local existing = map[identifier]
        local citizenid = existing and existing.citizenid or newCitizenId()
        if existing then license = existing.license end

        -- Slot must be unique per account; ESX single-character servers have no slot.
        cidByLicense[license] = cidByLicense[license] or {}
        cid = existing and existing.cid or cid or 1
        while cidByLicense[license][cid] and not existing do cid = cid + 1 end
        cidByLicense[license][cid] = true

        identifierToCitizen[identifier] = citizenid
        citizenToLicense[citizenid] = license
        local label = ('user %s'):format(identifier)

        local firstname = hasCol.firstname and row.firstname or nil
        local lastname = hasCol.lastname and row.lastname or nil
        local money, blackMoney = buildMoney(hasCol.accounts and row.accounts or nil)
        blackMoneyTotal = blackMoneyTotal + blackMoney

        local phone = hasCol.phone_number and row.phone_number and tostring(row.phone_number) or nil
        if phone == '' then phone = nil end
        if phone and existingPhones[phone] and not existing then
            report:warnCapped('esx-phone', '%s: phone %s already taken - left NULL, qbx_core will generate one', label, phone)
            phone = nil
        elseif phone then
            existingPhones[phone] = true
        end

        local charinfo = {
            firstname = tostring(firstname or 'Firstname'),
            lastname = tostring(lastname or 'Lastname'),
            birthdate = convertBirthdate(hasCol.dateofbirth and row.dateofbirth or nil) or '2000-01-01',
            gender = (hasCol.sex and tostring(row.sex):lower() == 'f') and 1 or 0,
            nationality = CFG.nationality,
            phone = phone,
            cid = cid,
            backstory = 'Migrated from ESX',
        }
        if hasCol.height and tonumber(row.height) then charinfo.height = tonumber(row.height) end

        local job = buildJob(row.job, row.job_grade, esxJobs, report, label)
        local metadata = buildMetadata(row, licencesByOwner[identifier])
        local position = buildPosition(hasCol.position and row.position or nil)

        local inventory, keepRaw = buildInventory(row, label, oxItems, maxSlots, maxWeight, blackMoney, report)
        local inventoryJson
        if keepRaw then inventoryJson = row.inventory
        elseif inventory then inventoryJson = encodeArray(inventory)
        else inventoryJson = '[]' end

        if hasCol.disabled and (row.disabled == 1 or row.disabled == true or row.disabled == '1') then
            disabled = disabled + 1
            metadata.esxDisabled = true
        end

        if hasCol.group then
            local g = tostring(row.group or 'user'):lower()
            if g ~= 'user' and g ~= '' then
                admins[#admins + 1] = { license = license, group = g, name = charinfo.firstname .. ' ' .. charinfo.lastname }
            end
        end

        playerRows[#playerRows + 1] = {
            citizenid = citizenid,
            cid = cid,
            license = license,
            name = ('%s %s'):format(charinfo.firstname, charinfo.lastname),
            money = json.encode(money),
            charinfo = json.encode(charinfo),
            job = json.encode(job),
            gang = json.encode(DEFAULT_GANG),
            position = position and json.encode(position) or 'null',
            metadata = json.encode(metadata),
            inventory = inventoryJson,
            phone_number = phone,
        }
        mapRows[#mapRows + 1] = { identifier, citizenid, license, cid }
        if job.name ~= 'unemployed' then
            groupRows[#groupRows + 1] = { citizenid, job.name, 'job', job.grade.level }
        end
    end

    report:add('- identifier shapes: %s', (function()
        local parts = {}
        for k, v in pairs(shapeTally) do parts[#parts + 1] = ('%s=%d'):format(k, v) end
        table.sort(parts)
        return table.concat(parts, ', ')
    end)())
    if shapeTally.unknown then
        report:warn('%d identifiers could not be classified and were written as `license:<value>`. Set CONFIG.esx.identifierType if that is wrong. The login reconciler still matches on the bare value.', shapeTally.unknown)
    end
    if disabled > 0 then report:add('- %d characters were disabled in esx_multicharacter (flagged metadata.esxDisabled)', disabled) end
    report:add('- %d characters to write, %d already mapped from a previous run', #playerRows, (function() local n = 0 for _ in pairs(map) do n = n + 1 end return n end)())
    report:add('- weapons from loadout: %d, black_money converted to items: $%d', LoadoutStats.weapons, LoadoutStats.blackMoney)
    do
        local dropped = {}
        for c, n in pairs(LoadoutStats.componentsDropped) do dropped[#dropped + 1] = ('%s (%d)'):format(c, n) end
        table.sort(dropped)
        if #dropped > 0 then
            report:warn('weapon components with no ox_inventory attachment item were dropped: %s. Add them to CONFIG.esx.componentMap.', table.concat(dropped, ', '))
        end
    end

    local playersWritten = 0
    if apply and #playerRows > 0 then
        local hasUserId = columnExists('players', 'userId')
        local batch = {}
        for _, p in ipairs(playerRows) do
            batch[#batch + 1] = {
                p.citizenid, p.cid, p.license, p.name, p.money, p.charinfo, p.job, p.gang, p.position, p.metadata, p.inventory, orEmpty(p.phone_number),
            }
        end
        flush([[
            INSERT INTO players (citizenid, cid, license, name, money, charinfo, job, gang, position, metadata, inventory, phone_number)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULLIF(?, ''))
            ON DUPLICATE KEY UPDATE cid = VALUES(cid), license = VALUES(license), name = VALUES(name), money = VALUES(money),
                charinfo = VALUES(charinfo), job = VALUES(job), gang = VALUES(gang), position = VALUES(position),
                metadata = VALUES(metadata), inventory = VALUES(inventory), phone_number = VALUES(phone_number)
        ]], batch)
        flush(('INSERT INTO `%s` (identifier, citizenid, license, cid) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE citizenid = VALUES(citizenid), license = VALUES(license), cid = VALUES(cid)'):format(MAP_TABLE), mapRows)
        if #groupRows > 0 then
            flush('INSERT INTO player_groups (citizenid, `group`, `type`, grade) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE grade = VALUES(grade)', groupRows)
        end
        playersWritten = #playerRows
        report:ok('wrote %d players, %d player_groups rows', #playerRows, #groupRows)
        if not hasUserId then report:warn('`players.userId` missing; qbx_core adds it on start') end
    end

    -- Admin ACE snippet. `identifier.license:` works because the client still presents
    -- its `license:` identifier alongside license2.
    if #admins > 0 then
        local lines = {
            '# Generated by qbx_migrate from ESX users.group. Append to server.cfg (review first).',
            '# Qbox has no DB-backed groups; permissions are ACE principals.',
        }
        table.sort(admins, function(a, b) return a.group < b.group end)
        for _, a in ipairs(admins) do
            local group = a.group == 'superadmin' and 'admin' or a.group
            lines[#lines + 1] = ('add_principal identifier.%s group.%s  # %s (was %s)'):format(a.license, group, a.name, a.group)
        end
        if apply then
            SaveResourceFile(RES, 'output/esx_admins.cfg', table.concat(lines, '\n') .. '\n', -1)
            report:ok('%d staff accounts -> output/esx_admins.cfg', #admins)
        else
            report:add('- %d staff accounts would be written to output/esx_admins.cfg', #admins)
        end
    end

    ---------------------------------------------------------------------------
    -- 4. owned_vehicles -> player_vehicles
    ---------------------------------------------------------------------------
    report:heading('Vehicles')
    local vehiclesWritten = 0
    if not tableExists('owned_vehicles') then
        report:add('- `owned_vehicles` not present, skipping')
    else
        buildModelIndex(report)

        local vcol = {}
        for _, c in ipairs({ 'owner', 'plate', 'vehicle', 'type', 'job', 'stored', 'parking', 'pound', 'garage', 'trunk', 'glovebox', 'fuel', 'engine', 'body' }) do
            vcol[c] = columnExists('owned_vehicles', c)
        end
        local pvHas = {}
        for _, c in ipairs({ 'license', 'trunk', 'glovebox', 'garage', 'state', 'fuel', 'engine', 'body', 'hash', 'mods' }) do
            pvHas[c] = tableExists('player_vehicles') and columnExists('player_vehicles', c)
        end

        local rows = MySQL.query.await('SELECT * FROM owned_vehicles') or {}
        report:add('- %d owned_vehicles rows', #rows)

        local inserts, seenPlates, dupes, orphans, unresolved = {}, {}, {}, {}, {}
        for _, v in ipairs(rows) do
            local plate = tostring(v.plate or '')
            local key = trim(plate):upper()
            if key == '' then
                goto nextVehicle
            end
            if seenPlates[key] then
                dupes[#dupes + 1] = plate
                goto nextVehicle
            end
            seenPlates[key] = true

            do
                local owner = v.owner and tostring(v.owner) or ''
                local citizenid = identifierToCitizen[owner]
                if not citizenid then
                    orphans[#orphans + 1] = ('%s (owner `%s`%s)'):format(plate, owner, v.job and (', job ' .. tostring(v.job)) or '')
                    if not CFG.keepOrphanVehicles then goto nextVehicle end
                end

                local props = decodeMaybe(v.vehicle)
                if type(props) ~= 'table' then props = {} end
                local model = resolveModel(props)
                if not model then
                    unresolved[#unresolved + 1] = ('%s (model %s)'):format(plate, tostring(props.model))
                    goto nextVehicle
                end
                props.plate = props.plate or plate

                local state = 1
                if vcol.pound and v.pound and v.pound ~= '' then state = 2
                elseif vcol.stored and (tonumber(v.stored) or 0) == 0 then state = 0 end

                local garage = (vcol.parking and v.parking) or (vcol.garage and v.garage) or nil
                if garage == '' then garage = nil end

                inserts[#inserts + 1] = {
                    license = citizenid and citizenToLicense[citizenid] or nil,
                    citizenid = citizenid,
                    vehicle = model,
                    hash = tostring(toSigned(joaat(model))),
                    mods = json.encode(props),
                    plate = plate,
                    garage = garage,
                    fuel = math.floor(tonumber((vcol.fuel and v.fuel) or props.fuelLevel) or 100),
                    engine = tonumber((vcol.engine and v.engine) or props.engineHealth) or 1000,
                    body = tonumber((vcol.body and v.body) or props.bodyHealth) or 1000,
                    state = state,
                    trunk = vcol.trunk and v.trunk or nil,
                    glovebox = vcol.glovebox and v.glovebox or nil,
                }
            end
            ::nextVehicle::
        end

        report:add('- %d vehicles to write, %d duplicate plates skipped, %d unowned, %d unresolved models', #inserts, #dupes, #orphans, #unresolved)
        if #dupes > 0 then report:row('- duplicate plates (first row kept): `%s`', table.concat(dupes, '`, `')) end
        if #orphans > 0 then
            report:warn('%d vehicles have an owner that is not an ESX user (job/society vehicles). %s', #orphans,
                CFG.keepOrphanVehicles and 'Written with citizenid NULL.' or 'Skipped - set CONFIG.esx.keepOrphanVehicles = true to write them with citizenid NULL.')
            report:row('')
            for _, o in ipairs(orphans) do report:row('    - %s', o) end
        end
        if #unresolved > 0 then
            report:warn('%d vehicles have a model hash that matches no known spawn name. Add the addon model names to CONFIG.esx.vehicleModels and re-run; these rows are NOT written.', #unresolved)
            report:row('')
            for _, u in ipairs(unresolved) do report:row('    - %s', u) end
        end

        if apply and #inserts > 0 then
            local cols = { 'citizenid', 'vehicle', 'plate', 'depotprice' }
            local optional = { 'license', 'hash', 'mods', 'garage', 'fuel', 'engine', 'body', 'state', 'trunk', 'glovebox' }
            for _, c in ipairs(optional) do if pvHas[c] then cols[#cols + 1] = c end end

            local nullable = { license = true, citizenid = true, garage = true, trunk = true, glovebox = true }
            local marks, updates = {}, {}
            for _, c in ipairs(cols) do
                marks[#marks + 1] = nullable[c] and "NULLIF(?, '')" or '?'
                if c ~= 'plate' then updates[#updates + 1] = ('`%s` = VALUES(`%s`)'):format(c, c) end
            end
            local query = ('INSERT INTO player_vehicles (%s) VALUES (%s) ON DUPLICATE KEY UPDATE %s')
                :format('`' .. table.concat(cols, '`, `') .. '`', table.concat(marks, ', '), table.concat(updates, ', '))

            local batch = {}
            for _, ins in ipairs(inserts) do
                local values = {}
                for i, c in ipairs(cols) do
                    if c == 'depotprice' then values[i] = 0 else values[i] = orEmpty(ins[c]) end
                end
                batch[#batch + 1] = values
            end
            flush(query, batch)
            for _, ins in ipairs(inserts) do logRow('vehicle', ins.plate, ins.citizenid) end
            vehiclesWritten = #inserts
            report:ok('wrote %d player_vehicles rows', #inserts)
        end
    end

    ---------------------------------------------------------------------------
    -- 5. society inventories -> ox_inventory stashes
    ---------------------------------------------------------------------------
    report:heading('Stashes & societies')

    -- ESX splits one society store across two tables: items in addon_inventory_items,
    -- weapons in datastore_data, both under the same name. Collect per (name, owner)
    -- first, convert once, so neither source overwrites the other.
    local stashGroups, stashOrder = {}, {}
    local function stashGroup(name, ownerRaw)
        local ownerId = ownerRaw and tostring(ownerRaw) or ''
        local owner = ownerId ~= '' and (identifierToCitizen[ownerId] or ownerId) or ''
        local key = name .. '/' .. owner
        if not stashGroups[key] then
            stashGroups[key] = { name = name, owner = owner, ownerRaw = ownerId, entries = {} }
            stashOrder[#stashOrder + 1] = key
        end
        return stashGroups[key]
    end

    if tableExists('addon_inventory_items') then
        local n = 0
        for _, r in ipairs(MySQL.query.await('SELECT inventory_name, name, count, owner FROM addon_inventory_items') or {}) do
            local g = stashGroup(tostring(r.inventory_name), r.owner)
            g.entries[#g.entries + 1] = { name = tostring(r.name), amount = r.count }
            n = n + 1
        end
        report:add('- addon_inventory_items: %d item rows', n)
    end

    if tableExists('datastore_data') then
        local n = 0
        for _, r in ipairs(MySQL.query.await('SELECT name, owner, data FROM datastore_data') or {}) do
            local data = decodeMaybe(r.data)
            if type(data) == 'table' and (type(data.items) == 'table' or type(data.weapons) == 'table') then
                local g = stashGroup(tostring(r.name), r.owner)
                for _, it in ipairs(data.items or {}) do
                    if type(it) == 'table' and it.name then g.entries[#g.entries + 1] = { name = tostring(it.name), amount = it.count or it.amount } end
                end
                for _, w in ipairs(loadoutToEntries(data.weapons or {}, oxItems)) do g.entries[#g.entries + 1] = w end
                n = n + 1
            end
        end
        report:add('- datastore_data: %d entries with items or weapons', n)
    end

    local stashRows = {}
    for _, key in ipairs(stashOrder) do
        local g = stashGroups[key]
        for i, e in ipairs(g.entries) do e.slot = i end
        if #g.entries > 0 then
            local converted = Q.convertItemList(json.encode(g.entries), ('stash %s/%s'):format(g.name, g.ownerRaw), oxItems, maxSlots, nil, report)
            if converted then
                stashRows[#stashRows + 1] = { encodeArray(converted), g.owner, g.name }
            end
        end
    end

    report:add('- %d stashes to write into ox_inventory', #stashRows)
    if #stashRows > 0 then
        report:row('')
        report:row('| stash name | owner |')
        report:row('| --- | --- |')
        for _, s in ipairs(stashRows) do report:row('| `%s` | `%s` |', s[3], s[2]) end
        report:add('- these keep their ESX names (`society_police`, ...). Whatever qbx/ox script owns the stash must register it under the same name.')
    end
    if apply and #stashRows > 0 then
        flush('INSERT INTO ox_inventory (data, owner, name) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE data = VALUES(data)', stashRows)
        for _, s in ipairs(stashRows) do logRow('stash', s[2] .. '/' .. s[3]) end
        report:ok('wrote %d stashes', #stashRows)
    end

    -- Society money
    if tableExists('addon_account_data') then
        local funds = MySQL.query.await("SELECT account_name, money, owner FROM addon_account_data WHERE owner IS NULL OR owner = ''") or {}
        if #funds > 0 then
            report:row('')
            report:row('| society account | balance |')
            report:row('| --- | --- |')
            local json_out, mgmt = {}, {}
            for _, f in ipairs(funds) do
                report:row('| `%s` | %d |', tostring(f.account_name), tonumber(f.money) or 0)
                json_out[tostring(f.account_name)] = tonumber(f.money) or 0
                local jobName = tostring(f.account_name):gsub('^society_', '')
                mgmt[#mgmt + 1] = { jobName, tonumber(f.money) or 0, 'boss' }
            end
            local canWrite = tableExists('management_funds') and columnExists('management_funds', 'job_name') and columnExists('management_funds', 'amount')
            if apply then
                SaveResourceFile(RES, 'output/esx_society_funds.json', json.encode(json_out), -1)
                if canWrite then
                    local hasType = columnExists('management_funds', 'type')
                    if hasType then
                        flush('INSERT INTO management_funds (job_name, amount, `type`) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE amount = VALUES(amount)', mgmt)
                    else
                        local two = {}
                        for _, m in ipairs(mgmt) do two[#two + 1] = { m[1], m[2] } end
                        flush('INSERT INTO management_funds (job_name, amount) VALUES (?, ?) ON DUPLICATE KEY UPDATE amount = VALUES(amount)', two)
                    end
                    for _, m in ipairs(mgmt) do logRow('funds', m[1]) end
                    report:ok('%d society balances -> management_funds (and output/esx_society_funds.json)', #mgmt)
                else
                    report:warn('%d society balances written to output/esx_society_funds.json only - no `management_funds` table (install qbx_management / your banking first, then re-run this step)', #mgmt)
                end
            else
                report:add('- %d society balances would go to %s', #mgmt, canWrite and 'management_funds' or 'output/esx_society_funds.json (no management_funds table yet)')
            end
        end
    end

    ---------------------------------------------------------------------------
    -- 6. ox_inventory owners (servers that already ran ox_inventory on ESX)
    ---------------------------------------------------------------------------
    if tableExists('ox_inventory') then
        local owners = MySQL.query.await("SELECT DISTINCT owner FROM ox_inventory WHERE owner IS NOT NULL AND owner <> ''") or {}
        local remaps = {}
        for _, o in ipairs(owners) do
            local citizenid = identifierToCitizen[tostring(o.owner)]
            if citizenid then remaps[#remaps + 1] = { citizenid, tostring(o.owner) } end
        end
        if #remaps > 0 then
            report:add('- ox_inventory: %d owned-stash owners are ESX identifiers and will be rewritten to citizenids', #remaps)
            if apply then
                flush('UPDATE ox_inventory SET owner = ? WHERE owner = ?', remaps)
                for _, r in ipairs(remaps) do logRow('oxowner', r[1], r[2]) end
                report:ok('rewrote %d ox_inventory owners', #remaps)
            end
        end
    end

    ---------------------------------------------------------------------------
    -- 7. what is NOT migrated
    ---------------------------------------------------------------------------
    report:heading('Not migrated (by design)')
    report:add('- `%s.skin` - use illenium-appearance\'s own importer; the column is untouched', usersTable)
    for _, t in ipairs({ 'billing', 'phone_users', 'phone_calls', 'phone_messages', 'properties', 'owned_properties', 'rented_vehicles', 'society_moneywash', 'multicharacter_slots' }) do
        if tableExists(t) then report:add('- `%s` (%d rows) - no qbx equivalent, left in place', t, Q.rowCount(t) or 0) end
    end
    report:add('- third-party tables keyed by the ESX identifier: `%s` maps identifier -> citizenid for your own UPDATE statements', MAP_TABLE)

    local unknown = {}
    for name, count in pairs(Q.invStats().itemsUnknown) do unknown[#unknown + 1] = { name = name, count = count } end
    table.sort(unknown, function(a, b) return a.count > b.count end)
    if #unknown > 0 then
        report:heading('Items NOT defined in ox_inventory')
        report:add('ox_inventory silently discards these on load. Run `qbxmigrate items apply`, merge output/items.lua into ox_inventory/data/items.lua, restart, and re-run this step BEFORE going live.')
        report:row('')
        report:row('| item | total count |')
        report:row('| --- | --- |')
        for _, u in ipairs(unknown) do report:row('| `%s` | %d |', u.name, u.count) end
    end

    if apply then
        Q.markMigration('esx', playersWritten + vehiclesWritten + #stashRows, ('players=%d vehicles=%d stashes=%d'):format(playersWritten, vehiclesWritten, #stashRows))
        if Q.refreshIdentityColumns then Q.refreshIdentityColumns() end
        report:add('')
        report:add('Next: `qbxmigrate items apply`, `qbxmigrate jobs apply`, merge the generated files, stop es_extended, start qbx_core + ox_inventory, then `qbxmigrate check`.')
        report:add('Player identifiers are rewritten to `license2:` automatically as each player connects (see `qbxmigrate identity`).')
    end

    return playersWritten + vehiclesWritten + #stashRows
end

-- =====================================================================================
-- ROLLBACK
-- =====================================================================================

local function rollbackEsx(report, apply)
    report:heading('ESX rollback' .. (apply and ' (APPLY)' or ' (DRY RUN)'))

    if not tableExists(MAP_TABLE) then
        report:err('`%s` does not exist - nothing recorded to roll back', MAP_TABLE)
        return
    end

    local players = MySQL.scalar.await(('SELECT COUNT(*) FROM `%s`'):format(MAP_TABLE)) or 0
    local logs = {}
    if tableExists(LOG_TABLE) then
        for _, r in ipairs(MySQL.query.await(('SELECT kind, ref, extra FROM `%s`'):format(LOG_TABLE)) or {}) do
            logs[r.kind] = logs[r.kind] or {}
            table.insert(logs[r.kind], r)
        end
    end
    local function n(kind) return logs[kind] and #logs[kind] or 0 end

    report:add('- %d migrated players would be deleted from `players` (player_groups / player_vehicles cascade)', players)
    report:add('- %d vehicles, %d stashes, %d ox owner rewrites, %d society funds rows', n('vehicle'), n('stash'), n('oxowner'), n('funds'))

    local esxUsers = tableExists(CFG.usersTable)
    local qbxUsers = tableExists('users') and columnExists('users', 'userId')
    if esxUsers then
        report:add('- `%s` would be renamed back to `users`%s', CFG.usersTable, qbxUsers and (' (qbx_core\'s `users` moved aside to `users_qbx_backup`)') or '')
    end

    if not apply then
        report:add('')
        report:add('DRY RUN - rerun with `qbxmigrate esx rollback apply`.')
        return
    end

    if tableExists('players') then
        MySQL.query.await(('DELETE p FROM players p JOIN `%s` m ON m.citizenid = p.citizenid'):format(MAP_TABLE))
        report:ok('deleted %d migrated players', players)
    end
    if tableExists('player_vehicles') then
        for _, r in ipairs(logs.vehicle or {}) do
            MySQL.query.await('DELETE FROM player_vehicles WHERE plate = ?', { r.ref })
        end
        report:ok('deleted %d migrated vehicles', n('vehicle'))
    end
    if tableExists('ox_inventory') then
        for _, r in ipairs(logs.stash or {}) do
            local owner, name = r.ref:match('^(.-)/(.*)$')
            if name then MySQL.query.await('DELETE FROM ox_inventory WHERE owner = ? AND name = ?', { owner, name }) end
        end
        for _, r in ipairs(logs.oxowner or {}) do
            MySQL.query.await('UPDATE ox_inventory SET owner = ? WHERE owner = ?', { r.extra, r.ref })
        end
        report:ok('removed %d stashes, restored %d ox owners', n('stash'), n('oxowner'))
    end
    if tableExists('management_funds') then
        for _, r in ipairs(logs.funds or {}) do
            MySQL.query.await('DELETE FROM management_funds WHERE job_name = ?', { r.ref })
        end
    end

    if esxUsers then
        if qbxUsers then
            if tableExists('users_qbx_backup') then MySQL.query.await('DROP TABLE `users_qbx_backup`') end
            MySQL.query.await('RENAME TABLE `users` TO `users_qbx_backup`')
            report:warn('qbx_core `users` moved to `users_qbx_backup` (it is only an id registry; qbx_core recreates it)')
        end
        if not tableExists('users') then
            MySQL.query.await(('RENAME TABLE `%s` TO `users`'):format(CFG.usersTable))
            report:ok('renamed `%s` back to `users`', CFG.usersTable)
        else
            report:err('`users` still exists; `%s` left in place', CFG.usersTable)
        end
    end

    MySQL.query.await(('DELETE FROM `%s`'):format(MAP_TABLE))
    if tableExists(LOG_TABLE) then MySQL.query.await(('DELETE FROM `%s`'):format(LOG_TABLE)) end
    MySQL.query.await("DELETE FROM qbx_migrations WHERE id = 'esx'")
    report:ok('rollback complete. Schema additions (players, player_vehicles, ...) are left in place; they are empty of migrated data.')
end

-- =====================================================================================
-- HOOKS: items / jobs from ESX tables
-- =====================================================================================

Q.HOOKS.esxItems = function(report, apply)
    if not tableExists('items') then
        report:err('neither qb-core/shared/items.lua nor an ESX `items` table is available')
        return 0
    end
    local oxItems = Q.getOxItems()
    if not oxItems then
        report:warn('ox_inventory is not running - cannot skip items it already defines. Generating ALL items; review before merging.')
    end

    local rows = MySQL.query.await('SELECT name, label, weight FROM items') or {}
    local out, keys, skipped = {}, {}, 0
    for _, r in ipairs(rows) do
        local key = tostring(r.name):lower()
        if oxItems and oxItems[key] then
            skipped = skipped + 1
        else
            out[key] = {
                label = tostring(r.label or key),
                weight = math.floor((tonumber(r.weight) or 0) * CFG.itemWeightMultiplier),
                stack = true,
                close = true,
            }
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)

    local buf = {
        '-- Generated by qbx_migrate from the ESX `items` table',
        '-- Merge into ox_inventory/data/items.lua. Weights are ESX units x ' .. CFG.itemWeightMultiplier .. ' (grams).',
        '-- Copy item images into ox_inventory/web/images/<name>.png',
        '',
        'return {',
    }
    for _, k in ipairs(keys) do
        buf[#buf + 1] = ('    [%q] = %s,'):format(k, Q.serialize(out[k], 2))
    end
    buf[#buf + 1] = '}'
    buf[#buf + 1] = ''

    report:add('- %d ESX items, %d already defined by ox_inventory, %d to add', #rows, skipped, #keys)
    if apply then
        SaveResourceFile(RES, 'output/items.lua', table.concat(buf, '\n'), -1)
        report:ok('wrote output/items.lua (%d items)', #keys)
        Q.markMigration('items', #keys)
    else
        report:add('- dry run: append `apply` to write output/items.lua')
    end
    return #keys
end

Q.HOOKS.esxJobs = function(report, apply)
    local esxJobs = loadEsxJobs(report)
    local out, keys = {}, {}
    for name, def in pairs(esxJobs) do
        local grades = {}
        for level, g in pairs(def.grades) do
            local entry = { name = g.label, payment = g.payment }
            if g.isboss then entry.isboss = true entry.bankAuth = true end
            grades[level] = entry
        end
        if next(grades) == nil then grades[0] = { name = 'Grade 0', payment = 0 } end
        local entry = { label = def.label, grades = grades, defaultDuty = true, offDutyPay = false }
        if def.type and def.type ~= '' then entry.type = tostring(def.type) end
        out[name] = entry
        keys[#keys + 1] = name
    end
    if not out.unemployed then
        out.unemployed = { label = 'Civilian', defaultDuty = true, offDutyPay = false, grades = { [0] = { name = 'Freelancer', payment = 10 } } }
        keys[#keys + 1] = 'unemployed'
    end
    table.sort(keys)

    local buf = {
        '-- Generated by qbx_migrate from the ESX jobs / job_grades tables. Replace qbx_core/shared/jobs.lua with this file.',
        '-- Grade keys are numbers (qbx_core requirement).',
        '',
        'return {',
    }
    for _, k in ipairs(keys) do buf[#buf + 1] = ('    [%q] = %s,'):format(k, Q.serialize(out[k], 2)) end
    buf[#buf + 1] = '}'
    buf[#buf + 1] = ''

    local gangs = {
        '-- Generated by qbx_migrate. ESX has no gangs; qbx_core requires at least `none`.',
        '',
        'return {',
        "    ['none'] = { label = 'No Gang', grades = { [0] = { name = 'Unaffiliated' } } },",
        '}',
        '',
    }

    report:add('- Jobs: converted %d entries from ESX tables', #keys)
    if apply then
        SaveResourceFile(RES, 'output/jobs.lua', table.concat(buf, '\n'), -1)
        SaveResourceFile(RES, 'output/gangs.lua', table.concat(gangs, '\n'), -1)
        report:ok('wrote output/jobs.lua and output/gangs.lua')
        Q.markMigration('jobs', #keys)
    else
        report:add('- dry run: append `apply` to write output/jobs.lua and output/gangs.lua')
    end
    return #keys
end

-- =====================================================================================
-- REGISTRATION
-- =====================================================================================

Q.STEPS.esx = stepEsx

Q.COMMANDS.esx = function(report, arg2, arg3)
    if arg2 == 'rollback' then
        rollbackEsx(report, arg3 == 'apply')
        return
    end
    local apply = arg2 == 'apply'
    if apply then Q.doBackup(report) end
    stepEsx(report, apply)
    if not apply then
        report:add('')
        report:add('DRY RUN - nothing was written. Rerun with `qbxmigrate esx apply`.')
    end
end
