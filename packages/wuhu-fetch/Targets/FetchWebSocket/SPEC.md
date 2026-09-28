# FetchWebSocket

A minimal cross-platform (macOS + Linux) WebSocket client in the web-platform
spirit of wuhu-fetch: `WebSocketClient.connect` dials, runs the RFC 6455 client
upgrade over NIO, and returns a `WebSocketDuplex` — an `AsyncStream<[UInt8]>`
inbound plus async `send` / fire-and-forget `close`.

- Schemes: `ws://`/`http://` dial cleartext TCP; `wss://`/`https://` dial TLS.
  For a secure scheme the `tls` argument selects trust: `.pinned(fingerprint:)`
  rides the PinnedTLS leaf-pinning dial, `.configuration` uses a caller-supplied
  `TLSConfiguration`, and the default (`nil`) is system trust. SNI is set from
  the host, except for IP literals, which handshake without a server hostname.
- Extra request headers ride the upgrade request, so a server can gate the
  upgrade on credentials before any frame flows. A refused upgrade surfaces as
  `WebSocketClientError.refused`; TCP failures throw the underlying error.
- Inbound text and binary frames both arrive as their raw bytes; fragmented
  messages are reassembled; pings are answered with pongs at the channel layer;
  a close frame (or channel death) finishes `inbound`. There is no pump task —
  the NIO handler yields bytes straight into the stream.
- Outbound `send` writes one masked binary frame per call and throws once the
  connection is severed. `close` sends a normal-closure frame and closes the
  channel.
- `maxFrameBytes` is the inbound frame ceiling handed to the NIO decoder; size
  it to the peer's advertised maximum (wuhu's machine wire uses 16 MiB).
