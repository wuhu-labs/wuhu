# Agents contract

`SessionKind` is the agent/task wire value. `SessionSummary` describes session identity, group, kind, parent, creation date, lifecycle and creator. Session ids and parents use `SessionID`; `SessionLifecycle` is live or archived with a `Date` grace expiry. Group stays a string to avoid a direct dependency on the changing SpaceContract wire module. Archived sessions retain their grace period; no authorization or liveness filtering is implicit.

`CellContext.session(_:)` resolves the provided `AgentCells` factory and returns one session's `SessionReading` handle in the caller's existing read. Its `summary` is nil for a missing session. The owner cell implements the read over its own rows. No database, SQL, batch lookup, connection or projection crosses the contract. LoopCore currently provides the factory when registering SessionCell; an unprovided factory traps. Tests substitute the same factory with fixture handles.
