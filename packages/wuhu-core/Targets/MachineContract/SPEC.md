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
  `VFSOp`, `VFSResult`) are
  **internally tagged**: `{"kind": "<case>", …flattened labeled values}`,
  never externally tagged, never a `_0` key.
- **Optional fields** are omitted when absent (never explicit `null`) and are
  absent from the schema's `required`.
- **`Base64Data`** crosses the wire as a base64 string inside the JSON
  payload. All byte accounting — cursors, `window`, `maxOutput` — counts
  **decoded raw bytes**, never base64 characters.

## Machine registration

`MachineAddInput` carries optional `name` and `group` for both `POST /v1/machine` and `POST /v1/machine-v2`. For people, an omitted group preserves personal-group registration; an explicit group must exist (`404 unknownGroup`) and admit the caller as an admin (`403 adminRequired`), just as the target of a machine move does. Sessions always register in their principal's group. The dev seat defaults to `shared` and can name an existing target. The CLI accepts `machine add --group G` or global `--group G machine add` and sends the selection in the body. `pubkey` and `device` apply only to `POST /v1/machine-v2`: a present `pubkey` turns registration into one-call enrollment of that key (no join token, no `-v2` suffix), and `device` links the new machine to the caller's device; both are omitted on the wire when nil, so old servers keep reading the body.

`MachineAddOutput.group` echoes the actual registration group on both routes. It is optional on decode for older-server compatibility; a CLI requesting placement must verify an exact echo and fail clearly if the old server ignores the group or returns another placement.

## Frames

A connection carries `Frame` values: `{streamID, opcode, body}` where `body`
is the opcode's payload type. Stream 0 is control (`ControlMessage`); each
exec gets a fresh nonzero `streamID` assigned by the initiating side; VFS
traffic demuxes by its payload's request `id`, not by stream.

Opcode → payload: `control`→`ControlMessage`, `exec-start`→`ExecStart`,
`stdin`→`StdinChunk`, `stdin-eof`→`StdinEOF`, `output`→`OutputChunk`,
`exec-exit`→`ExecExit`, `ack`→`Ack`, `kill`→`Kill`,
`vfs-request`→`VFSRequest`, `vfs-response`→`VFSResponse`.

`search-request` and `search-response` are retired: v1 machines
no longer search. An endpoint answers a `search-request` with a
`search-response` carrying `{id, result: {kind: "error", error: {code:
"invalidArgument", …}}}`, so an old server gets a typed refusal instead of a
hang. Machine search is the v2 `search.v1` operation (ComputerFiles SPEC).

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
  v1 also clears `WUHU_TOKEN_EXPIRES_AT`, never inheriting a v2 expiry;
  absent, it unsets all the reserved names (those four plus `WUHU_ID_TOKEN_URL`
  and `WUHU_ID_TOKEN_REQUEST`, which the server sets in `env`/`secretValues`
  for a session's exec so agents of any version pass them through). An agent that predates the field ignores it
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
- `ExecExit.timedOut` says the start's `timeout` ended the exec: `killed` when the process group was killed and `status` is its own; `statusUnknown` when it was stopped but its status never came back, so `status` is a placeholder. New event consumers emit `.timedOut(outcome:)` after any `.truncated` and before the exit. Absent means the timeout did not end it, however long it ran.

## VFS

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

## Machine v2 dial credential

`MachineV2Connect` is separate from v1: `x-wuhu-machine-v2-key`, `challenge`, `signature`, and `machines` headers carry the enrolled key label, one-shot challenge, raw algorithm-tagged signature and comma-separated addressed machine IDs. Signing bytes are UTF-8 `wuhu-machine-v2-tunnel-connect.v1\n<challenge>\n<sorted machine IDs joined by newline>`. The machine set is signed, duplicate or malformed IDs are refused, and v1 challenge signatures never authorize v2. The credential lists allowed IDs, never an implicit connection-bound machine. Today's enrollment grants one machine per key; a wider requested credential is refused, not silently narrowed. Only the exact `wuhu-fetch-tunnel.v1` WebSocket protocol is selected.

## Machine v2 agent upgrade

`MachineV2Upgrade` is what the server wants a v2 machine to run: `version` (absent when the server is unstamped and no pin names one), `pinned` (an admin pin chose it), `status` (`MachineV2UpgradeStatus`: `ready`, `paused`, `unstamped`, `unpublished`, `unreachable`) and `artifacts`. Only `ready` lists artifacts, and a machine installs only the `MachineV2Artifact` whose `platform` is its own (`macos-arm64`, `linux-amd64`): `url` is the release archive (`.zip` on macOS, `.tar.gz` on Linux, one `wuhu` inside) and `sha256` the lowercase hex digest of the archive bytes, which the machine must verify before installing. Every other status means stay put. The server sends it in the machine's signed hello and at `GET /v1/machine-v2/:id/upgrade` (SpaceServer SPEC).
