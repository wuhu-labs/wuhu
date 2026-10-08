# MachineChannel

The transport-agnostic multiplexer for the machine domain wire (MachineContract
SPEC.md pins the frame vocabulary and cursor semantics; this file pins the
channel behavior above it). One `ChannelEndpoint` serves every role: the caller
leg (`startExec` / `OutgoingExec`), the machine agent leg (`incomingExecs` /
`IncomingExec`, `inboundRequests` / `respond`), and — via envelope-level
forwarding — a server relay that holds no stream state.

## Transport contract

`FrameTransport` carries opaque datagrams: one `send` = one encoded frame, byte
order preserved per direction, `inbound` finishes when the connection dies, and
`send` throws once severed. Transports must accept sends promptly (buffer, don't
block): all flow control lives in the channel protocol, never in the transport.
`FrameCodec` is the wire codec — a frame is the UTF-8 JSON of `Frame`, with the
body kept as `JSONValue` so relays and the pump route on `{streamID, opcode}`
without decoding payloads. `InMemoryTransport.pair` is the in-memory duplex
(with an optional sever-after-N-sends budget for blip tests); the production
WebSocket transport is a later milestone.

## Endpoint lifecycle

An endpoint outlives its transports. The owner drives each connection with
`run(transport)`, which returns when the transport dies; re-binding is just
calling `run` again with a fresh transport. All per-exec state (replay buffers,
cursors, delivery watermarks) survives across bindings. In-flight VFS / search
round trips do not: they are scoped to the *pair* of bindings that carried
them, failing with `ChannelError.severed` on the requester's own unbind and on
the responder's rebind (its `hello` — the response may have died with the old
binding, and responses are never replayed). Retry policy belongs to the caller.
Accepted edge: a request that did survive into the responder's new binding can
still execute after the requester already saw `.severed` — delivery to the
caller is at-most-once, execution under retry is at-least-once, so
non-idempotent ops carry `ifMatch` or fail loudly at the tool layer. A `hello`
crossing a just-issued request at connection start fails it the same way; the
caller retries. Cursored byte streams are the only end-to-end-reliable traffic.

## Cursored streams, acks, resume

Producers (`sendStdin`, `IncomingExec.send`) append to a per-exec replay buffer
before transmitting; a full window (`ExecStart.window`, decoded raw bytes)
suspends the producer until acks free room — that suspension is the
child-blocking backpressure. Receivers ack on consumption: each `ExecEvents` /
`StdinStream` element acknowledges its end cursor when the consumer pulls it, so
a consumer that never iterates stalls the producer at exactly `window` buffered
bytes.

Resume and retirement use optional v1 fields; older peers ignore them:

- On every bind, an endpoint sends a stream-0 `hello` first, then per live exec
  retransmits `exec-start` for outgoing execs (delivery is at-most-once by exec
  id on the receiver), self-replays all un-acked chunks plus `stdin-eof` /
  `kill` / `exec-exit` tails, and re-announces its consumption cursor as a
  plain `ack`. Hello-before-acks keeps the blocked-sender rebind drop-free: an
  announcement ack can wake the peer's window-blocked sender, and the fresh
  chunk that wakeup emits sits far above the rebinding receiver's watermark
  (the bytes between died with the old binding) — emitted after the
  hello-queued replay it arrives in order instead of being dropped and
  redelivered.
- Receiving `hello` means the peer (re)connected and anything un-acked may have
  been lost on the way to it: outgoing execs resume as at bind, while incoming execs replay only the ids listed in `hello.execs`. An absent list is a legacy unscoped hello, and an empty list requests no incoming replay. New caller hellos list their outstanding exec ids; the hub additionally scopes each caller leg to its authorized exec. Resumption runs exactly as at bind — `exec-start` retransmit for outgoing execs included —
  and replays all of its own un-acked tails, synchronously, before routing any
  later frame from that peer. The replay runs from the cursor acked before the
  blip (the peer's announcement ack arrives after its hello); the over-replay
  is bounded by the window and deduped by the receiver watermark. It also fails
  its in-flight round trips (see Endpoint lifecycle). This is what heals a
  single-leg blip behind a stateless relay: the reconnecting side's bind covers
  its own losses, and its hello makes the far side resend everything the relay
  dropped — including an `exec-start` that never arrived — even though the far
  binding never blipped.
- Receivers keep a consumed watermark: wholly stale chunks are dropped and
  re-acked (recovering producer trim when acks were lost), partially stale
  chunks are trimmed to the watermark, and chunks wholly above the watermark
  are dropped unacked. Above-watermark arrival is a legal transient, not
  corruption: a sender that never blipped can have fresh frames in flight
  across the receiver's rebind (behind a relay they land on the new leg ahead
  of the hello-driven replay), and everything above the watermark is still
  retained un-acked at the sender, so the replay redelivers it contiguously.
  Delivery is byte-exact regardless of re-chunking. A non-advancing ack is a
  no-op for the producer.

`stdin-eof` and `exec-exit` complete a stream only at their exact cursor: one
arriving above the consumed watermark is dropped like a data chunk (its bytes
and the tail replay behind the same hello), and one below it is a protocol
violation. Transports preserve per-direction frame order within a binding, so
after the resume handshake settles, tails land exactly at their cursor.

## Discipline and errors

Per direction of one exec there is a single logical writer: interleaving
concurrent `sendStdin` calls, or sending after `closeStdin` / `exit`, is caller
misuse (preconditions, not wire errors). A frame that fails envelope decode is
answered with a stream-0 `control` error and dropped; a body that fails typed
decode fails only its own consumer (the exec's iterator or the awaiting round
trip). The pump itself never blocks on a consumer and never crashes on peer
input.

A byte acknowledgement never retires an exec, even when its cursor covers all output: the exit itself may still need replay. `OutgoingExec.acknowledgeExit()` sends `Ack.terminal = true` at the received exit cursor and waits until the frame is sent or the binding is lost. Automatic consumers do this when they consume the exit; manual consumers call it only after storing their durable result. If the leg is absent or lost before transmission, the terminal-ACK intent survives and is resent on rebind or peer hello without replaying `exec-start`. Successful transmission releases local outgoing state. Receipt of a matching terminal acknowledgement releases all incoming state and cancels its expiry timer. Invalid id/cursor acknowledgements cannot retire an exec.

The owner of incoming execs runs `runRetention()` for its whole lifetime, independently of transports. Every incoming exit schedules expiry 10 minutes later on the injected continuous clock; acknowledgement cancels that timer. Expiry releases the same state even while disconnected. Bind replay therefore includes only running or still-unacknowledged, unexpired execs. An old server's ordinary byte ACKs keep working; expiry bounds its finished history.

`IncomingExec.stopOutput()` marks a forced output cutoff, stops output admission and releases capacity waiters without waiting for the caller. Subsequent unsent bytes are discarded; `send(..., waitForCapacity: false)` sends only the immediately available prefix and marks any dropped suffix. Already-transmitted chunks retain their cursor/replay semantics for mixed-version callers. `ExecEvents` translates an output-cut exit into `.truncated(limit: emittedCursor)` followed by the unchanged exit status.
