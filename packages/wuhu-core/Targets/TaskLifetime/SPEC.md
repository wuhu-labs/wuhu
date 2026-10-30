# Task lifetimes

`TaskScope` owns named unstructured tasks. `run("name")` preserves the caller’s actor isolation and task-local context and returns a standard typed `Task` for a result or individual cancellation. Live names (including duplicates) are available as `liveTasks`; completed children are removed automatically. Admission and completion are serialized. Calling `run` after closing throws `TaskScopeClosed` synchronously without starting the operation. Already-admitted work must handle refusal if it attempts nested admission during shutdown.

`cancel()` cancels the current children without waiting or closing admission. It is for a dismount that must return before noncooperative work finishes. The parent must subsequently call `close()`; cancellation alone does not relinquish ownership. `close()` closes admission, cancels all remaining children, and drains them even if its caller is cancelled. Concurrent and repeated closes are safe. Never close a scope from one of its own children.

`bestEffort("name", within: duration, clock: clock)` runs throwing work under the same ownership with an injectable clock (continuous by default), cancels it at its deadline, and logs failures with the name, including closed-scope admission refusal. Closing the scope also cancels and drains best-effort work. Like all structured cancellation, the deadline requires a cooperative operation; it cannot forcibly terminate arbitrary code.

`withDeadline(_:clock:operation:)` races one operation against a deadline on the supplied clock. Timeout throws `DeadlineExceeded`; operation and clock failures pass through. The losing child is cancelled and drained before returning.

The deadline timers of `withDeadline`, `withUnjoinedDeadline` and `bestEffort` sleep on the caller's isolation (`isolation:`, `#isolation` by default), so an isolated test advancing a `TestClock` wakes them deterministically.

`withUnjoinedDeadline(_:within:clock:scope:operation:)` owns the operation and timer in the supplied scope, cancels the loser, and delivers the answer without joining either child; the external work may outlive its waiter, and its scope owner remains responsible for draining or an explicit noncooperative-transport teardown exception.

`uncancellable("why")` runs one operation to completion without inheriting the caller’s cancellation, preserving actor isolation and task-local context. The required reason documents why completion matters. This single implementation becomes Swift’s built-in cancellation shield when the deployment floor reaches OS version 27.
