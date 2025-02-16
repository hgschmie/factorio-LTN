--[[ Copyright (c) 2017 Optera
 * Part of Logistics Train Network
 *
 * See LICENSE.md in the project directory for license information.
--]]


-- return true if stop, output, lamp are on same logic network
local function detectShortCircuit(checkStop)
    local scdetected = false
    local networks = {}
    local entities = { checkStop.entity, checkStop.output, checkStop.input }

    for k, entity in pairs(entities) do
        local greenWire = entity.get_circuit_network(defines.wire_type.green)
        if greenWire then
            if networks[greenWire.network_id] then
                scdetected = true
            else
                networks[greenWire.network_id] = entity.unit_number
            end
        end
        local redWire = entity.get_circuit_network(defines.wire_type.red)
        if redWire then
            if networks[redWire.network_id] then
                scdetected = true
            else
                networks[redWire.network_id] = entity.unit_number
            end
        end
    end

    return scdetected
end

local function remove_available_train(trainID)
    if debug_log then log('(UpdateStop) removing available train ' .. tostring(trainID) .. ' from depot.') end
    storage.Dispatcher.availableTrains_total_capacity = storage.Dispatcher.availableTrains_total_capacity - storage.Dispatcher.availableTrains[trainID].capacity
    storage.Dispatcher.availableTrains_total_fluid_capacity = storage.Dispatcher.availableTrains_total_fluid_capacity -
        storage.Dispatcher.availableTrains[trainID].fluid_capacity
    storage.Dispatcher.availableTrains[trainID] = nil
end

-- update stop input signals
function UpdateStop(stopID, stop)
    storage.Dispatcher.Requests_by_Stop[stopID] = nil

    -- remove invalid stops
    if not stop or not stop.entity.valid or not stop.input.valid or not stop.output.valid or not stop.lamp_control.valid then
        if message_level >= 1 then printmsg { 'ltn-message.error-invalid-stop', stopID } end
        if debug_log then log(format('(UpdateStop) Removing invalid stop: [%d]', stopID)) end
        RemoveStop(stopID)
        return
    end

    -- remove invalid trains
    if stop.parked_train and not stop.parked_train.valid then
        storage.LogisticTrainStops[stopID].parked_train = nil
        storage.LogisticTrainStops[stopID].parked_train_id = nil
    end

    -- remove invalid active_deliveries -- shouldn't be necessary
    for i = #stop.active_deliveries, 1, -1 do
        if not storage.Dispatcher.Deliveries[stop.active_deliveries[i]] then
            table.remove(stop.active_deliveries, i)
            if message_level >= 1 then printmsg { 'ltn-message.error-invalid-delivery', stop.entity.backer_name } end
            if debug_log then
                log("(UpdateStop) Removing invalid delivery from stop '" ..
                    tostring(stop.entity.backer_name) .. "': " .. tostring(stop.active_deliveries[i]))
            end
        end
    end

    -- reset stop parameters in case something goes wrong
    stop.min_carriages = 0
    stop.max_carriages = 0
    stop.max_trains = 0
    stop.requesting_threshold = min_requested
    stop.requester_priority = 0
    stop.no_warnings = false
    stop.providing_threshold = min_provided
    stop.provider_priority = 0
    stop.locked_slots = 0
    stop.depot_priority = 0

    -- skip short circuited stops
    if detectShortCircuit(stop) then
        stop.error_code = 1
        if stop.parked_train_id and storage.Dispatcher.availableTrains[stop.parked_train_id] then
            remove_available_train(stop.parked_train_id)
        end
        setLamp(stop, ErrorCodes[stop.error_code], 1)
        if debug_log then log('(UpdateStop) Short circuit error: ' .. stop.entity.backer_name) end
        return
    end

    -- skip deactivated stops
    local stopCB = stop.entity.get_control_behavior()
    if stopCB and stopCB.disabled then
        stop.error_code = 1
        if stop.parked_train_id and storage.Dispatcher.availableTrains[stop.parked_train_id] then
            remove_available_train(stop.parked_train_id)
        end
        setLamp(stop, ErrorCodes[stop.error_code], 2)
        if debug_log then log('(UpdateStop) Circuit deactivated stop: ' .. stop.entity.backer_name) end
        return
    end

    -- initialize control signal values to defaults
    local is_depot = false
    local depot_priority = 0
    local network_id = default_network
    local min_carriages = 0
    local max_carriages = 0
    local max_trains = 0
    local requesting_threshold = min_requested
    local requesting_threshold_stacks = 0
    local requester_priority = 0
    local no_warnings = false
    local providing_threshold = min_provided
    local providing_threshold_stacks = 0
    local provider_priority = 0
    local locked_slots = 0

    -- get circuit values 0.16.24
    local signals = stop.input.get_signals(defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green)
    if not signals then return end -- either lamp and lampctrl are not connected or lampctrl has no output signal

    local signals_filtered = {}
    local signal_type_virtual = 'virtual'
    local abs = math.abs

    for _, v in pairs(signals) do
        local signal = v.signal
        signal.type = signal.type or 'item'
        if signal.name and signal.type then
            if signal.type ~= signal_type_virtual then
                -- add item and fluid signals to new array
                signals_filtered[signal] = v.count
            elseif ControlSignals[signal.name] then
                -- read out control signals
                if signal.name == ISDEPOT and v.count > 0 then
                    is_depot = true
                elseif signal.name == DEPOT_PRIORITY then
                    depot_priority = v.count
                elseif signal.name == NETWORKID then
                    network_id = v.count
                elseif signal.name == MINTRAINLENGTH and v.count > 0 then
                    min_carriages = v.count
                elseif signal.name == MAXTRAINLENGTH and v.count > 0 then
                    max_carriages = v.count
                elseif signal.name == MAXTRAINS and v.count > 0 then
                    max_trains = v.count
                elseif signal.name == REQUESTED_THRESHOLD then
                    requesting_threshold = abs(v.count)
                elseif signal.name == REQUESTED_STACK_THRESHOLD then
                    requesting_threshold_stacks = abs(v.count)
                elseif signal.name == REQUESTED_PRIORITY then
                    requester_priority = v.count
                elseif signal.name == NOWARN and v.count > 0 then
                    no_warnings = true
                elseif signal.name == PROVIDED_THRESHOLD then
                    providing_threshold = abs(v.count)
                elseif signal.name == PROVIDED_STACK_THRESHOLD then
                    providing_threshold_stacks = abs(v.count)
                elseif signal.name == PROVIDED_PRIORITY then
                    provider_priority = v.count
                elseif signal.name == LOCKEDSLOTS and v.count > 0 then
                    locked_slots = v.count
                end
            end
        end
    end
    local network_id_string = format('0x%x', band(network_id))

    --update lamp colors when error_code or is_depot changed state
    if stop.error_code ~= 0 or stop.is_depot ~= is_depot then
        stop.error_code = 0 -- we are error free here
        if is_depot then
            if stop.parked_train_id and stop.parked_train.valid then
                if storage.Dispatcher.Deliveries[stop.parked_train_id] then
                    setLamp(stop, 'yellow', 1)
                else
                    setLamp(stop, 'blue', 1)
                end
            else
                setLamp(stop, 'green', 1)
            end
        else
            if #stop.active_deliveries > 0 then
                if stop.parked_train_id and stop.parked_train.valid then
                    setLamp(stop, 'blue', #stop.active_deliveries)
                else
                    setLamp(stop, 'yellow', #stop.active_deliveries)
                end
            else
                setLamp(stop, 'green', 1)
            end
        end
    end

    -- check if it's a depot
    if is_depot then
        stop.is_depot = true
        stop.depot_priority = depot_priority
        stop.network_id = network_id

        -- add parked train to available trains
        if stop.parked_train_id and stop.parked_train.valid then
            if storage.Dispatcher.Deliveries[stop.parked_train_id] then
                if debug_log then
                    log('(UpdateStop) ' .. stop.entity.backer_name .. ' {' .. network_id_string .. '}' ..
                        ', depot priority: ' .. depot_priority ..
                        ', assigned train.id: ' .. stop.parked_train_id)
                end
            else
                if not storage.Dispatcher.availableTrains[stop.parked_train_id] then
                    -- full arrival handling in case ltn-depot signal was turned on with an already parked train
                    TrainArrives(stop.parked_train)
                else
                    -- update properties from depot
                    storage.Dispatcher.availableTrains[stop.parked_train_id].network_id = network_id
                    storage.Dispatcher.availableTrains[stop.parked_train_id].depot_priority = depot_priority
                end
                if debug_log then
                    log('(UpdateStop) ' .. stop.entity.backer_name .. ' {' .. network_id_string .. '}' ..
                        ', depot priority: ' .. depot_priority ..
                        ', available train.id: ' .. stop.parked_train_id)
                end
            end
        else
            if debug_log then
                log('(UpdateStop) ' .. stop.entity.backer_name .. ' {' .. network_id_string .. '}' ..
                    ', depot priority: ' .. depot_priority ..
                    ', no available train')
            end
        end

        -- not a depot > check if the name is unique
    else
        stop.is_depot = false
        if stop.parked_train_id and storage.Dispatcher.availableTrains[stop.parked_train_id] then
            remove_available_train(stop.parked_train_id)
        end

        for signal, count in pairs(signals_filtered) do
            local signal_type = signal.type
            local signal_name = signal.name
            local item = signal_type .. ',' .. signal_name

            for trainID, delivery in pairs(storage.Dispatcher.Deliveries) do
                local deliverycount = delivery.shipment[item]
                if deliverycount then
                    if stop.parked_train and stop.parked_train_id == trainID then
                        -- calculate items +- train inventory
                        local traincount = 0
                        if signal_type == 'fluid' then
                            traincount = stop.parked_train.get_fluid_count(signal_name)
                        else
                            traincount = stop.parked_train.get_item_count(signal_name)
                        end

                        if delivery.to_id == stop.entity.unit_number then
                            local newcount = count + traincount
                            if newcount > 0 then newcount = 0 end --make sure we don't turn it into a provider
                            if debug_log then
                                log('(UpdateStop) ' ..
                                    stop.entity.backer_name ..
                                    ' {' ..
                                    network_id_string ..
                                    '} updating requested count with train ' .. trainID .. ' inventory: ' .. item .. ' ' .. count .. '+' .. traincount ..
                                    '=' .. newcount)
                            end
                            count = newcount
                        elseif delivery.from_id == stop.entity.unit_number then
                            if traincount <= deliverycount then
                                local newcount = count - (deliverycount - traincount)
                                if newcount < 0 then newcount = 0 end --make sure we don't turn it into a request
                                if debug_log then
                                    log('(UpdateStop) ' ..
                                        stop.entity.backer_name ..
                                        ' {' ..
                                        network_id_string ..
                                        '} updating provided count with train ' ..
                                        trainID .. ' inventory: ' .. item .. ' ' .. count .. '-' .. deliverycount - traincount .. '=' .. newcount)
                                end
                                count = newcount
                            else --train loaded more than delivery
                                if debug_log then
                                    log('(UpdateStop) ' ..
                                        stop.entity.backer_name ..
                                        ' {' .. network_id_string ..
                                        '} updating delivery count with overloaded train ' .. trainID .. ' inventory: ' .. item .. ' ' .. traincount)
                                end
                                -- update delivery to new size
                                storage.Dispatcher.Deliveries[trainID].shipment[item] = traincount
                            end
                        end
                    else
                        -- calculate items +- deliveries
                        if delivery.to_id == stop.entity.unit_number then
                            local newcount = count + deliverycount
                            if newcount > 0 then newcount = 0 end --make sure we don't turn it into a provider
                            if debug_log then
                                log('(UpdateStop) ' ..
                                    stop.entity.backer_name ..
                                    ' {' .. network_id_string .. '} updating requested count with delivery: ' .. item ..
                                    ' ' .. count .. '+' .. deliverycount .. '=' .. newcount)
                            end
                            count = newcount
                        elseif delivery.from_id == stop.entity.unit_number and not delivery.pickupDone then
                            local newcount = count - deliverycount
                            if newcount < 0 then newcount = 0 end --make sure we don't turn it into a request
                            if debug_log then
                                log('(UpdateStop) ' ..
                                    stop.entity.backer_name ..
                                    ' {' .. network_id_string .. '} updating provided count with delivery: ' .. item .. ' ' ..
                                    count .. '-' .. deliverycount .. '=' .. newcount)
                            end
                            count = newcount
                        end
                    end
                end
            end -- for delivery

            local useProvideStackThreshold = false
            local useRequestStackThreshold = false
            local stack_count = 0

            if signal_type == 'item' then
                useProvideStackThreshold = providing_threshold_stacks > 0
                useRequestStackThreshold = requesting_threshold_stacks > 0
                if prototypes.item[signal_name] then
                    stack_count = count / prototypes.item[signal_name].stack_size
                end
            end

            -- update Dispatcher Storage
            -- Providers are used when above Provider Threshold
            -- Requests are handled when above Requester Threshold
            if (useProvideStackThreshold and stack_count >= providing_threshold_stacks) or
                (not useProvideStackThreshold and count >= providing_threshold) then
                storage.Dispatcher.Provided[item] = storage.Dispatcher.Provided[item] or {}
                storage.Dispatcher.Provided[item][stopID] = count
                storage.Dispatcher.Provided_by_Stop[stopID] = storage.Dispatcher.Provided_by_Stop[stopID] or {}
                storage.Dispatcher.Provided_by_Stop[stopID][item] = count
                if debug_log then
                    local trainsEnRoute = '';
                    for k, v in pairs(stop.active_deliveries) do
                        trainsEnRoute = trainsEnRoute .. ' ' .. v
                    end
                    log('(UpdateStop) ' ..
                        stop.entity.backer_name ..
                        ' {' ..
                        network_id_string ..
                        '} provides ' ..
                        item ..
                        ' ' ..
                        count ..
                        '(' ..
                        providing_threshold ..
                        ')' ..
                        ' stacks: ' ..
                        stack_count ..
                        '(' ..
                        providing_threshold_stacks ..
                        ')' ..
                        ', priority: ' .. provider_priority .. ', min length: ' ..
                        min_carriages .. ', max length: ' .. max_carriages .. ', trains en route: ' .. trainsEnRoute)
                end
            elseif (useRequestStackThreshold and stack_count * -1 >= requesting_threshold_stacks) or
                (not useRequestStackThreshold and count * -1 >= requesting_threshold) then
                count = count * -1
                local ageIndex = item .. ',' .. stopID
                storage.Dispatcher.RequestAge[ageIndex] = storage.Dispatcher.RequestAge[ageIndex] or game.tick
                storage.Dispatcher.Requests[#storage.Dispatcher.Requests + 1] = {
                    age = storage.Dispatcher.RequestAge[ageIndex],
                    stopID = stopID,
                    priority =
                        requester_priority,
                    item = item,
                    count = count
                }
                storage.Dispatcher.Requests_by_Stop[stopID] = storage.Dispatcher.Requests_by_Stop[stopID] or {}
                storage.Dispatcher.Requests_by_Stop[stopID][item] = count
                if debug_log then
                    local trainsEnRoute = '';
                    for k, v in pairs(stop.active_deliveries) do
                        trainsEnRoute = trainsEnRoute .. ' ' .. v
                    end
                    log('(UpdateStop) ' ..
                        stop.entity.backer_name ..
                        ' {' ..
                        network_id_string ..
                        '} requests ' ..
                        item ..
                        ' ' ..
                        count ..
                        '(' ..
                        requesting_threshold ..
                        ')' ..
                        ' stacks: ' ..
                        tostring(stack_count * -1) ..
                        '(' ..
                        requesting_threshold_stacks ..
                        ')' ..
                        ', priority: ' ..
                        requester_priority ..
                        ', min length: ' ..
                        min_carriages ..
                        ', max length: ' .. max_carriages .. ', age: ' ..
                        storage.Dispatcher.RequestAge[ageIndex] .. '/' .. game.tick .. ', trains en route: ' .. trainsEnRoute)
                end
            end
        end -- for circuitValues

        stop.network_id = network_id
        stop.providing_threshold = providing_threshold
        stop.providing_threshold_stacks = providing_threshold_stacks
        stop.provider_priority = provider_priority
        stop.requesting_threshold = requesting_threshold
        stop.requesting_threshold_stacks = requesting_threshold_stacks
        stop.requester_priority = requester_priority
        stop.min_carriages = min_carriages
        stop.max_carriages = max_carriages
        stop.max_trains = max_trains
        stop.locked_slots = locked_slots
        stop.no_warnings = no_warnings
    end
end

function setLamp(trainStop, color, count)
    -- skip invalid stops and colors
    if trainStop and trainStop.lamp_control.valid and ColorLookup[color] then
        local lampctrl_control = trainStop.lamp_control.get_or_create_control_behavior()
        assert(lampctrl_control)
        assert(lampctrl_control.sections_count == 1)
        lampctrl_control.sections[1].set_slot(1, {
            value = {
                type = 'virtual',
                name = ColorLookup[color],
                quality = 'normal',
            },
            min = count,
        })
        return true
    end
    return false
end

function UpdateStopOutput(trainStop, ignore_existing_cargo)
    -- skip invalid stop outputs
    if not trainStop.output.valid then
        return
    end

    ---@type LogisticFilter[]
    local signals = {}

    if trainStop.parked_train and trainStop.parked_train.valid then
        -- get train composition
        local carriages = trainStop.parked_train.carriages
        local encoded_positions_by_name = {}
        local encoded_positions_by_type = {}

        local train_contents = {}
        for _, item in pairs(trainStop.parked_train.get_contents() or {}) do
            train_contents[item.name] = item
        end
        local inventory = not (ignore_existing_cargo) and train_contents or {}
        local fluidInventory = not (ignore_existing_cargo) and trainStop.parked_train.get_fluid_contents() or {}

        if #carriages < 32 then                       --prevent circuit network integer overflow error
            if trainStop.parked_train_faces_stop then --train faces forwards >> iterate normal
                for i = 1, #carriages do
                    local signal_type = format('ltn-position-any-%s', carriages[i].type)
                    if prototypes.virtual_signal[signal_type] then
                        if encoded_positions_by_type[signal_type] then
                            encoded_positions_by_type[signal_type] = encoded_positions_by_type[signal_type] + 2 ^ (i - 1)
                        else
                            encoded_positions_by_type[signal_type] = 2 ^ (i - 1)
                        end
                    else
                        if message_level >= 1 then printmsg { 'ltn-message.error-invalid-position-signal', signal_type } end
                        log(format('Error: signal \"%s\" not found!', signal_type))
                    end
                    local signal_name = format('ltn-position-%s', carriages[i].name)
                    if prototypes.virtual_signal[signal_name] then
                        if encoded_positions_by_name[signal_name] then
                            encoded_positions_by_name[signal_name] = encoded_positions_by_name[signal_name] + 2 ^ (i - 1)
                        else
                            encoded_positions_by_name[signal_name] = 2 ^ (i - 1)
                        end
                    else
                        if message_level >= 1 then printmsg { 'ltn-message.error-invalid-position-signal', signal_name } end
                        log(format('Error: signal \"%s\" not found!', signal_name))
                    end
                end
            else --train faces backwards >> iterate backwards
                n = 0
                for i = #carriages, 1, -1 do
                    local signal_type = format('ltn-position-any-%s', carriages[i].type)
                    if prototypes.virtual_signal[signal_type] then
                        if encoded_positions_by_type[signal_type] then
                            encoded_positions_by_type[signal_type] = encoded_positions_by_type[signal_type] + 2 ^ n
                        else
                            encoded_positions_by_type[signal_type] = 2 ^ n
                        end
                    else
                        if message_level >= 1 then printmsg { 'ltn-message.error-invalid-position-signal', signal_type } end
                        log(format('Error: signal \"%s\" not found!', signal_type))
                    end
                    local signal_name = format('ltn-position-%s', carriages[i].name)
                    if prototypes.virtual_signal[signal_name] then
                        if encoded_positions_by_name[signal_name] then
                            encoded_positions_by_name[signal_name] = encoded_positions_by_name[signal_name] + 2 ^ n
                        else
                            encoded_positions_by_name[signal_name] = 2 ^ n
                        end
                    else
                        if message_level >= 1 then printmsg { 'ltn-message.error-invalid-position-signal', signal_name } end
                        log(format('Error: signal \"%s\" not found!', signal_name))
                    end
                    n = n + 1
                end
            end

            for k, v in pairs(encoded_positions_by_type) do
                table.insert(signals, { value = { type = 'virtual', name = k, quality = 'normal', }, min = v, })
            end
            for k, v in pairs(encoded_positions_by_name) do
                table.insert(signals, { value = { type = 'virtual', name = k, quality = 'normal', }, min = v, })
            end
        end

        if not trainStop.is_depot then
            -- Update normal stations
            local conditions = trainStop.parked_train.schedule.records[trainStop.parked_train.schedule.current].wait_conditions
            if conditions ~= nil then
                for _, c in pairs(conditions) do
                    if c.condition and c.condition.first_signal then -- loading without mods can make first signal nil?
                        if c.type == 'item_count' then
                            if (c.condition.comparator == '=' and c.condition.constant == 0) then
                                --train expects to be unloaded of each of this item
                                inventory[c.condition.first_signal.name] = nil
                            elseif c.condition.comparator == '≥' then
                                --train expects to be loaded to x of this item
                                inventory[c.condition.first_signal.name] = inventory[c.condition.first_signal.name] or {
                                    name = c.condition.first_signal.name,
                                    quality = 'normal'
                                }
                                inventory[c.condition.first_signal.name].count = c.condition.constant
                            end
                        elseif c.type == 'fluid_count' then
                            if (c.condition.comparator == '=' and c.condition.constant == 0) then
                                --train expects to be unloaded of each of this fluid
                                fluidInventory[c.condition.first_signal.name] = -1
                            elseif c.condition.comparator == '≥' then
                                --train expects to be loaded to x of this fluid
                                fluidInventory[c.condition.first_signal.name] = c.condition.constant
                            end
                        end
                    end
                end
            end

            -- output expected inventory contents
            for k, v in pairs(inventory) do
                table.insert(signals, { value = { type = 'item', name = v.name, quality = v.quality, }, min = v.count, })
            end
            for k, v in pairs(fluidInventory) do
                table.insert(signals, { value = { type = 'fluid', name = v.name, quality = 'normal', }, min = v.count, })
            end
        end -- not trainStop.is_depot
    end
    -- will reset if called with no parked train
    -- log("[LTN] "..tostring(trainStop.entity.backer_name).. " displaying "..#signals.."/"..tostring(trainStop.output.get_control_behavior().signals_count).." signals.")

    local outputControl = trainStop.output.get_control_behavior()
    assert(outputControl)
    assert(outputControl.sections_count == 1)
    local section = outputControl.sections[1]
    section.filters = {}

    local idx = 1
    for _, signal in pairs(signals) do
        section.set_slot(idx, signal)
        idx = idx + 1
    end
end
