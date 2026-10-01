# ServeNIO WebSocket transport

Normal WebSocket `close()` writes a close frame before closing the channel. `abort()` closes the NIO channel directly, without a preceding write or flush. It ends inbound and fails pending writes even when the peer is not reading, so callers do not need to await a graceful close under backpressure.
