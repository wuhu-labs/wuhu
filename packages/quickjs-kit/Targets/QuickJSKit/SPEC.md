# QuickJSKit

A Swift wrapper around [quickjs-ng](https://github.com/quickjs-ng/quickjs). One
`JSEngine` owns one QuickJS runtime and one context; values cross the boundary
as `JSONValue`.

## Confinement

`JSEngine` is not `Sendable`. A context must be entered from one isolation
domain at a time — hold the engine inside an actor, or keep it local to a single
task. `Interrupter` is the only `Sendable` part of the surface and is the only
member callable from another domain.

Every re-entry into JS calls `JS_UpdateStackTop`, so an engine survives a task
resuming on a different thread. The default stack budget is 256 KiB rather than
QuickJS's own default, which exceeds the stack of a Swift concurrency worker
thread: a runaway recursion must hit the QuickJS limit before it hits the real
stack.

`run` is not reentrant. Calling it while another `run` is in flight traps.

## Value mapping

| JS | Swift |
|---|---|
| `null`, `undefined` | `.null` |
| boolean | `.bool` |
| number with an int32 representation | `.integer` |
| any other number | `.number` |
| string | `.string` |
| array | `.array` |
| plain object (own enumerable string keys, insertion order) | `.object` |
| function, symbol, bigint, promise | `JSError.unsupportedValue` |

`.integer` and `.number` both become JS numbers; the distinction does not
survive a round trip through JS arithmetic. Object key order is JS property
order, preserved by `OrderedDictionary`. Values nested deeper than 128 levels —
including cycles — are rejected rather than walked.

## Evaluation

- `evaluate` runs a script and bridges its completion value. It pumps no jobs:
  a promise created by the script stays pending.
- `execute` runs a script for effect and discards the completion value. This is
  the prelude entry point — a prelude's last statement is usually an assignment,
  whose value has no JSON shape.
- `run` evaluates with top-level `await` enabled and drives the script to
  completion: pending jobs are drained, host promises are awaited, and the
  results are settled back into JS until nothing is left to do.
- `run(module:)` evaluates an ES module the same way and returns nothing. `meta` becomes properties of the module's `import.meta`.

A script that ends still awaiting something no host call will settle fails with
`JSError.stalled`. An exception raised inside a job that never reaches the
script's own promise is reported instead of `stalled` when the script stalls.

A module's rejection ends its run at once: host calls still in flight are cancelled, not awaited. A script's rejection is reported only once nothing is left in flight.

Cancelling the task that awaits `run` ends it with `CancellationError` once the host calls in flight have observed the cancellation. To stop JS that is busy rather than waiting, interrupt it as well (see Limits).

## Modules

`defineModule` evaluates a module under a name, at once. From then on any module of the engine imports it by that exact name. Its body runs to the end synchronously: a module that awaits fails with `JSError.stalled`. Because it runs at definition time, it can capture host globals that a later prelude deletes.

Without a loader, importing any other name fails with `ReferenceError: could not load module '<name>'`.

`run(module:loader:)` takes a `ModuleLoader` for every other import. `resolve(specifier, referrer)` turns an import specifier into a module name, given the name of the importing module (the entry's name is `run`'s `name`); a defined module's name never reaches it. `source(name)` supplies a module's text. The loader walks the whole static import graph before anything runs: each name is resolved and fetched once, the fetches for one level of the graph run concurrently, and nothing is evaluated until every source has arrived. Each module is instantiated once per run, so cycles behave as ES modules specify. Imported modules share the entry's realm and get the same `import.meta`.

A graph with more than `maxModules` names is refused before the first name over the limit is fetched. When an imported module fails to resolve, fetch or compile, the run fails with a message that starts with the import chain, as in `script → lib:a → lib:b: no such module`. The entry's own syntax errors keep their plain message.

With a loader, `import()` is refused for every specifier: it rejects with `import() is not supported; import '<specifier>' statically`.

## Release

`run` returns once no host call that keeps the run alive is in flight and no job is pending. Nothing else can wake JS after that, so an open handle a script still holds — an iterator it never finished — does not delay the release.

A `promising` host function defined with `keepsAlive: false` does not hold the run open. When the run is released, such calls are cancelled and their promises never settle. This is how an embedder waits for an event that may never happen, such as an abort request from outside.

`defineCancel` installs a synchronous `name(promise, reason)`. If `promise` came from a `promising` host call still in flight, the Swift body is cancelled, the promise is rejected with `reason` (any JS value, passed through untouched), and the call returns `true`. It no longer holds the run open. Otherwise it returns `false`.

## Host functions

`define` installs a function on `globalThis`. Object graphs (`game.emit(…)`) are
the embedder's job — build them in a prelude over the flat globals.

A synchronous host function returns to JS directly. A `promising` host function
returns a promise: the Swift body is scheduled, `run` awaits it, and the promise
settles with the result. Bodies scheduled during the same pump run concurrently,
so `Promise.all` over several host calls really does overlap them.

A Swift error thrown by a host function becomes a JS `Error` whose `message` is
`String(describing:)` of the error, except for `JSError.exception`, which passes
its message through unchanged. Nothing else about the Swift error survives.

## Limits

`memoryBytes` and `stackBytes` map to `JS_SetMemoryLimit` and
`JS_SetMaxStackSize`. `stepBudget` counts QuickJS interrupt ticks — a coarse,
deterministic, clock-free bound on how long a script may run before it is
terminated. It is refreshed on every entry point. Wall-clock deadlines belong to
the embedder: drive an `Interrupter` from a clock dependency.

Termination — by budget or by `Interrupter` — is reported as `JSError.terminated`
and is not catchable from JS. A run waiting on host calls notices an interrupt when the next call completes.
