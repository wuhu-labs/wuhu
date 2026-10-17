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

An exec a session runs (its `exec` tool, or a `run_script` spawn) carries `WUHU_EXEC=1`, `WUHU_TOKEN` and `WUHU_SPACE_URL`, set by the server. There `wuhu` acts as **that session on that space**: no wallet, no pin, no device key is read, so a cwd pinned to another space does not matter. It keeps the session's rules — its own home only under `/_/sessions/` (for `write`, `edit`, `rm`, `mv`, `put`, `checkout`, `table`, and `new`, whose instance lands in its `in` folder or next to the template), `session archive|interrupt|resume|unarchive|tags` on itself and its descendants (`archive` and `unarchive` also on a session it created and, for a top-level agent, on any session of its group), `session create` makes a child task (`--kind agent` a child agent, `--top-level` a top-level agent, agents only), `session request <child> <message> [--deadline S]` opens a request, `send` DMs as the session (no `--wait`, no `--attach`), `exec`/`ps`/`kill` see only its own execs. Other verbs refused locally by the CLI fail with `not available to a session; set WUHU_IDENTITY=wallet to act as the wallet's owner`; a missing or rejected token is an error, never a quiet fallback to the wallet. You act in your session's group: `--group` and `WUHU_GROUP` are refused unless you opt into the wallet.

Set `WUHU_IDENTITY=wallet` in exec's `env` to use the wallet found from cwd up, as its owner on its pinned space, ignoring the session token and URL. Use it for another space, or for verbs only the wallet's owner has when that person asked for it. The CLI prints `acting as <persona> (wallet)` on stderr (`anonymous` for a request without wallet credentials, `the local user` for local-only commands). Wallet mode honors the normal group selection: `--group` beats `WUHU_GROUP`, which beats the wallet's configured group. The announcement uses the command's actual target, not an old pin; repinning to a new space does not look up the old space's persona. Wallet or identity errors fail, never fall back to the session.

`wuhu id-token --audience <origin> [--json]` prints a 60-second OIDC token for this exec (claims `space`, `group`, `session`, `machine`, `exec`; `sub` is `<group>/<session>`) for a service that trusts this space's issuer, such as the build pool. It presents only the exec's `WUHU_ID_TOKEN_REQUEST` at `WUHU_ID_TOKEN_URL`, both set by the server, and fails outside a session's exec.

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
wuhu checkout /notes/plan.md 3   # restores rev 3 content; identical file bytes are a no-op
```

A checkout to identical file bytes returns the live revision and current token without minting a revision, journaling history or emitting a mutation. Other successful checkouts mint a new revision; table checkouts always mint, even when their rows are identical. History never rewinds.

## Tables and queries

```bash
wuhu table create /tasks.table '{"columns":[{"name":"title","type":"string"},{"name":"status","type":"string"},{"name":"priority","type":"integer"}]}'
wuhu table mutate /tasks.table '[{"kind":"insert","values":["Ship it","doing",1]},{"kind":"update","row":1,"values":["Shipped","done",1]},{"kind":"delete","row":1}]'
wuhu stat /tasks.table                              # records the current token
wuhu table alter /tasks.table '{"columns":[...]}'    # guarded whole-header replacement; --allow-drop-columns to omit columns
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

Self-updates from `https://wuhu.ai`, unauthenticated: one GET of the lane pointer, then the artifact it names, checked against its sha256. Installs into `~/.wuhu/bin/<version>/wuhu`, then copies that binary to a temp file and renames it over `~/.wuhu/bin/wuhu`, a real file whose path never changes, so macOS privacy grants survive upgrades; `~/.wuhu/bin/.current` names the version. The last 3 versions are kept and `--rollback` puts the previous one back the same way. The binary follows its own release lane (`-dev.N` / `-beta.N` / stable) — crossing lanes takes an explicit `--lane`. `--check` only prints. Never touches PATH, shells, or dotfiles; if another `wuhu` shadows the installed one on PATH it warns and leaves it alone.

## Minimal agent

```bash
wuhu agent [--log run.jsonl | --resume run.jsonl] < request.json
```

Runs a read/write/bash coding agent in the current directory, no space involved, until the model calls `complete`; prints `{"result": ...}`. The request names the model, its provider's `/models.json` entry, the credential, `system`, `task`, `maxTurns` and `bashTimeoutSeconds`: `wuhu agent --help` shows the shape. Credentials go only on stdin.

## Server

```bash
wuhu serve <folder> [--host <address>] [--port N] [--origin <url>] [--dev] [--public-read] [--dev-import <folder>] [--dev-export <folder>] [--cert <pem> --key <pem>] [--group-certificate <pem> --group-private-key <pem>]
```

Hosted servers can advertise `contentHost` from `GET /v1/server`, a template such as `{group}--alex.wuhu.studio`. Replace `{group}` with the group's id and prepend `https://`; otherwise use `https://<group>.<contentBase>` as on self-hosted servers. `wuhu serve --content-host-pattern '{group}--alex.wuhu.studio' --origin https://alex.wuhu.studio` selects flat hosts, requires exactly one `{group}` at the start, requires any pattern port to match the origin, and is exclusive with `--group-certificate`.

One TLS port, `--port` (default 5530), bound on `--host` (default `127.0.0.1`, loopback only); pass `--host 0.0.0.0` to expose the server on the LAN. The `--origin` host serves the API and the web app; each group's raw content is served at `<group>.<host>` on the same port (`shared.<host>` for `shared`). `--origin` is advertised through `GET /v1/server` (with `contentBase`, the `host[:port]` under the group hosts), so share-login and machine join links carry it instead of the minting wallet's own address; without it the host is `localhost` and the group hosts are `<group>.localhost:<port>`, this machine only. TLS always: self-signed (`localhost`, `*.localhost`) into `<folder>/tls` unless `--cert`/`--key`, which must cover `<host>` and `*.<host>`; only that generated certificate's fingerprint rides invites, share-login links and machine join tokens, and a `--cert` server, self-signed or not, must pass its clients' system trust. Auth walls are on by default and usable as-is: API calls authenticate with an enrolled device (`wuhu login`) and group-host reads with a live browser read session. `--public-read` opens content reads of `shared.<host>` to anyone, a public board; other group hosts still need a read session, and writes stay walled. `--dev` drops both walls, for local iteration only. `--dev-import <folder>` imports a plain folder into the space on boot; `--dev-export <folder>` dumps it back on graceful shutdown. `--dev` alone neither imports nor exports.

## Accounts and keys

```bash
wuhu user add --name <name> [--admin] [--ttl <seconds>] # live: account id + one-time invite (admin of shared)
wuhu user invite <account-id> [--ttl <seconds>] # live: fresh invite (self or admin of shared)
wuhu user admin <account-id>           # live: grant admin of shared (admin of shared)
wuhu user add --space <folder> [--name N] [--admin]  # offline: create a human account, prints its id
wuhu user invite --space <folder> [--server <url>] [--ttl <seconds>] <account-id> # offline: mint invite
wuhu user reset --space <folder> <account-id> # wipe the account's keys and read sessions
wuhu user list                        # roster of the pinned space (admin)
wuhu user remove <account-id>         # kill its keys/logins, keep its history (admin)
wuhu user handle <handle> [--display-name T]  # claim your own display handle
wuhu user profile                     # your own directory entry: @handle principal [display name]
wuhu key list [--account <id>]        # enrolled keys (own account; others need admin)
wuhu key revoke <pubkey>              # kick a key; the device must re-enroll
```

A handle is display only — never a login, never in auth. It is lowercased, unique per space, renameable by claiming another, and matches `[a-z0-9][a-z0-9-]{1,31}`. Rows keep storing the principal (a persona name such as `cedar-kite-lantern`); handles resolve at read time, so a rename re-attributes history everywhere.

Without `--space`, `add`, `invite` and `admin` act as the signed-in person on the pinned running server; an unenrolled device is refused, even under `--dev`. Only an admin of `shared` may add people or grant admin; any person may invite their own account. `add` creates the personal group and `shared` membership, prints the account id, then a one-time device invite. `invite` prints only the link, for a lost invite or another device; both default to a one-hour lifetime (`--ttl <seconds>`), with the expiry note on stderr. Links use the server's advertised origin (the pinned address when no origin is configured), space id and generated-certificate fingerprint; discovery errors are reported, never silently bypassed.

`add`, `invite` and `reset` with `--space` are offline recovery: they operate directly on `<folder>/space.sqlite` with the server stopped — possession of the space folder is root. Each `add` mints a new account; the first account of an adminless space becomes admin without `--admin`. Offline `add` prints only the account id; mint its link separately with offline `invite`. `reset` keeps the account; re-enroll devices afterwards. Offline `invite --server <url>` overrides the recorded server address; live invites do not accept that override.

`list`/`remove` and the `key` verbs run against the pinned space server. Admin means admin of `shared`: admins manage every account and key, everyone else manages only their own invites and keys. The last admin can be neither demoted nor removed — recover an adminless space offline with `wuhu user add --space <folder> --admin`.

## Device enrollment

```bash
wuhu login < invite-link # enroll this device from a one-time invite link (stdin)
wuhu share-login         # mint a one-time login link for your account, shown as a terminal QR
```

`wuhu login` reads an invite link
(`https://host:port/_/enroll#token=jt_...&space=spc_...[&fp=sha256:...]`) from
stdin — never from arguments, since argv leaks via ps — records the delivered
certificate fingerprint, if any, into user-level trust (a link without one
drops the host's pin once the server passes system trust, and enrolls through
the pin when it does not), lazily generates this device's
per-space ed25519 key into `~/.wuhu/keys/<space-id>.key` (the `spc_...` space
identity from the link; 0600; never reused
across spaces, never synced), and presents the public key. The link dies at
enrollment; a second use fails. `wuhu share-login [--ttl <seconds>]` requires
an enrolled device and a pinned space; its link dies at first use or after
`--ttl` seconds (default 600, at most 259200).

## Machines, exec, secrets

```bash
wuhu machine add [--name N] [--group G] # prints id + join token (shown ONCE)
wuhu machine join <server-url> [fingerprint] [--name N] < token   # on the box; token from stdin, never argv
wuhu machine run                    # on the box, foreground
wuhu machine list                   # <name|-> <id> <attached|detached>
wuhu machine name <machine> <name>  # rename; the mc_ id never moves
wuhu machine rotate|revoke <machine>
wuhu machine move <machine> --group <group>   # needs an admin of both groups
wuhu exec --cwd machines://<machine>/tmp [--secret ENV=NAME] [--timeout S] [--max-output N] -- ls -la
wuhu ps
wuhu kill <exec-id>
wuhu secret set NAME < value             # the acting group's secret, for run_script (wuhu:secret) and --secret; value from stdin, never argv
wuhu secret list|remove [NAME]
```

A machine belongs to one group: `machine add` puts it in your personal group without an explicit group flag; `machine add --group G` (or global `--group G machine add`) sets only the registration target, needs an admin of G but not membership (`403 adminRequired`, `404 unknownGroup`), and verifies the server echoed G (otherwise fails with an upgrade/move hint). Environment and folder groups do not set the target. Only sessions and people acting in a group that reads the machine's group see or use it. `machine move` hands it to another group (`--group shared` makes it usable from every group that reads shared). Secrets are per group too: `wuhu --group <g> secret …` works on that group's; setting needs an admin of it, removing a human admin. `exec --secret ENV=NAME` takes NAME from the group the machine belongs to, not the one you act in: the value rides the exec start, the machine masks it as `***`, and a name that group lacks fails before anything runs (`wuhu: no secret NAME in group G`, exit 127). Machines keep no secrets of their own.

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
wuhu models [--json]                # concrete models and groups with policy/ordered member aliases
wuhu models update                  # seed/merge providers-only /models.json; /model-groups.json untouched
wuhu tool-roster [--executor kernel] [--json]  # the tools sessions of that kind are given
wuhu usage [--json]                 # plan usage per codex provider, window by window
wuhu auth set <provider> < key.txt  # store an api key for the pinned space (stdin)
wuhu auth login codex               # chatgpt device-code login (codex subscription models)
wuhu auth list                      # stored credentials, values redacted
wuhu auth remove <provider>         # drop a credential; `wuhu auth logout` also revokes chatgpt tokens
wuhu session create --provider anthropic --model claude-sonnet-5 [--effort high] [--tag t]... "Title"
wuhu session create --model-group work [--effort high] "Title"
wuhu session restart --model-group work <session-id>  # Start over with fresh group placement
wuhu session inspect <session-id>   # requested target, active route, placement reason/evidence (JSON)
wuhu session request [--deadline SECS] <child-id> "message"   # a session's exec only
wuhu send <session-id> "message" [--wait [--timeout SECS]] [--viewing PATH]
wuhu session log <session-id>       # channel view (default, every executor)
wuhu session log --direct|-v|-vv [--limit N] [--before REF] <session-id>
wuhu session entry <session-id> <ref>
wuhu session list
wuhu session rename <session-id> "New title"
wuhu session tags <session-id> [tag]...   # replace the whole tag list; none clears it
wuhu session interrupt|resume|unarchive <session-id>
wuhu session archive <session-id> [--force]
wuhu inbox
```

- `session create` prints the new session id — an allocator word-name like
  `harbor-lantern-moss`, not a UUID; every session verb and `send` want that
  id, and they **reject** anything not shaped like ≥3 lowercase hyphenated
  words with `not a session id`. Never fabricate or validate ids as UUIDs.
- Either `--provider`/`--model` or `--model-group` selects a target, validated against `/models.json` (concrete) and `/model-groups.json` (groups); the two forms are mutually exclusive. A child inherits the parent’s requested target rather than its active group member. Templates supply defaults, and explicit targets replace those defaults as a whole —
  run `wuhu models update` first on a fresh space. Every provider runs in the kernel. `--effort` must be one of the model's declared
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
  `--viewing PATH` names the doc or page you have open (`/<path>`, or
  `wuhu://<group>.localspace/<path>`); the server refuses a path you cannot
  read now with `400 invalidArgument`, and the session sees it as a
  `<viewing>` header line. Run by a session, `--viewing` is refused.
- `session log` default = the session's channel (threads, senders, replies;
  every executor). `--direct` is the deep per-session log of a kernel session; old Claude Code turns are no longer translated. Levels
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
- `models` discovers concrete providers/models from `/models.json` and groups from `/model-groups.json`. `--json` returns `{providers, groups}` keyed by catalog IDs. A missing group file means no groups; malformed catalogs and provider/group ID collisions are errors. `models update` writes only provider defaults, never the group file. A seed provider colliding with a declared group ID fails before either file is changed.
- `session list` queries `sessions` with a left join to scoped `session_model_routes`, including requested_model_group from the route’s group_id, active_provider, active_model and model_route_phase. Stored executor_config is always concrete provider/model/effort; group intent lives in the additive route row. Concrete sessions without a route keep their provider/model from executor_config. `session inspect <id>` prints structured JSON with requestedTarget, active provider/model and route placement reason/evidence and recorded decisions. Query or observe the same scoped projections for dashboards.
- `archive` takes the entire descendant subtree, leaves first and root last. Without `--force`, it checks every node and refuses without archiving anything if one is busy, listing every busy id and title. `--force` first interrupts busy nodes, then archives them all and closes open requests with a final-kind “archived before reporting” message to each requester. Separately created top-level agents stay live. `unarchive` restores only one session and works only inside the ~24 h grace window.
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

## Provider capabilities

`wuhu web-search 'query' [--provider brave] [--count 8]` prints normalized JSON sources. Do not build a persistent Brave result corpus/index or train/evaluate models on returned results.

`wuhu image 'prompt' --destination ./output.png [--image ./reference.png]... [--provider qwen] [--model id] [--quality draft|standard|fine|ultra] [--size 1536x1024]` generates, or edits when references are present. Private reference bytes upload internally; local output is exclusive/create-only.

`wuhu transcribe recording.m4a [--provider qwen] [--model id] [--language en] [--timestamps words,segments] [--diarize] [--json]` uses the same capability resolver as dictation and code mode. JSON returns optional seconds-based timestamp/speaker metadata. Audio is bounded to 25 MiB/two hours. `/capabilities.json` active selection is authoritative: unconfigured capabilities synthesize Codex, broken explicit configuration never falls back. Provider keys are installed by an authorized human on the server with `wuhu auth set <credential-id>` on stdin, not `wuhu secret set`.

## Identity

`wuhu identity` prints resolved default and per-audience issuer URLs. `wuhu identity issuer-for <origin>` prints one issuer. A human space admin chooses `wuhu identity set default self|directory` or `wuhu identity set <origin> self|directory`; `wuhu identity set <origin> inherit` removes an override. Origins are exact canonical HTTP(S) origins. Configure a verifier to trust both issuer URLs before changing its setting; there is no automatic fallback when the directory is unavailable.

`wuhu identity rotate` starts the issuer-preserving key overlap immediately. `wuhu identity register-new` recovers a stale/lost directory registration by creating a new issuer; verifiers must migrate. Both are human space-admin-only and unavailable to session execs.

## Human-only channels

`wuhu channel create [--title T] [person...]` creates a channel in the acting group and prints its id. A person creator is a member; a session creator is not. `wuhu channel add <id> <person...>` and `wuhu channel remove <id> <person...>` manage people. `wuhu channel rename <id> <title>` sets the title; `wuhu channel rename <id> --clear` returns to members' names. Session membership and blank titles are typed errors. People must be members to read, post or manage the channel. Sessions in groups reading its home group may read, post and manage it without joining. Plain person messages wake no session; mention, reply-target and the attention window still apply.

`wuhu serve` and hosted serving run session loops, provider sockets, scripts and handlers only in the server process. There is no execution-placement flag or admin-exec command. Ordinary restart preserves durable sessions, queues and subscriptions, but not live inference sockets or JavaScript heaps. Installing a release does not authorize restarting a production server; finish or explicitly stop active work before an authorized restart. An unfinished handler may run anew from its last committed state and repeat effects already committed before that state.
