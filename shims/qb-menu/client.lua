--[[
    qb-menu -> ox_lib context menu shim (qbx_migrate)

    Implements the qb-menu export surface so legacy QBCore scripts keep working
    on a Qbox server without being rewritten:

        exports['qb-menu']:openMenu(data)
        exports['qb-menu']:showHeader(data)
        exports['qb-menu']:closeMenu()

    DELETE the original qb-menu resource before using this. Two resources cannot
    share a name.
]]

local MENU_ID = 'qb_menu_shim'
local currentId = 0

---Runs a qb-menu `params` block.
---@param params table
local function invoke(params)
    if type(params) ~= 'table' or params.event == nil then return end

    local args = params.args

    if params.isAction then
        -- qb-menu: params.event holds a function
        if type(params.event) == 'function' then
            params.event(args)
        end
        return
    end

    if params.isCommand then
        ExecuteCommand(tostring(params.event))
        return
    end

    if params.isQBCommand then
        TriggerServerEvent('QBCore:CallCommand', tostring(params.event), args)
        return
    end

    if params.isServer then
        TriggerServerEvent(tostring(params.event), args)
        return
    end

    TriggerEvent(tostring(params.event), args)
end

---Converts a qb-menu data array into ox_lib context options.
---@param data table
---@return string title, table options
local function build(data)
    local title = 'Menu'
    local options = {}

    for i = 1, #data do
        local entry = data[i]
        if type(entry) == 'table' then
            if entry.isMenuHeader and entry.header and #options == 0 then
                -- First non-clickable header becomes the context title.
                title = tostring(entry.header)
                if entry.txt and entry.txt ~= '' then
                    title = ('%s - %s'):format(title, tostring(entry.txt))
                end
            else
                local params = entry.params
                local option = {
                    title = tostring(entry.header or ''),
                    description = entry.txt ~= '' and entry.txt or nil,
                    icon = entry.icon,
                    disabled = entry.disabled == true or entry.isMenuHeader == true,
                }

                if params and not option.disabled then
                    option.onSelect = function()
                        invoke(params)
                    end
                end

                options[#options + 1] = option
            end
        end
    end

    return title, options
end

local function openMenu(data)
    if type(data) ~= 'table' or #data == 0 then return end

    local title, options = build(data)

    -- Unique id per open so a stale context never gets reused.
    currentId = currentId + 1
    local id = ('%s_%d'):format(MENU_ID, currentId)

    lib.registerContext({
        id = id,
        title = title,
        options = options,
    })

    lib.showContext(id)
end

local function closeMenu()
    lib.hideContext(false)
end

exports('openMenu', openMenu)
exports('showHeader', openMenu)
exports('closeMenu', closeMenu)

RegisterNetEvent('qb-menu:client:openMenu', function(data) openMenu(data) end)
RegisterNetEvent('qb-menu:client:closeMenu', function() closeMenu() end)
