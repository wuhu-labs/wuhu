# MachineContract

The wire contract for the machine domain: the multiplexed frame protocol
between server and machine agent, the caller-facing exec event union, and the
machine admin types. Swift is the source of truth; JSON Schema is derived from
these types (see `Tests/contract/*.schema.json`, simultaneously golden
fixtures, reviewable contract diff, and tool definitions); TypeScript derives
from the schema files. The target imports nothing beyond `Contract` and
`JSONValue` so server internals cannot leak into wire types.

This file pins the wire semantics the JSON Schema cannot carry. It is a
contract: changes here are contract changes.

## Encoding conventions

- **Discriminated unions** (`ControlMessage`, `ExitStatus`, `ExecEvent`,
  `VFSOp`, `VFSResult`, `SearchQuery`, `SearchResult`) are
  **internally tagged**: `{"kind": "<case>", …flattened labeled values}`,
  never externally tagged, never a `_0` key.
- **Optional fields** are omitted when absent (never explicit `null`) and are
  absent from the schema's `required`.
- **`Base64Data`** crosses the wire as a base64 string inside the JSON
  payload. All byte accounting — cursors, `window`, `maxOutput` — counts
  **decoded raw bytes**, never base64 characters.

## Frames

A connection carries `Frame` values: `{streamID, opcode, body}` where `body`
is the opcode's payload type. Stream 0 is control (`ControlMessage`); each
exec gets a fresh nonzero `streamID` assigned by the initiating side; VFS
and search traffic demux by their payload's request `id`, not by stream.

Opcode → payload: `control`→`ControlMessage`, `exec-start`→`ExecStart`,
`stdin`→`StdinChunk`, `stdin-eof`→`StdinEOF`, `output`→`OutputChunk`,
`exec-exit`→`ExecExit`, `ack`→`Ack`, `kill`→`Kill`,
`vfs-request`→`VFSRequest`, `vfs-response`→`VFSResponse`,
`search-request`→`SearchRequest`, `search-response`→`SearchResponse`.

There are no secret opcodes: a machine keeps no secrets of its own, and a
secret's value reaches it only inside the `ExecStart` that needs it.

## Ids, tokens, and the connect handshake

- `MachineID` = `mc_` + 8 and `ExecID` = `ex_` + 8, over the lowercase
  alphanumeric alphabet `[a-z0-9]`. Suffixes are random, never sequential.
  Decoding is total (any string decodes); `isValid` is the shape gate,
  enforced at minting and at trust boundaries, and the derived schemas carry
  the grammar as `pattern`.
- The one-time join token (`jt_` + 32, minted by the space's unified
  enrollment) appears on the wire exactly twice: `MachineAddOutput` and
  `MachineRotateOutput` (minted, shown once). The box consumes it at
  `/v1/enroll/consume`, enrolling its own ed25519 key; no machine credential
  is retained server-side beyond the key row, and no token appears in any
  list/status output.
- The dial-in authenticates by signature, not a bearer: the box fetches a
  one-shot challenge (`MachineChallengeOutput`), signs
  `MachineConnect.signingPayload(challenge:)` with its machine key, and
  presents pubkey/challenge/signature in the `MachineConnect` headers on the
  connect upgrade. The server burns the challenge at first take and verifies
  against the live key row, so a captured handshake cannot replay and a
  revoked key cannot dial.
- The same upgrade carries `MachineConnect.capabilitiesHeader`
  (`x-wuhu-machine-capabilities`), a comma-separated list of what the dialing
  agent speaks. Today's one capability is `MachineConnect.groupSecrets`
  (`group-secrets`): the agent takes `ExecStart.secretValues` and resolves no
  secret name itself. A header that is absent, or lacks a capability, means
  an agent from before it; the server treats that connection as such for its
  whole life.
- `ExecID` is server-minted before `exec-start` and the frame carries it, so a
  retried start after a blip is idempotent — the machine spawns at most one
  process per exec id.

## Exec

- `ExecStart.cwd` is an **absolute path on the machine**. The
  `machines://<id>/<path>` addressing is resolved caller/server-side to pick
  the machine; only the machine-local path crosses this wire.
- `command` is argv: `command[0]` is the executable; no shell interpretation.
- `env` and `secrets` absent mean empty. `secrets` maps `ENV_NAME` →
  `SECRET_NAME`, names of secrets in the group of the machine the exec runs
  on — the machine's group at the moment the start is relayed, never the
  caller's. A caller sends names only. The server resolves them and relays,
  to an agent that announced `group-secrets`, the start with `secrets` absent
  and `secretValues` (`ENV_NAME` → value) in its place; the agent injects
  those as env at spawn, masks every non-empty value in the output, and never
  writes one to disk. A name the machine's group lacks spawns nothing: the
  server answers the caller as a failed spawn does — one stderr line
  `wuhu: no secret NAME in group GROUP\n` and `exited(code: 127)` — and the
  agent never sees the start. An agent that announced `group-secrets` but is
  handed names in `secrets` (a server from before this field) spawns nothing
  either and fails the same way, naming the first secret.
- An agent that did not announce `group-secrets` (one from before it) is
  relayed the start as it always was: `secrets` names, no `secretValues`,
  which it resolves in its own local vault. The server never sends such an
  agent a value.
- `session` (`ExecSessionCredential {token, spaceURL}`) is set by the server,
  never by a caller, on an exec run for a session. The agent sets
  the `SessionExecEnvironment` names from it — `WUHU_EXEC=1`, `WUHU_TOKEN`,
  `WUHU_SPACE_URL` — after `env` and secrets, and masks the token in output;
  absent, it unsets those three. An agent that predates the field ignores it
  (unknown keys are skipped), so its execs keep the wallet.
- `window` absent means `ExecDefaults.window` (4 MiB); it is the un-acked
  flow-control window and the reconnect replay buffer, always finite.
- `maxOutput` is a total-output byte cap; on exceed the exec is killed and the
  caller sees `ExecEvent.truncated(limit:)` before the exit event. `timeout`
  is wall-clock **seconds**, fractional. Both absent mean unlimited.
- **Cursors** are byte offsets of a chunk's first byte. Output has one cursor
  space per exec: stdout and stderr count into a single merged sequence in
  emission order. Stdin has its own cursor space; `StdinEOF.cursor` is the
  total stdin length, making the half-close position unambiguous across
  reconnects. `ExecExit.cursor` is the total output length. `Ack.cursor`
  acknowledges every byte below it (machine→server acks stdin,
  server→machine acks output); acks are end-to-end — the producer retains
  un-acked bytes for replay, the server relays and holds no durable stream
  state.
- `ExitStatus` is `exited(code:)` or `signaled(signal:)`; kills (caller kill,
  timeout, `maxOutput`, disconnect past grace) surface as `signaled`.
- `ExecEvent` is the caller-leg union. `failed(error:)` is terminal;
  `machineLost` there means the machine stayed gone past its grace and the
  output already delivered is all there is.

## v1 replay retirement and output cutoff

- `ControlMessage.hello.execs` optionally scopes incoming-exec replay to those ids. New caller endpoints list their outgoing execs; the server scopes a caller leg to its authorized exec. An empty list requests none, while an absent list preserves legacy unscoped replay. Outgoing-exec resume is unaffected, so a machine reconnect still recovers starts lost during its outage.
- `Ack.terminal = true` acknowledges the exit and its entire output at `ExecExit.cursor`. It is sent only once the consumer has its durable result (or has consumed the exit for streaming callers). A matching terminal ACK retires the agent's full exec state; byte ACKs alone do not. Unacknowledged finished state expires 10 minutes after exit, even disconnected. Old servers/agents ignore additive fields or omit them, and continue working with ordinary byte replay and the new agent's expiry.
- `ExecExit.outputCut = true` means stopping the command forcibly cut off output admission; unsent bytes are discarded, and unread pipe data may be lost. Its cursor still counts bytes admitted to the wire, preserving replay for older consumers; the unsent suffix cannot hold kill/timeout behind a full window. New event consumers emit `.truncated(limit: cursor)` before the exit. Absent `outputCut` means the peer made no cutoff claim.

## VFS and search

- Machine fs is raw: **version token = mtime**, opaque on the wire
  (`MachineEntry.token`, `VFSResult.file/written` tokens; `ifMatch` gates
  write/rm). `mtime` is seconds since the Unix epoch, UTC, fractional.
- There is no edit op: the resolver arm composes read → fuzzy match →
  write-if-token-unchanged server-side.
- A `read` travels as one frame. Without `offset` and `length` it reads the
  whole file, and a file over the agent's read bound (`VFSDefaults.maxReadBytes`,
  8 MiB) fails with `tooLarge` instead of severing the channel. With either,
  it reads that range: `offset` defaults to 0, `length` to the rest of the
  file, a range past the end is empty, a negative one is `invalidArgument`,
  and a `length` over the bound is `tooLarge`. Every range carries the file's
  token, so a reader assembling a file from ranges sees a change between them.
  An agent built before ranged reads ignores both fields, reads the whole
  file and so refuses one over the bound with `tooLarge`; the server takes
  that as "upgrade the machine agent". Attachments from a machine are read
  this way (up to the 50 MiB attachment limit); other big files still stream
  through exec.
- `SearchQuery` runs the whole traversal machine-side with the agent's own
  matcher. `matchLimit` caps results, `entryLimit` caps entries traversed,
  `step`/`cursor` is an opaque resume cursor over a deterministic traversal
  order: `cursor` is present iff the page was truncated, and passing it back
  as `step` continues.
