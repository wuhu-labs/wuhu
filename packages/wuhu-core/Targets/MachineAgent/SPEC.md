# MachineAgent

The daemon side of the machine domain: one `MachineAgent` owns one
`ChannelEndpoint`, dials the server forever, runs execs as real subprocesses,
serves VFS/search requests, and enforces the output policy machine-side.
MachineContract pins the wire vocabulary; MachineChannel pins channel behavior;
this file pins the agent semantics on top.

## Surface

`MachineAgent(stateDirectory:killGrace:disconnectGrace:)` plus
`run(dial:)` — that is the whole public surface. `dial` returns a fresh
`FrameTransport` per (re)connection; production hands in the WebSocket dialer
(a later milestone), tests hand in in-memory pairs. The production dialer
announces `group-secrets` in MachineContract's capabilities header on every
dial: this agent takes secret values from the exec start and resolves no name
itself. `run` returns only on task cancellation. The clock is `@Dependency(\.continuousClock)`, captured at init.

## Connection lifecycle

- Dial with deterministic doubling backoff (1s, 2s, 4s, …, capped at 30s, no
  jitter), reset after every successful binding. Cancellation is the only stop
  signal.
- **Server-absence grace (5 min default)**: while unbound, live execs keep
  running; if a disconnection persists past `disconnectGrace`, every live exec
  group is SIGTERM-then-SIGKILLed, and dialing continues forever. Reconnect
  within the grace resumes streams seamlessly (channel replay). Exit events
  recorded while unbound replay on the next binding.

## Exec

- Spawned via swift-subprocess in its **own process group**
  (`processGroupID = 0`), never a PTY, pipes only. `command` is argv
  (`command[0]` resolved via PATH when it contains no `/`, else as a path); no
  shell. Environment = agent environment ∪ `env` ∪ `secretValues` ∪ the
  session names, rightmost wins. The session names are the server's:
  with `session` present, `WUHU_EXEC=1`, `WUHU_TOKEN` = its token and
  `WUHU_SPACE_URL` = its `spaceURL`; without it, all three are **unset**, so
  an agent that itself runs inside a session's exec never passes its own on.
  `WUHU_IDENTITY` and `WUHU_GROUP` are **unset** unless the exec start itself
  sets them (in `env` or `secretValues`): ones inherited from the agent's
  own environment never reach an exec, so an agent started in wallet mode or
  in a group does not put its execs there.
- **Kill escalation** (kill frame, timeout expiry, maxOutput exceeded,
  server-absence grace): SIGTERM to the group, then `killGrace` (5s default,
  clock-injected), then SIGKILL to the group. Supervision lasts until the process exits, independently of stdout/stderr EOF; once TERM is sent, escalation still completes for surviving group members even if the direct child exits first. Under task cancellation (agent orderly
  shutdown) swift-subprocess's uncancellable teardown runs the same
  TERM → grace → KILL against the group, with the grace on the library's own
  wall clock.
- **Exit status** is faithful: `exited(code)` or `signaled(signal)`; every
  escalated kill surfaces as `signaled`.
- **Failure shape**: a secret handed over by name, empty command, and spawn failure
  (missing executable, bad cwd) surface as one `wuhu: …` line on stderr
  followed by `exited(code: 127)` — the wire has no separate failure op; the
  caller-facing `ExecEvent.failed` is composed by the caller leg.
- **Orphans**: agent crash (SIGKILL) leaks the child groups — accepted; there
  is no pid ledger. Closing stdout/stderr does not detach the direct child from timeout or kill supervision.

## Enforcement locus

`maxOutput` and `timeout` are enforced **machine-side**, so they survive
caller blips:

- `maxOutput` budgets masked output across stdout and stderr together. On exceed, total transmitted output is **at most**, not necessarily exactly, `maxOutput`, and the group is killed. The final allowed prefix is sent only while the window has room; its unsent suffix is dropped rather than delaying termination. For example, an unread one-byte window with a two-byte budget and a three-byte output chunk emits one byte before terminating. `ExecExit.outputCut` records a cutoff, rendered as `ExecEvent.truncated` before the exit.
- `timeout` is wall clock from spawn on the injected clock; expiry kills the
  group.

Backpressure is the channel window: `send` suspends when the window fills,
which stops the pipe read loop, so the child blocks on write — local-pipe
semantics, no loss during normal execution, no unbounded per-exec buffer. Kill and timeout stop output admission and wake blocked sends: unsent output is discarded and the exit is marked `outputCut` (unread pipe data may also be lost on termination). Already-transmitted bytes keep their cursors and remain replayable until terminal acknowledgement or expiry, including for older callers.

Finished execs retain replay state for at most 10 minutes from exit, including while disconnected. A terminal acknowledgement releases output, start/environment/credentials, streams and bookkeeping immediately; an older server sends no terminal acknowledgement and uses the expiry. The agent owns the endpoint retention task alongside connection and request serving.

## Secrets

- The agent keeps no secrets. `exec-start.secretValues` (`ENV_NAME → value`,
  resolved by the server in the machine's group) injects as environment only,
  at spawn; no value is written to disk, logged, or interpolated into an
  error.
- `exec-start.secrets` present and non-empty means a server from before
  group secrets, which expects the agent to resolve names itself. The agent
  spawns nothing and fails the exec (see failure shape) with `wuhu: secret
  NAME came as a name, not a value; this machine's server predates group
  secrets`, naming the lexically first secret.
- A `<stateDirectory>/vault.json` left by an agent from before group secrets
  is never read, changed or removed; `run` logs one notice line that it is no
  longer used.
- **Masking** covers the `secretValues` values and the session token
  (that is what this exec can leak), independently per output stream, replacement `***`. The streaming
  masker holds back exactly the bytes that are a proper prefix of some secret
  (at most `maxSecretLen − 1`), so chunked output is byte-identical to
  whole-string masking; the holdback flushes at stream end. Matching is
  greedy longest-match over UTF-8 bytes; empty values inject but do not mask.

## VFS

Ops execute against the real filesystem at the request's absolute path, each
request in its own task. Version token = mtime: the decimal string of
`timeIntervalSince1970` (also `MachineEntry.mtime`), opaque to callers and
compared as an exact string. Two writes within the filesystem's timestamp
granularity can share a token — accepted for a raw box.

- `stat`/`ls` use lstat semantics (symlinks report as themselves); `ls` sorts
  by name.
- `write` with `ifMatch` requires the entry to exist with that exact token,
  else `conflict`; without `ifMatch` it creates or overwrites unconditionally.
  `rm` honors `ifMatch` the same way and removes directories recursively.
- `mkdir` creates intermediates. `mv` fails `conflict` if the destination
  exists.
- `read` is bounded at **8 MiB** (`VFSDefaults.maxReadBytes`): a response is one
  wire frame, and the bound keeps its base64 body safely under the server's
  16 MiB WebSocket frame ceiling. A whole-file read of a bigger file fails
  `tooLarge` (checked before reading; the size at stat time decides), never
  severs the channel. A ranged read (`offset`, `length`) returns up to the
  bound from anywhere in the file, which is how the server reads a machine
  file for an attachment; a range longer than the bound is `tooLarge`.
- Missing entries are `notFound`; other filesystem failures are `io`.

## Search

Machine-side matcher, no shelled-out grep, mirroring SpaceTools semantics so
M5 can assert space/machine parity for identical contract inputs:

- **grep**: pattern is an `NSRegularExpression`, matched per line; defaults
  `matchLimit` 50, `entryLimit` 1000 (files scanned per page); limits must be
  ≥ 1 else `invalidArgument`. Cursor is `line@path`, parsed at the first `@`.
  A page stops with a cursor when the entry limit is reached (next unscanned
  file, line 1) or the match limit is hit (that match's position, re-emitted
  on resume). Unreadable files fail the page with `io`. `path` omitted means
  `/`; a file root scans just that file. Symlinks are skipped.
- **find**: glob (SpaceFS `Glob`, the space-side dialect) matched against the
  absolute path; same defaults and cursor discipline, the cursor being the
  next path to consider. Files and symlinks are leaves; directories are not
  emitted.
- **Traversal order** is the lexicographic order of absolute paths (what a
  flat `.sorted()` over the tree yields), streamed without materializing the
  tree: sibling sort keys append `/` to directory names, and resume prunes
  subtrees below the cursor. Every page is bounded by `entryLimit` regardless
  of tree size.
