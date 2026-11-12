# OperationClient

`MachineLink` performs one generic machine-protocol exchange for BoxLink. It takes an origin, a `FetchClient`, an operation clock, a UUID source and a tracer. It owns no operation admission, driver, store, owner claim, recovery, file adapter, copy pump or retry policy; those are outside this target.

## Exchange

`send(type, machine, exchange, body:, correlation:, deadline:, limit:, preparation:)` makes one request to `origin/machine/v2/machines/<machine>[/operations/<uuid>[/stop|/inputs/<channel>]]`. Describe and poll use GET, start POST, stop and input PUT. Poll query items pass through unchanged. Each exchange has a fresh `X-Wuhu-Request-ID`; its correlation header is the caller's supplied UUID or that request UUID. Fetch is one dispatch, with no automatic retry, redirect replay or fallback.

`Exchanged` carries the typed result and whether the machine itself answered. A response must echo both request headers and carry a valid UUID in `X-Wuhu-Agent-Instance`. Missing or invalid evidence is `invalidResponse` with `answered: false`. A valid typed error envelope has `answered: true`, including an error code unknown to this build; a malformed error body does not. A successful response with valid headers has `answered: true` even when decoding its body as the requested type fails. The caller decides what an answer means for its lease.

The response body is bounded by the caller's limit before decoding. A fetch or body failure preserves a typed OperationError or becomes `transport`; failed decoding is `invalidResponse`. A passed deadline becomes `requestDeadline`, cancellation `requestCancelled`. Neither failure dispatches another exchange. `OperationPreparation` forwards balanced local routing/authentication notifications to the supplied observer without suspending the real deadline.

## Lifetime

The exchange deadline answers the caller even if fetch ignores cancellation. Its named transport task remains in the machine-link task scope until the adapter returns. Cancelling an injected clock sleep disables only that timer, not its exchange; caller cancellation still ends the wait. `ExchangeClock` adapts the operation clock for these deadlines. This target does not subtract local work from any machine-silence budget.

## Tracing

Each exchange under a current span creates exactly one content-free `machine.exchange` client span under it and propagates its context through tracer headers. It carries only `machine.id`, optional `operation.id`, `machine.exchange.kind` (`describe`, `start`, `poll`, `stop`, `input`), `http.response.status_code`, `machine.exchange.head_ms`, `machine.exchange.elapsed_ms`, `wuhu.outcome` (`ok`, `errored`) and on failure `error.type` (the known operation code or `unknown`) with error status. It never includes paths, queries, bodies or error messages. Outside a current span it starts none.
