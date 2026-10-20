# Serve WebSocket transport

`WebSocket.send` awaits transport delivery. `close()` requests normal closure and may wait for queued outbound data; it is not a hard termination boundary. `abort()` terminates the transport without waiting for outbound data or a close frame to flush, finishes inbound, and releases pending sends with failure. Custom transports must supply both closure operations. The in-memory pair has no queued transport writes, so both operations finish both sides immediately; retained inbound messages can still drain.

## Opt-in bounded binary upgrades

`UpgradeResult.boundedWebSocket` accepts explicit BoundedWebSocketLimits, one required subprotocol and a session over TunnelTransport. This is additive: `.webSocket` keeps its existing messages, queueing and default frame behavior. The bounded path is binary-only, single-receiver/sequential-sender, and supplies immediate abort. An unsupported subprotocol is refused at the upgrade; no extension is selected; it never becomes a legacy WebSocket. ServeTesting explicitly refuses bounded upgrades rather than constructing its old unbounded pair; deterministic tunnel tests inject their own bounded transport.

## In-process client

`FetchClient.inProcess(handler)` is a fetch client over a `Handler` or `UpgradingHandler` called as a function: what a client in the same process as the server uses in place of a socket. A `ServeError` thrown by the handler answers as the status response a socket server would send (`<code> <reason>` text body). Headers the client marked sensitive are folded into the request's plain headers first, as a wire transport would serialize them, so the handler sees what a socket server sees. An upgrade result (`.webSocket` or `.boundedWebSocket`) is refused with `WebSocketUpgradeRefused`, which carries the request; the in-process client never becomes a WebSocket.
