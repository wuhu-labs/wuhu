# Serve WebSocket transport

`WebSocket.send` awaits transport delivery. `close()` requests normal closure and may wait for queued outbound data; it is not a hard termination boundary. `abort()` terminates the transport without waiting for outbound data or a close frame to flush, finishes inbound, and releases pending sends with failure. Custom transports must supply both closure operations. The in-memory pair has no queued transport writes, so both operations finish both sides immediately; retained inbound messages can still drain.

## Opt-in bounded binary upgrades

`UpgradeResult.boundedWebSocket` accepts explicit BoundedWebSocketLimits, one required subprotocol and a session over TunnelTransport. This is additive: `.webSocket` keeps its existing messages, queueing and default frame behavior. The bounded path is binary-only, single-receiver/sequential-sender, and supplies immediate abort. An unsupported subprotocol is refused at the upgrade; no extension is selected; it never becomes a legacy WebSocket. ServeTesting explicitly refuses bounded upgrades rather than constructing its old unbounded pair; deterministic tunnel tests inject their own bounded transport.
