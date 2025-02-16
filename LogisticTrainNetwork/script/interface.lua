--[[ Copyright (c) 2017 Optera
 * Part of Logistics Train Network
 *
 * See LICENSE.md in the project directory for license information.
--]]

on_stops_updated_event = script.generate_event_name()
on_dispatcher_updated_event = script.generate_event_name()
on_dispatcher_no_train_found_event = script.generate_event_name()
on_delivery_created_event = script.generate_event_name()
on_delivery_pickup_complete_event = script.generate_event_name()
on_delivery_completed_event = script.generate_event_name()
on_delivery_failed_event = script.generate_event_name()

on_provider_missing_cargo_alert = script.generate_event_name()
on_provider_unscheduled_cargo_alert = script.generate_event_name()
on_requester_unscheduled_cargo_alert = script.generate_event_name()
on_requester_remaining_cargo_alert = script.generate_event_name()

-- ltn_interface allows mods to register for update events
remote.add_interface('logistic-train-network', {
    -- updates for ltn_stops
    on_stops_updated = function() return on_stops_updated_event end,

    -- updates for dispatcher
    on_dispatcher_updated = function() return on_dispatcher_updated_event end,
    on_dispatcher_no_train_found = function() return on_dispatcher_no_train_found_event end,
    on_delivery_created = function() return on_delivery_created_event end,

    -- update for updated deliveries after leaving provider
    on_delivery_pickup_complete = function() return on_delivery_pickup_complete_event end,

    -- update for completing deliveries
    on_delivery_completed = function() return on_delivery_completed_event end,
    on_delivery_failed = function() return on_delivery_failed_event end,

    -- alerts
    on_provider_missing_cargo = function() return on_provider_missing_cargo_alert end,
    on_provider_unscheduled_cargo = function() return on_provider_unscheduled_cargo_alert end,
    on_requester_unscheduled_cargo = function() return on_requester_unscheduled_cargo_alert end,
    on_requester_remaining_cargo = function() return on_requester_remaining_cargo_alert end,

    -- surface connections
    connect_surfaces = ConnectSurfaces,     -- function(entity1 :: LuaEntity, entity2 :: LuaEntity, network_id :: int32)
    disconnect_surfaces = DisconnectSurfaces, -- function(entity1 :: LuaEntity, entity2 :: LuaEntity)
    clear_all_surface_connections = ClearAllSurfaceConnections,

    -- Re-assigns a delivery to a different train.
    reassign_delivery = ReassignDelivery,                 -- function(old_train_id :: uint, new_train :: LuaTrain) :: bool
    get_or_create_next_temp_stop = GetOrCreateNextTempStop, -- function(train :: LuaTrain, schedule_index :: uint?) :: uint
    get_next_logistic_stop = GetNextLogisticStop,         -- function(train :: LuaTrain, schedule_index :: uint?) :: uint?, uint?, string?
})


--[[ register events from LTN:
if remote.interfaces["logistic-train-network"] then
  script.on_event(remote.call("logistic-train-network", "on_stops_updated"), on_stops_updated)
  script.on_event(remote.call("logistic-train-network", "on_dispatcher_updated"), on_dispatcher_updated)
end
]] --


--[[ EVENTS
on_stops_updated
Raised every UpdateInterval, after delivery generation
-> Contains:
logistic_train_stops = { [stop_id :: uint], {
    -- stop data
    active_deliveries :: int,
    entity :: LuaEntity,
    input :: LuaEntity,
    output :: LuaEntity,
    lamp_control :: LuaEntity,
    error_code :: int,

    -- control signals
    is_depot :: bool,
    depot_priority :: int32,
    network_id :: int32,
    max_carriages :: int32,
    min_carriages :: int32,
    max_trains :: int32,
    providing_threshold :: int32,
    providing_threshold_stacks :: int32,
    provider_priority :: int32,
    requesting_threshold :: int32,
    requesting_threshold_stacks :: int32,
    requester_priority :: int32,
    locked_slots :: int32,
    no_warnings :: bool,

    -- parked train data
    parked_train :: LuaTrain,
    parked_train_id :: uint,
    parked_train_faces_stop :: bool,
}}


on_dispatcher_updated
Raised every UpdateInterval, after delivery generation
-> Contains:
  update_interval = int -- time in ticks LTN needed to run all updates, varies depending on number of stops and requests
  provided_by_stop = { [stop_id :: uint], { [item :: string], count :: int } }
  requests_by_stop = { [stop_id :: uint], { [item :: string], count :: int } }
  new_deliveries = { uint } -- train_ids of deliveries created this UpdateInterval
  deliveries = { [train_id :: uint], {
    force :: LuaForce,
    train :: LuaTrain,
    from :: string,
    from_id :: uint,
    to :: string,
    to_id :: uint,
    network_id: int32,
    started :: uint, -- tick this delivery was created on
    surface_connections = { entity1 :: LuaEntity, entity2 :: LuaEntity, network_id :: int32 },
    shipment = { [item :: string], count :: int }
  } }
  available_trains = { [train_id :: uint], {
    capacity :: int,
    fluid_capacity :: int,
    force :: LuaForce,
    surface :: LuaSurface,
    depot_priority :: int32,
    network_id :: int32,
    train :: LuaTrain
  } }


on_dispatcher_no_train_found
Raised when no train was found to handle a request
-> Contains:
  to :: string -- requester.backer_name
  to_id :: uint -- requester.unit_number
  network_id :: int32
  (optional) item :: string
  (optional) from :: string
  (optional) from_id :: uint
  (optional) min_carriages :: int32
  (optional) max_carriages :: int32
  (optional) shipment = { [item :: string], count :: int }


on_delivery_pickup_complete
Raised when a train leaves provider stop
-> Contains:
  train_id :: uint
  train :: LuaTrain
  planned_shipment= { [item :: string], count :: int }
  actual_shipment = { [item :: string], count :: int } -- shipment updated to train inventory


on_delivery_completed
Raised when train leaves requester stop
-> Contains:
  train_id :: uint
  train :: LuaTrain
  shipment= { [item :: string], count :: int }


on_delivery_failed
Raised when rolling stock of a train gets removed, the delivery timed out, train enters depot stop with active delivery
-> Contains:
  train_id :: uint
  shipment= { [item :: string], count :: int } }


----  Alerts ----

on_dispatcher_no_train_found
Raised when depot was empty
-> Contains:
  to :: string
  to_id :: uint
  network_id :: int32
  item :: string -- <type,name>

on_dispatcher_no_train_found
Raised when no matching train was found
-> Contains:
  to :: string
  to_id :: uint
  network_id :: int32
  from :: string
  from_id :: uint
  min_carriages :: int32
  max_carriages :: int32
  shipment = { [item :: string], count :: int } }

on_provider_missing_cargo
Raised when trains leave provider with less than planned load
-> Contains:
  train :: LuaTrain
  station :: LuaEntity
  planned_shipment = { [item :: string], count :: int } }
  actual_shipment = { [item :: string], count :: int } }

on_provider_unscheduled_cargo
Raised when trains leave provider with wrong cargo
-> Contains:
  train :: LuaTrain
  station :: LuaEntity
  planned_shipment = { [item :: string], count :: int } }
  unscheduled_load = { [item :: string], count :: int } }

on_requester_unscheduled_cargo
Raised when trains arrive at requester with wrong cargo
-> Contains:
  train :: LuaTrain
  station :: LuaEntity
  planned_shipment = { [item :: string], count :: int } }
  unscheduled_load = { [item :: string], count :: int } }

on_requester_remaining_cargo
Raised when trains leave requester with remaining cargo
-> Contains:
  train :: LuaTrain
  station :: LuaEntity
  remaining_load = { [item :: string], count :: int } }

--]]

--[[ REMOTE CALLS

usage:
if remote.interfaces["logistic-train-network"] then
  remote.call("logistic-train-network", "<name>", <parameters>?)
end

connect_surfaces(entity1 :: LuaEntity, entity2 :: LuaEntity, network_id :: int32)
  Designates two entities on different surfaces as forming a surface connection.
  Connections are bi-directional but not transitive, i.e. surface A -> B implies B -> A, but A -> B and B -> C does not imply A -> C.
  LTN will generate deliveries between depot and provider on one surface and requester on the other.
  Network_id acts as additional mask for potential providers.
  It is the caller's responsibility to ensure:
  1) trains are moved between surfaces
  2) deliveries are updated to the new train after surface transition, see reassign_delivery()
  3) trains return to their original surface depot

disconnect_surfaces(entity1 :: LuaEntity, entity2 :: LuaEntity)
  Removes a surface connection formed by the two given entities.
  Active deliveries will not be affected.
  It's not necessary to call this function when deleting one or both entities.

clear_all_surface_connections()
  Clears all surface connections.
  Active deliveries will not be affected
  This function exists for debugging purposes, no event is raised to notify connection owners.

reassign_delivery(old_train_id :: uint, new_train :: LuaTrain) :: bool
  Re-assigns a delivery to a different train.
  Should be called after creating a train based on another train, for example after moving a train to a different surface.
  Calls with an old_train_id without delivery have no effect.
  Don't call this function when coupling trains via script, LTN already handles that through Factorio events.
  This function does not add missing temp stops. See get_or_create_next_temp_stop for that.

get_or_create_next_temp_stop(train :: LuaTrain, schedule_index :: uint?) :: uint
  Ensures the next logistic stop in the schedule has a temporary stop if it is on the same surface as the train.
  If no schedule_index is given, the search for the next logistic stop starts from train.schedule.current
  In case the train is currently stopping at that index, the search starts at the next higher index.
  The result will be the schedule index of the temp stop of the next logistic stop or nil if there is no further logistic stop.

get_next_logistic_stop(train :: LuaTrain, schedule_index :: uint?) :: uint?, uint?, string?
  Finds the next logistic stop in the schedule of the given train.
  If no schedule_index is given, the search starts from train.schedule.current.
  In case the train is currently stopping at that index, the search starts at the next higher index.
  The result will be three values stop_schedule_index, stop_id and either the string "provider" or "requester".
  If there is no further logistic stop in the schedule, the result will be nil.

--]]
