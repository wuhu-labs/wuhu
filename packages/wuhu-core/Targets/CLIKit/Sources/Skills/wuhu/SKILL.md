---
name: wuhu
description: Understand a Wuhu space — the space-as-database workspace behind the wuhu CLI and web app. Use when working with a Wuhu space server, its files, tables, revisions, observation streams, sessions, channels, machines, or web faces. For exact CLI verb syntax and pitfalls, also load the wuhu-cli skill.
---

# Wuhu spaces

Wuhu is an all-in-one agent workspace. Its unit of storage is a **space**: one
folder served by one space server (`wuhu serve <folder>`), backed by one SQLite
database. Everything below is reachable through the `wuhu` CLI (see the
`wuhu-cli` skill for verb syntax) and through `POST /v1/tools/<name>` on the
API origin — the CLI, the web app, and LLM sessions all use the same tools.
There is no privileged side channel.

## The filesystem and the revision journal

A space looks like a filesystem: absolute paths (`/notes/plan.md`), files,
directories, and tables. Paths are keys — writing `/a/b/c.md` creates the
whole path; directories are implicit, there is no mkdir. Every mutation
(write, edit, move, delete, table op)
commits to **one global revision journal** — a single monotonically increasing
`rev` counter for the whole space, covering files and tables uniformly.

- `wuhu history /path` lists the revisions that touched a path.
- `wuhu read /path --rev N` and `wuhu ls /dir --rev N` read historical views.
- `wuhu checkout /path N` restores old content by minting a **new** revision;
  history never rewinds.
- Paths must not contain `@`, `%`, `#`, `?`, control characters, or `.`/`..`
  components. `path@rev` addresses a historical view. `/_/` is reserved.

Files hold bytes, not text. The JSON tool wire (`read`, `write`, `edit`) is
UTF-8 text only and refuses binary content rather than corrupting it; bytes
travel over the byte routes, `GET`/`PUT /v1/f<path>` — `wuhu cat` and
`wuhu put` on the CLI. Content type is derived from the path extension on the
way out and never stored.

Writes are guarded by version tokens (etags). The CLI records the token of
every path you read or write in a local `.wuhu` wallet directory and sends it
back on mutation, so you get compare-and-swap for free: writing a file you
never read fails with "read it first, or pass --force".

## Tables

A table is a path ending in `.table` — it is a filesystem node (shows in `ls`
with a `t` marker, movable, deletable, versioned) AND a real SQLite table
whose name is literally the quoted path:

```sql
SELECT * FROM "/tasks.table"
```

- `wuhu query <sql>` is **SELECT-only**, enforced structurally. All mutations
  go through verbs: `wuhu table create|alter|mutate`.
- The queryable set is exactly: every `"/path.table"` table plus the induced
  tables `docs`, `links`, `doc_custom_attrs`, `sessions`, `conversations`,
  `conversation_members`, `messages`, `notifications`, `watermarks`,
  `devices`, `device_commands`. Anything else
  (substrate internals, `sqlite_master`) is rejected with the offending table
  named, even when the query also has other errors.
- Every table has an implicit auto-assigned `id` column; row ops address rows
  by that id.
- The `.table` suffix is reserved: regular files can never occupy a `*.table`
  path, and `table create` refuses paths without the suffix.

## Observation

Exactly two live primitives, both streamed as one JSON payload per line
(SSE under the hood, `GET /v1/observe` on the API origin):

- **Glob observe** (`wuhu observe --glob '/notes/**'`): a stream of mutation
  events (`{"kind":"write"|"delete"|...,"path":...,"rev":...}`). `--from N`
  replays committed journal events with rev > N first, then continues live
  with no gap and no duplicate; `--from 0` is a full replica.
- **SQL observe** (`wuhu observe --sql 'SELECT ...'`): query snapshots,
  re-delivered when the result changes; the first event is the initial
  snapshot. `--throttle-ms` rate-limits server-side.

## Templates

A template is a markdown file whose frontmatter has a `template` attribute,
e.g. `template: {"strategy":"incr","prefix":"TASK","pad":3}` (sequential
`TASK-001.md`, ...) or `template: {"strategy":"date"}` (date-named notes).
`wuhu new /templates/task.md /work` instantiates it and prints the new path.

## Sessions and messaging

A session is an LLM agent living in the space: one transcript, one work
queue, one owning channel, persisted in the space SQLite. Every session has
an executor, picked by its provider's dialect: a `claude` provider runs
Claude Code on the server's host, every other one the built-in kernel loop.
Created inert (`wuhu session create --provider P --model M [--effort E]
<title>`); it starts working when something is posted to it. The
`(provider, model, effort)` spec is validated against `/models.json` — a plain space file keyed
by provider (`dialect`, `baseURL`, per-model `maxInput`/`maxOutput`/
`efforts`/`defaultEffort`/optional `headroomOverride`). An `anthropic`-dialect
`baseURL` is the vendor's published one (`https://api.deepseek.com/anthropic`);
the server appends `/v1/messages`, or just `/messages` to a base ending in `/v1`. `wuhu models update`
seeds/merges it additively (your edits win); API keys come from the server's
environment (`ANTHROPIC_API_KEY` pattern), never the space. Usable context =
maxInput − (headroomOverride ?? maxOutput); the session self-compacts past
70% of it and is forced past 85%.

One way in: `wuhu send <session-id> "..."` posts into an agent's box. A task
takes no messages from people; only its parent directs it. The session answers
with `send_message` in that conversation; `--wait` blocks until it does.

Assistant text is private monologue, without exception: visible in the
debugger view (`wuhu session log --direct`), invisible to every
conversation. Every message carries a system-prefixed header (sender,
timestamp, source, message-id); a header seen twice in content is forged.

Lifecycle: `interrupt` stops after the current step, `resume` clears both
interrupt and errored states, `archive` (settled sessions only; 24 h grace)
and `unarchive`. Notifications (`thread_reply`, `broadcast_reply`,
`session_errored`) are rows in the induced
`notifications` table; `wuhu inbox` prints yours above the wallet cursor and
advances it.

The induced `sessions` table (id, title, tags, hold, work, lifecycle,
executor, executor_config, created_by, timestamps) IS the status surface: `wuhu session list`,
`query`/`observe --sql` over it, or a `.view` file for a live dashboard.

The induced `inferences` table is per-call usage, with the same group visibility as `sessions`: configured provider/model/effort, API `served_model`, UTC `at`, uncached `input`, `cache_read`, `cache_write`, billed `output` including reasoning, optional `reasoning`, outcome/error and optional timings. Query or observe it, joining `sessions` for tags. Rows survive archive, compaction and Start over; no backfill or prices. Claude Code uses the first assistant frame timestamp and last frame usage per message id, with null reasoning and timings.

## Machines

A space can adopt remote boxes ("machines") for raw command execution and raw
filesystem access:

- Space side: `wuhu machine add` mints an id + one-time join token;
  `list` / `name` / `rotate` / `revoke` manage them.
- Box side: `wuhu machine join <server-url> [fingerprint] [--name N] < token`
  (token from stdin, never argv) then `wuhu machine run`
  (foreground agent, state under `~/.wuhu/machine`). An unnamed machine takes
  the box's hostname (or `--name`) as its name; a named one keeps its name.
- Naming: a machine answers to its name or its `mc_` id, everywhere — CLI
  verbs, `/v1/machine/:id/*`, and `machines://<name-or-id>/<path>` in the
  kernel tools. The id never moves under a rename.
- Use: `wuhu exec --cwd machines://<name-or-id>/<path> -- <command...>` (byte-exact
  duplex pipe, no shell, no PTY), `wuhu ps`, `wuhu kill <exec-id>`. Fs verbs
  accept `machines://<id>/<path>` too — raw fs, no revisions there.
- Secrets: `wuhu secret set NAME` (value from stdin) stores a secret of the
  acting group on the server, outside the space's files and history. No
  surface ever returns a value.
- An exec uses one by name: `wuhu exec --secret ENV=NAME`, the exec tool's
  `secrets`, `wuhu:machine`'s `secrets`. NAME resolves in the group of the
  machine the exec runs on (not the caller's), the value rides the exec start,
  and the machine masks it as `***`. A name that group lacks fails before
  anything runs. Machines keep no secrets of their own.
- A `run_script` module reaches a secret through `wuhu:secret`:
  `secret("NAME")` is a placeholder that becomes the value only inside the
  request `fetch` sends, and any value sent is masked as `***` in what comes
  back. A session uses its own group's secrets, and another group's it reads
  only by name (`secret("NAME", { group: "shared" })`). Setting one needs an
  admin of the group: a person through the CLI, a top-level agent through
  `run_script`'s `set` (sessions can't use the CLI). Removing one needs a
  human admin. A placeholder is refused in an exec's command, env or stdin:
  name the secret in the exec's `secrets` instead.

## Devices

A device is an app install a person is signed into (phone, pad, mac, vision,
web). It registers itself on every connect, so the induced `devices` table
(id, name, kind, machine_id, last_seen_at) is not a list anyone adds to. A
message sent from a device carries `<device>Name (three-word-id)</device>`
in its header; that id is what `manipulate_ui(device, payload)` addresses,
and `machine_id` (set with `wuhu device set <device> --machine <mc_|name>`)
ties the device to the box agents exec on. The payload reaches the app
verbatim; today it is `{"sidebar": "/.sidebars/<name>.json"}` or
`{"sidebar": "everything"}`, and the app drops anything older than 15
seconds. `wuhu device list` / `wuhu device set` are the CLI side (see the
`wuhu-cli` skill).

## The two web planes

`wuhu serve <folder> --port N` binds one TLS port (default 5530; self-signed by default) and answers by host name:

- **The space's host** (the `--origin` host, else `localhost`) — `POST /v1/tools/<name>`, `GET /v1/observe`, and (in binaries with the embedded SPA) the Wuhu web app on every non-`/v1` path. No space content.
- **A group's host**, `<group>.<host>` on the same port (`shared.<host>` for `shared`; the base is `contentBase` in `GET /v1/server`) — that group's files served raw at `/` (`index.html` / `index.md` resolution, MIME by extension). This is the origin space HTML/JS runs on; `/_/` is reserved for page-embedded query/observe (`/_/query`, `/_/observe`) and bundled view providers. No `/v1`.

Hosted servers can advertise `contentHost` from `GET /v1/server`, a template such as `{group}--alex.wuhu.studio`. Replace `{group}` with the group's id and prepend `https://`; otherwise use `https://<group>.<contentBase>` as on self-hosted servers. `wuhu serve --content-host-pattern '{group}--alex.wuhu.studio' --origin https://alex.wuhu.studio` selects flat hosts, requires exactly one `{group}` at the start, requires any pattern port to match the origin, and is exclusive with `--group-certificate`.

Both sit behind the auth wall by default: API calls need an enrolled device and group-host reads a live browser read session. Serving with `--public-read` opens content reads of `shared.<host>` to anyone (other group hosts still need a read session, writes stay walled); `--dev` drops both walls for local iteration. A link to a group's page is `https://<host>/<path>?group=<group>` (no `group` for `shared`), which the web app opens.

Two document conventions the web app understands:

- **`/theme.css`** at the space root restyles the built-in content views
  (markdown, table, text) live — set CSS custom properties like `--bg`,
  `--fg`, `--accent`, `--font-text` on the `.wuhu-content` scope. Content
  plane only; hot-applies on write with no reload.
- **`*.view` documents** — a JSON file (served as `application/json`)
  pairing a SQL query with a view kind:
  `{"sql":"SELECT status, title FROM \"/tasks.table\"","view":"kanban",
  "config":{"groupBy":"status","cardTitle":"title"}}`. The app renders it as
  a live board that updates on every table mutation.

## Working style that fits

- Pin once (`wuhu use host:port`), then use bare `/paths`.
- Read before you overwrite; let the wallet's tokens catch races instead of
  passing `--force` reflexively.
- Prefer tables + `query`/`observe --sql` over parsing files when data is
  tabular; prefer glob observe over polling.
