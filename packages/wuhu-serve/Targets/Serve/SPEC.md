# Serve WebSocket transport

`WebSocket.send` awaits transport delivery. `close()` requests normal closure and may wait for queued outbound data; it is not a hard termination boundary. `abort()` terminates the transport without waiting for outbound data or a close frame to flush, finishes inbound, and releases pending sends with failure. Custom transports must supply both closure operations. The in-memory pair has no queued transport writes, so both operations finish both sides immediately; retained inbound messages can still drain.
