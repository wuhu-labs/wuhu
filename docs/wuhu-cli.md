# Wuhu CLI

`wuhu` is the wuhu-core space CLI. It talks to a pinned space server through
the same `POST /v1/tools/<name>` contract the web app and LLM sessions use,
plus the machine and session HTTP routes. Run `wuhu --help` for the verb list
or `wuhu <verb> --help` for per-verb arguments, flags, and exit codes — the
help strings are the authoritative reference; this page organizes them. The CLI
is pre-1.0 and may change with any release.

## Files, search, history

| Verb | Purpose |
| --- | --- |
| `wuhu use <host:port> [--pin] [--group <id>]` | Pin the current checkout wallet to a space server. The certificate must pass system trust; `--pin` instead records its fingerprint (trust on first use) in the user-level `~/.wuhu/trust.json`. `--group` records the wallet's group (see [Groups](#groups)); without it, re-pinning the same server (by `host:port`, however spelled) keeps its group, and pinning another server clears it with a note on stderr. |
| `wuhu trust <host:port>` | Re-record a pinned server's certificate fingerprint after an expected change (reinstall, moved tunnel target). |
| `wuhu untrust <host:port>` | Forget the user-level trust record; the next connection falls back to system trust. |
| `wuhu read <path> [--rev N] [--lines A-B]` | Print file text. Historical reads do not update the wallet etag. `--lines` is a 1-based inclusive range. Fails with `unsupported` on a file that is not UTF-8 text. |
| `wuhu write <path> --body <text> [--force]` | Write UTF-8 `<text>` to a path. Without `--force`, the CLI sends the recorded token or refuses to overwrite an unread existing path. A bare `wuhu write <path>` is a usage error pointing at `put`. |
| `wuhu cat <path>` | Write a path's raw bytes to stdout over `GET /v1/f<path>` — unclamped, byte-exact, no wallet token recorded. |
| `wuhu put <path> [--force]` | Write raw stdin bytes to a path over `PUT /v1/f<path>`. Same overwrite preflight as `write`; records the resulting token. |
| `wuhu transcribe [<file>] [--language <code>]` | Upload an audio file to the space over `POST /v1/transcribe` and print the transcript. Accepts `.wav`, `.mp3`, `.mp4`, `.m4a`, `.webm` up to 25 MiB, refusing an oversized file before the upload. With no `<file>` it prints the provider and model the space would use (`GET /v1/transcribe`), or `no transcriber`. |
| `wuhu edit <path> <old> <new> [--force]` | Apply one text replacement through the server edit tool. |
| `wuhu rm <path> [--force]` | Remove a path and clear its recorded wallet token. |
| `wuhu mv <from> <to> [--replace]` | Move a path and migrate recorded wallet tokens under that path. An existing `<to>` refuses the move; `--replace` replaces an existing file there in the same revision. |
| `wuhu ls [path] [--rev N]` | List entries with compact `d`, `-`, and `t` markers. |
| `wuhu stat <path>` | Print labeled metadata: kind, size, optional line count, token, mtime. |
| `wuhu grep <pattern> [path] [--match-limit N] [--entry-limit N] [--step cursor]` | Search file contents; paged by an opaque continuation cursor. |
| `wuhu find <glob> [path] [--match-limit N] [--entry-limit N] [--step cursor]` | Find paths by glob, same paging contract as grep. |
| `wuhu history <path>` | Print revision history. |
| `wuhu checkout <path> <rev>` | Restore content from a prior revision (mints a new revision; history never rewinds). |

### Text and bytes

Space files hold bytes. The JSON tool wire behind `read`, `write`, and `edit`
carries UTF-8 text only: a `read` of a file that is not valid UTF-8 fails with
`unsupported: <path> is not UTF-8 text` rather than handing back replacement
characters.

Bytes travel over the byte routes on the API origin, `GET /v1/f<path>` and
`PUT /v1/f<path>` — `wuhu cat` and `wuhu put`. They are gated by exactly the
same assertion wall as `POST /v1/tools/*`, so `--public-read` (which opens the
*content* origin) never opens them. The response content type is derived from
the path extension, the same table the content origin uses; nothing about
content type is stored. `GET` carries the version token as an `ETag`, and
`PUT` honors `If-Match`.

## Tables and query

| Verb | Purpose |
| --- | --- |
| `wuhu query <sql>` | Run a SELECT query (SELECT-only, enforced structurally). |
| `wuhu table create <path> <header-json>` | Create a table at a `*.table` path. |
| `wuhu table alter <path> <header-json>` | Replace a table header. |
| `wuhu table mutate <path> <ops-json>` | Apply row operations. |

## Templates

| Verb | Purpose |
| --- | --- |
| `wuhu new <template> [in]` | Instantiate a template file, optionally under `[in]`; prints the new path. |

## Observe

| Verb | Purpose |
| --- | --- |
| `wuhu observe --glob <pattern> [--from REV] [--once]` | Stream mutation events. `--from N` replays committed journal events with rev > N first, then continues live. |
| `wuhu observe --sql <query> [--throttle-ms N] [--once]` | Stream query snapshots, re-delivered when the result changes. |

Both modes print one JSON payload per line (SSE under the hood). `--once` is
intentionally asymmetric:

- `--glob ... --once`: print the first mutation event received and exit. Glob
  events are deltas; any event is news.
- `--sql ... --once`: skip snapshots whose payload hash matches the stored
  cursor, print the first differing snapshot, store its hash, and exit.

SQL observation cursors are keyed by pinned space plus mode plus query, so
different spaces do not share cursors. `--from` applies only to `--glob`.

## Server

| Verb | Purpose |
| --- | --- |
| `wuhu serve <folder> [--host <address>] [--port N] [--web-port N] [--origin <url>] [--web-origin <url>] [--dev] [--public-read] [--dev-import <folder>] [--dev-export <folder>] [--cert <pem> --key <pem>] [--group-certificate <pem> --group-private-key <pem>] [--web-app <dir>]` | Run the space server. |
| `wuhu upgrade [--check] [--lane dev\|beta\|release]` / `--rollback` | Update the installed `wuhu` from `https://wuhu.ai` into `~/.wuhu/bin/<version>/wuhu`, with `~/.wuhu/bin/wuhu` a symlink flipped atomically to the current version; every download is checked against the lane pointer's sha256, and the last 3 versions are kept. `--check` prints the newest release in the lane without installing, `--lane` crosses to another lane, `--rollback` flips back to the previous version. It never touches `PATH`, shells or dotfiles. |

Both listeners bind `--host`, which defaults to `127.0.0.1` (loopback only); `--host 0.0.0.0` exposes them. The API origin binds `--port` (default 5540) and the web-content origin binds `--web-port` (default port + 1). The server always serves TLS: `--cert`/`--key` (given together) name the certificate, else a self-signed one is generated into `<folder>/tls` and reused. Only that generated certificate's fingerprint rides invites, share-login links and machine join tokens; under `--cert`/`--key`, self-signed or not, they carry none and clients rely on their system trust store. `--origin` is the canonical `https://` API origin: `/v1/server` advertises it, share-login and invite links are minted against it, and serve records it with the TLS fingerprint and whether that is the generated certificate in the space database at boot for the offline `wuhu user invite`. `--web-origin` advertises an explicit `https://` web-content origin; without it clients use the same host on the web port. A group is served at `<group>.<host>` of each origin, and `--group-certificate`/`--group-private-key` (a `*.<host>` leaf, together, needing `--origin` and `--cert`/`--key`) is presented to those names by SNI. `--web-app <dir>` serves the SPA from a folder (loaded once at boot; `index.html` required) instead of the embedded build.

The auth walls are on by default: API calls need an enrolled device, and web-content reads need a live browser read session. `--public-read` opens content reads of the `shared` group (the bare host) to anyone, while group hosts still need a read session and writes stay walled; `--dev` drops both walls, for local iteration. See [getting-started.md](getting-started.md#authentication). `--dev-import` imports a plain folder into the space on boot; `--dev-export` dumps the space back to a folder on graceful shutdown. These are independent flags: `--dev` alone neither imports nor exports.

## Device enrollment

| Verb | Purpose |
| --- | --- |
| `wuhu login < invite-link` | Enroll this device at a space from a one-time invite link (`https://host:port/_/enroll#token=jt_...&space=spc_...[&fp=sha256:...]`), read from stdin — never from arguments, since the token enrolls whatever key its holder presents and argv leaks via `ps`: record the delivered fingerprint, if any, into user-level trust (a link without one drops this host's pin once the server passes system trust, and enrolls through the pin when it does not), generate the per-space ed25519 key into `~/.wuhu/keys/spc_<id>.key` if this device has none yet, present the public key. Prints `enrolled <account> (<capabilities>)`; `wuhu use <host:port>` then pins the space. The link dies at enrollment. |
| `wuhu share-login [--ttl <seconds>]` | Mint a one-time login link for this device's account in the pinned space and render it as a terminal QR plus plain URL. Dies at first use or after `--ttl` seconds (default 600, at most 259200, three days). Requires an enrolled device. |
| `wuhu key list [--account <account-id>]` | List enrolled keys: pubkey, capabilities and expiry. Your own account's by default; another account's needs an admin. |
| `wuhu key revoke <pubkey>` | Revoke a key; any assertion it signs is refused from the next request. Your own keys always, other accounts' as an admin. Revoking this device's own key locks it out until it enrolls again. |
| `wuhu device list` | List the app installs signed into the space: `<id> <kind> <machine\|-> <name>`. Devices register themselves on every connect. |
| `wuhu device set <device> [--name <name>] [--machine <machine>]` | Rename a device and/or record which enrolled machine it is (`mc_` id or name). Omitted fields are left alone. |

Device keys are per (device × space), keyed by the space identity (`spc_` plus 32 characters, from `GET /v1/server`): never reused across spaces, never synced. The key file is 0600 in a 0700 `keys/` directory under `~/.wuhu` (or `WUHU_CONFIG_DIR`); a looser mode is refused with the `chmod` that fixes it.

## Users and handles

| Verb | Purpose |
| --- | --- |
| `wuhu user handle <handle> [--display-name <text>]` | Claim a display handle for the identity this device holds in the pinned space; prints `handle @<handle> (<principal>)`. |
| `wuhu user profile` | Print this device's own directory entry: `@<handle> <principal> [display name]`. |
| `wuhu user list` | List the pinned space's accounts (admin): id, kind, admin marker and name. |
| `wuhu user remove <account-id>` | Remove a human account (admin): its device keys, browser logins and outstanding invites die; its history and attribution stay. Refuses the last admin. |
| `wuhu user add --space <folder> [--name N] [--admin]` | Offline, server stopped: create a human account in `<folder>/space.sqlite` and print its id. The first account of an adminless space becomes admin without `--admin`, which makes this also the recovery path when every admin is gone. |
| `wuhu user invite --space <folder> [--server <url>] [--ttl <seconds>] <account-id>` | Offline, server stopped: mint a one-time device invite link for the account (`https://host:port/_/enroll#token=...&space=...[&fp=...]`) for `wuhu login` or a browser. The address and fingerprint come from what the server recorded at its last boot, the fingerprint only if that boot ran the generated certificate (a record from a server that predates this distinction yields none, with a note on stderr, until the next boot); `--server` overrides the address (it must reach the same certificate), and with neither the verb fails. Expires after `--ttl` seconds (default 3600). |
| `wuhu user reset --space <folder> <account-id>` | Offline, server stopped: delete every key and browser login of the account, keeping the account; re-enroll its devices afterwards. |

`add`, `invite` and `reset` work on the space folder directly: possession of the folder is root, and they need no enrolled device and no `--dev`. [getting-started.md](getting-started.md#authentication) walks through the first device.

A handle is display only: it never logs in, never appears in auth, and the persona name stays the principal that rows store. Handles are lowercased, unique per space, renameable by claiming another, and match `[a-z0-9][a-z0-9-]{1,31}`. Claiming a handle rewrites how history renders — nothing is copied onto a message — so a rename re-attributes every message the principal ever sent.

## Machines, exec, vault

| Verb | Purpose |
| --- | --- |
| `wuhu machine add [--name N]` | Mint a machine in the pinned space; prints id, one-time join token (once), and, when the server runs its generated certificate, that certificate's fingerprint. |
| `wuhu machine join <server-url> [fingerprint] [--name N] < token` | Box side: record the fingerprint (if given) into user-level trust, enroll this box's own machine key by consuming the token (read from stdin, never argv), persist the agent config. The box claims `--name`, defaulting to its hostname, if the machine is still unnamed; the server suffixes it until free (`mini`, `mini-2`, …). A machine that already has a name keeps it — rename with `wuhu machine name`, never by rejoining. |
| `wuhu machine run` | Box side: run the machine agent in the foreground (dial loop with signed challenge handshakes, stderr logs). |
| `wuhu machine list` | List machines: `<name\|-> <id> <attached\|detached>`. |
| `wuhu machine name <machine> <name>` | Rename a machine; needs an admin of the machine's group. Names are lowercased, unique per space, and match `[a-z0-9][a-z0-9.-]{0,62}`. |
| `wuhu machine rotate <machine>` | Kick the machine's enrolled key (dropping any live connection) and mint a fresh join token; rejoin the box with it. |
| `wuhu machine revoke <machine>` | Kick the key and drop any live connection; rotate re-enables the machine. |
| `wuhu machine move <machine> --group <group>` | Move a machine to another group, so the sessions of the groups that read that group may exec on it. Needs an admin of both groups. Its notes under `/_/machines/<name>/` move into the new group's tree in the same revision. |
| `wuhu vault set <machine> <NAME>` | Store a secret on the machine. Value from stdin, never argv (argv leaks via `ps`). |
| `wuhu vault list <machine>` | List secret names. No surface ever returns a value. |
| `wuhu vault remove <machine> <NAME>` | Delete a secret. |
| `wuhu secret set <NAME>` | Create or replace a space secret for `run_script` (`wuhu:secret`). Value from stdin, never argv. |
| `wuhu secret list` | List space secret names. No surface ever returns a value. |
| `wuhu secret remove <NAME>` | Delete a space secret. |
| `wuhu exec --cwd machines://<machine>/<path> [flags] -- <command...>` | Run a command on a machine, duplex and pipe-clean. |
| `wuhu ps` | List live execs: `<exec-id> <machine-id> <started> <command>`. |
| `wuhu kill <exec-id>` | Kill an exec; the agent kills the process group it owns. |

A `<machine>` argument is the machine's name or its `mc_` id — every machine verb, `--cwd` included, takes either, and the id never changes under a rename.

### Exec

`wuhu exec` is a byte pipe, not a terminal: command stdout/stderr map to local
stdout/stderr byte-exactly with zero decoration, all CLI diagnostics go to
stderr, and local stdin streams to the command's stdin (immediate half-close
when local stdin is a terminal — no PTY, ever). Policy knobs live here, not in
the protocol: `--window` defaults to 4 MiB, `--max-output` and `--timeout`
default to off. `--secret ENV=NAME` injects a vault secret as an environment
variable; the machine masks its value in the output stream.

The CLI auto-reconnects across network blips with the same exec id and resumes
byte-exactly (first redial is immediate, then doubling backoff from 200 ms
capped at 30 s). After each sever it consults `GET /v1/exec/:id`; the retry
budget spans roughly 90 seconds of an unresponsive server — past the server's
own 60 s caller-absence grace, so a longer wait could never help.

Exit codes: the command's exit code passes through; a signal death exits
`128+SIG` (kill, `--timeout`, and `--max-output` all surface as signals, the
latter with a loud `truncated` diagnostic on stderr); `125` machine lost
(partial output); `124` exec cancelled server-side; `123` output tail no longer
replayable after the command finished; `122` server unreachable; `64` usage;
`1` runtime error.

## Sessions and messaging

| Verb | Purpose |
| --- | --- |
| `wuhu session compact <session-id> [--instructions ...]` | Ask a session to fold its context at its next quiet point. A Claude Code session writes `/compact [instructions]` on its process's standard input between turns, never mid-turn. A kernel session pins its next settled turn to the compact tool, with the instructions injected first as one `compact request` notification. Either way the boundary and the resulting summary land in the session log. |
| `wuhu session create [--kind agent\|task] [--top-level] [--home-group G] [--provider P] [--model M] [--effort E] [--template N] [--tag T]... <title>` | Create an inert session and its owning channel. From a session's exec it is that session's child — a task unless `--kind agent`, on the parent's model unless named — and `--top-level` (agents only) makes a top-level agent instead; see *Session execs* below. Provider and model are required, validated against `/models.json`; effort defaults to the model's declared default. The provider's dialect picks the executor: a `claude` provider runs Claude Code, every other one the kernel loop. `--template N` applies `/templates/N/template.json` underneath the flags (its `kind` stands in for `--kind`) and clones the template's other files into the session's home — denormalized at creation, explicit flags win, later template edits never touch existing sessions. `--home-group G` places a top-level agent in group `G`, which the acting group must read; a child always lives in its creator's group. |
| `wuhu session restart [--provider P] [--model M] [--effort E] [--message TEXT] <id>` | Start the session over: same id, same box, same DMs, same home folder, empty transcript. Drops undrained work, subscriptions and timers, and clears the interrupt/error axes. Omitted fields keep the live spec on the same provider, so a bare restart is a pure wipe; naming another provider keeps nothing of the old model, and the new spec is validated exactly as `session create` does. Refused while the session has unfinished work. `--message` posts an opening input so the fresh session starts working. |
| `wuhu session request [--deadline SECS] <id> <message>` | A session's exec only: open a request on a child of the session, posted into their DM; prints `requested <request-id> in <conversation-id>`. |
| `wuhu session rename <id> <title>` | Retitle a session. The title is trimmed, one non-empty line, at most 200 characters. |
| `wuhu session interrupt <id>` | Stop after the current step; resume to continue. |
| `wuhu session resume <id>` | Clear interrupt/error and continue. |
| `wuhu session archive <id>` | Archive a settled session (a grace window applies). |
| `wuhu session unarchive <id>` | Restore within the grace window. |
| `wuhu session tags <id> [<tag>...]` | Replace the session's tags with the ones given (none clears them), on any lifecycle; prints the stored tags one per line. |
| `wuhu session log [--direct\|-v\|-vv] [--limit N] [--before REF] <id>` | Read a session's channel, or with `--direct` its transcript at three verbosities. |
| `wuhu session entry <id> <ref>` | Print one direct-view item in full, unclipped. |
| `wuhu session list` | List sessions (sugar over `query` against the induced `sessions` table). |
| `wuhu send <session-id> <message> [--wait [--timeout SECS]]` | Post as your wallet identity into an agent's box; a task refuses it with `403 taskInput`. |
| `wuhu send <session-id> <message> --attach PATH ...` | Attach local files of any type to the post. Repeatable. |
| `wuhu inbox` | Print notifications above this wallet's client cursor for the pinned space, then advance the cursor. Empty output means nothing new. One inbox and one cursor span all your groups, so switching `--group` replays nothing; each line names its group, and an outside sender shows with theirs. |
| `wuhu models update` | Merge the published well-known models basis into `/models.json` (additive; user edits win). |
| `wuhu usage [--json]` | Print the plan usage the server last observed for each `codex` and `claude` provider, window by window with its reset time (`GET /v1/providers`). Inference refreshes it; the server reads it itself when a provider has gone fifteen minutes unobserved. |
| `wuhu tool-roster [--executor kernel\|claude-code] [--json]` | Print the tool roster the server hands its sessions — name, one-line description, and parameters with `*` on the required ones. Without `--executor` both rosters print; `--json` is the raw `GET /v1/session-tools` payload with full parameter schemas. |
| `wuhu auth set <provider>` | Store an API key for a provider (stdin) in the per-space credential file on this host. |
| `wuhu auth login <provider>` | Chooses by `/models.json` dialect: ChatGPT device-code login for `codex`, or installs pinned Claude Code and stores a setup token for `claude` (stdin when redirected, prompt at terminal). |
| `wuhu auth list` / `remove` / `logout` | Inspect and drop stored credentials (logout also revokes the ChatGPT tokens). |

`send --wait` blocks until the session posts back into that conversation, and exits nonzero if the session errors (or is already errored). `--timeout` gives up after SECS (nonzero exit).

`send --attach PATH` (repeatable) uploads each local file with the post as a `multipart/form-data` part; the server stores them write-once under `/_/conversations/<conversation>/attachments/YYYY/MM/DD/HHmmssZ/<file name>` in the same transaction as the message. At most 8 files per message, of any type, each at most 50 MiB and 150 MiB in all; the CLI checks the count and sizes before it sends anything, and the server refuses the same limits with an error naming the file. A `png`, `jpg`, `jpeg`, `gif` or `webp` whose bytes match its extension is stored as an image, which a receiving session sees as an image when it is at most 3 MB; any other file reaches a session as one line with its path, type and size.

`session log` defaults to the session's channel for every executor: each message's `[n]`, its sender as `handle (id)` for a person, the sender kind, time, message kind, `id <message id>`, the reply target, and one `attached: <path>` line per attachment. A task has no box, so its channel view answers `notFound`. `--direct` reads the transcript instead: `--direct` is the narrative (inputs, reminders, assistant text, replies, compaction markers), `-v` adds tool calls, reasoning summaries and cumulative context usage, and `-vv` adds tool results. A Claude Code session's transcript is translated from its stored log, so Wuhu tools show under their own names and Claude Code's own as `ClaudeRead`, `ClaudeWrite`, `ClaudeEdit` and `WebSearch`. Every direct-view item carries a `[ref]` for `session entry`; refs are short-lived, and compaction invalidates them.

## Agent skills

| Verb | Purpose |
| --- | --- |
| `wuhu skill export` | Install the bundled agent skills into coding agent homes. |

The binary embeds two authored skills (`wuhu`, `wuhu-cli`; source of truth in
`packages/wuhu-core/Targets/CLIKit/Sources/Skills/`, packed by the Bazel
`embedded_directories` step — a SwiftPM build has none and the verb says so).
`wuhu skill export` installs them as `<name>/SKILL.md` under both
`~/.claude/skills/` (Claude Code) and `~/.agents/skills/` (the Agent Skills
standard location scanned by Codex CLI and pi). It prints one line per file —
`wrote`, `updated`, or `unchanged` — and refuses to touch an existing SKILL.md
that lacks its install marker, so a user's own skill named `wuhu` is skipped,
never overwritten.

## Machine agent state

The box side (`wuhu machine join` / `wuhu machine run`) persists its state
under `~/.wuhu/machine`: `agent.json` (server URL, machine id — file mode
0600), `machine.key` (the box's ed25519 machine credential, 0600 in the 0700
directory, distinct from any device key under `~/.wuhu/keys/`) and `state/`
(the agent's vault and working state). Server trust
is not part of this state; it lives in the user-level `~/.wuhu/trust.json`
shared with every other client on the box. This is the one
deliberate exception to the wallet rule below: agent identity is per box, not
per checkout.

## Wallet

The CLI wallet is strictly a `.wuhu` directory found by walking up from the current working directory. If no walk-up wallet exists, `wuhu use <host:port>` creates `./.wuhu/config.json`; other bare-path commands fail with:

```text
no space pinned; run: wuhu use <host:port>
```

The wallet intentionally never lives in `~/.wuhu`: that directory is user config — the server trust store (below), the device keys under `~/.wuhu/keys` (above), and the machine agent state under `~/.wuhu/machine` — never a `use` binding or identity. `WUHU_CONFIG_DIR` redirects the whole user-config directory (trust store and machine state alike); an empty `WUHU_CONFIG_DIR` or empty/unset `HOME` is a loud error, never a silent fallback.

Wallet files:

```text
.wuhu/config.json                         {"space":"host:port","group":"<id>"}   group optional
.wuhu/etags.json                          {"<space>|<canonical-path>":"<VersionToken>"}
.wuhu/observations/<sha256>.json           {"hash":"<sha256(payload)>"}
```

With a group selected, the etag, observation and inbox cursor keys become `<space>|<group>|…` so groups never share read-before-write tokens or cursors; with none they are exactly the keys above.

`etags.json` and observation state are caches. If malformed, the CLI warns and treats them as empty. A malformed `config.json` is a usage error with a repair hint.

Server trust is user-level, not wallet-level: `~/.wuhu/trust.json` (override
the directory with `WUHU_CONFIG_DIR`) maps `host:port` to a
`sha256:<hex>` certificate fingerprint. It holds only the PKI exceptions:
`wuhu use` requires the OS trust store to validate the server and records
nothing on success; `wuhu use --pin` opts into trust-on-first-use and records
the fingerprint, honored from every working folder on HTTP, SSE, and
WebSocket dials. A pin mismatch is a hard failure naming both fingerprints;
the only way forward is the explicit `wuhu trust <host:port>` re-trust verb —
no flag skips verification. `wuhu untrust <host:port>` forgets the record.
`wuhu login` records the fingerprint its invite link carries, so a `use`
after it needs no `--pin`. Machine agents resolve trust from the same store with the same
rules — a recorded pin means a pinned dial, otherwise system trust — so
`machine add` prints the server certificate fingerprint next to the join
token, and `machine join <server-url> <fingerprint> < token` records it
before the first dial (trust rides the token's own out-of-band channel; no
first-connect window). Without a fingerprint, `machine join` requires the
server to pass system trust unless the box already pins the host. Re-enrolling
replaces the pin: a `login` or `machine join` with a fingerprint records it
over the old one, and one without drops the host's pin once the server passes
system trust; when it does not, the existing pin carries the enrollment and
stays.

The wallet also caches the seat's messaging identity: a stable persona name
drawn by the server (`POST /v1/persona`, allocator word-name genre) against
this device's enrolled key, once per wallet × space, and reused on every
subsequent verb. `send` and `inbox` act as that identity; two work folders
are two distinguishable senders. An unenrolled seat has no persona and acts
as the owner.

## Groups

A space holds groups: `shared`, and one personal group per person. A request names the group it acts in with a `Wuhu-Group: <id>` header; the CLI takes the id from, in order, the global `--group <id>` (written before the verb: `wuhu --group <id> ls /`), `WUHU_GROUP`, and the wallet's `"group"`. With none it sends no header and the server picks, so every command's requests are exactly what they were before groups. The group never goes into the host, so trust pins keyed by `host:port` are unchanged.

| Verb | Purpose |
| --- | --- |
| `wuhu group list` | Print the space's group ids (`GET /v1/groups`). |
| `wuhu group use <id>` / `--clear` | Record the wallet's group in `.wuhu/config.json` after checking the server has it, or remove it. `--group` and `WUHU_GROUP` still win. It ignores the configured group, so it repairs an invalid one; so does `wuhu use`. |
| `wuhu group set --space-layer on\|off <id>` | Whether the sessions of group `<id>` render the space-wide instruction layer (`shared`'s `/AGENTS.md` and skills); they pick the change up at their next turn. Needs an admin of the group (`PUT /v1/groups/<id>`). Prints `<id> space-layer on\|off`. |
| `wuhu group current` | Print the selected group and its source; with none, the group the server picks for this caller (`group` in `GET /v1/server`), or `none` on a server without groups. |

A selected group is never dropped: when `GET /v1/server` answers without `groups` in `features`, the command fails with `this server has no groups` before sending anything else; when the probe itself fails, that failure is the error. In a session's exec the acting group is the session's; `--group` and `WUHU_GROUP` are refused there.

## Session execs

An exec a session runs — its `exec` tool or a `run_script` spawn — is started
with `WUHU_EXEC=1`, `WUHU_TOKEN` (a per-exec token, masked in the exec's
output, dead once the exec ends, its timeout passes or the server restarts)
and `WUHU_SPACE_URL`. The server owns those three names: it strips them from
any caller's `env` and `secrets`, and the machine agent unsets them for every
other exec. The agent also unsets a `WUHU_IDENTITY` or `WUHU_GROUP` it
inherited, unless the exec itself sets it.

With `WUHU_EXEC` set (any non-empty value), the CLI acts as that session on
that space, in its group. `WUHU_IDENTITY` may be unset or `session`; `WUHU_IDENTITY=wallet`,
`--group` and `WUHU_GROUP` are refused, because each would act outside the
session's group. It reads no wallet and no device key — a cwd
pinned elsewhere changes nothing, and an address on another server is
refused. Read-before-write tokens and observe cursors live in a scratch
folder under the temp directory keyed by the token. The server applies the
session's own rules (home rule, ancestry, child-only create, own
execs only). The home rule covers every verb that writes: the file verbs,
`checkout`, `table create|alter|mutate` and `new`, which checks its `in`
folder, else its template's, where the instance lands. Verbs a session lacks — `user list|handle|profile|remove`, `key`, `vault`, `auth`,
`machine add|join|run|rotate|revoke`, `models update`, `use`, `trust`,
`untrust`, `login`, `share-login`, `group use`, `upgrade` (all but
`--check`, since on a server's host it swaps the binary the server runs), and
every other route the server keeps for people — fail with exactly `not
available to a session`. `serve`, `upgrade --check` and `user add|reset
--space` open no wallet and act on no space, so they run. `send`
refuses `--wait` and `--attach`. A missing `WUHU_TOKEN` or `WUHU_SPACE_URL`,
or a token the server rejects, is an error saying which — never a fallback
to the wallet.

These refusals are advisory, not a boundary: they keep an exec's CLI in its
session's group, but a process that unsets `WUHU_EXEC` can still reach a
wallet in its cwd.

Without `WUHU_EXEC` — a person's terminal — none of this applies and
`WUHU_IDENTITY` is ignored.

## Addressing

- `/path` uses the pinned space and sends `/path` to the server.
- `wuhu://host:port/path` routes to `host:port` and sends `/path`. `wuhu://`
  means TLS, full stop — servers always speak TLS and there is no loopback
  exception; a bare `host:port` dials `https://host:port`.
- `path@rev` is passed through for the server to resolve as a historical view.
- `machines://<id>/<path>` passes through to the pinned space, which routes the
  fs tools to that machine (raw fs: no revisions — a `@rev` suffix on a machine
  address fails `unsupported`).
