---@meta

--- Runtime resource - server side.
--- Handles resource lifecycle events and dependency graph management.
--- Cascades stop/restart sequences when a dependency changes state,
--- and fires per-resource `<name>:start` / `<name>:stop` events so
--- other resources can react to their own (or any) resource's lifecycle.

--- forward index:  deps[resource]   = { dep, ... }
--- reverse index:  dependents[dep]  = { resource, ... }
--- tracks resources we cascade-stopped so we can restart them once all deps recover

---@type table<string, string[]>
local deps = {}

---@type table<string, string[]>
local dependents = {}

---@type table<string, boolean>
local stoppedByUs = {}

--- Tracks resources that should be restarted without cascading to dependents.
--- Set by `restartsingle` before calling StopResource; consumed in onResourceStop.
---@type table<string, boolean>
local skipCascade = {}

--- Parse a resource's fxmanifest.lua to extract its declared dependencies.
--- Runs the manifest in a sandboxed Lua environment.
--- Entries starting with '/' (e.g. /server:xxxx, /onesync) are ignored.
---@param resourceName string
---@return string[]
local function readManifestDeps(resourceName)
    local path = GetResourcePath(resourceName)
    if not path or path == '' then return {} end

    local f = io.open(path .. '/fxmanifest.lua', 'r')
           or io.open(path .. '/__resource.lua', 'r')
    if not f then return {} end

    local src = f:read('*a')
    f:close()

    local result = {}
    local seen   = {}

    --- Add a dependency string if it is valid and not yet recorded.
    ---@param dep string
    local function add(dep)
        if type(dep) == 'string' and dep:sub(1, 1) ~= '/' and not seen[dep] then
            seen[dep]          = true
            result[#result + 1] = dep
        end
    end

    -- Minimal sandbox: only `dependency` and `dependencies` calls are honoured;
    -- every other key returns a no-op function so the manifest executes cleanly.
    local env = setmetatable({
        dependency   = add,
        dependencies = function(t)
            if type(t) == 'table' then
                for _, v in ipairs(t) do add(v) end
            end
        end,
    }, { __index = function() return function() end end })

    local chunk = load(src, resourceName .. ':fxmanifest', 't', env)
    if chunk then pcall(chunk) end

    return result
end

--- Collect dependency metadata for a resource and update both lookup tables.
--- Clears stale reverse-index entries before rebuilding.
---@param resourceName string
local function indexDependencies(resourceName)
    -- Remove old reverse-index entries so a restart with changed deps is clean
    if deps[resourceName] then
        for _, dep in ipairs(deps[resourceName]) do
            local list = dependents[dep]
            if list then
                for i = #list, 1, -1 do
                    if list[i] == resourceName then
                        table.remove(list, i)
                    end
                end
            end
        end
    end

    local collected = readManifestDeps(resourceName)
    deps[resourceName] = collected

    for _, dep in ipairs(collected) do
        if not dependents[dep] then
            dependents[dep] = {}
        end

        -- Avoid duplicate entries in the reverse index
        local exists = false
        for _, v in ipairs(dependents[dep]) do
            if v == resourceName then exists = true; break end
        end

        if not exists then
            dependents[dep][#dependents[dep] + 1] = resourceName
        end
    end
end

--- Warn about any declared dependencies that are not present on the server.
---@param resourceName string
local function warnMissingDeps(resourceName)
    for _, dep in ipairs(deps[resourceName] or {}) do
        if GetResourceState(dep) == 'missing' then
            print(('[runtime] %s dependency "%s" is missing'):format(resourceName, dep))
        end
    end
end

--- BFS over the reverse-dependency graph to collect every resource
--- that (transitively) depends on `resourceName`, deduplicated.
---@param resourceName string
---@return string[]
local function getDependentChain(resourceName)
    local visited = {}
    local chain   = {}
    local queue   = { resourceName }

    while #queue > 0 do
        local current  = table.remove(queue, 1)
        local children = dependents[current]

        if children then
            for _, child in ipairs(children) do
                if not visited[child] then
                    visited[child]     = true
                    chain[#chain + 1]  = child
                    queue[#queue + 1]  = child
                end
            end
        end
    end

    return chain
end

--- Restart any cascade-stopped resources whose full dependency list is now satisfied.
--- Calls itself again via SetTimeout when a blocking dep is still starting.
local function tryRestartCascaded()
    local retryNeeded = false

    for dependent in pairs(stoppedByUs) do
        local state = GetResourceState(dependent)

        if state ~= 'stopped' then
            -- Already started (or gone) – clear the flag
            stoppedByUs[dependent] = nil
        else
            local allDepsUp        = true
            local blockedBy        = nil
            local blockedByStarting = false

            for _, dep in ipairs(deps[dependent] or {}) do
                local depState = GetResourceState(dep)
                if depState ~= 'started' then
                    allDepsUp  = false
                    blockedBy  = ('%s(%s)'):format(dep, depState)
                    if depState == 'starting' then
                        blockedByStarting = true
                    end
                    break
                end
            end

            if allDepsUp then
                stoppedByUs[dependent] = nil
                print(('[runtime] restarting %s (all deps satisfied)'):format(dependent))
                StartResource(dependent)
            elseif blockedByStarting then
                retryNeeded = true
            else
                print(('[runtime] cannot restart %s yet; waiting on %s'):format(dependent, blockedBy))
            end
        end
    end

    if retryNeeded then
        SetTimeout(500, tryRestartCascaded)
    end
end

--[[ Exports ]] --

--- Get the direct dependencies declared in a resource's fxmanifest.
--- Returns a shallow copy of the internal array so callers cannot mutate the graph.
---@param resourceName string
---@return string[]
exports('getDependencies', function(resourceName)
    local result = {}
    for _, v in ipairs(deps[resourceName] or {}) do
        result[#result + 1] = v
    end
    return result
end)

--- Get the direct dependents of a resource – i.e. resources that declare it as a dependency.
--- Returns a shallow copy of the internal array.
---@param resourceName string
---@return string[]
exports('getDependents', function(resourceName)
    local result = {}
    for _, v in ipairs(dependents[resourceName] or {}) do
        result[#result + 1] = v
    end
    return result
end)

--- Get the full transitive dependent chain for a resource (BFS, deduplicated).
--- Useful for determining the blast-radius of stopping a resource.
---@param resourceName string
---@return string[]
exports('getDependentChain', function(resourceName)
    return getDependentChain(resourceName)
end)

--- Force a rescan of a resource's fxmanifest dependencies and rebuild the graph indexes.
--- Useful after a resource has been hot-swapped with changed dependencies.
---@param resourceName string
exports('rescan', function(resourceName)
    indexDependencies(resourceName)
    print(('[runtime] rescanned %s | deps=[%s]'):format(
        resourceName,
        table.concat(deps[resourceName] or {}, ', ')
    ))
end)

--- Force a rescan of every currently started resource.
--- Re-builds the entire dependency graph from scratch.
exports('rescanAll', function()
    -- Reset both indexes first so stale entries don't survive
    deps       = {}
    dependents = {}

    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if name and GetResourceState(name) == 'started' then
            indexDependencies(name)
        end
    end

    print('[runtime] full dependency graph rescan complete')
end)

--- Check whether a resource is currently flagged as cascade-stopped by the runtime.
---@param resourceName string
---@return boolean
exports('isCascadeStopped', function(resourceName)
    return stoppedByUs[resourceName] == true
end)

--[[ Callbacks ]] --

--- Allow any server-side resource to request the dependency info for a given resource.
---@param source      number  (injected by lib.callback)
---@param resourceName string
lib.callback.register('runtime:getDependencies', function(source, resourceName)
    return {
        dependencies   = deps[resourceName] or {},
        dependents     = dependents[resourceName] or {},
        dependentChain = getDependentChain(resourceName),
    }
end)

--- Seed the dependency graph for every resource already running at boot.
CreateThread(function()
    for i = 0, GetNumResources() - 1 do
        local name = GetResourceByFindIndex(i)
        if name and GetResourceState(name) == 'started' then
            indexDependencies(name)
        end
    end
end)

--- Handle resource start: index deps, warn about missing ones, then fire the lifecycle event.
---@param resourceName string
AddEventHandler('onResourceStart', function(resourceName)
    indexDependencies(resourceName)
    warnMissingDeps(resourceName)

    print(('[runtime:start] %s | stoppedByUs=%s | dependents=%s'):format(
        resourceName,
        stoppedByUs[resourceName] and 'true' or 'false',
        dependents[resourceName] and table.concat(dependents[resourceName], ', ') or 'none'
    ))

    -- Clear the cascade-stop flag now that this resource is back up
    stoppedByUs[resourceName] = nil

    -- Attempt to restore any cascade-stopped resources now that a dep has recovered
    tryRestartCascaded()

    -- Fire the resource-specific start event
    TriggerEvent(resourceName .. ':start')
end)

--- Handle resource stop: cascade-stop dependents, then fire the lifecycle event.
--- Intentionally keeps `deps[resourceName]` intact so tryRestartCascaded can
--- read it after the resource restarts.
--- If `skipCascade[resourceName]` is set, the cascade is skipped and the resource
--- is automatically restarted after a short delay (used by `restartsingle`).
---@param resourceName string
AddEventHandler('onResourceStop', function(resourceName)
    -- Single-restart mode: skip cascade and auto-start after a brief delay
    if skipCascade[resourceName] then
        skipCascade[resourceName] = nil
        print(('[runtime] %s stopped for single restart; skipping cascade'):format(resourceName))
        TriggerEvent(resourceName .. ':stop')
        SetTimeout(100, function()
            print(('[runtime] restartsingle: starting %s'):format(resourceName))
            StartResource(resourceName)
        end)
        return
    end

    warnMissingDeps(resourceName)

    local chain = getDependentChain(resourceName)
    print(('[runtime:stop] %s | chain=[%s] | myDeps=[%s]'):format(
        resourceName,
        table.concat(chain, ', '),
        table.concat(deps[resourceName] or {}, ', ')
    ))

    -- Self-register: if any of our own deps are stopped/stopping, FiveM cascade-stopped us
    for _, dep in ipairs(deps[resourceName] or {}) do
        local depState = GetResourceState(dep)
        if depState == 'stopped' or depState == 'stopping' then
            print(('[runtime] marking %s -> stoppedByUs (dep %s is %s)'):format(resourceName, dep, depState))
            stoppedByUs[resourceName] = true
            break
        end
    end

    -- Cascade-stop all dependents deepest-first; also mark already-stopped ones
    for i = #chain, 1, -1 do
        local dependent = chain[i]
        local state     = GetResourceState(dependent)

        if state == 'started' then
            print(('[runtime] marking %s -> stoppedByUs (stopping due to %s)'):format(dependent, resourceName))
            stoppedByUs[dependent] = true
            StopResource(dependent)
        elseif state == 'stopped' or state == 'stopping' then
            print(('[runtime] marking %s -> stoppedByUs (already %s, dep %s)'):format(dependent, state, resourceName))
            stoppedByUs[dependent] = true
        end
    end

    -- Fire the resource-specific stop event
    TriggerEvent(resourceName .. ':stop')
end)

--[[ Commands ]] --


--- Restart a single resource without cascade-stopping its dependents.
--- Useful for refreshing a library resource without bringing down everything that depends on it.
RegisterCommand('restartsingle', function(source, args, rawCommand, cb)
    local resourceName = args[1]

    if not resourceName or resourceName == '' then
        cb('error', 'Usage: /restartsingle <resource>')
        return
    end

    local state = GetResourceState(resourceName)
    if state ~= 'started' then
        cb('error', ('Resource "%s" is not started (state: %s)'):format(resourceName, state))
        return
    end

    -- Flag this resource to skip cascade logic in onResourceStop
    skipCascade[resourceName] = true
    StopResource(resourceName)

    print(('Restarting %s (dependents will not be affected)'):format(resourceName))
end, true)
