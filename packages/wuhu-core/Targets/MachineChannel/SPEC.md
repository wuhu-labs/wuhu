# MachineChannel

The transport-agnostic exec channel used by the v2 caller adapter. MachineContract pins the frame vocabulary and cursor semantics; this file pins the channel behavior above it. A `ChannelEndpoint` is the caller side of an exec: `startExec` / `OutgoingExec` for a new exec and `ExecEvents` for its output and exit. VFS and search use v2 operations, not this channel.

## Transport contract

`FrameTransport` carries opaque datagrams: one `send` = one encoded frame, byte order preserved per direction, `inbound` finishes when the connection dies, and `send` throws once severed. Transports must accept sends promptly (buffer, don't block): all flow control lives in the channel protocol, never in the transport. `FrameCodec` is the wire codec — a frame is the UTF-8 JSON of `Frame`, with the body kept as `JSONValue` so relays and the pump route on `{streamID, opcode}` without decoding payloads. `InMemoryTransport.pair` is the in-memory duplex; production runs the same frames over the WebSocket transport in `SpaceServer`.

## Endpoint lifecycle

An endpoint outlives its transports. The owner drives each connection with `run(transport)`, which returns when the transport dies; re-binding calls `run` again with a fresh transport. Per-exec replay buffers and cursors survive across bindings.

## Cursored streams, acks, resume

`sendStdin` appends to a per-exec replay buffer before transmitting; a full window (`ExecStart.window`, decoded raw bytes) suspends the producer until acks free room — that suspension is the child-blocking backpressure. The caller acknowledges what it consumed: each `ExecEvents` element acknowledges its end cursor when the consumer pulls it, so a consumer that never iterates leaves the peer's window full at exactly `window` buffered bytes.

Resume:

- On every bind, an endpoint sends a stream-0 `hello` first, then per live exec retransmits `exec-start`, self-replays all un-acked chunks plus `stdin-eof` / `kill` tails, and re-announces its consumption cursor as a plain `ack`. Hello-before-acks keeps the blocked-sender rebind drop-free: an announcement ack can wake the peer's window-blocked sender, and the fresh chunk that wakeup emits sits far above the peer's consumption cursor (the bytes between died with the old binding) — emitted after the hello-queued replay it arrives in order instead of being dropped and redelivered.
- An `exec-start` the peer takes is answered with a plain `ack` at its consumption cursor, zero for a fresh exec. `OutgoingExec.accepted()` returns on the exec's first `ack`: the peer holds the exec, which no longer depends on the sender staying connected.
- Receiving `hello` means the peer (re)connected and anything un-acked may have been lost on the way to it, so every live exec resumes as at bind — `exec-start` retransmit included — and the endpoint replays all of its own un-acked tails, synchronously, before routing any later frame from that peer. The replay runs from the cursor acked before the blip (the peer's announcement ack arrives after its hello); the over-replay is bounded by the window and deduped by the peer's consumption cursor. This heals a single-leg blip behind a stateless relay: the reconnecting side's bind covers its own losses, and its hello makes the far side resend everything the relay dropped — including an `exec-start` that never arrived — even though the far binding never blipped. The hello's `execs` list names the exec ids the sender holds so a hub can scope each caller leg; the endpoint itself does not read it.

`ExecEvents` carries a consumed cursor for the exec's combined stdout+stderr stream. A chunk wholly below it is dropped and re-acked (recovering producer trim when acks were lost), a partially stale chunk is trimmed to it, and a chunk wholly above it is dropped unacked. Above-cursor arrival is a legal transient, not corruption: output in flight from a peer that never blipped can land ahead of the hello-driven replay, and everything above the cursor is still retained un-acked at the sender, so the replay redelivers it contiguously. Delivery is byte-exact regardless of re-chunking. A non-advancing ack is a no-op for the producer.

`exec-exit` completes the stream only at its exact cursor: one arriving above the consumed cursor is dropped like a data chunk (its bytes and the tail replay behind the same hello), and one below it is a protocol violation. Transports preserve per-direction frame order within a binding, so after the resume handshake settles, tails land exactly at their cursor. An exit with `outputCut` reports `.truncated(limit: emittedCursor)` ahead of its status, and one with `timedOut` reports `.timedOut` the same way.

## Discipline and errors

Per direction of one exec there is a single logical writer: interleaving concurrent `sendStdin` calls, or sending after `closeStdin`, is caller misuse (preconditions, not wire errors). A frame that fails envelope decode is answered with a stream-0 `control` error and dropped; a body that fails typed decode fails only its own consumer (the exec's iterator). The pump itself never blocks on a consumer and never crashes on peer input.

A byte acknowledgement never retires an exec, even when its cursor covers all output: the exit itself may still need replay. `OutgoingExec.acknowledgeExit()` sends `Ack.terminal = true` at the received exit cursor and waits until the frame is sent or the binding is lost. Automatic consumers do this when they consume the exit; manual consumers call it only after storing their durable result. If the leg is absent or lost before transmission, the terminal-ACK intent survives and is resent on rebind or peer hello without replaying `exec-start`. Successful transmission releases local outgoing state. Invalid id/cursor acknowledgements cannot retire an exec.
