# ServeTesting

Runs a wuhu-serve `Serve.Handler` / `UpgradingHandler` as an in-memory
`Fetch.FetchClient`, so route logic can be tested without a socket. The request
you construct is handed to the handler and the handler's `Response` comes back
unchanged. There is no `ServeNIO` in the loop.

`ServeTesting.client(_:)` wraps a plain `Handler`; `ServeTesting.client(upgrading:)`
wraps an `UpgradingHandler` and turns a `.webSocket` outcome into a thrown
`WebSocketUpgradeRefused`. `ServeTesting.upgrade(_:_:)` exposes the upgrade
outcome directly: `.response` for a non-upgrade (or a handler-thrown `ServeError`),
or `.webSocket(client, serve:)` — the caller's socket leg plus a closure that runs
the server session, wired through `Serve.WebSocket.pair`.

## What transfers (faithful to ServeNIO)

- **Streaming.** The `Response` is returned the instant the handler returns; its
  body is never collected. A streaming body streams to the caller chunk by chunk.
- **`ServeError` → status.** A `ServeError` thrown by the handler becomes a
  `Response` carrying `error.responseStatus` and ServeNIO's `"<code> <reason>\n"`
  text body — through `client(_:)`, `client(upgrading:)`, and `upgrade(_:_:)`
  alike. Any other thrown error propagates to the test unchanged (ServeNIO would
  turn it into a 500; surfacing the real failure is more useful in a test).
- **Sensitive headers.** A real transport serializes every header onto the wire,
  but the in-process handler reads only `RequestHeaders.values`. Headers the
  client marked sensitive are folded into `values` before dispatch, so the
  handler sees what a socket server would.

## The boundary — what does NOT transfer

ServeTesting sits **above request admission**: it exercises handler logic, not
the wire. A route test that depends on any of the following is testing something
ServeTesting does not model — use a real `ServeNIO` server (see `ServeNIOTests`).

- **No `ServeOptions`.** No `maximumBodyBytes` / header-count / head-size caps. A
  20 MB POST that a real server rejects with `413` runs straight through here.
- **No Host requirement or URL reconstruction.** The `request.url` you pass is
  used verbatim. A real server rebuilds the URL from `scheme://` + the `Host`
  header + the request target, and rejects a missing `Host`.
- **Request body identity.** The body arrives exactly as constructed — a
  replayable `.data`/`.bytes`, readable more than once. A real server delivers a
  single-pass stream that a double read exhausts, and delivers *no* body where
  you passed `.bytes(Data())` (an empty body is non-nil in-memory, nil on the
  wire).
- **No transport-injected headers.** A `Body`'s `contentType` / `contentLength`
  are *not* folded into request headers (only sensitive headers are). A real
  client transport emits `content-type` / `content-length` request headers a
  handler could read.
- **No response normalization.** The `Response` is returned as-is: no
  `connection` / `content-length` / `transfer-encoding` framing is stripped or
  synthesized, and no body suppression for `1xx` / `204` / `304`. A real server
  rewrites all of that on the way out.
