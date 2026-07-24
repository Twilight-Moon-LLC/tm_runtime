# runtime

Manages resource **lifecycle events** and the server-side **dependency graph**.

Two responsibilities are unified here:

1. **Lifecycle events** — fires `<name>:start`, `<name>:stop`, `<name>:clientStart`, `<name>:clientStop`, and `<name>:ready` so every resource can react to its own (or any other) resource's state changes without polling.
2. **Dependency graph** — parses every resource's `fxmanifest.lua` at boot and on each start/stop, then cascade-stops and auto-restarts dependents when a shared dependency changes state.

---

## Lifecycle events

### Server events

| Event | Fired when |
|---|---|
| `<name>:start` | A resource starts on the server |
| `<name>:stop` | A resource stops on the server |

```lua
AddEventHandler('vehicles:start', function()
    -- vehicles just started on the server
end)
```

### Client events

| Event | Fired when |
|---|---|
| `<name>:clientStart` | A resource starts on the client |
| `<name>:clientStop` | A resource stops on the client |

```lua
AddEventHandler('vehicles:clientStart', function()
    -- vehicles just started on this client
end)
```

### Server event — client ready

| Event | Fired when |
|---|---|
| `<name>:ready` | A client signals the server that the resource is ready (via `TriggerServerEvent`) |

---

## Server exports

### `getDependencies(resourceName)`
Returns the direct dependencies declared in `resourceName`'s `fxmanifest.lua`.

```lua
local runtimeExports = utils.exports.get('runtime')
local deps = runtimeExports:getDependencies('vehicles')
-- { 'ox_lib', 'utils', 'inventory', ... }
```

### `getDependents(resourceName)`
Returns resources that **directly** declare `resourceName` as a dependency.

```lua
local dependents = runtimeExports:getDependents('utils')
```

### `getDependentChain(resourceName)`
Returns the full **transitive** dependent chain (BFS, deduplicated).  
Useful for calculating the blast-radius before stopping a resource.

```lua
local chain = runtimeExports:getDependentChain('utils')
```

### `rescan(resourceName)`
Force a re-read of a resource's `fxmanifest.lua` and rebuild its graph entries.  
Useful after hot-swapping a resource with changed dependencies.

```lua
runtimeExports:rescan('vehicles')
```

### `rescanAll()`
Rebuild the entire dependency graph from scratch by rescanning every started resource.

```lua
runtimeExports:rescanAll()
```

### `isCascadeStopped(resourceName)`
Returns `true` if the runtime has flagged this resource as cascade-stopped (i.e. stopped because a dependency went down). Used internally to know whether to auto-restart.

```lua
local flagged = runtimeExports:isCascadeStopped('vehicles')
```

---

## Client exports

### `getDependencies(resourceName)`
Async request to the server for the dependency info for a given resource.  
Returns a table with three arrays.

```lua
-- client-side
local runtimeExports = utils.exports.get('runtime')
local info = runtimeExports:getDependencies('vehicles')
-- info.dependencies    -- direct deps
-- info.dependents      -- direct dependents
-- info.dependentChain  -- full transitive chain
```

---

## Cascade behaviour

When a resource stops, the runtime:

1. Walks the reverse-dependency graph (BFS) to find every transitive dependent.
2. Stops them deepest-first and marks them as `stoppedByUs`.
3. When the original resource starts again, attempts to restart all cascade-stopped resources once all their dependencies are satisfied.
4. If a blocking dependency is still `starting`, retries automatically after 500 ms.

This means you rarely need to manually restart dependent resources after restarting a library like `utils` or `ox_lib`.

---

## Notes

- `runtime` must start **before** any resource that relies on `:start` / `:stop` events or the dependency graph.
- The dependency graph is seeded at boot for every resource that is already running.
- Intentionally keeps `deps[resourceName]` intact after a stop so the restart logic can still read it.
