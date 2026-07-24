---@meta

--- Runtime resource - client side.
--- Fires per-resource lifecycle events when any resource starts or stops on the client,
--- notifies the server that this client is ready for the started resource,
--- and exposes a helper to query the server-side dependency graph.

--- Trigger the resource-specific client start event and signal the server.
---@param resourceName string
AddEventHandler('onClientResourceStart', function(resourceName)
    TriggerEvent(resourceName .. ':clientStart')
    TriggerServerEvent(resourceName .. ':ready')
end)

--- Trigger the resource-specific client stop event.
---@param resourceName string
AddEventHandler('onClientResourceStop', function(resourceName)
    TriggerEvent(resourceName .. ':clientStop')
end)

--- Request the dependency graph info for a resource from the server.
--- Returns a table with `dependencies`, `dependents`, and `dependentChain` arrays.
---@param resourceName string
---@return { dependencies: string[], dependents: string[], dependentChain: string[] }
exports('getDependencies', function(resourceName)
    return lib.callback.await('runtime:getDependencies', false, resourceName)
end)
