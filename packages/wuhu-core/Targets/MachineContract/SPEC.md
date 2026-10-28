# MachineContract

The machine admin and v2 dial contracts, shared filesystem operation values, and the exec frame protocol retained for the v2 caller adapter. Swift is the source of truth; `Tests/contract/*.schema.json` are derived golden fixtures. The target imports only `Contract` and `JSONValue`.

## Encoding conventions

- **Discriminated unions** (`ControlMessage`, `ExitStatus`, `ExecEvent`, `VFSOp`, `VFSResult`) are **internally tagged**: `{"kind": "<case>", …flattened labeled values}`, never externally tagged, never a `_0` key.
- **Optional fields** are omitted when absent (never explicit `null`) and are absent from the schema's `required`.
- **`Base64Data`** crosses the wire as a base64 string inside the JSON payload. All byte accounting — cursors, `window`, `maxOutput` — counts **decoded raw bytes**, never base64 characters.

## Machine registration

`MachineAddInput` carries optional `name` and `group` for `POST /v1/machine-v2`. For people, an omitted group preserves personal-group registration; an explicit group must exist (`404 unknownGroup`) and admit the caller as an admin (`403 adminRequired`), just as the target of a machine move does. Sessions always register in their principal's group. The dev seat defaults to `shared` and can name an existing target. The CLI accepts `machine add --group G` or global `--group G machine add` and sends the selection in the body. `pubkey` and `device` apply to registration: a present `pubkey` turns registration into one-call enrollment of that key (no join token), and `device` links the new machine to the caller's device; both are omitted on the wire when nil, so old servers keep reading the body.

A machine move requires admin rights for both its source and target groups. Its HTTP 403 uses `MachineAdminErrorCode.adminRequired` (`adminRequired`); client presentation selects its own localized copy from the code, not the diagnostic `message`.

`MachineAddOutput.group` echoes the actual registration group. It is optional on decode for older-server compatibility; a CLI requesting placement must verify an exact echo and fail clearly if the old server ignores the group or returns another placement.

## Frames

The caller-facing exec connection carries `Frame` values: `{streamID, opcode, body}`. Stream 0 carries `ControlMessage`; each exec gets a fresh nonzero stream ID assigned by the initiating side.

Opcode → payload: `control`→`ControlMessage`, `exec-start`→`ExecStart`, `stdin`→`StdinChunk`, `stdin-eof`→`StdinEOF`, `output`→`OutputChunk`, `exec-exit`→`ExecExit`, `ack`→`Ack`, `kill`→`Kill`. VFS and search are v2 operations, not frame opcodes.

## Ids and enrollment tokens

- `MachineID` = `mc_` + 8 and `ExecID` = `ex_` + 8, over the lowercase alphanumeric alphabet `[a-z0-9]`. Suffixes are random, never sequential. Decoding is total (any string decodes); `isValid` is the shape gate, enforced at minting and at trust boundaries, and the derived schemas carry the grammar as `pattern`.
- The one-time join token (`jt_` + 32, minted by the space's unified enrollment) appears on the wire exactly twice: `MachineAddOutput` and `MachineRotateOutput` (minted, shown once). The box consumes it at `/v1/enroll/consume`, enrolling its own ed25519 key; no machine credential is retained server-side beyond the key row, and no token appears in any list/status output.
- `ExecID` is server-minted before `exec-start` and the frame carries it, so a retried start after a blip is idempotent — the machine spawns at most one process per exec id.

## Exec

- `ExecStart.cwd` is an **absolute path on the machine**. The `machines://<id>/<path>` addressing is resolved caller/server-side to pick the machine; only the machine-local path crosses this wire.
- `command` is argv: `command[0]` is the executable; no shell interpretation.
- `env` and `secrets` absent mean empty. `secrets` maps environment names to names in the executing machine's group. The server resolves these names into `secretValues` for the v2 operation; missing names fail before spawn. The machine injects the values and masks non-empty values from output.
- `session` (`ExecSessionCredential {token, spaceURL}`) and `secretValues` remain in the exec frame schema. The v2 relay does not trust caller-supplied credentials or resolved secret values: it mints the operation credential from the authenticated session and resolves `secrets` names itself.
- `window` absent means `ExecDefaults.window` (4 MiB); it is the un-acked flow-control window and the reconnect replay buffer, always finite.
- `maxOutput` is a total-output byte cap; on exceed the exec is killed and the caller sees `ExecEvent.truncated(limit:)` before the exit event. `timeout` is wall-clock **seconds**, fractional. Both absent mean unlimited.
- **Cursors** are byte offsets of a chunk's first byte. Output has one cursor space per exec: stdout and stderr count into a single merged sequence in emission order. Stdin has its own cursor space; `StdinEOF.cursor` is the total stdin length, making the half-close position unambiguous across reconnects. `ExecExit.cursor` is the total output length. `Ack.cursor` acknowledges every byte below it (receiver→caller acks stdin, caller→receiver acks output); the producer retains un-acked bytes for replay.
- `ExitStatus` is `exited(code:)` or `signaled(signal:)`; kills (caller kill, timeout, `maxOutput`, disconnect past grace) surface as `signaled`.
- `ExecEvent` is the caller-leg union. `failed(error:)` is terminal; `machineLost` there means the machine stayed gone past its grace and the output already delivered is all there is.

## Exec replay retirement and output cutoff

- `ControlMessage.hello.execs` optionally scopes incoming-exec replay to those ids. New caller endpoints list their outgoing execs; the server scopes a caller leg to its authorized exec. An empty list requests none, while an absent list preserves legacy unscoped replay. Outgoing-exec resume is unaffected, so a machine reconnect still recovers starts lost during its outage.
- `Ack.terminal = true` acknowledges the exit and its entire output at `ExecExit.cursor`. It is sent only once the consumer has its durable result (or has consumed the exit for streaming callers). A matching terminal ACK retires the receiving endpoint's full exec state; byte ACKs alone do not. Unacknowledged finished state expires 10 minutes after exit, even disconnected.
- `ExecExit.outputCut = true` means stopping the command forcibly cut off output admission; unsent bytes are discarded, and unread pipe data may be lost. Its cursor still counts bytes admitted to the wire, preserving replay for older consumers; the unsent suffix cannot hold kill/timeout behind a full window. New event consumers emit `.truncated(limit: cursor)` before the exit. Absent `outputCut` means the peer made no cutoff claim.
- `ExecExit.timedOut` says the start's `timeout` ended the exec: `killed` when the process group was killed and `status` is its own; `statusUnknown` when it was stopped but its status never came back, so `status` is a placeholder. New event consumers emit `.timedOut(outcome:)` after any `.truncated` and before the exit. Absent means the timeout did not end it, however long it ran.

## VFS

- Machine fs is raw: **version token = mtime**, opaque on the wire (`MachineEntry.token`, `VFSResult.file/written` tokens; `ifMatch` gates write/rm). `mtime` is seconds since the Unix epoch, UTC, fractional.
- There is no edit op: the resolver arm composes read → fuzzy match → write-if-token-unchanged server-side.
- `VFSOp` and `VFSResult` are shared values used to translate v2 filesystem operations. `read` accepts optional `offset` (default 0) and `length` (default remaining bytes); negative ranges fail with `invalidArgument`, and a range past EOF is empty. Reads are bounded by `VFSDefaults.maxReadBytes` (8 MiB), with oversized requests failing as `tooLarge`. Every range carries the file token.

## Machine v2 dial credential

`MachineV2Connect` authenticates the tunnel: `x-wuhu-machine-v2-key`, `challenge`, `signature`, and `machines` headers carry the enrolled key label, one-shot challenge, raw algorithm-tagged signature and comma-separated addressed machine IDs. Signing bytes are UTF-8 `wuhu-machine-v2-tunnel-connect.v1\n<challenge>\n<sorted machine IDs joined by newline>`. The machine set is signed, duplicate or malformed IDs are refused. The credential lists allowed IDs, never an implicit connection-bound machine. Today's enrollment grants one machine per key; a wider requested credential is refused, not silently narrowed. Only the exact `wuhu-fetch-tunnel.v1` WebSocket protocol is selected.

## Machine v2 agent upgrade

`MachineV2Upgrade` is what the server wants a v2 machine to run: `version` (absent when the server is unstamped and no pin names one), `pinned` (an admin pin chose it), `status` (`MachineV2UpgradeStatus`: `ready`, `paused`, `unstamped`, `unpublished`, `unreachable`) and `artifacts`. Only `ready` lists artifacts, and a machine installs only the `MachineV2Artifact` whose `platform` is its own (`macos-arm64`, `linux-amd64`): `url` is the release archive (`.zip` on macOS, `.tar.gz` on Linux, one `wuhu` inside) and `sha256` the lowercase hex digest of the archive bytes, which the machine must verify before installing. Every other status means stay put. The server sends it in the machine's signed hello and at `GET /v1/machine-v2/:id/upgrade` (SpaceServer SPEC).

## Exec registry inputs and status

`ExecMintInput.spec` is optional opaque JSON for a tool-call exec claim; a plain mint does not use it. `ExecMintInput.script` names the `run_script` execution that owns the exec: the row's `caller` is the minting session, and the server kills what the script still runs when the script ends. `ExecStatus.toolCallID` identifies the session tool call that claimed an exec, or is absent for ordinary and script mints. `ExecStatus.killDelivered` says the kill reached the machine, so a `cancelled` exec may still settle with the process's real output and exit.
