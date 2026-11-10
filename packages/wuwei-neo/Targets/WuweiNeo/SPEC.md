# WuweiNeo

Durable addressables over one SQLite file, on one of two backends. Layered (`Storage.layered(FileDatabase)`): each addressable has a SQLite database of its own, whose pages live as rows of the outer file. Shared (`Storage.shared(any SharedDatabase)`): every addressable's tables live in the outer database itself, which a host program may own (Wuhu lends `space.sqlite`). Code written against one runs on the other; the suite runs on both.

## Addressables

- An addressable type has a `kind`, a `Message` type and a `schema`, applied once per statement and tracked by `PRAGMA user_version` (layered) or the `wuwei_schema` ledger (shared, applied when the worker starts). Its address is `kind/key`.
- A table whose `owner` column is `Addressable.ownerColumn` (`DEFAULT (cell())`) is owned: a row belongs to the addressable whose step wrote it, and `cell()` is that addressable's key on every connection the runtime prepares (`prepareConnection`). A read keeps to its own rows with `WHERE owner = cell()`, or with `WuweiNeoQueries`' `Owned` default scope; on the shared backend, a statement writing another addressable's row aborts (TEMP triggers). Without an owner column, a table on the shared backend is common to every addressable of the kind.
- A cell is a struct marked `@Cell`. Every mutating method that is not private is a message: synchronous, returning nothing, its parameters plain Codable values. The macro adds the stored `_context` with its `init`, a private `ctx` over it with `db` and `id`, `kind` (the type's name unless declared), `Message`, `receive` and `Sender`. One delivery is one call and one durable step: a throw rolls back everything the call wrote, sent and emitted (the mail is still consumed). A nonmutating method is a read; `cell(_:)` gives anyone a read handle at the durable snapshot, whose writes trap. `job(_:)` does the same for a job, whose handle has its database and nothing else. `exists(_:)` (on the worker and a cell's `ctx`) says whether a job was ever created. A cell reaches other addressables only by mail, `ctx.send(id).method(…)`, and its only outputs are `emit`s, best-effort, released once the call's writes are durable. An idle cell is evicted after `cellIdle` and gives up its lease.
- A cell has no alarm to set: its `nextWake()`, a read over its own tables (nil by default), says when it wants `wake()`, a call like a message but never mail (`@Cell` leaves `wake()` out of `Message`). The runtime reads it at the end of every call, inside that call's step, records it in `wuwei_addressable.wake_at` with the step and arms an in-process timer; the scan finds a cell that was evicted or lost its holder, and a boot arms the recorded time, so one that passed while nobody held the cell wakes it at once. A wake that commits must move `nextWake()` past the time it ran, or the process traps; one that throws is tried again after `retryDelay`.
- A job is a struct marked `@Job`, which adds `_context`, a private `ctx` with `db` and `id`, `kind`, and a private `state` over `ctx.state` when it declares a `State`. It runs the static `create(ctx:)` once, in its first epoch; `hydrate` on every boot, building its in-memory `State`; and its mutating `start()`, the long task, rerun from the top after every failover. `start` returns `.done` (the job row and its tables stay as a tombstone, readable through `job(_:)`, so creating it again does nothing; `.done(sending:to:)` commits a last message with it), `.notDone` (run `start` again after `retryDelay`; a throw means the same) or `.hibernate(until:)` (drop the instance and its state, keep the lease, wake on mail or at that time).
- `JobContext` is not `Sendable`: `db`, `params`, `state`, `send`, `create`, `cell`, `job`, `receive(within:)`, `sleep`, `effect`, and `race(body, until:)`: `body` runs as an effect unless a message for which `until` holds arrives first, which cancels and awaits `body` (other messages are taken and handed to `body` as a stream). A child task of `start` gets `effects` (Sendable: `effect`, `dependency`, `now`). An effect traps when used from a task the runtime did not start, or after the `start` it came from returned.
- `start` is `nonisolated(nonsending)`, so a module defining jobs builds with `NonisolatedNonsendingByDefault`. Behind both contexts is one actor per incarnation on the addressable's lane, which code never sees.
- A cell's `Database`: `rows` and `one` run only read-only statements, `execute` is `mutating` and throws only `ConstraintViolation`; a statement that cannot run traps, as does a failing disk. A job's `JobDatabase` reads the same way, and a write the disk fails ends the incarnation and throws `Evicted`.

## Storage

- The outer file runs in WAL mode and holds `wuwei_addressable` (id, lease holder, fence, expiry, page count, a cell's wake time), `wuwei_pages` (keyed `id << 32 | page number`, layered only), `wuwei_mail`, `wuwei_job` and `wuwei_schema`. A host owning the database creates them itself (`FileDatabase.schema` lists them).
- Layered: an inner database runs on the `wuwei-neo` VFS with `journal_mode = MEMORY` and exclusive locking. Its writes collect in memory until a seal, as below.
- Shared: every step (a call, a stretch of `start` between awaits) is one transaction on the shared writer, committed when it returns; there are no epochs, and an output waits only for that commit. Reads go to a reader connection, except those a cell or job makes during its own step (read handles, `exists`), which read on the step's open connection. `Database.host` gives a cell the host's own object for that connection (`SharedDatabase.write` passes it), so it can write the host's tables through the host's code in its step; nil on the layered backend.

## Epochs and the output gate (layered)

- When an addressable's lane runs dry, or after 256 jobs if it never does, everything written since the last seal becomes one epoch: pages, sends, consumed mail, job transitions.
- One shipper per worker writes every sealed epoch in one outer transaction, a savepoint per epoch. Each epoch first checks its fence, which also renews the lease. Once an epoch of a lease fails, no later epoch of that lease lands.
- An effect or an emit waits until the epoch holding everything written before it is durable. A failed epoch ends the incarnation: held effects throw `Evicted`, held emits are dropped, and the next poke hydrates a new incarnation from durable pages.
- A read handle (`cell(_:)`, `job(_:)`) holds one snapshot of the outer file for as long as it lives. It lags by that addressable's open epoch. Its schema is applied to its own copy, which is never sealed, so an addressable that never booted reads as a fresh one.

## Delivery

- Mail is a row in the outer file. A cell call consumes its row in the same epoch as its writes, so every cell call is exactly once. A job's `receive` consumes the row in the epoch open then. Delivery is not ordered, except on the shared backend, where a recipient takes its mail in the order the rows were written.
- On the shared backend the host program is a sender too: `Recipient(kind:key:).post(_:on:)` writes the mail row in the host's own open transaction, so it is durable with what the host wrote, and `Worker.poke(_:)` after the commit has the recipient look.
- A poke, after an epoch is durable or after an outside send, is lossy. Every `scanInterval` each worker renews its leases, then pokes every recipient with mail, every job that nobody holds or whose wake time has come, and every cell whose wake time has come that nobody else holds. A poke claims a free or expired lease, bumping the fence, and hydrates the addressable.
- A worker hosts nothing before `Worker.start`: mail sent to it or through it waits in the store, and `start` scans for it.
- `Worker.drain` ends every job's `start`, waits for what was written, and gives up every lease.

## Sockets

- A `Socket` type declares `Incoming` (`Never` for publish-only) and `Outgoing`. Whoever owns the transport calls `worker.attach(S.self, to: id) { output in … }` and gets a `Peer` to send frames and close; `nil` means the addressable is not this worker's to host. A job takes only publish-only sockets.
- A cell handles sockets with `attached(_:)`, `receive(_:from:)` and `closed(_:)`, each taking a `SocketHandle<S>`; `@Cell` dispatches them by socket type, and a frame of a type with no `receive` traps. Each is a call like a message, one durable step, but nothing about it is durable: it is lost if the incarnation dies. A peer's frames reach the cell one at a time, in order, after its `attached`; its `closed` comes after its last frame.
- `ctx.sockets(of:)` lists the attached sockets, in the order they came. Membership lives in the worker's registry, not in the incarnation, so an evicted cell finds its sockets again.
- `send` and `close` on a handle are outputs: they leave in order once what was written before them is durable. A failed epoch drops them and closes their sockets, so a client never silently misses a frame. A job that is done closes its sockets after its last epoch; a draining worker closes all of its own.
- A job hears `attached(_:)` (from `@Job`'s `_attached`) when a socket attaches and again on every hydrate, once per socket per incarnation: where a late peer catches up.
- An event that reaches an incarnation after it left goes to the next one; a retiring incarnation holds events until it leaves.

## Testing

- `Simulation` runs the lanes, task jobs, events and timers of all its processes on one thread, choosing among the ready ones with a seeded generator, under a virtual clock; a due timer is ready like any other step. `kill` drops a process mid-await; `freeze` and `thaw` pause it while time goes on. A step that runs for over a second of real time crashes the test process.

## Not built yet

`withIsolatedTaskGroup` with a lint against the stdlib task groups, an `effects.timeout` race helper, sockets across workers, frames into a job, watch, exports and an authorizer hook, `ATTACH` joins, pokes across processes, a cap on claims per scan, and a thread pool of its own: `LiveScheduler` runs lanes on a concurrent dispatch queue.
