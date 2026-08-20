--[[
    progressbar -> ox_lib progress bar shim (qbx_migrate)

        exports['progressbar']:Progress({
            name = 'unique_name',
            duration = 5000,
            label = 'Doing a thing',
            useWhileDead = false,
            canCancel = true,
            controlDisables = { disableMovement = true, disableCarMovement = true, disableMouse = false, disableCombat = true },
            animation = { animDict = 'amb@...', anim = 'idle_a', flags = 49 },
            prop = { model = 'prop_cs_burger_01', bone = 60309, coords = vec3(0,0,0), rotation = vec3(0,0,0) },
        }, function(cancelled)
            if not cancelled then ... end
        end)

    QBCore.Functions.Progressbar is already bridged by qbx_core, so this only
    matters for scripts that call the standalone `progressbar` resource.

    DELETE the original progressbar resource before using this.
]]

local function toAnim(animation)
    if type(animation) ~= 'table' then return nil end
    if not animation.animDict and not animation.dict then return nil end
    return {
        dict = animation.animDict or animation.dict,
        clip = animation.anim or animation.clip,
        flag = animation.flags or animation.flag,
    }
end

local function toScenario(animation)
    if type(animation) ~= 'table' or not animation.task then return nil end
    return { scenario = animation.task }
end

local function toProp(prop)
    if type(prop) ~= 'table' or not prop.model then return nil end
    return {
        model = prop.model,
        bone = prop.bone,
        pos = prop.coords,
        rot = prop.rotation,
    }
end

local function Progress(data, cb)
    if type(data) ~= 'table' then
        if cb then cb(true) end
        return false
    end

    local disables = data.controlDisables or {}

    local props = nil
    local first = toProp(data.prop)
    local second = toProp(data.propTwo)
    if first and second then
        props = { first, second }
    elseif first then
        props = first
    elseif second then
        props = second
    end

    local success = lib.progressBar({
        duration = tonumber(data.duration) or 1000,
        label = tostring(data.label or ''),
        useWhileDead = data.useWhileDead == true,
        canCancel = data.canCancel ~= false,
        disable = {
            move = disables.disableMovement == true,
            car = disables.disableCarMovement == true,
            mouse = disables.disableMouse == true,
            combat = disables.disableCombat == true,
        },
        anim = toAnim(data.animation) or toScenario(data.animation),
        prop = props,
    })

    -- qb passes `cancelled`, ox returns `completed`.
    if cb then cb(not success) end
    return success
end

exports('Progress', Progress)
exports('ProgressWithStartEvent', function(data, startEvent, cb)
    if startEvent then TriggerEvent(startEvent) end
    return Progress(data, cb)
end)
