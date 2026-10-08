# ServeNIO WebSocket transport

Normal WebSocket `close()` writes a close frame before closing the channel. `abort()` closes the NIO channel directly, without a preceding write or flush. It ends inbound and fails pending writes even when the peer is not reading, so callers do not need to await a graceful close under backpressure.

## Request-body cancellation and early close

Cancelling a pending inbound body read finishes its buffer with CancellationError and resumes its waiter, including when cancellation races waiter registration. A cancelled or failed body is never drained for HTTP/1 keep-alive reuse. A handler response containing the Connection: close token skips the unread body drain, writes its response immediately and closes the connection. This permits bounded upload refusals without waiting for a peer to finish a trickling body; ordinary keep-alive responses still drain healthy unread bodies within the existing byte/inactivity bounds.
