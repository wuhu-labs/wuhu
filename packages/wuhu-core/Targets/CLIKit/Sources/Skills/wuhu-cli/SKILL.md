---
name: wuhu-cli
description: Drive the wuhu CLI correctly — exact verb syntax, JSON argument shapes, wallet/token behavior, session and messaging verbs, and the sharp edges (quoted table paths, bare JSON args, text vs byte writes, observe cursors, --wait vs --direct). Use whenever running wuhu commands against a space server. For the conceptual model of spaces, load the wuhu skill.
---

# wuhu CLI

Every command prints usage with `wuhu <verb> --help`. Exit codes: `0` ok,
`64` usage error, `1` runtime error (server errors print `code: message` plus
an optional `hint:` on stderr).

## Pinning: `wuhu use`

```bash
wuhu use localhost:5599
```

Creates `./.wuhu/config.json` in the **current directory** (unless a `.wuhu`
directory already exists in some ancestor — the wallet is found by walking
up). After pinning, bare paths like `/notes/plan.md` go to that space.
`~/.wuhu` is never a wallet; there is no home fallback. Any verb also accepts
full addresses without a pin: a file's share link `https://host:port/path`, or its
`wuhu://host:port/path` twin. `path@rev` reads a
historical view; `machines://<name-or-id>/<path>` targets a machine's raw fs.
`wuhu://<group>.localspace/<path>` is another group of the pinned space, never a
space to dial: every file verb takes it, and a group your acting group does not
read answers `notFound`.

Servers always speak TLS (`wuhu://` means TLS; bare `host:port` dials
`https://`). The certificate must pass system trust; for a self-signed server
run `wuhu use host:port --pin` to record its fingerprint (trust on first use)
in the user-level `~/.wuhu/trust.json`, honored from every working folder. If
the server's certificate legitimately changed and commands fail with a
`server certificate changed` message, re-record it with `wuhu trust host:port`
— no flag skips verification. `wuhu untrust host:port` forgets the record.

A space may hold several groups. `wuhu group list` prints them, `wuhu group
use <id>` (or `wuhu use host:port --group <id>`) records the one this wallet
acts in, `wuhu group use --clear` drops it, and `wuhu group current` says
which one applies. `wuhu --group <id> <verb> …` or `WUHU_GROUP=<id>` override
it for one command. With none the server picks; naming a group on a server
without groups fails.

## Inside a session's exec: you are the session

An exec a session runs (its `exec` tool, or a `run_script` spawn) carries
`WUHU_EXEC=1`, `WUHU_TOKEN` and `WUHU_SPACE_URL`, set by the server. There
`wuhu` acts as **that session on that space**: no wallet, no pin, no device
key is read, so a cwd pinned to another space does not matter. It keeps the
session's rules — its own home only under `/_/sessions/` (for `write`,
`edit`, `rm`, `mv`, `put`, `checkout`, `table`, and `new`, whose instance
lands in its `in` folder or next to the template), `session
archive|interrupt|resume|unarchive|tags` on itself and its descendants
(`archive` and `unarchive` also on a session it created and, for a top-level
agent, on any session of its group),
`session create` makes a child task (`--kind agent` a child agent,
`--top-level` a top-level agent, agents only), `session request <child>
<message> [--deadline S]` opens a request, `send` DMs as the session (no
`--wait`, no `--attach`), `exec`/`ps`/`kill` see only its own execs. Other
verbs fail with `not available to a session`; a missing or rejected token is
an error, never a quiet fallback to the wallet. You act in your session's
group: `WUHU_IDENTITY=wallet`, `--group` and `WUHU_GROUP` are refused.
Outside a session's exec (a person's terminal) nothing of this applies.

## Files

```bash
wuhu write /notes/plan.md --body "content"    # text in, from argv
wuhu read /notes/plan.md [--rev N] [--lines 2-5]
wuhu put /images/logo.png < logo.png          # bytes in, from STDIN
wuhu cat /images/logo.png > logo.png          # bytes out, byte-exact
wuhu transcribe memo.m4a [--language en]      # speech to text through the space
wuhu transcribe                               # which provider and model the space would use
wuhu edit /notes/plan.md "old text" "new text"
wuhu ls /notes        # markers: d dir, - file, t table; then size, then name
wuhu stat /notes/plan.md
wuhu mv /notes/plan.md /notes/done.md
wuhu rm /notes/done.md
wuhu grep pattern [/dir]
wuhu find '**/*.md' [/dir]
```

Sharp edges:

- Paths are keys: `wuhu write /a/b/c.md` creates the whole path; directories
  are implicit, there is no mkdir.
- `write` takes its content as `--body <text>` and never reads stdin. A bare
  `wuhu write <path>` is a usage error pointing at `put`.
- `write`/`read`/`edit` ride the JSON tool wire, which is UTF-8 text only.
  Reading a binary file through them fails with `unsupported: <path> is not
  UTF-8 text` instead of returning mojibake.
- `put`/`cat` are the byte lane (`PUT`/`GET /v1/f<path>`): byte-exact, no
  line semantics, no clamping. `put` takes `--force`; `cat` records no wallet
  token, so a `cat` then `put` round trip needs `--force`. The served content
  type is derived from the path extension, never stored.
- Writing a path you never read fails:
  `refusing to overwrite /x: read it first, or pass --force`. The wallet
  records a version token on every `read`/`write`/`stat`; mutations send it
  as compare-and-swap. `--force` skips the check — use it deliberately.
- `edit` replaces exactly one occurrence of `old`; if the content changed
  since your last read (or `old` does not match), it fails with `conflict` —
  re-read, then retry.
- After `wuhu mv`, the moved node's token changes but the wallet keeps the
  old one, so an immediate `rm`/`write` on the new path can hit
  `conflict: version mismatch`. Run `wuhu stat <new-path>` (or `read`) first
  to refresh the token.
- `--lines A-B` is inclusive and 1-based.

## History

```bash
wuhu history /notes/plan.md      # lines: <rev> <op> <unix-mtime>
wuhu checkout /notes/plan.md 3   # restores rev 3 content by minting a NEW rev
```

## Tables and queries

```bash
wuhu table create /tasks.table '{"columns":[{"name":"title","type":"string"},{"name":"status","type":"string"},{"name":"priority","type":"integer"}]}'
wuhu table mutate /tasks.table '[{"kind":"insert","values":["Ship it","doing",1]},{"kind":"update","row":1,"values":["Shipped","done",1]},{"kind":"delete","row":1}]'
wuhu table alter  /tasks.table '{"columns":[...]}'   # replaces the whole header
wuhu query 'SELECT * FROM "/tasks.table"'
```

Sharp edges:

- Table paths **must end in `.table`**; anything else fails with
  `not a table`.
- `table create`/`alter` take the **bare header JSON object** (not wrapped in
  any envelope): `{"columns":[{"name":...,"type":...}]}` with types
  `string | integer | number | boolean | json`.
- `table mutate` takes the **bare ops array**. Ops are tagged with `"kind"`:
  - `{"kind":"insert","values":[...]}` — values positional, in column order,
    excluding `id`.
  - `{"kind":"update","row":<id>,"values":[...]}` — full row replacement.
  - `{"kind":"delete","row":<id>}`.
- Every table has an implicit auto-increment `id` column; `row` in ops refers
  to that id. `query` output is TSV with a header row and includes `id`.
- In SQL the table name is the path **in double quotes**:
  `SELECT * FROM "/tasks.table"`. Unquoted paths are a SQL syntax error.
- `query` is SELECT-only; INSERT/UPDATE/DELETE are rejected — mutate through
  the verbs.

## Observe

```bash
wuhu observe --glob '/notes/**' [--from REV] [--once]
wuhu observe --sql 'SELECT count(*) AS n FROM "/tasks.table"' [--throttle-ms N] [--once]
```

One JSON payload per line; streams until killed unless `--once`.

- Glob events look like
  `{"kind":"write","path":"/notes/x.md","rev":7,"entry":"file"}` (deletes
  carry no `entry`). `--from N` replays journal history with rev > N before
  going live — `--from 0` replays everything; without `--from` you only see
  new events, so a quiet space prints nothing until something changes.
- `--from` applies only to `--glob`, and glob observe keeps no cursor for
  you: the value is a rev you already hold — a prior event's `rev` or the
  `rev N` printed by a mutation.
- SQL observe delivers the current snapshot immediately
  (`{"columns":[...],"rows":[[...]]}`), then again on every change.
- `--once` is asymmetric: glob prints the first event and exits (it may wait
  forever on a quiet glob); sql prints the first snapshot that differs from
  the cursor stored in the wallet, so repeated `--sql --once` calls are
  change-detectors.

## Templates

```bash
wuhu write /templates/task.md --body '---
template: {"strategy":"incr","prefix":"TASK","pad":3}
---
# Task
'
wuhu new /templates/task.md /work    # prints: /work/TASK-001.md
```

Strategies: `{"strategy":"incr","prefix":"TASK","pad":3}` (prefix must be
uppercase ASCII) or `{"strategy":"date","folders":true|false,
"specificity":"minute"}` (local-time date names).

## Upgrading the CLI

```bash
wuhu upgrade [--check] [--lane dev|beta|release]
wuhu upgrade --rollback
```

Self-updates from `https://wuhu.ai`, unauthenticated: one GET of the lane
pointer, then the artifact it names, checked against its sha256. Installs into `~/.wuhu/bin/<version>/wuhu` and atomically
flips the `~/.wuhu/bin/wuhu` symlink; the last 3 versions are kept and
`--rollback` flips back one. The binary follows its own release lane
(`-dev.N` / `-beta.N` / stable) — crossing lanes takes an explicit `--lane`.
`--check` only prints. Never touches PATH, shells, or dotfiles; if another
`wuhu` shadows the installed one on PATH it warns and leaves it alone.

## Server

```bash
wuhu serve <folder> [--host <address>] [--port N] [--web-port N] [--origin <url>] [--web-origin <url>] [--dev] [--public-read] [--dev-import <folder>] [--dev-export <folder>] [--cert <pem> --key <pem>]
```

Both listeners bind `--host` (default `127.0.0.1`, loopback only); pass
`--host 0.0.0.0` to expose the server on the LAN.
API origin on `:N` (default 5540), raw space content on `:N+1` — both always
TLS (self-signed into `<folder>/tls` unless `--cert`/`--key`); `--origin`
advertises the server's canonical API origin through `GET /v1/server`, so
share-login and machine join links carry it instead of the
minting wallet's own address; `--web-origin` advertises an explicit
web-content URL the same way. Auth walls are on by default and usable
as-is: API calls authenticate with an enrolled device (`wuhu login`) and
web-content reads with a live browser read session. `--public-read` opens
content reads of the `shared` group (the bare host) to anyone, a public
board; group hosts still need a read session, and writes stay walled. `--dev` drops
both walls, for local iteration only. `--dev-import <folder>` imports a
plain folder into the space on boot; `--dev-export <folder>` dumps it back
on graceful shutdown. `--dev` alone neither imports nor exports.

## Accounts and keys

```bash
wuhu user add --space <folder> [--name N] [--admin]  # create a human account, prints its id
wuhu user reset --space <folder> <account-id> # wipe the account's keys and read sessions
wuhu user list                        # roster of the pinned space (admin)
wuhu user remove <account-id>         # kill its keys/logins, keep its history (admin)
wuhu user handle <handle> [--display-name T]  # claim your own display handle
wuhu user profile                     # your own directory entry: @handle principal [display name]
wuhu key list [--account <id>]        # enrolled keys (own account; others need admin)
wuhu key revoke <pubkey>              # kick a key; the device must re-enroll
```

A handle is display only — never a login, never in auth. It is lowercased, unique per space, renameable by claiming another, and matches `[a-z0-9][a-z0-9-]{1,31}`. Rows keep storing the principal (a persona name such as `cedar-kite-lantern`); handles resolve at read time, so a rename re-attributes history everywhere.

`add` and `reset` are offline recovery: they operate directly on
`<folder>/space.sqlite` with the server stopped — possession of the space
folder is root; there is no localhost side channel. Each `add` mints a new
account; the first account of an adminless space becomes admin without
`--admin`. `reset` keeps the account; re-enroll devices afterwards.

`list`/`remove` and the `key` verbs run against the pinned space server.
Admin is an account flag: admins manage every account and key, everyone else
manages only their own invites and keys. The last admin can be neither
demoted nor removed — recover an adminless space offline with
`wuhu user add --space <folder> --admin`.

## Device enrollment

```bash
wuhu login < invite-link # enroll this device from a one-time invite link (stdin)
wuhu share-login         # mint a one-time login link for your account, shown as a terminal QR
```

`wuhu login` reads an invite link
(`https://host:port/_/enroll#token=jt_...&space=spc_...&fp=sha256:...`) from
stdin — never from arguments, since argv leaks via ps — records the delivered
certificate fingerprint into user-level trust, lazily generates this device's
per-space ed25519 key into `~/.wuhu/keys/<space-id>.key` (the `spc_...` space
identity from the link; 0600; never reused
across spaces, never synced), and presents the public key. The link dies at
enrollment; a second use fails. `wuhu share-login [--ttl <seconds>]` requires
an enrolled device and a pinned space; its link dies at first use or after
`--ttl` seconds (default 600, at most 259200).

## Machines, exec, vault

```bash
wuhu machine add [--name N]         # prints id + join token (shown ONCE)
wuhu machine join <server-url> [fingerprint] [--name N] < token   # on the box; token from stdin, never argv
wuhu machine run                    # on the box, foreground
wuhu machine list                   # <name|-> <id> <attached|detached>
wuhu machine name <machine> <name>  # rename; the mc_ id never moves
wuhu machine rotate|revoke <machine>
wuhu machine move <machine> --group <group>   # needs an admin of both groups
wuhu exec --cwd machines://<machine>/tmp [--secret ENV=NAME] [--timeout S] [--max-output N] -- ls -la
wuhu ps
wuhu kill <exec-id>
wuhu vault set <machine> NAME < value    # value from stdin, never argv
wuhu vault list|remove <machine> [NAME]
wuhu secret set NAME < value             # the acting group's secret for run_script (wuhu:secret); value from stdin
wuhu secret list|remove [NAME]
```

A machine belongs to one group: `machine add` puts it in your personal group, and only sessions and people acting in a group that reads it see or use it. `machine move` hands it to another group (`--group shared` makes it usable from every group that reads shared). Secrets are per group too: `wuhu --group <g> secret …` works on that group's; setting needs an admin of it, removing a human admin.

`<machine>` is the machine's name or its `mc_` id — every machine verb and route takes either, `exec --cwd` included. `machine join` claims `--name` (default: the box's hostname, suffixed until free — `mini`, `mini-2`, …) only when the machine is still unnamed; a named machine keeps its name, so renaming is `machine name` alone.

`exec` runs argv directly (no shell) and is pipe-clean: command stdout/stderr
map byte-exactly to local stdout/stderr, diagnostics go to stderr. Exit codes
pass through; signal deaths exit `128+SIG`; `125`/`124`/`123`/`122` are
machine-lost / cancelled / tail-lost / unreachable.

## Devices

```bash
wuhu device list                                      # <id> <kind> <machine|-> <name>
wuhu device set <device> [--name N] [--machine M]     # omitted fields are left alone
```

A device is an app install signed into the space; it registers itself on every connect, so this is not a list you add to. Its three-word id is what a `<device>` header line names and what the `manipulate_ui` tool addresses. `--machine` takes an `mc_` id or a machine name, and is how the Mac running the app is tied to the box agents exec on.

## Sessions and messaging

```bash
wuhu models update                  # seed/merge /models.json (additive; your edits win)
wuhu tool-roster [--executor kernel|claude-code] [--json]  # the tools sessions of that kind are given
wuhu usage [--json]                 # plan usage per codex/claude provider, window by window
wuhu auth set <provider> < key.txt  # store an api key for the pinned space (stdin)
wuhu auth login codex               # chatgpt device-code login (codex subscription models)
wuhu auth list                      # stored credentials, values redacted
wuhu auth remove <provider>         # drop a credential; `wuhu auth logout` also revokes chatgpt tokens
wuhu session create --provider anthropic --model claude-sonnet-5 [--effort high] [--tag t]... "Title"
wuhu session request [--deadline SECS] <child-id> "message"   # a session's exec only
wuhu send <session-id> "message" [--wait [--timeout SECS]]
wuhu session log <session-id>       # channel view (default, every executor)
wuhu session log --direct|-v|-vv [--limit N] [--before REF] <session-id>
wuhu session entry <session-id> <ref>
wuhu session list
wuhu session rename <session-id> "New title"
wuhu session tags <session-id> [tag]...   # replace the whole tag list; none clears it
wuhu session interrupt|resume|archive|unarchive <session-id>
wuhu inbox
```

- `session create` prints the new session id — an allocator word-name like
  `harbor-lantern-moss`, not a UUID; every session verb and `send` want that
  id, and they **reject** anything not shaped like ≥3 lowercase hyphenated
  words with `not a session id`. Never fabricate or validate ids as UUIDs.
- `--provider`/`--model` are required, validated against `/models.json` —
  run `wuhu models update` first on a fresh space. The provider's dialect
  picks who runs the session: a `claude` provider runs Claude Code, every
  other one the kernel loop. `--effort` must be one of the model's declared
  effort strings (omitted means the model's default). The
  session is inert until something is posted; the title is a positional
  argument, after the flags.
- `auth` writes `~/.wuhu/credentials/<space-id>.json` on the local host, so
  run it where the space server runs. Environment variables
  (`<PROVIDER>_API_KEY`) override the stored key. `auth login` prints a URL
  plus a short code and blocks (up to 15 minutes) until the code is approved
  in a browser on any device; the server refreshes the tokens itself from
  then on.
- `send` posts into an agent's box. A task takes no messages from people, so
  a person's send to one is refused (`403 taskInput`); run by a session, it
  lands in that session's DM with the task. The session answers there with
  `send_message`. `--wait` blocks
  until the session posts back into that conversation, and prints it. It
  exits nonzero **immediately** if the session is already errored, and
  nonzero on error or `--timeout SECS` expiry; `--timeout` requires `--wait`.
- `session log` default = the session's channel (threads, senders, replies;
  every executor). `--direct` is the deep per-session log of a kernel or
  Claude Code session — a Claude Code session's is translated from its
  stored log, so Wuhu tools show under their own names and Claude Code's as
  `ClaudeRead`, `ClaudeWrite`, `ClaudeEdit`, `WebSearch` — and levels
  select kinds: `--direct` = narrative (inputs,
  reminders, assistant text, replies, compaction markers); `-v` adds tool
  calls, reasoning summaries, and cumulative context usage; `-vv` adds tool
  results. Every item carries a
  `[ref]` header; `session entry <session-id> <ref>` prints that one item
  unclipped. Both views serve the tail — last 50 by default, `--limit N` to
  cap, `--before` for older pages (the `[n]` cursor in the channel view, a
  `[ref]` in the direct view). Refs are short-lived — compaction invalidates
  them (typed `unknownRef`/`trimmedRef` errors); re-read the log for fresh
  ones.
- `session rename` sets a session's title and prints the stored value; a
  session can do the same to itself with the `set_title` tool. One non-empty
  line, at most 200 characters.
- `session tags` replaces a session's whole tag list, archived sessions
  included, and prints the stored tags one per line; with no tags it clears
  the list. A session retags itself and its descendants from run_script's
  `wuhu:session` (`setTags`).
- `session list` is sugar over
  `wuhu query 'SELECT id, title, hold, work, lifecycle, last_activity_at FROM sessions ...'` —
  query or `observe --sql` the `sessions` table directly for dashboards.
- `archive` refuses a session with unfinished work (interrupt it or let it
  settle); `unarchive` works only inside the ~24 h grace window.
- `inbox` prints notifications above this wallet's cursor, then advances the
  cursor — a second call prints nothing until something new arrives. One
  inbox and one cursor span all your groups, so switching `--group` replays
  nothing; each line names its group (`[12] group ops · message from …`), and
  a sender from outside the conversation's group shows theirs. Sender
  identity is a server-minted persona cached per `.wuhu` wallet × space
  (enrolled devices only; unenrolled seats act as the owner), so different
  work folders are different senders.

## Skills

```bash
wuhu skill export
```

Installs these skills for coding agents into `~/.claude/skills/` and the
Agent Skills standard location `~/.agents/skills/` (read by Codex CLI and
pi). Idempotent; prints every path it writes; skips files it does not own.
