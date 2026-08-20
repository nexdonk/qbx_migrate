--[[
    qb-input -> ox_lib input dialog shim (qbx_migrate)

        local result = exports['qb-input']:ShowInput({
            header = 'Title',
            submitText = 'Confirm',
            inputs = {
                { type = 'text',     name = 'reason', text = 'Reason', isRequired = true },
                { type = 'number',   name = 'amount', text = 'Amount', default = 1 },
                { type = 'select',   name = 'kind',   text = 'Kind', options = { { value = 'a', text = 'A' } } },
                { type = 'checkbox', name = 'flag',   text = 'Enable' },
            }
        })

    Returns a table keyed by input `name`, or nil when the player cancels -
    same contract as qb-input.

    DELETE the original qb-input resource before using this.
]]

---@param input table qb-input row
---@return table oxRow
local function toOxRow(input)
    local kind = tostring(input.type or 'text'):lower()

    local row = {
        label = tostring(input.text or input.name or ''),
        description = input.description,
        required = input.isRequired == true,
        default = input.default,
    }

    if kind == 'number' then
        row.type = 'number'
        row.min = input.min
        row.max = input.max
        if row.default ~= nil then row.default = tonumber(row.default) end
    elseif kind == 'select' or kind == 'radio' then
        row.type = 'select'
        row.options = {}
        if type(input.options) == 'table' then
            for i = 1, #input.options do
                local opt = input.options[i]
                row.options[#row.options + 1] = {
                    value = opt.value,
                    label = tostring(opt.text or opt.label or opt.value),
                }
            end
        end
    elseif kind == 'checkbox' then
        row.type = 'checkbox'
        row.checked = input.default == true
        row.default = nil
        row.required = false
    elseif kind == 'password' then
        row.type = 'input'
        row.password = true
    elseif kind == 'textarea' then
        row.type = 'textarea'
    else
        row.type = 'input'
    end

    return row
end

local function ShowInput(data)
    if type(data) ~= 'table' or type(data.inputs) ~= 'table' then return nil end

    local rows, names = {}, {}
    for i = 1, #data.inputs do
        local input = data.inputs[i]
        if type(input) == 'table' then
            rows[#rows + 1] = toOxRow(input)
            names[#rows] = input.name or tostring(i)
        end
    end

    if #rows == 0 then return nil end

    local values = lib.inputDialog(tostring(data.header or 'Input'), rows, {
        allowCancel = true,
    })

    -- Cancelled.
    if not values then return nil end

    local result = {}
    for i = 1, #rows do
        result[names[i]] = values[i]
    end
    return result
end

exports('ShowInput', ShowInput)
exports('showInput', ShowInput)
exports('CloseInput', function() end)
